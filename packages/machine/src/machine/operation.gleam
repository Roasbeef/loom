//// The operation state space — a faithful transcription of pi's harness
//// spec Part 3 into Gleam ADTs, with pi's "lane" renamed to "strand".
////
//// An operation is one accepted unit of strand work: a run, compaction, or
//// navigation. Its immutable metadata (`Operation`) lives in the `op.meta`
//// register, written once at acceptance; its total current state
//// (`OperationState`) lives in `op.state`, replaced by every durable
//// transition and deleted by the terminal transaction. There is no
//// finished variant — an ended operation has no state at all, and its
//// outcome lives in `strand.last_result` (`LastResult` here).
////
//// The state is *total*: it never depends on a previous state, and
//// recovery reads exactly this value to decide where to resume. Small
//// captured values (configuration, stream options, retry policy) are
//// inline; large stable payloads live at sibling operation-owned registers
//// (`op.tool_args`, `op.preparation`, `pending.entry`) and are named by
//// deterministic keys or reserved ids.

import core/ids.{type EntryId, type OpId, type UsageId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/option.{type Option}
import machine/strand.{type StrandConfiguration}

// --- immutable acceptance metadata --------------------------------------

/// Immutable acceptance metadata — the `op.meta` register payload (pi
/// §3.1's `OperationMeta`; Loom's frozen contract names this `Operation`).
///
/// Constructor invariants: written exactly once at acceptance and deleted
/// only by the terminal transaction. `source_leaf` is the strand's leaf
/// *before* the operation — entries the operation appends come after it.
/// `started_at` is the acceptance time in Unix ms.
pub type Operation {
  Operation(
    id: OpId,
    strand: String,
    source_leaf: Option(EntryId),
    started_at: Int,
    intent: OperationIntent,
  )
}

/// What the operation was accepted to do.
///
/// Constructor invariants: `RunIntent.prompt_entries` name the caller's
/// normalized prompt entries, born placed in the acceptance transaction —
/// captured next-run items and hook injections are not acceptance
/// metadata. `NavigationIntent.target` is `None` for the root; `summarize`
/// requires a non-null target and a non-null source leaf (validated before
/// acceptance).
pub type OperationIntent {
  /// A conversational run.
  RunIntent(prompt_entries: List(EntryId))
  /// A standalone compaction.
  CompactionIntent(custom_instructions: Option(String))
  /// A leaf move, optionally summarizing the abandoned branch.
  NavigationIntent(
    target: Option(EntryId),
    summarize: Bool,
    label: Option(String),
    custom_instructions: Option(String),
  )
}

// --- shared control and error vocabulary --------------------------------

/// Durable cancellation control, shared by every operation kind.
///
/// Constructor invariants: the first abort commits `CancelRequested`,
/// moving current steer/follow-up ids into the drained lists and emptying
/// the inbox lists — the drained ids' `pending.entry` registers survive the
/// drain and are deleted only by the terminal transaction (pi §3.11,
/// §3.13). Cancellation is never un-requested.
pub type Control {
  /// No cancellation requested.
  Running
  /// Cancellation is durable; reconciliation is next.
  CancelRequested(
    requested_at: Int,
    drained_steer: List(EntryId),
    drained_follow_up: List(EntryId),
  )
}

/// A durable, in-band operation error (pi's `OperationError`).
///
/// Constructor invariants: `code` is a stable machine-readable identifier
/// (`"model_unavailable"`, `"configured_tools_unavailable"`,
/// `"provider_error"`, `"context_overflow"`, ...); `message` is for
/// humans; `details` is opaque structured context.
pub type OperationError {
  OperationError(code: String, message: String, details: Option(JsonValue))
}

/// Where a run failure came from (pi §3.2 `failure_drain` provenance).
pub type FailureProvenance {
  /// A settled response entry carries the failure.
  ResponseProvenance(entry: EntryId)
  /// A structural (summary) task failed; the task id locates its
  /// preparation register.
  StructuralProvenance(task_id: String)
  /// Captured configuration could not be resolved at an effect-admission
  /// boundary; no response or usage was fabricated.
  ConfigurationProvenance
}

// --- run settings --------------------------------------------------------

/// Queue drain mode (pi's `QueueMode`): wire forms `"all"` and
/// `"one-at-a-time"`.
pub type QueueMode {
  /// A drain point consumes every currently eligible item in acceptance
  /// order.
  ConsumeAll
  /// A drain point consumes only the oldest eligible item and leaves the
  /// rest pending.
  OneAtATime
}

/// Whether a tool batch executes calls one at a time or concurrently.
pub type ToolExecution {
  /// Clear, execute, and materialize one call at a time in source order.
  Sequential
  /// Clear and commit intents in source order; effects settle
  /// independently; tree materialization stays source ordered.
  Parallel
}

/// Threshold-compaction settings captured into a run at acceptance.
///
/// Constructor invariants: both token counts are non-negative; validated
/// at set time by whoever publishes the settings, trusted here.
pub type CompactionSettings {
  CompactionSettings(
    enabled: Bool,
    reserve_tokens: Int,
    keep_recent_tokens: Int,
  )
}

/// The run-scoped settings snapshot, captured atomically at acceptance
/// (pi §3.2): later global setter calls affect later operations only.
pub type RunSettings {
  RunSettings(
    compaction: CompactionSettings,
    steering_mode: QueueMode,
    follow_up_mode: QueueMode,
    tool_execution: ToolExecution,
  )
}

/// The provider retry policy in normalized form (pi §0.7): `max_attempts`
/// is at least 1 (disabled retry normalizes to one attempt);
/// `base_delay_ms` is non-negative. Exponential delay saturates rather
/// than overflowing.
pub type NormalizedRetryPolicy {
  NormalizedRetryPolicy(max_attempts: Int, base_delay_ms: Int)
}

// --- the operation state -------------------------------------------------

/// The `op.state` register payload: one total durable restart point,
/// replaced by every transition (design doc §3.2, pi §3.2).
///
/// Constructor invariants: the constructor kind is compatible with the
/// operation's intent kind (run/compaction/navigation) — a mismatch is
/// corruption. There is no terminal constructor: the terminal transaction
/// deletes the register instead.
pub type OperationState {
  /// A run: settings snapshot, current phase, inbox, and the newest
  /// durable assistant response id in this operation.
  RunState(
    control: Control,
    settings: RunSettings,
    phase: RunPhase,
    inbox: Inbox,
    latest_assistant: Option(EntryId),
  )
  /// A standalone compaction operation.
  CompactionState(
    control: Control,
    custom_instructions: Option(String),
    structural: StructuralDecision,
  )
  /// A navigation operation.
  NavigationState(control: Control, navigation: Navigation)
}

/// The run inbox: reserved entry ids only — payloads (and, for writes,
/// the entry type and custom type) live at `pending.entry/{id}` (pi §3.2).
///
/// Constructor invariants: lists are in acceptance order; an id appears in
/// at most one queue; at every commit boundary a queued id has its pending
/// register (pending or drained), its entry (consumed), or neither
/// (cancelled) — never both.
pub type Inbox {
  Inbox(steer: List(EntryId), follow_up: List(EntryId), writes: List(EntryId))
}

/// The run's current phase (pi §3.2 `RunPhase`).
pub type RunPhase {
  /// Durably accepted, awaiting its first drive's run-start hook output.
  /// Payload-free by construction: the consuming transition replaces it
  /// with a checkpoint.
  Starting
  /// Between steps: the queue-drain / threshold / generate / finish
  /// decision point (pi §3.12).
  Checkpoint(checkpoint: CheckpointPhase)
  /// An assistant generation step.
  Assistant(generation: Generation)
  /// A tool batch produced by the newest assistant response.
  Tools(batch: ToolBatch)
  /// An in-run compaction (threshold or overflow). `resume_after` stores
  /// the checkpoint to restore on success or threshold decline, already
  /// marked threshold-checked so the same boundary is never rechecked.
  Compacting(
    reason: CompactionReason,
    structural: StructuralDecision,
    resume_after: CheckpointPhase,
  )
  /// Suspended on (or polling) a provider-side deferred response.
  AwaitingDeferred(deferred: DeferredState)
  /// A terminal failure is draining the inbox: accepted writes and queued
  /// input are applied; projecting user-context input clears the failure,
  /// otherwise the run finishes failed (pi §3.12).
  FailureDrain(error: OperationError, provenance: FailureProvenance)
}

/// Why an in-run compaction started.
pub type CompactionReason {
  /// The context-size check at a checkpoint crossed the threshold.
  ThresholdReason
  /// A provider request did not fit; recovery is one-shot per consumed
  /// input (the `NeedAssistant` flag).
  OverflowReason
}

/// A checkpoint: the durable decision point between steps (pi §3.2).
///
/// Constructor invariants: `trigger` names an existing entry — the newest
/// appended entry that caused this boundary. `threshold_checked` carries
/// the trigger id whose threshold-compaction check already ran, so one
/// boundary is checked at most once. `skip_inbox_once` makes the next
/// checkpoint pass skip queue draining and generate first, so a crash
/// cannot turn a one-at-a-time drain into an all-item drain.
pub type CheckpointPhase {
  CheckpointPhase(
    continuation: Continuation,
    trigger: EntryId,
    threshold_checked: Option(EntryId),
    skip_inbox_once: Bool,
  )
}

/// What the checkpoint owes next (pi §3.2 `Continuation`).
pub type Continuation {
  /// Another assistant turn is required. `overflow_recovery_used` is the
  /// one-shot overflow flag: `True` only after an overflow compaction, and
  /// reset to `False` by any transition that appends projecting
  /// conversational input or tool results (pi invariant 18).
  NeedAssistant(overflow_recovery_used: Bool)
  /// The run may finish if the inbox stays empty.
  /// `include_final_assistant` is `True` when the boundary was a settled
  /// assistant response and `False` for an all-terminating tool batch.
  MayFinish(include_final_assistant: Bool)
}

// --- assistant generation -------------------------------------------------

/// The captured context of one generation step (pi §3.2
/// `GenerationContext`).
///
/// Constructor invariants: `configuration`, `stream_options`, and `retry`
/// are inline snapshots taken when the step entered `ready` — recovery
/// retains the exact identities selected for the step even when their
/// current implementations are unavailable. `stream_options` is an opaque
/// provider-facing options bag owned by the runtime; the machine persists
/// it untouched. `overflow_recovery_used` is copied from the producing
/// checkpoint's `NeedAssistant` continuation so a settlement classified
/// after crash-restore still knows whether overflow recovery was spent.
pub type GenerationContext {
  GenerationContext(
    step_id: String,
    trigger: EntryId,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
    retry: NormalizedRetryPolicy,
    overflow_recovery_used: Bool,
  )
}

/// One assistant generation step (pi §3.2 `Generation`).
///
/// Constructor invariants: `GenerationEffectPending` reserves the response
/// entry id and usage id minted at intent — settlement writes under
/// exactly those ids, and synthetic recovery settlements do too.
/// `intended_output_limit` and `context_window` are persisted in the
/// intent so overflow classification is stable across recovery, and
/// `request_api` is the resolved adapter api the request was admitted
/// against — deferred-handle validity compares against this captured
/// value, never against the api the response reports about itself
/// (review finding ORCH-L4). `GenerationRetryWait.not_before` is the
/// Unix-ms wake time.
pub type Generation {
  /// Snapshot taken; the pre-request hook and identity resolution are
  /// next. Attempt numbering starts at 1.
  GenerationReady(context: GenerationContext, next_attempt: Int)
  /// A provider request is in flight (or orphaned): the one genuinely
  /// uncertain window.
  GenerationEffectPending(
    context: GenerationContext,
    attempt: Int,
    response_entry: EntryId,
    usage: UsageId,
    intended_output_limit: Int,
    context_window: Int,
    request_api: String,
  )
  /// A retryable failure settled; the next attempt starts at `not_before`.
  GenerationRetryWait(
    context: GenerationContext,
    next_attempt: Int,
    not_before: Int,
    error_message: String,
  )
}

// --- tool batches ---------------------------------------------------------

/// Whether re-executing an interrupted tool call is acceptable.
pub type ReplayPolicy {
  /// Never re-execute: recovery synthesizes an interrupted result under
  /// the reserved id instead.
  ReplayNever
  /// Safe to re-execute with the persisted arguments.
  ReplaySafe
}

/// The tool batch produced by one assistant response (pi §3.2
/// `ToolBatch`).
///
/// Constructor invariants: `assistant_entry` names the producing response;
/// each call's source call comes from that entry's message content at the
/// call's `source_index`. `configuration` is the producing generation's
/// snapshot — active tool names come from here. `turn_id` is the
/// producing generation's step id. `calls` are in source order.
pub type ToolBatch {
  ToolBatch(
    assistant_entry: EntryId,
    configuration: StrandConfiguration,
    turn_id: String,
    calls: List(ToolCallState),
  )
}

/// One tool call's durable status (pi §3.2 `ToolCall`).
///
/// Constructor invariants: `source_index` is the zero-based index into the
/// assistant message's complete content array, and the indexed block is a
/// tool call. `result_entry` is reserved at plan time as a follower of the
/// assistant id. Completed calls form a source-ordered prefix; in
/// sequential mode the suffix has at most one effect-pending or
/// outcome-ready call before planned calls; in parallel mode the suffix
/// may mix planned, effect-pending, and outcome-ready. An outcome-ready
/// call has its complete finalized result staged at
/// `pending.entry/{result_entry}` and never executes again.
pub type ToolCallState {
  /// Planned; clearance has not passed yet.
  CallPlanned(source_index: Int, result_entry: EntryId)
  /// The effect is (or may be) running; `replay` was declared at intent.
  CallEffectPending(
    source_index: Int,
    result_entry: EntryId,
    replay: ReplayPolicy,
  )
  /// The finalized result is staged, awaiting source-ordered placement.
  CallOutcomeReady(source_index: Int, result_entry: EntryId, terminate: Bool)
  /// The result entry is in the tree.
  CallCompleted(source_index: Int, result_entry: EntryId, terminate: Bool)
}

// --- deferred responses ---------------------------------------------------

/// A run suspended on (or polling) a provider-side deferred response (pi
/// §3.2 `Deferred`).
///
/// Constructor invariants: `source_entry` names the newest response whose
/// deferred handle is being polled. `poll` counts completed polls; a fresh
/// intent uses `poll + 1`, and an unknown-outcome poll is replaced at the
/// *same* poll number. `configuration` and `stream_options` are copied
/// from the original generation's context — current global settings do not
/// affect polls.
pub type DeferredState {
  /// Waiting for a poll permit.
  DeferredSuspended(
    step_id: String,
    source_entry: EntryId,
    poll: Int,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
  /// One fetch is in flight (or orphaned) under reserved response/usage
  /// ids.
  DeferredEffectPending(
    step_id: String,
    source_entry: EntryId,
    poll: Int,
    response_entry: EntryId,
    usage: UsageId,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
}

// --- structural work (summaries) ------------------------------------------

/// The deciding/generating machinery shared by compactions and navigation
/// summaries (pi §3.2 "Structural work").
///
/// Constructor invariants: `task_id` locates the write-once
/// `op.preparation/{op}:{task_id}` register committed together with the
/// `Deciding` state; reopen never rebuilds preparation from current
/// settings. A durable `Generating` decision prevents the decision hook
/// from ever rerunning.
pub type StructuralDecision {
  /// The decision hook has not durably decided yet (it may rerun after a
  /// crash).
  Deciding(task_id: String)
  /// The hook selected generation; the summary generator owns the rest.
  Generating(task_id: String, generation: SummaryGeneration)
}

/// Which structural artifact is being generated.
pub type SummaryKind {
  /// A compaction entry.
  CompactionSummary
  /// A branch-summary entry.
  BranchSummary
}

/// Why the summary was requested (pi `SummaryContext.reason`).
pub type SummaryReason {
  /// The caller asked (standalone compaction).
  ManualSummary
  /// A checkpoint threshold check asked.
  ThresholdSummary
  /// An overflow recovery asked.
  OverflowSummary
}

/// The captured context of one summary generation (pi §3.2
/// `SummaryContext`).
///
/// Constructor invariants: as for `GenerationContext` — inline snapshots
/// taken when the hook selected generation. `result_entry` is the reserved
/// id the published compaction/branch-summary entry will use.
pub type SummaryContext {
  SummaryContext(
    task_id: String,
    result_entry: EntryId,
    kind: SummaryKind,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
    retry: NormalizedRetryPolicy,
    reason: SummaryReason,
  )
}

/// One nested provider-request intent inside a structural attempt.
///
/// Constructor invariants: `index` is the zero-based request index across
/// the operation's structural requests; `usage` is the reserved ledger id
/// the request's settlement writes under.
pub type SummaryRequest {
  SummaryRequest(index: Int, usage: UsageId)
}

/// One structural generation attempt (pi §3.2 `SummaryGeneration`).
///
/// Constructor invariants: `SummaryEffectPending.request` is the current
/// nested request intent, absent between requests; `usage_ids` accumulates
/// every settled request's ledger id (failed-attempt usage stays in the
/// ledger regardless). An orphaned effect-pending attempt is treated as
/// wholly uncertain and advances to a later ready attempt under the
/// captured policy.
pub type SummaryGeneration {
  /// The next attempt may start once the captured model resolves.
  SummaryReady(context: SummaryContext, next_attempt: Int)
  /// An attempt is live; at most one nested request is in flight.
  SummaryEffectPending(
    context: SummaryContext,
    attempt: Int,
    request: Option(SummaryRequest),
    usage_ids: List(UsageId),
  )
  /// A retryable attempt failed; the next starts at `not_before` (Unix
  /// ms).
  SummaryRetryWait(
    context: SummaryContext,
    next_attempt: Int,
    not_before: Int,
    error_message: String,
  )
}

// --- navigation -----------------------------------------------------------

/// A navigation operation's state (pi §3.2 `NavigationState`).
///
/// Constructor invariants: `Unsummarized` finishes in one transaction
/// (`ready_to_commit` in pi); no post-move recovery state exists.
/// `Summarized` requires a non-null target (validated at acceptance) and
/// carries the summary machinery; a declined summary moves nothing.
pub type Navigation {
  /// Ready to commit the leaf move; the terminal transaction publishes it.
  UnsummarizedNavigation(target: Option(EntryId), label: Option(String))
  /// Generating (or deciding on) a branch summary before the move.
  SummarizedNavigation(
    target: EntryId,
    label: Option(String),
    custom_instructions: Option(String),
    structural: StructuralDecision,
  )
}

// --- terminal results -----------------------------------------------------

/// The `strand.last_result` register payload: the strand's latest terminal
/// outcome (pi §3.13 `LaneLastResult`), written only by terminal
/// transactions and overwritten by the next one on the same strand.
///
/// Constructor invariants: `leaf` is the strand leaf at the terminal
/// commit. `final_assistant` is present when the outcome includes a newest
/// settled assistant response and absent otherwise. Navigation records its
/// pre-navigation source leaf and, when a completed navigation published
/// one, its summary entry id. Recovery never reads this value.
pub type LastResult {
  /// A run ended.
  RunLastResult(
    operation: OpId,
    leaf: Option(EntryId),
    outcome: RunOutcome,
    final_assistant: Option(EntryId),
  )
  /// A standalone compaction ended.
  CompactionLastResult(
    operation: OpId,
    leaf: Option(EntryId),
    outcome: StructuralOutcome,
  )
  /// A navigation ended.
  NavigationLastResult(
    operation: OpId,
    leaf: Option(EntryId),
    old_leaf: Option(EntryId),
    outcome: StructuralOutcome,
    summary: Option(EntryId),
  )
}

/// How a run ended.
pub type RunOutcome {
  /// The run finished normally; `completion` says what produced the final
  /// state.
  RunCompleted(completion: RunCompletion)
  /// Failure drain finished without recovering input.
  RunFailed(error: OperationError)
  /// Cancellation reconciliation finished.
  RunAborted
}

/// What completed a run.
pub type RunCompletion {
  /// The final assistant response ended the run.
  CompletedByAssistant
  /// Every finalized tool result in the final batch set `terminate`; there
  /// is no final assistant answer.
  CompletedByTerminatedTools
}

/// How a structural operation (compaction or navigation) ended.
pub type StructuralOutcome {
  /// The result was published.
  StructuralCompleted
  /// The decision hook declined; nothing was published or moved.
  StructuralDeclined
  /// Generation failed terminally.
  StructuralFailed(error: OperationError)
  /// Aborted before the publication commit; nothing was published or
  /// moved.
  StructuralAborted
}

// --- pending-entry payloads and structural preparation --------------------

/// The `pending.entry/{id}` register payload: complete content that is
/// durable before tree placement (pi §1.3 `PendingEntry`). The placement
/// transaction inserts the entry and deletes this register together;
/// cancellation deletes it and the content never enters the tree.
///
/// Constructor invariants: exactly one of the pending register and the
/// placed entry exists at any commit boundary. `PendingCustom.data` may be
/// absent — a custom entry with no data.
pub type PendingEntry {
  /// A queued or staged message (steer, follow-up, next-run input, or a
  /// finalized tool result awaiting source-ordered placement).
  PendingMessage(message: AgentMessage)
  /// A deferred custom tree write.
  PendingCustom(custom_type: String, data: Option(JsonValue))
}

/// File-operation provenance carried by a structural preparation (pi §1.3
/// `DurableFileOperations`).
///
/// Constructor invariants: each list is sorted and duplicate-free — pi
/// normalizes set-valued fields to sorted arrays before the write-once
/// preparation commit.
pub type FileOperations {
  FileOperations(
    read: List(String),
    written: List(String),
    edited: List(String),
  )
}

/// The `op.preparation/{op}:{task}` register payload (pi §1.3
/// `DurableStructuralPreparation`): the summary input frozen before the
/// decision hook, written exactly once so the provider sees the same input
/// the hook approved.
///
/// Constructor invariants: built from an observed source leaf and settings
/// snapshot by the ordinary context-projection rules; never rebuilt after
/// commit. `CompactionPreparation.retained_tail` is complete (`[]` when
/// empty); `tokens_before` is the context size being replaced.
pub type StructuralPreparation {
  /// Input for a compaction summary.
  CompactionPreparation(
    messages_to_summarize: List(AgentMessage),
    turn_prefix_messages: List(AgentMessage),
    retained_tail: List(AgentMessage),
    is_split_turn: Bool,
    tokens_before: Int,
    previous_summary: Option(String),
    file_ops: FileOperations,
    settings: CompactionSettings,
  )
  /// Input for a branch summary.
  BranchSummaryPreparation(
    messages: List(AgentMessage),
    file_ops: FileOperations,
    total_tokens: Int,
  )
}
