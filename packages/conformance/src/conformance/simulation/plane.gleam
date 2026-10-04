//// The simulation's effect plane: a simulated session's tool calls run
//// through the real executor service, over fake helpers.
////
//// Until this module the runner scripted the tools and left the broker, the
//// executor and the helpers out of the loop, so no scheduled fault could ever
//// land while an execution was in flight. Now each simulated tool call starts
//// a real execution first. The tool surface (`surface.execute`) opens the
//// execution, applies the fault schedule while it is running, and only then
//// cancels it and returns the scripted result. A crash or a strand kill that
//// the schedule fires at that point reaps the tool's effect process with the
//// execution live, which is the interruption the executor's own tests could
//// only stage by hand: the relay must notice its caller is gone, cancel, and
//// settle, and the broker must give back the helper.
////
//// The scripted result is unchanged by any of it. The execution is a
//// witness, not an input, so convergence between the fault-free and the
//// faulted run still compares what the script said and nothing the plane did.
////
//// ## What the plane is held to
////
//// Two checks, run once a session's tree has been killed and its effects
//// have had a moment to unwind (`verify`):
////
//// - `effects/no-orphan`: no execution outlives its caller. The executor
////   holds no row, the pool has nothing borrowed, and every relay is dead.
//// - `effects/one-settlement`: every execution that was started settled
////   exactly once. A caller that stayed to hear its execution end heard one
////   settlement and nothing after it, and the service's own books agree:
////   what it started is what it completed, failed or lost.
////
//// ## Where the plane lives
////
//// The plane belongs to the process that runs the simulation, not to the
//// session's tree, because a tree kill must not take the broker or the
//// helpers with it: the point is to see what a kill leaves behind in them.
////
//// ## Flow
////
//// `start` → `begin` → `finish` → `verify` → `stop`
////
//// 1. `start` builds a pool of fake helpers, the executor over it and a
////    broker over the executor.
//// 2. `begin` clears one execution from the calling effect process, so that
////    the process's death cancels it.
//// 3. `finish` cancels the execution and waits for its one settlement.
//// 4. `verify` reads what the effects recorded in the ledger and what the
////    service and the pool say, and answers the violations.
//// 5. `stop` closes the service and the pool.

import broker/broker
import broker/budget
import broker/exec
import broker/executor
import broker/policy
import broker/token
import conformance/simulation/control.{type Control}
import conformance/simulation/fake_jail
import core/clock
import core/ids
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import telemetry/log
import weft/poll

// Helpers in the pool. A batch of simulated tools is two or three wide, and a
// faulted run can leave a few executions unwinding while the next starts, so
// a pool this size never refuses a clearance for lack of a helper.
const pool_size = 8

// How long a tool waits for its execution to be cleared.
const clearance_wait_ms = 2000

// How long a tool waits, after cancelling its execution, to hear it settle.
const settlement_wait_ms = 5000

// How long `verify` lets the effects of a killed tree unwind.
const unwind_ms = 2000

/// The plane: the broker the tools clear calls through, the service and pool
/// behind it, and the ledger the effects write to.
pub opaque type Plane {
  Plane(
    broker: broker.Broker,
    service: executor.Executor,
    pool: exec.Pool,
    op: ids.OpId,
    // Written by effect processes and read by `verify`, in the process that
    // started the plane, which is the subject's owner.
    ledger: Subject(Entry),
  )
}

// What an effect process writes down about its execution.
type Entry {

  // An execution was cleared.
  Started

  // A caller heard its execution's settlement.
  Heard

  // The relay of a cleared execution, to be seen dead at the end.
  Relay(pid: Pid)

  // Something an effect saw that a check will report.
  Fault(text: String)
}

/// An execution a tool started and has not yet ended.
pub type Execution {
  Execution(handle: broker.CallHandle, events: Subject(broker.CallEvent))
}

/// What `verify` found.
pub type Observation {
  Observation(
    /// Executions cleared over the run.
    executions: Int,
    /// One line per violated check, `check: detail`.
    violations: List(String),
  )
}

/// Starts a plane over fresh fake helpers. The caller owns it: the service
/// and the pool are linked to the calling process and end with it.
///
/// ## Examples
///
/// ```gleam
/// let plane = plane.start()
/// ```
///
pub fn start() -> Plane {
  let assert Ok(pool) =
    exec.start_pool(size: pool_size, spawn: fn() {
      Ok(fake_jail.start_helper())
    })
    as "the simulation's helper pool starts"
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: clearance_wait_ms) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
      incarnation: 1,
      log: log.discard(),
    ))
    as "the simulation's executor service starts"
  let assert Ok(started) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(at: 1_700_000_000_000),
      dispatcher: executor.dispatcher(service),
    )
    as "the simulation's broker starts"
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 17)
  let #(op, _generator) = ids.mint_op(generator)
  Plane(broker: started, service:, pool:, op:, ledger: process.new_subject())
}

// A call whose payload is held until cancelled, under the policy a tool run
// would get. Each call is its own step, so no call's budget is another's.
fn call_spec(op: ids.OpId, step: Int) -> broker.CallSpec {
  let base = policy.workspace_default("/work")
  broker.CallSpec(
    op_id: op,
    step_id: "call-" <> int.to_string(step),
    base_policy: base,
    requirements: base,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: exec.BestEffort,
    argv: ["hold"],
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    budget: budget.Budget(max_outstanding: 8, deadline_ms: 0),
  )
}

/// Starts one execution from the calling process, which is the tool's effect
/// process: the execution's events go to it, and its death is what cancels
/// the execution. `None` when the broker refused the call, which the plane
/// does not count against any check.
///
/// ## Examples
///
/// ```gleam
/// // let assert Some(execution) = plane.begin(plane, ctl)
/// ```
///
pub fn begin(plane: Plane, ctl: Control) -> Option(Execution) {
  let step = control.bump(ctl, "plane:call")
  let events = process.new_subject()
  case
    broker.clear_call(
      plane.broker,
      call_spec(plane.op, step),
      events:,
      waiting: clearance_wait_ms,
    )
  {
    Error(_refusal) -> {
      control.mark(ctl, "effect-plane-refused")
      None
    }
    Ok(handle) -> {
      process.send(plane.ledger, Started)
      case broker.relay_pid(plane.broker, handle, waiting: 1000) {
        Ok(pid) -> process.send(plane.ledger, Relay(pid:))
        Error(Nil) -> Nil
      }
      control.mark(ctl, "effect-plane-execution")
      Some(Execution(handle:, events:))
    }
  }
}

/// Cancels the execution and waits for its settlement, recording that the
/// caller heard exactly one, or what it heard instead.
///
/// ## Examples
///
/// ```gleam
/// // plane.finish(plane, execution)
/// ```
///
pub fn finish(plane: Plane, execution: Execution) -> Nil {
  broker.cancel(plane.broker, execution.handle)
  case hear_settlement(execution.events, settlement_wait_ms) {
    False ->
      process.send(
        plane.ledger,
        Fault(
          "effects/one-settlement: an execution had not settled "
          <> int.to_string(settlement_wait_ms)
          <> " ms after its cancel",
        ),
      )
    True -> {
      process.send(plane.ledger, Heard)
      case process.receive(execution.events, 30) {
        Ok(_event) ->
          process.send(
            plane.ledger,
            Fault(
              "effects/one-settlement: a caller heard an event after its"
              <> " execution's settlement",
            ),
          )
        Error(Nil) -> Nil
      }
    }
  }
}

// Reads events until the settlement, which is the last thing an execution
// sends. False when none arrives within `within` milliseconds.
fn hear_settlement(events: Subject(broker.CallEvent), within: Int) -> Bool {
  case process.receive(events, within) {
    Ok(broker.CallSettled(..)) -> True
    Ok(broker.CallOutput(..)) -> hear_settlement(events, within)
    Error(Nil) -> False
  }
}

/// Reads the ledger and the service's own books and answers the violations.
/// Call it after the session's tree is dead: the effects that tree was
/// running are then unwinding, and the plane is given a few seconds to show
/// that they did.
///
/// ## Examples
///
/// ```gleam
/// let observation = plane.verify(plane)
/// ```
///
pub fn verify(plane: Plane) -> Observation {
  let entries = drain(plane.ledger, [])
  let started = list.count(entries, fn(entry) { entry == Started })
  let heard = list.count(entries, fn(entry) { entry == Heard })
  let relays =
    list.filter_map(entries, fn(entry) {
      case entry {
        Relay(pid:) -> Ok(pid)
        Started | Heard | Fault(..) -> Error(Nil)
      }
    })
  let faults =
    list.filter_map(entries, fn(entry) {
      case entry {
        Fault(text:) -> Ok(text)
        Started | Heard | Relay(..) -> Error(Nil)
      }
    })
  let orphans = case await_unwound(plane, relays) {
    Ok(Nil) -> []
    Error(what) -> ["effects/no-orphan: " <> what]
  }
  let #(executions, settled) = case orphans {
    // An execution that is still unwinding has not settled, so the books
    // would only repeat the orphan under another name.
    [_, ..] -> #(started, [])
    [] -> books_disagree(plane, heard)
  }
  Observation(executions:, violations: list.flatten([orphans, settled, faults]))
}

fn drain(ledger: Subject(Entry), seen: List(Entry)) -> List(Entry) {
  case process.receive(ledger, 0) {
    Ok(entry) -> drain(ledger, [entry, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

// Waits for the killed tree's executions to unwind: the executor holds no
// row, nothing is borrowed from the pool, and every relay is dead. The
// answer names what was left when the wait ran out.
fn await_unwound(plane: Plane, relays: List(Pid)) -> Result(Nil, String) {
  let left = fn() {
    let rows = case executor.snapshot(plane.service, waiting: 1000) {
      Ok(books) -> list.length(books.live)
      Error(executor.Unreachable) -> 0
    }
    let borrowed = case exec.pool_census(plane.pool, waiting: 1000) {
      Ok(census) -> census.borrowed
      Error(_refusal) -> 0
    }
    let relays_alive = list.count(relays, process.is_alive)
    #(rows, borrowed, relays_alive)
  }
  case
    poll.until(within: unwind_ms, every: 10, attempt: fn() {
      case left() {
        #(0, 0, 0) -> poll.Done(Nil)
        _unwinding -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    _expired -> {
      let #(rows, borrowed, relays_alive) = left()
      Error(
        int.to_string(rows)
        <> " executor rows, "
        <> int.to_string(borrowed)
        <> " helpers borrowed and "
        <> int.to_string(relays_alive)
        <> " relays alive "
        <> int.to_string(unwind_ms)
        <> " ms after the tree was killed",
      )
    }
  }
}

// The service's books against what the callers heard: every execution it
// started is one it completed, failed or lost, and no more callers heard a
// settlement than there were executions. Also how many executions the service
// started, which is the figure to report: the ledger can miss an execution
// whose effect process was killed between its clearance and its ledger line,
// and the service cannot.
fn books_disagree(plane: Plane, heard: Int) -> #(Int, List(String)) {
  case executor.snapshot(plane.service, waiting: 1000) {
    Error(executor.Unreachable) -> #(heard, [])
    Ok(snapshot) -> {
      let metrics = snapshot.metrics
      let settled = metrics.completed + metrics.failed + metrics.lost
      let unsettled = case metrics.started == settled {
        True -> []
        False -> [
          "effects/one-settlement: the service started "
          <> int.to_string(metrics.started)
          <> " executions and settled "
          <> int.to_string(settled),
        ]
      }
      let overheard = case heard > metrics.started {
        True -> [
          "effects/one-settlement: "
          <> int.to_string(heard)
          <> " callers heard a settlement for "
          <> int.to_string(metrics.started)
          <> " executions",
        ]
        False -> []
      }
      #(metrics.started, list.append(unsettled, overheard))
    }
  }
}

/// Closes the service and the pool and stops the broker.
///
/// ## Examples
///
/// ```gleam
/// plane.stop(plane)
/// ```
///
pub fn stop(plane: Plane) -> Nil {
  broker.stop(plane.broker)
  let _verdict = executor.close(plane.service, draining: 200, helpers: 500)
  exec.stop_pool(plane.pool)
}
