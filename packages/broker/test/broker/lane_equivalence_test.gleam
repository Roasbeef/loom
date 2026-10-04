//// The two dispatch lanes must look the same from the caller's side.
////
//// `broker/direct` and `broker/executor` sit behind one seam, and the
//// seam is only the right one if nothing a caller can observe depends on
//// which is installed. This module is the cheapest disproof: it runs the
//// same scenarios through a broker in each lane, over identical fake
//// helpers in identical pools, and asserts that the caller sees the same
//// `CallEvent` sequence, normalising nothing.
////
//// What is deliberately not in the list is where the service lane is meant
//// to differ: a helper actor that dies mid-run settles as lost in the
//// service lane and, in the direct lane, only at a deadline that may not
//// exist; and a relay that dies settles its caller in the service lane and
//// not in the direct one. `executor_test` covers both, and an equivalence
//// assertion over them would be a statement that the old defects are
//// features.

import broker/broker.{type CallEvent}
import broker/exec
import broker/support/fake_helper
import broker/support/lanes.{type Lane}
import core/clock
import gleam/erlang/process
import gleam/list

// What the test does with a call once it is running.
type Drive {
  // Nothing: the helper finishes by itself.
  RunToCompletion

  // A broker cancel as soon as the call is running.
  CancelAtOnce

  // An operation abort as soon as the call is running.
  AbortAtOnce

  // Two stdin chunks, the second closing the stream, straight away.
  FeedStdin
}

type Scenario {
  Scenario(
    name: String,
    script: fake_helper.Script,
    demand: exec.EnforcementDemand,
    deadline_ms: Int,
    stepping: Bool,
    drive: Drive,
  )
}

fn scenarios() -> List(Scenario) {
  [
    Scenario(
      "an echo completes",
      fake_helper.EchoArgv,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "several chunks arrive in order",
      fake_helper.ManyChunks(count: 5),
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a truncated chunk is reported as truncated",
      fake_helper.Truncating,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a broker cancel settles the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      100_000,
      False,
      CancelAtOnce,
    ),
    Scenario(
      "an operation abort settles the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      100_000,
      False,
      AbortAtOnce,
    ),
    Scenario(
      "stdin reaches the payload",
      fake_helper.StdinEcho,
      exec.BestEffort,
      100_000,
      False,
      FeedStdin,
    ),
    Scenario(
      "a cancel the helper ignores escalates",
      fake_helper.IgnoreCancel,
      exec.BestEffort,
      100_000,
      False,
      CancelAtOnce,
    ),
    Scenario(
      "a degraded helper is refused in band",
      fake_helper.Degraded,
      exec.FullEnforcement,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a lying exit report is refused in band",
      fake_helper.LyingDegraded,
      exec.FullEnforcement,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a busy refusal from the helper settles in band",
      fake_helper.AlwaysBusy,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a malformed frame closes the channel in band",
      fake_helper.MalformedOnExec,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
    ),
    Scenario(
      "a wall deadline cancels the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      1100,
      True,
      RunToCompletion,
    ),
  ]
}

// What a caller can see of one scenario: whether the call was cleared, and
// the events of the call up to its settlement.
type Observed {
  Observed(cleared: Result(Nil, broker.Refusal), events: List(CallEvent))
}

fn run(lane: Lane, scenario: Scenario) -> Observed {
  let at = case scenario.stepping {
    True -> clock.stepping(from: 1000, by: 300)
    False -> clock.fixed(at: 1000)
  }
  let plane =
    lanes.start(
      lane,
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(scenario.script)) },
      clock: at,
    )
  let op_id = lanes.op()
  let spec = lanes.spec(op_id, argv: ["/bin/echo", "hi"], deadline_ms: 0)
  let spec =
    broker.CallSpec(
      ..spec,
      demand: scenario.demand,
      budget: broker_budget(scenario.deadline_ms),
    )
  let events = process.new_subject()
  let observed = case
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  {
    Error(refusal) -> Observed(cleared: Error(refusal), events: [])
    Ok(handle) -> {
      case scenario.drive {
        RunToCompletion -> Nil
        CancelAtOnce -> broker.cancel(plane.broker, handle)
        AbortAtOnce -> broker.abort(plane.broker, op_id)
        FeedStdin -> {
          broker.stdin(plane.broker, handle, data: <<"ab">>, eof: False)
          broker.stdin(plane.broker, handle, data: <<"cd">>, eof: True)
        }
      }
      Observed(cleared: Ok(Nil), events: lanes.collect(events, within: 3000))
    }
  }

  // Exactly one settlement, in either lane: nothing follows the last event.
  assert process.receive(events, 200) == Error(Nil)
  lanes.stop(plane)
  observed
}

fn broker_budget(deadline_ms: Int) {
  lanes.spec(lanes.op(), argv: [], deadline_ms:).budget
}

/// Every scenario produces the same events in both lanes, and each of them
/// settled, so the comparison is not two identical hangs.
pub fn both_lanes_show_the_caller_the_same_events_test() {
  list.each(scenarios(), fn(scenario) {
    let direct = run(lanes.Direct, scenario)
    let service = run(lanes.Service, scenario)
    assert direct == service as scenario.name
    assert list.any(direct.events, is_settlement) as scenario.name
  })
}

fn is_settlement(event: CallEvent) -> Bool {
  case event {
    broker.CallSettled(..) -> True
    broker.CallOutput(..) -> False
  }
}

/// A pool with no helper to lend refuses the same way in both lanes, so the
/// broker's congestion handling reads one answer.
pub fn both_lanes_refuse_an_empty_pool_alike_test() {
  let outcomes =
    list.map([lanes.Direct, lanes.Service], fn(lane) {
      let plane =
        lanes.start(
          lane,
          size: 0,
          spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
          clock: clock.fixed(at: 1000),
        )
      let spec = lanes.spec(lanes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
      let refused =
        broker.clear_call(
          plane.broker,
          spec,
          events: process.new_subject(),
          waiting: 500,
        )
      lanes.stop(plane)
      refused
    })
  let assert [direct, service] = outcomes
  assert direct == Error(broker.NoHelper(error: exec.AllBusy(size: 0)))
  assert service == direct
}
