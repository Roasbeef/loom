//// Targeted recovery tests: the pi §0.5 crash-mid-tool scenario
//// reproduced against a live tree, and the corrupt-restore fault path
//// (a strand whose registers cannot be validated faults its tree rather
//// than wedging).

import core/clock
import core/ids
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import machine/codec
import machine/operation.{ReplayNever}
import machine/strand.{StrandState}
import runtime/api
import runtime/supervisor
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder

/// pi §0.5, live: a `replay: Never` tool is genuinely mid-flight when
/// the whole tree is killed. On reboot the harness does not re-run the
/// deletion — recovery stages the synthetic interrupted result under the
/// reserved id, the conversation stays coherent, and the run completes.
pub fn never_tool_interrupted_mid_flight_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let provider = fn(spec) {
    case fake.turn(spec) {
      0 -> fake.Reply(fake.tool_use("deleting", [#("c1", "write")], 6))
      _ -> fake.Reply(fake.answer("Recovered after the crash", 4))
    }
  }
  let scripted = fn(hang: Bool) {
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("write", ReplayNever)],
      provider,
      fn(_run) {
        case hang {
          True -> fake.ToolHang
          False ->
            fake.ToolReply(text: "ran", is_error: False, terminate: False)
        }
      },
    )
  }
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) = api.open(sess, scripted(True), options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("delete the migrations")])
    as "the prompt must be accepted"
  wait_for(fn() { recorder.read(rec, "tool:write:c1") >= 1 }, 5000)
  // The tool is mid-flight. Kill the whole tree.
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)
  // Reboot from the same store. The tool script would answer normally
  // now — proving a completed result can only come from a re-execution.
  let assert Ok(rt) = api.open(sess, scripted(False), options)
    as "the rebooted tree must start"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the recovered run must complete"
  harness.assert_completed(outcome)
  // Nothing ran twice: the one mid-flight invocation is the only one.
  assert recorder.read(rec, "tool:write:c1") == 1
  // The synthetic interrupted result is in the tree, with the warning.
  let projection = harness.final_projection(sess)
  assert list.any(projection, fn(line) {
    string.starts_with(line, "tool:write:c1:err:")
    && string.contains(line, "interrupted")
  })
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

/// Corrupt restore faults the strand, never wedges: a strand state that
/// names an operation with no registers keeps faulting the strand until
/// the supervisor gives up and the tree dies — visibly, not silently.
pub fn corrupt_restore_faults_the_tree_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let assert Ok(Nil) =
    session.ensure_strand(sess, "main", harness.configuration())
    as "the strand must seed"
  // Corrupt the restore projection: an operation id with no op.meta or
  // op.state registers.
  let #(ghost, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 99))
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.StrandState,
            key: "main",
            value: register.value(
              codec.encode_strand_state(
                StrandState(
                  current_operation: Some(ghost),
                  pending_next_run: [],
                ),
              ),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the corrupting commit must apply"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("unreachable", 1)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      tolerance: supervisor.Tolerance(intensity: 2, period: 1),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the tree boots before the strand's first drive faults it"
  // The strand faults on every restore attempt; the tree must die
  // rather than wedge.
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 5000)
  // The corrupt state was never "repaired" behind the operator's back.
  let assert Ok(Some(session.Cell(value: still, ..))) =
    session.strand_state(sess, "main")
    as "the corrupt strand state must still be readable"
  assert still.current_operation == Some(ghost)
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
