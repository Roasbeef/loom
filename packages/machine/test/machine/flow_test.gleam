//// Flow tests beyond the three worked examples: deferred suspension and
//// polling, steering consumption with `skip_inbox_once`, threshold
//// compaction (decline and empty-preparation dedup), navigation, and
//// standalone compaction.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/option.{None, Some}
import machine/acceptance.{AcceptCompaction, AcceptNavigation, AcceptRun}
import machine/operation.{
  AwaitingDeferred, Checkpoint, Compacting, CompactionLastResult, Deciding,
  DeferredSuspended, NavigationLastResult, NeedAssistant, PendingMessage,
  ReplaySafe, RunState, StructuralCompleted, StructuralDeclined, ThresholdReason,
}
import machine/planner.{
  Admitted, AwaitEffect, Dispatch, EmptyPreparation, Finish, ModelResolved,
  NoObservation, ObservedAdmission, ObservedAssistantSettled,
  ObservedDeferredSettled, ObservedResolution, ObservedRunEnd, ObservedRunStart,
  ObservedStructuralDecision, ObservedSummaryProgress, ObservedSummaryReturned,
  Prepared, SummaryProduced, ThresholdExceeded, VerdictDeclined, VerdictGenerate,
  VerdictSupplied, Wait,
}
import machine/queue
import support/fixture
import support/scenario.{type World, StepOptions, World}
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

pub fn deferred_suspend_poll_resume_test() {
  let world = start_run("run this as a batch job")
  // Settlement classifies deferred with a valid handle: suspended poll 0.
  let deferred = fixture.assistant_deferred(Some(fixture.handle("job-7")))
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(deferred),
        overflow_preparation: None,
      ),
      opts(),
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(
    phase: AwaitingDeferred(deferred: DeferredSuspended(poll: 0, ..)),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  // Without a poll permit the strand waits durably.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert Wait(until: planner.DeferredPollDue(..)) = action
  // With a permit, identity resolution precedes the fresh poll intent.
  let permit = StepOptions(..opts(), poll_permit: True)
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, permit)
  let assert AwaitEffect(key: planner.PollAdmissionKey(poll: 1, ..)) = action
  let assert Ok(#(world, action)) =
    scenario.step(world, ObservedResolution(resolution: ModelResolved), permit)
  let assert Dispatch(
    intent: planner.DeferredFetch(poll: 1, ..),
    next: _,
    tx: poll_tx,
  ) = action
  assert scenario.write_names(poll_tx) == ["set:op.state"]
  // A pending response with a completely equal handle re-suspends and
  // becomes the next source, at the same poll count.
  let still_pending = fixture.assistant_deferred(Some(fixture.handle("job-7")))
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedDeferredSettled(settled: fixture.settled(still_pending)),
      permit,
    )
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  let assert Ok(RunState(
    phase: AwaitingDeferred(deferred: DeferredSuspended(
      poll: 1,
      source_entry:,
      ..,
    )),
    latest_assistant: Some(latest),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  assert source_entry == latest
  // A ready response without calls checkpoints toward finish.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, permit)
  let assert AwaitEffect(key: planner.PollAdmissionKey(poll: 2, ..)) = action
  let assert Ok(#(world, action)) =
    scenario.step(world, ObservedResolution(resolution: ModelResolved), permit)
  let assert Dispatch(intent: planner.DeferredFetch(poll: 2, ..), ..) = action
  let ready = fixture.assistant(message.Stop, "batch finished", 30)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedDeferredSettled(settled: fixture.settled(ready)),
      permit,
    )
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.RunEndKey(..)) = action
  let assert Ok(#(_world, action)) =
    scenario.step(world, ObservedRunEnd(follow_up: None), opts())
  let assert Finish(result: _, tx: _) = action
}

pub fn poll_handle_mismatch_drains_as_failure_test() {
  let world = start_run("batch")
  let deferred = fixture.assistant_deferred(Some(fixture.handle("job-a")))
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(deferred),
        overflow_preparation: None,
      ),
      opts(),
    )
  let permit = StepOptions(..opts(), poll_permit: True)
  let assert Ok(#(world, _action)) = scenario.step(world, NoObservation, permit)
  let assert Ok(#(world, _action)) =
    scenario.step(world, ObservedResolution(resolution: ModelResolved), permit)
  // The poll returns pending under a different handle id: normalized to
  // a durable error and drained as a failure.
  let mismatched = fixture.assistant_deferred(Some(fixture.handle("job-b")))
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedDeferredSettled(settled: fixture.settled(mismatched)),
      permit,
    )
  let assert Ok(RunState(phase: operation.FailureDrain(error:, ..), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert error.code == "deferred_handle_mismatch"
}

pub fn steer_consumed_at_checkpoint_with_skip_test() {
  let world = start_run("build the feature")
  // A steer item lands while the request is in flight.
  let assert Ok(state) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(seq, _)) =
    store.get_register(
      world.store,
      register.OpState,
      ids.op_id_to_string(world.op.id),
    )
  let assert Ok(plan) =
    queue.enqueue_steer(
      world.op,
      state,
      seq,
      ids_generator(world),
      PendingMessage(message: fixture.user("also update the docs")),
    )
  let assert Ok(steered_store) = store.apply(world.store, plan.tx)
  let world = World(..world, store: steered_store)
  // Settlement without calls: may_finish, but the steer is pending.
  let answer = fixture.assistant(message.Stop, "done with phase one", 20)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  // Checkpoint step 2 consumes the steer item: entry placed, pending
  // register deleted, need_assistant with skip_inbox_once.
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
  assert checkpoint.skip_inbox_once == True
  assert checkpoint.trigger == plan.entry
}

pub fn threshold_decline_marks_boundary_test() {
  let world = start_run("keep going")
  let answer = fixture.assistant_calls(["bash"])
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(#(world, _action)) = scenario.step(world, NoObservation, opts())
  let assert Ok(#(world, _action)) =
    scenario.step(
      world,
      planner.ObservedToolCleared(
        source_index: 1,
        effective_arguments: json.Object([]),
        replay: ReplaySafe,
      ),
      opts(),
    )
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      planner.ObservedToolSettled(
        source_index: 1,
        result: fixture.tool_result("call_bash_0", "bash", "ok"),
        terminate: False,
      ),
      opts(),
    )
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, NoObservation, opts())
  // The next checkpoint pass crosses the threshold; the preparation is
  // built and the decision hook declines: the marked resume checkpoint
  // restores and the same boundary is never rechecked.
  let exceeded =
    StepOptions(
      ..opts(),
      threshold: ThresholdExceeded(
        outcome: Prepared(preparation: fixture.preparation()),
      ),
    )
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, exceeded)
  assert writes == ["set:op.preparation", "set:op.state"]
  let assert Ok(RunState(
    phase: Compacting(reason: ThresholdReason, structural: Deciding(..), ..),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedStructuralDecision(verdict: VerdictDeclined),
      exceeded,
    )
  assert writes == ["set:op.state"]
  let assert Ok(RunState(phase: Checkpoint(checkpoint:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert checkpoint.threshold_checked == Some(checkpoint.trigger)
  // Even with the threshold still exceeded, the marked boundary skips
  // the check and generation starts.
  let assert Ok(#(_world, action)) =
    scenario.step(world, NoObservation, exceeded)
  let assert planner.Transition(
    next: RunState(phase: operation.Assistant(..), ..),
    ..,
  ) = action
}

pub fn threshold_empty_preparation_marks_boundary_test() {
  let world = start_run("noop threshold")
  let answer = fixture.assistant(message.Stop, "ok", 5)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  let empty =
    StepOptions(
      ..opts(),
      threshold: ThresholdExceeded(outcome: EmptyPreparation),
    )
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, empty)
  // Empty preparation: the boundary is marked checked, nothing else.
  assert writes == ["set:op.state"]
  let assert Ok(RunState(phase: Checkpoint(checkpoint:), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  assert checkpoint.threshold_checked == Some(checkpoint.trigger)
}

pub fn standalone_compaction_generated_test() {
  let world = scenario.fresh()
  let assert Ok(#(world, accept_tx)) =
    scenario.accept(
      world,
      AcceptCompaction(
        custom_instructions: Some("be brief"),
        preparation: Some(fixture.preparation()),
      ),
    )
  assert scenario.write_names(accept_tx)
    == ["set:op.preparation", "set:op.meta", "set:op.state", "set:strand.state"]
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedStructuralDecision(verdict: VerdictGenerate),
      opts(),
    )
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedResolution(resolution: ModelResolved),
      opts(),
    )
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert Dispatch(intent: planner.SummaryProviderRequest(..), ..) = action
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedSummaryReturned(usage: fixture.usage_of(2000, 150)),
      opts(),
    )
  // Publication is the terminal transaction, with the compaction entry
  // and leaf move inline.
  let assert Ok(#(world, action)) =
    scenario.step(
      world,
      ObservedSummaryProgress(progress: SummaryProduced(
        summary: "the story so far",
        usage: None,
      )),
      opts(),
    )
  let assert Finish(
    result: CompactionLastResult(outcome: StructuralCompleted, ..),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "insert:compaction", "set:strand.leaf", "del:op.meta", "del:op.state",
      "del:op.preparation", "set:strand.last_result", "set:strand.state",
    ]
  assert store.list_register_keys(world.store, register.OpPreparation, "") == []
}

pub fn standalone_compaction_declined_test() {
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(
      world,
      AcceptCompaction(
        custom_instructions: None,
        preparation: Some(fixture.preparation()),
      ),
    )
  let assert Ok(#(_world, action)) =
    scenario.step(
      world,
      ObservedStructuralDecision(verdict: VerdictDeclined),
      opts(),
    )
  let assert Finish(
    result: CompactionLastResult(outcome: StructuralDeclined, ..),
    tx: _,
  ) = action
}

pub fn unsummarized_navigation_completes_in_one_transaction_test() {
  // Build some history first so a navigation target exists.
  let world = start_run("first turn")
  let answer = fixture.assistant(message.Stop, "done", 5)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(#(world, action)) =
    scenario.step(world, ObservedRunEnd(follow_up: None), opts())
  let assert Finish(result: _, tx: _) = action
  // Navigate back to the prompt entry.
  let assert [prompt_id, ..] = world.op.intent |> prompt_ids
  let assert Ok(#(world, accept_tx)) =
    scenario.accept(
      world,
      AcceptNavigation(
        target: Some(prompt_id),
        summarize: False,
        label: Some("prompt"),
        custom_instructions: None,
        preparation: None,
        target_known: True,
      ),
    )
  assert scenario.write_names(accept_tx)
    == ["set:op.meta", "set:op.state", "set:strand.state"]
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert Finish(
    result: NavigationLastResult(
      outcome: StructuralCompleted,
      summary: None,
      ..,
    ),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "set:strand.leaf", "set:fact.label", "del:op.meta", "del:op.state",
      "set:strand.last_result", "set:strand.state",
    ]
  // The leaf moved to the target.
  let assert Ok(#(_seq, leaf_value)) =
    store.get_register(world.store, register.StrandLeaf, "main")
  assert register.read_leaf(leaf_value) == Ok(Some(prompt_id))
}

pub fn summarized_navigation_publishes_summary_test() {
  let world = start_run("explore an approach")
  let answer = fixture.assistant(message.Stop, "explored", 5)
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(answer),
        overflow_preparation: None,
      ),
      opts(),
    )
  let assert Ok(#(world, action)) =
    scenario.step(world, ObservedRunEnd(follow_up: None), opts())
  let assert Finish(result: _, tx: _) = action
  let assert [prompt_id, ..] = world.op.intent |> prompt_ids
  let assert Ok(#(world, _accept_tx)) =
    scenario.accept(
      world,
      AcceptNavigation(
        target: Some(prompt_id),
        summarize: True,
        label: None,
        custom_instructions: None,
        preparation: Some(operation.BranchSummaryPreparation(
          messages: [fixture.user("explored")],
          file_ops: operation.FileOperations(read: [], written: [], edited: []),
          total_tokens: 50,
        )),
        target_known: True,
      ),
    )
  // Hook supplies the summary directly: one terminal transaction with
  // the leaf move, summary entry, and second leaf move inline.
  let assert Ok(#(world, action)) =
    scenario.step(
      world,
      ObservedStructuralDecision(verdict: VerdictSupplied(
        summary: "tried an approach; kept the prompt",
        usage: None,
      )),
      opts(),
    )
  let assert Finish(
    result: NavigationLastResult(
      outcome: StructuralCompleted,
      summary: Some(summary_id),
      ..,
    ),
    tx: terminal_tx,
  ) = action
  assert scenario.write_names(terminal_tx)
    == [
      "set:strand.leaf", "insert:branch_summary", "set:strand.leaf",
      "del:op.meta", "del:op.state", "del:op.preparation",
      "set:strand.last_result", "set:strand.state",
    ]
  // The summary entry is parented on the target and is the new leaf.
  let assert Ok(entry.BranchSummaryEntry(parent: Some(parent), from_id:, ..)) =
    store.get_entry(world.store, ids.entry_id_to_string(summary_id))
  assert parent == prompt_id
  let assert Some(source_leaf) = world.op.source_leaf
  assert from_id == Some(source_leaf)
  let assert Ok(#(_seq, leaf_value)) =
    store.get_register(world.store, register.StrandLeaf, "main")
  assert register.read_leaf(leaf_value) == Ok(Some(summary_id))
}

fn prompt_ids(intent: operation.OperationIntent) -> List(ids.EntryId) {
  case intent {
    operation.RunIntent(prompt_entries:) -> prompt_entries
    _ -> []
  }
}

fn ids_generator(world: World) -> ids.Generator {
  ids.generator(clock.fixed(at: scenario.now(world)), seed: 424_242)
}
