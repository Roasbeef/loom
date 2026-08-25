//// Failure-path flows: retry waits, failure-drain recovery through new
//// user-context input, truncated tool batches, orphaned requests,
//// aborts during structural work, and the reason-gated survival of an
//// in-run compaction whose summarizer failed.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/option.{None, Some}
import machine/acceptance.{AcceptCompaction, AcceptRun}
import machine/operation.{
  Assistant, Checkpoint, Compacting, CompactionLastResult,
  ConfigurationProvenance, Deciding, FailureDrain, GenerationRetryWait,
  NeedAssistant, OperationError, OverflowReason, PendingMessage, RunCompleted,
  RunLastResult, RunState, StructuralAborted, ThresholdReason, Tools,
}
import machine/planner.{
  Admitted, AwaitEffect, Dispatch, Finish, ModelResolved, ModelUnresolved,
  NoObservation, ObservedAdmission, ObservedAssistantOrphaned,
  ObservedAssistantSettled, ObservedResolution, ObservedRunEnd, ObservedRunStart,
  ObservedStructuralDecision, ObservedSummaryProgress, ObservedSummaryReturned,
  Prepared, SummaryFailed, ThresholdExceeded, VerdictGenerate,
}
import machine/queue
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
    api: "acme-api",
  ))
}

fn start_run(prompt: String) -> World {
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user(prompt)]))
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, ObservedRunStart(messages: []), opts())
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, NoObservation, opts())
  let assert Ok(#(world, _action)) = scenario.step(world, admitted(), opts())
  world
}

pub fn retry_then_failure_drain_recovers_on_steer_test() {
  let world = start_run("flaky provider")
  // Attempt 1 settles as a retryable error: the response entry and its
  // usage row are durable, and the run waits for attempt 2.
  let error = fixture.assistant_error("overloaded", True)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(error),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(
    phase: Assistant(generation: GenerationRetryWait(next_attempt: 2, ..)),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  // The wait elapses (driver time advances past not_before): ready again,
  // then intent for attempt 2.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes == ["set:op.state"]
  let assert Ok(#(world, action)) = scenario.step(world, admitted(), opts())
  let assert Dispatch(intent: planner.ProviderRequest(attempt: 2, ..), ..) =
    action
  // Attempt 2 fails terminally: failure drain with response provenance.
  let fatal = fixture.assistant_error("invalid request", False)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(fatal),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(RunState(phase: operation.FailureDrain(..), ..) as drained) =
    scenario.read_op_state(world.store, world.op.id)
  // A steer item arrives during the drain; consuming it clears the
  // failure into a need_assistant checkpoint.
  let assert Ok(#(seq, _value)) =
    store.get_register(
      world.store,
      register.OpState,
      ids.op_id_to_string(world.op.id),
    )
  let assert Ok(plan) =
    queue.enqueue_steer(
      world.op,
      drained,
      seq,
      ids.generator(clock.fixed(at: scenario.now(world)), seed: 31),
      PendingMessage(message: fixture.user("try a different approach")),
    )
  let assert Ok(steered) = store.apply(world.store, plan.tx)
  let world = World(..world, store: steered)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes
    == [
      "insert:message",
      "del:pending.entry",
      "set:strand.leaf",
      "set:op.state",
    ]
  let assert Ok(RunState(phase: Checkpoint(checkpoint:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert NeedAssistant(overflow_recovery_used: False) =
    checkpoint.continuation
}

pub fn failure_drain_without_input_finishes_failed_test() {
  let world = start_run("doomed")
  let fatal = fixture.assistant_error("invalid request", False)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(fatal),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(#(_world, action)) = scenario.step(world, NoObservation, opts())
  let assert Finish(
    result: RunLastResult(outcome: operation.RunFailed(error:), ..),
    tx: _,
  ) = action
  assert error.code == "provider_error"
}

pub fn orphaned_request_retries_with_partial_test() {
  let world = start_run("interrupted")
  // The continuation is lost mid-request; recovery commits a synthetic
  // zero-usage error under the reserved ids carrying the partial, then
  // ordinary classification retries.
  let partial = [
    message.AssistantText(text: "half an answ", text_signature: None),
  ]
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, ObservedAssistantOrphaned(partial:), opts())
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(
    phase: Assistant(generation: GenerationRetryWait(next_attempt: 2, ..)),
    latest_assistant: Some(synthetic_id),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  // The synthetic settlement is an error carrying the committed partial
  // and api "unknown" with the captured identity.
  let assert Ok(entry.MessageEntry(
    message: message.AssistantMessage(
      stop_reason: message.Errored,
      api: "unknown",
      provider: "acme",
      content: [message.AssistantText(text: "half an answ", ..)],
      usage:,
      ..,
    ),
    ..,
  )) = store.get_entry(world.store, ids.entry_id_to_string(synthetic_id))
  assert usage.total_tokens == 0
}

pub fn truncated_batch_stages_synthetic_errors_test() {
  let world = start_run("truncated calls")
  // A genuine length stop that still carries calls: the full plan
  // commits, nothing executes, and each call gets an error result
  // demanding another turn.
  let calls = fixture.assistant_calls(["bash"])
  let truncated = case calls {
    message.AssistantMessage(..) ->
      message.AssistantMessage(
        ..calls,
        stop_reason: message.Length,
        usage: fixture.usage_of(100, 5000),
      )
    other -> other
  }
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(truncated),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(RunState(phase: Tools(..), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  // No clearance is requested: the machine stages the synthetic result
  // directly.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes == ["set:pending.entry", "set:op.state"]
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, NoObservation, opts())
  // The batch completes into a need_assistant checkpoint — truncated
  // results require another assistant turn.
  let assert Ok(RunState(phase: Checkpoint(checkpoint:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert NeedAssistant(overflow_recovery_used: False) =
    checkpoint.continuation
}

pub fn abort_during_structural_deciding_finishes_aborted_test() {
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(
      world,
      AcceptCompaction(
        custom_instructions: None,
        preparation: Some(fixture.preparation()),
      ),
    )
  let assert Ok(state) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(seq, _value)) =
    store.get_register(
      world.store,
      register.OpState,
      ids.op_id_to_string(world.op.id),
    )
  let assert queue.AbortPlanned(next: _, tx: abort_tx, ..) =
    queue.request_abort(world.op, state, seq, scenario.now(world))
  let assert Ok(aborted) = store.apply(world.store, abort_tx)
  let world = World(..world, store: aborted)
  // Abort before any structural commit finishes aborted with nothing
  // published; the terminal transaction clears the preparation register.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert Finish(
    result: CompactionLastResult(outcome: StructuralAborted, ..),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "del:op.meta", "del:op.state", "del:op.preparation",
      "set:strand.last_result", "set:fact.custom", "set:strand.state",
    ]
  assert store.list_register_keys(world.store, register.OpPreparation, "") == []
}

// --- a summarizer that is down (issue #34) ---------------------------------

/// Drives a run to the point where a threshold compaction has crossed
/// into its structural lifecycle and the decision hook has asked for a
/// generated summary. The returned world is one observation away from
/// `structural_failure`.
fn threshold_compaction_generating(
  prompt: String,
) -> #(World, scenario.StepOptions) {
  let world = start_run(prompt)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(fixture.assistant(message.Stop, "ok", 5)),
        overflow_preparation: None,
      ),
      opts(),
    )
  let exceeded =
    scenario.StepOptions(
      ..opts(),
      threshold: ThresholdExceeded(
        outcome: Prepared(preparation: fixture.preparation()),
      ),
    )
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, NoObservation, exceeded)
  let assert Ok(RunState(
    phase: Compacting(reason: ThresholdReason, structural: Deciding(..), ..),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedStructuralDecision(verdict: VerdictGenerate),
      exceeded,
    )
  #(world, exceeded)
}

/// The same lifecycle entered from an overflowing generation request
/// rather than from the threshold.
fn overflow_compaction_generating(prompt: String) -> World {
  let world = start_run(prompt)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(fixture.assistant_error(
          "context window exceeded: too big",
          False,
        )),
        overflow_preparation: Some(Prepared(preparation: fixture.preparation())),
      ),
      opts(),
    )
  let assert Ok(RunState(
    phase: Compacting(reason: OverflowReason, structural: Deciding(..), ..),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedStructuralDecision(verdict: VerdictGenerate),
      opts(),
    )
  world
}

pub fn threshold_summarizer_unresolved_keeps_the_run_alive_test() {
  let #(world, exceeded) =
    threshold_compaction_generating("the summarizer is down")
  // The summary route does not resolve. The conversation is untouched,
  // so the run restores its checkpoint instead of draining.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(
        resolution: ModelUnresolved(error: OperationError(
          code: "model_unavailable",
          message: "no configured route resolves to a usable provider",
          details: None,
        )),
      ),
      exceeded,
    )
  assert writes == ["set:op.state"]
  let assert Ok(RunState(phase: Checkpoint(checkpoint:), settings:, ..)) =
    scenario.read_op_state(world.store, world.op.id)
  // The boundary stays marked, and threshold compaction is off for the
  // rest of this run so the next boundary cannot re-fire into the same
  // dead route.
  assert checkpoint.threshold_checked == Some(checkpoint.trigger)
  assert settings.compaction.enabled == False
  // Reserve and keep-recent survive: only the gate moved.
  assert settings.compaction.reserve_tokens
    == scenario.settings().compaction.reserve_tokens
  // The run carries straight on through its finish boundary, even with
  // the threshold still reporting exceeded, and ends *completed* rather
  // than failed.
  let assert Ok(#(world, action)) =
    scenario.step(world, NoObservation, exceeded)
  let assert AwaitEffect(key: planner.RunEndKey(..)) = action
  let assert Ok(#(_world, action)) =
    scenario.step(world, ObservedRunEnd(follow_up: None), exceeded)
  let assert Finish(result: RunLastResult(outcome: RunCompleted(..), ..), tx: _) =
    action
}

pub fn threshold_summary_failure_past_the_ladder_keeps_the_run_alive_test() {
  let #(world, exceeded) = threshold_compaction_generating("flaky summarizer")
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(resolution: ModelResolved),
      exceeded,
    )
  let assert Ok(#(world, action)) =
    scenario.step(world, NoObservation, exceeded)
  let assert Dispatch(intent: planner.SummaryProviderRequest(..), ..) = action
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedSummaryReturned(usage: fixture.usage_of(3000, 200)),
      exceeded,
    )
  // The attempt is over and not retryable: the ladder is exhausted.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedSummaryProgress(progress: SummaryFailed(
        error: OperationError(
          code: "summary_failed",
          message: "the summarizer attempted a tool call instead of summarizing",
          details: None,
        ),
        retryable: False,
      )),
      exceeded,
    )
  assert writes == ["set:op.state"]
  let assert Ok(RunState(phase: Checkpoint(..), settings:, ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert settings.compaction.enabled == False
}

pub fn overflow_summarizer_unresolved_still_drains_test() {
  let world = overflow_compaction_generating("an overflowing run")
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(
        resolution: ModelUnresolved(error: OperationError(
          code: "model_unavailable",
          message: "no configured route resolves to a usable provider",
          details: None,
        )),
      ),
      opts(),
    )
  assert writes == ["set:op.state"]
  // The request that overflowed still does not fit: this one drains.
  let assert Ok(RunState(phase: FailureDrain(error:, provenance:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert error.code == "model_unavailable"
  assert provenance == ConfigurationProvenance
}

pub fn threshold_context_overflow_still_drains_test() {
  let #(world, exceeded) = threshold_compaction_generating("a hopeless context")
  // Not every structural failure is about the summarizer. An error that
  // says the context itself does not fit leaves the run nowhere to go.
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(
        resolution: ModelUnresolved(error: OperationError(
          code: "context_overflow",
          message: "the conversation does not fit any configured route",
          details: None,
        )),
      ),
      exceeded,
    )
  assert writes == ["set:op.state"]
  let assert Ok(RunState(phase: FailureDrain(error:, ..), settings:, ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert error.code == "context_overflow"
  // A drained run never had its compaction gate touched.
  assert settings.compaction.enabled == True
}
