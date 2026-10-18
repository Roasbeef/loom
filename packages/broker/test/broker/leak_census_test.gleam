//// A leak census for the executor service: a mix of up to a hundred
//// executions through one broker, and afterwards nothing is left that the
//// executions made.
////
//// The mix is a `statem` command list on a fixed seed, so the gate draws the
//// same endings on every machine. A command is the way one execution is made
//// to end; `execute` runs it to that ending through the plane and checks what
//// its caller heard; `finish` is the census proper. A failing mix is reported
//// already shrunk, by deleting endings from anywhere in the list and then
//// pulling each remaining one toward the execution that simply succeeds, so
//// what remains is the endings the leak needs. What the seed reproduces is
//// the mix and not the schedule, because the executions run on real
//// processes; the check retries each shrink candidate (`shrink_retries`) so
//// that a leak which shows on only some schedules is not shrunk away by one
//// clean run.
////
//// The system under test is the plane, built fresh for every execution of a
//// mix with one execution already run, so the helper and its fake exist
//// before the process count is read. `teardown` closes the service and stops
//// the plane on every path, so a mix that fails, and the shrink candidates
//// after it, leave nothing behind. The model counts the faults a mix has
//// made, which is what keeps a generated or shrunk mix inside the pool.
////
//// One property, because it is a sum. Each execution ends in one of five
//// ways (it succeeds, it is cancelled, its caller dies, its helper actor
//// crashes, it ignores cancel and is escalated), and each way has its own
//// bookkeeping to return: a budget slot, a token, a row, a relay, a borrowed
//// helper. A leak in any one of them shows as a residue after the hundredth,
//// which is far too late to show up in a test of a single execution and too
//// small to notice in a test of ten.
////
//// The census reads four things, each under its own violation tag. The pool
//// is back to baseline: nothing borrowed (`pool_borrowed`), and holding only
//// the slots of the helpers the run itself killed or lost, which the fake
//// can never show retired (`pool_slots`). The executor's inventory is empty
//// (`row_kept`). Every relay the run started is dead (`relay_alive`). And the
//// VM's process count is back within a tolerance of where it stood after the
//// first execution warmed the pool (`process_count`). Beside them, every
//// caller that was alive to hear its settlement heard exactly one, and
//// nothing after it (`settlements`, `alive_mute`, `trailing`), and every
//// call was cleared (`refused`).

import broker/broker
import broker/exec
import broker/executor
import broker/support/bench_host as host
import broker/support/fake_helper
import broker/support/planes
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import qcheck
import statem.{type Violation, Admit, Reject, Violation}
import weft/poll

// --- the commands -----------------------------------------------------------

// How an execution is made to end.
type Ending {
  Succeeds
  Cancelled
  CallerDies
  HelperCrashes
  Escalated
}

// How many faults the mix has made so far, which is the whole model: the
// precondition stops a mix making more than the pool can hold.
type Model {
  Model(faults: Int)
}

// The pool is sized above the most slots the faults can hold. A helper crash
// or an escalated execution leaves a slot the pool cannot show retired,
// because a fake helper cannot attest to a kill, so a mix is not admitted
// past `fault_cap` of them.
const fault_cap = 8

/// The census checks four mixes of up to a hundred endings. Half of a mix's
/// endings succeed, a fifth are cancelled, a fifth have their caller die, and
/// one in twenty each crashes its helper or ignores cancel until it is
/// escalated, up to `fault_cap` of the last two. The length is drawn rather
/// than fixed, so a failure can shrink to the few endings it needs and the
/// mixes range from empty to full.
const mix_count = 4

const mix_length = 100

const mix_seed = 3

/// How many times a shrink candidate is run before it is called passing, so
/// that a leak showing on only some schedules is not shrunk away by one
/// clean run.
const shrink_retries = 2

/// The most executions one shrink may spend, retries included. This is the
/// second bound: it ends the shrink early and reports the smallest mix found
/// so far.
const max_shrinks = 8

/// How long into the test shrinking may begin another candidate, in
/// milliseconds. gleeunit kills a test after fifty seconds. A failing
/// execution of a mix can wait out the pool balance poll (four seconds) and
/// the per-ending waits of `run_live` (up to eight seconds to collect one
/// ending's events), and a candidate runs `shrink_retries` times. The
/// deadline is read when the test starts and checked before each candidate,
/// so a candidate already running is not interrupted. Fifteen seconds leaves
/// thirty-five for the one candidate that may be running when the deadline
/// passes; one that waits out several bounds on both runs can still overrun
/// the kill.
const shrink_budget_ms = 15_000

/// The fewest endings the mixes may draw between them. The census this test
/// replaced ran two seeds of exactly a hundred endings each, and a length
/// drawn from `0..mix_length` can come out short, so `statem.commands` is
/// asserted to reach at least that many in total.
const ending_floor = 200

fn mix_config() -> statem.Config {
  statem.default_config(seed: mix_seed)
  |> statem.with_test_count(mix_count)
  |> statem.with_max_commands(mix_length)
  |> statem.with_max_shrinks(max_shrinks)
  |> statem.with_shrink_retries(shrink_retries)
}

fn spec() -> statem.Spec(Model, Ending, Sut) {
  statem.Spec(
    initial: Model(faults: 0),
    command: fn(_model) { ending_generator() },
    precondition:,
    next_model:,
    new_sut:,
    execute:,
    finish:,
    teardown:,
  )
}

// Each ending is drawn as an index that shrinks toward zero, the execution
// that succeeds.
fn ending_generator() -> qcheck.Generator(Ending) {
  qcheck.bounded_int(from: 0, to: 19)
  |> qcheck.map(fn(draw) {
    case draw {
      0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 -> Succeeds
      10 | 11 | 12 | 13 -> Cancelled
      14 | 15 | 16 | 17 -> CallerDies
      18 -> HelperCrashes
      _ -> Escalated
    }
  })
}

// A fault past the cap is not admitted. Deleting an earlier ending can only
// lower the count, so a shrink candidate that deletes one stays admissible.
fn precondition(model: Model, ending: Ending) -> statem.Admission {
  case ending, model.faults >= fault_cap {
    HelperCrashes, True | Escalated, True -> Reject
    HelperCrashes, False
    | Escalated, False
    | Succeeds, _
    | Cancelled, _
    | CallerDies, _
    -> Admit
  }
}

fn next_model(model: Model, ending: Ending) -> Model {
  case ending {
    HelperCrashes | Escalated -> Model(faults: model.faults + 1)
    Succeeds | Cancelled | CallerDies -> model
  }
}

fn argv_of(ending: Ending) -> List(String) {
  case ending {
    Succeeds -> ["ok"]
    Cancelled | CallerDies | HelperCrashes -> ["sleep"]
    Escalated -> ["stubborn"]
  }
}

// --- the system under test --------------------------------------------------

// The plane, the process count after the first execution warmed it, and what
// each execution left behind, newest first.
type Sut {
  Sut(plane: planes.Plane, processes_before: Int, results: List(Outcome))
}

// What one execution left behind for the census.
type Outcome {
  Outcome(ending: Ending, settlements: Int, relays: List(Pid))
}

fn new_sut() -> Sut {
  let plane =
    planes.start_scripted(size: 12, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })

  // One execution first, so the helper and its fake exist before the
  // process count is read. It is the plane's own warm-up, so a failure of it
  // is not a mix's: it crashes `new_sut`, which statem reports as a crash.
  let assert Ok(_) = run_one(plane, Succeeds) as "the warm-up execution ran"
  let #(_ports, processes_before, _bytes) = host.vm_counts()
  Sut(plane:, processes_before:, results: [])
}

// Dismantles the plane, whichever way the mix ended.
fn teardown(sut: Sut) -> Nil {
  planes.dismantle(sut.plane)
}

fn violation(tag: String, detail: String) -> Result(a, Violation) {
  Error(Violation(tag:, detail:))
}

// Runs one execution to its ending and checks what its caller heard.
fn execute(sut: Sut, _model: Model, ending: Ending) -> Result(Sut, Violation) {
  use outcome <- result.try(run_one(sut.plane, ending))
  use <- bool.guard(
    outcome.settlements > 1,
    violation("settlements", "a caller heard more than one settlement"),
  )
  use <- bool.guard(
    outcome.settlements == 0 && outcome.ending != CallerDies,
    violation("alive_mute", "a caller that was alive heard no settlement"),
  )
  Ok(Sut(..sut, results: [outcome, ..sut.results]))
}

// --- the census -------------------------------------------------------------

// The pool, the executor, the relays and the VM, read once the mix is over.
fn finish(sut: Sut, _model: Model) -> Result(Nil, Violation) {
  let plane = sut.plane
  let at = int.to_string(list.length(sut.results)) <> " endings: "
  let crashes =
    list.count(sut.results, fn(result) {
      result.ending == HelperCrashes || result.ending == Escalated
    })

  use _ <- result.try(check_pool(plane, crashes, at))
  use _ <- result.try(check_executor(plane, sut.results, at))
  check_vm(sut, at)
}

// The pool holds only what the crashes and escalations meant it to.
fn check_pool(
  plane: planes.Plane,
  crashes: Int,
  at: String,
) -> Result(Nil, Violation) {
  let balanced =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case exec.pool_census(plane.pool, waiting: 1000) {
        Ok(census) ->
          case census.borrowed == 0 {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
  case balanced {
    poll.Failed(_) | poll.Expired ->
      violation("pool_borrowed", at <> "the pool never balanced")

    // The fake cannot attest to a kill, so a helper the run killed stays a
    // slot the pool holds as draining (shutdown asked, exit not reported) or
    // unconfirmed (its actor died unobserved). Those are exactly the helpers
    // this run killed, and no slot is held by anything else.
    poll.Answered(census) -> {
      let held = census.draining + census.unconfirmed + census.retiring
      case held == crashes {
        True -> Ok(Nil)
        False ->
          violation(
            "pool_slots",
            at <> "the pool holds slots no killed helper accounts for",
          )
      }
    }
  }
}

// The executor holds no row, and no relay is alive.
fn check_executor(
  plane: planes.Plane,
  results: List(Outcome),
  at: String,
) -> Result(Nil, Violation) {
  use books <- result.try(
    executor.snapshot(plane.service, waiting: 1000)
    |> result.map_error(fn(_unreachable) {
      Violation(tag: "row_kept", detail: at <> "the executor did not answer")
    }),
  )
  use <- bool.guard(
    books.live != [],
    violation("row_kept", at <> "the executor kept a row"),
  )
  let alive =
    list.filter(list.flat_map(results, fn(r) { r.relays }), process.is_alive)
  case alive {
    [] -> Ok(Nil)
    [_, ..] -> violation("relay_alive", at <> "a relay outlived its execution")
  }
}

// The VM is where it was, give or take the helpers the pool replaced.
fn check_vm(sut: Sut, at: String) -> Result(Nil, Violation) {
  let #(_ports, processes_after, _bytes) = host.vm_counts()
  case int.absolute_value(processes_after - sut.processes_before) <= 20 {
    True -> Ok(Nil)
    False ->
      violation(
        "process_count",
        at
          <> "process count moved from "
          <> int.to_string(sut.processes_before)
          <> " to "
          <> int.to_string(processes_after),
      )
  }
}

/// Mixed executions, drawn four times over, leave the pool, the executor,
/// the relays and the VM as they were.
pub fn mixed_executions_leak_nothing_test() {
  let config =
    mix_config()
    |> statem.with_shrink_stop(planes.shrink_stop_after(
      within_ms: shrink_budget_ms,
    ))

  case statem.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

/// The mixes the census draws are together at least as many endings as the
/// two hundred it used to run, so a short draw cannot thin the census out.
pub fn the_mixes_draw_enough_endings_test() {
  let drawn =
    list.repeat(Nil, mix_count)
    |> list.index_map(fn(_, run) {
      list.length(statem.commands(spec(), mix_config(), run))
    })
  let total = int.sum(drawn)

  assert total >= ending_floor
}

// --- one execution ----------------------------------------------------------

// Runs one execution to its ending and counts what its caller heard.
fn run_one(plane: planes.Plane, ending: Ending) -> Result(Outcome, Violation) {
  case ending {
    CallerDies -> run_doomed(plane)
    Succeeds | Cancelled | HelperCrashes | Escalated -> run_live(plane, ending)
  }
}

fn run_live(plane: planes.Plane, ending: Ending) -> Result(Outcome, Violation) {
  let events = process.new_subject()
  let spec = planes.spec(planes.op(), argv: argv_of(ending), deadline_ms: 0)
  case broker.clear_call(plane.broker, spec, events:, waiting: 5000) {
    Error(refusal) -> violation("refused", string.inspect(refusal))
    Ok(handle) -> {
      let relay = broker.relay_pid(plane.broker, handle, waiting: 1000)
      case ending {
        Succeeds -> Nil
        Cancelled | Escalated -> broker.cancel(plane.broker, handle)
        HelperCrashes -> {
          process.kill(exec.pid(latest_borrowed(plane)))
        }
        CallerDies -> Nil
      }
      let seen = planes.collect(events, within: 8000)
      let settlements = count_settlements(seen)
      case process.receive(events, 20) {
        Ok(_) -> violation("trailing", "an event arrived after the settlement")
        Error(Nil) -> Ok(Outcome(ending:, settlements:, relays: pids(relay)))
      }
    }
  }
}

// A caller that dies after the call is running: it hears nothing, and the
// broker is left to put everything back.
fn run_doomed(plane: planes.Plane) -> Result(Outcome, Violation) {
  let reported: Subject(Result(Pid, Nil)) = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let spec =
        planes.spec(planes.op(), argv: argv_of(CallerDies), deadline_ms: 0)
      case broker.clear_call(plane.broker, spec, events:, waiting: 5000) {
        // A refused call reports nothing, which the receive below reads as a
        // call that was never cleared.
        Error(_refusal) -> Nil
        Ok(handle) -> {
          process.send(
            reported,
            broker.relay_pid(plane.broker, handle, waiting: 1000),
          )
          process.sleep_forever()
        }
      }
    })
  case process.receive(reported, 6000) {
    Ok(relay) -> {
      process.kill(caller)
      Ok(Outcome(ending: CallerDies, settlements: 0, relays: pids(relay)))
    }
    Error(Nil) -> {
      process.kill(caller)
      violation("refused", "a doomed call was never cleared")
    }
  }
}

// The helper the last checkout lent: every checkout is announced on the
// plane's `borrowed` subject, so the newest announcement is the one just
// made, and the older ones are read past.
fn latest_borrowed(plane: planes.Plane) -> exec.Helper {
  let assert Ok(first) = process.receive(plane.borrowed, 2000)
  newest(plane, first)
}

fn newest(plane: planes.Plane, so_far: exec.Helper) -> exec.Helper {
  case process.receive(plane.borrowed, 0) {
    Ok(later) -> newest(plane, later)
    Error(Nil) -> so_far
  }
}

fn pids(relay: Result(Pid, Nil)) -> List(Pid) {
  case relay {
    Ok(pid) -> [pid]
    Error(Nil) -> []
  }
}

fn count_settlements(seen: List(broker.CallEvent)) -> Int {
  list.count(seen, fn(event) {
    case event {
      broker.CallSettled(..) -> True
      broker.CallOutput(..) -> False
    }
  })
}
