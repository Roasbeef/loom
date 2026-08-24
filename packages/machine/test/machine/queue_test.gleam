//// Queue admission, cancellation triage, and the abort drain (pi §3.11).

import core/clock
import core/ids
import gleam/option.{None}
import machine/operation.{
  CancelRequested, Checkpoint, CheckpointPhase, Inbox, MayFinish, NeedAssistant,
  Operation, PendingMessage, RunIntent, RunState, Running,
}
import machine/queue.{
  AbortAlreadyRequested, AbortPlanned, CancelledNextRun, CancelledQueued,
  NextRunNotPending, NoActiveRun, NotPending, QueuePlan,
}
import machine/strand.{StrandState}
import support/fixture
import support/scenario

fn generator() -> ids.Generator {
  ids.generator(clock.fixed(at: 9000), seed: 5)
}

fn op() -> operation.Operation {
  let #(id, _generator) = ids.mint_op(generator())
  Operation(
    id:,
    strand: "main",
    source_leaf: None,
    started_at: 1,
    intent: RunIntent(prompt_entries: []),
  )
}

fn running_run(inbox: operation.Inbox) -> operation.OperationState {
  let #(trigger, _generator) = ids.mint_entry(generator())
  RunState(
    control: Running,
    settings: scenario.settings(),
    phase: Checkpoint(checkpoint: CheckpointPhase(
      continuation: MayFinish(include_final_assistant: True),
      trigger:,
      threshold_checked: None,
      skip_inbox_once: False,
    )),
    inbox:,
    latest_assistant: None,
  )
}

fn empty_inbox() -> operation.Inbox {
  Inbox(steer: [], follow_up: [], writes: [])
}

pub fn steer_enqueues_on_running_run_test() {
  let assert Ok(QueuePlan(entry:, next:, tx: plan_tx)) =
    queue.enqueue_steer(
      op(),
      running_run(empty_inbox()),
      7,
      generator(),
      PendingMessage(message: fixture.user("steer")),
    )
  let assert RunState(inbox: Inbox(steer: [queued], ..), ..) = next
  assert queued == entry
  assert scenario.write_names(plan_tx) == ["set:pending.entry", "set:op.state"]
}

pub fn steer_refused_under_cancellation_test() {
  let cancelled =
    RunState(
      control: CancelRequested(
        requested_at: 1,
        drained_steer: [],
        drained_follow_up: [],
      ),
      settings: scenario.settings(),
      phase: operation.Starting,
      inbox: empty_inbox(),
      latest_assistant: None,
    )
  assert queue.enqueue_steer(
      op(),
      cancelled,
      7,
      generator(),
      PendingMessage(message: fixture.user("late steer")),
    )
    == Error(NoActiveRun)
}

pub fn write_admitted_under_cancellation_test() {
  let cancelled =
    RunState(
      control: CancelRequested(
        requested_at: 1,
        drained_steer: [],
        drained_follow_up: [],
      ),
      settings: scenario.settings(),
      phase: operation.Starting,
      inbox: empty_inbox(),
      latest_assistant: None,
    )
  // Tree writes survive abort: admission succeeds even while cancelling.
  let assert Ok(QueuePlan(
    next: RunState(inbox: Inbox(writes: [_one], ..), ..),
    ..,
  )) =
    queue.enqueue_write(
      op(),
      cancelled,
      7,
      generator(),
      PendingMessage(message: fixture.user("write")),
    )
}

pub fn abort_drains_queues_without_deleting_payloads_test() {
  let #(steer_id, generator_2) = ids.mint_entry(generator())
  let #(follow_id, _generator) = ids.mint_entry(generator_2)
  let state =
    running_run(Inbox(steer: [steer_id], follow_up: [follow_id], writes: []))
  let assert AbortPlanned(
    next:,
    tx: abort_tx,
    drained_steer: [drained_steer],
    drained_follow_up: [drained_follow],
  ) = queue.request_abort(op(), state, 9, 12_345)
  assert drained_steer == steer_id
  assert drained_follow == follow_id
  // Only the control marker is written — no pending register dies here.
  assert scenario.write_names(abort_tx) == ["set:op.state"]
  let assert RunState(
    control: CancelRequested(drained_steer: [_], drained_follow_up: [_], ..),
    inbox: Inbox(steer: [], follow_up: [], writes: []),
    ..,
  ) = next
  // A repeat abort reuses the durable marker.
  let assert AbortAlreadyRequested(drained_steer: [_], drained_follow_up: [_]) =
    queue.request_abort(op(), next, 10, 99_999)
}

pub fn cancel_queued_triage_test() {
  let #(queued, _generator) = ids.mint_entry(generator())
  let state = running_run(Inbox(steer: [queued], follow_up: [], writes: []))
  let assert CancelledQueued(next:, tx: cancel_tx) =
    queue.cancel_queued(op(), state, 4, queued)
  assert scenario.write_names(cancel_tx)
    == ["set:op.state", "del:pending.entry"]
  let assert RunState(inbox: Inbox(steer: [], ..), ..) = next
  // A second cancellation finds nothing pending.
  assert queue.cancel_queued(op(), next, 5, queued) == NotPending
}

pub fn next_run_enqueue_and_cancel_test() {
  let strand_state = StrandState(current_operation: None, pending_next_run: [])
  let #(entry, next, plan_tx) =
    queue.enqueue_next_run(
      "main",
      strand_state,
      2,
      generator(),
      PendingMessage(message: fixture.user("later")),
    )
  assert scenario.write_names(plan_tx)
    == ["set:pending.entry", "set:strand.state"]
  assert next.pending_next_run == [entry]
  let assert CancelledNextRun(next: cleared, tx: cancel_tx) =
    queue.cancel_next_run("main", next, 3, entry)
  assert cleared.pending_next_run == []
  assert scenario.write_names(cancel_tx)
    == ["set:strand.state", "del:pending.entry"]
  assert queue.cancel_next_run("main", cleared, 4, entry) == NextRunNotPending
}

pub fn need_assistant_checkpoint_allows_steer_test() {
  // Steering is admitted in any running phase, including mid-generation
  // checkpoints; consumption timing is the checkpoint procedure's job.
  let #(trigger, _generator) = ids.mint_entry(generator())
  let state =
    RunState(
      control: Running,
      settings: scenario.settings(),
      phase: Checkpoint(checkpoint: CheckpointPhase(
        continuation: NeedAssistant(overflow_recovery_used: False),
        trigger:,
        threshold_checked: None,
        skip_inbox_once: True,
      )),
      inbox: empty_inbox(),
      latest_assistant: None,
    )
  let assert Ok(QueuePlan(..)) =
    queue.enqueue_follow_up(
      op(),
      state,
      3,
      generator(),
      PendingMessage(message: fixture.user("follow up")),
    )
}
