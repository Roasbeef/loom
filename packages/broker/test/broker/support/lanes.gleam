//// A broker over a real pool of fake helpers, in either dispatch lane.
////
//// The direct lane and the service lane must behave alike from the
//// caller's side, so the tests that compare them need the two planes built
//// from the same parts: one pool of the same helpers, one broker, the same
//// clock. Only the dispatcher differs. This module builds each, and the
//// small amount of scaffolding every such test wants: a call spec, a
//// collector for a call's events, and a record of every helper the lane
//// borrowed.

import broker/broker.{type CallEvent}
import broker/budget
import broker/exec.{type Helper}
import broker/executor
import broker/policy
import broker/token
import core/clock.{type Clock}
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}

/// Which dispatcher carries cleared calls out.
pub type Lane {
  /// `broker/direct`: today's relay per call, no service.
  Direct

  /// `broker/executor`: the service, with a relay per call.
  Service
}

/// One lane's parts.
pub type Plane {
  Plane(
    lane: Lane,
    broker: broker.Broker,
    pool: exec.Pool,
    /// The service, in the service lane only.
    service: Option(executor.Executor),
    /// Every helper the lane borrowed from the pool, in order.
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

/// Builds a pool of `size` helpers made by `spawn` and a broker over it in
/// `lane`. The same pool seams feed both lanes, so a difference between
/// two planes is a difference between dispatchers.
pub fn start(
  lane: Lane,
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
) -> Plane {
  start_intercepted(lane, size:, spawn:, clock:, intercept: fn(checkout) {
    checkout()
  })
}

/// As `start`, with the checkout seam wrapped: `intercept` receives the
/// pool's own checkout and may delay it, refuse it or call it. It lets a
/// test block the service inside a `start`, or answer `AllBusy` at once,
/// without touching the pool.
pub fn start_intercepted(
  lane: Lane,
  size size: Int,
  spawn spawn: fn() -> Result(Helper, exec.SpawnError),
  clock clock: Clock,
  intercept intercept: fn(fn() -> Result(Helper, exec.CheckoutError)) ->
    Result(Helper, exec.CheckoutError),
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
  case lane {
    Direct -> {
      let assert Ok(started) =
        broker.start(broker.BrokerConfig(
          entropy: token.production_entropy(),
          clock:,
          checkout:,
          checkin:,
        ))
        as "the direct broker starts"
      Plane(lane:, broker: started, pool:, service: None, borrowed:)
    }
    Service -> {
      let assert Ok(service) =
        executor.start(executor.ExecutorConfig(
          checkout:,
          checkin:,
          census: fn() { exec.pool_census(pool, waiting: 1000) },
          close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
          incarnation: 1,
        ))
        as "the executor service starts"
      let assert Ok(started) =
        broker.start_dispatching(
          entropy: token.production_entropy(),
          clock:,
          dispatcher: executor.dispatcher(service),
        )
        as "the service broker starts"
      Plane(lane:, broker: started, pool:, service: Some(service), borrowed:)
    }
  }
}

/// A plane over fresh helpers of one script, with the clock fixed.
pub fn start_scripted(
  lane: Lane,
  size size: Int,
  script script: fn() -> Helper,
) -> Plane {
  start(lane, size:, spawn: fn() { Ok(script()) }, clock: clock.fixed(at: 1000))
}

/// Stops the broker and asks the pool to retire every helper.
pub fn stop(plane: Plane) -> Nil {
  broker.stop(plane.broker)
  exec.stop_pool(plane.pool)
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
