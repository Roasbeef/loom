//// The M1 cold-open acceptance test: a multi-turn SQLite session
//// (eleven runs, twenty-two assistant turns, one tool call per run —
//// over thirty turns of conversation) is killed mid-operation,
//// everything is closed, and the session is reopened from the database
//// file alone. The restored strand resumes the crashed run and
//// completes it correctly.

import core/clock
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import machine/operation.{ReplayNever}
import runtime/api
import runtime/effects
import session/session
import simplifile
import support/fake
import support/harness
import support/recorder

const hang_call = "c20"

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

// Even assistant turns request the tool (with a turn-stable call id);
// odd turns answer. Stable across crashes because the projection drives
// the turn number.
fn provider(spec: effects.RequestSpec) -> fake.ProviderResult {
  let turn = fake.turn(spec)
  case turn % 2 {
    0 ->
      fake.Reply(fake.tool_use(
        "inspecting " <> int.to_string(turn),
        [#("c" <> int.to_string(turn), "read")],
        3,
      ))
    _ -> fake.Reply(fake.answer("done " <> int.to_string(turn), 2))
  }
}

fn scripted(
  rec: process.Subject(recorder.Message),
  from: Int,
) -> effects.Effects {
  fake.effects(
    rec,
    clock.stepping(from:, by: 25),
    [#("read", ReplayNever)],
    provider,
    fn(tool_run) {
      case tool_run.call.id == hang_call {
        // The final run's tool never settles: the kill lands mid-flight.
        True -> fake.ToolHang
        False -> fake.ToolReply(text: "data", is_error: False, terminate: False)
      }
    },
  )
}

pub fn cold_open_resumes_a_crashed_session_test() {
  let path = fresh_path("cold_open")
  let rec = recorder.start()
  let assert Ok(first) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 30_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
    as "the fresh sqlite session must open"
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) = api.open(first, scripted(rec, 2_000_000), options)
    as "the session tree must boot"
  // Ten complete runs: user → assistant(tool) → result → assistant.
  int.range(from: 0, to: 10, with: Nil, run: fn(_, index) {
    let assert Ok(op) =
      api.prompt(rt, [fake.user("question " <> int.to_string(index))])
      as "each warm-up prompt must be accepted"
    let assert Ok(outcome) = api.await_result(rt, op, within_ms: 10_000)
      as "each warm-up run must complete"
    harness.assert_completed(outcome)
  })
  // The eleventh run's tool hangs; kill the tree mid-operation.
  let assert Ok(crashed_op) = api.prompt(rt, [fake.user("question 10")])
    as "the eleventh prompt must be accepted"
  wait_for(fn() { recorder.read(rec, "tool:read:" <> hang_call) >= 1 }, 10_000)
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)
  // Close everything: the storage handle releases the writer lease.
  let assert Ok(Nil) = session.close(first)
    as "the crashed session's handle must close"

  // Reopen from the file alone: a new owner, a new recorder, the same
  // deterministic scripts.
  let rec2 = recorder.start()
  let assert Ok(second) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 30_000,
      clock: clock.stepping(from: 9_000_000, by: 7),
    )
    as "the session must reopen from the file"
  let assert Ok(rt2) = api.open(second, scripted(rec2, 10_000_000), options)
    as "the reopened tree must boot"
  let assert Ok(outcome) = api.await_result(rt2, crashed_op, within_ms: 10_000)
    as "the crashed run must resume and complete"
  harness.assert_completed(outcome)
  // The Never tool was not re-executed on resume.
  assert recorder.read(rec2, "tool:read:" <> hang_call) == 0
  // The transcript is intact: twenty-two assistant turns across eleven
  // runs, the interrupted eleventh tool call answered synthetically, and
  // the final answer present.
  let projection = harness.final_projection(second)
  let assistants = list.filter(projection, string.starts_with(_, "assistant:"))
  assert list.length(assistants) == 22
  assert list.any(projection, fn(line) {
    string.starts_with(line, "tool:read:" <> hang_call <> ":err:")
  })
  assert list.contains(projection, "assistant:stop:done 21")
  harness.assert_placement_invariants(second)
  let assert Ok(Some(session.Cell(value: strand_state, ..))) =
    session.strand_state(second, "main")
    as "the reopened strand state must read"
  assert strand_state.current_operation == option.None
  let assert Ok(Nil) = api.close(rt2)
    as "the reopened runtime must close cleanly"
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
