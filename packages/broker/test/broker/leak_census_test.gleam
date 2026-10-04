//// A leak census for the executor service: a hundred mixed executions through
//// one broker, and afterwards nothing is left that the executions made.
////
//// The mix is drawn from a seed (`support/seeded`), so a failure prints the
//// seed that made it and the same hundred endings come back from it.
//// `LOOM_LEAK_CENSUS_SEEDS` sets how many seeds a run draws (default 2), and
//// `LOOM_LEAK_CENSUS_ONLY` replays one.
////
//// One test, because the property is a sum. Each execution ends in one of
//// five ways (it succeeds, it is cancelled, its caller dies, its helper
//// actor crashes, it ignores cancel and is escalated), and each way has its
//// own bookkeeping to return: a budget slot, a token, a row, a relay, a
//// borrowed helper. A leak in any one of them shows as a residue after the
//// hundredth, which is far too late to show up in a test of a single
//// execution and too small to notice in a test of ten.
////
//// The census reads four things. The pool is back to baseline: nothing
//// borrowed, and holding only the slots of the helpers the run itself
//// killed or lost, which the fake can never show retired. The
//// executor's inventory is empty. Every relay the run started is dead. And
//// the VM's process count is back within a tolerance of where it stood
//// after the first execution warmed the pool. Beside them, every caller
//// that was alive to hear its settlement heard exactly one.

import broker/broker
import broker/exec
import broker/executor
import broker/support/bench_host as host
import broker/support/fake_helper
import broker/support/planes
import broker/support/seeded
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result
import weft/poll

// How an execution is made to end.
type Ending {
  Succeeds
  Cancelled
  CallerDies
  HelperCrashes
  Escalated
}

// The pool is sized above the most slots the faults can hold. A helper crash
// or an escalated execution leaves a slot the pool cannot show retired,
// because a fake helper cannot attest to a kill, so the draw stops making
// them once it has made `fault_cap`.
const fault_cap = 8

// A hundred endings drawn from a seed: half succeed, a fifth are cancelled, a
// fifth have their caller die, and one in twenty each crashes its helper or
// ignores cancel until it is escalated, up to `fault_cap` of the last two.
fn endings(seed_value: Int) -> List(Ending) {
  let #(drawn, _seed) =
    seeded.repeat(seeded.new(seed_value), 100, fn(seed) {
      seeded.between(seed, 0, 19)
    })
  let #(endings, _faults) =
    list.fold(drawn, #([], 0), fn(state, draw) {
      let #(endings, faults) = state
      let ending = case draw {
        0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 -> Succeeds
        10 | 11 | 12 | 13 -> Cancelled
        14 | 15 | 16 | 17 -> CallerDies
        18 -> HelperCrashes
        _ -> Escalated
      }
      case ending, faults >= fault_cap {
        HelperCrashes, False | Escalated, False -> #(
          [ending, ..endings],
          faults + 1,
        )
        HelperCrashes, True | Escalated, True -> #(
          [Succeeds, ..endings],
          faults,
        )
        _, _ -> #([ending, ..endings], faults)
      }
    })
  list.reverse(endings)
}

fn argv_of(ending: Ending) -> List(String) {
  case ending {
    Succeeds -> ["ok"]
    Cancelled | CallerDies | HelperCrashes -> ["sleep"]
    Escalated -> ["stubborn"]
  }
}

/// A hundred mixed executions, drawn from each seed, leave the pool, the
/// executor, the relays and the VM as they were.
pub fn a_hundred_mixed_executions_leak_nothing_test() {
  list.each(seeds(), census_for)
}

// The seeds a run draws: `LOOM_LEAK_CENSUS_SEEDS` consecutive ones from 1, or
// the one `LOOM_LEAK_CENSUS_ONLY` names.
fn seeds() -> List(Int) {
  case host.getenv("LOOM_LEAK_CENSUS_ONLY") |> result.try(int.parse) {
    Ok(only) -> [only]
    Error(Nil) -> {
      let count =
        host.getenv("LOOM_LEAK_CENSUS_SEEDS")
        |> result.try(int.parse)
        |> result.unwrap(2)
      list.index_map(list.repeat(Nil, count), fn(_, offset) { offset + 1 })
    }
  }
}

fn census_for(seed_value: Int) -> Nil {
  let at = "seed " <> int.to_string(seed_value) <> ": "
  let plane =
    planes.start_scripted(size: 12, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })
  let service = plane.service

  // One execution first, so the helper and its fake exist before the
  // process count is read.
  let _ = run_one(plane, Succeeds)
  let #(_ports, processes_before, _bytes) = host.vm_counts()

  let results =
    list.map(endings(seed_value), fn(ending) { run_one(plane, ending) })
  assert list.length(results) == 100 as { at <> "a hundred executions ran" }

  // Every caller that could hear did, and heard once.
  assert list.all(results, fn(result) { result.settlements <= 1 })
    as { at <> "a caller heard more than one settlement" }
  let heard = list.filter(results, fn(result) { result.settlements == 1 })
  let mute = list.filter(results, fn(result) { result.settlements == 0 })
  assert list.all(mute, fn(result) { result.ending == CallerDies })
    as { at <> "a caller that was alive heard no settlement" }
  assert list.length(heard) + list.length(mute) == 100

  // The pool holds only what the crashes and escalations meant it to.
  let crashes =
    list.count(results, fn(result) {
      result.ending == HelperCrashes || result.ending == Escalated
    })
  let assert poll.Answered(census) =
    poll.until(within: 8000, every: 20, attempt: fn() {
      case exec.pool_census(plane.pool, waiting: 1000) {
        Ok(census) ->
          case census.borrowed == 0 {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
    as "the pool balanced"

  // The fake cannot attest to a kill, so a helper the run killed stays a
  // slot the pool holds as draining (shutdown asked, exit not reported) or
  // unconfirmed (its actor died unobserved). Those are exactly the helpers
  // this run killed, and no slot is held by anything else.
  assert census.draining + census.unconfirmed + census.retiring == crashes
    as { at <> "the pool holds slots no killed helper accounts for" }

  // The executor holds no row, and no relay is alive.
  let assert Ok(books) = executor.snapshot(service, waiting: 1000)
  assert books.live == [] as { at <> "the executor kept a row" }
  let alive =
    list.filter(list.flat_map(results, fn(r) { r.relays }), process.is_alive)
  assert alive == [] as { at <> "a relay outlived its execution" }

  // The VM is where it was, give or take the helpers the pool replaced.
  let #(_ports, processes_after, _bytes) = host.vm_counts()
  assert int.absolute_value(processes_after - processes_before) <= 20
    as {
      at
      <> "process count moved from "
      <> int.to_string(processes_before)
      <> " to "
      <> int.to_string(processes_after)
    }
  planes.stop(plane)
}

// What one execution left behind for the census.
type Outcome {
  Outcome(ending: Ending, settlements: Int, relays: List(Pid))
}

// Runs one execution to its ending and counts what its caller heard.
fn run_one(plane: planes.Plane, ending: Ending) -> Outcome {
  case ending {
    CallerDies -> run_doomed(plane)
    Succeeds | Cancelled | HelperCrashes | Escalated -> run_live(plane, ending)
  }
}

fn run_live(plane: planes.Plane, ending: Ending) -> Outcome {
  let events = process.new_subject()
  let spec = planes.spec(planes.op(), argv: argv_of(ending), deadline_ms: 0)
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 5000)
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
  assert process.receive(events, 20) == Error(Nil)
  Outcome(ending:, settlements:, relays: pids(relay))
}

// A caller that dies after the call is running: it hears nothing, and the
// broker is left to put everything back.
fn run_doomed(plane: planes.Plane) -> Outcome {
  let reported: Subject(Result(Pid, Nil)) = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let spec =
        planes.spec(planes.op(), argv: argv_of(CallerDies), deadline_ms: 0)
      let assert Ok(handle) =
        broker.clear_call(plane.broker, spec, events:, waiting: 5000)
      process.send(
        reported,
        broker.relay_pid(plane.broker, handle, waiting: 1000),
      )
      process.sleep_forever()
    })
  let assert Ok(relay) = process.receive(reported, 6000)
  process.kill(caller)
  Outcome(ending: CallerDies, settlements: 0, relays: pids(relay))
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
