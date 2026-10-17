//// A broker over a real pool of fake helpers, carried out by the executor
//// service.
////
//// A test of the effect plane wants the same parts every time: one pool of
//// scripted helpers, the service over it, a broker whose dispatcher is that
//// service, and a clock. This module builds them, and the small amount of
//// scaffolding every such test wants: a call spec, a collector for a call's
//// events, and a record of every helper the service borrowed.
////
//// A plane is also what a property test must not leak. `qcheck` runs a
//// property once per generated value and again per shrink candidate, and a
//// failing run panics partway through, so a test that builds a plane inline
//// and stops it on the last line leaves one running for every failure. The
//// `isolated` function is the shape that cannot: the plane is built and
//// driven in a process of its own, and the caller stops it however that
//// process ended.
////
//// Shrinking has a second cost. These properties drive real processes and
//// wait on real deadlines, so a failing candidate can take seconds to fail,
//// and gleeunit gives a whole test fifty. A shrink that outruns that is
//// killed by the runner before `qcheck` prints what it found. A `Budget`
//// is the answer: it starts counting at the first failure, and once it has
//// run out `isolated` returns at once, which `qcheck` reads as a passing
//// candidate and so stops shrinking at the smallest failing value so far.

import broker/broker.{type CallEvent}
import broker/budget
import broker/exec.{type Helper}
import broker/executor
import broker/policy
import broker/support/bench_host as host
import broker/token
import core/clock.{type Clock}
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
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

/// Stops the broker and asks the pool to retire every helper.
pub fn stop(plane: Plane) -> Nil {
  broker.stop(plane.broker)
  exec.stop_pool(plane.pool)
}

// How an isolated run ended, as the caller that waits on it sees it.
type Ending {
  Finished
  Crashed(reason: process.ExitReason)
}

/// A wall-clock allowance for shrinking, shared by every run of one test.
pub opaque type Budget {
  Budget(cell: Subject(BudgetMsg))
}

type BudgetMsg {
  FirstFailure
  AskSpent(reply: Subject(Bool))
}

/// A budget that is spent `ms` milliseconds after the first run fails. It
/// lives in a process linked to the test, so it goes when the test does.
///
/// ## Examples
///
/// ```gleam
/// let budget = planes.shrink_budget(ms: 25_000)
/// ```
pub fn shrink_budget(ms ms: Int) -> Budget {
  let started = process.new_subject()
  process.spawn(fn() {
    let cell = process.new_subject()
    process.send(started, cell)
    budget_loop(cell, ms, None)
  })
  let assert Ok(cell) = process.receive(started, 1000)
    as "the budget process reports its subject"
  Budget(cell:)
}

// Waits for the first failure, then answers whether `ms` has passed since.
// The first failure is the one that counts: the failures after it are the
// shrink candidates the budget exists to bound.
fn budget_loop(cell: Subject(BudgetMsg), ms: Int, first: Option(Int)) -> Nil {
  case process.receive_forever(cell) {
    FirstFailure ->
      case first {
        None -> budget_loop(cell, ms, Some(host.now_us()))
        Some(_) -> budget_loop(cell, ms, first)
      }
    AskSpent(reply:) -> {
      process.send(reply, case first {
        None -> False
        Some(at) -> host.now_us() - at > ms * 1000
      })
      budget_loop(cell, ms, first)
    }
  }
}

fn spent(budget: Budget) -> Bool {
  process.call(budget.cell, 1000, AskSpent)
}

/// Runs `body` over a fresh plane in a process of its own and always stops
/// the plane afterwards, so a run that panics, which is how a failed
/// property reports itself, leaves nothing behind for the next shrink
/// candidate to trip over.
///
/// The plane is built inside the child because the `borrowed` subject, and
/// every subject the body makes, belongs to the process that made it. The
/// child hands the plane back as soon as it exists, and stays alive after
/// `body` returns until the caller has stopped the plane, so the pool is
/// never left to see its owner exit before it is asked to retire. A panic in
/// `body` is re-raised here with the child's exit reason, which carries the
/// assertion message, and a run that neither finishes nor crashes within
/// `within` milliseconds is a hang and also panics. Either failure starts the
/// `budget`; once it is spent the call does nothing, so the shrink that
/// follows a failure ends before the test runner's own timeout.
///
/// ## Examples
///
/// ```gleam
/// let budget = planes.shrink_budget(ms: 25_000)
/// planes.isolated(size: 3, script:, within: 30_000, budget:, body: fn(plane) {
///   assert exec.pool_census(plane.pool, waiting: 1000) |> result.is_ok
/// })
/// ```
pub fn isolated(
  size size: Int,
  script script: fn() -> Helper,
  within within: Int,
  budget budget: Budget,
  body body: fn(Plane) -> Nil,
) -> Nil {
  case spent(budget) {
    True -> Nil
    False -> run_isolated(size, script, within, budget, body)
  }
}

fn run_isolated(
  size: Int,
  script: fn() -> Helper,
  within: Int,
  budget: Budget,
  body: fn(Plane) -> Nil,
) -> Nil {
  let ready = process.new_subject()
  let finished = process.new_subject()
  let child =
    process.spawn_unlinked(fn() {
      let plane = start_scripted(size:, script:)
      process.send(ready, plane)
      body(plane)
      process.send(finished, Finished)
      process.sleep_forever()
    })
  let monitor = process.monitor(child)
  let ending =
    process.new_selector()
    |> process.select(finished)
    |> process.select_specific_monitor(monitor, fn(down) {
      case down {
        process.ProcessDown(reason:, ..) -> Crashed(reason:)
        process.PortDown(reason:, ..) -> Crashed(reason:)
      }
    })
    |> process.selector_receive(within:)

  // The child sent the plane before it ran anything, so a plane that
  // exists is already waiting here whichever way the run ended.
  case process.receive(ready, 0) {
    Ok(plane) -> stop(plane)
    Error(Nil) -> Nil
  }
  process.kill(child)
  case ending {
    Ok(Finished) -> Nil
    Ok(Crashed(reason:)) -> {
      process.send(budget.cell, FirstFailure)
      panic as { "the isolated run crashed: " <> string.inspect(reason) }
    }
    Error(Nil) -> {
      process.send(budget.cell, FirstFailure)
      panic as {
        "the isolated run neither finished nor crashed within "
        <> string.inspect(within)
        <> " ms"
      }
    }
  }
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
