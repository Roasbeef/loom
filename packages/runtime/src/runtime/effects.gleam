//// The effect seam: everything the strand driver does to the world,
//// injected as one record.
////
//// For M1 the runtime does not wire the real broker, tools, or provider
//// network — effects are injected. Production wiring (the M2 integration
//// task) fills this record with the real provider gateway, the
//// ToolBroker, and the tool registry; tests fill it with scripted fakes.
//// The provider surface is type-compatible with `provider/stream`'s
//// `StreamHandle` contract (zero or more deltas, exactly one terminal),
//// and the tool-runner shape is modeled on the broker's `clear_call`
//// settlement events without depending on the broker package: the M2
//// integration adapts `broker.CallOutcome` into `ToolOutcome` here.
////
//// Also here: the retryability bridge (spec-gaps WP-D item 3). The
//// machine reads the adapter's retryable judgment from
//// `raw_stop_reason == "retryable"`; `settle_failure` encodes a
//// `ProviderError` into that convention using `provider/retry.classify`.

import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type DeferredHandle, type ToolCall, AssistantMessage,
  Errored,
}
import gleam/option.{type Option, None, Some}
import machine/operation.{type ReplayPolicy, type StructuralPreparation}
import machine/planner.{
  type ModelResolution, type PreparationOutcome, type RequestAdmission,
  type StructuralVerdict, type SummaryProgress, type ThresholdStatus, Admitted,
  EmptyPreparation, ModelResolved, SummaryProduced, ThresholdNotExceeded,
  VerdictDeclined,
}
import machine/strand.{type StrandConfiguration}
import provider/retry
import provider/stream.{type ProviderError, type StreamHandle}

/// One provider request as the driver dispatches it. The variants mirror
/// the machine's provider-shaped effect intents; production wiring maps
/// them onto `gateway.request`, fakes script terminals directly.
///
/// Constructor invariants: `context` is the projected provider context
/// (oldest first, already filtered by the standard drop rules);
/// `configuration` is the captured identity snapshot from the intent, not
/// the strand's current configuration.
pub type RequestSpec {
  /// An ordinary assistant generation attempt.
  GenerationRequest(
    operation: OpId,
    step_id: String,
    attempt: Int,
    configuration: StrandConfiguration,
    context: List(AgentMessage),
    stream_options: JsonValue,
  )
  /// One deferred-response poll against the newest source handle.
  PollRequest(
    operation: OpId,
    step_id: String,
    poll: Int,
    handle: DeferredHandle,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
  /// One nested structural-summary request.
  SummaryRequest(
    operation: OpId,
    task_id: String,
    attempt: Int,
    request_index: Int,
    preparation: Option(StructuralPreparation),
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
}

/// The provider surface: called on the effect process, which owns the
/// returned handle and consumes it with `stream.await_terminal`.
pub type ProviderSurface {
  ProviderSurface(
    /// Starts one request and returns its live stream.
    request: fn(RequestSpec) -> StreamHandle,
    /// How long the effect process waits for the terminal event, in
    /// milliseconds, before settling the attempt as a transport failure.
    timeout_ms: Int,
  )
}

/// One tool execution as the driver dispatches it.
///
/// Constructor invariants: `arguments` are the persisted effective
/// arguments (post-clearance); `replay` is the policy persisted in the
/// intent — a runner must not consult the live registry for it.
pub type ToolRun {
  ToolRun(
    operation: OpId,
    step_id: String,
    source_index: Int,
    call: ToolCall,
    arguments: JsonValue,
    replay: ReplayPolicy,
  )
}

/// How a tool execution settled, mirroring the broker's `CallOutcome`
/// split (`CallExited` | `CallFailed`) without a broker dependency.
pub type ToolOutcome {
  /// The tool produced a finalized result message (which may itself be an
  /// in-band error result) and its termination flag.
  ToolCompleted(result: AgentMessage, terminate: Bool)
  /// The execution failed outside the tool's own result channel (runner
  /// refusal, channel death). The driver stages a synthetic error result.
  ToolFailed(reason: String)
}

/// Clearance for one planned call: the pre-effect half of the broker's
/// `clear_call`, collapsed to what the machine needs.
pub type ClearanceQuery {
  ClearanceQuery(
    operation: OpId,
    step_id: String,
    source_index: Int,
    call: ToolCall,
    configuration: StrandConfiguration,
  )
}

/// The clearance verdict.
pub type Clearance {
  /// Execute with these effective arguments under this replay policy.
  Cleared(effective_arguments: JsonValue, replay: ReplayPolicy)
  /// Refuse the call (unknown tool, invalid arguments, policy block);
  /// the driver stages a synthetic error result carrying `reason`.
  ClearanceRefused(reason: String)
}

/// The tool surface: clearance, execution, and the replay-still-safe
/// check orphan recovery consults.
pub type ToolSurface {
  ToolSurface(
    /// Clears (or refuses) one planned call.
    clear: fn(ClearanceQuery) -> Clearance,
    /// Runs one cleared call; called on the effect process and may block
    /// for the execution's duration.
    run: fn(ToolRun) -> ToolOutcome,
    /// Whether the named tool's *current* registration still declares
    /// safe replay (pi §4.5: both stored and current declarations must
    /// say safe for a re-execution).
    replay_still_safe: fn(String) -> Bool,
  )
}

/// The pre-request admission query (identity resolution plus the
/// pre-request hook's composed options).
pub type AdmissionQuery {
  AdmissionQuery(
    operation: OpId,
    step_id: String,
    attempt: Int,
    configuration: StrandConfiguration,
    stream_options: JsonValue,
  )
}

/// The threshold-compaction query answered at every checkpoint boundary.
pub type ThresholdQuery {
  ThresholdQuery(operation: OpId, strand: String)
}

/// The hook surface the driver consults for hook-shaped effect keys.
/// Hooks are replayable and carry no effect intent (a crash before the
/// consuming commit may rerun them), so they are plain synchronous
/// functions here.
pub type Hooks {
  Hooks(
    /// `before_run`: messages to inject at run start.
    run_start: fn(OpId) -> List(AgentMessage),
    /// Pre-request admission for a ready generation attempt.
    admission: fn(AdmissionQuery) -> RequestAdmission,
    /// `before_run_end`: an optional born-placed follow-up message.
    run_end: fn(OpId) -> Option(AgentMessage),
    /// The threshold-compaction signal for the current checkpoint.
    threshold: fn(ThresholdQuery) -> ThresholdStatus,
    /// Builds the compaction preparation an overflow settlement needs.
    overflow_preparation: fn(OpId) -> PreparationOutcome,
    /// The structural decision hook for a deciding task.
    structural_decision: fn(OpId, String) -> StructuralVerdict,
    /// The structural attempt's progress after its latest request
    /// cleared.
    summary_progress: fn(OpId, String, Int) -> SummaryProgress,
    /// Whether a captured identity currently resolves (deferred polls,
    /// summary requests).
    resolution: fn(StrandConfiguration) -> ModelResolution,
  )
}

/// Everything the strand driver needs to touch the world.
///
/// Constructor invariants: `clock` is the driver's time source (tests
/// inject fixtures); `entropy` returns a fresh seed for every id
/// generator — values must never repeat within a session's lifetime, or
/// re-minted ids could collide with committed ones.
pub type Effects {
  Effects(
    clock: Clock,
    entropy: fn() -> Int,
    provider: ProviderSurface,
    tools: ToolSurface,
    hooks: Hooks,
  )
}

/// Hooks that do nothing: no injected messages, requests admitted with
/// effectively unlimited windows, no follow-ups, threshold never crossed,
/// structural decisions declined, identities always resolved. The M2
/// integration replaces these with the real hook registry.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(clock:, entropy:, provider:, tools:,
/// //   hooks: effects.default_hooks())
/// ```
///
pub fn default_hooks() -> Hooks {
  Hooks(
    run_start: fn(_) { [] },
    admission: fn(query: AdmissionQuery) {
      Admitted(
        stream_options: query.stream_options,
        intended_output_limit: 1_000_000,
        context_window: 1_000_000,
      )
    },
    run_end: fn(_) { None },
    threshold: fn(_) { ThresholdNotExceeded },
    overflow_preparation: fn(_) { EmptyPreparation },
    structural_decision: fn(_, _) { VerdictDeclined },
    summary_progress: fn(_, _, _) { SummaryProduced(summary: "", usage: None) },
    resolution: fn(_) { ModelResolved },
  )
}

/// Encodes a provider failure as a settled zero-usage error response
/// under the captured identity — the retryability bridge (spec-gaps WP-D
/// item 3): `raw_stop_reason` carries `"retryable"` exactly when
/// `provider/retry.classify` judges the error retryable, which is the
/// convention `ClassifyCtx.error_retryable` is derived from.
///
/// ## Examples
///
/// ```gleam
/// // effects.settle_failure(error, configuration, now).raw_stop_reason
/// //   == Some("retryable")  // for a 500
/// ```
///
pub fn settle_failure(
  error: ProviderError,
  configuration: StrandConfiguration,
  now: Int,
) -> AgentMessage {
  let raw_stop_reason = case retry.classify(error) {
    retry.Retryable(backoff_hint_ms: _) -> Some("retryable")
    retry.Terminal -> Some("terminal")
  }
  AssistantMessage(
    content: [],
    api: "unknown",
    provider: configuration.model.provider,
    model: configuration.model.model_id,
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: zero_usage(),
    stop_reason: Errored,
    deferred: None,
    error_message: Some(stream.describe_error(error)),
    raw_stop_reason:,
    end_turn: None,
    timestamp: now,
  )
}

/// The zero usage aggregate for synthetic settlements.
///
/// ## Examples
///
/// ```gleam
/// assert effects.zero_usage().total_tokens == 0
/// ```
///
pub fn zero_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}
