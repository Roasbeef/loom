//// The executor service's failure matrix: what each party observes when
//// something goes wrong, pinned case by case.
////
//// Every case runs a real broker over a real pool of fake helpers and
//// asserts four things. The caller hears exactly one settlement, or the
//// one refusal if nothing was dispatched, and then silence. That
//// settlement is the one the case should produce. When the dust settles
//// the pool's census is back to baseline (nothing borrowed, nothing
//// draining or retiring, and nothing unconfirmed unless the case is meant
//// to leave one). And the executor's inventory is empty, so no row
//// outlived its execution.
////
//// The cases from a helper actor that dies on are the service's own faults:
//// a helper actor that dies settles its call as lost promptly rather than
//// at a deadline that may not exist, a relay that dies settles its caller,
//// and a service killed mid-run or closed during output has its own
//// pinned outcome.
////
//// A caller that dies hears nothing, by definition, so those cases cannot
//// assert a settlement. What they assert is that the broker, which saw the
//// settlement, gave everything back: the books balance, and a following
//// call on a pool of one runs to its own single settlement.

import broker/broker
import broker/dispatch
import broker/exec
import broker/executor
import broker/support/fake_helper
import broker/support/planes
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import telemetry/log
import weft/poll

// --- fixtures -------------------------------------------------------------

fn plane(script: fake_helper.Script, size size: Int) -> planes.Plane {
  planes.start_scripted(size:, script: fn() { fake_helper.start_helper(script) })
}

fn call(plane: planes.Plane, deadline_ms: Int) {
  let events = process.new_subject()
  let spec = planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms:)
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  #(handle, events)
}

// The pool's census once the books have had time to balance: nothing lent,
// nothing on its way out. The broker releases a helper while it handles the
// settlement, after the caller has been told, so this polls rather than
// reading once.
fn balanced_census(plane: planes.Plane) -> exec.PoolCensus {
  let assert poll.Answered(census) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case exec.pool_census(plane.pool, waiting: 1000) {
        Ok(census) ->
          case
            census.borrowed == 0 && census.draining == 0 && census.retiring == 0
          {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
    as "the pool's census balanced"
  census
}

// The census is at baseline, with `unconfirmed` slots held, and the
// executor holds no row.
fn assert_baseline(plane: planes.Plane, unconfirmed unconfirmed: Int) -> Nil {
  let census = balanced_census(plane)
  assert census.unconfirmed == unconfirmed
  assert_no_rows(plane)
}

fn assert_no_rows(plane: planes.Plane) -> Nil {
  let assert Ok(books) = executor.snapshot(plane.service, waiting: 1000)
  assert books.live == []
}

// The call's whole story: its events up to the settlement, then silence.
fn story(events: process.Subject(broker.CallEvent)) -> List(broker.CallEvent) {
  let seen = planes.collect(events, within: 2000)
  assert process.receive(events, 300) == Error(Nil)
  seen
}

fn lost(cause: exec.LossCause) -> broker.CallEvent {
  broker.CallSettled(broker.CallFailed(exec.ExecutionLost(cause:)))
}

// A story that is a single cancelled exit.
fn assert_cancelled_exit(seen: List(broker.CallEvent)) -> Nil {
  let assert [broker.CallSettled(broker.CallExited(result))] = seen
  assert result.signal == 15
  assert result.cancelled
}

// A caller process: it clears a call, reports the handle, and then waits
// to be killed. Its events subject is the process the relay monitors.
fn doomed_caller(
  plane: planes.Plane,
  deadline_ms: Int,
) -> #(process.Pid, process.Subject(Nil)) {
  let started = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let spec =
        planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms:)
      let assert Ok(_handle) =
        broker.clear_call(plane.broker, spec, events:, waiting: 2000)
      process.send(started, Nil)

      // Output counts as having started reading; the caller dies after the
      // first thing it hears, or after a moment if there is nothing to hear.
      let _ = process.receive(events, 300)
      process.send(started, Nil)
      process.sleep_forever()
    })
  #(caller, started)
}

// After a case, the plane still serves: a call on the same pool runs to its
// own single settlement. Proves the helper came back and the budget and
// token went with it.
fn assert_next_call_runs(plane: planes.Plane) -> Nil {
  let #(handle, events) = call(plane, 0)
  broker.cancel(plane.broker, handle)
  assert_cancelled_exit(story(events))
}

// --- the ordinary failures ---------------------------------------------------

/// A caller that dies mid-run cancels the execution, the
/// helper comes back, and nothing is left on the books. The dead caller
/// hears nothing; the following call is the witness that the broker
/// settled.
pub fn caller_crash_mid_run_cancels_and_balances_the_books_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(caller, started) = doomed_caller(plane, 0)
  let assert Ok(Nil) = process.receive(started, 3000)
  let assert Ok(Nil) = process.receive(started, 3000)

  process.kill(caller)
  assert_baseline(plane, unconfirmed: 0)
  assert_next_call_runs(plane)
  planes.stop(plane)
}

/// The caller's event subject dies in the middle of a flood of output. The
/// relay delivers into a mailbox nobody reads, sees the caller's death,
/// cancels, and the execution ends; the pool is whole again.
pub fn output_pump_failure_when_the_events_owner_dies_test() {
  let plane = plane(fake_helper.ChunksThenSleep(count: 300), size: 1)
  let #(caller, started) = doomed_caller(plane, 0)
  let assert Ok(Nil) = process.receive(started, 3000)
  let assert Ok(Nil) = process.receive(started, 3000)

  process.kill(caller)
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// A cancel that arrives the instant `clear_call` returns, before anyone
/// has heard the helper speak, still reaches the execution and settles it
/// once.
pub fn cancel_before_dispatch_returns_settles_once_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 0)
  broker.cancel(plane.broker, handle)

  assert_cancelled_exit(story(events))
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// A cancel in the middle of output: the chunks that arrived are delivered
/// in order, then the one cancelled exit.
pub fn cancel_during_output_delivers_the_chunks_then_settles_once_test() {
  let plane = plane(fake_helper.ChunksThenSleep(count: 8), size: 1)
  let #(handle, events) = call(plane, 0)
  let assert Ok(broker.CallOutput(data: <<0>>, ..)) =
    process.receive(events, 2000)
  broker.cancel(plane.broker, handle)

  let seen = story(events)
  let assert Ok(last) = list.last(seen)
  assert_cancelled_exit([last])
  let chunks = list.take(seen, list.length(seen) - 1)
  assert list.all(chunks, fn(event) {
    case event {
      broker.CallOutput(..) -> True
      broker.CallSettled(..) -> False
    }
  })
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// A cancel after the execution completed is a no-op: no second event, and
/// the helper that finished cleanly is lent again rather than retired.
pub fn cancel_after_completion_is_idempotent_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  let #(handle, events) = call(plane, 0)
  let assert [
    broker.CallOutput(..),
    broker.CallSettled(broker.CallExited(result)),
  ] = planes.collect(events, within: 2000)
  assert result.code == 0
  let census = balanced_census(plane)

  broker.cancel(plane.broker, handle)
  broker.cancel(plane.broker, handle)
  assert process.receive(events, 400) == Error(Nil)
  assert balanced_census(plane).available == census.available
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// Cancelling twice settles once.
pub fn double_cancel_settles_once_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 0)
  broker.cancel(plane.broker, handle)
  broker.cancel(plane.broker, handle)

  assert_cancelled_exit(story(events))
  assert_baseline(plane, unconfirmed: 0)
  assert_next_call_runs(plane)
  planes.stop(plane)
}

// --- acquiring a helper -------------------------------------------------------

/// A pool that cannot spawn a helper refuses the call with the pool's own
/// reason, and holds nothing: ten refusals in a row do not
/// use up a budget of eight outstanding calls.
pub fn acquisition_failure_spawn_failed_refuses_and_holds_nothing_test() {
  let plane =
    planes.start(
      size: 1,
      spawn: fn() { Error(exec.PortOpenFailed) },
      clock: clock.fixed(at: 1000),
    )
  list.each(list.repeat(Nil, 10), fn(_attempt) {
    let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
    let events = process.new_subject()
    assert broker.clear_call(plane.broker, spec, events:, waiting: 1000)
      == Error(
        broker.NoHelper(error: exec.SpawnFailed(error: exec.PortOpenFailed)),
      )
    assert process.receive(events, 50) == Error(Nil)
  })
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// A full pool refuses with `AllBusy` once the caller's wait is spent, and
/// the refusal leaves the running execution untouched.
pub fn acquisition_failure_all_busy_refuses_and_holds_nothing_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 0)

  let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  let refused_events = process.new_subject()
  assert broker.clear_call(
      plane.broker,
      spec,
      events: refused_events,
      waiting: 1000,
    )
    == Error(broker.NoHelper(error: exec.AllBusy(size: 1)))
  assert process.receive(refused_events, 50) == Error(Nil)

  // The first execution never noticed.
  assert process.receive(events, 100) == Error(Nil)
  broker.cancel(plane.broker, handle)
  assert_cancelled_exit(story(events))
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

/// The service's checkout seam refused at once, as a pool whose `AllBusy`
/// is not going to clear would: the refusal is the pool's, and no row or
/// relay is left behind.
pub fn acquisition_refused_by_the_seam_leaves_no_row_test() {
  let plane =
    planes.start_intercepted(
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
      clock: clock.fixed(at: 1000),
      intercept: fn(_checkout) { Error(exec.AllBusy(size: 0)) },
    )
  let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  assert broker.clear_call(
      plane.broker,
      spec,
      events: process.new_subject(),
      waiting: 1000,
    )
    == Error(broker.NoHelper(error: exec.AllBusy(size: 0)))
  assert_baseline(plane, unconfirmed: 0)
  planes.stop(plane)
}

// --- the helper actor dies ------------------------------------------------------

/// The helper actor dies mid-run. The relay monitors it and settles the call
/// as lost at once, with no wall deadline needed to notice.
pub fn helper_actor_crash_mid_run_settles_lost_test() {
  let service = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(_handle, events) = call(service, 0)
  let assert Ok(helper) = process.receive(service.borrowed, 1000)
  process.kill(exec.pid(helper))
  assert story(events) == [lost(exec.HelperActorDown)]

  // A killed actor cannot say whether its jail is gone, so the pool keeps
  // the slot as unconfirmed rather than lend a helper it cannot vouch for.
  // That is the one case in the matrix meant to leave one.
  assert_baseline(service, unconfirmed: 1)
  planes.stop(service)
}

// --- shutdown during output ---------------------------------------------------

/// `close` while output is flowing, with a helper that honours cancel: the
/// caller sees its real exit, one settlement, and the close answers the
/// pool's verdict. The result is not mistaken for a retirement, so the
/// caller is never told `ExecutorClosing` for an execution that ended by
/// itself.
pub fn shutdown_during_output_delivers_the_real_exit_test() {
  let plane = plane(fake_helper.ChunksThenSleep(count: 20), size: 1)
  let #(_handle, events) = call(plane, 0)
  let assert Ok(broker.CallOutput(..)) = process.receive(events, 2000)
  let service = plane.service

  assert executor.close(service, draining: 2000, helpers: 2000) == Ok(Nil)
  let seen = story(events)
  let assert Ok(last) = list.last(seen)
  assert_cancelled_exit([last])
  broker.stop(plane.broker)
}

/// `close` while output is flowing, with a helper that ignores cancel: the
/// drain runs out and the caller is told `ExecutionLost(ExecutorClosing)`,
/// once, and never also an exit. The pool's own close still answers `Ok`:
/// it retires the helper the service gave up on.
pub fn shutdown_during_output_with_a_stubborn_helper_settles_lost_test() {
  let plane =
    planes.start_scripted(size: 1, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.IgnoreCancel,
        cancel_grace_ms: 60_000,
        heartbeat_interval_ms: 0,
      )
    })
  let #(_handle, events) = call(plane, 0)
  let service = plane.service

  assert executor.close(service, draining: 500, helpers: 2000) == Ok(Nil)
  assert story(events) == [lost(exec.ExecutorClosing)]
  broker.stop(plane.broker)
}

// A small process that lends the helpers it was given, one per ask, in
// order. The service asks from its own process, and a subject belongs to
// the process that made it, so the test's helpers travel through an agent
// both sides can call.
type Lend {
  Lend(reply: process.Subject(exec.Helper))
}

fn lender(helpers: List(exec.Helper)) -> process.Subject(Lend) {
  let handoff = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    lend_loop(inbox, helpers)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000) as "the lender started"
  inbox
}

fn lend_loop(inbox: process.Subject(Lend), helpers: List(exec.Helper)) -> Nil {
  let Lend(reply:) = process.receive_forever(inbox)
  case helpers {
    [helper, ..rest] -> {
      process.send(reply, helper)
      lend_loop(inbox, rest)
    }
    [] -> lend_loop(inbox, [])
  }
}

fn hand_dispatch(
  seq: Int,
  settlements: process.Subject(dispatch.Terminal),
) -> dispatch.Dispatch {
  dispatch.Dispatch(
    context: dispatch.CallContext(
      operation: planes.op(),
      step: "fixture",
      origin: None,
    ),
    request: exec.ExecRequest(
      argv: ["/bin/sleep", "30"],
      env: [],
      cwd: "/work",
      policy: None,
      token: <<0:size(32)-unit(8)>>,
      demand: exec.BestEffort,
    ),
    seq:,
    deadline_ms: 0,
    clock: clock.fixed(at: 1000),
    caller: None,
    deliver: fn(_chunk) { Nil },
    settle: fn(terminal) { process.send(settlements, terminal) },
  )
}

/// A result already granted its settlement is not turned into a loss by a
/// close that follows, even one that does expire another execution. The
/// test plays the broker: it never releases the first execution, whose
/// relay has reported its exit, so its row is still on the books when the
/// close finds a second, stubborn execution to expire. The first caller's
/// one settlement is the exit, the second's is `ExecutorClosing`, and the
/// pool answers the close.
pub fn close_after_the_result_was_granted_does_not_settle_it_lost_test() {
  let honest = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let stubborn =
    fake_helper.start_helper_configured(
      fake_helper.IgnoreCancel,
      cancel_grace_ms: 60_000,
      heartbeat_interval_ms: 0,
    )
  let lender = lender([honest, stubborn])
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() { Ok(process.call(lender, 1000, Lend)) },
      checkin: fn(_helper) { Nil },
      custody: fn() { Error(exec.PoolUnavailable) },
      close_helpers: fn(_ms) { Ok(Nil) },
      incarnation: 1,
      log: log.discard(),
    ))
  let first_settlements = process.new_subject()
  let second_settlements = process.new_subject()
  let dispatcher = executor.dispatcher(service)
  let assert Ok(first) = dispatcher.start(hand_dispatch(1, first_settlements))
  let assert Ok(_second) =
    dispatcher.start(hand_dispatch(2, second_settlements))

  first.cancel()
  let assert Ok(dispatch.Completed(result)) =
    process.receive(first_settlements, 2000)
  assert result.signal == 15

  assert executor.close(service, draining: 500, helpers: 1000) == Ok(Nil)
  assert process.receive(second_settlements, 500)
    == Ok(dispatch.Failed(exec.ExecutionLost(cause: exec.ExecutorClosing)))
  assert process.receive(second_settlements, 300) == Error(Nil)
  assert process.receive(first_settlements, 300) == Error(Nil)
}

// --- the service itself dies --------------------------------------------------

/// The service is killed mid-run. Each party's view, pinned:
///
/// - The relay, which does not depend on the service for what the helper
///   tells it, keeps watching. Its cancel and settlement questions are
///   answered by a dead process, so it asks nothing of anyone and acts on
///   what it knows. It knows nothing about the helper's fate beyond the
///   events it hears, and it hears none: nobody told the helper to stop.
/// - A broker cancel is a cast to the dead service and goes nowhere, so the
///   execution runs on and the caller hears nothing.
/// - The wall deadline is the relay's own. It cannot reach the helper
///   through the dead service, so after its grace the relay reports
///   `CancelEscalated`. That is a truthful verdict, not a completion: no
///   one ever claims the execution completed.
/// - The helper is never lent again. Nothing checks it in, so the pool
///   holds it borrowed, and the broker, whose dispatcher is the dead
///   service, refuses new calls as unavailable.
/// - `executor.close` on the dead service answers `RetirementOwnerGone`
///   and nothing else, and the pool's own close, which is what retires the
///   helper, answers for itself.
pub fn a_killed_service_does_not_report_completion_nor_lend_the_helper_test() {
  let plane =
    planes.start(
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.SleepUntilCancel)) },
      clock: clock.fixed(at: 1000),
    )
  let service = plane.service
  let events = process.new_subject()
  let spec = planes.spec(planes.op(), argv: ["/bin/echo"], deadline_ms: 1300)
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)

  // The service is a child of this test's process; custody unlinks it for
  // the same reason, so that killing it is a death and not an exit signal.
  process.unlink(executor.pid(service))
  process.kill(executor.pid(service))

  // A broker cancel goes nowhere.
  broker.cancel(plane.broker, handle)
  assert process.receive(events, 200) == Error(Nil)

  // The wall deadline fires 300 ms in and cannot reach the helper; the
  // relay's grace then reports the truth, five seconds later.
  assert planes.collect(events, within: 8000)
    == [broker.CallSettled(broker.CallFailed(exec.CancelEscalated))]
  assert process.receive(events, 300) == Error(Nil)

  // The helper is still held: borrowed, not lent again.
  let assert Ok(census) = exec.pool_census(plane.pool, waiting: 1000)
  assert census.borrowed == 1
  assert census.available == 0
  let refused_events = process.new_subject()
  let next = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  assert broker.clear_call(
      plane.broker,
      next,
      events: refused_events,
      waiting: 500,
    )
    == Error(broker.BrokerUnavailable)

  // The service cannot answer for the pool; the pool answers for itself.
  assert executor.close(service, draining: 100, helpers: 100)
    == Error(exec.RetirementOwnerGone)
  assert exec.close_pool(plane.pool, waiting: 3000) == Ok(Nil)
  broker.stop(plane.broker)
}
