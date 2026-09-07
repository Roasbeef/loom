//// Targeted recovery tests: the pi §0.5 crash-mid-tool scenario
//// reproduced against a live tree, and the corrupt-restore fault path
//// (a strand whose registers cannot be validated faults its tree rather
//// than wedging).
////
//// The last two tests bound that fault path from the other side. A
//// corrupt register only gets to fault a driver if the driver's own
//// operation reads it, and the pending queue is read by the run intent
//// alone — so the same undecodable payload stops a run's load and
//// leaves a navigation's load alone.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation.{NavigationLastResult, ReplayNever, StructuralCompleted}
import machine/strand.{StrandState}
import runtime/api
import runtime/supervisor
import runtime/writer
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

/// A corrupt queue payload is none of a structural driver's business.
/// `pending.entry` keys are entry ids with no strand in them, so the
/// drive loop's queue read is a session-wide scan that one undecodable
/// register spoils entirely; only a run-intent operation ever
/// dereferences an id out of it. A navigation loaded beside such a
/// register must therefore still run to publication, where before the
/// read was scoped it faulted its strand on a value it never consults
/// (issue #70).
pub fn corrupt_queue_payload_leaves_a_navigation_driver_alone_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("answered", 3)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the session tree must boot"

  // One completed run, so the navigation has a leaf to move away from
  // and the strand is idle again when it is accepted.
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")])
    as "the prompt must be accepted"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  harness.assert_completed(outcome)

  // A queue payload no decoder can read, committed through the writer
  // as another strand's admission would have committed it.
  let assert Ok(_committed) =
    writer.commit(
      rt.tree.writer,
      Tx(
        writes: [
          SetRegister(
            ns: register.PendingEntry,
            key: "corrupt-pending-item",
            value: register.value(json.String("not a pending entry")),
          ),
        ],
        expected: [],
      ),
    )
    as "the corrupt queue payload must land"

  // The navigation's driver load happens strictly after the corruption,
  // so reaching publication is proof the load never read the queue.
  let assert Ok(navigation) =
    api.navigate(
      rt,
      to: None,
      summarize: False,
      label: None,
      custom_instructions: None,
      preparation: None,
    )
    as "the navigation must be accepted"
  api.nudge(rt)
  let assert Ok(NavigationLastResult(outcome: StructuralCompleted, ..)) =
    api.await_result(rt, navigation, within_ms: 5000)
    as "the navigation must publish despite the corrupt queue payload"
  process.kill(rt.tree.supervisor)
}

/// The run half of the same rule. A run does dereference queue ids —
/// `place_pending` turns each one into an entry — so its driver load
/// must still refuse an undecodable payload rather than place content it
/// cannot read. Admission already refuses a *fresh* run outright
/// (`runtime/api.read_pending_for`), so the only way to reach the drive
/// loop's read with the payload already present is to corrupt the queue
/// under a run that is open: the tree is killed mid-tool, the register is
/// planted while nothing is driving, and the reboot's load faults the
/// strand until the supervisor gives up. The same reboot without the
/// payload is `never_tool_interrupted_mid_flight_test`, which completes.
pub fn corrupt_queue_payload_still_faults_a_run_driver_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("write", ReplayNever)],
      fn(_spec) { fake.Reply(fake.tool_use("deleting", [#("c1", "write")], 6)) },
      fn(_run) { fake.ToolHang },
    )
  let base = api.default_options(harness.configuration())
  let assert Ok(rt) = api.open(sess, eff, base) as "the session tree must boot"
  let assert Ok(_op) = api.prompt(rt, [fake.user("delete the migrations")])
    as "the prompt must be accepted"

  // The tool is mid-flight, so the strand's open operation is a run and
  // the reboot has a run-intent load to perform.
  wait_for(fn() { recorder.read(rec, "tool:write:c1") >= 1 }, 5000)
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)

  // The same undecodable payload, planted directly in the store while
  // no driver is running.
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.PendingEntry,
            key: "corrupt-pending-item",
            value: register.value(json.String("not a pending entry")),
          ),
        ],
        expected: [],
      ),
    )
    as "the corrupt queue payload must land"

  // The run's load refuses it on every restore attempt, so the tree dies
  // visibly rather than placing an entry it could not decode.
  let options =
    api.Options(
      ..base,
      tolerance: supervisor.Tolerance(intensity: 2, period: 1),
    )
  let assert Ok(rebooted) = api.open(sess, eff, options)
    as "the tree boots before the strand's first drive faults it"
  wait_for(fn() { !process.is_alive(rebooted.tree.supervisor) }, 5000)
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
