//// What a caller sees of each way a call can end, pinned as a story.
////
//// The executor service sits behind the broker's dispatch seam, and a caller
//// only ever sees `CallEvent`s. This module runs one scenario per ending
//// through a broker over fake helpers in a pool and pins the caller's whole
//// story for each: the output events in order, the one settlement, and
//// silence after it. A change to what the service forwards, or to which
//// settlement an ending produces, is a failing line here.
////
//// Where the service is meant to be better than a bare relay (a helper
//// actor that dies mid-run settles as lost, a relay that dies settles its
//// caller) `executor_test` and `failure_matrix_test` own the story.

import broker/broker.{type CallEvent}
import broker/exec
import broker/support/fake_helper
import broker/support/planes
import core/clock
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

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
    story: List(String),
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
      [
        "output Stdout \"/bin/echo hi\\n\" total=13 truncated=False",
        "exited code=0 signal=0 cancelled=False timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "several chunks arrive in order",
      fake_helper.ManyChunks(count: 5),
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
      [
        "output Stdout \"\\u{0000}\" total=1 truncated=False",
        "output Stdout \"\\u{0001}\" total=2 truncated=False",
        "output Stdout \"\\u{0002}\" total=3 truncated=False",
        "output Stdout \"\\u{0003}\" total=4 truncated=False",
        "output Stdout \"\\u{0004}\" total=5 truncated=False",
        "exited code=0 signal=0 cancelled=False timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "a truncated chunk is reported as truncated",
      fake_helper.Truncating,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
      [
        "output Stdout \"trunc\" total=5 truncated=True",
        "exited code=0 signal=0 cancelled=False timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "a broker cancel settles the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      100_000,
      False,
      CancelAtOnce,
      [
        "exited code=0 signal=15 cancelled=True timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "an operation abort settles the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      100_000,
      False,
      AbortAtOnce,
      [
        "exited code=0 signal=15 cancelled=True timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "stdin reaches the payload",
      fake_helper.StdinEcho,
      exec.BestEffort,
      100_000,
      False,
      FeedStdin,
      [
        "output Stdout \"abcd\" total=4 truncated=False",
        "exited code=0 signal=0 cancelled=False timed_out=False degraded=False",
      ],
    ),
    Scenario(
      "a cancel the helper ignores escalates",
      fake_helper.IgnoreCancel,
      exec.BestEffort,
      100_000,
      False,
      CancelAtOnce,
      [
        "failed CancelEscalated",
      ],
    ),
    Scenario(
      "a degraded helper is refused in band",
      fake_helper.Degraded,
      exec.FullEnforcement,
      100_000,
      False,
      RunToCompletion,
      [
        "failed DegradedHelper([\"rlimits\", \"pgroup\", \"degraded\"])",
      ],
    ),
    Scenario(
      "a lying exit report is refused in band",
      fake_helper.LyingDegraded,
      exec.FullEnforcement,
      100_000,
      False,
      RunToCompletion,
      [
        "output Stdout \"/bin/echo hi\\n\" total=13 truncated=False",
        "failed DegradedExecution(ExecResult(0, 0, 13, 0, False, False, [\"rlimits\", \"pgroup\", \"skip:bwrap: not found\"], True, 3, False, False))",
      ],
    ),
    Scenario(
      "a busy refusal from the helper settles in band",
      fake_helper.AlwaysBusy,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
      [
        "failed RefusedByHelper(\"busy\", \"an execution is already running\")",
      ],
    ),
    Scenario(
      "a malformed frame closes the channel in band",
      fake_helper.MalformedOnExec,
      exec.BestEffort,
      100_000,
      False,
      RunToCompletion,
      [
        "failed ChannelFault(CorruptFrame(CorruptionReport(\"core/msgpack.decode\", \"0 bytes remaining\", \"a byte-aligned msgpack value\", \"end of input\")))",
      ],
    ),
    Scenario(
      "a wall deadline cancels the execution",
      fake_helper.SleepUntilCancel,
      exec.BestEffort,
      1100,
      True,
      RunToCompletion,
      [
        "exited code=0 signal=15 cancelled=True timed_out=False degraded=False",
      ],
    ),
  ]
}

// What a caller can see of one scenario: whether the call was cleared, and
// the events of the call up to its settlement.
type Observed {
  Observed(cleared: Result(Nil, broker.Refusal), events: List(String))
}

fn run(scenario: Scenario) -> Observed {
  let at = case scenario.stepping {
    True -> clock.stepping(from: 1000, by: 300)
    False -> clock.fixed(at: 1000)
  }
  let plane =
    planes.start(
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(scenario.script)) },
      clock: at,
    )
  let op_id = planes.op()
  let spec = planes.spec(op_id, argv: ["/bin/echo", "hi"], deadline_ms: 0)
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
      Observed(
        cleared: Ok(Nil),
        events: list.map(planes.collect(events, within: 3000), summary),
      )
    }
  }

  // Exactly one settlement: nothing follows the last event.
  assert process.receive(events, 200) == Error(Nil)
  planes.stop(plane)
  observed
}

fn broker_budget(deadline_ms: Int) {
  planes.spec(planes.op(), argv: [], deadline_ms:).budget
}

// One event as the fields a caller acts on, so a pinned line names what it
// asserts and does not carry a whole enforcement report.
fn summary(event: CallEvent) -> String {
  case event {
    broker.CallOutput(stream:, data:, total_bytes:, truncated:) ->
      "output "
      <> string.inspect(stream)
      <> " "
      <> string.inspect(data)
      <> " total="
      <> int.to_string(total_bytes)
      <> " truncated="
      <> string.inspect(truncated)
    broker.CallSettled(broker.CallExited(result)) ->
      "exited code="
      <> int.to_string(result.code)
      <> " signal="
      <> int.to_string(result.signal)
      <> " cancelled="
      <> string.inspect(result.cancelled)
      <> " timed_out="
      <> string.inspect(result.timed_out)
      <> " degraded="
      <> string.inspect(result.degraded)
    broker.CallSettled(broker.CallFailed(failure)) ->
      "failed " <> string.inspect(failure)
  }
}

/// Every scenario's story is the pinned one, and each of them settled, so
/// the pin is not a hang.
pub fn each_ending_shows_the_caller_its_pinned_story_test() {
  list.each(scenarios(), fn(scenario) {
    let observed = run(scenario)
    assert observed.cleared == Ok(Nil) as scenario.name
    assert observed.events == scenario.story as scenario.name
  })
}

/// A pool with no helper to lend refuses the call with the pool's own
/// reason, so the broker's congestion handling reads one answer.
pub fn an_empty_pool_refuses_the_call_test() {
  let plane =
    planes.start(
      size: 0,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
      clock: clock.fixed(at: 1000),
    )
  let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  let refused =
    broker.clear_call(
      plane.broker,
      spec,
      events: process.new_subject(),
      waiting: 500,
    )
  planes.stop(plane)
  assert refused == Error(broker.NoHelper(error: exec.AllBusy(size: 0)))
}
