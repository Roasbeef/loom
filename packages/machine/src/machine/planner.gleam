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
//// of the spec. The vocabulary comes first and in full: all twenty
//// types are declared before the first function body, so nothing below
//// introduces a name the reader has not already met. After that, each
//// section decides one question, and the list below says which — enough
//// to find the section you want without reading the ones you don't.
////
//// - **planner inputs** — the vocabulary the *runtime* speaks:
////   `PlannerInputs` and the answer types it carries (`ThresholdStatus`,
////   `RequestAdmission`, `ModelResolution`, `StructuralVerdict`,
////   `SummaryProgress`, `Observation`). Decides nothing; it fixes what
////   the machine is permitted to know.
//// - **actions** — the vocabulary the *machine* speaks: `EffectKey`
////   (what it is waiting for), `EffectIntent` (what it wants performed),
////   `WaitUntil`, and `Action` itself.
//// - **internal vocabulary** — the eight private types the handlers
////   below speak in among themselves. Four of them are bundles: a
////   handler takes the record its values arrived in (`RunPass`,
////   `AssistantAttempt`, `StructuralTask`, `Fetch`) rather than the
////   record exploded into parameters, and rebuilds it at the one hop
////   that changes a field. The other four are small private alphabets
////   one section uses to say something to the next.
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
import gleam/bool
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
  type SummaryContext, type SummaryGeneration, type SummaryRequest,
  type ToolBatch, type ToolCallState, Assistant, AwaitingDeferred, BranchSummary,
  BranchSummaryPreparation, CallCompleted, CallEffectPending, CallOutcomeReady,
  CallPlanned, CancelRequested, Checkpoint, CheckpointPhase, Compacting,
  CompactionIntent, CompactionLastResult, CompactionPreparation,
  CompactionSettings, CompactionState, CompactionSummary, CompletedByAssistant,
  CompletedByTerminatedTools, ConfigurationProvenance, ConsumeAll, Deciding,
  DeferredEffectPending, DeferredSuspended, FailureDrain, Generating,
  GenerationContext, GenerationEffectPending, GenerationReady,
  GenerationRetryWait, Inbox, ManualSummary, MayFinish, NavigationIntent,
  NavigationLastResult, NavigationState, NeedAssistant, OneAtATime,
  OperationError, OverflowReason, OverflowSummary, PendingCustom, PendingMessage,
  ReplaySafe, ResponseProvenance, RunAborted, RunCompleted, RunFailed, RunIntent,
  RunLastResult, RunSettings, RunState, Running, Starting, StructuralAborted,
  StructuralCompleted, StructuralDeclined, StructuralFailed,
  StructuralProvenance, SummarizedNavigation, SummaryContext,
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
// The eight types that are not part of anyone's contract. Four of them
// are bundles — the values a section's handlers all carry, kept in the
// record they came from instead of exploded into parameters — and four
// are small private alphabets one section's handlers use to say
// something to each other. They sit here, with the public vocabulary
// rather than beside their users, so that the rule holds without
// exception — every type this module has is declared before the first
// function body, and no handler thousands of lines down introduces one
// cold.
//
// The bundles are not a convenience. A wide call is one argument per
// line under `gleam format`, so a value threaded through n hops costs 2n
// lines of pure plumbing and nothing checks the argument order but the
// types; this module once spent 28% of itself that way. Each bundle is
// the record its values were destructured out of, so passing it is a
// restoration rather than an invention, and a handler that means to
// change one field says so with a record update at that one hop.

/// Everything one pass over a *run* carries that is not the phase: the
/// operation, the driver's inputs, and the four `RunState` fields every
/// phase handler shares. `next_action` destructures the state once and
/// builds this; nothing below re-declares those fields.
///
/// The phase stays out deliberately. Each handler already receives its
/// own phase's payload, and a handler's whole job is to produce the
/// *next* phase — `run_state` is what puts a pass and a phase back
/// together into the state a transition commits.
///
/// It is named `pass` and not `step` because a *step* in pi's spec is a
/// generation step (`step_id`), which is a different thing.
type RunPass {
  RunPass(
    op: Operation,
    in: PlannerInputs,
    control: Control,
    settings: RunSettings,
    inbox: Inbox,
    latest: Option(EntryId),
  )
}

/// One assistant generation attempt in flight: the step's captured
/// context, which attempt of the retry ladder this is, the response and
/// usage ids the settlement is obliged to write under, and the two
/// values classification compares the response against. It is
/// `GenerationEffectPending` without `context_window`, which only the
/// dispatch that reserved the ids ever reads — so the settle paths below
/// take one value where they took four to six.
type AssistantAttempt {
  AssistantAttempt(
    context: GenerationContext,
    number: Int,
    response_entry: EntryId,
    usage: UsageId,
    intended_output_limit: Int,
    request_api: String,
  )
}

/// One structural task in hand: the operation and the driver's inputs,
/// the task's own id, and the host whose lifecycle it belongs to. The
/// structural section's handlers all speak about the same task, so they
/// take it as one value; `host` is what makes an in-run compaction, a
/// standalone compaction and a summarized navigation one set of
/// handlers rather than three.
type StructuralTask {
  StructuralTask(
    op: Operation,
    in: PlannerInputs,
    task_id: String,
    host: StructuralHost,
  )
}

/// The fetch a deferred operation is making, or about to make: which
/// generation step it belongs to, the entry holding the handle being
/// polled, how many permits have been spent against that handle, and the
/// configuration and stream options the original request was captured
/// with. It is `DeferredSuspended`'s whole payload, and both deferred
/// states carry it, so the handlers below pass it as one value rather
/// than as five.
type Fetch {
  Fetch(
    step_id: String,
    source_entry: EntryId,
    poll: Int,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
}

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
    RunState(control:, settings:, phase:, inbox:, latest_assistant: latest),
      RunIntent(..)
    -> {
      let pass = RunPass(op:, in:, control:, settings:, inbox:, latest:)
      case control {
        Running -> run_action(pass, phase)
        CancelRequested(..) -> reconcile_run(pass, phase)
      }
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

fn run_action(pass: RunPass, phase: RunPhase) -> Action {
  let RunPass(op:, in:, control:, settings:, inbox:, latest:) = pass
  case phase {
    Starting -> begin_run(pass)
    Checkpoint(checkpoint:) -> checkpoint_action(pass, checkpoint)
    Assistant(generation:) -> assistant_action(pass, generation)
    Tools(batch:) -> tools_action(pass, batch)
    Compacting(reason:, structural:, resume_after:) ->
      structural_action(
        op,
        in,
        control,
        structural,
        InRunHost(reason:, settings:, inbox:, latest:, resume: resume_after),
      )
    AwaitingDeferred(deferred:) -> deferred_action(pass, deferred)
    FailureDrain(error:, provenance:) ->
      failure_drain_action(pass, error, provenance)
  }
}

/// `starting` → `checkpoint`: consume the run-start hook's output. The
/// hook may rerun after a crash; the consuming transition commits once.
fn begin_run(pass: RunPass) -> Action {
  let RunPass(op:, in:, ..) = pass
  case in.observation {
    ObservedRunStart(messages:) -> {
      let #(entry_writes, newest, _generator) =
        append_messages(in.generator, in.leaf, messages)

      // The boundary triggers on the newest injected message, or on the
      // existing leaf when the hook injected nothing. Neither existing
      // is impossible after acceptance, so it is corruption.
      use trigger <- or_fault(option.to_result(
        option.or(newest, in.leaf),
        corruption.report(
          at: "machine/planner.begin_run",
          on: build.op_key(op.id),
          expected: "a strand leaf after run acceptance",
          context: "null leaf with no injected messages",
        ),
      ))
      let next =
        run_state(
          pass,
          Checkpoint(checkpoint: CheckpointPhase(
            continuation: NeedAssistant(overflow_recovery_used: False),
            trigger:,
            threshold_checked: None,
            skip_inbox_once: False,
          )),
        )
      let leaf_writes = case newest {
        Some(id) -> [build.set_leaf(op.strand, Some(id))]
        None -> []
      }
      transition(
        pass,
        next,
        list.flatten([
          entry_writes,
          leaf_writes,
          [build.set_op_state(op.id, next)],
        ]),
      )
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
fn checkpoint_action(pass: RunPass, checkpoint: CheckpointPhase) -> Action {
  // Steps 1–2 are skipped once (generation clears the flag); otherwise the
  // first eligible non-empty queue wins, in order.
  case checkpoint.skip_inbox_once, pass.inbox.writes, pass.inbox.steer {
    True, _, _ -> after_inbox(pass, checkpoint)
    False, [_, ..], _ -> apply_writes(pass, checkpoint)
    False, [], [_, ..] -> consume_queue(pass, checkpoint, SteerQueue)
    False, [], [] -> after_inbox(pass, checkpoint)
  }
}

fn after_inbox(pass: RunPass, checkpoint: CheckpointPhase) -> Action {
  // Step 3: threshold compaction, at most once per trigger boundary.
  let unchecked = checkpoint.threshold_checked != Some(checkpoint.trigger)
  case pass.settings.compaction.enabled && unchecked, pass.in.threshold {
    True, ThresholdExceeded(outcome: Prepared(preparation:)) ->
      enter_threshold_compaction(pass, checkpoint, preparation)
    True, ThresholdExceeded(outcome: EmptyPreparation) ->
      mark_threshold_checked(pass, checkpoint)
    _, _ -> after_threshold(pass, checkpoint)
  }
}

/// Step 3, declined by an empty preparation: atomically mark the boundary
/// checked and continue — no structural lifecycle.
fn mark_threshold_checked(
  pass: RunPass,
  checkpoint: CheckpointPhase,
) -> Action {
  let RunPass(op:, ..) = pass
  let marked =
    CheckpointPhase(..checkpoint, threshold_checked: Some(checkpoint.trigger))
  let next = run_state(pass, Checkpoint(checkpoint: marked))
  transition(pass, next, [build.set_op_state(op.id, next)])
}

/// Steps 4–5: no threshold work this pass — dispatch on the checkpoint's
/// continuation, and on a may-finish continuation, on whether there is
/// still eligible follow-up input to drain first.
fn after_threshold(pass: RunPass, checkpoint: CheckpointPhase) -> Action {
  case checkpoint.continuation, pass.inbox.follow_up {
    NeedAssistant(..), _ -> start_generation(pass, checkpoint)
    MayFinish(..), [_, ..] -> consume_queue(pass, checkpoint, FollowUpQueue)
    MayFinish(include_final_assistant:), [] ->
      finish_boundary(pass, checkpoint, include_final_assistant)
  }
}

/// Steps 1: atomically apply every accepted deferred write.
fn apply_writes(pass: RunPass, checkpoint: CheckpointPhase) -> Action {
  let RunPass(op:, inbox:, ..) = pass
  use Placement(writes: entry_writes, newest:, projecting:) <- or_fault(
    place_pending(pass, inbox.writes),
  )
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
    run_state(
      RunPass(..pass, inbox: remaining),
      Checkpoint(checkpoint: next_checkpoint),
    )
  let leaf_writes = case newest {
    Some(id) -> [build.set_leaf(op.strand, Some(id))]
    None -> []
  }
  transition(
    pass,
    next,
    list.flatten([entry_writes, leaf_writes, [build.set_op_state(op.id, next)]]),
  )
}

/// Steps 2 and 5: consume eligible steer or follow-up input per its mode.
fn consume_queue(
  pass: RunPass,
  checkpoint: CheckpointPhase,
  queue: DrainedQueue,
) -> Action {
  let RunPass(op:, settings:, inbox:, ..) = pass
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
  use Placement(writes: entry_writes, newest:, projecting: _) <- or_fault(
    place_pending(pass, consumed),
  )

  // A drain is only reached with an eligible queue, so placing nothing
  // means the queue and the mode disagreed — durable state, corrupt.
  use newest <- or_fault(option.to_result(
    newest,
    corruption.report(
      at: "machine/planner.consume_queue",
      on: build.op_key(op.id),
      expected: "a non-empty eligible queue",
      context: "queue drain with nothing to place",
    ),
  ))
  let remaining = case queue {
    SteerQueue -> Inbox(..inbox, steer: left)
    FollowUpQueue -> Inbox(..inbox, follow_up: left)
  }
  let next =
    run_state(
      RunPass(..pass, inbox: remaining),
      Checkpoint(checkpoint: CheckpointPhase(
        continuation: NeedAssistant(overflow_recovery_used: False),
        trigger: newest,
        threshold_checked: checkpoint.threshold_checked,
        skip_inbox_once: True,
      )),
    )
  transition(
    pass,
    next,
    list.flatten([
      entry_writes,
      [build.set_leaf(op.strand, Some(newest)), build.set_op_state(op.id, next)],
    ]),
  )
}

/// Step 3, taken: enter threshold compaction, copying the checkpoint into
/// `resume_after` marked checked so this boundary is never rechecked.
fn enter_threshold_compaction(
  pass: RunPass,
  checkpoint: CheckpointPhase,
  preparation: StructuralPreparation,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  let #(task_entry, _generator) = ids.mint_entry(in.generator)
  let task_id = ids.entry_id_to_string(task_entry)
  let marked =
    CheckpointPhase(..checkpoint, threshold_checked: Some(checkpoint.trigger))
  let next =
    run_state(
      pass,
      Compacting(
        reason: ThresholdReason,
        structural: Deciding(task_id:),
        resume_after: marked,
      ),
    )
  transition(pass, next, [
    build.set_preparation(op.id, task_id, preparation),
    build.set_op_state(op.id, next),
  ])
}

/// Step 4: `need_assistant` starts a generation step, snapshotting the
/// current configuration, stream options, and retry policy inline and
/// clearing `skip_inbox_once`.
fn start_generation(pass: RunPass, checkpoint: CheckpointPhase) -> Action {
  let RunPass(op:, in:, ..) = pass
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
    run_state(
      pass,
      Assistant(generation: GenerationReady(context:, next_attempt: 1)),
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
  pass: RunPass,
  checkpoint: CheckpointPhase,
  include_final_assistant: Bool,
) -> Action {
  let RunPass(op:, in:, control:, inbox:, latest:, ..) = pass
  case in.observation {
    ObservedRunEnd(follow_up: Some(message)) -> {
      // A run-end follow-up is born placed: entry and need_assistant
      // state commit together, with no pending register.
      let #(entry_id, _generator) = ids.mint_entry(in.generator)
      let next =
        run_state(
          pass,
          Checkpoint(checkpoint: CheckpointPhase(
            continuation: NeedAssistant(overflow_recovery_used: False),
            trigger: entry_id,
            threshold_checked: checkpoint.threshold_checked,
            skip_inbox_once: False,
          )),
        )
      transition(pass, next, [
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

/// The three states of a generation step: waiting to be admitted, in
/// flight, or sleeping off a retry backoff. Each is one step of the
/// intent/settle sandwich, and this function only says which.
fn assistant_action(pass: RunPass, generation: Generation) -> Action {
  let RunPass(op:, in:, ..) = pass
  case generation {
    GenerationReady(context:, next_attempt:) ->
      admit_generation(pass, context, next_attempt)
    GenerationEffectPending(
      context:,
      attempt:,
      response_entry:,
      usage:,
      intended_output_limit:,
      context_window: _,
      request_api:,
    ) ->
      await_generation(
        pass,
        AssistantAttempt(
          context:,
          number: attempt,
          response_entry:,
          usage:,
          intended_output_limit:,
          request_api:,
        ),
      )
    GenerationRetryWait(context:, next_attempt:, not_before:, error_message: _) -> {
      use <- bool.guard(
        when: in.now < not_before,
        return: Wait(until: RetryNotBefore(at: not_before)),
      )
      let next =
        run_state(
          pass,
          Assistant(generation: GenerationReady(context:, next_attempt:)),
        )
      transition(pass, next, [build.set_op_state(op.id, next)])
    }
  }
}

/// `ready`: the pre-request hook and identity resolution decide whether
/// this attempt is made at all. Admission is the last point before ids
/// are reserved — a refusal costs nothing durable, while an admission
/// mints the response and usage ids the settlement (real or synthetic)
/// is obliged to write under.
fn admit_generation(
  pass: RunPass,
  context: GenerationContext,
  next_attempt: Int,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  case in.observation {
    ObservedAdmission(admission: AdmissionUnavailable(error:)) ->
      enter_configuration_failure_drain(pass, error)
    ObservedAdmission(admission: Admitted(
      stream_options:,
      intended_output_limit:,
      context_window:,
      api: request_api,
    )) -> {
      let #(response_entry, generator) = ids.mint_entry(in.generator)
      let #(usage, _generator) = ids.mint_usage(generator)
      let next =
        run_state(
          pass,
          Assistant(generation: GenerationEffectPending(
            context:,
            attempt: next_attempt,
            response_entry:,
            usage:,
            intended_output_limit:,
            context_window:,
            request_api:,
          )),
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
}

/// `effect_pending`: the request is in flight and exactly one of three
/// things can happen to it — it settles, it is reported orphaned, or it
/// is still running and the pass parks on it.
fn await_generation(pass: RunPass, attempt: AssistantAttempt) -> Action {
  let RunPass(op:, in:, ..) = pass
  let AssistantAttempt(context:, response_entry:, ..) = attempt
  case in.observation {
    ObservedAssistantSettled(settled:, overflow_preparation:) ->
      settle_assistant(pass, attempt, settled, overflow_preparation)
    ObservedAssistantOrphaned(partial:) ->
      settle_orphaned_assistant(pass, attempt, partial)
    NoObservation ->
      AwaitEffect(key: AssistantKey(
        operation: op.id,
        step_id: context.step_id,
        response_entry:,
      ))
    other -> unexpected_observation(op, "assistant effect_pending", other)
  }
}

fn settle_assistant(
  pass: RunPass,
  attempt: AssistantAttempt,
  settled: SettledAssistantMessage,
  overflow_preparation: Option(PreparationOutcome),
) -> Action {
  let AssistantAttempt(
    context:,
    response_entry:,
    usage:,
    intended_output_limit:,
    request_api:,
    ..,
  ) = attempt
  let RunPass(control:, ..) = pass
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

  // One destination per classification; the arms below are dispatch
  // only, so the normative order of `classification.classify` stays
  // readable in one screen.
  case classification.classify(settled, classify_ctx) {
    CorruptClassification(report:) -> Fault(report:)
    CancelledClassification ->
      settle_at_may_finish(
        pass,
        response_entry,
        usage,
        normalize_stop(message, Aborted, None),
      )
    OverflowClassification ->
      settle_overflow(pass, attempt, message, overflow_preparation)
    DeferredValidClassification(handle: _) ->
      suspend_on_deferred_handle(pass, attempt, message)
    DeferredInvalidClassification ->
      settle_failure_drain(
        pass,
        response_entry,
        usage,
        normalize_stop(
          message,
          Errored,
          Some("invalid deferred handle: the response carried no usable handle"),
        ),
        OperationError(
          code: "invalid_deferred_handle",
          message: "the deferred response carried no usable handle",
          details: None,
        ),
      )
    ErrorClassification(retryable:, error_message:) ->
      settle_provider_error(pass, attempt, message, retryable, error_message)
    ToolUseClassification(truncated: _) ->
      settle_to_tool_batch(pass, context, response_entry, usage, message)
    FinishedClassification ->
      settle_at_may_finish(pass, response_entry, usage, message)
  }
}

/// An overflow gets exactly one recovery per generation step. The first
/// one diverts into a compaction task and resumes with the one-shot
/// marked spent; a second overflow, or a first with nothing left to
/// compact, drains as a failure. Either way the response itself commits
/// normalized to `error` — pi §3.7 records an overflow that way at
/// commit, deliberately.
fn settle_overflow(
  pass: RunPass,
  attempt: AssistantAttempt,
  message: AgentMessage,
  overflow_preparation: Option(PreparationOutcome),
) -> Action {
  let AssistantAttempt(context:, response_entry:, usage:, ..) = attempt
  let normalized =
    normalize_stop(message, Errored, Some(overflow_error_message(message)))
  let drain_as_failure = fn() {
    settle_failure_drain(
      pass,
      response_entry,
      usage,
      normalized,
      overflow_operation_error(message),
    )
  }

  // A spent recovery drains whatever the preparation would have said,
  // so its arm matches on the first subject alone and never asks for
  // one.
  case context.overflow_recovery_used, overflow_preparation {
    True, _ -> drain_as_failure()
    False, None ->
      AwaitEffect(key: OverflowPreparationKey(
        operation: pass.op.id,
        response_entry:,
      ))
    False, Some(EmptyPreparation) -> drain_as_failure()
    False, Some(Prepared(preparation:)) ->
      enter_overflow_compaction(pass, attempt, normalized, message, preparation)
  }
}

/// The first overflow's recovery. The response entry, its leaf move, its
/// usage row, the preparation and the new state are one transaction, so
/// the compaction task can never exist without the response that caused
/// it. `resume_after` restores the same trigger with the one-shot
/// recovery spent, so the retried request cannot loop on overflow.
fn enter_overflow_compaction(
  pass: RunPass,
  attempt: AssistantAttempt,
  normalized: AgentMessage,
  message: AgentMessage,
  preparation: StructuralPreparation,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  let AssistantAttempt(context:, response_entry:, usage:, ..) = attempt
  let #(task_entry, _generator) = ids.mint_entry(in.generator)
  let task_id = ids.entry_id_to_string(task_entry)
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      Compacting(
        reason: OverflowReason,
        structural: Deciding(task_id:),
        resume_after: CheckpointPhase(
          continuation: NeedAssistant(overflow_recovery_used: True),
          trigger: context.trigger,
          threshold_checked: None,
          skip_inbox_once: False,
        ),
      ),
    )
  transition(pass, next, [
    build.message_entry(response_entry, in.leaf, normalized, False),
    build.set_leaf(op.strand, Some(response_entry)),
    build.usage_row(usage, Some(response_entry), message_usage(message)),
    build.set_preparation(op.id, task_id, preparation),
    build.set_op_state(op.id, next),
  ])
}

/// A valid deferred handle suspends the operation on its own response:
/// the committed entry becomes the source the first fetch polls against,
/// and nothing further happens until the caller grants a poll permit.
/// The step's captured configuration and stream options ride into the
/// deferred state so every fetch uses what the request was made with.
fn suspend_on_deferred_handle(
  pass: RunPass,
  attempt: AssistantAttempt,
  message: AgentMessage,
) -> Action {
  let AssistantAttempt(context:, response_entry:, usage:, ..) = attempt
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      AwaitingDeferred(deferred: DeferredSuspended(
        step_id: context.step_id,
        source_entry: response_entry,
        poll: 0,
        configuration: context.configuration,
        stream_options: context.stream_options,
      )),
    )
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, message, usage, next),
  )
}

/// A retryable error waits and tries again while the *captured* policy
/// has attempts left; every other error drains the run. The failed
/// response commits on both paths — the error is part of the tree, and
/// the retry's backoff is measured from the attempt that just finished.
fn settle_provider_error(
  pass: RunPass,
  attempt: AssistantAttempt,
  message: AgentMessage,
  retryable: Bool,
  error_message: String,
) -> Action {
  let RunPass(in:, ..) = pass
  let AssistantAttempt(context:, number:, response_entry:, usage:, ..) = attempt
  case retryable && number < context.retry.max_attempts {
    True -> {
      let next =
        run_state(
          RunPass(..pass, latest: Some(response_entry)),
          Assistant(generation: GenerationRetryWait(
            context:,
            next_attempt: number + 1,
            not_before: in.now + backoff(context.retry, number),
            error_message:,
          )),
        )
      transition(
        pass,
        next,
        settle_writes(pass, response_entry, message, usage, next),
      )
    }
    False ->
      settle_failure_drain(
        pass,
        response_entry,
        usage,
        message,
        OperationError(
          code: "provider_error",
          message: error_message,
          details: None,
        ),
      )
  }
}

/// The shared settlement write list: response entry, leaf, usage row, and
/// the next state — one atomic commit, in pi's normative order.
fn settle_writes(
  pass: RunPass,
  response_entry: EntryId,
  message: AgentMessage,
  usage_id: UsageId,
  next: OperationState,
) -> List(Write) {
  let RunPass(op:, in:, ..) = pass
  [
    build.message_entry(response_entry, in.leaf, message, False),
    build.set_leaf(op.strand, Some(response_entry)),
    build.usage_row(usage_id, Some(response_entry), message_usage(message)),
    build.set_op_state(op.id, next),
  ]
}

/// The settlement every turn-ending response shares: the response
/// commits, becomes the leaf and the latest assistant, and the run lands
/// at a may-finish checkpoint triggered on it. Four settlements arrive
/// here — a finished response, a cancelled one (normalized to aborted),
/// and the synthetic stand-ins recovery commits for each — because pi
/// gives all four the same destination.
///
/// It takes the two ids rather than an `AssistantAttempt` because a
/// deferred poll settles here too, and a poll has no generation attempt
/// behind it — only the ids its fetch reserved. The same is true of
/// `settle_failure_drain` and `settle_to_tool_batch` below.
fn settle_at_may_finish(
  pass: RunPass,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
) -> Action {
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      Checkpoint(checkpoint: CheckpointPhase(
        continuation: MayFinish(include_final_assistant: True),
        trigger: response_entry,
        threshold_checked: None,
        skip_inbox_once: False,
      )),
    )
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, message, usage_id, next),
  )
}

/// A tool-use response opens a batch: the planned calls and the response
/// entry commit in one transaction, so a crash can never leave a
/// committed response whose calls were never planned. `context` supplies
/// the configuration and step id the batch is stamped with — the real
/// generation context for an assistant turn, a poll's reconstruction of
/// one for a deferred settlement.
fn settle_to_tool_batch(
  pass: RunPass,
  context: GenerationContext,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
) -> Action {
  let RunPass(in:, ..) = pass
  use batch <- or_fault(plan_batch(in, message, context, response_entry))
  let next =
    run_state(RunPass(..pass, latest: Some(response_entry)), Tools(batch:))
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, message, usage_id, next),
  )
}

/// An identity or tool implementation that will not resolve drains the
/// run as a configuration failure. Nothing is fabricated on this path:
/// no response or usage id was ever reserved, so the drain is a bare
/// state change with no entry behind it — which is also why it keeps the
/// existing `latest_assistant` rather than naming a response.
fn enter_configuration_failure_drain(
  pass: RunPass,
  error: OperationError,
) -> Action {
  let RunPass(op:, ..) = pass
  let next =
    run_state(pass, FailureDrain(error:, provenance: ConfigurationProvenance))
  transition(pass, next, [build.set_op_state(op.id, next)])
}

fn settle_failure_drain(
  pass: RunPass,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
  error: OperationError,
) -> Action {
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      FailureDrain(
        error:,
        provenance: ResponseProvenance(entry: response_entry),
      ),
    )
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, message, usage_id, next),
  )
}

/// Orphan recovery for an assistant `effect_pending` (pi §4.5): commit a
/// synthetic zero-usage error under the reserved ids carrying the
/// reconstructed partial, then follow ordinary classification — retry
/// with attempts remaining, failure drain at the cap.
fn settle_orphaned_assistant(
  pass: RunPass,
  attempt: AssistantAttempt,
  partial: List(message.AssistantBlock),
) -> Action {
  let RunPass(in:, control:, ..) = pass
  let AssistantAttempt(context:, number:, response_entry:, usage:, ..) = attempt

  // Running reports the orphan as an error; a cancelled control reports it
  // as an abort. Either way the content recovered so far is kept.
  let stop_reason = case control {
    Running -> Errored
    CancelRequested(..) -> Aborted
  }
  let synthetic =
    synthetic_response(
      context,
      partial,
      stop_reason,
      interrupted_warning(),
      in.now,
    )
  case control, number < context.retry.max_attempts {
    // Cancelled: the synthetic is the operation's last word, so it goes
    // straight to a may-finish checkpoint rather than being retried.
    CancelRequested(..), _ ->
      settle_at_may_finish(pass, response_entry, usage, synthetic)
    Running, True -> retry_after_orphan(pass, attempt, synthetic)
    Running, False ->
      settle_failure_drain(
        pass,
        response_entry,
        usage,
        synthetic,
        OperationError(
          code: "interrupted",
          message: interrupted_warning(),
          details: None,
        ),
      )
  }
}

/// Running, an orphan with attempts left: wait out backoff before retrying
/// the generation, same as any other retryable settle.
fn retry_after_orphan(
  pass: RunPass,
  attempt: AssistantAttempt,
  synthetic: AgentMessage,
) -> Action {
  let RunPass(in:, ..) = pass
  let AssistantAttempt(context:, number:, response_entry:, usage:, ..) = attempt
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      Assistant(generation: GenerationRetryWait(
        context:,
        next_attempt: number + 1,
        not_before: in.now + backoff(context.retry, number),
        error_message: interrupted_warning(),
      )),
    )
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, synthetic, usage, next),
  )
}

// --- tools (pi §3.8) ------------------------------------------------------

fn tools_action(pass: RunPass, batch: ToolBatch) -> Action {
  use source <- or_fault(option.to_result(
    pass.in.batch_source,
    corruption.report(
      at: "machine/planner.tools_action",
      on: ids.entry_id_to_string(batch.assistant_entry),
      expected: "the batch source assistant message in the inputs",
      context: "batch_source absent",
    ),
  ))

  // The batch reads as three zones in source order: a completed prefix
  // already in the tree, then the frontier — whose leading outcome-ready
  // run is what materializes next, and whose head is otherwise the call
  // to work.
  let completed_prefix = list.take_while(batch.calls, call_is_completed)
  let frontier = list.drop(batch.calls, list.length(completed_prefix))
  let ready_run = list.take_while(frontier, call_is_outcome_ready)
  case ready_run {
    [_, ..] -> materialize(pass, batch, ready_run)
    [] -> advance_batch(pass, batch, source, frontier)
  }
}

fn advance_batch(
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  frontier: List(ToolCallState),
) -> Action {
  let RunPass(op:, in:, control:, ..) = pass

  // Consume a tool observation when one is present.
  case in.observation {
    ObservedToolCleared(source_index:, effective_arguments:, replay:) ->
      dispatch_tool(
        pass,
        batch,
        source,
        source_index,
        effective_arguments,
        replay,
      )
    ObservedToolRefused(source_index:, result:) ->
      stage_result(pass, batch, source_index, result, False)
    ObservedToolSettled(source_index:, result:, terminate:) -> {
      // Under cancelled control a live result is preserved but never
      // terminates the run.
      let terminate = case control {
        Running -> terminate
        CancelRequested(..) -> False
      }
      stage_result(pass, batch, source_index, result, terminate)
    }
    ObservedToolOrphaned(source_index:, replay_still_safe:, checkpoint:) ->
      recover_tool(
        pass,
        batch,
        source,
        source_index,
        replay_still_safe,
        checkpoint,
      )
    NoObservation -> request_batch_work(pass, batch, source, frontier)
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
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  frontier: List(ToolCallState),
) -> Action {
  case frontier {
    [] ->
      Fault(report: corruption.report(
        at: "machine/planner.request_batch_work",
        on: build.op_key(pass.op.id),
        expected: "a batch with unfinished calls",
        context: "tools phase with every call completed",
      ))
    [CallCompleted(..), ..] | [CallOutcomeReady(..), ..] ->
      Fault(report: corruption.report(
        at: "machine/planner.request_batch_work",
        on: build.op_key(pass.op.id),
        expected: "materialization to have handled the frontier",
        context: "outcome_ready or completed at the frontier",
      ))
    [CallPlanned(source_index:, result_entry: _), ..] ->
      work_planned_call(pass, batch, source, source_index)
    [CallEffectPending(source_index:, result_entry:, replay: _), ..] ->
      await_effect_pending(
        pass,
        batch,
        source,
        frontier,
        source_index,
        result_entry,
      )
  }
}

/// pi §3.8's scheduling-mode decision for the call effect-pending at the
/// frontier's head: `Sequential` waits on it; `Parallel` works the next
/// still-planned call while it is in flight, and only once every
/// unfinished call is effect-pending does the batch park on the first of
/// them (any pending call's observation satisfies the key).
fn await_effect_pending(
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  frontier: List(ToolCallState),
  source_index: Int,
  result_entry: EntryId,
) -> Action {
  let RunPass(op:, settings:, ..) = pass
  case settings.tool_execution {
    operation.Sequential ->
      AwaitEffect(key: ToolKey(
        operation: op.id,
        step_id: batch.turn_id,
        source_index:,
        result_entry:,
      ))
    operation.Parallel ->
      case first_planned(frontier) {
        Some(planned_index) ->
          work_planned_call(pass, batch, source, planned_index)
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

/// Whether a call's result is already an entry in the tree.
fn call_is_completed(call: ToolCallState) -> Bool {
  case call {
    CallCompleted(..) -> True
    _ -> False
  }
}

/// Whether a call has a finalized result staged in `pending.entry`,
/// waiting only for its source-ordered turn to enter the tree.
fn call_is_outcome_ready(call: ToolCallState) -> Bool {
  case call {
    CallOutcomeReady(..) -> True
    _ -> False
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
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  source_index: Int,
) -> Action {
  let RunPass(op:, in:, control:, ..) = pass
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
    Some(text) -> {
      use result <- or_fault(synthetic_tool_result(
        source,
        source_index,
        text,
        None,
        in.now,
      ))
      stage_result(pass, batch, source_index, result, False)
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
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  source_index: Int,
  effective_arguments: JsonValue,
  replay: operation.ReplayPolicy,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  use found <- or_fault(find_call(batch, source_index))
  use call <- or_fault(source_call(source, source_index))

  // Only a planned call can be cleared; anything else means the batch
  // and the observation disagree about where this call had got to.
  case found {
    CallPlanned(source_index: _, result_entry:) -> {
      let calls =
        replace_call(
          batch.calls,
          source_index,
          CallEffectPending(source_index:, result_entry:, replay:),
        )
      let next = run_state(pass, Tools(batch: ToolBatch(..batch, calls:)))
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
    CallEffectPending(..) | CallOutcomeReady(..) | CallCompleted(..) ->
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
  pass: RunPass,
  batch: ToolBatch,
  source: AgentMessage,
  source_index: Int,
  replay_still_safe: Bool,
  checkpoint: Option(AgentMessage),
) -> Action {
  let RunPass(op:, in:, control:, ..) = pass
  use found <- or_fault(find_call(batch, source_index))
  use call <- or_fault(source_call(source, source_index))

  // Only an effect-pending call can be orphaned; anything else means the
  // batch and the observation disagree about where this call had got to.
  use #(result_entry, replay) <- or_fault(case found {
    CallEffectPending(source_index: _, result_entry:, replay:) ->
      Ok(#(result_entry, replay))
    CallPlanned(..) | CallOutcomeReady(..) | CallCompleted(..) ->
      Error(corruption.report(
        at: "machine/planner.recover_tool",
        on: build.op_key(op.id),
        expected: "an effect-pending call at the orphaned index",
        context: "orphan observed for a non-pending call",
      ))
  })

  // Only a still-safe replay of a still-running call re-executes; every
  // other orphan is settled with a synthetic interrupted result.
  let replayable = case control, replay {
    Running, ReplaySafe -> replay_still_safe
    _, _ -> False
  }
  use <- bool.lazy_guard(when: replayable, return: fn() {
    Dispatch(
      intent: ToolReplay(
        operation: op.id,
        step_id: batch.turn_id,
        source_index:,
        call:,
        arguments_key: build.tool_args_key(op.id, batch.turn_id, source_index),
        result_entry:,
      ),
      next: run_state(pass, Tools(batch:)),
      tx: op_tx(op, in, []),
    )
  })
  use result <- or_fault(interrupted_tool_result(call, checkpoint, in.now))
  stage_result(pass, batch, source_index, result, False)
}

/// Stages one finalized result: the complete message enters
/// `pending.entry/{result}` and the call becomes outcome-ready, awaiting
/// source-ordered materialization.
fn stage_result(
  pass: RunPass,
  batch: ToolBatch,
  source_index: Int,
  result: AgentMessage,
  terminate: Bool,
) -> Action {
  let RunPass(op:, ..) = pass
  use <- or_fault_unless(result_is_tool_result(result), fn() {
    corruption.report(
      at: "machine/planner.stage_result",
      on: build.op_key(op.id),
      expected: "a tool-result message",
      context: "a non-tool-result observation payload",
    )
  })
  use found <- or_fault(find_call(batch, source_index))

  // A call may be staged once. Reaching here twice means an observation
  // was delivered for work the batch has already accounted for.
  use result_entry <- or_fault(case found {
    CallPlanned(source_index: _, result_entry:)
    | CallEffectPending(source_index: _, result_entry:, replay: _) ->
      Ok(result_entry)
    CallCompleted(..) | CallOutcomeReady(..) ->
      Error(corruption.report(
        at: "machine/planner.stage_result",
        on: build.op_key(op.id),
        expected: "a planned or effect-pending call to stage",
        context: "result observed for an already staged call",
      ))
  })
  let calls =
    replace_call(
      batch.calls,
      source_index,
      CallOutcomeReady(source_index:, result_entry:, terminate:),
    )
  let next = run_state(pass, Tools(batch: ToolBatch(..batch, calls:)))
  transition(pass, next, [
    build.set_pending(result_entry, PendingMessage(message: result)),
    build.set_op_state(op.id, next),
  ])
}

/// Whether a settled payload is the tool-result message it must be.
fn result_is_tool_result(message: AgentMessage) -> Bool {
  case message {
    ToolResultMessage(..) -> True
    _ -> False
  }
}

/// Materializes the contiguous outcome-ready run at the frontier: result
/// entries enter the tree in source order, their staged registers die,
/// tool-reported usage lands in the ledger, and the batch either
/// continues or checkpoints (pi §3.8).
fn materialize(
  pass: RunPass,
  batch: ToolBatch,
  ready_run: List(ToolCallState),
) -> Action {
  let RunPass(op:, in:, ..) = pass
  use #(entry_writes, newest) <- or_fault(place_ready_run(op, in, ready_run))

  // Unreachable: `ready_run` is non-empty at every call site, so
  // something was placed and is the new leaf.
  let newest = option.unwrap(newest, batch.assistant_entry)
  let calls = complete_ready_calls(batch.calls, ready_run)
  case list.all(calls, call_is_completed) {
    // More calls left to work: the batch stays in the tools phase with
    // the materialized results already in the tree.
    False -> {
      let next = run_state(pass, Tools(batch: ToolBatch(..batch, calls:)))
      transition(
        pass,
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
    True -> close_batch(pass, calls, entry_writes, newest)
  }
}

/// Turns the contiguous outcome-ready run into tree writes: each staged
/// result becomes an entry parented on the one before it, its
/// `pending.entry` register dies in the same transaction, and any
/// tool-reported usage gets a ledger row under a freshly minted id.
/// Returns the writes and the newest entry placed, which becomes the
/// leaf.
fn place_ready_run(
  op: Operation,
  in: PlannerInputs,
  ready_run: List(ToolCallState),
) -> Result(#(List(Write), Option(EntryId)), CorruptionReport) {
  let placed =
    list.try_fold(ready_run, #([], in.leaf, in.generator), fn(acc, call) {
      let #(writes, parent, generator) = acc
      use #(result_entry, terminate) <- result.try(case call {
        CallOutcomeReady(source_index: _, result_entry:, terminate:) ->
          Ok(#(result_entry, terminate))
        CallPlanned(..) | CallEffectPending(..) | CallCompleted(..) ->
          Error(corruption.report(
            at: "machine/planner.materialize",
            on: build.op_key(op.id),
            expected: "an outcome-ready call in the ready run",
            context: "a non-ready call",
          ))
      })
      use pending <- result.try(deref_pending(in, result_entry))
      use message <- result.try(case pending {
        PendingMessage(message:) -> Ok(message)
        PendingCustom(..) ->
          Error(corruption.report(
            at: "machine/planner.materialize",
            on: ids.entry_id_to_string(result_entry),
            expected: "a staged tool-result message",
            context: "a custom pending payload under a result id",
          ))
      })
      let entry_writes = [
        build.message_entry(result_entry, parent, message, terminate),
        build.delete_pending(result_entry),
      ]

      // Tool-reported usage becomes a ledger row of its own, under an id
      // minted here rather than reserved in the intent — the tool did
      // not have to report any.
      let #(usage_writes, generator) = case message {
        ToolResultMessage(usage: Some(usage), ..) -> {
          let #(usage_id, generator) = ids.mint_usage(generator)
          #([build.usage_row(usage_id, Some(result_entry), usage)], generator)
        }
        _ -> #([], generator)
      }
      Ok(#(
        list.flatten([writes, entry_writes, usage_writes]),
        Some(result_entry),
        generator,
      ))
    })
  use #(writes, newest, _generator) <- result.map(placed)
  #(writes, newest)
}

/// Marks every call that was just materialized completed, leaving the
/// rest of the batch untouched.
fn complete_ready_calls(
  calls: List(ToolCallState),
  ready_run: List(ToolCallState),
) -> List(ToolCallState) {
  list.map(calls, fn(call) {
    case call {
      CallOutcomeReady(source_index:, result_entry:, terminate:) -> {
        let is_ready =
          list.any(ready_run, fn(ready) {
            case ready {
              CallOutcomeReady(source_index: ready_index, ..) ->
                ready_index == source_index
              _ -> False
            }
          })
        case is_ready {
          True -> CallCompleted(source_index:, result_entry:, terminate:)
          False -> call
        }
      }
      _ -> call
    }
  })
}

/// The last materialization of a batch: every call is completed, so the
/// tools phase ends at a checkpoint and the batch's persisted tool
/// arguments are deleted.
///
/// The continuation turns on whether *every* call terminated the run. If
/// so the batch itself is the run's conclusion and no final assistant
/// message is included; otherwise another assistant turn is owed —
/// carrying, faithfully to pi, `skip_inbox_once`, so the results reach
/// the model before newly queued input does.
fn close_batch(
  pass: RunPass,
  calls: List(ToolCallState),
  entry_writes: List(Write),
  newest: EntryId,
) -> Action {
  let RunPass(op:, in:, ..) = pass
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
    run_state(
      pass,
      Checkpoint(checkpoint: CheckpointPhase(
        continuation:,
        trigger: newest,
        threshold_checked: None,
        skip_inbox_once:,
      )),
    )
  let args_deletes = list.map(in.tool_args_keys, build.delete_tool_args_key)
  transition(
    pass,
    next,
    list.flatten([
      entry_writes,
      [build.set_leaf(op.strand, Some(newest))],
      args_deletes,
      [build.set_op_state(op.id, next)],
    ]),
  )
}

// --- deferred responses (pi §3.2 deferred table) --------------------------

/// A deferred operation is either suspended between polls or waiting on
/// one in flight. Both halves are gated the same way — a poll costs a
/// caller-granted permit and a resolved identity — which is why the two
/// handlers below look so alike.
fn deferred_action(pass: RunPass, deferred: DeferredState) -> Action {
  case deferred {
    DeferredSuspended(
      step_id:,
      source_entry:,
      poll:,
      configuration:,
      stream_options:,
    ) ->
      deferred_suspended_action(
        pass,
        deferred,
        Fetch(step_id:, source_entry:, poll:, configuration:, stream_options:),
      )
    DeferredEffectPending(
      step_id:,
      source_entry:,
      poll:,
      response_entry:,
      usage:,
      configuration:,
      stream_options:,
    ) ->
      await_poll(
        pass,
        Fetch(step_id:, source_entry:, poll:, configuration:, stream_options:),
        response_entry,
        usage,
      )
  }
}

/// A suspended deferred handle: cancelled control drains without starting
/// a fetch (best-effort remote cancellation is the runtime's cleanup, not
/// durable state); running control spends a poll permit on one.
fn deferred_suspended_action(
  pass: RunPass,
  deferred: DeferredState,
  fetch: Fetch,
) -> Action {
  case pass.control {
    CancelRequested(..) ->
      drain_writes_then_finish_aborted(pass, AwaitingDeferred(deferred:))
    Running -> start_poll(pass, fetch)
  }
}

/// `suspended`: a fetch costs a permit the caller grants, and then
/// identity resolution decides whether it is made at all. An
/// unresolvable identity drains the run rather than burning further
/// permits against a model that is gone.
fn start_poll(pass: RunPass, fetch: Fetch) -> Action {
  let RunPass(op:, in:, ..) = pass
  let Fetch(source_entry:, step_id:, poll:, ..) = fetch
  use <- bool.guard(
    when: !in.poll_permit,
    return: Wait(until: DeferredPollDue(source_entry:)),
  )

  // The first fetch after a suspension is the next poll against the same
  // handle; nothing else about the fetch changes.
  let next_fetch = Fetch(..fetch, poll: poll + 1)
  case in.observation {
    ObservedResolution(resolution: ModelUnresolved(error:)) ->
      enter_configuration_failure_drain(pass, error)
    ObservedResolution(resolution: ModelResolved) ->
      dispatch_poll(pass, next_fetch)
    NoObservation ->
      AwaitEffect(key: PollAdmissionKey(
        operation: op.id,
        step_id:,
        poll: next_fetch.poll,
      ))
    other -> unexpected_observation(op, "deferred suspended", other)
  }
}

/// `effect_pending`: the fetch settles, is reported orphaned, or is
/// still running.
///
/// The orphan arm also matches a bare `ObservedResolution`, because the
/// orphan report itself carries no resolution: this handler asks for one
/// (`OrphanPollUnknown` below) and the answer arrives on a later pass as
/// its own observation. Matching only the orphan report would fault the
/// strand on the very pass that answered its question.
fn await_poll(
  pass: RunPass,
  fetch: Fetch,
  response_entry: EntryId,
  usage: UsageId,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  let Fetch(step_id:, poll:, ..) = fetch
  case in.observation {
    ObservedDeferredSettled(settled:) ->
      settle_poll(pass, fetch, response_entry, usage, settled)
    ObservedDeferredOrphaned | ObservedResolution(..) ->
      reconcile_orphaned_poll(pass, fetch, response_entry, usage)
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

/// The fetch's outcome is unknown, or the orphan's own resolution answer
/// has just arrived: cancelled control settles it aborted; running
/// control replaces it under fresh ids (pi §4.5).
fn reconcile_orphaned_poll(
  pass: RunPass,
  fetch: Fetch,
  response_entry: EntryId,
  usage: UsageId,
) -> Action {
  case pass.control {
    CancelRequested(..) ->
      settle_cancelled_poll(pass, fetch, response_entry, usage)
    Running -> replace_orphaned_poll(pass, fetch)
  }
}

/// Orphan recovery for a poll (pi §4.5): the fetch's outcome is unknown,
/// so it is simply made again under *fresh* ids at the **same** poll
/// number — the poll count measures permits spent against the source
/// handle, and a replacement is not a new poll. The abandoned reserved
/// ids are never materialized. The replacement still costs a permit,
/// which is why the same guard as `start_poll` opens this function.
fn replace_orphaned_poll(pass: RunPass, fetch: Fetch) -> Action {
  let RunPass(op:, in:, ..) = pass
  let Fetch(source_entry:, step_id:, poll:, ..) = fetch
  use <- bool.guard(
    when: !in.poll_permit,
    return: Wait(until: DeferredPollDue(source_entry:)),
  )
  case orphan_poll_resolution(in) {
    OrphanPollUnresolved(error) ->
      enter_configuration_failure_drain(pass, error)
    OrphanPollResolved -> dispatch_poll(pass, fetch)
    OrphanPollUnknown ->
      AwaitEffect(key: PollAdmissionKey(operation: op.id, step_id:, poll:))
  }
}

/// Reserves the ids for one deferred fetch and dispatches it as `poll`.
/// The first fetch after a suspension passes `poll + 1`; the replacement
/// of an orphaned fetch passes the same `poll` it had. Nothing else
/// distinguishes the two.
fn dispatch_poll(pass: RunPass, fetch: Fetch) -> Action {
  let RunPass(op:, in:, ..) = pass
  let Fetch(step_id:, source_entry:, poll:, configuration:, stream_options:) =
    fetch
  let #(response_entry, generator) = ids.mint_entry(in.generator)
  let #(usage, _generator) = ids.mint_usage(generator)
  let next =
    run_state(
      pass,
      AwaitingDeferred(deferred: DeferredEffectPending(
        step_id:,
        source_entry:,
        poll:,
        response_entry:,
        usage:,
        configuration:,
        stream_options:,
      )),
    )
  Dispatch(
    intent: DeferredFetch(
      operation: op.id,
      step_id:,
      poll:,
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
  pass: RunPass,
  fetch: Fetch,
  response_entry: EntryId,
  usage_id: UsageId,
  settled: SettledAssistantMessage,
) -> Action {
  let RunPass(control:, ..) = pass
  let Fetch(step_id:, source_entry:, configuration:, stream_options:, ..) =
    fetch
  let message = classification.message(settled)
  let classify_ctx =
    ClassifyCtx(
      control:,
      // Polls persist no intended output limit; the length-below rule is
      // disabled.
      intended_output_limit: 0,
      expected_model: configuration.model,
      // Not a captured api, unlike `settle_assistant`'s: neither the
      // deferred state nor the `DeferredFetch` intent persists one, so
      // this compares the response against its own claim and can never
      // fail. ORCH-L4 is upheld one step later instead —
      // `resuspend_on_poll_handle` requires the returned handle to be
      // *completely* equal to the source handle, api included, and the
      // first source handle was validated against the real captured api
      // in `settle_assistant`. By induction every accepted poll handle
      // carries that api. `classification.handle_valid` names this split
      // too: poll-source equality is the planner's, stricter, check.
      expected_api: message_api(message),
      error_retryable: settled_retryable(message),
    )

  // The same classification order as a generation settlement, but with
  // three of its destinations closed off: a poll has no retry wait, no
  // overflow compaction, and no admission to fall back on, so every
  // error lands in the same response-provenance failure drain (pi §3.2).
  case classification.classify(settled, classify_ctx) {
    CorruptClassification(report:) -> Fault(report:)

    // A really-settled poll under cancelled control commits normalized to
    // aborted, retaining its content and reported usage (pi §4.6 —
    // review finding ORCH-M3): only an *unknown-outcome* orphan gets the
    // zero-usage synthetic below.
    CancelledClassification ->
      settle_at_may_finish(
        pass,
        response_entry,
        usage_id,
        normalize_stop(message, Aborted, None),
      )
    DeferredValidClassification(handle:) ->
      resuspend_on_poll_handle(
        pass,
        fetch,
        response_entry,
        usage_id,
        message,
        handle,
      )
    DeferredInvalidClassification ->
      settle_poll_failure(
        pass,
        response_entry,
        usage_id,
        normalize_stop(
          message,
          Errored,
          Some(
            "invalid deferred handle: the pending response carried no usable handle",
          ),
        ),
        OperationError(
          code: "invalid_deferred_handle",
          message: "the pending response carried no usable handle",
          details: None,
        ),
      )
    ToolUseClassification(truncated: _) ->
      // A poll never had a generation context of its own, so the batch
      // is stamped with the one the original request would have carried:
      // the poll's step and captured configuration, triggered on the
      // source entry it was fetched against.
      settle_to_tool_batch(
        pass,
        GenerationContext(
          step_id:,
          trigger: source_entry,
          configuration:,
          stream_options:,
          retry: pass.in.retry_policy,
          overflow_recovery_used: False,
        ),
        response_entry,
        usage_id,
        message,
      )
    FinishedClassification ->
      settle_at_may_finish(pass, response_entry, usage_id, message)
    OverflowClassification ->
      settle_poll_failure(
        pass,
        response_entry,
        usage_id,
        normalize_stop(message, Errored, Some(overflow_error_message(message))),
        overflow_operation_error(message),
      )
    ErrorClassification(retryable: _, error_message:) ->
      settle_poll_failure(
        pass,
        response_entry,
        usage_id,
        message,
        OperationError(
          code: "provider_error",
          message: error_message,
          details: None,
        ),
      )
  }
}

/// A poll that comes back still pending suspends again on its own
/// response, which becomes the source the next fetch is made against.
/// The handle must be *completely* equal to the source handle it was
/// fetched with; anything else is a durable error rather than a retry,
/// because a changed handle means the machine no longer knows what it is
/// polling (pi §3.2). The poll number does not advance — it counts
/// permits spent, and this response cost the one already counted.
fn resuspend_on_poll_handle(
  pass: RunPass,
  fetch: Fetch,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
  handle: DeferredHandle,
) -> Action {
  let RunPass(in:, ..) = pass
  let Fetch(step_id:, poll:, configuration:, stream_options:, ..) = fetch
  case in.deferred_source == Some(handle) {
    True -> {
      let next =
        run_state(
          RunPass(..pass, latest: Some(response_entry)),
          AwaitingDeferred(deferred: DeferredSuspended(
            step_id:,
            source_entry: response_entry,
            poll:,
            configuration:,
            stream_options:,
          )),
        )
      transition(
        pass,
        next,
        settle_writes(pass, response_entry, message, usage_id, next),
      )
    }
    False ->
      settle_poll_failure(
        pass,
        response_entry,
        usage_id,
        normalize_stop(
          message,
          Errored,
          Some(
            "deferred handle mismatch: the pending handle does not equal its source",
          ),
        ),
        OperationError(
          code: "deferred_handle_mismatch",
          message: "the pending handle does not equal its source",
          details: None,
        ),
      )
  }
}

fn settle_poll_failure(
  pass: RunPass,
  response_entry: EntryId,
  usage_id: UsageId,
  message: AgentMessage,
  error: OperationError,
) -> Action {
  let next =
    run_state(
      RunPass(..pass, latest: Some(response_entry)),
      FailureDrain(
        error:,
        provenance: ResponseProvenance(entry: response_entry),
      ),
    )
  transition(
    pass,
    next,
    settle_writes(pass, response_entry, message, usage_id, next),
  )
}

/// Synthetic settlement of a cancelled *unknown-outcome* poll under the
/// existing reserved ids — the orphan path only; a really-settled poll
/// under cancelled control retains its reported usage in `settle_poll`
/// (pi §4.6). A cancelled may-finish checkpoint then leads to the
/// aborted terminal transaction.
fn settle_cancelled_poll(
  pass: RunPass,
  fetch: Fetch,
  response_entry: EntryId,
  usage_id: UsageId,
) -> Action {
  // No content: an orphan report for a poll carries no partial, unlike an
  // assistant orphan's reconstructed blocks.
  let synthetic =
    AssistantMessage(
      content: [],
      api: "unknown",
      provider: fetch.configuration.model.provider,
      model: fetch.configuration.model.model_id,
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: build.zero_usage(),
      stop_reason: Aborted,
      deferred: None,
      error_message: Some("deferred poll aborted"),
      raw_stop_reason: None,
      end_turn: None,
      timestamp: pass.in.now,
    )
  settle_at_may_finish(pass, response_entry, usage_id, synthetic)
}

// --- failure drain (pi §3.12) ---------------------------------------------

fn failure_drain_action(
  pass: RunPass,
  error: OperationError,
  provenance: operation.FailureProvenance,
) -> Action {
  let RunPass(op:, in:, control:, settings:, inbox:, latest:) = pass
  let phase = FailureDrain(error:, provenance:)

  // Same priority as the checkpoint's own inbox drain — writes, then
  // steer, then follow-up — with no recovering input finishing the run
  // failed, without the run-end hook or another provider request.
  case inbox.writes, inbox.steer, inbox.follow_up {
    [_, ..], _, _ ->
      drain_failure_input(pass, phase, inbox.writes, fn(inbox) {
        Inbox(..inbox, writes: [])
      })
    [], [_, ..], _ -> {
      let #(consumed, left) = take_per_mode(inbox.steer, settings.steering_mode)
      drain_failure_input(pass, phase, consumed, fn(inbox) {
        Inbox(..inbox, steer: left)
      })
    }
    [], [], [_, ..] -> {
      let #(consumed, left) =
        take_per_mode(inbox.follow_up, settings.follow_up_mode)
      drain_failure_input(pass, phase, consumed, fn(inbox) {
        Inbox(..inbox, follow_up: left)
      })
    }
    [], [], [] -> {
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

/// Applies one drained batch during failure drain. Projecting
/// user-context input atomically clears the failure into a
/// `need_assistant` checkpoint; unprojected custom writes append without
/// clearing it.
fn drain_failure_input(
  pass: RunPass,
  phase: RunPhase,
  consumed: List(EntryId),
  remove: fn(Inbox) -> Inbox,
) -> Action {
  let RunPass(op:, inbox:, ..) = pass
  use Placement(writes: entry_writes, newest:, projecting:) <- or_fault(
    place_pending(pass, consumed),
  )
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
  let next = run_state(RunPass(..pass, inbox: remaining), next_phase)
  let leaf_writes = case newest {
    Some(id) -> [build.set_leaf(op.strand, Some(id))]
    None -> []
  }
  transition(
    pass,
    next,
    list.flatten([entry_writes, leaf_writes, [build.set_op_state(op.id, next)]]),
  )
}

// --- cancellation reconciliation (pi §4.6) --------------------------------

fn reconcile_run(pass: RunPass, phase: RunPhase) -> Action {
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
      reconcile_pending_assistant(
        pass,
        AssistantAttempt(
          context:,
          number: attempt,
          response_entry:,
          usage:,
          intended_output_limit:,
          request_api:,
        ),
      )

    // Tool batches reconcile through the ordinary machinery: planned
    // calls stage aborted synthetics, pending effects settle or
    // synthesize interruption, staged outcomes materialize in source
    // order; the closing checkpoint then drains writes and finishes.
    Tools(batch:) -> tools_action(pass, batch)
    AwaitingDeferred(deferred:) -> deferred_action(pass, deferred)

    // Structural work not yet atomically published is discarded.
    Starting
    | Checkpoint(..)
    | Assistant(..)
    | Compacting(..)
    | FailureDrain(..) -> drain_writes_then_finish_aborted(pass, phase)
  }
}

/// Cancellation caught the assistant effect still in flight: dispatch on
/// what the runtime observed for it, same vocabulary as the ordinary
/// (uncancelled) settle path, so a really-settled response still keeps
/// its content and reported usage (pi §4.6, ORCH-M3).
fn reconcile_pending_assistant(
  pass: RunPass,
  attempt: AssistantAttempt,
) -> Action {
  let RunPass(op:, in:, ..) = pass
  let AssistantAttempt(context:, response_entry:, ..) = attempt
  case in.observation {
    ObservedAssistantSettled(settled:, overflow_preparation: _) ->
      settle_assistant(pass, attempt, settled, None)
    ObservedAssistantOrphaned(partial:) ->
      settle_orphaned_assistant(pass, attempt, partial)
    NoObservation ->
      AwaitEffect(key: AssistantKey(
        operation: op.id,
        step_id: context.step_id,
        response_entry:,
      ))
    other ->
      unexpected_observation(op, "cancelled assistant effect_pending", other)
  }
}

/// Under cancelled control every accepted deferred write is still applied
/// in order (without changing phase or starting work); the aborted
/// terminal transaction follows once the writes are drained.
fn drain_writes_then_finish_aborted(pass: RunPass, phase: RunPhase) -> Action {
  let RunPass(op:, in:, control:, inbox:, latest:, ..) = pass
  case inbox.writes {
    [_, ..] -> {
      use Placement(writes: entry_writes, newest:, projecting: _) <- or_fault(
        place_pending(pass, inbox.writes),
      )
      let next =
        run_state(RunPass(..pass, inbox: Inbox(..inbox, writes: [])), phase)
      let leaf_writes = case newest {
        Some(id) -> [build.set_leaf(op.strand, Some(id))]
        None -> []
      }
      transition(
        pass,
        next,
        list.flatten([
          entry_writes,
          leaf_writes,
          [build.set_op_state(op.id, next)],
        ]),
      )
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

/// The section's two entry points take `op`, `in` and `control`
/// separately rather than a `StructuralTask`, because the task id lives
/// inside `structural` and is not known until the match below — and
/// because `control` is exactly what this function decides on, while a
/// `StructuralTask` is only ever built for a running one.
fn structural_action(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  structural: StructuralDecision,
  host: StructuralHost,
) -> Action {
  case control {
    CancelRequested(..) -> abandon_structural(op, in, control, structural, host)
    Running ->
      case structural {
        Deciding(task_id:) ->
          decide_structural(StructuralTask(op:, in:, task_id:, host:))
        Generating(task_id:, generation:) ->
          generate_structural(
            StructuralTask(op:, in:, task_id:, host:),
            generation,
          )
      }
  }
}

/// Cancelled control: an in-run host still settles its outstanding
/// structural work through the ordinary reconciliation path; a standalone
/// compaction or summarized navigation host finishes aborted and moves
/// nothing.
fn abandon_structural(
  op: Operation,
  in: PlannerInputs,
  control: Control,
  structural: StructuralDecision,
  host: StructuralHost,
) -> Action {
  case host {
    InRunHost(settings:, inbox:, latest:, reason:, resume:) ->
      reconcile_run(
        RunPass(op:, in:, control:, settings:, inbox:, latest:),
        Compacting(reason:, structural:, resume_after: resume),
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
}

fn decide_structural(task: StructuralTask) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  case in.observation {
    ObservedStructuralDecision(verdict: VerdictDeclined) ->
      decline_structural(task)
    ObservedStructuralDecision(verdict: VerdictSupplied(summary:, usage:)) ->
      publish_structural(task, summary, usage, True)
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
      let next = host_state(host, Generating(task_id:, generation:))
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

/// A declined structural task: an in-run host restores its resume
/// checkpoint (threshold decline) or drains to failure (overflow decline,
/// since the request still cannot fit); a standalone compaction or
/// summarized navigation host finishes declined and moves nothing.
fn decline_structural(task: StructuralTask) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  case host {
    InRunHost(reason:, settings:, inbox:, latest:, resume:) ->
      decline_in_run(
        RunPass(op:, in:, control: Running, settings:, inbox:, latest:),
        task_id,
        reason,
        resume,
      )
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
}

/// An in-run host's declined structural task, by the reason it entered
/// structural work in the first place.
fn decline_in_run(
  pass: RunPass,
  task_id: String,
  reason: CompactionReason,
  resume: CheckpointPhase,
) -> Action {
  let RunPass(op:, ..) = pass
  case reason {
    // Threshold decline: restore the marked checkpoint.
    ThresholdReason -> {
      let next = run_state(pass, Checkpoint(checkpoint: resume))
      transition(pass, next, [build.set_op_state(op.id, next)])
    }

    // Overflow decline: the request still cannot fit.
    OverflowReason -> {
      let next =
        run_state(
          pass,
          FailureDrain(
            error: OperationError(
              code: "context_overflow",
              message: "overflow compaction was declined",
              details: None,
            ),
            provenance: StructuralProvenance(task_id:),
          ),
        )
      transition(pass, next, [build.set_op_state(op.id, next)])
    }
  }
}

/// One structural generation attempt, which unlike an assistant
/// generation may take *several* nested provider requests: the attempt
/// alternates between dispatching a request and asking the runtime what
/// that request bought (`SummaryProgress`) until a summary is produced.
/// `request` names the one request in flight; `usage_ids` is the ledger
/// of every request this attempt has already paid for, and its length is
/// the next request's index.
fn generate_structural(
  task: StructuralTask,
  generation: SummaryGeneration,
) -> Action {
  let StructuralTask(op:, in:, task_id:, ..) = task
  case generation {
    // Resolution before the attempt commits to anything.
    SummaryReady(context:, next_attempt:) ->
      case in.observation {
        ObservedResolution(resolution: ModelUnresolved(error:)) ->
          structural_failure(task, error)
        ObservedResolution(resolution: ModelResolved) ->
          transition_generation(
            task,
            SummaryEffectPending(
              context:,
              attempt: next_attempt,
              request: None,
              usage_ids: [],
            ),
          )
        NoObservation ->
          AwaitEffect(key: SummaryKey(
            operation: op.id,
            task_id:,
            attempt: next_attempt,
          ))
        other -> unexpected_observation(op, "summary ready", other)
      }

    // A nested request is in flight.
    SummaryEffectPending(context:, attempt:, request: Some(request), usage_ids:) ->
      settle_summary_request(task, context, attempt, request, usage_ids)

    // Between requests: decide whether the attempt needs another one.
    SummaryEffectPending(context:, attempt:, request: None, usage_ids:) ->
      advance_summary_attempt(task, context, attempt, usage_ids)
    SummaryRetryWait(context:, next_attempt:, not_before:, error_message: _) ->
      case in.now >= not_before {
        True ->
          transition_generation(task, SummaryReady(context:, next_attempt:))
        False -> Wait(until: RetryNotBefore(at: not_before))
      }
  }
}

/// The in-flight nested request either returns with its usage or is
/// reported orphaned. A returned request settles its ledger row and
/// clears the `request` field in one commit, so the next pass is
/// unambiguously "between requests" and asks for progress.
fn settle_summary_request(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
  request: SummaryRequest,
  usage_ids: List(UsageId),
) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  case in.observation {
    ObservedSummaryReturned(usage:) -> {
      let next_generation =
        SummaryEffectPending(
          context:,
          attempt:,
          request: None,
          usage_ids: list.append(usage_ids, [request.usage]),
        )
      let next =
        host_state(host, Generating(task_id:, generation: next_generation))
      Transition(
        next:,
        tx: op_tx(op, in, [
          build.usage_row(request.usage, None, usage),
          build.set_op_state(op.id, next),
        ]),
      )
    }
    ObservedSummaryOrphaned -> advance_orphaned_summary(task, context, attempt)
    NoObservation ->
      AwaitEffect(key: SummaryKey(operation: op.id, task_id:, attempt:))
    other -> unexpected_observation(op, "summary request pending", other)
  }
}

/// Between nested requests. With no requests paid for yet the first one
/// is unconditional — there is nothing to report progress on — so no
/// observation is consulted. After that the runtime's progress verdict
/// decides: another request, the finished summary, a retry wait, or
/// failure.
fn advance_summary_attempt(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
  usage_ids: List(UsageId),
) -> Action {
  case usage_ids {
    [] -> dispatch_summary_request(task, context, attempt, [])
    [_, ..] -> advance_ready_summary_attempt(task, context, attempt, usage_ids)
  }
}

/// A summary attempt that has already paid for at least one request:
/// dispatch on what the runtime observed for the one currently in flight.
fn advance_ready_summary_attempt(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
  usage_ids: List(UsageId),
) -> Action {
  let StructuralTask(op:, in:, task_id:, ..) = task
  case in.observation {
    ObservedSummaryProgress(progress: SummaryNeedsRequest) ->
      dispatch_summary_request(task, context, attempt, usage_ids)
    ObservedSummaryProgress(progress: SummaryProduced(summary:, usage:)) ->
      publish_structural(task, summary, usage, False)
    ObservedSummaryProgress(progress: SummaryFailed(error:, retryable:)) ->
      summary_failed(task, context, attempt, error, retryable)
    ObservedSummaryOrphaned -> advance_orphaned_summary(task, context, attempt)
    NoObservation ->
      AwaitEffect(key: SummaryProgressKey(operation: op.id, task_id:, attempt:))
    other -> unexpected_observation(op, "summary progress", other)
  }
}

/// A summary request attempt failed: a retryable failure with attempts
/// left waits out backoff before starting over from `ready` — nothing
/// this attempt bought is reused, only its usage rows survive — otherwise
/// the structural task fails outright.
fn summary_failed(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
  error: OperationError,
  retryable: Bool,
) -> Action {
  let StructuralTask(in:, ..) = task
  case retryable && attempt < context.retry.max_attempts {
    True ->
      transition_generation(
        task,
        SummaryRetryWait(
          context:,
          next_attempt: attempt + 1,
          not_before: in.now + backoff(context.retry, attempt),
          error_message: error.message,
        ),
      )
    False -> structural_failure(task, error)
  }
}

/// The structural section's default transition: rebuild the host's whole
/// operation state around a new generation step and commit just that.
fn transition_generation(
  task: StructuralTask,
  generation: SummaryGeneration,
) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  let next = host_state(host, Generating(task_id:, generation:))
  Transition(next:, tx: op_tx(op, in, [build.set_op_state(op.id, next)]))
}

/// An orphaned structural attempt is wholly uncertain: advance to a later
/// ready attempt under the captured policy, or fail at the cap (pi §4.5).
fn advance_orphaned_summary(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
) -> Action {
  case attempt < context.retry.max_attempts {
    True ->
      transition_generation(
        task,
        SummaryReady(context:, next_attempt: attempt + 1),
      )
    False ->
      structural_failure(
        task,
        OperationError(
          code: "interrupted",
          message: "structural generation was interrupted at the attempt cap",
          details: None,
        ),
      )
  }
}

fn dispatch_summary_request(
  task: StructuralTask,
  context: SummaryContext,
  attempt: Int,
  usage_ids: List(UsageId),
) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  let #(usage, _generator) = ids.mint_usage(in.generator)
  let index = list.length(usage_ids)
  let next_generation =
    SummaryEffectPending(
      context:,
      attempt:,
      request: Some(SummaryRequest(index:, usage:)),
      usage_ids:,
    )
  let next = host_state(host, Generating(task_id:, generation: next_generation))
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
  host: StructuralHost,
  structural: StructuralDecision,
) -> OperationState {
  case host {
    // Written out rather than through `run_state`: a host state is built
    // from the host's own captured fields, and two of the three hosts
    // have no run behind them to take a pass from.
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

/// Whether a failed structural attempt is a statement about the *context*
/// rather than about the summarizer that was asked to shrink it.
///
/// The subject of the error decides, not its severity. Every way a
/// summarize attempt ordinarily ends badly — an unresolvable route, a
/// provider that would not answer, a summarizer that replied with a tool
/// call instead of a summary, a settlement lost with its process, an
/// attempt orphaned at the cap — describes the *summarizer*. The
/// conversation it was handed is untouched by all of them: still in the
/// tree, still projecting to the same messages, still the size it was
/// when the last generation request fitted the window. Losing the clamp
/// is not the same as losing the context.
///
/// So this is a denylist and not an allowlist, deliberately. A code this
/// function has never heard of — from a host's own hooks, or from a
/// wiring written after this line — is far likelier to be one more way
/// for a summarizer to be unavailable than a claim that the conversation
/// cannot be continued, and the two mistakes cost wildly different
/// amounts. Continuing when the run should have drained costs one more
/// generation request, and the overflow path catches it with a
/// preparation of its own. Draining when the run should have continued
/// costs the whole session, which is the failure this distinction exists
/// to prevent.
///
/// Corruption never arrives here. An undecodable register or an
/// observation that cannot belong to the current phase is a `Fault`
/// raised at its own site, not an `OperationError`, so nothing this
/// function returns can turn an impossible state into a survivable one.
fn fatal_to_the_context(error: OperationError) -> Bool {
  case error.code {
    "context_overflow" -> True
    _ -> False
  }
}

/// A threshold compaction the run could not perform, abandoned.
///
/// The run restores the checkpoint the compaction copied aside — the
/// same restore a *declined* threshold compaction does — and goes on
/// without the summary it wanted. That checkpoint is already marked
/// threshold-checked, so this boundary is not rechecked.
///
/// **And threshold compaction is switched off for the rest of this run.**
/// That is the deliberate answer to "what does the run do next", and it
/// is worth stating plainly because the alternative is quiet and
/// expensive. Restoring the checkpoint alone would leave the gate open:
/// the next appended entry is a new trigger, the boundary is unchecked
/// again, the threshold is still exceeded — the context did not shrink —
/// and the run would spend a whole retry ladder against the same dead
/// route on every turn for the rest of its life. Clearing `enabled`
/// records the abandoned attempt in the one place the check already
/// reads (`after_inbox`, step 3) and in state that is already durable,
/// so a crash-restore does not re-open the gate.
///
/// The backoff interval is the operation. `RunSettings` is captured per
/// operation at acceptance, so the next run on this strand takes a fresh
/// snapshot with compaction enabled and asks the summarizer again: this
/// suppresses the retry loop within one run without disabling compaction
/// for the session.
///
/// The run then continues unclamped, and that is survivable because the
/// clamp was never the only guard. Overflow recovery does not consult
/// these settings at all — a request that does not fit still diverts
/// into a compaction task — so the provider's own limit remains the
/// backstop. If the summarizer is still down when it fires, that
/// compaction drains the run, and by then draining is the honest
/// outcome: the context genuinely will not fit.
fn abandon_threshold_compaction(
  pass: RunPass,
  resume: CheckpointPhase,
) -> Action {
  let RunPass(op:, settings:, ..) = pass
  let clamped =
    RunSettings(
      ..settings,
      compaction: CompactionSettings(..settings.compaction, enabled: False),
    )
  let next =
    run_state(
      RunPass(..pass, settings: clamped),
      Checkpoint(checkpoint: resume),
    )
  transition(pass, next, [build.set_op_state(op.id, next)])
}

/// A structural failure the run cannot survive: the whole run drains.
///
/// The provenance is the failure's *subject*, and the distinction is
/// older than this one. A captured identity that no longer resolves is a
/// configuration failure — nothing was dispatched, no response or usage
/// was fabricated, and the same code reaches the drain from an assistant
/// step. Anything else is a property of this summary task, and its
/// `task_id` locates the preparation register the failure happened over.
fn drain_failed_structural(
  pass: RunPass,
  task_id: String,
  error: OperationError,
) -> Action {
  let RunPass(op:, ..) = pass
  let provenance = case error.code {
    "model_unavailable" | "configured_tools_unavailable" ->
      ConfigurationProvenance
    _ -> StructuralProvenance(task_id:)
  }
  let next = run_state(pass, FailureDrain(error:, provenance:))
  transition(pass, next, [build.set_op_state(op.id, next)])
}

/// Terminal or in-run failure for structural work.
///
/// For an in-run host the `CompactionReason` decides whether the run
/// survives, exactly as it does on the decline path just above. A
/// **threshold** compaction is Loom's own clamp: failing to apply it
/// costs the clamp, not the conversation, so a recoverable failure
/// abandons the compaction and the run carries on. An **overflow**
/// compaction is the provider's verdict that the context does not fit,
/// and a run that cannot shrink a context the provider has already
/// refused has nowhere left to go, so it drains whatever the error says.
/// A standalone or navigation host has no run to keep alive and finishes
/// failed either way.
fn structural_failure(task: StructuralTask, error: OperationError) -> Action {
  let StructuralTask(op:, in:, task_id:, host:) = task
  case host {
    InRunHost(reason:, settings:, inbox:, latest:, resume:) -> {
      let pass = RunPass(op:, in:, control: Running, settings:, inbox:, latest:)
      case reason, fatal_to_the_context(error) {
        ThresholdReason, False -> abandon_threshold_compaction(pass, resume)
        ThresholdReason, True | OverflowReason, _ ->
          drain_failed_structural(pass, task_id, error)
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
  task: StructuralTask,
  summary: String,
  usage: Option(Usage),
  from_hook: Bool,
) -> Action {
  let StructuralTask(op:, in:, host:, ..) = task
  case host {
    InRunHost(settings:, inbox:, latest:, resume:, ..) -> {
      use #(writes, _entry_id) <- or_fault(compaction_publication(
        task,
        summary,
        usage,
        from_hook,
      ))
      let pass = RunPass(op:, in:, control: Running, settings:, inbox:, latest:)
      let next = run_state(pass, Checkpoint(checkpoint: resume))
      transition(
        pass,
        next,
        list.append(writes, [build.set_op_state(op.id, next)]),
      )
    }
    StandaloneHost(..) -> {
      use #(writes, entry_id) <- or_fault(compaction_publication(
        task,
        summary,
        usage,
        from_hook,
      ))
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

      // The branch summary is parented on the abandoned leaf, so a
      // navigation that never had one has nothing to summarize.
      use source_leaf <- or_fault(option.to_result(
        op.source_leaf,
        corruption.report(
          at: "machine/planner.publish_structural",
          on: build.op_key(op.id),
          expected: "a non-null source leaf for a summarized navigation",
          context: "null source leaf",
        ),
      ))
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

/// Builds the compaction-entry publication writes: hook usage row (when
/// hook-supplied usage exists), the compaction entry parented on the
/// current leaf, and the leaf move.
fn compaction_publication(
  task: StructuralTask,
  summary: String,
  usage: Option(Usage),
  from_hook: Bool,
) -> Result(#(List(Write), EntryId), CorruptionReport) {
  let StructuralTask(op:, in:, ..) = task
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
  case navigation, control {
    UnsummarizedNavigation(..), CancelRequested(..) ->
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
    UnsummarizedNavigation(target:, label:), Running -> {
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
    SummarizedNavigation(target:, label:, custom_instructions:, structural:), _
    ->
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
///
/// `op` and `in` come in separately here, not as a `RunPass`: ten of the
/// thirteen callers are on the standalone-compaction or navigation
/// paths, which have no run and therefore no pass to hand over.
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

/// Binds a fallible read of the inputs or the durable state, faulting on
/// corruption. This is the planner's `use` form for
/// `Result(a, CorruptionReport)`: `result.try` cannot serve, because the
/// continuation returns an `Action` and not another `Result`.
///
/// It exists because the alternative is the same two-armed `case` at a
/// dozen sites, whose error arm is always exactly `Fault(report:)` and
/// whose success arm swallows the rest of the function into another
/// level of indentation. Gleam has no early return; this is how the
/// planner gets one for the corruption path.
///
/// ## Examples
///
/// ```gleam
/// // use batch <- or_fault(plan_batch(in, message, context, entry))
/// ```
///
fn or_fault(
  result: Result(a, CorruptionReport),
  then: fn(a) -> Action,
) -> Action {
  case result {
    Error(report) -> Fault(report:)
    Ok(value) -> then(value)
  }
}

/// The guard form of `or_fault`: proceed when the condition holds,
/// otherwise fault with the given report. `bool.guard` cannot serve,
/// because its `return` is an `Action` and the report has to become
/// one.
///
/// ## Examples
///
/// ```gleam
/// // use <- or_fault_unless(is_tool_result(result), fn() { report })
/// ```
///
/// The report is a thunk because it is an ordinary argument otherwise:
/// building a `CorruptionReport` on every call, taken or not, is the
/// hazard `bool.guard`'s `return:` has, and the reports here are not
/// free — they format an op key and bound their context string.
fn or_fault_unless(
  condition: Bool,
  report: fn() -> CorruptionReport,
  then: fn() -> Action,
) -> Action {
  case condition {
    True -> then()
    False -> Fault(report: report())
  }
}

/// The durable state this pass describes, moved to `phase`.
///
/// The inverse of the destructuring in `next_action`: every run
/// transition is "these four fields, at a new phase", so the four are
/// carried as a `RunPass` and put back together here. A handler that
/// means to change one of them says so at this call —
/// `run_state(RunPass(..pass, inbox: remaining), phase)` — which is the
/// one place a reader has to look to see what a transition altered
/// besides the phase.
fn run_state(pass: RunPass, phase: RunPhase) -> OperationState {
  RunState(
    control: pass.control,
    settings: pass.settings,
    phase:,
    inbox: pass.inbox,
    latest_assistant: pass.latest,
  )
}

/// The default transition action: writes guarded by the op-state seq.
fn transition(
  pass: RunPass,
  next: OperationState,
  writes: List(Write),
) -> Action {
  Transition(next:, tx: op_tx(pass.op, pass.in, writes))
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
  pass: RunPass,
  items: List(EntryId),
) -> Result(Placement, CorruptionReport) {
  let in = pass.in
  list.try_fold(
    items,
    Placement(writes: [], newest: None, projecting: False),
    fn(acc, id) {
      let parent = case acc.newest {
        Some(newest) -> Some(newest)
        None -> in.leaf
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
