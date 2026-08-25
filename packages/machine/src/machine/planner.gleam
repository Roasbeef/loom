//// The pure operation planner: `State × Inputs → Action`.
////
//// `next_action` is the machine's frozen entry point (implementation spec
//// §1.3). The runtime driver (WP-E) loads the operation's registers,
//// gathers what the current state needs into `PlannerInputs`, and calls
//// `next_action`; the returned `Action` tells it exactly what to do:
////
//// - `Transition(next, tx)` — commit `tx` (all writes that make `next`
////   true, guarded by seq expectations) and plan again.
//// - `Dispatch(intent, next, tx)` — commit the intent transaction, then
////   perform the described external effect (provider request, tool
////   execution, deferred fetch, summary request). The effect's outcome
////   returns through `PlannerInputs.observation` on a later call.
//// - `AwaitEffect(key)` — the machine needs the observation named by
////   `key` and it is not in the inputs: wait on the live effect, run the
////   named hook, or perform the named recovery read, then plan again.
//// - `Wait(until)` — nothing to do until the stated durable wake point.
//// - `Finish(result, tx)` — commit the terminal transaction; the
////   operation ceases to exist.
//// - `Fault(report)` — the inputs or durable state are corrupt; the
////   caller must fault, never continue. (The frozen contract sketches
////   five actions; this sixth is the total-decoder discipline of spec
////   §0.2 applied to the planner itself — a pure function cannot crash
////   and must report corruption in-band.)
////
//// Everything here transcribes pi's harness spec Part 3 (§3.4–§3.13) and
//// the recovery rules of §4.5/§4.6, with pi's "lane" renamed "strand".
//// Hook outputs (run-start injections, request admission, structural
//// decisions, run-end follow-ups) arrive through observations because
//// hooks are replayable and carry no effect intent; provider requests,
//// tool executions, deferred fetches, and summary requests go through the
//// intent/settle sandwich as `Dispatch`.
////
//// ## Reading this module
////
//// One public function over a typed vocabulary, then a section per phase
//// of the spec. The vocabulary comes first and in full: all sixteen
//// types are declared before the first function body, so nothing below
//// introduces a name the reader has not already met. After that, each
//// section answers exactly one question, and the section you are in is
//// the only one you need.
////
//// - **planner inputs** — the vocabulary the *runtime* speaks:
////   `PlannerInputs` and the answer types it carries (`ThresholdStatus`,
////   `RequestAdmission`, `ModelResolution`, `StructuralVerdict`,
////   `SummaryProgress`, `Observation`). Decides nothing; it fixes what
////   the machine is permitted to know.
//// - **actions** — the vocabulary the *machine* speaks: `EffectKey`
////   (what it is waiting for), `EffectIntent` (what it wants performed),
////   `WaitUntil`, and `Action` itself.
//// - **internal vocabulary** — the four private types the handlers below
////   speak in among themselves.
//// - **the frozen entry point** — `next_action`. Decides which of the
////   three operation kinds owns the pass (run, standalone compaction,
////   navigation) and whether its control is running or cancelled; a
////   state whose kind contradicts the intent is corruption.
//// - **running runs** — decides which run phase handler owns the pass,
////   and consumes the run-start hook's injections into the first
////   checkpoint.
//// - **the checkpoint procedure (§3.12)** — the run's junction. Decides
////   which of pi's seven ordered steps is the next undone one: deferred
////   writes, steer, threshold compaction, generation, follow-up, the
////   run-end hook, finish.
//// - **assistant generation (§3.7)** — decides what one generation
////   attempt becomes: dispatched, retried after a wait, drained as a
////   failure, diverted into overflow compaction, suspended on a deferred
////   handle, opened as a tool batch, or landed at a may-finish
////   checkpoint.
//// - **tools (§3.8)** — decides which call in the batch is worked next
////   (scheduling mode), whether it clears, executes, replays, or gets a
////   machine-built synthetic, and when the contiguous outcome-ready run
////   at the frontier materializes into the tree.
//// - **deferred responses (§3.2)** — decides whether a suspended
////   operation may spend a poll permit on a fetch, and what a settled or
////   orphaned fetch becomes.
//// - **failure drain (§3.12)** — decides whether recovering input clears
////   the failure back into a generation, or the run finishes failed.
//// - **cancellation reconciliation (§4.6)** — decides which phases still
////   settle their outstanding work before aborting and which discard it,
////   and drains accepted writes before the aborted terminal transaction.
//// - **structural work (§3.9)** — the decide → generate → publish
////   lifecycle shared by all three of its hosts (an in-run compaction
////   phase, a standalone compaction operation, a summarized navigation);
////   `StructuralHost` is what keeps the three from being three copies.
//// - **navigation (§3.10)** — decides whether a move is a bare leaf move
////   or one that summarizes the abandoned branch first.
//// - **terminal transactions (§3.13)** — builds the single transaction
////   that ends an operation: publication writes, register deletion, the
////   strand and operation-keyed results, and the strand-state clear.
//// - **shared helpers** — entry placement, batch planning, the synthetic
////   messages recovery commits, stop-reason normalization, backoff.

import core/corruption.{type CorruptionReport}
import core/ids.{type EntryId, type OpId, type Seq, type UsageId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type DeferredHandle, type ToolCall, type Usage, Aborted,
  AssistantMessage, AssistantText, AssistantThinking, AssistantToolCall, Errored,
  Length, ToolResultMessage, ToolResultText,
}
import core/tx.{type Tx, type Write, Tx}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/classification.{
  type SettledAssistantMessage, CancelledClassification, ClassifyCtx,
  CorruptClassification, DeferredInvalidClassification,
  DeferredValidClassification, ErrorClassification, FinishedClassification,
  OverflowClassification, ToolUseClassification,
}
import machine/internal/build
import machine/operation.{
  type CheckpointPhase, type CompactionReason, type Control, type DeferredState,
  type Generation, type GenerationContext, type Inbox, type LastResult,
  type Navigation, type NormalizedRetryPolicy, type Operation,
  type OperationError, type OperationState, type PendingEntry, type RunPhase,
  type RunSettings, type StructuralDecision, type StructuralPreparation,
  type SummaryContext, type SummaryGeneration, type ToolBatch,
  type ToolCallState, Assistant, AwaitingDeferred, BranchSummary,
  BranchSummaryPreparation, CallCompleted, CallEffectPending, CallOutcomeReady,
  CallPlanned, CancelRequested, Checkpoint, CheckpointPhase, Compacting,
  CompactionIntent, CompactionLastResult, CompactionPreparation, CompactionState,
  CompactionSummary, CompletedByAssistant, CompletedByTerminatedTools,
  ConfigurationProvenance, ConsumeAll, Deciding, DeferredEffectPending,
  DeferredSuspended, FailureDrain, Generating, GenerationContext,
  GenerationEffectPending, GenerationReady, GenerationRetryWait, Inbox,
  ManualSummary, MayFinish, NavigationIntent, NavigationLastResult,
  NavigationState, NeedAssistant, OneAtATime, OperationError, OverflowReason,
  OverflowSummary, PendingCustom, PendingMessage, ReplaySafe, ResponseProvenance,
  RunAborted, RunCompleted, RunFailed, RunIntent, RunLastResult, RunState,
  Running, Starting, StructuralAborted, StructuralCompleted, StructuralDeclined,
  StructuralFailed, StructuralProvenance, SummarizedNavigation, SummaryContext,
  SummaryEffectPending, SummaryReady, SummaryRequest, SummaryRetryWait,
  ThresholdReason, ThresholdSummary, ToolBatch, Tools, UnsummarizedNavigation,
}
import machine/strand.{type StrandConfiguration, type StrandState, StrandState}

// --- planner inputs -------------------------------------------------------

/// Everything `next_action` reads besides the operation and its state.
///
/// The runtime assembles this from bounded, exact-id register and entry
/// reads plus its process-local knowledge (live effects, hook outputs,
/// poll permits). Constructor invariants, field by field:
///
/// - `now`: the injected clock's Unix-ms time for this planning pass.
/// - `generator`: an id-minting capability that has never produced a
///   committed id. The machine may mint several ids in one call, so the
///   caller must supply a freshly seeded (or correctly threaded) generator
///   on *every* call — reusing one across calls mints colliding ids.
/// - `op_state_seq`: the seq at which `op.state` was read; every emitted
///   transaction expects it (optimistic CAS, design doc §3.7).
/// - `strand_state` / `strand_state_seq`: the current `strand.state` value
///   and its seq; transactions that rewrite it re-read it here and change
///   only their own fields.
/// - `leaf`: the strand's current leaf.
/// - `configuration` / `configuration_seq`: the current `strand.config`,
///   snapshotted (with its seq expected) when a generation step starts.
/// - `stream_options`: the current global stream options as an opaque
///   value, snapshotted at generation start.
/// - `retry_policy`: the current normalized retry policy, snapshotted at
///   generation start.
/// - `pending`: the dereferenced `pending.entry` payloads for every id the
///   state names (inbox items, drained items, staged outcomes), keyed by
///   entry-id text. A referenced id missing here is storage corruption.
/// - `projected_custom_types`: custom types with a registered projector; a
///   custom write whose type is absent here is unprojected and preserves
///   the current continuation.
/// - `batch_source`: the assistant message at the tool batch's
///   `assistant_entry`; required whenever the phase is `Tools`.
/// - `deferred_source`: the deferred handle carried by the deferred
///   state's `source_entry` message; required whenever the phase is
///   `AwaitingDeferred`.
/// - `preparation`: the dereferenced `op.preparation` payload for the
///   current structural task, when the state carries one.
/// - `tool_args_keys` / `preparation_keys`: every existing `op.tool_args`
///   and `op.preparation` key owned by this operation (the runtime lists
///   them); the terminal transaction deletes each defensively.
/// - `threshold`: the runtime's threshold-compaction signal for the
///   current checkpoint boundary (always supplied; `ThresholdNotExceeded`
///   when compaction is off or the context fits).
/// - `poll_permit`: whether this pass may perform one deferred poll.
/// - `observation`: what the runtime produced since the last plan — hook
///   output, effect settlement, orphan report. `NoObservation` when there
///   is nothing new.
pub type PlannerInputs {
  PlannerInputs(
    now: Int,
    generator: ids.Generator,
    op_state_seq: Seq,
    strand_state: StrandState,
    strand_state_seq: Seq,
    leaf: Option(EntryId),
    configuration: StrandConfiguration,
    configuration_seq: Seq,
    stream_options: JsonValue,
    retry_policy: NormalizedRetryPolicy,
    pending: Dict(String, PendingEntry),
    projected_custom_types: List(String),
    batch_source: Option(AgentMessage),
    deferred_source: Option(DeferredHandle),
    preparation: Option(StructuralPreparation),
    tool_args_keys: List(String),
    preparation_keys: List(String),
    threshold: ThresholdStatus,
    poll_permit: Bool,
    observation: Observation,
  )
}

/// The runtime's threshold-compaction signal for the current checkpoint.
pub type ThresholdStatus {
  /// The projected context fits (or compaction is disabled).
  ThresholdNotExceeded
  /// The threshold is crossed; the outcome of building a preparation.
  ThresholdExceeded(outcome: PreparationOutcome)
}

/// The outcome of building a structural preparation.
pub type PreparationOutcome {
  /// A non-empty preparation was built.
  Prepared(preparation: StructuralPreparation)
  /// There was nothing to compact — the boundary is marked checked and
  /// the run continues (threshold), or the failure drains (overflow).
  EmptyPreparation
}

/// The pre-request admission verdict: identity resolution plus the
/// pre-request hook's composed options and computed limits.
pub type RequestAdmission {
  /// The captured model or a configured tool implementation is
  /// unavailable; `error` carries the stable configuration-failure code.
  AdmissionUnavailable(error: OperationError)
  /// Admitted: `stream_options` is the composed per-attempt options value
  /// the request must use; the two limits and `api` (the resolved
  /// adapter api the request will be made against) are persisted in the
  /// intent — deferred-handle validity compares against the captured
  /// `api`, never the response's self-reported one (ORCH-L4).
  Admitted(
    stream_options: JsonValue,
    intended_output_limit: Int,
    context_window: Int,
    api: String,
  )
}

/// Whether a captured model identity currently resolves — consulted
/// before deferred polls and summary requests, where no per-request
/// limits are computed.
pub type ModelResolution {
  /// The captured identity resolves.
  ModelResolved
  /// It does not; `error` carries the configuration-failure description.
  ModelUnresolved(error: OperationError)
}

/// The structural decision hook's verdict (pi §3.9 `deciding` rows).
pub type StructuralVerdict {
  /// The hook declined.
  VerdictDeclined
  /// The hook supplied the finished summary itself; `usage` is its
  /// reported cost, written as a ledger row at publication.
  VerdictSupplied(summary: String, usage: Option(Usage))
  /// The hook selected generation.
  VerdictGenerate
}

/// Progress of a structural generation attempt after its latest nested
/// request settled and cleared.
pub type SummaryProgress {
  /// The attempt needs another nested provider request (split turns).
  SummaryNeedsRequest
  /// The attempt produced the final summary text; `usage` is the display
  /// snapshot stored on the published entry (provider usage rows were
  /// already written per request).
  SummaryProduced(summary: String, usage: Option(Usage))
  /// The attempt failed; `retryable` and the captured policy decide
  /// between a retry wait and failure.
  SummaryFailed(error: OperationError, retryable: Bool)
}

/// What the runtime produced for the machine since the last plan.
pub type Observation {
  /// Nothing new.
  NoObservation
  /// The run-start hook finished; `messages` are its injected messages
  /// (possibly empty). Consumed by the `Starting` phase.
  ObservedRunStart(messages: List(AgentMessage))
  /// The pre-request hook and identity resolution finished for the
  /// current `ready` generation attempt.
  ObservedAdmission(admission: RequestAdmission)
  /// The pending assistant request settled. `overflow_preparation` is
  /// supplied (on request via `OverflowPreparationKey`) when the
  /// settlement classifies as a first overflow.
  ObservedAssistantSettled(
    settled: SettledAssistantMessage,
    overflow_preparation: Option(PreparationOutcome),
  )
  /// The pending assistant request is orphaned (its process-local
  /// continuation is lost); `partial` is the content reconstructed from
  /// the committed stream prefix, `[]` when none.
  ObservedAssistantOrphaned(partial: List(message.AssistantBlock))
  /// Clearance passed for the planned call at `source_index`:
  /// `effective_arguments` are the post-hook arguments to persist, and
  /// `replay` is the tool's declared replay policy.
  ObservedToolCleared(
    source_index: Int,
    effective_arguments: JsonValue,
    replay: operation.ReplayPolicy,
  )
  /// Clearance refused the call (unknown tool, invalid arguments, hook
  /// block): `result` is the complete synthetic error result to stage.
  ObservedToolRefused(source_index: Int, result: AgentMessage)
  /// The effect-pending call at `source_index` finished and post-effect
  /// hooks ran; `result` is the finalized result message and `terminate`
  /// its termination flag.
  ObservedToolSettled(source_index: Int, result: AgentMessage, terminate: Bool)
  /// The effect-pending call at `source_index` is orphaned.
  /// `replay_still_safe` reports whether the current registration still
  /// declares safe replay; `checkpoint` is the latest durable progress
  /// snapshot, when one exists.
  ObservedToolOrphaned(
    source_index: Int,
    replay_still_safe: Bool,
    checkpoint: Option(AgentMessage),
  )
  /// Whether a captured identity resolves (deferred polls, summary
  /// requests).
  ObservedResolution(resolution: ModelResolution)
  /// The pending deferred fetch settled.
  ObservedDeferredSettled(settled: SettledAssistantMessage)
  /// The pending deferred fetch is orphaned; recovery replaces the poll
  /// under fresh ids at the same poll number once a permit and identity
  /// resolution allow.
  ObservedDeferredOrphaned
  /// The structural decision hook returned.
  ObservedStructuralDecision(verdict: StructuralVerdict)
  /// The current nested summary request returned with its usage.
  ObservedSummaryReturned(usage: Usage)
  /// The attempt's progress after its latest request cleared.
  ObservedSummaryProgress(progress: SummaryProgress)
  /// The live structural attempt is orphaned; it is wholly uncertain and
  /// advances to a later attempt under the captured policy.
  ObservedSummaryOrphaned
  /// The run-end hook returned; `follow_up` is its optional born-placed
  /// follow-up message.
  ObservedRunEnd(follow_up: Option(AgentMessage))
}

// --- actions --------------------------------------------------------------

/// A key naming the observation the machine is waiting for. The runtime
/// resolves it — by waiting on a live effect, running the named hook, or
/// performing the named recovery read — and plans again with the matching
/// `Observation`.
pub type EffectKey {
  /// Run-start hook output for the `Starting` phase.
  RunStartKey(operation: OpId)
  /// Pre-request admission for a `ready` generation attempt.
  AdmissionKey(operation: OpId, step_id: String, attempt: Int)
  /// The pending assistant request (settlement or orphan report).
  AssistantKey(operation: OpId, step_id: String, response_entry: EntryId)
  /// An overflow settlement needs its compaction preparation.
  OverflowPreparationKey(operation: OpId, response_entry: EntryId)
  /// Clearance for the planned call at `source_index`.
  ToolClearanceKey(operation: OpId, step_id: String, source_index: Int)
  /// The pending tool effect at `source_index` (settlement or orphan
  /// report). In parallel mode this names the first pending call; any
  /// pending call's observation satisfies it.
  ToolKey(
    operation: OpId,
    step_id: String,
    source_index: Int,
    result_entry: EntryId,
  )
  /// Identity resolution before a deferred poll intent.
  PollAdmissionKey(operation: OpId, step_id: String, poll: Int)
  /// The pending deferred fetch (settlement or orphan report).
  PollKey(operation: OpId, step_id: String, poll: Int, response_entry: EntryId)
  /// The structural decision hook for the named task.
  DecisionKey(operation: OpId, task_id: String)
  /// Identity resolution before a summary request, or the pending nested
  /// request itself when one is in flight.
  SummaryKey(operation: OpId, task_id: String, attempt: Int)
  /// The attempt's progress after its latest request cleared.
  SummaryProgressKey(operation: OpId, task_id: String, attempt: Int)
  /// The run-end hook at a finishable boundary.
  RunEndKey(operation: OpId)
}

/// An external effect the runtime must perform after committing the
/// paired intent transaction. Every intent carries the reserved ids its
/// settlement (real or synthetic) will write under.
pub type EffectIntent {
  /// One assistant provider request.
  ProviderRequest(
    operation: OpId,
    step_id: String,
    attempt: Int,
    context: GenerationContext,
    stream_options: JsonValue,
    response_entry: EntryId,
    usage: UsageId,
    intended_output_limit: Int,
    context_window: Int,
  )
  /// One real tool execution with the persisted effective arguments.
  ToolRequest(
    operation: OpId,
    step_id: String,
    source_index: Int,
    call: ToolCall,
    effective_arguments: JsonValue,
    replay: operation.ReplayPolicy,
    result_entry: EntryId,
  )
  /// Safe re-execution of an orphaned call with its persisted arguments
  /// (`op.tool_args/{key}`) under the same reserved result id. No new
  /// intent is written; the paired transaction only fences the state.
  ToolReplay(
    operation: OpId,
    step_id: String,
    source_index: Int,
    call: ToolCall,
    arguments_key: String,
    result_entry: EntryId,
  )
  /// One deferred fetch against the newest source handle.
  DeferredFetch(
    operation: OpId,
    step_id: String,
    poll: Int,
    source_entry: EntryId,
    response_entry: EntryId,
    usage: UsageId,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
  /// One nested summary provider request.
  SummaryProviderRequest(
    operation: OpId,
    task_id: String,
    attempt: Int,
    request_index: Int,
    usage: UsageId,
    context: SummaryContext,
  )
}

/// A durable wake point for `Wait`.
pub type WaitUntil {
  /// A retry wait: wake at `at` (Unix ms).
  RetryNotBefore(at: Int)
  /// A deferred suspension: wake when the caller grants a poll permit.
  DeferredPollDue(source_entry: EntryId)
}

/// What the runtime must do next. See the module doc for the contract of
/// each constructor.
pub type Action {
  /// Commit `tx`; the operation's durable state becomes `next`.
  Transition(next: OperationState, tx: Tx)
  /// Commit the intent transaction, then perform the effect.
  Dispatch(intent: EffectIntent, next: OperationState, tx: Tx)
  /// Produce the observation named by `key`, then plan again.
  AwaitEffect(key: EffectKey)
  /// Nothing to do until the stated wake point.
  Wait(until: WaitUntil)
  /// Commit the terminal transaction; the operation ceases to exist.
  Finish(result: LastResult, tx: Tx)
  /// The inputs or durable state are corrupt; the caller must fault.
  Fault(report: CorruptionReport)
}

// --- internal vocabulary --------------------------------------------------
//
// The four types that are not part of anyone's contract: each is a small
// private alphabet one section's handlers use to say something to each
// other. They sit here, with the public vocabulary rather than beside
// their users, so that the rule holds without exception — every type this
// module has is declared before the first function body, and no handler
// thousands of lines down introduces one cold.

/// Which checkpoint queue a drain consumes (checkpoint procedure).
type DrainedQueue {
  SteerQueue
  FollowUpQueue
}

/// The resolution answer available for an orphaned poll (deferred
/// responses). The orphan report itself carries no resolution, so
/// `OrphanPollUnknown` is the state of having asked and not yet been
/// answered.
type OrphanPollResolution {
  OrphanPollResolved
  OrphanPollUnresolved(OperationError)
  OrphanPollUnknown
}

/// Who hosts the structural machinery: an in-run compaction phase, a
/// standalone compaction operation, or a summarized navigation. Every
/// handler in the structural section is written once against this type
/// and differs between the three only where the spec does — which state
/// to rebuild, and what a decline, a failure, or a publication means.
type StructuralHost {
  InRunHost(
    reason: CompactionReason,
    settings: RunSettings,
    inbox: Inbox,
    latest: Option(EntryId),
    resume: CheckpointPhase,
  )
  StandaloneHost(custom_instructions: Option(String))
  NavigationHost(
    target: EntryId,
    label: Option(String),
    custom_instructions: Option(String),
  )
}

/// The result of placing a batch of pending ids as entries (shared
/// helpers). `projecting` is true when at least one placed entry feeds
/// the model, which is what makes a placement demand another assistant
/// turn rather than preserving the current continuation.
type Placement {
  Placement(writes: List(Write), newest: Option(EntryId), projecting: Bool)
}

// --- the frozen entry point ----------------------------------------------

/// Computes the next action for one operation. Pure and total: corrupt
/// inputs yield `Fault`, never a crash.
///
/// ## Examples
///
/// ```gleam
/// // See the scenario tests: the driver loops
/// //   planner.next_action(op, state, inputs)
/// // applying each emitted transaction to a fake store.
/// ```
///
pub fn next_action(
  op: Operation,
  state: OperationState,
  in: PlannerInputs,
) -> Action {
  case state, op.intent {
    RunState(control:, settings:, phase:, inbox:, latest_assistant:),
      RunIntent(..)
    ->
      case control {
        Running ->
          run_action(op, in, control, settings, phase, inbox, latest_assistant)
        CancelRequested(..) ->
          reconcile_run(
            op,
            in,
            control,
            settings,
            phase,
            inbox,
            latest_assistant,
          )
      }
    CompactionState(control:, custom_instructions:, structural:),
      CompactionIntent(..)
    ->
      structural_action(
        op,
        in,
        control,
        structural,
        StandaloneHost(custom_instructions:),
      )
    NavigationState(control:, navigation:), NavigationIntent(..) ->
      navigation_action(op, in, control, navigation)
    _, _ ->
      Fault(report: corruption.report(
        at: "machine/planner.next_action",
        on: build.op_key(op.id),
        expected: "state kind compatible with the operation intent",
        context: "mismatched op.meta and op.state kinds",
      ))
  }
}

// --- running runs ---------------------------------------------------------

fn run_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  phase: RunPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case phase {
    Starting -> begin_run(op, in, control, settings, inbox, latest)
    Checkpoint(checkpoint:) ->
      checkpoint_action(op, in, control, settings, checkpoint, inbox, latest)
    Assistant(generation:) ->
      assistant_action(op, in, control, settings, generation, inbox, latest)
    Tools(batch:) ->
      tools_action(op, in, control, settings, batch, inbox, latest)
    Compacting(reason:, structural:, resume_after:) ->
      structural_action(
        op,
        in,
        control,
        structural,
        InRunHost(reason:, settings:, inbox:, latest:, resume: resume_after),
      )
    AwaitingDeferred(deferred:) ->
      deferred_action(op, in, control, settings, deferred, inbox, latest)
    FailureDrain(error:, provenance:) ->
      failure_drain_action(
        op,
        in,
        control,
        settings,
        error,
        provenance,
        inbox,
        latest,
      )
  }
}

/// `starting` → `checkpoint`: consume the run-start hook's output. The
/// hook may rerun after a crash; the consuming transition commits once.
fn begin_run(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case in.observation {
    ObservedRunStart(messages:) -> {
      let #(entry_writes, newest, _generator) =
        append_messages(in.generator, in.leaf, messages)
      let trigger = case newest {
        Some(id) -> Ok(id)
        None ->
          case in.leaf {
            Some(id) -> Ok(id)
            None ->
              Error(corruption.report(
                at: "machine/planner.begin_run",
                on: build.op_key(op.id),
                expected: "a strand leaf after run acceptance",
                context: "null leaf with no injected messages",
              ))
          }
      }
      case trigger {
        Error(report) -> Fault(report:)
        Ok(trigger) -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Checkpoint(checkpoint: CheckpointPhase(
                continuation: NeedAssistant(overflow_recovery_used: False),
                trigger:,
                threshold_checked: None,
                skip_inbox_once: False,
              )),
              inbox:,
              latest_assistant: latest,
            )
          let leaf_writes = case newest {
            Some(id) -> [build.set_leaf(op.strand, Some(id))]
            None -> []
          }
          transition(
            op,
            in,
            next,
            list.flatten([
              entry_writes,
              leaf_writes,
              [build.set_op_state(op.id, next)],
            ]),
          )
        }
      }
    }
    NoObservation -> AwaitEffect(key: RunStartKey(operation: op.id))
    other -> unexpected_observation(op, "starting", other)
  }
}

// --- the checkpoint procedure (pi §3.12) ----------------------------------

/// The seven-step procedure, in this normative order (pi §3.12): deferred
/// writes, steer, threshold compaction, generation, follow-up, run-end
/// hook, finish. This function and `after_inbox` together are the
/// dispatcher; each step's own commit-shaped work lives in the function
/// named after it below. Every step that does anything is its own commit,
/// so a crash always resumes at the next undone step in the same order —
/// `skip_inbox_once`, set by whichever drain just ran, is what makes that
/// resumption skip straight past steps 1–2 instead of re-evaluating them.
fn checkpoint_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case checkpoint.skip_inbox_once {
    // Steps 1–2 are skipped once; generation clears the flag.
    True -> after_inbox(op, in, control, settings, checkpoint, inbox, latest)
    False ->
      case inbox.writes {
        [_, ..] ->
          apply_writes(op, in, control, settings, checkpoint, inbox, latest)
        [] ->
          case inbox.steer {
            [_, ..] ->
              consume_queue(
                op,
                in,
                control,
                settings,
                checkpoint,
                inbox,
                latest,
                SteerQueue,
              )
            [] ->
              after_inbox(op, in, control, settings, checkpoint, inbox, latest)
          }
      }
  }
}

fn after_inbox(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  // Step 3: threshold compaction, at most once per trigger boundary.
  let unchecked = checkpoint.threshold_checked != Some(checkpoint.trigger)
  case settings.compaction.enabled && unchecked, in.threshold {
    True, ThresholdExceeded(outcome: Prepared(preparation:)) ->
      enter_threshold_compaction(
        op,
        in,
        control,
        settings,
        checkpoint,
        inbox,
        latest,
        preparation,
      )
    True, ThresholdExceeded(outcome: EmptyPreparation) -> {
      // Empty preparation: atomically mark the boundary checked and
      // continue — no structural lifecycle.
      let marked =
        CheckpointPhase(
          ..checkpoint,
          threshold_checked: Some(checkpoint.trigger),
        )
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: marked),
          inbox:,
          latest_assistant: latest,
        )
      transition(op, in, next, [build.set_op_state(op.id, next)])
    }
    _, _ ->
      case checkpoint.continuation {
        NeedAssistant(..) ->
          start_generation(op, in, control, settings, checkpoint, inbox, latest)
        MayFinish(include_final_assistant:) ->
          case inbox.follow_up {
            [_, ..] ->
              consume_queue(
                op,
                in,
                control,
                settings,
                checkpoint,
                inbox,
                latest,
                FollowUpQueue,
              )
            [] ->
              finish_boundary(
                op,
                in,
                control,
                settings,
                checkpoint,
                inbox,
                latest,
                include_final_assistant,
              )
          }
      }
  }
}

/// Steps 1: atomically apply every accepted deferred write.
fn apply_writes(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case place_pending(in, in.leaf, inbox.writes) {
    Error(report) -> Fault(report:)
    Ok(Placement(writes: entry_writes, newest:, projecting:)) -> {
      let remaining = Inbox(..inbox, writes: [])
      let next_checkpoint = case projecting, newest {
        // Projecting input: need another assistant turn, trigger on the
        // newest appended entry, and skip the inbox once.
        True, Some(newest) ->
          CheckpointPhase(
            continuation: NeedAssistant(overflow_recovery_used: False),
            trigger: newest,
            threshold_checked: checkpoint.threshold_checked,
            skip_inbox_once: True,
          )
        // Unprojected custom writes preserve the checkpoint, including
        // trigger and overflow flag.
        _, _ -> checkpoint
      }
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: next_checkpoint),
          inbox: remaining,
          latest_assistant: latest,
        )
      let leaf_writes = case newest {
        Some(id) -> [build.set_leaf(op.strand, Some(id))]
        None -> []
      }
      transition(
        op,
        in,
        next,
        list.flatten([
          entry_writes,
          leaf_writes,
          [build.set_op_state(op.id, next)],
        ]),
      )
    }
  }
}

/// Steps 2 and 5: consume eligible steer or follow-up input per its mode.
fn consume_queue(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
  queue: DrainedQueue,
) -> Action {
  let #(items, mode) = case queue {
    SteerQueue -> #(inbox.steer, settings.steering_mode)
    FollowUpQueue -> #(inbox.follow_up, settings.follow_up_mode)
  }
  let #(consumed, left) = case mode {
    ConsumeAll -> #(items, [])
    OneAtATime ->
      case items {
        [first, ..rest] -> #([first], rest)
        [] -> #([], [])
      }
  }
  case place_pending(in, in.leaf, consumed) {
    Error(report) -> Fault(report:)
    Ok(Placement(writes: entry_writes, newest:, projecting: _)) ->
      case newest {
        None ->
          Fault(report: corruption.report(
            at: "machine/planner.consume_queue",
            on: build.op_key(op.id),
            expected: "a non-empty eligible queue",
            context: "queue drain with nothing to place",
          ))
        Some(newest) -> {
          let remaining = case queue {
            SteerQueue -> Inbox(..inbox, steer: left)
            FollowUpQueue -> Inbox(..inbox, follow_up: left)
          }
          let next =
            RunState(
              control:,
              settings:,
              phase: Checkpoint(checkpoint: CheckpointPhase(
                continuation: NeedAssistant(overflow_recovery_used: False),
                trigger: newest,
                threshold_checked: checkpoint.threshold_checked,
                skip_inbox_once: True,
              )),
              inbox: remaining,
              latest_assistant: latest,
            )
          transition(
            op,
            in,
            next,
            list.flatten([
              entry_writes,
              [
                build.set_leaf(op.strand, Some(newest)),
                build.set_op_state(op.id, next),
              ],
            ]),
          )
        }
      }
  }
}

/// Step 3, taken: enter threshold compaction, copying the checkpoint into
/// `resume_after` marked checked so this boundary is never rechecked.
fn enter_threshold_compaction(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
  preparation: StructuralPreparation,
) -> Action {
  let #(task_entry, _generator) = ids.mint_entry(in.generator)
  let task_id = ids.entry_id_to_string(task_entry)
  let marked =
    CheckpointPhase(..checkpoint, threshold_checked: Some(checkpoint.trigger))
  let next =
    RunState(
      control:,
      settings:,
      phase: Compacting(
        reason: ThresholdReason,
        structural: Deciding(task_id:),
        resume_after: marked,
      ),
      inbox:,
      latest_assistant: latest,
    )
  transition(op, in, next, [
    build.set_preparation(op.id, task_id, preparation),
    build.set_op_state(op.id, next),
  ])
}

/// Step 4: `need_assistant` starts a generation step, snapshotting the
/// current configuration, stream options, and retry policy inline and
/// clearing `skip_inbox_once`.
fn start_generation(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  let overflow_recovery_used = case checkpoint.continuation {
    NeedAssistant(overflow_recovery_used:) -> overflow_recovery_used
    MayFinish(..) -> False
  }
  let #(step_entry, _generator) = ids.mint_entry(in.generator)
  let context =
    GenerationContext(
      step_id: ids.entry_id_to_string(step_entry),
      trigger: checkpoint.trigger,
      configuration: in.configuration,
      stream_options: in.stream_options,
      retry: in.retry_policy,
      overflow_recovery_used:,
    )
  let next =
    RunState(
      control:,
      settings:,
      phase: Assistant(generation: GenerationReady(context:, next_attempt: 1)),
      inbox:,
      latest_assistant: latest,
    )
  Transition(
    next:,
    tx: Tx(writes: [build.set_op_state(op.id, next)], expected: [
      build.expect_op_state(op.id, in.op_state_seq),
      build.expect_configuration(op.strand, in.configuration_seq),
    ]),
  )
}

/// Steps 6–7: at a finishable boundary, consult the run-end hook, then
/// finish.
fn finish_boundary(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  checkpoint: CheckpointPhase,
  inbox: Inbox,
  latest: Option(EntryId),
  include_final_assistant: Bool,
) -> Action {
  case in.observation {
    ObservedRunEnd(follow_up: Some(message)) -> {
      // A run-end follow-up is born placed: entry and need_assistant
      // state commit together, with no pending register.
      let #(entry_id, _generator) = ids.mint_entry(in.generator)
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: NeedAssistant(overflow_recovery_used: False),
            trigger: entry_id,
            threshold_checked: checkpoint.threshold_checked,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: latest,
        )
      transition(op, in, next, [
        build.message_entry(entry_id, in.leaf, message, False),
        build.set_leaf(op.strand, Some(entry_id)),
        build.set_op_state(op.id, next),
      ])
    }
    ObservedRunEnd(follow_up: None) -> {
      let completion = case include_final_assistant {
        True -> CompletedByAssistant
        False -> CompletedByTerminatedTools
      }
      let final_assistant = case include_final_assistant {
        True -> latest
        False -> None
      }
      let result =
        RunLastResult(
          operation: op.id,
          leaf: in.leaf,
          outcome: RunCompleted(completion:),
          final_assistant:,
        )
      finish(op, in, run_pending_ids(control, inbox, None), result, [])
    }
    NoObservation -> AwaitEffect(key: RunEndKey(operation: op.id))
    other -> unexpected_observation(op, "finish boundary", other)
  }
}

// --- assistant generation (pi §3.7) ---------------------------------------

fn assistant_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  generation: Generation,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case generation {
    GenerationReady(context:, next_attempt:) ->
      case in.observation {
        ObservedAdmission(admission: AdmissionUnavailable(error:)) -> {
          // No response or usage ids are reserved; nothing is fabricated.
          let next =
            RunState(
              control:,
              settings:,
              phase: FailureDrain(error:, provenance: ConfigurationProvenance),
              inbox:,
              latest_assistant: latest,
            )
          transition(op, in, next, [build.set_op_state(op.id, next)])
        }
        ObservedAdmission(admission: Admitted(
          stream_options:,
          intended_output_limit:,
          context_window:,
          api: request_api,
        )) -> {
          let #(response_entry, generator) = ids.mint_entry(in.generator)
          let #(usage, _generator) = ids.mint_usage(generator)
          let next =
            RunState(
              control:,
              settings:,
              phase: Assistant(generation: GenerationEffectPending(
                context:,
                attempt: next_attempt,
                response_entry:,
                usage:,
                intended_output_limit:,
                context_window:,
                request_api:,
              )),
              inbox:,
              latest_assistant: latest,
            )
          Dispatch(
            intent: ProviderRequest(
              operation: op.id,
              step_id: context.step_id,
              attempt: next_attempt,
              context:,
              stream_options:,
              response_entry:,
              usage:,
              intended_output_limit:,
              context_window:,
            ),
            next:,
            tx: op_tx(op, in, [build.set_op_state(op.id, next)]),
          )
        }
        NoObservation ->
          AwaitEffect(key: AdmissionKey(
            operation: op.id,
            step_id: context.step_id,
            attempt: next_attempt,
          ))
        other -> unexpected_observation(op, "assistant ready", other)
      }
    GenerationEffectPending(
      context:,
      attempt:,
      response_entry:,
      usage:,
      intended_output_limit:,
      context_window: _,
      request_api:,
    ) ->
      case in.observation {
        ObservedAssistantSettled(settled:, overflow_preparation:) ->
          settle_assistant(
            op,
            in,
            control,
            settings,
            context,
            attempt,
            response_entry,
            usage,
            intended_output_limit,
            request_api,
            inbox,
            latest,
            settled,
            overflow_preparation,
          )
        ObservedAssistantOrphaned(partial:) ->
          settle_orphaned_assistant(
            op,
            in,
            control,
            settings,
            context,
            attempt,
            response_entry,
            usage,
            inbox,
            latest,
            partial,
          )
        NoObservation ->
          AwaitEffect(key: AssistantKey(
            operation: op.id,
            step_id: context.step_id,
            response_entry:,
          ))
        other -> unexpected_observation(op, "assistant effect_pending", other)
      }
    GenerationRetryWait(context:, next_attempt:, not_before:, error_message: _) ->
      case in.now >= not_before {
        True -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Assistant(generation: GenerationReady(
                context:,
                next_attempt:,
              )),
              inbox:,
              latest_assistant: latest,
            )
          transition(op, in, next, [build.set_op_state(op.id, next)])
        }
        False -> Wait(until: RetryNotBefore(at: not_before))
      }
  }
}

fn settle_assistant(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  context: GenerationContext,
  attempt: Int,
  response_entry: EntryId,
  usage_id: UsageId,
  intended_output_limit: Int,
  request_api: String,
  inbox: Inbox,
  latest: Option(EntryId),
  settled: SettledAssistantMessage,
  overflow_preparation: Option(PreparationOutcome),
) -> Action {
  let message = classification.message(settled)
  let classify_ctx =
    ClassifyCtx(
      control:,
      intended_output_limit:,
      expected_model: context.configuration.model,
      // The captured request api from the intent, never the response's
      // self-reported one (ORCH-L4): a handle whose api differs from the
      // request must be invalid even when the response echoes it.
      expected_api: request_api,
      error_retryable: settled_retryable(message),
    )
  case classification.classify(settled, classify_ctx) {
    CorruptClassification(report:) -> Fault(report:)
    CancelledClassification -> {
      let aborted = normalize_stop(message, Aborted, None)
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: MayFinish(include_final_assistant: True),
            trigger: response_entry,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, aborted, usage_id, in.leaf, next),
      )
    }
    OverflowClassification -> {
      let normalized =
        normalize_stop(message, Errored, Some(overflow_error_message(message)))
      case context.overflow_recovery_used {
        // Second overflow: the one-shot recovery is spent.
        True ->
          settle_failure_drain(
            op,
            in,
            control,
            settings,
            response_entry,
            usage_id,
            normalized,
            inbox,
            latest,
            overflow_operation_error(message),
          )
        False ->
          case overflow_preparation {
            None ->
              AwaitEffect(key: OverflowPreparationKey(
                operation: op.id,
                response_entry:,
              ))
            Some(EmptyPreparation) ->
              settle_failure_drain(
                op,
                in,
                control,
                settings,
                response_entry,
                usage_id,
                normalized,
                inbox,
                latest,
                overflow_operation_error(message),
              )
            Some(Prepared(preparation:)) -> {
              let #(task_entry, _generator) = ids.mint_entry(in.generator)
              let task_id = ids.entry_id_to_string(task_entry)
              let next =
                RunState(
                  control:,
                  settings:,
                  phase: Compacting(
                    reason: OverflowReason,
                    structural: Deciding(task_id:),
                    resume_after: CheckpointPhase(
                      continuation: NeedAssistant(overflow_recovery_used: True),
                      trigger: context.trigger,
                      threshold_checked: None,
                      skip_inbox_once: False,
                    ),
                  ),
                  inbox:,
                  latest_assistant: Some(response_entry),
                )
              transition(
                op,
                in,
                next,
                list.flatten([
                  [
                    build.message_entry(
                      response_entry,
                      in.leaf,
                      normalized,
                      False,
                    ),
                    build.set_leaf(op.strand, Some(response_entry)),
                    build.usage_row(
                      usage_id,
                      Some(response_entry),
                      message_usage(message),
                    ),
                    build.set_preparation(op.id, task_id, preparation),
                    build.set_op_state(op.id, next),
                  ],
                ]),
              )
            }
          }
      }
    }
    DeferredValidClassification(handle: _) -> {
      let next =
        RunState(
          control:,
          settings:,
          phase: AwaitingDeferred(deferred: DeferredSuspended(
            step_id: context.step_id,
            source_entry: response_entry,
            poll: 0,
            configuration: context.configuration,
            stream_options: context.stream_options,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, message, usage_id, in.leaf, next),
      )
    }
    DeferredInvalidClassification -> {
      let normalized =
        normalize_stop(
          message,
          Errored,
          Some("invalid deferred handle: the response carried no usable handle"),
        )
      settle_failure_drain(
        op,
        in,
        control,
        settings,
        response_entry,
        usage_id,
        normalized,
        inbox,
        latest,
        OperationError(
          code: "invalid_deferred_handle",
          message: "the deferred response carried no usable handle",
          details: None,
        ),
      )
    }
    ErrorClassification(retryable:, error_message:) ->
      case retryable && attempt < context.retry.max_attempts {
        True -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Assistant(generation: GenerationRetryWait(
                context:,
                next_attempt: attempt + 1,
                not_before: in.now + backoff(context.retry, attempt),
                error_message:,
              )),
              inbox:,
              latest_assistant: Some(response_entry),
            )
          transition(
            op,
            in,
            next,
            settle_writes(op, response_entry, message, usage_id, in.leaf, next),
          )
        }
        False ->
          settle_failure_drain(
            op,
            in,
            control,
            settings,
            response_entry,
            usage_id,
            message,
            inbox,
            latest,
            OperationError(
              code: "provider_error",
              message: error_message,
              details: None,
            ),
          )
      }
    ToolUseClassification(truncated: _) ->
      case plan_batch(in, message, context, response_entry) {
        Error(report) -> Fault(report:)
        Ok(batch) -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Tools(batch:),
              inbox:,
              latest_assistant: Some(response_entry),
            )
          transition(
            op,
            in,
            next,
            settle_writes(op, response_entry, message, usage_id, in.leaf, next),
          )
        }
      }
    FinishedClassification -> {
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: MayFinish(include_final_assistant: True),
            trigger: response_entry,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, message, usage_id, in.leaf, next),
      )
    }
  }
}

/// The shared settlement write list: response entry, leaf, usage row, and
/// the next state — one atomic commit, in pi's normative order.
fn settle_writes(
  op: Operation,
  response_entry: EntryId,
  message: AgentMessage,
  usage_id: UsageId,
  leaf: Option(EntryId),
  next: OperationState,
) -> List(Write) {
  [
    build.message_entry(response_entry, leaf, message, False),
    build.set_leaf(op.strand, Some(response_entry)),
    build.usage_row(usage_id, Some(response_entry), message_usage(message)),
    build.set_op_state(op.id, next),
  ]
}

fn settle_failure_drain(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
  inbox: Inbox,
  _latest: Option(EntryId),
  error: OperationError,
) -> Action {
  let next =
    RunState(
      control:,
      settings:,
      phase: FailureDrain(
        error:,
        provenance: ResponseProvenance(entry: response_entry),
      ),
      inbox:,
      latest_assistant: Some(response_entry),
    )
  transition(
    op,
    in,
    next,
    settle_writes(op, response_entry, message, usage_id, in.leaf, next),
  )
}

/// Orphan recovery for an assistant `effect_pending` (pi §4.5): commit a
/// synthetic zero-usage error under the reserved ids carrying the
/// reconstructed partial, then follow ordinary classification — retry
/// with attempts remaining, failure drain at the cap.
fn settle_orphaned_assistant(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  context: GenerationContext,
  attempt: Int,
  response_entry: EntryId,
  usage_id: UsageId,
  inbox: Inbox,
  latest: Option(EntryId),
  partial: List(message.AssistantBlock),
) -> Action {
  let synthetic = case control {
    Running ->
      synthetic_response(
        context,
        partial,
        Errored,
        interrupted_warning(),
        in.now,
      )
    CancelRequested(..) ->
      synthetic_response(
        context,
        partial,
        Aborted,
        interrupted_warning(),
        in.now,
      )
  }
  case control {
    CancelRequested(..) -> {
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: MayFinish(include_final_assistant: True),
            trigger: response_entry,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, synthetic, usage_id, in.leaf, next),
      )
    }
    Running ->
      case attempt < context.retry.max_attempts {
        True -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Assistant(generation: GenerationRetryWait(
                context:,
                next_attempt: attempt + 1,
                not_before: in.now + backoff(context.retry, attempt),
                error_message: interrupted_warning(),
              )),
              inbox:,
              latest_assistant: Some(response_entry),
            )
          transition(
            op,
            in,
            next,
            settle_writes(
              op,
              response_entry,
              synthetic,
              usage_id,
              in.leaf,
              next,
            ),
          )
        }
        False ->
          settle_failure_drain(
            op,
            in,
            control,
            settings,
            response_entry,
            usage_id,
            synthetic,
            inbox,
            latest,
            OperationError(
              code: "interrupted",
              message: interrupted_warning(),
              details: None,
            ),
          )
      }
  }
}

// --- tools (pi §3.8) ------------------------------------------------------

fn tools_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case in.batch_source {
    None ->
      Fault(report: corruption.report(
        at: "machine/planner.tools_action",
        on: ids.entry_id_to_string(batch.assistant_entry),
        expected: "the batch source assistant message in the inputs",
        context: "batch_source absent",
      ))
    Some(source) -> {
      // Materialize a contiguous outcome-ready run at the frontier first.
      let completed_prefix =
        list.take_while(batch.calls, fn(call) {
          case call {
            CallCompleted(..) -> True
            _ -> False
          }
        })
      let frontier = list.drop(batch.calls, list.length(completed_prefix))
      let ready_run =
        list.take_while(frontier, fn(call) {
          case call {
            CallOutcomeReady(..) -> True
            _ -> False
          }
        })
      case ready_run {
        [_, ..] ->
          materialize(
            op,
            in,
            control,
            settings,
            batch,
            inbox,
            latest,
            ready_run,
          )
        [] ->
          advance_batch(
            op,
            in,
            control,
            settings,
            batch,
            inbox,
            latest,
            source,
            frontier,
          )
      }
    }
  }
}

fn advance_batch(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source: AgentMessage,
  frontier: List(ToolCallState),
) -> Action {
  // Consume a tool observation when one is present.
  case in.observation {
    ObservedToolCleared(source_index:, effective_arguments:, replay:) ->
      dispatch_tool(
        op,
        in,
        control,
        settings,
        batch,
        inbox,
        latest,
        source,
        source_index,
        effective_arguments,
        replay,
      )
    ObservedToolRefused(source_index:, result:) ->
      stage_result(
        op,
        in,
        control,
        settings,
        batch,
        inbox,
        latest,
        source_index,
        result,
        False,
      )
    ObservedToolSettled(source_index:, result:, terminate:) -> {
      // Under cancelled control a live result is preserved but never
      // terminates the run.
      let terminate = case control {
        Running -> terminate
        CancelRequested(..) -> False
      }
      stage_result(
        op,
        in,
        control,
        settings,
        batch,
        inbox,
        latest,
        source_index,
        result,
        terminate,
      )
    }
    ObservedToolOrphaned(source_index:, replay_still_safe:, checkpoint:) ->
      recover_tool(
        op,
        in,
        control,
        settings,
        batch,
        inbox,
        latest,
        source,
        source_index,
        replay_still_safe,
        checkpoint,
      )
    NoObservation ->
      request_batch_work(
        op,
        in,
        control,
        settings,
        batch,
        inbox,
        latest,
        source,
        frontier,
      )
    other -> unexpected_observation(op, "tools", other)
  }
}

/// With no observation, decide what to ask the runtime for next — or, for
/// a planned call that must not execute (cancelled control, truncated
/// source response), stage the machine-built synthetic result directly.
///
/// The batch's execution mode decides which call is worked (pi §3.8,
/// review finding ORCH-M2): `Sequential` works the frontier's head only,
/// so one call clears, executes, and settles at a time; `Parallel` works
/// the first still-*planned* call even while earlier calls are
/// effect-pending, so clearance and intents issue in source order and
/// their effects settle independently. Tree materialization stays
/// source-ordered in both modes — the frontier's contiguous outcome-ready
/// run is handled before this function is reached.
fn request_batch_work(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source: AgentMessage,
  frontier: List(ToolCallState),
) -> Action {
  case frontier {
    [] ->
      Fault(report: corruption.report(
        at: "machine/planner.request_batch_work",
        on: build.op_key(op.id),
        expected: "a batch with unfinished calls",
        context: "tools phase with every call completed",
      ))
    [first, ..] ->
      case first {
        CallCompleted(..) | CallOutcomeReady(..) ->
          Fault(report: corruption.report(
            at: "machine/planner.request_batch_work",
            on: build.op_key(op.id),
            expected: "materialization to have handled the frontier",
            context: "outcome_ready or completed at the frontier",
          ))
        CallPlanned(source_index:, result_entry: _) ->
          work_planned_call(
            op,
            in,
            control,
            settings,
            batch,
            inbox,
            latest,
            source,
            source_index,
          )
        CallEffectPending(source_index:, result_entry:, replay: _) ->
          case settings.tool_execution {
            operation.Sequential ->
              AwaitEffect(key: ToolKey(
                operation: op.id,
                step_id: batch.turn_id,
                source_index:,
                result_entry:,
              ))
            operation.Parallel ->
              // Work the next planned call while this one is in flight;
              // only once every unfinished call is effect-pending does
              // the batch park on the first of them (any pending call's
              // observation satisfies the key).
              case first_planned(frontier) {
                Some(planned_index) ->
                  work_planned_call(
                    op,
                    in,
                    control,
                    settings,
                    batch,
                    inbox,
                    latest,
                    source,
                    planned_index,
                  )
                None ->
                  AwaitEffect(key: ToolKey(
                    operation: op.id,
                    step_id: batch.turn_id,
                    source_index:,
                    result_entry:,
                  ))
              }
          }
      }
  }
}

/// The source index of the first still-planned call at the frontier, if
/// any — parallel mode's next unit of work.
fn first_planned(frontier: List(ToolCallState)) -> Option(Int) {
  case frontier {
    [] -> None
    [CallPlanned(source_index:, ..), ..] -> Some(source_index)
    [CallEffectPending(..), ..rest]
    | [CallOutcomeReady(..), ..rest]
    | [CallCompleted(..), ..rest] -> first_planned(rest)
  }
}

/// Works one planned call: stage the machine-built synthetic when the
/// call must not execute (cancelled control, truncated source response),
/// otherwise ask for its clearance.
fn work_planned_call(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source: AgentMessage,
  source_index: Int,
) -> Action {
  let synthetic_text = case control, message_stop_reason(source) {
    CancelRequested(..), _ ->
      Some("tool call aborted: cancellation was requested before execution")
    Running, Length ->
      Some(
        "tool call not executed: the response hit its output limit and "
        <> "the call arguments may be truncated; answer with corrected "
        <> "calls",
      )
    Running, _ -> None
  }
  case synthetic_text {
    Some(text) ->
      case synthetic_tool_result(source, source_index, text, None, in.now) {
        Error(report) -> Fault(report:)
        Ok(result) ->
          stage_result(
            op,
            in,
            control,
            settings,
            batch,
            inbox,
            latest,
            source_index,
            result,
            False,
          )
      }
    None ->
      AwaitEffect(key: ToolClearanceKey(
        operation: op.id,
        step_id: batch.turn_id,
        source_index:,
      ))
  }
}

/// Clearance passed: persist the effective arguments (write-once) and
/// commit the call's effect intent, then the runtime executes the tool.
fn dispatch_tool(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source: AgentMessage,
  source_index: Int,
  effective_arguments: JsonValue,
  replay: operation.ReplayPolicy,
) -> Action {
  case find_call(batch, source_index), source_call(source, source_index) {
    Error(report), _ | _, Error(report) -> Fault(report:)
    Ok(CallPlanned(source_index: _, result_entry:)), Ok(call) -> {
      let calls =
        replace_call(
          batch.calls,
          source_index,
          CallEffectPending(source_index:, result_entry:, replay:),
        )
      let next =
        RunState(
          control:,
          settings:,
          phase: Tools(batch: ToolBatch(..batch, calls:)),
          inbox:,
          latest_assistant: latest,
        )
      Dispatch(
        intent: ToolRequest(
          operation: op.id,
          step_id: batch.turn_id,
          source_index:,
          call:,
          effective_arguments:,
          replay:,
          result_entry:,
        ),
        next:,
        tx: op_tx(op, in, [
          build.set_tool_args(
            op.id,
            batch.turn_id,
            source_index,
            effective_arguments,
          ),
          build.set_op_state(op.id, next),
        ]),
      )
    }
    Ok(_), Ok(_) ->
      Fault(report: corruption.report(
        at: "machine/planner.dispatch_tool",
        on: build.op_key(op.id),
        expected: "a planned call at the cleared index",
        context: "clearance observed for a non-planned call",
      ))
  }
}

/// Orphan recovery for an effect-pending call (pi §4.5): safe replay
/// re-executes with persisted arguments under the same reserved id;
/// anything else synthesizes an interrupted result, preserving the latest
/// durable checkpoint content when one exists.
fn recover_tool(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source: AgentMessage,
  source_index: Int,
  replay_still_safe: Bool,
  checkpoint: Option(AgentMessage),
) -> Action {
  case find_call(batch, source_index), source_call(source, source_index) {
    Error(report), _ | _, Error(report) -> Fault(report:)
    Ok(CallEffectPending(source_index: _, result_entry:, replay:)), Ok(call) -> {
      let replayable = case control, replay {
        Running, ReplaySafe -> replay_still_safe
        _, _ -> False
      }
      case replayable {
        True ->
          Dispatch(
            intent: ToolReplay(
              operation: op.id,
              step_id: batch.turn_id,
              source_index:,
              call:,
              arguments_key: build.tool_args_key(
                op.id,
                batch.turn_id,
                source_index,
              ),
              result_entry:,
            ),
            next: RunState(
              control:,
              settings:,
              phase: Tools(batch:),
              inbox:,
              latest_assistant: latest,
            ),
            tx: op_tx(op, in, []),
          )
        False ->
          case interrupted_tool_result(call, checkpoint, in.now) {
            Error(report) -> Fault(report:)
            Ok(result) ->
              stage_result(
                op,
                in,
                control,
                settings,
                batch,
                inbox,
                latest,
                source_index,
                result,
                False,
              )
          }
      }
    }
    Ok(_), Ok(_) ->
      Fault(report: corruption.report(
        at: "machine/planner.recover_tool",
        on: build.op_key(op.id),
        expected: "an effect-pending call at the orphaned index",
        context: "orphan observed for a non-pending call",
      ))
  }
}

/// Stages one finalized result: the complete message enters
/// `pending.entry/{result}` and the call becomes outcome-ready, awaiting
/// source-ordered materialization.
fn stage_result(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  source_index: Int,
  result: AgentMessage,
  terminate: Bool,
) -> Action {
  case result {
    ToolResultMessage(..) ->
      case find_call(batch, source_index) {
        Error(report) -> Fault(report:)
        Ok(CallCompleted(..)) | Ok(CallOutcomeReady(..)) ->
          Fault(report: corruption.report(
            at: "machine/planner.stage_result",
            on: build.op_key(op.id),
            expected: "a planned or effect-pending call to stage",
            context: "result observed for an already staged call",
          ))
        Ok(CallPlanned(source_index: _, result_entry:))
        | Ok(CallEffectPending(source_index: _, result_entry:, replay: _)) -> {
          let calls =
            replace_call(
              batch.calls,
              source_index,
              CallOutcomeReady(source_index:, result_entry:, terminate:),
            )
          let next =
            RunState(
              control:,
              settings:,
              phase: Tools(batch: ToolBatch(..batch, calls:)),
              inbox:,
              latest_assistant: latest,
            )
          transition(op, in, next, [
            build.set_pending(result_entry, PendingMessage(message: result)),
            build.set_op_state(op.id, next),
          ])
        }
      }
    _ ->
      Fault(report: corruption.report(
        at: "machine/planner.stage_result",
        on: build.op_key(op.id),
        expected: "a tool-result message",
        context: "a non-tool-result observation payload",
      ))
  }
}

/// Materializes the contiguous outcome-ready run at the frontier: result
/// entries enter the tree in source order, their staged registers die,
/// tool-reported usage lands in the ledger, and the batch either
/// continues or checkpoints (pi §3.8).
fn materialize(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  batch: ToolBatch,
  inbox: Inbox,
  latest: Option(EntryId),
  ready_run: List(ToolCallState),
) -> Action {
  let placed =
    list.try_fold(ready_run, #([], in.leaf, in.generator), fn(acc, call) {
      let #(writes, parent, generator) = acc
      case call {
        CallOutcomeReady(source_index: _, result_entry:, terminate:) ->
          case deref_pending(in, result_entry) {
            Error(report) -> Error(report)
            Ok(PendingMessage(message:)) -> {
              let entry_writes = [
                build.message_entry(result_entry, parent, message, terminate),
                build.delete_pending(result_entry),
              ]
              let #(usage_writes, generator) = case message {
                ToolResultMessage(usage: Some(usage), ..) -> {
                  let #(usage_id, generator) = ids.mint_usage(generator)
                  #(
                    [build.usage_row(usage_id, Some(result_entry), usage)],
                    generator,
                  )
                }
                _ -> #([], generator)
              }
              Ok(#(
                list.flatten([writes, entry_writes, usage_writes]),
                Some(result_entry),
                generator,
              ))
            }
            Ok(PendingCustom(..)) ->
              Error(corruption.report(
                at: "machine/planner.materialize",
                on: ids.entry_id_to_string(result_entry),
                expected: "a staged tool-result message",
                context: "a custom pending payload under a result id",
              ))
          }
        _ ->
          Error(corruption.report(
            at: "machine/planner.materialize",
            on: build.op_key(op.id),
            expected: "an outcome-ready call in the ready run",
            context: "a non-ready call",
          ))
      }
    })
  case placed {
    Error(report) -> Fault(report:)
    Ok(#(entry_writes, newest, _generator)) -> {
      let newest = case newest {
        Some(id) -> id
        // Unreachable: `ready_run` is non-empty at every call site.
        None -> batch.assistant_entry
      }
      let calls =
        list.map(batch.calls, fn(call) {
          case call {
            CallOutcomeReady(source_index:, result_entry:, terminate:) ->
              case
                list.any(ready_run, fn(ready) {
                  case ready {
                    CallOutcomeReady(source_index: ready_index, ..) ->
                      ready_index == source_index
                    _ -> False
                  }
                })
              {
                True -> CallCompleted(source_index:, result_entry:, terminate:)
                False -> call
              }
            _ -> call
          }
        })
      let all_completed =
        list.all(calls, fn(call) {
          case call {
            CallCompleted(..) -> True
            _ -> False
          }
        })
      case all_completed {
        False -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Tools(batch: ToolBatch(..batch, calls:)),
              inbox:,
              latest_assistant: latest,
            )
          transition(
            op,
            in,
            next,
            list.flatten([
              entry_writes,
              [
                build.set_leaf(op.strand, Some(newest)),
                build.set_op_state(op.id, next),
              ],
            ]),
          )
        }
        True -> {
          let every_terminates =
            list.all(calls, fn(call) {
              case call {
                CallCompleted(terminate:, ..) -> terminate
                _ -> False
              }
            })
          let continuation = case every_terminates {
            True -> MayFinish(include_final_assistant: False)
            False -> NeedAssistant(overflow_recovery_used: False)
          }
          let skip_inbox_once = case every_terminates {
            True -> False
            False -> True
          }
          let next =
            RunState(
              control:,
              settings:,
              phase: Checkpoint(checkpoint: CheckpointPhase(
                continuation:,
                trigger: newest,
                threshold_checked: None,
                skip_inbox_once:,
              )),
              inbox:,
              latest_assistant: latest,
            )
          let args_deletes =
            list.map(in.tool_args_keys, build.delete_tool_args_key)
          transition(
            op,
            in,
            next,
            list.flatten([
              entry_writes,
              [build.set_leaf(op.strand, Some(newest))],
              args_deletes,
              [build.set_op_state(op.id, next)],
            ]),
          )
        }
      }
    }
  }
}

// --- deferred responses (pi §3.2 deferred table) --------------------------

fn deferred_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  deferred: DeferredState,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case deferred {
    DeferredSuspended(
      step_id:,
      source_entry:,
      poll:,
      configuration:,
      stream_options:,
    ) ->
      case control {
        // Cancelled while suspended: no fetch starts; best-effort remote
        // cancellation is the runtime's cleanup, not durable state.
        CancelRequested(..) ->
          drain_writes_then_finish_aborted(
            op,
            in,
            control,
            settings,
            AwaitingDeferred(deferred:),
            inbox,
            latest,
          )
        Running ->
          case in.poll_permit {
            False -> Wait(until: DeferredPollDue(source_entry:))
            True ->
              case in.observation {
                ObservedResolution(resolution: ModelUnresolved(error:)) -> {
                  let next =
                    RunState(
                      control:,
                      settings:,
                      phase: FailureDrain(
                        error:,
                        provenance: ConfigurationProvenance,
                      ),
                      inbox:,
                      latest_assistant: latest,
                    )
                  transition(op, in, next, [build.set_op_state(op.id, next)])
                }
                ObservedResolution(resolution: ModelResolved) -> {
                  let #(response_entry, generator) =
                    ids.mint_entry(in.generator)
                  let #(usage, _generator) = ids.mint_usage(generator)
                  let next_poll = poll + 1
                  let next =
                    RunState(
                      control:,
                      settings:,
                      phase: AwaitingDeferred(deferred: DeferredEffectPending(
                        step_id:,
                        source_entry:,
                        poll: next_poll,
                        response_entry:,
                        usage:,
                        configuration:,
                        stream_options:,
                      )),
                      inbox:,
                      latest_assistant: latest,
                    )
                  Dispatch(
                    intent: DeferredFetch(
                      operation: op.id,
                      step_id:,
                      poll: next_poll,
                      source_entry:,
                      response_entry:,
                      usage:,
                      configuration:,
                      stream_options:,
                    ),
                    next:,
                    tx: op_tx(op, in, [build.set_op_state(op.id, next)]),
                  )
                }
                NoObservation ->
                  AwaitEffect(key: PollAdmissionKey(
                    operation: op.id,
                    step_id:,
                    poll: poll + 1,
                  ))
                other -> unexpected_observation(op, "deferred suspended", other)
              }
          }
      }
    DeferredEffectPending(
      step_id:,
      source_entry:,
      poll:,
      response_entry:,
      usage:,
      configuration:,
      stream_options:,
    ) ->
      case in.observation {
        ObservedDeferredSettled(settled:) ->
          settle_poll(
            op,
            in,
            control,
            settings,
            step_id,
            source_entry,
            poll,
            response_entry,
            usage,
            configuration,
            stream_options,
            inbox,
            latest,
            settled,
          )
        // Either the orphan report itself, or the resolution answer this
        // handler asked for on the pass before (`OrphanPollUnknown`
        // below). Both say the same thing — the pending poll's outcome
        // is unknown — and both must reach the replacement path; the
        // resolution arrives as its own observation, so matching only
        // the orphan report would fault the strand on the very pass
        // that answered its question.
        ObservedDeferredOrphaned | ObservedResolution(..) ->
          case control {
            CancelRequested(..) ->
              settle_cancelled_poll(
                op,
                in,
                control,
                settings,
                response_entry,
                usage,
                configuration,
                [],
                inbox,
                latest,
              )
            Running ->
              case in.poll_permit {
                False -> Wait(until: DeferredPollDue(source_entry:))
                True ->
                  case orphan_poll_resolution(in) {
                    OrphanPollUnresolved(error) -> {
                      let next =
                        RunState(
                          control:,
                          settings:,
                          phase: FailureDrain(
                            error:,
                            provenance: ConfigurationProvenance,
                          ),
                          inbox:,
                          latest_assistant: latest,
                        )
                      transition(op, in, next, [build.set_op_state(op.id, next)])
                    }
                    OrphanPollResolved -> {
                      // Replace the unknown poll under fresh ids at the
                      // same poll number; the old reserved strings are
                      // abandoned, never materialized.
                      let #(fresh_entry, generator) =
                        ids.mint_entry(in.generator)
                      let #(fresh_usage, _generator) = ids.mint_usage(generator)
                      let next =
                        RunState(
                          control:,
                          settings:,
                          phase: AwaitingDeferred(
                            deferred: DeferredEffectPending(
                              step_id:,
                              source_entry:,
                              poll:,
                              response_entry: fresh_entry,
                              usage: fresh_usage,
                              configuration:,
                              stream_options:,
                            ),
                          ),
                          inbox:,
                          latest_assistant: latest,
                        )
                      Dispatch(
                        intent: DeferredFetch(
                          operation: op.id,
                          step_id:,
                          poll:,
                          source_entry:,
                          response_entry: fresh_entry,
                          usage: fresh_usage,
                          configuration:,
                          stream_options:,
                        ),
                        next:,
                        tx: op_tx(op, in, [build.set_op_state(op.id, next)]),
                      )
                    }
                    OrphanPollUnknown ->
                      AwaitEffect(key: PollAdmissionKey(
                        operation: op.id,
                        step_id:,
                        poll:,
                      ))
                  }
              }
          }
        NoObservation ->
          AwaitEffect(key: PollKey(
            operation: op.id,
            step_id:,
            poll:,
            response_entry:,
          ))
        other -> unexpected_observation(op, "deferred effect_pending", other)
      }
  }
}

fn orphan_poll_resolution(in: PlannerInputs) -> OrphanPollResolution {
  // The orphan observation itself carries no resolution; a second pass
  // with `ObservedResolution` answers it. This helper only exists to keep
  // the deferred handler readable.
  case in.observation {
    ObservedResolution(resolution: ModelResolved) -> OrphanPollResolved
    ObservedResolution(resolution: ModelUnresolved(error:)) ->
      OrphanPollUnresolved(error)
    _ -> OrphanPollUnknown
  }
}

fn settle_poll(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  step_id: String,
  source_entry: EntryId,
  poll: Int,
  response_entry: EntryId,
  usage_id: UsageId,
  configuration: StrandConfiguration,
  stream_options: JsonValue,
  inbox: Inbox,
  _latest: Option(EntryId),
  settled: SettledAssistantMessage,
) -> Action {
  let message = classification.message(settled)
  let classify_ctx =
    ClassifyCtx(
      control:,
      // Polls persist no intended output limit; the length-below rule is
      // disabled.
      intended_output_limit: 0,
      expected_model: configuration.model,
      expected_api: message_api(message),
      error_retryable: settled_retryable(message),
    )
  case classification.classify(settled, classify_ctx) {
    CorruptClassification(report:) -> Fault(report:)
    // A really-settled poll under cancelled control commits normalized to
    // aborted, retaining its content and reported usage (pi §4.6 —
    // review finding ORCH-M3): only an *unknown-outcome* orphan gets the
    // zero-usage synthetic below.
    CancelledClassification -> {
      let aborted = normalize_stop(message, Aborted, None)
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: MayFinish(include_final_assistant: True),
            trigger: response_entry,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, aborted, usage_id, in.leaf, next),
      )
    }
    DeferredValidClassification(handle:) ->
      // A pending response must carry a handle completely equal to its
      // source handle; it becomes the next source. A mismatch is
      // normalized to a durable error (pi §3.2).
      case in.deferred_source == Some(handle) {
        True -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: AwaitingDeferred(deferred: DeferredSuspended(
                step_id:,
                source_entry: response_entry,
                poll:,
                configuration:,
                stream_options:,
              )),
              inbox:,
              latest_assistant: Some(response_entry),
            )
          transition(
            op,
            in,
            next,
            settle_writes(op, response_entry, message, usage_id, in.leaf, next),
          )
        }
        False ->
          settle_poll_failure(
            op,
            in,
            control,
            settings,
            response_entry,
            usage_id,
            normalize_stop(
              message,
              Errored,
              Some(
                "deferred handle mismatch: the pending handle does not equal its source",
              ),
            ),
            inbox,
            OperationError(
              code: "deferred_handle_mismatch",
              message: "the pending handle does not equal its source",
              details: None,
            ),
          )
      }
    DeferredInvalidClassification ->
      settle_poll_failure(
        op,
        in,
        control,
        settings,
        response_entry,
        usage_id,
        normalize_stop(
          message,
          Errored,
          Some(
            "invalid deferred handle: the pending response carried no usable handle",
          ),
        ),
        inbox,
        OperationError(
          code: "invalid_deferred_handle",
          message: "the pending response carried no usable handle",
          details: None,
        ),
      )
    ToolUseClassification(truncated: _) -> {
      let generation_like =
        GenerationContext(
          step_id:,
          trigger: source_entry,
          configuration:,
          stream_options:,
          retry: in.retry_policy,
          overflow_recovery_used: False,
        )
      case plan_batch(in, message, generation_like, response_entry) {
        Error(report) -> Fault(report:)
        Ok(batch) -> {
          let next =
            RunState(
              control:,
              settings:,
              phase: Tools(batch:),
              inbox:,
              latest_assistant: Some(response_entry),
            )
          transition(
            op,
            in,
            next,
            settle_writes(op, response_entry, message, usage_id, in.leaf, next),
          )
        }
      }
    }
    FinishedClassification -> {
      let next =
        RunState(
          control:,
          settings:,
          phase: Checkpoint(checkpoint: CheckpointPhase(
            continuation: MayFinish(include_final_assistant: True),
            trigger: response_entry,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
          inbox:,
          latest_assistant: Some(response_entry),
        )
      transition(
        op,
        in,
        next,
        settle_writes(op, response_entry, message, usage_id, in.leaf, next),
      )
    }
    // Polls have no retry or compaction path: every error settles as
    // response-provenance failure drain (pi §3.2).
    OverflowClassification ->
      settle_poll_failure(
        op,
        in,
        control,
        settings,
        response_entry,
        usage_id,
        normalize_stop(message, Errored, Some(overflow_error_message(message))),
        inbox,
        overflow_operation_error(message),
      )
    ErrorClassification(retryable: _, error_message:) ->
      settle_poll_failure(
        op,
        in,
        control,
        settings,
        response_entry,
        usage_id,
        message,
        inbox,
        OperationError(
          code: "provider_error",
          message: error_message,
          details: None,
        ),
      )
  }
}

fn settle_poll_failure(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
  inbox: Inbox,
  error: OperationError,
) -> Action {
  let next =
    RunState(
      control:,
      settings:,
      phase: FailureDrain(
        error:,
        provenance: ResponseProvenance(entry: response_entry),
      ),
      inbox:,
      latest_assistant: Some(response_entry),
    )
  transition(
    op,
    in,
    next,
    settle_writes(op, response_entry, message, usage_id, in.leaf, next),
  )
}

/// Synthetic settlement of a cancelled *unknown-outcome* poll under the
/// existing reserved ids — the orphan path only; a really-settled poll
/// under cancelled control retains its reported usage in `settle_poll`
/// (pi §4.6). A cancelled may-finish checkpoint then leads to the
/// aborted terminal transaction.
fn settle_cancelled_poll(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  response_entry: EntryId,
  usage_id: UsageId,
  configuration: StrandConfiguration,
  partial: List(message.AssistantBlock),
  inbox: Inbox,
  _latest: Option(EntryId),
) -> Action {
  let synthetic =
    AssistantMessage(
      content: partial,
      api: "unknown",
      provider: configuration.model.provider,
      model: configuration.model.model_id,
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: build.zero_usage(),
      stop_reason: Aborted,
      deferred: None,
      error_message: Some("deferred poll aborted"),
      raw_stop_reason: None,
      end_turn: None,
      timestamp: in.now,
    )
  let next =
    RunState(
      control:,
      settings:,
      phase: Checkpoint(checkpoint: CheckpointPhase(
        continuation: MayFinish(include_final_assistant: True),
        trigger: response_entry,
        threshold_checked: None,
        skip_inbox_once: False,
      )),
      inbox:,
      latest_assistant: Some(response_entry),
    )
  transition(
    op,
    in,
    next,
    settle_writes(op, response_entry, synthetic, usage_id, in.leaf, next),
  )
}

// --- failure drain (pi §3.12) ---------------------------------------------

fn failure_drain_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  error: OperationError,
  provenance: operation.FailureProvenance,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  let phase = FailureDrain(error:, provenance:)
  case inbox.writes {
    [_, ..] ->
      drain_failure_input(
        op,
        in,
        control,
        settings,
        phase,
        inbox,
        latest,
        inbox.writes,
        fn(inbox) { Inbox(..inbox, writes: []) },
      )
    [] ->
      case inbox.steer {
        [_, ..] -> {
          let #(consumed, left) =
            take_per_mode(inbox.steer, settings.steering_mode)
          drain_failure_input(
            op,
            in,
            control,
            settings,
            phase,
            inbox,
            latest,
            consumed,
            fn(inbox) { Inbox(..inbox, steer: left) },
          )
        }
        [] ->
          case inbox.follow_up {
            [_, ..] -> {
              let #(consumed, left) =
                take_per_mode(inbox.follow_up, settings.follow_up_mode)
              drain_failure_input(
                op,
                in,
                control,
                settings,
                phase,
                inbox,
                latest,
                consumed,
                fn(inbox) { Inbox(..inbox, follow_up: left) },
              )
            }
            [] -> {
              // No recovering input: finish failed, without the run-end
              // hook or another provider request.
              let result =
                RunLastResult(
                  operation: op.id,
                  leaf: in.leaf,
                  outcome: RunFailed(error:),
                  final_assistant: latest,
                )
              finish(op, in, run_pending_ids(control, inbox, None), result, [])
            }
          }
      }
  }
}

/// Applies one drained batch during failure drain. Projecting
/// user-context input atomically clears the failure into a
/// `need_assistant` checkpoint; unprojected custom writes append without
/// clearing it.
fn drain_failure_input(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  phase: RunPhase,
  inbox: Inbox,
  latest: Option(EntryId),
  consumed: List(EntryId),
  remove: fn(Inbox) -> Inbox,
) -> Action {
  case place_pending(in, in.leaf, consumed) {
    Error(report) -> Fault(report:)
    Ok(Placement(writes: entry_writes, newest:, projecting:)) -> {
      let remaining = remove(inbox)
      let next_phase = case projecting, newest {
        True, Some(newest) ->
          Checkpoint(checkpoint: CheckpointPhase(
            continuation: NeedAssistant(overflow_recovery_used: False),
            trigger: newest,
            threshold_checked: None,
            skip_inbox_once: True,
          ))
        _, _ -> phase
      }
      let next =
        RunState(
          control:,
          settings:,
          phase: next_phase,
          inbox: remaining,
          latest_assistant: latest,
        )
      let leaf_writes = case newest {
        Some(id) -> [build.set_leaf(op.strand, Some(id))]
        None -> []
      }
      transition(
        op,
        in,
        next,
        list.flatten([
          entry_writes,
          leaf_writes,
          [build.set_op_state(op.id, next)],
        ]),
      )
    }
  }
}

// --- cancellation reconciliation (pi §4.6) --------------------------------

fn reconcile_run(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  phase: RunPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case phase {
    // A pending assistant effect settles (really or synthetically) as
    // aborted first; the resulting cancelled checkpoint reconciles next.
    Assistant(generation: GenerationEffectPending(
      context:,
      attempt:,
      response_entry:,
      usage:,
      intended_output_limit:,
      context_window: _,
      request_api:,
    )) ->
      case in.observation {
        ObservedAssistantSettled(settled:, overflow_preparation: _) ->
          settle_assistant(
            op,
            in,
            control,
            settings,
            context,
            attempt,
            response_entry,
            usage,
            intended_output_limit,
            request_api,
            inbox,
            latest,
            settled,
            None,
          )
        ObservedAssistantOrphaned(partial:) ->
          settle_orphaned_assistant(
            op,
            in,
            control,
            settings,
            context,
            attempt,
            response_entry,
            usage,
            inbox,
            latest,
            partial,
          )
        NoObservation ->
          AwaitEffect(key: AssistantKey(
            operation: op.id,
            step_id: context.step_id,
            response_entry:,
          ))
        other ->
          unexpected_observation(
            op,
            "cancelled assistant effect_pending",
            other,
          )
      }
    // Tool batches reconcile through the ordinary machinery: planned
    // calls stage aborted synthetics, pending effects settle or
    // synthesize interruption, staged outcomes materialize in source
    // order; the closing checkpoint then drains writes and finishes.
    Tools(batch:) ->
      tools_action(op, in, control, settings, batch, inbox, latest)
    AwaitingDeferred(deferred:) ->
      deferred_action(op, in, control, settings, deferred, inbox, latest)
    // Structural work not yet atomically published is discarded.
    Starting
    | Checkpoint(..)
    | Assistant(..)
    | Compacting(..)
    | FailureDrain(..) ->
      drain_writes_then_finish_aborted(
        op,
        in,
        control,
        settings,
        phase,
        inbox,
        latest,
      )
  }
}

/// Under cancelled control every accepted deferred write is still applied
/// in order (without changing phase or starting work); the aborted
/// terminal transaction follows once the writes are drained.
fn drain_writes_then_finish_aborted(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  settings: RunSettings,
  phase: RunPhase,
  inbox: Inbox,
  latest: Option(EntryId),
) -> Action {
  case inbox.writes {
    [_, ..] ->
      case place_pending(in, in.leaf, inbox.writes) {
        Error(report) -> Fault(report:)
        Ok(Placement(writes: entry_writes, newest:, projecting: _)) -> {
          let next =
            RunState(
              control:,
              settings:,
              phase:,
              inbox: Inbox(..inbox, writes: []),
              latest_assistant: latest,
            )
          let leaf_writes = case newest {
            Some(id) -> [build.set_leaf(op.strand, Some(id))]
            None -> []
          }
          transition(
            op,
            in,
            next,
            list.flatten([
              entry_writes,
              leaf_writes,
              [build.set_op_state(op.id, next)],
            ]),
          )
        }
      }
    [] -> {
      let staged = case phase {
        Tools(batch:) -> staged_result_ids(batch)
        _ -> []
      }
      let result =
        RunLastResult(
          operation: op.id,
          leaf: in.leaf,
          outcome: RunAborted,
          final_assistant: latest,
        )
      finish(op, in, run_pending_ids(control, inbox, Some(staged)), result, [])
    }
  }
}

// --- structural work (pi §3.9) --------------------------------------------

fn structural_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  structural: StructuralDecision,
  host: StructuralHost,
) -> Action {
  case control {
    CancelRequested(..) ->
      case host {
        InRunHost(settings:, inbox:, latest:, reason:, resume:) ->
          reconcile_run(
            op,
            in,
            control,
            settings,
            Compacting(reason:, structural:, resume_after: resume),
            inbox,
            latest,
          )
        StandaloneHost(..) ->
          finish(
            op,
            in,
            [],
            CompactionLastResult(
              operation: op.id,
              leaf: in.leaf,
              outcome: StructuralAborted,
            ),
            [],
          )
        NavigationHost(..) ->
          finish(
            op,
            in,
            [],
            NavigationLastResult(
              operation: op.id,
              leaf: in.leaf,
              old_leaf: op.source_leaf,
              outcome: StructuralAborted,
              summary: None,
            ),
            [],
          )
      }
    Running ->
      case structural {
        Deciding(task_id:) -> decide_structural(op, in, task_id, host)
        Generating(task_id:, generation:) ->
          generate_structural(op, in, task_id, generation, host)
      }
  }
}

fn decide_structural(
  op: Operation,
  in: PlannerInputs,
  task_id: String,
  host: StructuralHost,
) -> Action {
  case in.observation {
    ObservedStructuralDecision(verdict: VerdictDeclined) ->
      case host {
        InRunHost(reason:, settings:, inbox:, latest:, resume:) ->
          case reason {
            // Threshold decline: restore the marked checkpoint.
            ThresholdReason -> {
              let next =
                RunState(
                  control: Running,
                  settings:,
                  phase: Checkpoint(checkpoint: resume),
                  inbox:,
                  latest_assistant: latest,
                )
              transition(op, in, next, [build.set_op_state(op.id, next)])
            }
            // Overflow decline: the request still cannot fit.
            OverflowReason -> {
              let next =
                RunState(
                  control: Running,
                  settings:,
                  phase: FailureDrain(
                    error: OperationError(
                      code: "context_overflow",
                      message: "overflow compaction was declined",
                      details: None,
                    ),
                    provenance: StructuralProvenance(task_id:),
                  ),
                  inbox:,
                  latest_assistant: latest,
                )
              transition(op, in, next, [build.set_op_state(op.id, next)])
            }
          }
        StandaloneHost(..) ->
          finish(
            op,
            in,
            [],
            CompactionLastResult(
              operation: op.id,
              leaf: in.leaf,
              outcome: StructuralDeclined,
            ),
            [],
          )
        NavigationHost(..) ->
          // A declined summarized navigation moves nothing.
          finish(
            op,
            in,
            [],
            NavigationLastResult(
              operation: op.id,
              leaf: in.leaf,
              old_leaf: op.source_leaf,
              outcome: StructuralDeclined,
              summary: None,
            ),
            [],
          )
      }
    ObservedStructuralDecision(verdict: VerdictSupplied(summary:, usage:)) ->
      publish_structural(op, in, task_id, host, summary, usage, True)
    ObservedStructuralDecision(verdict: VerdictGenerate) -> {
      let #(result_entry, _generator) = ids.mint_entry(in.generator)
      let #(kind, reason) = case host {
        InRunHost(reason: ThresholdReason, ..) -> #(
          CompactionSummary,
          ThresholdSummary,
        )
        InRunHost(reason: OverflowReason, ..) -> #(
          CompactionSummary,
          OverflowSummary,
        )
        StandaloneHost(..) -> #(CompactionSummary, ManualSummary)
        NavigationHost(..) -> #(BranchSummary, ManualSummary)
      }
      let context =
        SummaryContext(
          task_id:,
          result_entry:,
          kind:,
          configuration: in.configuration,
          stream_options: in.stream_options,
          retry: in.retry_policy,
          reason:,
        )
      let generation = SummaryReady(context:, next_attempt: 1)
      let next = host_state(op, host, Generating(task_id:, generation:))
      Transition(
        next:,
        tx: Tx(writes: [build.set_op_state(op.id, next)], expected: [
          build.expect_op_state(op.id, in.op_state_seq),
          build.expect_configuration(op.strand, in.configuration_seq),
        ]),
      )
    }
    NoObservation -> AwaitEffect(key: DecisionKey(operation: op.id, task_id:))
    other -> unexpected_observation(op, "structural deciding", other)
  }
}

fn generate_structural(
  op: Operation,
  in: PlannerInputs,
  task_id: String,
  generation: SummaryGeneration,
  host: StructuralHost,
) -> Action {
  case generation {
    SummaryReady(context:, next_attempt:) ->
      case in.observation {
        ObservedResolution(resolution: ModelUnresolved(error:)) ->
          structural_failure(op, in, task_id, host, error)
        ObservedResolution(resolution: ModelResolved) -> {
          let next_generation =
            SummaryEffectPending(
              context:,
              attempt: next_attempt,
              request: None,
              usage_ids: [],
            )
          let next =
            host_state(
              op,
              host,
              Generating(task_id:, generation: next_generation),
            )
          transition(op, in, next, [build.set_op_state(op.id, next)])
        }
        NoObservation ->
          AwaitEffect(key: SummaryKey(
            operation: op.id,
            task_id:,
            attempt: next_attempt,
          ))
        other -> unexpected_observation(op, "summary ready", other)
      }
    SummaryEffectPending(context:, attempt:, request: Some(request), usage_ids:) ->
      case in.observation {
        ObservedSummaryReturned(usage:) -> {
          // Usage settles and the request field clears atomically; the
          // next pass asks for progress.
          let next_generation =
            SummaryEffectPending(
              context:,
              attempt:,
              request: None,
              usage_ids: list.append(usage_ids, [request.usage]),
            )
          let next =
            host_state(
              op,
              host,
              Generating(task_id:, generation: next_generation),
            )
          transition(op, in, next, [
            build.usage_row(request.usage, None, usage),
            build.set_op_state(op.id, next),
          ])
        }
        ObservedSummaryOrphaned ->
          advance_orphaned_summary(
            op,
            in,
            task_id,
            context,
            attempt,
            usage_ids,
            host,
          )
        NoObservation ->
          AwaitEffect(key: SummaryKey(operation: op.id, task_id:, attempt:))
        other -> unexpected_observation(op, "summary request pending", other)
      }
    SummaryEffectPending(context:, attempt:, request: None, usage_ids:) ->
      case usage_ids {
        // No request has been made yet this attempt: the first nested
        // request is always required.
        [] ->
          dispatch_summary_request(op, in, task_id, context, attempt, [], host)
        [_, ..] ->
          case in.observation {
            ObservedSummaryProgress(progress: SummaryNeedsRequest) ->
              dispatch_summary_request(
                op,
                in,
                task_id,
                context,
                attempt,
                usage_ids,
                host,
              )
            ObservedSummaryProgress(progress: SummaryProduced(summary:, usage:)) ->
              publish_structural(op, in, task_id, host, summary, usage, False)
            ObservedSummaryProgress(progress: SummaryFailed(error:, retryable:)) ->
              case retryable && attempt < context.retry.max_attempts {
                True -> {
                  let next_generation =
                    SummaryRetryWait(
                      context:,
                      next_attempt: attempt + 1,
                      not_before: in.now + backoff(context.retry, attempt),
                      error_message: error.message,
                    )
                  let next =
                    host_state(
                      op,
                      host,
                      Generating(task_id:, generation: next_generation),
                    )
                  transition(op, in, next, [build.set_op_state(op.id, next)])
                }
                False -> structural_failure(op, in, task_id, host, error)
              }
            ObservedSummaryOrphaned ->
              advance_orphaned_summary(
                op,
                in,
                task_id,
                context,
                attempt,
                usage_ids,
                host,
              )
            NoObservation ->
              AwaitEffect(key: SummaryProgressKey(
                operation: op.id,
                task_id:,
                attempt:,
              ))
            other -> unexpected_observation(op, "summary progress", other)
          }
      }
    SummaryRetryWait(context:, next_attempt:, not_before:, error_message: _) ->
      case in.now >= not_before {
        True -> {
          let next_generation = SummaryReady(context:, next_attempt:)
          let next =
            host_state(
              op,
              host,
              Generating(task_id:, generation: next_generation),
            )
          transition(op, in, next, [build.set_op_state(op.id, next)])
        }
        False -> Wait(until: RetryNotBefore(at: not_before))
      }
  }
}

/// An orphaned structural attempt is wholly uncertain: advance to a later
/// ready attempt under the captured policy, or fail at the cap (pi §4.5).
fn advance_orphaned_summary(
  op: Operation,
  in: PlannerInputs,
  task_id: String,
  context: SummaryContext,
  attempt: Int,
  _usage_ids: List(UsageId),
  host: StructuralHost,
) -> Action {
  case attempt < context.retry.max_attempts {
    True -> {
      let next_generation = SummaryReady(context:, next_attempt: attempt + 1)
      let next =
        host_state(op, host, Generating(task_id:, generation: next_generation))
      transition(op, in, next, [build.set_op_state(op.id, next)])
    }
    False ->
      structural_failure(
        op,
        in,
        task_id,
        host,
        OperationError(
          code: "interrupted",
          message: "structural generation was interrupted at the attempt cap",
          details: None,
        ),
      )
  }
}

fn dispatch_summary_request(
  op: Operation,
  in: PlannerInputs,
  task_id: String,
  context: SummaryContext,
  attempt: Int,
  usage_ids: List(UsageId),
  host: StructuralHost,
) -> Action {
  let #(usage, _generator) = ids.mint_usage(in.generator)
  let index = list.length(usage_ids)
  let next_generation =
    SummaryEffectPending(
      context:,
      attempt:,
      request: Some(SummaryRequest(index:, usage:)),
      usage_ids:,
    )
  let next =
    host_state(op, host, Generating(task_id:, generation: next_generation))
  Dispatch(
    intent: SummaryProviderRequest(
      operation: op.id,
      task_id:,
      attempt:,
      request_index: index,
      usage:,
      context:,
    ),
    next:,
    tx: op_tx(op, in, [build.set_op_state(op.id, next)]),
  )
}

/// Rebuilds the host's total operation state around a new structural
/// decision.
fn host_state(
  _op: Operation,
  host: StructuralHost,
  structural: StructuralDecision,
) -> OperationState {
  case host {
    InRunHost(reason:, settings:, inbox:, latest:, resume:) ->
      RunState(
        control: Running,
        settings:,
        phase: Compacting(reason:, structural:, resume_after: resume),
        inbox:,
        latest_assistant: latest,
      )
    StandaloneHost(custom_instructions:) ->
      CompactionState(control: Running, custom_instructions:, structural:)
    NavigationHost(target:, label:, custom_instructions:) ->
      NavigationState(
        control: Running,
        navigation: SummarizedNavigation(
          target:,
          label:,
          custom_instructions:,
          structural:,
        ),
      )
  }
}

/// Terminal or in-run failure for structural work.
fn structural_failure(
  op: Operation,
  in: PlannerInputs,
  task_id: String,
  host: StructuralHost,
  error: OperationError,
) -> Action {
  case host {
    InRunHost(settings:, inbox:, latest:, ..) -> {
      let provenance = case error.code {
        "model_unavailable" | "configured_tools_unavailable" ->
          ConfigurationProvenance
        _ -> StructuralProvenance(task_id:)
      }
      let next =
        RunState(
          control: Running,
          settings:,
          phase: FailureDrain(error:, provenance:),
          inbox:,
          latest_assistant: latest,
        )
      transition(op, in, next, [build.set_op_state(op.id, next)])
    }
    StandaloneHost(..) ->
      finish(
        op,
        in,
        [],
        CompactionLastResult(
          operation: op.id,
          leaf: in.leaf,
          outcome: StructuralFailed(error:),
        ),
        [],
      )
    NavigationHost(..) ->
      finish(
        op,
        in,
        [],
        NavigationLastResult(
          operation: op.id,
          leaf: in.leaf,
          old_leaf: op.source_leaf,
          outcome: StructuralFailed(error:),
          summary: None,
        ),
        [],
      )
  }
}

/// Publishes the structural result: a compaction entry plus leaf move
/// (resuming the run or finishing the standalone operation), or the
/// navigation terminal transaction with its writes inline (pi §3.10).
fn publish_structural(
  op: Operation,
  in: PlannerInputs,
  _task_id: String,
  host: StructuralHost,
  summary: String,
  usage: Option(Usage),
  from_hook: Bool,
) -> Action {
  case host {
    InRunHost(settings:, inbox:, latest:, resume:, ..) ->
      case compaction_publication(op, in, summary, usage, from_hook) {
        Error(report) -> Fault(report:)
        Ok(#(writes, _entry_id)) -> {
          let next =
            RunState(
              control: Running,
              settings:,
              phase: Checkpoint(checkpoint: resume),
              inbox:,
              latest_assistant: latest,
            )
          transition(
            op,
            in,
            next,
            list.append(writes, [build.set_op_state(op.id, next)]),
          )
        }
      }
    StandaloneHost(..) ->
      case compaction_publication(op, in, summary, usage, from_hook) {
        Error(report) -> Fault(report:)
        Ok(#(writes, entry_id)) ->
          finish(
            op,
            in,
            [],
            CompactionLastResult(
              operation: op.id,
              leaf: Some(entry_id),
              outcome: StructuralCompleted,
            ),
            writes,
          )
      }
    NavigationHost(target:, label:, custom_instructions: _) -> {
      let #(summary_entry, generator) = ids.mint_entry(in.generator)
      case op.source_leaf {
        None ->
          Fault(report: corruption.report(
            at: "machine/planner.publish_structural",
            on: build.op_key(op.id),
            expected: "a non-null source leaf for a summarized navigation",
            context: "null source leaf",
          ))
        Some(source_leaf) -> {
          let hook_usage_writes = case from_hook, usage {
            True, Some(usage) -> {
              let #(usage_id, _generator) = ids.mint_usage(generator)
              [build.usage_row(usage_id, Some(summary_entry), usage)]
            }
            _, _ -> []
          }
          let label_writes = case label {
            Some(label) -> [build.set_entry_label(target, label)]
            None -> []
          }
          let writes =
            list.flatten([
              hook_usage_writes,
              [
                build.set_leaf(op.strand, Some(target)),
                build.branch_summary_entry(
                  summary_entry,
                  Some(target),
                  source_leaf,
                  summary,
                  from_hook,
                  usage,
                ),
                build.set_leaf(op.strand, Some(summary_entry)),
              ],
              label_writes,
            ])
          finish(
            op,
            in,
            [],
            NavigationLastResult(
              operation: op.id,
              leaf: Some(summary_entry),
              old_leaf: op.source_leaf,
              outcome: StructuralCompleted,
              summary: Some(summary_entry),
            ),
            writes,
          )
        }
      }
    }
  }
}

/// Builds the compaction-entry publication writes: hook usage row (when
/// hook-supplied usage exists), the compaction entry parented on the
/// current leaf, and the leaf move.
fn compaction_publication(
  op: Operation,
  in: PlannerInputs,
  summary: String,
  usage: Option(Usage),
  from_hook: Bool,
) -> Result(#(List(Write), EntryId), CorruptionReport) {
  case in.preparation {
    Some(CompactionPreparation(retained_tail:, tokens_before:, ..)) -> {
      let #(entry_id, generator) = ids.mint_entry(in.generator)
      let hook_usage_writes = case from_hook, usage {
        True, Some(usage) -> {
          let #(usage_id, _generator) = ids.mint_usage(generator)
          [build.usage_row(usage_id, Some(entry_id), usage)]
        }
        _, _ -> []
      }
      Ok(#(
        list.flatten([
          hook_usage_writes,
          [
            build.compaction_entry(
              entry_id,
              in.leaf,
              summary,
              retained_tail,
              tokens_before,
              from_hook,
              usage,
            ),
            build.set_leaf(op.strand, Some(entry_id)),
          ],
        ]),
        entry_id,
      ))
    }
    Some(BranchSummaryPreparation(..)) ->
      Error(corruption.report(
        at: "machine/planner.compaction_publication",
        on: build.op_key(op.id),
        expected: "a compaction preparation",
        context: "a branch-summary preparation on a compaction task",
      ))
    None ->
      Error(corruption.report(
        at: "machine/planner.compaction_publication",
        on: build.op_key(op.id),
        expected: "the structural preparation in the inputs",
        context: "preparation absent",
      ))
  }
}

// --- navigation (pi §3.10) ------------------------------------------------

fn navigation_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  navigation: Navigation,
) -> Action {
  case navigation {
    UnsummarizedNavigation(target:, label:) ->
      case control {
        CancelRequested(..) ->
          finish(
            op,
            in,
            [],
            NavigationLastResult(
              operation: op.id,
              leaf: in.leaf,
              old_leaf: op.source_leaf,
              outcome: StructuralAborted,
              summary: None,
            ),
            [],
          )
        Running -> {
          let label_writes = case target, label {
            Some(target), Some(label) -> [build.set_entry_label(target, label)]
            _, _ -> []
          }
          finish(
            op,
            in,
            [],
            NavigationLastResult(
              operation: op.id,
              leaf: target,
              old_leaf: op.source_leaf,
              outcome: StructuralCompleted,
              summary: None,
            ),
            list.flatten([[build.set_leaf(op.strand, target)], label_writes]),
          )
        }
      }
    SummarizedNavigation(target:, label:, custom_instructions:, structural:) ->
      structural_action(
        op,
        in,
        control,
        structural,
        NavigationHost(target:, label:, custom_instructions:),
      )
  }
}

// --- terminal transactions (pi §3.13) -------------------------------------

/// Builds the terminal transaction: optional publication writes, deletion
/// of every operation-owned register, the strand's terminal result, and
/// the strand-state clear preserving concurrently accepted next-run ids.
///
/// `tool_args_keys` and `preparation_keys` are the runtime's listing of
/// this operation's existing registers, not a scan the pure machine could
/// perform itself — deletion is therefore over-approximate by
/// construction, matching pi's own defensive scan. Deleting an
/// already-absent key is a no-op, so listing one extra key costs nothing
/// and missing one leaves an orphaned register rather than corrupting the
/// commit (spec-gaps WP-D item 4).
fn finish(
  op: Operation,
  in: PlannerInputs,
  pending_ids: List(EntryId),
  result: LastResult,
  publication: List(Write),
) -> Action {
  let writes =
    list.flatten([
      publication,
      [build.delete_op_meta(op.id), build.delete_op_state(op.id)],
      list.map(in.tool_args_keys, build.delete_tool_args_key),
      list.map(in.preparation_keys, build.delete_preparation_key),
      list.map(pending_ids, build.delete_pending),
      [
        build.set_last_result(op.strand, result),
        // The operation-keyed copy, in the same atomic transaction: the
        // strand register above is latest-wins (pi §3.13), so it alone
        // cannot answer "what did *this* operation conclude" once a
        // later run lands — `api.await_strand_result` keys on this row.
        build.set_op_result(op.id, result),
        build.set_strand_state(
          op.strand,
          StrandState(
            current_operation: None,
            pending_next_run: in.strand_state.pending_next_run,
          ),
        ),
      ],
    ])
  Finish(
    result:,
    tx: Tx(writes:, expected: [
      build.expect_op_state(op.id, in.op_state_seq),
      build.expect_strand_state(op.strand, in.strand_state_seq),
    ]),
  )
}

/// Every operation-owned `pending.entry` id at a run's terminal boundary:
/// remaining inbox items, drained items, and staged unmaterialized
/// outcomes.
fn run_pending_ids(
  control: Control,
  inbox: Inbox,
  staged: Option(List(EntryId)),
) -> List(EntryId) {
  let drained = case control {
    Running -> []
    CancelRequested(drained_steer:, drained_follow_up:, ..) ->
      list.append(drained_steer, drained_follow_up)
  }
  list.flatten([
    inbox.steer,
    inbox.follow_up,
    inbox.writes,
    drained,
    option.unwrap(staged, []),
  ])
}

fn staged_result_ids(batch: ToolBatch) -> List(EntryId) {
  list.filter_map(batch.calls, fn(call) {
    case call {
      CallOutcomeReady(result_entry:, ..) -> Ok(result_entry)
      _ -> Error(Nil)
    }
  })
}

// --- shared helpers -------------------------------------------------------

/// The default transition action: writes guarded by the op-state seq.
fn transition(
  op: Operation,
  in: PlannerInputs,
  next: OperationState,
  writes: List(Write),
) -> Action {
  Transition(next:, tx: op_tx(op, in, writes))
}

fn op_tx(op: Operation, in: PlannerInputs, writes: List(Write)) -> Tx {
  Tx(writes:, expected: [build.expect_op_state(op.id, in.op_state_seq)])
}

fn unexpected_observation(
  op: Operation,
  at_phase: String,
  _observation: Observation,
) -> Action {
  Fault(report: corruption.report(
    at: "machine/planner.next_action",
    on: build.op_key(op.id),
    expected: "an observation matching the " <> at_phase <> " phase",
    context: "a mismatched observation",
  ))
}

/// Builds entry inserts (with their `pending.entry` deletes) for queued
/// ids in acceptance order, chaining parents from the current leaf.
fn place_pending(
  in: PlannerInputs,
  leaf: Option(EntryId),
  items: List(EntryId),
) -> Result(Placement, CorruptionReport) {
  list.try_fold(
    items,
    Placement(writes: [], newest: None, projecting: False),
    fn(acc, id) {
      let parent = case acc.newest {
        Some(newest) -> Some(newest)
        None -> leaf
      }
      use pending <- result.try(deref_pending(in, id))
      let #(entry_write, projects) = case pending {
        PendingMessage(message:) -> #(
          build.message_entry(id, parent, message, False),
          True,
        )
        PendingCustom(custom_type:, data:) -> #(
          build.custom_entry(id, parent, custom_type, data),
          list.contains(in.projected_custom_types, custom_type),
        )
      }
      Ok(Placement(
        writes: list.append(acc.writes, [entry_write, build.delete_pending(id)]),
        newest: Some(id),
        projecting: acc.projecting || projects,
      ))
    },
  )
}

fn deref_pending(
  in: PlannerInputs,
  id: EntryId,
) -> Result(PendingEntry, CorruptionReport) {
  case dict.get(in.pending, ids.entry_id_to_string(id)) {
    Ok(pending) -> Ok(pending)
    Error(Nil) ->
      Error(corruption.report(
        at: "machine/planner.deref_pending",
        on: ids.entry_id_to_string(id),
        expected: "a pending.entry payload for a referenced id",
        context: "payload absent",
      ))
  }
}

/// Appends born-placed messages, chaining parents from the leaf.
fn append_messages(
  generator: ids.Generator,
  leaf: Option(EntryId),
  messages: List(AgentMessage),
) -> #(List(Write), Option(EntryId), ids.Generator) {
  list.fold(messages, #([], None, generator), fn(acc, message) {
    let #(writes, newest, generator) = acc
    let parent = case newest {
      Some(id) -> Some(id)
      None -> leaf
    }
    let #(id, generator) = ids.mint_entry(generator)
    #(
      list.append(writes, [build.message_entry(id, parent, message, False)]),
      Some(id),
      generator,
    )
  })
}

/// Plans the tool batch from a settled response: one planned call per
/// tool-call block, with result ids minted as followers of the response
/// id so the group is time-cohesive (pi §1.2 rule 2).
fn plan_batch(
  in: PlannerInputs,
  message: AgentMessage,
  context: GenerationContext,
  response_entry: EntryId,
) -> Result(ToolBatch, CorruptionReport) {
  case message {
    AssistantMessage(content:, ..) -> {
      let #(calls, _generator) =
        content
        |> list.index_map(fn(block, index) { #(block, index) })
        |> list.fold(#([], in.generator), fn(acc, indexed) {
          let #(calls, generator) = acc
          let #(block, index) = indexed
          case block {
            AssistantToolCall(..) -> {
              let #(result_entry, generator) =
                ids.mint_follower(generator, of: response_entry)
              #(
                [CallPlanned(source_index: index, result_entry:), ..calls],
                generator,
              )
            }
            AssistantText(..) | AssistantThinking(..) -> #(calls, generator)
          }
        })
      Ok(ToolBatch(
        assistant_entry: response_entry,
        configuration: context.configuration,
        turn_id: context.step_id,
        calls: list.reverse(calls),
      ))
    }
    _ ->
      Error(corruption.report(
        at: "machine/planner.plan_batch",
        on: ids.entry_id_to_string(response_entry),
        expected: "an assistant message with tool calls",
        context: "a non-assistant message",
      ))
  }
}

fn find_call(
  batch: ToolBatch,
  source_index: Int,
) -> Result(ToolCallState, CorruptionReport) {
  let found =
    list.find(batch.calls, fn(call) {
      case call {
        CallPlanned(source_index: index, ..)
        | CallEffectPending(source_index: index, ..)
        | CallOutcomeReady(source_index: index, ..)
        | CallCompleted(source_index: index, ..) -> index == source_index
      }
    })
  case found {
    Ok(call) -> Ok(call)
    Error(Nil) ->
      Error(corruption.report(
        at: "machine/planner.find_call",
        on: int.to_string(source_index),
        expected: "a call at the observed source index",
        context: "no such call in the batch",
      ))
  }
}

fn replace_call(
  calls: List(ToolCallState),
  source_index: Int,
  replacement: ToolCallState,
) -> List(ToolCallState) {
  list.map(calls, fn(call) {
    let index = case call {
      CallPlanned(source_index: index, ..)
      | CallEffectPending(source_index: index, ..)
      | CallOutcomeReady(source_index: index, ..)
      | CallCompleted(source_index: index, ..) -> index
    }
    case index == source_index {
      True -> replacement
      False -> call
    }
  })
}

/// Dereferences the tool call block at `source_index` in the batch's
/// source assistant message.
fn source_call(
  source: AgentMessage,
  source_index: Int,
) -> Result(ToolCall, CorruptionReport) {
  case source {
    AssistantMessage(content:, ..) ->
      case
        content
        |> list.drop(source_index)
        |> list.first
      {
        Ok(AssistantToolCall(call:)) -> Ok(call)
        Ok(_) | Error(Nil) ->
          Error(corruption.report(
            at: "machine/planner.source_call",
            on: int.to_string(source_index),
            expected: "a tool-call block at the source index",
            context: "no tool call at that index",
          ))
      }
    _ ->
      Error(corruption.report(
        at: "machine/planner.source_call",
        on: int.to_string(source_index),
        expected: "an assistant source message",
        context: "a non-assistant message",
      ))
  }
}

/// A machine-built synthetic tool result carrying only explanatory text.
fn synthetic_tool_result(
  source: AgentMessage,
  source_index: Int,
  text: String,
  usage: Option(Usage),
  now: Int,
) -> Result(AgentMessage, CorruptionReport) {
  use call <- result.try(source_call(source, source_index))
  Ok(ToolResultMessage(
    tool_call_id: call.id,
    tool_name: call.name,
    content: [ToolResultText(text:, text_signature: None)],
    details: None,
    usage:,
    added_tool_names: None,
    is_error: True,
    timestamp: now,
  ))
}

/// The synthetic interrupted result for an unreplayable orphaned call:
/// checkpoint content (when present) plus the explicit warning, with
/// checkpoint details and usage preserved and termination hints ignored
/// (pi §4.5).
fn interrupted_tool_result(
  call: ToolCall,
  checkpoint: Option(AgentMessage),
  now: Int,
) -> Result(AgentMessage, CorruptionReport) {
  let warning =
    ToolResultText(text: interrupted_warning(), text_signature: None)
  case checkpoint {
    None ->
      Ok(ToolResultMessage(
        tool_call_id: call.id,
        tool_name: call.name,
        content: [warning],
        details: None,
        usage: None,
        added_tool_names: None,
        is_error: True,
        timestamp: now,
      ))
    Some(ToolResultMessage(content:, details:, usage:, ..)) ->
      Ok(ToolResultMessage(
        tool_call_id: call.id,
        tool_name: call.name,
        content: list.append(content, [warning]),
        details:,
        usage:,
        added_tool_names: None,
        is_error: True,
        timestamp: now,
      ))
    Some(_) ->
      Error(corruption.report(
        at: "machine/planner.interrupted_tool_result",
        on: call.id,
        expected: "a tool-result checkpoint payload",
        context: "a non-tool-result checkpoint",
      ))
  }
}

/// The explicit unknown-outcome warning shared by synthetic settlements.
fn interrupted_warning() -> String {
  "interrupted: the preceding content is the latest committed partial; "
  <> "newer live output may be missing and the external outcome is unknown"
}

/// The synthetic response recovery commits under reserved ids when a
/// request's outcome is unknown (pi §4.5).
fn synthetic_response(
  context: GenerationContext,
  partial: List(message.AssistantBlock),
  stop_reason: message.StopReason,
  error_message: String,
  now: Int,
) -> AgentMessage {
  AssistantMessage(
    content: partial,
    api: "unknown",
    provider: context.configuration.model.provider,
    model: context.configuration.model.model_id,
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: build.zero_usage(),
    stop_reason:,
    deferred: None,
    error_message: Some(error_message),
    raw_stop_reason: None,
    end_turn: None,
    timestamp: now,
  )
}

/// Rewrites a settled message's stop reason (the two deliberate commit
/// normalizations, pi §3.7), preserving content and usage and stamping a
/// human-readable reason when supplied.
fn normalize_stop(
  message: AgentMessage,
  stop_reason: message.StopReason,
  error_message: Option(String),
) -> AgentMessage {
  case message {
    AssistantMessage(..) ->
      AssistantMessage(
        ..message,
        stop_reason:,
        error_message: case error_message {
          Some(text) -> Some(text)
          None -> message.error_message
        },
      )
    other -> other
  }
}

fn overflow_error_message(message: AgentMessage) -> String {
  case message {
    AssistantMessage(error_message: Some(text), ..) -> text
    AssistantMessage(stop_reason: Length, ..) ->
      classification.overflow_message_prefix
      <> ": length stop below the intended output limit"
    _ -> classification.overflow_message_prefix
  }
}

fn overflow_operation_error(message: AgentMessage) -> OperationError {
  OperationError(
    code: "context_overflow",
    message: overflow_error_message(message),
    details: None,
  )
}

fn message_usage(message: AgentMessage) -> Usage {
  case message {
    AssistantMessage(usage:, ..) -> usage
    _ -> build.zero_usage()
  }
}

fn message_api(message: AgentMessage) -> String {
  case message {
    AssistantMessage(api:, ..) -> api
    _ -> "unknown"
  }
}

fn message_stop_reason(message: AgentMessage) -> message.StopReason {
  case message {
    AssistantMessage(stop_reason:, ..) -> stop_reason
    _ -> message.Stop
  }
}

/// Whether the adapter marked the settled error retryable. The settled
/// message itself has no such field; the runtime encodes the judgment in
/// `raw_stop_reason` as `"retryable"` by adapter convention.
fn settled_retryable(message: AgentMessage) -> Bool {
  case message {
    AssistantMessage(raw_stop_reason: Some("retryable"), ..) -> True
    _ -> False
  }
}

/// Exponential retry backoff, saturating instead of overflowing: the
/// delay for finished attempt `n` (1-based) is `base * 2^(n-1)`, capped
/// at 2^20 times the base.
fn backoff(retry: NormalizedRetryPolicy, finished_attempt: Int) -> Int {
  let exponent = int.min(int.max(finished_attempt - 1, 0), 20)
  retry.base_delay_ms * power_of_two(exponent)
}

fn power_of_two(exponent: Int) -> Int {
  case exponent <= 0 {
    True -> 1
    False -> 2 * power_of_two(exponent - 1)
  }
}

fn take_per_mode(
  items: List(EntryId),
  mode: operation.QueueMode,
) -> #(List(EntryId), List(EntryId)) {
  case mode {
    ConsumeAll -> #(items, [])
    OneAtATime ->
      case items {
        [first, ..rest] -> #([first], rest)
        [] -> #([], [])
      }
  }
}
