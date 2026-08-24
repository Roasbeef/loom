//// Failure-path flows: retry waits, failure-drain recovery through new
//// user-context input, truncated tool batches, orphaned requests, and
//// aborts during structural work.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/option.{None, Some}
import machine/acceptance.{AcceptCompaction, AcceptRun}
import machine/operation.{
  Assistant, Checkpoint, CompactionLastResult, GenerationRetryWait,
  NeedAssistant, PendingMessage, RunLastResult, RunState, StructuralAborted,
  Tools,
}
import machine/planner.{
  Admitted, Dispatch, Finish, NoObservation, ObservedAdmission,
  ObservedAssistantOrphaned, ObservedAssistantSettled, ObservedRunStart,
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
      "set:strand.last_result", "set:strand.state",
    ]
  assert store.list_register_keys(world.store, register.OpPreparation, "") == []
}
