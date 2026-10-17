//// A broker over a real pool of fake helpers, carried out by the executor
//// service.
////
//// A test of the effect plane wants the same parts every time: one pool of
//// scripted helpers, the service over it, a broker whose dispatcher is that
//// service, and a clock. This module builds them, and the small amount of
//// scaffolding every such test wants: a call spec, a collector for a call's
//// events, and a record of every helper the service borrowed.
////
//// A plane is also what a property test must not leak. A stateful property
//// builds one per execution of a command list and again per shrink candidate,
//// and a failing run stops partway through, so a test that builds a plane
//// inline and stops it on the last line leaves one running for every failure.
//// The shape that cannot is `statem`'s: `new_sut` builds the plane and
//// `teardown` calls `stop` on every path, a failed or crashed execution
//// included (`executor_property_test`, `leak_census_test`).

import broker/broker.{type CallEvent}
import broker/budget
import broker/exec.{type Helper}
import broker/executor
import broker/policy
import broker/support/bench_host
import broker/token
import core/clock.{type Clock}
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import statem
import telemetry/log.{type Logger}

/// One plane's parts.
pub type Plane {
  Plane(
    broker: broker.Broker,
    pool: exec.Pool,
    /// The service the broker dispatches through.
    service: executor.Executor,
    /// Every helper the service borrowed from the pool, in order.
    borrowed: Subject(Helper),
  )
}

/// An operation identity for a test.
pub fn op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 11)
  let #(op_id, _) = ids.mint_op(generator)
  op_id
}

/// A call of `argv` under a wall deadline of `deadline_ms` (0 for none).
pub fn spec(
  op_id: ids.OpId,
  argv argv: List(String),
  deadline_ms deadline_ms: Int,
) -> broker.CallSpec {
  broker.CallSpec(
    op_id:,
    step_id: "step-1",
    base_policy: policy.workspace_default("/work"),
    requirements: policy.workspace_default("/work"),
    grants: [],
    response: broker.RefuseNarrowed,
    demand: exec.BestEffort,
    argv:,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    budget: budget.Budget(max_outstanding: 8, deadline_ms:),
  )
}

/// Builds a pool of `size` helpers made by `spawn` and a broker over it,
/// dispatching through a service over that pool.
pub fn start(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
) -> Plane {
  start_intercepted(size:, spawn:, clock:, intercept: fn(checkout) {
    checkout()
  })
}

/// As `start`, with the checkout seam wrapped: `intercept` receives the
/// pool's own checkout and may delay it, refuse it or call it. It lets a
/// test block the service inside a `start`, or answer `AllBusy` at once,
/// without touching the pool.
pub fn start_intercepted(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
  intercept intercept: fn(fn() -> Result(Helper, exec.CheckoutError)) ->
    Result(Helper, exec.CheckoutError),
) -> Plane {
  start_with(
    size:,
    spawn:,
    clock:,
    intercept:,
    custody: fn(custody) { custody() },
    logger: log.discard(),
  )
}

/// As `start`, with the service's custody query wrapped: `intercept`
/// receives the pool's own query and may delay it, refuse it or call it. It
/// lets a test hold an observer inside the pool question, to show what that
/// wait does and does not delay.
pub fn start_custody_intercepted(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
  intercept intercept: fn(fn() -> Result(exec.PoolCustody, exec.CheckoutError)) ->
    Result(exec.PoolCustody, exec.CheckoutError),
) -> Plane {
  start_with(
    size:,
    spawn:,
    clock:,
    intercept: fn(checkout) { checkout() },
    custody: intercept,
    logger: log.discard(),
  )
}

/// As `start`, with the service writing its lines through `logger`.
pub fn start_logged(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
  logger logger: Logger,
) -> Plane {
  start_with(
    size:,
    spawn:,
    clock:,
    logger:,
    intercept: fn(checkout) { checkout() },
    custody: fn(custody) { custody() },
  )
}

fn start_with(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
  intercept intercept: fn(fn() -> Result(Helper, exec.CheckoutError)) ->
    Result(Helper, exec.CheckoutError),
  custody custody: fn(fn() -> Result(exec.PoolCustody, exec.CheckoutError)) ->
    Result(exec.PoolCustody, exec.CheckoutError),
  logger logger: Logger,
) -> Plane {
  let assert Ok(pool) = exec.start_pool(size:, spawn:)
    as "the pool of fake helpers starts"
  let borrowed = process.new_subject()
  let checkout = fn() {
    intercept(fn() {
      case exec.checkout(pool, waiting: 15_000) {
        Ok(helper) -> {
          process.send(borrowed, helper)
          Ok(helper)
        }
        Error(refusal) -> Error(refusal)
      }
    })
  }
  let checkin = fn(helper) { exec.checkin(pool, helper) }
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout:,
      checkin:,
      custody: fn() { custody(fn() { exec.pool_custody(pool, waiting: 1000) }) },
      close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
      incarnation: 1,
      log: logger,
    ))
    as "the executor service starts"
  let assert Ok(started) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock:,
      dispatcher: executor.dispatcher(service),
    )
    as "the service broker starts"
  Plane(broker: started, pool:, service:, borrowed:)
}

/// A plane over fresh helpers of one script, with the clock fixed.
pub fn start_scripted(size size: Int, script script: fn() -> Helper) -> Plane {
  start(size:, spawn: fn() { Ok(script()) }, clock: clock.fixed(at: 1000))
}

/// A `statem` shrink stop that says `StopShrinking` once `within_ms`
/// milliseconds of monotonic time have passed since this call.
///
/// A stateful property shrinks by running real processes, and one failing
/// candidate can wait out several poll deadlines, so shrinking by a count of
/// executions cannot promise to finish before gleeunit kills the test. Call
/// this when the test starts, so the deadline is the test's and not a
/// candidate's, and pass the result to `statem.with_shrink_stop`. It is read
/// between candidates, so a candidate already running is not interrupted and
/// the total can exceed `within_ms` by that candidate's own cost.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7)
/// |> statem.with_shrink_stop(planes.shrink_stop_after(within_ms: 30_000))
/// ```
pub fn shrink_stop_after(
  within_ms within_ms: Int,
) -> fn() -> statem.ShrinkStop {
  let deadline_us = bench_host.now_us() + within_ms * 1000

  fn() {
    case bench_host.now_us() >= deadline_us {
      True -> statem.StopShrinking
      False -> statem.KeepShrinking
    }
  }
}

/// Stops the broker and asks the pool to retire every helper.
pub fn stop(plane: Plane) -> Nil {
  broker.stop(plane.broker)
  exec.stop_pool(plane.pool)
}

/// Closes the service, stops the plane, and then reaps the pool.
///
/// `stop` only asks the pool to retire its helpers, and a pool holding a
/// helper a fake cannot attest to a kill of waits for its owner to exit
/// before it will. A property builds its plane in the test's own process,
/// which outlives every execution, so without this each faulty execution
/// would leave its pool, and the helpers linked to it, running until the
/// test ends. The pool is unlinked first so that killing it does not take
/// the test process with it.
///
/// ## Examples
///
/// ```gleam
/// planes.dismantle(plane)
/// ```
pub fn dismantle(plane: Plane) -> Nil {
  let _verdict = executor.close(plane.service, draining: 400, helpers: 800)
  stop(plane)
  let pool = exec.pool_pid(plane.pool)
  process.unlink(pool)
  process.kill(pool)
}

/// Reads a call's events up to and including its settlement, waiting up to
/// `within` milliseconds for each. A call that never settles ends the list
/// without a `CallSettled`, which is how a test sees a hang.
pub fn collect(
  events: Subject(CallEvent),
  within within: Int,
) -> List(CallEvent) {
  collect_loop(events, within, [])
}

fn collect_loop(
  events: Subject(CallEvent),
  within: Int,
  seen: List(CallEvent),
) -> List(CallEvent) {
  case process.receive(events, within) {
    Error(Nil) -> list.reverse(seen)
    Ok(broker.CallSettled(..) as settled) -> list.reverse([settled, ..seen])
    Ok(event) -> collect_loop(events, within, [event, ..seen])
  }
}

/// A hold that a test can place on the checkout seam from outside the
/// service. The service calls the seam from its own process, and a subject
/// belongs to the process that made it, so the test's instruction travels
/// through a small process of its own that both sides can ask.
pub opaque type Gate {
  Gate(subject: Subject(GateMsg))
}

type GateMsg {
  Hold(ms: Int)
  Take(reply: Subject(Int))
}

/// Makes a gate with no hold armed.
pub fn gate() -> Gate {
  let handoff = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    gate_loop(inbox, 0)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
    as "the gate process started"
  Gate(subject: inbox)
}

fn gate_loop(inbox: Subject(GateMsg), held: Int) -> Nil {
  case process.receive_forever(inbox) {
    Hold(ms:) -> gate_loop(inbox, ms)
    Take(reply:) -> {
      process.send(reply, held)
      gate_loop(inbox, 0)
    }
  }
}

/// Arms the gate: the next checkout that passes it sleeps `ms` first.
pub fn hold_next(gate: Gate, ms ms: Int) -> Nil {
  process.send(gate.subject, Hold(ms:))
}

/// A checkout interceptor for `start_intercepted` that passes through the
/// gate: it sleeps for an armed hold, once, then runs the real checkout.
pub fn through(
  gate: Gate,
) -> fn(fn() -> Result(Helper, exec.CheckoutError)) ->
  Result(Helper, exec.CheckoutError) {
  fn(checkout) {
    let held = process.call(gate.subject, 1000, Take)
    process.sleep(held)
    checkout()
  }
}
