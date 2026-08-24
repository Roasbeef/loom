//// Replays of pi's worked examples, transaction for transaction:
//// §0.4 (the Slack thread), §0.5 (crash mid-tool), and §3.9's overflow
//// example — adapted to strand naming and Loom's register vocabulary.
////
//// Every driver step decodes `op.state` from the fake store before
//// planning, so each step is also a crash-restore; the §0.5 test makes
//// the crash explicit by discarding everything but the store.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/option.{None, Some}
import machine/acceptance.{AcceptRun}
import machine/codec
import machine/operation.{
  CallEffectPending, Checkpoint, Compacting, Deciding, MayFinish, NeedAssistant,
  OverflowReason, PendingMessage, ReplayNever, ReplaySafe, RunAborted,
  RunCompleted, RunFailed, RunLastResult, RunState, Tools,
}
import machine/planner.{
  Admitted, AwaitEffect, Dispatch, Finish, ModelResolved, NoObservation,
  ObservedAdmission, ObservedAssistantSettled, ObservedResolution,
  ObservedRunEnd, ObservedRunStart, ObservedStructuralDecision,
  ObservedSummaryProgress, ObservedSummaryReturned, ObservedToolCleared,
  ObservedToolOrphaned, ObservedToolSettled, Prepared, SummaryProduced,
  VerdictGenerate,
}
import machine/queue
import machine/strand.{StrandState}
import support/fixture
import support/scenario.{type World, World}
import support/store

fn opts() -> scenario.StepOptions {
  scenario.default_options()
}

fn admitted() -> planner.Observation {
  ObservedAdmission(admission: Admitted(
    stream_options: json.Object([]),
    intended_output_limit: 4096,
    context_window: 200_000,
  ))
}

/// Drives a fresh world through acceptance and the run-start hook into
/// the first `assistant effect_pending`, asserting pi §0.4's opening
/// transaction shapes along the way.
fn start_run(prompt: String) -> World {
  let world = scenario.fresh()
  // TX 1 — acceptance: user entry, leaf, op.meta, op.state = starting,
  // strand.state names the operation.
  let assert Ok(#(world, accept_tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user(prompt)]))
  assert scenario.write_names(accept_tx)
    == [
      "insert:message", "set:strand.leaf", "set:op.meta", "set:op.state",
      "set:strand.state",
    ]
  // TX 2 — the consuming command replaces starting with a checkpoint.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, ObservedRunStart(messages: []), opts())
  assert writes == ["set:op.state"]
  // TX 3 — checkpoint enters assistant ready (config snapshot).
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes == ["set:op.state"]
  // Pre-request admission is awaited, then TX 4 — the request intent
  // reserving the response and usage ids.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.AdmissionKey(..)) = action
  let assert Ok(#(world, action)) = scenario.step(world, admitted(), opts())
  let assert Dispatch(
    intent: planner.ProviderRequest(..),
    next: _,
    tx: intent_tx,
  ) = action
  assert scenario.write_names(intent_tx) == ["set:op.state"]
  world
}

pub fn slack_thread_scenario_test() {
  let world = start_run("what changed in auth last week?")
  // TX 5 — settlement with one tool call: response entry, leaf, usage,
  // and the batch plan with a reserved result id, atomically.
  let response = fixture.assistant_calls(["bash"])
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(response),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  // The reserved result id inherits the response id's time prefix.
  let assert Ok(RunState(phase: Tools(batch:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert [operation.CallPlanned(source_index: 1, result_entry:)] =
    batch.calls
  assert ids.entry_id_timestamp_ms(result_entry)
    == ids.entry_id_timestamp_ms(batch.assistant_entry)
  // TX 6 — clearance passed: tool args persist and call 0 goes
  // effect-pending in one commit.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 1, ..)) =
    action
  let assert Ok(#(world, action)) =
    scenario.step(
      world,
      ObservedToolCleared(
        source_index: 1,
        effective_arguments: json.Object([#("cmd", json.String("git log"))]),
        replay: ReplayNever,
      ),
      opts(),
    )
  let assert Dispatch(intent: planner.ToolRequest(..), next: _, tx: tool_tx) =
    action
  assert scenario.write_names(tool_tx) == ["set:op.tool_args", "set:op.state"]
  // TX 7 — the finalized outcome stages in pending.entry.
  let result =
    fixture.tool_result("call_bash_0", "bash", "3 commits touched auth")
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedToolSettled(source_index: 1, result:, terminate: False),
      opts(),
    )
  assert writes == ["set:pending.entry", "set:op.state"]
  // TX 8 — source-ordered materialization: entry in, staged register
  // out, leaf forward, args cleaned, checkpoint next.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes
    == [
      "insert:message", "del:pending.entry", "set:strand.leaf",
      "del:op.tool_args", "set:op.state",
    ]
  // Second turn: ready, intent, settle without calls.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes == ["set:op.state"]
  let assert Ok(#(world, action)) = scenario.step(world, admitted(), opts())
  let assert Dispatch(intent: planner.ProviderRequest(..), ..) = action
  let answer =
    fixture.assistant(message.Stop, "auth changed in three commits", 40)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  // The finish boundary consults the run-end hook, then the terminal
  // transaction deletes the operation's registers and records the result.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.RunEndKey(..)) = action
  let assert Ok(#(world, action)) =
    scenario.step(world, ObservedRunEnd(follow_up: None), opts())
  let assert Finish(
    result: RunLastResult(outcome: RunCompleted(..), ..),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "del:op.meta",
      "del:op.state",
      "set:strand.last_result",
      "set:strand.state",
    ]
  // A finished strand holds exactly conversation, ledger, and strand
  // registers: no op.* register survives.
  assert store.list_register_keys(world.store, register.OpState, "") == []
  assert store.list_register_keys(world.store, register.OpMeta, "") == []
  assert store.list_register_keys(world.store, register.OpToolArgs, "") == []
  assert store.list_register_keys(world.store, register.PendingEntry, "") == []
  let assert Ok(#(_seq, register.RegisterValue(payload:))) =
    store.get_register(world.store, register.StrandState, "main")
  assert codec.decode_strand_state(payload)
    == Ok(StrandState(current_operation: None, pending_next_run: []))
  // No further transition exists out of terminal.
  case scenario.step(world, NoObservation, opts()) {
    Error(message) -> {
      assert message == "op.state absent"
    }
    Ok(_) -> panic as "stepped an operation after its terminal transaction"
  }
}

pub fn crash_mid_tool_scenario_test() {
  let world = start_run("delete the stale migrations and run the test suite")
  // The model returns two tool calls; the batch plan reserves both
  // result ids in the settlement transaction.
  let response = fixture.assistant_calls(["rm", "test"])
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(response),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(RunState(phase: Tools(batch: planned_batch), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert [
    operation.CallPlanned(source_index: 1, result_entry: first_result),
    operation.CallPlanned(source_index: 2, result_entry: second_result),
  ] = planned_batch.calls
  // Call 0 clears and declares itself unsafe to replay.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 1, ..)) =
    action
  let assert Ok(#(world, action)) =
    scenario.step(
      world,
      ObservedToolCleared(
        source_index: 1,
        effective_arguments: json.Object([#("path", json.String("migrations/"))]),
        replay: ReplayNever,
      ),
      opts(),
    )
  let assert Dispatch(intent: planner.ToolRequest(replay: ReplayNever, ..), ..) =
    action
  // CRASH: nothing process-local survives. The durable state says
  // call 0 is effect_pending with replay never.
  let restored = World(..world, now: world.now + 60_000, seed: world.seed + 100)
  let assert Ok(RunState(phase: Tools(batch: restored_batch), ..)) =
    scenario.read_op_state(restored.store, restored.op.id)
  let assert [
    CallEffectPending(
      source_index: 1,
      result_entry: restored_result,
      replay: ReplayNever,
    ),
    operation.CallPlanned(source_index: 2, ..),
  ] = restored_batch.calls
  assert restored_result == first_result
  // Reconciliation: the synthetic interrupted result stages under the
  // reserved id, carrying the latest durable checkpoint plus the
  // warning. It is never re-executed.
  let checkpoint =
    fixture.tool_result("call_rm_0", "rm", "deleted 3 of 9 migrations")
  let assert Ok(#(restored, writes)) =
    scenario.step_writes(
      restored,
      ObservedToolOrphaned(
        source_index: 1,
        replay_still_safe: False,
        checkpoint: Some(checkpoint),
      ),
      opts(),
    )
  assert writes == ["set:pending.entry", "set:op.state"]
  // The staged payload preserves checkpoint content and appends the
  // explicit unknown-outcome warning as an error result.
  let assert Ok(#(_seq, register.RegisterValue(payload:))) =
    store.get_register(
      restored.store,
      register.PendingEntry,
      ids.entry_id_to_string(first_result),
    )
  let assert Ok(PendingMessage(message: message.ToolResultMessage(
    is_error: True,
    content:,
    ..,
  ))) = codec.decode_pending_entry(payload)
  let assert [
    message.ToolResultText(text: "deleted 3 of 9 migrations", ..),
    message.ToolResultText(text: warning, ..),
  ] = content
  assert warning
    == "interrupted: the preceding content is the latest committed partial; "
    <> "newer live output may be missing and the external outcome is unknown"
  // Materialization places the interrupted result under the reserved id.
  let assert Ok(#(restored, writes)) =
    scenario.step_writes(restored, NoObservation, opts())
  assert writes
    == [
      "insert:message",
      "del:pending.entry",
      "set:strand.leaf",
      "set:op.state",
    ]
  let assert Ok(entry.MessageEntry(
    message: message.ToolResultMessage(is_error: True, ..),
    ..,
  )) = store.get_entry(restored.store, ids.entry_id_to_string(first_result))
  // The second call had declared safe replay in spirit; run it normally
  // so every tool call ends with a result.
  let assert Ok(#(restored, action)) =
    scenario.step(restored, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 2, ..)) =
    action
  let assert Ok(#(restored, _action)) =
    scenario.step(
      restored,
      ObservedToolCleared(
        source_index: 2,
        effective_arguments: json.Object([]),
        replay: ReplaySafe,
      ),
      opts(),
    )
  let assert Ok(#(restored, _writes)) =
    scenario.step_writes(
      restored,
      ObservedToolSettled(
        source_index: 2,
        result: fixture.tool_result("call_test_1", "test", "42 tests passed"),
        terminate: False,
      ),
      opts(),
    )
  let assert Ok(#(restored, writes)) =
    scenario.step_writes(restored, NoObservation, opts())
  // Both calls wrote effective arguments; final materialization deletes
  // every op.tool_args register.
  assert writes
    == [
      "insert:message", "del:pending.entry", "set:strand.leaf",
      "del:op.tool_args", "del:op.tool_args", "set:op.state",
    ]
  // Every reserved result id now has exactly one immutable entry.
  let assert Ok(_first) =
    store.get_entry(restored.store, ids.entry_id_to_string(first_result))
  let assert Ok(_second) =
    store.get_entry(restored.store, ids.entry_id_to_string(second_result))
}

pub fn overflow_one_shot_scenario_test() {
  let world = start_run("summarize the last month of work")
  // 1. Settlement classifies overflow: the response commits normalized
  // to error, together with the preparation and the compaction state.
  let overflow =
    fixture.assistant_error("context window exceeded: too big", False)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(overflow),
        overflow_preparation: Some(Prepared(preparation: fixture.preparation())),
      ),
      opts(),
    )
  assert writes
    == [
      "insert:message", "set:strand.leaf", "insert:usage", "set:op.preparation",
      "set:op.state",
    ]
  let assert Ok(RunState(
    phase: Compacting(
      reason: OverflowReason,
      structural: Deciding(..),
      resume_after: resume,
    ),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  // resumeAfter restores need_assistant with the one-shot flag spent.
  let assert NeedAssistant(overflow_recovery_used: True) = resume.continuation
  // The committed response is durable history with stop reason error.
  let assert Ok(RunState(latest_assistant: Some(normalized_id), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert Ok(entry.MessageEntry(
    message: message.AssistantMessage(stop_reason: message.Errored, ..),
    ..,
  )) = store.get_entry(world.store, ids.entry_id_to_string(normalized_id))
  // 2. The decision hook selects generation; one nested request settles;
  // the compaction publishes and the marked checkpoint resumes.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedStructuralDecision(verdict: VerdictGenerate),
      opts(),
    )
  assert writes == ["set:op.state"]
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(resolution: ModelResolved),
      opts(),
    )
  assert writes == ["set:op.state"]
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert Dispatch(
    intent: planner.SummaryProviderRequest(..),
    next: _,
    tx: request_tx,
  ) = action
  assert scenario.write_names(request_tx) == ["set:op.state"]
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedSummaryReturned(usage: fixture.usage_of(3000, 200)),
      opts(),
    )
  assert writes == ["insert:usage", "set:op.state"]
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedSummaryProgress(progress: SummaryProduced(
        summary: "a month of auth work",
        usage: None,
      )),
      opts(),
    )
  assert writes == ["insert:compaction", "set:strand.leaf", "set:op.state"]
  // 3. Resume: the retried request overflows again; the flag is already
  // spent, so the run drains as failed instead of compacting in a loop.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes == ["set:op.state"]
  let assert Ok(#(world, action)) = scenario.step(world, admitted(), opts())
  let assert Dispatch(intent: planner.ProviderRequest(..), ..) = action
  let second =
    fixture.assistant_error("context window exceeded: still too big", False)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(second),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(phase: operation.FailureDrain(error:, ..), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert error.code == "context_overflow"
  // 4. No recovering input: the run finishes failed; the terminal
  // transaction also clears the leftover preparation registers.
  let assert Ok(#(_world, action)) = scenario.step(world, NoObservation, opts())
  let assert Finish(
    result: RunLastResult(outcome: RunFailed(..), ..),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "del:op.meta", "del:op.state", "del:op.preparation",
      "set:strand.last_result", "set:strand.state",
    ]
}

pub fn abort_normalizes_settlement_test() {
  let world = start_run("long research task")
  // Durable cancellation lands while the request is in flight.
  let assert Ok(state) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(op_state_seq, _)) =
    store.get_register(
      world.store,
      register.OpState,
      ids.op_id_to_string(world.op.id),
    )
  let assert queue.AbortPlanned(
    next: _,
    tx: abort_tx,
    drained_steer: [],
    drained_follow_up: [],
  ) = queue.request_abort(world.op, state, op_state_seq, scenario.now(world))
  let assert Ok(aborted_store) = store.apply(world.store, abort_tx)
  let world = World(..world, store: aborted_store)
  // The raced real settlement commits normalized to aborted, in the same
  // transaction as the cancelled control state (pi invariant 19).
  let finished = fixture.assistant(message.Stop, "partial answer", 10)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(finished),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(
    control: operation.CancelRequested(..),
    phase: Checkpoint(checkpoint:),
    latest_assistant: Some(aborted_id),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  let assert MayFinish(include_final_assistant: True) = checkpoint.continuation
  let assert Ok(entry.MessageEntry(
    message: message.AssistantMessage(stop_reason: message.Aborted, ..),
    ..,
  )) = store.get_entry(world.store, ids.entry_id_to_string(aborted_id))
  // Reconciliation finishes aborted and deletes the drained payloads.
  let assert Ok(#(_world, action)) = scenario.step(world, NoObservation, opts())
  let assert Finish(result: RunLastResult(outcome: RunAborted, ..), ..) = action
}
