//// The tool surface's recovery slot: what the driver does with an orphaned
//// call when `ToolSurface.recover` can say what became of it.
////
//// Every test builds the same orphan. A tool runs and blocks, the whole tree
//// is killed with the call's intent durable as effect-pending, and the
//// session is reopened over a surface whose `recover` answers. The first
//// incarnation's single execution is the only one `run` is allowed to see
//// unless the answer sends the call back through the planner's replay arm,
//// so the recorder's run counter is the evidence of "nothing re-ran".

import core/clock
import core/ids.{type OpId}
import core/json
import core/message.{type AgentMessage, ToolResultMessage, ToolResultText}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{type ReplayPolicy, ReplayNever, ReplaySafe}
import runtime/api
import runtime/effects.{type Effects}
import session/session.{type Session}
import support/fake
import support/harness
import support/recorder

// --- the mappings ----------------------------------------------------------

/// The executor holds the finished outcome: it is staged exactly as a fresh
/// run's outcome would be, and a replay-safe call is not run again.
pub fn recovered_outcome_is_staged_without_a_rerun_test() {
  let rec = recorder.start()
  let #(sess, options, op) = orphan(rec, "slow", ReplaySafe)

  // The closure checks the run it is handed against the persisted intent, so
  // a recovery that rebuilt the run from anything else would not count.
  let recover = fn(run: effects.ToolRun) {
    case
      run.call.id == "c1"
      && run.call.name == "slow"
      && run.arguments == json.Object([])
      && run.replay == ReplaySafe
      && run.grants == []
      && run.strand == "main"
    {
      True -> {
        let _seen = recorder.bump(rec, "recover-run-ok")
        Nil
      }
      False -> Nil
    }
    let _asked = recorder.bump(rec, "recover")
    effects.Recovered(effects.ToolCompleted(
      result: tool_result(run, "held by the executor"),
      terminate: False,
    ))
  }
  let rt = reopen(sess, rec, "slow", ReplaySafe, Some(recover), options)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the recovered run must complete"
  harness.assert_completed(last)

  assert recorder.read(rec, "recover") == 1
  assert recorder.read(rec, "recover-run-ok") == 1
  // `run` saw only the first incarnation's execution.
  assert recorder.read(rec, "tool:slow:c1") == 1
  assert list.contains(
    harness.final_projection(sess),
    "tool:slow:c1:ok:held by the executor",
  )
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

/// The executor restarted mid-run: the outcome is unknown even though the
/// call's replay policy would have allowed a re-execution.
pub fn outcome_unknown_stages_the_unknown_result_test() {
  let rec = recorder.start()
  let #(sess, options, op) = orphan(rec, "slow", ReplaySafe)
  let recover = fn(_run) { effects.OutcomeUnknown }
  let rt = reopen(sess, rec, "slow", ReplaySafe, Some(recover), options)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete after the unknown outcome"
  harness.assert_completed(last)

  assert recorder.read(rec, "tool:slow:c1") == 1
  let projection = harness.final_projection(sess)
  assert list.any(projection, fn(line) {
    string.starts_with(line, "tool:slow:c1:err:")
    && string.contains(line, "interrupted")
  })
  process.kill(rt.tree.supervisor)
}

/// The call never reached the executor and its replay is safe: it takes the
/// planner's replay arm and runs exactly once more.
pub fn not_started_replay_safe_runs_once_test() {
  let rec = recorder.start()
  let #(sess, options, op) = orphan(rec, "slow", ReplaySafe)
  let recover = fn(_run) { effects.NotStarted }
  let rt = reopen(sess, rec, "slow", ReplaySafe, Some(recover), options)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the replayed run must complete"
  harness.assert_completed(last)

  assert recorder.read(rec, "tool:slow:c1") == 2
  assert list.contains(harness.final_projection(sess), "tool:slow:c1:ok:out")
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

/// The call never reached the executor and may not be replayed: the model is
/// told it did not run, not that its outcome is unknown.
pub fn not_started_replay_never_stages_did_not_run_test() {
  let rec = recorder.start()
  let #(sess, options, op) = orphan(rec, "write", ReplayNever)
  let recover = fn(_run) { effects.NotStarted }
  let rt = reopen(sess, rec, "write", ReplayNever, Some(recover), options)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete after the failed call"
  harness.assert_completed(last)

  assert recorder.read(rec, "tool:write:c1") == 1
  let projection = harness.final_projection(sess)
  assert list.any(projection, fn(line) {
    string.starts_with(line, "tool:write:c1:err:")
    && string.contains(
      line,
      "the call never reached the executor and did not run",
    )
  })
  process.kill(rt.tree.supervisor)
}

// --- the effect's lifetime --------------------------------------------------

/// A recovery that blocks does not block the driver, and an abort kills it.
///
/// The abort could not be handled at all if the driver were parked inside the
/// surface's function, and the effect's process being dead afterwards is the
/// proof that it was registered where the abort path looks.
pub fn blocked_recovery_keeps_the_driver_responsive_and_abort_kills_it_test() {
  let rec = recorder.start()
  let pids: Subject(process.Pid) = process.new_subject()
  let #(sess, options, op) = orphan(rec, "slow", ReplaySafe)
  let recover = fn(_run) {
    process.send(pids, process.self())
    let _asked = recorder.bump(rec, "recover")
    let never: Subject(Nil) = process.new_subject()
    let _nil = process.receive_forever(never)
    effects.OutcomeUnknown
  }
  let rt = reopen(sess, rec, "slow", ReplaySafe, Some(recover), options)
  wait_for(fn() { recorder.read(rec, "recover") >= 1 }, 5000)
  let assert Ok(recovering) = process.receive(pids, 1000)
    as "the recovery effect must report its process"
  assert process.is_alive(recovering)

  // A second drive while the recovery is live must not spawn a second one.
  api.nudge(rt)
  process.sleep(100)
  assert recorder.read(rec, "recover") == 1

  api.abort(rt)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the abort must be handled while the recovery blocks"
  harness.assert_aborted(last)
  wait_for(fn() { !process.is_alive(recovering) }, 2000)
  assert recorder.read(rec, "tool:slow:c1") == 1
  process.kill(rt.tree.supervisor)
}

/// A recovery that dies without answering takes the path any tool effect
/// takes when its process exits: a synthetic error result, and the run goes
/// on.
pub fn crashed_recovery_takes_the_effect_exit_path_test() {
  let rec = recorder.start()
  let #(sess, options, op) = orphan(rec, "slow", ReplaySafe)
  let recover = fn(_run) {
    process.kill(process.self())
    effects.OutcomeUnknown
  }
  let rt = reopen(sess, rec, "slow", ReplaySafe, Some(recover), options)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete after the recovery died"
  harness.assert_completed(last)

  assert recorder.read(rec, "tool:slow:c1") == 1
  let projection = harness.final_projection(sess)
  assert list.any(projection, fn(line) {
    string.starts_with(line, "tool:slow:c1:err:")
    && string.contains(line, "the tool effect process exited before settling")
  })
  process.kill(rt.tree.supervisor)
}

// --- fixtures ---------------------------------------------------------------

// One orphan: the model asks for `name` once, the tool blocks on its first
// execution, and the tree is killed with the intent durable. Returns the
// session, the options to reopen it with, and the interrupted operation.
fn orphan(
  rec: Subject(recorder.Message),
  name: String,
  replay: ReplayPolicy,
) -> #(Session, api.Options, OpId) {
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) =
    api.open(sess, scripted(rec, name, replay, fake.ToolHang, None), options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("go")])
    as "the prompt must be accepted"
  wait_for(fn() { recorder.read(rec, "tool:" <> name <> ":c1") >= 1 }, 5000)
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)
  #(sess, options, op)
}

// The session reopened over a surface that would answer any re-execution
// with `out:{name}`, so a result of that shape can only come from a run.
fn reopen(
  sess: Session,
  rec: Subject(recorder.Message),
  name: String,
  replay: ReplayPolicy,
  recover: option.Option(fn(effects.ToolRun) -> effects.Recovery),
  options: api.Options,
) -> api.Runtime {
  let reply = fake.ToolReply(text: "out", is_error: False, terminate: False)
  let assert Ok(rt) =
    api.open(sess, scripted(rec, name, replay, reply, recover), options)
    as "the rebooted tree must start"
  rt
}

fn scripted(
  rec: Subject(recorder.Message),
  name: String,
  replay: ReplayPolicy,
  tool: fake.ToolResult,
  recover: option.Option(fn(effects.ToolRun) -> effects.Recovery),
) -> Effects {
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#(name, replay)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("working", [#("c1", name)], 4))
          _ -> fake.Reply(fake.answer("done", 5))
        }
      },
      fn(_run) { tool },
    )
  effects.Effects(
    ..base,
    tools: effects.ToolSurface(..base.tools, recover: recover),
  )
}

fn tool_result(run: effects.ToolRun, text: String) -> AgentMessage {
  ToolResultMessage(
    tool_call_id: run.call.id,
    tool_name: run.call.name,
    content: [ToolResultText(text:, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  )
}

fn wait_for(condition: fn() -> Bool, remaining: Int) -> Nil {
  case condition() {
    True -> Nil
    False ->
      case remaining <= 0 {
        True -> panic as "timed out waiting for a test condition"
        False -> {
          process.sleep(10)
          wait_for(condition, remaining - 10)
        }
      }
  }
}
