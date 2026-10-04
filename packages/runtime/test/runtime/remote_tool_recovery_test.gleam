//// Restart tests with actual session and owner-custody SQLite databases.
//// The scripted custodian serializes durable writes independently of tool
//// workers and strand incarnations. A pending callback observes custody and
//// never calls the tool runner to reconstruct a final report from children.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/remote_tool
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation
import machine/queue
import runtime/api
import runtime/effects
import runtime/supervisor
import runtime/writer
import session/session
import simplifile
import storage/owner_custody as custody
import storage/storage
import support/fake
import support/harness
import support/recorder
import weft/actor
import weft/poll

// These modes select reachable loss points, not alternate production APIs.
type Mode {
  CallbackLoss
  StrandRestart
  ChildOnly
  Pending
}

type OwnerMessage {
  Admit(run: effects.ToolRun, reply: Subject(Nil))
  Recover(
    run: effects.ToolRun,
    wake: fn(effects.RecoveryCompletion) -> Nil,
    reply: Subject(effects.ToolRecovery),
  )
  Complete(reply: Subject(Nil))
  HasWake(reply: Subject(Bool))
  Close(reply: Subject(Nil))
}

type OwnerState {
  OwnerState(
    store: custody.Store,
    session_id: ids.SessionId,
    limits: custody.Limits,
    mode: Mode,
    run: Option(effects.ToolRun),
    completion: Option(fn(effects.RecoveryCompletion) -> Nil),
  )
}

fn key(state: OwnerState, run: effects.ToolRun) -> remote_tool.ToolKey {
  // This fixture uses the independently computed SHA-256 of canonical {}.
  // Production injects the existing host hash facility, outside pure core.
  assert json.to_string(json.canonical(run.arguments)) == "{}"
  let assert Ok(key) =
    remote_tool.key(
      state.session_id,
      run.operation,
      run.step_id,
      run.source_index,
      "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
      run.result_entry,
    )
    as "persisted runtime identity constructs the complete custody key"
  key
}

fn payload(state: OwnerState, bytes: BitArray) -> custody.Payload {
  let assert Ok(payload) = custody.payload(state.limits, bytes)
    as "fixture payload fits custody ceiling"
  payload
}

fn final(run: effects.ToolRun) -> effects.ToolOutcome {
  effects.ToolCompleted(
    message.ToolResultMessage(
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      content: [message.ToolResultText("exact owner final result", None)],
      details: Some(json.Object([#("retained", json.String("exact"))])),
      usage: None,
      added_tool_names: Some(["next-tool"]),
      is_error: False,
      timestamp: 42,
    ),
    False,
  )
}

fn persist_final(state: OwnerState, run: effects.ToolRun) -> Nil {
  let assert Ok(encoded) = effects.encode_tool_outcome(final(run))
    as "exact final outcome encodes"
  assert custody.finish(state.store, key(state, run), payload(state, encoded))
    == Ok(Nil)
}

fn handle(
  state: OwnerState,
  message: OwnerMessage,
) -> actor.Next(OwnerState, OwnerMessage) {
  case message {
    Admit(run:, reply:) -> {
      let key = key(state, run)
      let arguments =
        json.canonical(run.arguments)
        |> json.to_string
        |> bit_array.from_string
        |> payload(state, _)
      assert custody.admit(
          state.store,
          key,
          arguments,
          payload(state, <<"registered-workspace:epoch:exact-request":utf8>>),
        )
        == Ok(Nil)
      case state.mode {
        CallbackLoss | StrandRestart -> persist_final(state, run)
        ChildOnly -> {
          let assert Ok(origin) =
            remote_tool.tool_child(key, remote_tool.Compile)
            as "compile origin is typed"
          let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(9000), 45))
          assert custody.admit_child(
              state.store,
              origin,
              id,
              payload(state, <<"compile request":utf8>>),
            )
            == Ok(Nil)
          assert custody.receive_child(
              state.store,
              origin,
              id,
              payload(state, <<"compile succeeded":utf8>>),
            )
            == Ok(Nil)
        }
        Pending -> Nil
      }
      process.send(reply, Nil)
      actor.continue(OwnerState(..state, run: Some(run)))
    }
    Recover(run:, wake:, reply:) -> {
      assert run.grants == []
      let assert Some(original) = state.run
        as "custody retains the original run"
      assert run.operation == original.operation
      assert run.step_id == original.step_id
      assert run.source_index == original.source_index
      assert run.result_entry == original.result_entry
      assert run.arguments == original.arguments
      assert run.call == original.call
      let verdict = case custody.lookup(state.store, key(state, run)) {
        Ok(custody.FinalOutcome(payload)) -> {
          let assert Ok(outcome) =
            effects.decode_tool_outcome(custody.bytes(payload))
            as "only exact final outcome bytes recover"
          effects.RecoveredOutcome(outcome)
        }
        Ok(custody.AwaitingFinal(child_count: 1, ..)) ->
          effects.UnknownOutcome("compile child retained; final report absent")
        Ok(custody.AwaitingFinal(child_count: 0, ..)) ->
          effects.PendingReconciliation
        _ -> panic as "fixture custody must be retained and bounded"
      }
      process.send(reply, verdict)
      actor.continue(OwnerState(..state, completion: Some(wake)))
    }
    Complete(reply:) -> {
      let assert Some(run) = state.run
        as "completion retains original tool identity"
      let assert Some(wake) = state.completion
        as "reconciliation registered its wake"
      persist_final(state, run)

      // Lost/duplicated completion delivery cannot settle the tool twice.
      wake(effects.RecoveryCompleted(final(run)))
      wake(effects.RecoveryCompleted(final(run)))
      process.send(reply, Nil)
      actor.continue(state)
    }
    HasWake(reply:) -> {
      process.send(reply, option.is_some(state.completion))
      actor.continue(state)
    }
    Close(reply:) -> {
      assert custody.close(state.store) == Ok(Nil)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn fixture(
  name: String,
  mode: Mode,
) -> #(
  api.Runtime,
  Subject(OwnerMessage),
  Subject(recorder.Message),
  Subject(effects.ToolRun),
) {
  let directory = "build/test_db/owner-recovery-" <> name
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "fixture directory recreates SQLite and WAL together"
  let assert Ok(sess) =
    session.open_sqlite(
      directory <> "/session.db",
      "owner-recovery-test",
      60_000,
      clock.stepping(1_000_000, 7),
    )
    as "actual runtime session SQLite opens"
  let assert Ok(#(session_id, _)) =
    session.ensure_id(sess, ids.generator(clock.fixed(1000), 11))
    as "session identity commits before custody opens"
  let assert Ok(limits) = custody.limits(8, 32, 131_072, 4096)
    as "fixture custody ceilings validate"
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", session_id, limits)
    as "owner custody opens separately from frozen session schema"
  let assert Ok(owner) =
    actor.new(OwnerState(
      store:,
      session_id:,
      limits:,
      mode:,
      run: None,
      completion: None,
    ))
    |> actor.on_message(handle)
    |> actor.start
    as "serialized independent custodian starts"
  let owner = owner.data
  let rec = recorder.start()
  let started = process.new_subject()
  let base =
    fake.effects(
      rec,
      clock.stepping(2_000_000, 25),
      [#("slow", operation.ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 ->
            fake.Reply(fake.tool_use("remote", [#("remote-call", "slow")], 4))
          _ -> fake.Reply(fake.answer("done", 5))
        }
      },
      fn(_) { fake.ToolHang },
    )
  let tools =
    effects.ToolSurface(
      ..base.tools,
      run: fn(run) {
        let _count = recorder.bump(rec, "actual-runs")
        process.call(owner, 2000, Admit(run, _))
        process.send(started, run)
        case mode {
          CallbackLoss -> process.kill(process.self())
          StrandRestart | ChildOnly | Pending -> Nil
        }
        let never: Subject(Nil) = process.new_subject()
        process.receive_forever(never)
        effects.ToolFailed("unreachable fixture continuation")
      },
      recover: fn(run, wake) {
        let _count = recorder.bump(rec, "recovery-calls")
        process.call(owner, 2000, Recover(run, wake, _))
      },
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 20,
      idle_poll_interval_ms: 20,
      tolerance: supervisor.Tolerance(10_000, 10),
    )
  let assert Ok(runtime) =
    api.open(sess, effects.Effects(..base, tools:), options)
    as "runtime boots with real SQLite and injected owner custody"
  #(runtime, owner, rec, started)
}

fn restart(runtime: api.Runtime) -> Nil {
  let assert Ok(subject) = supervisor.strand_subject(runtime.tree, "main")
    as "original strand exists"
  let assert Ok(pid) = process.subject_owner(subject)
    as "original strand has a pid"
  process.kill(pid)
}

fn finish(runtime: api.Runtime, owner: Subject(OwnerMessage)) -> Nil {
  process.kill(runtime.tree.supervisor)
  process.call(owner, 2000, Close)
  assert storage.close(runtime.session.store) == Ok(Nil)
}

pub fn persisted_final_outcome_survives_live_callback_loss_test() {
  let #(runtime, owner, rec, started) = fixture("callback-loss", CallbackLoss)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(_) = process.receive(started, 5000)
    as "owner final commits before callback disappears"
  let assert Ok(result) = api.await_result(runtime, op, 10_000)
    as "lost live callback recovers its exact durable outcome"
  harness.assert_completed(result)
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "recovery-calls") == 1
  assert list.any(harness.final_projection(runtime.session), fn(line) {
    string.contains(line, "exact owner final result")
  })
  finish(runtime, owner)
}

pub fn restart_recovers_final_outcome_under_original_ids_without_rerun_test() {
  let #(runtime, owner, rec, started) = fixture("strand-restart", StrandRestart)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(original) = process.receive(started, 5000)
    as "outgoing request and exact final are durable"
  restart(runtime)
  let assert Ok(result) = api.await_result(runtime, op, 10_000)
    as "replacement strand settles exact owner final outcome"
  harness.assert_completed(result)
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "recovery-calls") == 1
  let assert Ok(entries) =
    storage.get_entries(runtime.session.store, [original.result_entry])
    as "result lands at original reserved entry"
  let assert Ok(entry) = dict.get(entries, original.result_entry)
    as "reserved result exists"
  let assert entry.MessageEntry(message:, terminate: False, ..) = entry
    as "recovery traversed durable result materialization"
  let assert effects.ToolCompleted(result: exact, ..) = final(original)
    as "fixture has exact final"
  assert message == exact
  finish(runtime, owner)
}

pub fn child_only_evidence_is_unknown_even_for_replay_safe_tool_test() {
  let #(runtime, owner, rec, started) = fixture("child-only", ChildOnly)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(_) = process.receive(started, 5000) as "child receipt commits"
  restart(runtime)
  let assert Ok(result) = api.await_result(runtime, op, 10_000)
    as "unknown result settles truthfully"
  harness.assert_completed(result)
  assert recorder.read(rec, "actual-runs") == 1
  assert list.any(harness.final_projection(runtime.session), fn(line) {
    string.contains(
      line,
      "remote tool outcome unknown; retained evidence: compile child retained; final report absent",
    )
  })
  finish(runtime, owner)
}

pub fn pending_reconciliation_wakes_and_settles_exactly_once_test() {
  let #(runtime, owner, rec, started) = fixture("pending", Pending)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(_) = process.receive(started, 5000)
    as "admission commits before request becomes sendable"
  restart(runtime)
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case process.call(owner, 2000, HasWake) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "supervised pending recovery installs its completion wake"
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "recovery-calls") == 1
  let before = recorder.read(rec, "entropy")
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case recorder.read(rec, "entropy") >= before + 3 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "several checkpoint ticks replan while reconciliation is pending"
  assert recorder.read(rec, "provider") == 1
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "recovery-calls") == 1
  process.call(owner, 2000, Complete)
  let assert Ok(result) = api.await_result(runtime, op, 10_000)
    as "completion wake settles without model polling or tool dispatch"
  harness.assert_completed(result)
  assert recorder.read(rec, "actual-runs") == 1
  let finals =
    harness.final_projection(runtime.session)
    |> list.filter(fn(line) {
      string.contains(line, "exact owner final result")
    })
  assert list.length(finals) == 1
  finish(runtime, owner)
}

pub fn final_outcome_codec_is_total_bounded_and_preserves_every_field_test() {
  assert effects.decode_tool_outcome(bit_array.from_string("[]"))
    == Error("invalid final tool outcome envelope")
  assert effects.decode_tool_outcome(
      bit_array.from_string(string.repeat("x", 262_145)),
    )
    == Error("final tool outcome exceeds custody payload bound")
  assert effects.decode_tool_outcome(<<255>>)
    == Error("invalid final tool outcome UTF-8")
  let outcome =
    effects.ToolCompleted(
      message.ToolResultMessage(
        "call",
        "tool",
        [
          message.ToolResultImage("data", "image/png"),
          message.ToolResultText("report", Some("signature")),
        ],
        Some(json.Array([json.Int(1)])),
        None,
        Some(["next"]),
        True,
        44,
      ),
      True,
    )
  let assert Ok(bytes) = effects.encode_tool_outcome(outcome)
    as "final tool fields encode"
  assert effects.decode_tool_outcome(bytes) == Ok(outcome)
}

/// An abort must not install a new indefinite wait after killing its callback.
pub fn abort_of_live_remote_callback_does_not_wait_for_reconciliation_test() {
  let #(runtime, owner, rec, started) = fixture("abort-pending", Pending)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(_) = process.receive(started, 5000)
    as "remote admission precedes the abort"
  api.abort_operation(runtime, op)
  let assert Ok(result) = api.await_result(runtime, op, 2000)
    as "durable cancellation settles without a remote completion wake"
  harness.assert_aborted(result)
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "provider") == 1
  assert recorder.read(rec, "recovery-calls") == 1
  assert list.any(harness.final_projection(runtime.session), fn(line) {
    string.contains(line, "remote tool outcome unknown")
  })
  finish(runtime, owner)
}

/// A replacement strand reads cancellation before installing a recovery wait.
pub fn restart_with_durable_cancel_does_not_wait_for_reconciliation_test() {
  let #(runtime, owner, rec, started) = fixture("restart-cancel", Pending)
  let assert Ok(op) = api.prompt(runtime, [fake.user("run remote")])
    as "run is accepted"
  let assert Ok(_) = process.receive(started, 5000)
    as "remote admission precedes the cancellation marker"
  let assert Ok(Some(metadata)) = session.op_meta(runtime.session, op)
    as "the original operation metadata is durable"
  let assert Ok(Some(current)) = session.op_state(runtime.session, op)
    as "the original pending state is durable"
  let assert queue.AbortPlanned(tx:, ..) =
    queue.request_abort(metadata.value, current.value, current.seq, 9000)
    as "the first cancellation produces a durable marker"
  let assert Ok(_) = writer.commit(runtime.tree.writer, tx)
    as "the writer persists cancellation before the old strand exits"

  // No abort message is delivered to the replacement. Durable state alone must
  // prevent a new wait, even though the owner still has no final tool report.
  restart(runtime)
  let assert Ok(result) = api.await_result(runtime, op, 5000)
    as "the replacement settles cancellation without a completion wake"
  harness.assert_aborted(result)
  assert recorder.read(rec, "actual-runs") == 1
  assert recorder.read(rec, "provider") == 1
  assert list.any(harness.final_projection(runtime.session), fn(line) {
    string.contains(line, "remote tool outcome unknown")
  })
  finish(runtime, owner)
}
