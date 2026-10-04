//// A leak census for the service lane: a hundred mixed executions through
//// one broker, and afterwards nothing is left that the executions made.
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
import broker/support/lanes
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import weft/poll

// How an execution is made to end.
type Ending {
  Succeeds
  Cancelled
  CallerDies
  HelperCrashes
  Escalated
}

// A hundred executions in a fixed mixed order: ten blocks of ten. Blocks
// 0, 3, 6 and 9 hold an execution that ignores cancel and is escalated;
// blocks 1, 4 and 7 open with a helper crash instead of a success. Both
// leave the pool a slot it cannot show retired (the fake's helper cannot
// attest to a kill), so seven slots stay held and the pool is sized
// above that.
fn endings() -> List(Ending) {
  let base = [
    Succeeds,
    Succeeds,
    Cancelled,
    Succeeds,
    CallerDies,
    Succeeds,
    Succeeds,
    Cancelled,
    Succeeds,
    CallerDies,
  ]
  list.index_map(list.repeat(Nil, 10), fn(_, index) { index })
  |> list.map(fn(index) {
    case index % 3 {
      0 -> list.flatten([list.take(base, 5), [Escalated], list.drop(base, 6)])
      1 -> [HelperCrashes, ..list.drop(base, 1)]
      _ -> base
    }
  })
  |> list.flatten
}

fn argv_of(ending: Ending) -> List(String) {
  case ending {
    Succeeds -> ["ok"]
    Cancelled | CallerDies | HelperCrashes -> ["sleep"]
    Escalated -> ["stubborn"]
  }
}

/// A hundred mixed executions leave the pool, the executor, the relays and
/// the VM as they were.
pub fn a_hundred_mixed_executions_leak_nothing_test() {
  let plane =
    lanes.start_scripted(lanes.Service, size: 12, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })
  let assert Some(service) = plane.service

  // One execution first, so the helper and its fake exist before the
  // process count is read.
  let _ = run_one(plane, Succeeds)
  let #(_ports, processes_before, _bytes) = host.vm_counts()

  let results = list.map(endings(), fn(ending) { run_one(plane, ending) })
  assert list.length(results) == 100

  // Every caller that could hear did, and heard once.
  assert list.all(results, fn(result) { result.settlements <= 1 })
  let heard = list.filter(results, fn(result) { result.settlements == 1 })
  let mute = list.filter(results, fn(result) { result.settlements == 0 })
  assert list.all(mute, fn(result) { result.ending == CallerDies })
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

  // The executor holds no row, and no relay is alive.
  let assert Ok(books) = executor.inventory(service, waiting: 1000)
  assert books.live == []
  let alive =
    list.filter(list.flat_map(results, fn(r) { r.relays }), process.is_alive)
  assert alive == []

  // The VM is where it was, give or take the helpers the pool replaced.
  let #(_ports, processes_after, _bytes) = host.vm_counts()
  assert int.absolute_value(processes_after - processes_before) <= 20
    as {
      "process count moved from "
      <> int.to_string(processes_before)
      <> " to "
      <> int.to_string(processes_after)
    }
  lanes.stop(plane)
}

// What one execution left behind for the census.
type Outcome {
  Outcome(ending: Ending, settlements: Int, relays: List(Pid))
}

// Runs one execution to its ending and counts what its caller heard.
fn run_one(plane: lanes.Plane, ending: Ending) -> Outcome {
  case ending {
    CallerDies -> run_doomed(plane)
    Succeeds | Cancelled | HelperCrashes | Escalated -> run_live(plane, ending)
  }
}

fn run_live(plane: lanes.Plane, ending: Ending) -> Outcome {
  let events = process.new_subject()
  let spec = lanes.spec(lanes.op(), argv: argv_of(ending), deadline_ms: 0)
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
  let seen = lanes.collect(events, within: 8000)
  let settlements = count_settlements(seen)
  assert process.receive(events, 20) == Error(Nil)
  Outcome(ending:, settlements:, relays: pids(relay))
}

// A caller that dies after the call is running: it hears nothing, and the
// broker is left to put everything back.
fn run_doomed(plane: lanes.Plane) -> Outcome {
  let reported: Subject(Result(Pid, Nil)) = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let spec =
        lanes.spec(lanes.op(), argv: argv_of(CallerDies), deadline_ms: 0)
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
fn latest_borrowed(plane: lanes.Plane) -> exec.Helper {
  let assert Ok(first) = process.receive(plane.borrowed, 2000)
  newest(plane, first)
}

fn newest(plane: lanes.Plane, so_far: exec.Helper) -> exec.Helper {
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
