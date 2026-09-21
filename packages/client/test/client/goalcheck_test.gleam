//// The goal check's runner, against a scripted broker seam.
////
//// The seam `client/goalcheck` clears through is one closure, so a test can
//// hand it a fake that streams the events a real helper would and settles
//// the way a real one does. That is enough to pin the three things the
//// runner decides and the advisor cannot: what a settlement becomes, what a
//// refusal becomes, and how much of a chatty command's output survives.
////
//// What is deliberately not tested here is the jail. Whether the composed
//// policy admits is `packages/broker`'s own coverage and the tool plane's
//// integration fixture; this module's claim is narrower — the call it asks
//// for is the `bash` tool's, under the session's own base policy, with the
//// wall and the output ceiling it states.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/goalcheck
import client/goalstate
import core/clock
import core/ids.{type OpId}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import tools/tool

const workspace = "/tmp/goal-check-fixture"

fn an_op() -> OpId {
  let #(id, _later) = ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 3))
  id
}

// A settlement with nothing unusual about it: ran to its own exit, whole
// output, no wall.
fn exited(code: Int) -> broker.CallOutcome {
  broker.CallExited(result: exec.ExecResult(
    code:,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 12,
    timed_out: False,
    cancelled: False,
  ))
}

// The same settlement as the wall's: the helper stopped the run rather than
// the run ending of its own accord.
fn walled() -> broker.CallOutcome {
  let assert broker.CallExited(result:) = exited(143)
    as "the fixture settlement is an exit"

  broker.CallExited(
    result: exec.ExecResult(..result, timed_out: True, cancelled: True),
  )
}

// A runner whose broker seam streams `chunks` and then settles with
// `outcome`, and which records the spec it was asked to clear.
//
// The events are sent from the collecting process itself, before the
// collector runs: a subject's mailbox is the process's own, so a message
// sent to it earlier in the same function is waiting when the receive
// starts. That keeps the fixture free of a second process and of any
// ordering to get wrong.
fn scripted(
  chunks: List(#(framing.OutputStream, String)),
  outcome: broker.CallOutcome,
  seen: Subject(broker.CallSpec),
) -> goalcheck.Runner {
  goalcheck.Runner(
    clear_call: fn(spec, events) {
      process.send(seen, spec)

      list.each(chunks, fn(chunk) {
        process.send(
          events,
          broker.CallOutput(
            stream: chunk.0,
            data: bit_array.from_string(chunk.1),
            total_bytes: string.byte_size(chunk.1),
            truncated: False,
          ),
        )
      })
      process.send(events, broker.CallSettled(outcome:))

      Ok(tool.RunningCall(stdin: fn(_data, _eof) { Nil }, cancel: fn() { Nil }))
    },
    base_policy: policy.workspace_default(workspace),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    workspace:,
    clock: clock.fixed(at: 1000),
    op_id: an_op(),
    clearance_ms: 1000,
  )
}

// A runner whose first few clearances are refused the way the broker refuses a
// check whose predecessor is still draining, and whose next one clears and
// exits `code`.
//
// The countdown is a mailbox rather than a counter in a process of its own:
// `wiring.run` is called on the test's own process here, so a token sent before
// the run is waiting when the clearance asks for it, and a zero-millisecond
// receive is the whole of the state machine. Every attempt records its spec, so
// a test can say how many times the runner asked.
fn draining(
  refusals: Int,
  code: Int,
  seen: Subject(broker.CallSpec),
) -> goalcheck.Runner {
  let admitting = scripted([], exited(code), seen)
  let slot = process.new_subject()
  list.each(list.repeat(Nil, refusals), fn(_taken) { process.send(slot, Nil) })

  goalcheck.Runner(..admitting, clear_call: fn(spec, events) {
    case process.receive(slot, within: 0) {
      // The slot is still held by the execution the advisor cancelled.
      Ok(Nil) -> {
        process.send(seen, spec)

        Error(
          broker.BudgetRefused(refusal: budget.OutstandingCapReached(cap: 1)),
        )
      }

      Error(Nil) -> admitting.clear_call(spec, events)
    }
  })
}

// A runner nothing clears through. The spec is still recorded, so a test can
// say how many times the runner asked before it gave up.
fn refusing(seen: Subject(broker.CallSpec)) -> goalcheck.Runner {
  goalcheck.Runner(
    ..scripted([], exited(0), seen),
    clear_call: fn(spec, _events) {
      process.send(seen, spec)

      Error(broker.BrokerUnavailable)
    },
  )
}

fn run(runner: goalcheck.Runner, command: String) -> goalstate.CheckResult {
  let wiring = goalcheck.wiring(runner, timeout_ms: 5000)
  wiring.run(command)
}

// A command that exits zero is a passing check, and both streams are carried
// labelled so a reviewer knows which one said what.
pub fn a_passing_check_reports_its_status_and_output_test() {
  let seen = process.new_subject()
  let result =
    run(
      scripted(
        [#(framing.Stdout, "ok\n"), #(framing.Stderr, "a warning\n")],
        exited(0),
        seen,
      ),
      "make check",
    )

  assert result.command == "make check"
  assert result.ending == goalstate.Exited(status: 0)
  assert result.output == "stdout:\nok\n\nstderr:\na warning\n"
  assert result.ran_at_ms == 1000
}

// A non-zero exit is carried verbatim: whether it means the objective is
// unachieved is the reviewer's judgement, so the runner reports the number
// and nothing else.
pub fn a_failing_check_carries_its_exit_status_test() {
  let seen = process.new_subject()
  let result =
    run(scripted([#(framing.Stdout, "FAIL")], exited(2), seen), "make check")

  assert result.ending == goalstate.Exited(status: 2)
  assert result.output == "stdout:\nFAIL"
}

// A command with nothing to say produces an empty tail rather than a line
// saying so; the frame is where that is worded.
pub fn a_silent_check_carries_no_output_test() {
  let seen = process.new_subject()
  let result = run(scripted([], exited(0), seen), "true")

  assert result.output == ""
}

// A run the wall stopped produced no status, and the runner says so rather
// than reporting the code the helper happened to relay: 143 is a byte three
// different causes share, and a reviewer shown it as an exit status would
// weigh the command's verdict on work the command never finished judging.
//
// The output is still carried, unlike a timed-out hook's: a hook's text is
// parsed for a decision, and a check's is evidence a reviewer weighs — the
// tail of a build killed at its wall is exactly what says why.
pub fn a_walled_check_reports_no_status_test() {
  let seen = process.new_subject()
  let result =
    run(scripted([#(framing.Stdout, "still linking")], walled(), seen), "make")

  let assert goalstate.DidNotFinish(reason:) = result.ending
    as "a walled run reports no exit status"
  assert string.contains(reason, "wall")
  assert result.output == "stdout:\nstill linking"
}

// A refusal before any process existed is reported in the broker's own
// words, taken from the rendering the tool plane already owns: an operator
// who has seen a `bash` call refused reads the same sentence here.
pub fn a_refused_check_carries_the_brokers_words_test() {
  let seen = process.new_subject()
  let result = run(refusing(seen), "make check")

  let assert goalstate.DidNotFinish(reason:) = result.ending
    as "a refused clearance produces no exit status"
  assert string.contains(reason, "broker is unavailable")
  assert result.output == ""
}

// The slot an abandoned check is still giving back is waited out, not reported.
//
// This is the flake the goal e2e fixture kept hitting on Linux. The step's
// ledger admits one check at a time; the advisor cancels an abandoned check and
// starts its replacement at once; and the cancelled execution's slot comes back
// only when the broker relay has drained it to the helper's terminal event. The
// replacement's clearance therefore lands inside that drain, and reporting the
// refusal showed the reviewer "no exit status" for a command that ran perfectly
// well a few milliseconds later — evidence about the harness's scheduling, read
// as evidence about the work.
pub fn a_slot_still_draining_is_waited_out_test() {
  let seen = process.new_subject()
  let result = run(draining(3, 1, seen), "make check")

  assert result.ending == goalstate.Exited(status: 1)
    as "the check reports the command's own status, not the refusal"

  // The runner asked four times: three refusals and the clearance. Counting
  // them is what says the wait happened here rather than the refusal having
  // been relabelled.
  assert list.length(attempts(seen)) == 4
}

// A slot that never comes free still ends the check, and in the runner's own
// words rather than the broker's.
//
// The bound is what keeps the loop's no-stall property true: the result lands,
// the phase moves to `ReadyToFeed`, and the feed goes out saying the harness has
// no evidence. The sentence is the runner's because it is a claim about the
// wait — the harness asked repeatedly for a slot and never got one — which the
// cap refusal's wording would not tell an operator.
pub fn a_slot_that_never_comes_free_is_reported_as_unfinished_test() {
  let seen = process.new_subject()
  let result = run(draining(1_000_000, 0, seen), "make check")

  assert result.ending
    == goalstate.DidNotFinish(reason: goalcheck.slot_never_came_free)
  assert result.output == ""

  // More than one attempt, so the wait was spent rather than skipped, and the
  // count is not pinned: how many attempts fit inside the wait is the
  // scheduler's business.
  assert list.length(attempts(seen)) > 1
}

// A refusal more time cannot change is reported at once. Waiting out a narrowed
// policy or an aborted operation would spend the check's whole wall re-asking a
// question already answered, and the feed the operator is waiting for would be
// that much later for nothing.
pub fn a_decided_refusal_is_not_waited_out_test() {
  let seen = process.new_subject()
  let result = run(refusing(seen), "make check")

  let assert goalstate.DidNotFinish(reason:) = result.ending
    as "a refused clearance produces no exit status"
  assert string.contains(reason, "broker is unavailable")
  assert list.length(attempts(seen)) == 1
}

// Every spec the runner asked to clear, drained from the recording subject.
fn attempts(seen: Subject(broker.CallSpec)) -> List(broker.CallSpec) {
  case process.receive(seen, within: 0) {
    Error(Nil) -> []
    Ok(spec) -> [spec, ..attempts(seen)]
  }
}

// A chatty command is clipped to its tail, because the end of a build log is
// where the failure is. The marker is what tells the reviewer it is reading a
// tail rather than the whole run.
pub fn an_oversized_output_is_clipped_to_its_tail_test() {
  let seen = process.new_subject()
  let flood =
    string.repeat("x", goalcheck.output_tail_chars * 2) <> "the last line"
  let result =
    run(scripted([#(framing.Stdout, flood)], exited(1), seen), "make check")

  assert string.contains(result.output, "the last line")
  assert string.contains(result.output, "(earlier output omitted)")
  assert string.length(result.output) < goalcheck.output_tail_chars + 100
}

// The call the runner asks for is the `bash` tool's, under the session's own
// base policy, with the wall mirroring the deadline the loop is waiting on
// and the output ceiling the collector applies. The env allowlist is derived
// from the environment rather than stated twice, so the names the process
// runs with and the names the policy was asked for are one value.
pub fn the_cleared_call_is_the_bash_tools_own_test() {
  let seen = process.new_subject()
  let _result = run(scripted([], exited(0), seen), "make check")

  let assert Ok(spec) = process.receive(seen, within: 1000)
    as "the runner must clear exactly one call"

  assert spec.argv == ["bash", "-o", "pipefail", "-c", "make check"]
  assert spec.cwd == workspace
  assert spec.step_id == goalcheck.step_id
  assert spec.response == broker.RefuseNarrowed
  assert spec.grants == []
  assert spec.requirements.limits.wall_s == 5
  assert spec.requirements.limits.output_bytes == goalcheck.output_bytes
  assert spec.requirements.env_allow == ["PATH"]
  assert spec.base_policy == policy.workspace_default(workspace)
  assert spec.budget.deadline_ms == 6000
}
