//// The executor service, driven through a real broker over a real pool of
//// fake helpers: ordering, exactly-once settlement, the ways a relay or a
//// helper can die, and closing with work in flight.
////
//// Tests that need to see inside the service use its snapshot, and the
//// two that must speak to it as its relay does build a `Dispatch` by hand
//// and call the dispatcher directly, because only the closures of an
//// `Execution` reach a row.

import broker/broker
import broker/census
import broker/dispatch
import broker/exec
import broker/executor
import broker/executor_view
import broker/relay
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

fn service_of(plane: planes.Plane) -> executor.Executor {
  plane.service
}

fn call(plane: planes.Plane, deadline_ms: Int) {
  let events = process.new_subject()
  let spec = planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms:)
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  #(handle, events)
}

fn wait_for_census(
  plane: planes.Plane,
  holds: fn(exec.PoolCensus) -> Bool,
) -> exec.PoolCensus {
  let assert poll.Answered(census) =
    poll.until(within: 4000, every: 10, attempt: fn() {
      case exec.pool_census(plane.pool, waiting: 1000) {
        Ok(census) ->
          case holds(census) {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
    as "the pool's census reached the expected shape"
  census
}

fn live_rows(plane: planes.Plane) -> List(executor_view.LiveView) {
  let assert Ok(books) = executor.snapshot(service_of(plane), waiting: 1000)
  books.live
}

fn lost(cause: exec.LossCause) -> broker.CallEvent {
  broker.CallSettled(broker.CallFailed(exec.ExecutionLost(cause:)))
}

// A dispatch built by hand, for tests that hold an execution's closures.
fn hand_dispatch(
  seq: Int,
  deliveries: process.Subject(dispatch.Chunk),
  settlements: process.Subject(dispatch.Terminal),
) -> dispatch.Dispatch {
  dispatch.Dispatch(
    context: dispatch.CallContext(operation: planes.op(), step: "fixture"),
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
    deliver: fn(chunk) { process.send(deliveries, chunk) },
    settle: fn(terminal) { process.send(settlements, terminal) },
  )
}

// --- the ordinary path ------------------------------------------------------

/// Output reaches the caller in the order the helper sent it, before the
/// one settlement, and nothing follows the settlement.
pub fn output_arrives_in_order_before_the_one_settlement_test() {
  let plane = plane(fake_helper.ManyChunks(count: 6), size: 1)
  let #(_handle, events) = call(plane, 100_000)
  let seen = planes.collect(events, within: 2000)
  let assert [
    broker.CallOutput(data: <<0>>, ..),
    broker.CallOutput(data: <<1>>, ..),
    broker.CallOutput(data: <<2>>, ..),
    broker.CallOutput(data: <<3>>, ..),
    broker.CallOutput(data: <<4>>, ..),
    broker.CallOutput(data: <<5>>, ..),
    broker.CallSettled(broker.CallExited(result)),
  ] = seen
  assert result.code == 0
  assert process.receive(events, 300) == Error(Nil)
  planes.stop(plane)
}

/// A broker cancel reaches the helper through the service, the execution
/// settles once, and the helper goes back to the pool idle.
pub fn cancel_settles_the_execution_and_returns_the_helper_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  assert process.receive(events, 200) == Error(Nil)
  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(events, within: 2000)
  assert result.signal == 15
  let census = wait_for_census(plane, fn(census) { census.borrowed == 0 })
  assert census.available == 1
  assert live_rows(plane) == []
  assert process.receive(events, 300) == Error(Nil)
  planes.stop(plane)
}

/// Stdin sent the moment `clear_call` returns reaches the payload: the
/// service sent the helper its `Run` before it replied, and sends the stdin
/// afterwards, as the same sender.
pub fn stdin_sent_straight_after_clear_call_reaches_the_payload_test() {
  let plane = plane(fake_helper.StdinEcho, size: 1)
  let #(handle, events) = call(plane, 100_000)
  broker.stdin(plane.broker, handle, data: <<"ab">>, eof: False)
  broker.stdin(plane.broker, handle, data: <<"cd">>, eof: True)
  let assert [
    broker.CallOutput(data: <<"abcd":utf8>>, ..),
    broker.CallSettled(broker.CallExited(_)),
  ] = planes.collect(events, within: 2000)
  planes.stop(plane)
}

/// The service's books show one row while the execution runs, naming the
/// broker's call id, and none once the broker has released it.
pub fn the_snapshot_shows_a_live_row_until_the_release_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 2)
  let #(handle, events) = call(plane, 100_000)
  let assert Ok(books) = executor.snapshot(service_of(plane), waiting: 1000)
  let assert [row] = books.live
  assert dispatch.seq(row.id) == 1
  assert dispatch.incarnation(row.id) == 1
  assert books.incarnation == 1
  let assert Ok(custody) = books.pool
  assert custody.census.borrowed == 1

  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(_)] = planes.collect(events, within: 2000)
  let _ = wait_for_census(plane, fn(census) { census.borrowed == 0 })
  assert live_rows(plane) == []
  planes.stop(plane)
}

/// The tool effect that asked for the call dies mid-execution. The relay
/// watches it, asks the service to cancel, and the helper comes back.
pub fn caller_death_cancels_the_execution_and_frees_the_helper_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let started = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let spec =
        planes.spec(
          planes.op(),
          argv: ["/bin/echo", "hi"],
          deadline_ms: 100_000,
        )
      let assert Ok(_handle) =
        broker.clear_call(plane.broker, spec, events:, waiting: 2000)
      process.send(started, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(started, 3000)
  let census = wait_for_census(plane, fn(census) { census.borrowed == 1 })
  assert census.available == 0

  process.kill(caller)
  let census = wait_for_census(plane, fn(census) { census.borrowed == 0 })
  assert census.available == 1
  planes.stop(plane)
}

// --- the relay's two deadlines -----------------------------------------------

fn stepping_plane(script: fn() -> exec.Helper) -> planes.Plane {
  planes.start(
    size: 1,
    spawn: fn() { Ok(script()) },
    // Authorization reads 1000, inside a deadline of 1100; every later read
    // is past it, so the relay's remaining wall time is nothing.
    clock: clock.stepping(from: 1000, by: 300),
  )
}

fn bounded_call(plane: planes.Plane) {
  let events = process.new_subject()
  let spec =
    planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 1100)
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  #(handle, events)
}

/// The wall deadline is the relay's `Streaming` state timeout. It asks the
/// service to cancel, and the execution settles through the helper's own
/// answer to the cancel.
pub fn the_wall_deadline_cancels_through_the_service_test() {
  let plane =
    stepping_plane(fn() {
      fake_helper.start_helper(fake_helper.SleepUntilCancel)
    })
  let #(_handle, events) = bounded_call(plane)
  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(events, within: 3000)
  assert result.signal == 15
  assert result.cancelled
  planes.stop(plane)
}

/// The drain grace is the relay's `Draining` state timeout. A helper that
/// ignores cancel, and whose own escalation is a minute away, leaves only
/// the relay's grace to end the execution, five seconds after it cancelled.
pub fn the_drain_grace_escalates_when_the_helper_never_answers_test() {
  let plane =
    stepping_plane(fn() {
      fake_helper.start_helper_configured(
        fake_helper.IgnoreCancel,
        cancel_grace_ms: 60_000,
        heartbeat_interval_ms: 0,
      )
    })
  let #(_handle, events) = bounded_call(plane)

  // Nothing settles inside the grace...
  assert process.receive(events, 4000) == Error(Nil)

  // ...and the verdict follows it.
  assert planes.collect(events, within: 2500)
    == [broker.CallSettled(broker.CallFailed(exec.CancelEscalated))]
  planes.stop(plane)
}

/// The relay's own cancel is asked of the service, and its grace starts
/// only once the service has sent it. Here the service is held inside a
/// second execution's `start` for three seconds, which spans the first
/// execution's wall deadline. The helper then takes three more seconds to
/// answer the cancel it finally hears. Measured from the moment the relay
/// decided to cancel, the helper answers after about 5.7 seconds, past the
/// five-second grace; measured from the cancel being sent, after three, well
/// inside it. A relay that started its grace on a cast would report
/// `CancelEscalated` for a helper that had never been told.
pub fn a_relays_own_cancel_starts_its_grace_when_the_cancel_is_sent_test() {
  let gate = planes.gate()
  let plane =
    planes.start_intercepted(
      size: 2,
      spawn: fn() {
        Ok(fake_helper.start_helper_configured(
          fake_helper.SlowCancel(delay_ms: 3000),
          cancel_grace_ms: 60_000,
          heartbeat_interval_ms: 0,
        ))
      },
      clock: clock.fixed(at: 1000),
      intercept: planes.through(gate),
    )

  // The first execution's wall deadline is 300 ms away on the fixed clock.
  let events = process.new_subject()
  let spec =
    planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 1300)
  let assert Ok(_handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)

  // A second start holds the service inside its checkout across it.
  planes.hold_next(gate, ms: 3000)
  process.spawn_unlinked(fn() {
    let spec =
      planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 0)
    let _ =
      broker.clear_call(
        plane.broker,
        spec,
        events: process.new_subject(),
        waiting: 10_000,
      )
    Nil
  })

  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(events, within: 9000)
  assert result.signal == 15
  assert result.cancelled
  planes.stop(plane)
}

// --- the ways a relay or a helper can die -----------------------------------

/// A relay killed outright settles its caller as lost, which the direct
/// lane never did, and the helper it was watching is never lent while it
/// still runs that execution: the next call runs to a clean end.
pub fn a_relay_crash_settles_lost_and_the_next_call_runs_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let assert Ok(_first) = process.receive(plane.borrowed, 1000)
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)

  process.kill(relay_pid)
  assert planes.collect(events, within: 2000) == [lost(exec.RelayDown)]
  assert process.receive(events, 300) == Error(Nil)

  // The service cancels the abandoned execution and returns the helper.
  // Which helper the second call gets depends on a race the test does not
  // control, and both outcomes are correct: if the helper has reported the
  // cancelled execution's exit by the time the pool probes it, it is idle
  // and fit to lend again; if not, it answers busy and the pool retires it
  // and spawns a fresh one. What must never happen is the second call
  // meeting a helper still running the first, which would settle it as
  // `HelperBusy` instead of running it to a cancellable end.
  let #(second_handle, second_events) = call(plane, 100_000)
  let assert Ok(_second) = process.receive(plane.borrowed, 1000)
  broker.cancel(plane.broker, second_handle)
  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(second_events, within: 2000)
  assert result.signal == 15
  planes.stop(plane)
}

// A helper actor killed mid-run settles the call as lost. The wall
// deadline is far away, or absent, so only the relay's monitor can do it.
fn assert_helper_death_settles_promptly(deadline_ms: Int) -> Nil {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(_handle, events) = call(plane, deadline_ms)
  let assert Ok(helper) = process.receive(plane.borrowed, 1000)

  process.kill(exec.pid(helper))
  assert planes.collect(events, within: 2000) == [lost(exec.HelperActorDown)]
  assert process.receive(events, 300) == Error(Nil)
  planes.stop(plane)
}

pub fn helper_actor_death_settles_as_lost_promptly_test() {
  assert_helper_death_settles_promptly(100_000)
}

pub fn helper_actor_death_settles_with_no_deadline_test() {
  assert_helper_death_settles_promptly(0)
}

// --- the row and the fence ---------------------------------------------------

/// Only the first ask for a live execution's settlement is granted, and a
/// relay that is refused stays silent. Here the test plays the relay's part
/// by asking first, so the real relay is the one refused and the caller
/// hears nothing: the settlement was granted away.
pub fn only_the_first_ask_to_settle_is_granted_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let service = service_of(plane)
  let assert [row] = live_rows(plane)

  assert executor.may_settle(service, row.id, waiting: 1000) == relay.Granted
  assert executor.may_settle(service, row.id, waiting: 1000)
    == relay.AlreadySettled

  // An identity the service never issued has no row to grant.
  let stranger = dispatch.execution_id(incarnation: 1, seq: 999)
  assert executor.may_settle(service, stranger, waiting: 1000)
    == relay.AlreadySettled

  // The real relay now asks, is refused, and does not settle.
  broker.cancel(plane.broker, handle)
  assert planes.collect(events, within: 600) == []
  planes.stop(plane)
}

/// A relay that was granted settlement and then died before it reported
/// leaves the caller with nothing, and the broker, which saw no `Settle`,
/// abandons the call. Abandonment proves the relay sent nothing, so the
/// service settles the caller as lost, once, and returns the helper. The
/// service's own notice of the relay's death, which cannot prove that, does
/// not settle: the settlement is the abandon's alone.
pub fn an_abandoned_granted_row_settles_the_caller_as_lost_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let service = service_of(plane)
  let assert [row] = live_rows(plane)
  assert executor.may_settle(service, row.id, waiting: 1000) == relay.Granted
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)

  process.kill(relay_pid)
  assert planes.collect(events, within: 2000) == [lost(exec.RelayDown)]
  let _ = wait_for_census(plane, fn(census) { census.borrowed == 0 })
  assert live_rows(plane) == []
  assert process.receive(events, 300) == Error(Nil)
  planes.stop(plane)
}

/// A start the service refused spends its call id: the broker never offers
/// a number twice. The orphan here is an execution the broker never held,
/// sitting at the number the broker's first call will use. That call is
/// refused (the service will not overwrite a live row), but the broker has
/// moved on, so the next call runs. Before the broker spent ids on refusal
/// it re-offered the same number for ever and every later call was
/// `BrokerUnavailable`, however long ago the orphan had ended.
pub fn an_orphaned_row_does_not_wedge_later_calls_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 2)
  let dispatcher = executor.dispatcher(service_of(plane))
  let deliveries = process.new_subject()
  let settlements = process.new_subject()
  let assert Ok(orphan) =
    dispatcher.start(hand_dispatch(1, deliveries, settlements))

  let spec = planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 0)
  let refused =
    broker.clear_call(
      plane.broker,
      spec,
      events: process.new_subject(),
      waiting: 2000,
    )
  assert refused == Error(broker.BrokerUnavailable)

  // The orphan ends; nothing will ever release it, since no broker held it.
  orphan.cancel()
  let assert Ok(dispatch.Completed(_)) = process.receive(settlements, 2000)

  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(events, within: 2000)
  assert result.signal == 15
  planes.stop(plane)
}

/// A cancel for an execution that has already ended must not reach the next
/// execution on the same helper. The first execution's closures are kept
/// and called after its release and after a second execution has started on
/// the same helper.
pub fn a_stale_cancel_does_not_reach_the_next_execution_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let dispatcher = executor.dispatcher(service_of(plane))
  let deliveries = process.new_subject()
  let settlements = process.new_subject()

  let assert Ok(first) =
    dispatcher.start(hand_dispatch(1, deliveries, settlements))
  first.cancel()
  let assert Ok(dispatch.Completed(_)) = process.receive(settlements, 2000)
  first.release()
  let _ = wait_for_census(plane, fn(census) { census.available == 1 })

  let assert Ok(second) =
    dispatcher.start(hand_dispatch(2, deliveries, settlements))
  first.cancel()
  first.cancel()
  assert process.receive(settlements, 400) == Error(Nil)

  second.cancel()
  let assert Ok(dispatch.Completed(result)) = process.receive(settlements, 2000)
  assert result.signal == 15
  planes.stop(plane)
}

/// A start whose sequence number is still in the table is refused and takes
/// no helper, so a late `start` the broker gave up on cannot overwrite a
/// live row.
pub fn a_taken_sequence_number_is_refused_without_a_helper_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 2)
  let dispatcher = executor.dispatcher(service_of(plane))
  let deliveries = process.new_subject()
  let settlements = process.new_subject()

  let assert Ok(_first) =
    dispatcher.start(hand_dispatch(1, deliveries, settlements))
  let assert Error(dispatch.NotStarted) =
    dispatcher.start(hand_dispatch(1, deliveries, settlements))
  let census = wait_for_census(plane, fn(census) { census.borrowed >= 1 })
  assert census.borrowed == 1
  assert list.length(live_rows(plane)) == 1
  planes.stop(plane)
}

// --- closing -----------------------------------------------------------------

/// Closing with an execution in flight cancels it, lets it settle through
/// its relay, and answers the pool's own verdict.
pub fn close_with_a_live_execution_settles_it_and_answers_the_pool_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(_handle, events) = call(plane, 100_000)

  assert executor.close(service_of(plane), draining: 2000, helpers: 1000)
    == Ok(Nil)
  let assert [broker.CallSettled(broker.CallExited(result))] =
    planes.collect(events, within: 1000)
  assert result.signal == 15
  assert process.receive(events, 300) == Error(Nil)
  broker.stop(plane.broker)
}

fn stubborn_plane() -> planes.Plane {
  // A helper that ignores cancel and whose own escalation is a minute away,
  // so only the service's closing deadline can end the execution.
  planes.start_scripted(size: 1, script: fn() {
    fake_helper.start_helper_configured(
      fake_helper.IgnoreCancel,
      cancel_grace_ms: 60_000,
      heartbeat_interval_ms: 0,
    )
  })
}

/// An execution that outlasts half the closing budget is settled as lost to
/// the closing, once, and its helper is retired by the pool's close.
pub fn close_settles_an_execution_that_will_not_end_as_lost_test() {
  let plane = stubborn_plane()
  let #(_handle, events) = call(plane, 0)

  let verdict = executor.close(service_of(plane), draining: 600, helpers: 1500)
  assert planes.collect(events, within: 1000) == [lost(exec.ExecutorClosing)]
  assert process.receive(events, 300) == Error(Nil)
  assert verdict == Ok(Nil)
  broker.stop(plane.broker)
}

/// While the service is closing it refuses new executions with
/// `PoolUnavailable`, which callers read as "stop polling".
pub fn start_during_closing_is_refused_as_pool_unavailable_test() {
  let plane = stubborn_plane()
  let #(_handle, events) = call(plane, 0)
  let verdicts = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      verdicts,
      executor.close(service_of(plane), draining: 800, helpers: 1500),
    )
  })

  // The closer cancelled the execution and now waits half its budget for
  // it, which a helper that ignores cancel will not oblige.
  process.sleep(200)
  let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  assert broker.clear_call(
      plane.broker,
      spec,
      events: process.new_subject(),
      waiting: 1000,
    )
    == Error(broker.NoHelper(error: exec.PoolUnavailable))

  assert process.receive(verdicts, 4000) == Ok(Ok(Nil))
  assert planes.collect(events, within: 1000) == [lost(exec.ExecutorClosing)]
  broker.stop(plane.broker)
}

// --- the close budget ----------------------------------------------------------

// A service over a stub pool whose `close_helpers` reports the budget it was
// handed. Lending always gives the same fake helper, which is enough for a
// test that needs one row and no pool.
fn budget_probe(
  helper: exec.Helper,
  seen: process.Subject(Int),
) -> executor.Executor {
  verdict_probe(helper, seen, Ok(Nil))
}

// As `budget_probe`, with the pool's verdict chosen.
fn verdict_probe(
  helper: exec.Helper,
  seen: process.Subject(Int),
  verdict: Result(Nil, exec.RetirementFailure),
) -> executor.Executor {
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() { Ok(helper) },
      checkin: fn(_helper) { Nil },
      custody: fn() { Error(exec.PoolUnavailable) },
      close_helpers: fn(ms) {
        process.send(seen, ms)
        verdict
      },
      incarnation: 1,
      log: log.discard(),
    ))
    as "the probe service starts"
  service
}

/// The pool is given the whole `helpers` budget however long the drain took.
/// A live execution that ignores cancel holds the drain for its full 600 ms,
/// and the pool is still handed exactly the 1 234 asked for; before the
/// budgets were separate it was handed what the drain had left of a single
/// total.
pub fn the_pool_gets_its_whole_budget_after_a_full_drain_test() {
  let helper =
    fake_helper.start_helper_configured(
      fake_helper.IgnoreCancel,
      cancel_grace_ms: 60_000,
      heartbeat_interval_ms: 0,
    )
  let seen = process.new_subject()
  let service = budget_probe(helper, seen)
  let deliveries = process.new_subject()
  let settlements = process.new_subject()
  let assert Ok(_execution) =
    executor.dispatcher(service).start(hand_dispatch(1, deliveries, settlements))

  assert executor.close(service, draining: 600, helpers: 1234) == Ok(Nil)
  assert process.receive(seen, 100) == Ok(1234)

  // The drain really was spent: the execution was settled as lost to it.
  assert process.receive(settlements, 100)
    == Ok(dispatch.Failed(exec.ExecutionLost(cause: exec.ExecutorClosing)))
}

/// With nothing live there is no drain, and the pool gets the same budget.
pub fn the_pool_gets_its_whole_budget_with_nothing_to_drain_test() {
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let seen = process.new_subject()
  let service = budget_probe(helper, seen)

  assert executor.close(service, draining: 600, helpers: 1234) == Ok(Nil)
  assert process.receive(seen, 100) == Ok(1234)
}

/// A second `close` answers the verdict the first one stored, whether it
/// arrives while the first is still draining or after it finished. The pool
/// here cannot show its helpers retired, so the service stays alive in
/// `Closed` holding that custody, and the pool is asked once.
pub fn a_second_close_answers_the_stored_verdict_test() {
  let helper =
    fake_helper.start_helper_configured(
      fake_helper.IgnoreCancel,
      cancel_grace_ms: 60_000,
      heartbeat_interval_ms: 0,
    )
  let seen = process.new_subject()
  let service = verdict_probe(helper, seen, Error(exec.RetirementPending))
  let deliveries = process.new_subject()
  let settlements = process.new_subject()
  let assert Ok(_execution) =
    executor.dispatcher(service).start(hand_dispatch(1, deliveries, settlements))

  // The second closer arrives while the first is draining, and is postponed
  // until the verdict exists.
  let verdicts = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(verdicts, executor.close(service, draining: 800, helpers: 500))
  })
  process.sleep(200)
  let during = executor.close(service, draining: 800, helpers: 500)
  let assert Ok(first) = process.receive(verdicts, 3000)
  assert first == Error(exec.RetirementPending)
  assert during == first

  // And one more, long after.
  assert executor.close(service, draining: 800, helpers: 500) == first
  assert process.receive(seen, 100) == Ok(500)
  assert process.receive(seen, 200) == Error(Nil)
}

/// The other half of the contract, pinned so nobody mistakes it for the
/// first: a clean close ends the service, so a second `close` finds no
/// process and answers `RetirementOwnerGone`, as `close_pool` does after a
/// clean `close_pool`. The session wiring never closes twice (the owned
/// path closes through custody and the ownerless path through
/// `close_instance`), so the two answers are never both given to one
/// session.
pub fn a_second_close_after_a_clean_close_finds_no_service_test() {
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let service = budget_probe(helper, process.new_subject())

  assert executor.close(service, draining: 100, helpers: 100) == Ok(Nil)
  assert executor.close(service, draining: 100, helpers: 100)
    == Error(exec.RetirementOwnerGone)
}

/// A census reads the features the pool heard at the handshake and borrows
/// no helper to do it: before any helper exists the features are unknown,
/// and asking spawns nothing.
pub fn the_census_reads_features_without_borrowing_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  let assert Ok(unknown) = executor.census(service_of(plane), waiting: 3000)
  assert unknown == census.local([])
  let assert Ok(before) = exec.pool_census(plane.pool, waiting: 1000)
  assert before.spawned == 0

  // One execution makes the pool spawn a helper, which says hello.
  let #(_handle, events) = call(plane, 5000)
  let assert [_, broker.CallSettled(_)] = planes.collect(events, within: 2000)
  let _ = wait_for_census(plane, fn(counts) { counts.borrowed == 0 })
  let assert Ok(spawned) = exec.pool_census(plane.pool, waiting: 1000)

  let assert Ok(known) = executor.census(service_of(plane), waiting: 3000)
  assert known
    == census.local(["rlimits", "pgroup", "bwrap", "landlock", "seccomp"])
  let assert Ok(after) = exec.pool_census(plane.pool, waiting: 1000)
  assert after.spawned == spawned.spawned
  assert after.borrowed == 0
  planes.stop(plane)
}

/// The census answers while the only slot is lent out, since it asks the
/// pool's books and never the pool's lending.
pub fn a_full_pool_still_reports_its_features_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = wait_for_census(plane, fn(counts) { counts.borrowed == 1 })
  let assert Ok(here) = executor.census(service_of(plane), waiting: 1000)
  assert here
    == census.local(["rlimits", "pgroup", "bwrap", "landlock", "seccomp"])

  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(_)] = planes.collect(events, within: 2000)
  planes.stop(plane)
}
