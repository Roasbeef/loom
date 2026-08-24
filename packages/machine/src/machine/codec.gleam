//// Durability-boundary JSON codecs for the machine's register payloads.
////
//// The `machine` package owns the rich payload types stored under the
//// orchestration register namespaces (`strand.config`, `strand.state`,
//// `strand.last_result`, `op.meta`, `op.state`, `op.preparation`,
//// `pending.entry`); `core` persists them as tagged JSON. This module maps
//// each type to and from `core/json` `JsonValue`. Encoders are plain
//// functions; decoders are total, returning `Result(t, CorruptionReport)`
//// for any input that does not match — wrong shapes and wrong kinds are
//// reports, never crashes.
////
//// Wire vocabulary follows pi's field names (`operationId`,
//// `triggerEntryId`, `skipInboxOnce`, `resumeAfter`, ...) with pi's "lane"
//// renamed to "strand". Kind/status discriminants use pi's exact strings
//// (`"run"`, `"checkpoint"`, `"effect_pending"`, `"one-at-a-time"`, ...).
//// Optional typed fields are omitted when absent; opaque JSON fields
//// (`details`, `data`, `streamOptions`) keep a present `null` distinct
//// from absence where their type permits.

import core/codec as core_codec
import core/corruption.{type CorruptionReport}
import core/ids.{type EntryId, type UsageId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/operation.{
  type CheckpointPhase, type CompactionSettings, type Continuation, type Control,
  type DeferredState, type FailureProvenance, type FileOperations,
  type Generation, type GenerationContext, type Inbox, type LastResult,
  type Navigation, type NormalizedRetryPolicy, type Operation,
  type OperationError, type OperationIntent, type OperationState,
  type PendingEntry, type QueueMode, type RunPhase, type RunSettings,
  type StructuralDecision, type StructuralOutcome, type StructuralPreparation,
  type SummaryContext, type SummaryGeneration, type ToolBatch,
  type ToolCallState, Assistant, AwaitingDeferred, BranchSummary,
  BranchSummaryPreparation, CallCompleted, CallEffectPending, CallOutcomeReady,
  CallPlanned, CancelRequested, Checkpoint, CheckpointPhase, Compacting,
  CompactionIntent, CompactionLastResult, CompactionPreparation,
  CompactionSettings, CompactionState, CompactionSummary, CompletedByAssistant,
  CompletedByTerminatedTools, ConfigurationProvenance, ConsumeAll, Deciding,
  DeferredEffectPending, DeferredSuspended, FailureDrain, FileOperations,
  Generating, GenerationContext, GenerationEffectPending, GenerationReady,
  GenerationRetryWait, Inbox, ManualSummary, MayFinish, NavigationIntent,
  NavigationLastResult, NavigationState, NeedAssistant, NormalizedRetryPolicy,
  OneAtATime, Operation, OperationError, OverflowReason, OverflowSummary,
  Parallel, PendingCustom, PendingMessage, ReplayNever, ReplaySafe,
  ResponseProvenance, RunAborted, RunCompleted, RunFailed, RunIntent,
  RunLastResult, RunSettings, RunState, Running, Sequential, Starting,
  StructuralAborted, StructuralCompleted, StructuralDeclined, StructuralFailed,
  StructuralProvenance, SummarizedNavigation, SummaryContext,
  SummaryEffectPending, SummaryReady, SummaryRequest, SummaryRetryWait,
  ThresholdReason, ThresholdSummary, ToolBatch, Tools, UnsummarizedNavigation,
}
import machine/strand.{
  type ModelIdentity, type StrandConfiguration, type StrandState,
  type ThinkingLevel, ModelIdentity, StrandConfiguration, StrandState,
  ThinkingHigh, ThinkingLow, ThinkingMax, ThinkingMedium, ThinkingMinimal,
  ThinkingOff, ThinkingXHigh,
}

// --- strand configuration -------------------------------------------------

/// Encodes a `StrandConfiguration` (the `strand.config` payload).
///
/// ## Examples
///
/// ```gleam
/// let config =
///   strand.StrandConfiguration(
///     strand.ModelIdentity("p", "m"),
///     strand.ThinkingOff,
///     [],
///   )
/// assert codec.decode_configuration(codec.encode_configuration(config))
///   == Ok(config)
/// ```
///
pub fn encode_configuration(configuration: StrandConfiguration) -> JsonValue {
  json.Object([
    #("model", encode_model(configuration.model)),
    #(
      "thinkingLevel",
      json.String(thinking_level_to_string(configuration.thinking_level)),
    ),
    #(
      "activeToolNames",
      json.Array(list.map(configuration.active_tool_names, json.String)),
    ),
  ])
}

/// Decodes a `StrandConfiguration`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_configuration(json.Null)
/// ```
///
pub fn decode_configuration(
  value: JsonValue,
) -> Result(StrandConfiguration, CorruptionReport) {
  let where = "machine/codec.configuration"
  use fields <- result.try(fields_of(value, where))
  use model_value <- result.try(require(fields, "model", where))
  use model <- result.try(decode_model(model_value))
  use level_text <- result.try(require_string(fields, "thinkingLevel", where))
  use thinking_level <- result.try(parse_thinking_level(level_text, where))
  use names_value <- result.try(require_array(fields, "activeToolNames", where))
  use active_tool_names <- result.try(
    list.try_map(names_value, fn(item) { as_string(item, where) }),
  )
  Ok(StrandConfiguration(model:, thinking_level:, active_tool_names:))
}

fn encode_model(model: ModelIdentity) -> JsonValue {
  json.Object([
    #("provider", json.String(model.provider)),
    #("modelId", json.String(model.model_id)),
  ])
}

fn decode_model(value: JsonValue) -> Result(ModelIdentity, CorruptionReport) {
  let where = "machine/codec.model"
  use fields <- result.try(fields_of(value, where))
  use provider <- result.try(require_string(fields, "provider", where))
  use model_id <- result.try(require_string(fields, "modelId", where))
  Ok(ModelIdentity(provider:, model_id:))
}

fn thinking_level_to_string(level: ThinkingLevel) -> String {
  case level {
    ThinkingOff -> "off"
    ThinkingMinimal -> "minimal"
    ThinkingLow -> "low"
    ThinkingMedium -> "medium"
    ThinkingHigh -> "high"
    ThinkingXHigh -> "xhigh"
    ThinkingMax -> "max"
  }
}

fn parse_thinking_level(
  text: String,
  where: String,
) -> Result(ThinkingLevel, CorruptionReport) {
  case text {
    "off" -> Ok(ThinkingOff)
    "minimal" -> Ok(ThinkingMinimal)
    "low" -> Ok(ThinkingLow)
    "medium" -> Ok(ThinkingMedium)
    "high" -> Ok(ThinkingHigh)
    "xhigh" -> Ok(ThinkingXHigh)
    "max" -> Ok(ThinkingMax)
    other ->
      Error(corruption.report(
        at: where,
        on: "thinkingLevel",
        expected: "a thinking level name",
        context: other,
      ))
  }
}

// --- strand state ---------------------------------------------------------

/// Encodes a `StrandState` (the `strand.state` payload).
///
/// ## Examples
///
/// ```gleam
/// let state = strand.StrandState(None, [])
/// assert codec.decode_strand_state(codec.encode_strand_state(state))
///   == Ok(state)
/// ```
///
pub fn encode_strand_state(state: StrandState) -> JsonValue {
  json.Object([
    #("currentOperationId", case state.current_operation {
      Some(id) -> json.String(ids.op_id_to_string(id))
      None -> json.Null
    }),
    #(
      "pendingNextRun",
      json.Array(list.map(state.pending_next_run, encode_entry_id)),
    ),
  ])
}

/// Decodes a `StrandState`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_strand_state(json.Int(3))
/// ```
///
pub fn decode_strand_state(
  value: JsonValue,
) -> Result(StrandState, CorruptionReport) {
  let where = "machine/codec.strand_state"
  use fields <- result.try(fields_of(value, where))
  use current_value <- result.try(require(fields, "currentOperationId", where))
  use current_operation <- result.try(case current_value {
    json.Null -> Ok(None)
    json.String(text) -> result.map(ids.parse_op_id(text), Some)
    other ->
      Error(corruption.report(
        at: where,
        on: "currentOperationId",
        expected: "null or an operation id string",
        context: json.to_string(other),
      ))
  })
  use pending_value <- result.try(require_array(fields, "pendingNextRun", where))
  use pending_next_run <- result.try(list.try_map(
    pending_value,
    decode_entry_id_value,
  ))
  Ok(StrandState(current_operation:, pending_next_run:))
}

// --- operation metadata ---------------------------------------------------

/// Encodes an `Operation` (the write-once `op.meta` payload).
///
/// ## Examples
///
/// ```gleam
/// // Round-trips for every intent kind; see the codec tests.
/// // codec.decode_operation(codec.encode_operation(meta)) == Ok(meta)
/// ```
///
pub fn encode_operation(operation: Operation) -> JsonValue {
  let intent = case operation.intent {
    RunIntent(prompt_entries:) ->
      json.Object([
        #("kind", json.String("run")),
        #(
          "promptEntryIds",
          json.Array(list.map(prompt_entries, encode_entry_id)),
        ),
      ])
    CompactionIntent(custom_instructions:) ->
      object_of([
        #("kind", Some(json.String("compaction"))),
        #("customInstructions", option.map(custom_instructions, json.String)),
      ])
    NavigationIntent(target:, summarize:, label:, custom_instructions:) ->
      object_of([
        #("kind", Some(json.String("navigation"))),
        #("targetId", Some(encode_optional_entry_id(target))),
        #("summarize", Some(json.Bool(summarize))),
        #("label", option.map(label, json.String)),
        #("customInstructions", option.map(custom_instructions, json.String)),
      ])
  }
  json.Object([
    #("operationId", json.String(ids.op_id_to_string(operation.id))),
    #("strand", json.String(operation.strand)),
    #("sourceLeafId", encode_optional_entry_id(operation.source_leaf)),
    #("startedAt", json.Int(operation.started_at)),
    #("intent", intent),
  ])
}

/// Decodes an `Operation`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_operation(json.Array([]))
/// ```
///
pub fn decode_operation(
  value: JsonValue,
) -> Result(Operation, CorruptionReport) {
  let where = "machine/codec.operation"
  use fields <- result.try(fields_of(value, where))
  use id_text <- result.try(require_string(fields, "operationId", where))
  use id <- result.try(ids.parse_op_id(id_text))
  use strand_name <- result.try(require_string(fields, "strand", where))
  use source_value <- result.try(require(fields, "sourceLeafId", where))
  use source_leaf <- result.try(decode_optional_entry_id(source_value, where))
  use started_at <- result.try(require_int(fields, "startedAt", where))
  use intent_value <- result.try(require(fields, "intent", where))
  use intent <- result.try(decode_intent(intent_value))
  Ok(Operation(id:, strand: strand_name, source_leaf:, started_at:, intent:))
}

fn decode_intent(
  value: JsonValue,
) -> Result(OperationIntent, CorruptionReport) {
  let where = "machine/codec.operation.intent"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  case kind {
    "run" -> {
      use prompts <- result.try(require_array(fields, "promptEntryIds", where))
      use prompt_entries <- result.try(list.try_map(
        prompts,
        decode_entry_id_value,
      ))
      Ok(RunIntent(prompt_entries:))
    }
    "compaction" -> {
      use custom_instructions <- result.try(optional_string(
        fields,
        "customInstructions",
        where,
      ))
      Ok(CompactionIntent(custom_instructions:))
    }
    "navigation" -> {
      use target_value <- result.try(require(fields, "targetId", where))
      use target <- result.try(decode_optional_entry_id(target_value, where))
      use summarize <- result.try(require_bool(fields, "summarize", where))
      use label <- result.try(optional_string(fields, "label", where))
      use custom_instructions <- result.try(optional_string(
        fields,
        "customInstructions",
        where,
      ))
      Ok(NavigationIntent(target:, summarize:, label:, custom_instructions:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "run, compaction, or navigation",
        context: other,
      ))
  }
}

// --- control and errors ---------------------------------------------------

/// Encodes a `Control`.
pub fn encode_control(control: Control) -> JsonValue {
  case control {
    Running -> json.Object([#("status", json.String("running"))])
    CancelRequested(requested_at:, drained_steer:, drained_follow_up:) ->
      json.Object([
        #("status", json.String("cancel_requested")),
        #("requestedAt", json.Int(requested_at)),
        #("drainedSteer", json.Array(list.map(drained_steer, encode_entry_id))),
        #(
          "drainedFollowUp",
          json.Array(list.map(drained_follow_up, encode_entry_id)),
        ),
      ])
  }
}

/// Decodes a `Control`. Total.
pub fn decode_control(value: JsonValue) -> Result(Control, CorruptionReport) {
  let where = "machine/codec.control"
  use fields <- result.try(fields_of(value, where))
  use status <- result.try(require_string(fields, "status", where))
  case status {
    "running" -> Ok(Running)
    "cancel_requested" -> {
      use requested_at <- result.try(require_int(fields, "requestedAt", where))
      use steer_value <- result.try(require_array(fields, "drainedSteer", where))
      use drained_steer <- result.try(list.try_map(
        steer_value,
        decode_entry_id_value,
      ))
      use follow_value <- result.try(require_array(
        fields,
        "drainedFollowUp",
        where,
      ))
      use drained_follow_up <- result.try(list.try_map(
        follow_value,
        decode_entry_id_value,
      ))
      Ok(CancelRequested(requested_at:, drained_steer:, drained_follow_up:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "running or cancel_requested",
        context: other,
      ))
  }
}

/// Encodes an `OperationError`.
pub fn encode_operation_error(error: OperationError) -> JsonValue {
  object_of([
    #("code", Some(json.String(error.code))),
    #("message", Some(json.String(error.message))),
    #("details", error.details |> option.map(fn(details) { details })),
  ])
}

/// Decodes an `OperationError`. Total.
pub fn decode_operation_error(
  value: JsonValue,
) -> Result(OperationError, CorruptionReport) {
  let where = "machine/codec.operation_error"
  use fields <- result.try(fields_of(value, where))
  use code <- result.try(require_string(fields, "code", where))
  use message_text <- result.try(require_string(fields, "message", where))
  let details = optional_json(fields, "details")
  Ok(OperationError(code:, message: message_text, details:))
}

fn encode_provenance(provenance: FailureProvenance) -> JsonValue {
  case provenance {
    ResponseProvenance(entry:) ->
      json.Object([
        #("kind", json.String("response")),
        #("entryId", encode_entry_id(entry)),
      ])
    StructuralProvenance(task_id:) ->
      json.Object([
        #("kind", json.String("structural")),
        #("taskId", json.String(task_id)),
      ])
    ConfigurationProvenance ->
      json.Object([#("kind", json.String("configuration"))])
  }
}

fn decode_provenance(
  value: JsonValue,
) -> Result(FailureProvenance, CorruptionReport) {
  let where = "machine/codec.provenance"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  case kind {
    "response" -> {
      use entry <- result.try(require_entry_id(fields, "entryId", where))
      Ok(ResponseProvenance(entry:))
    }
    "structural" -> {
      use task_id <- result.try(require_string(fields, "taskId", where))
      Ok(StructuralProvenance(task_id:))
    }
    "configuration" -> Ok(ConfigurationProvenance)
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "response, structural, or configuration",
        context: other,
      ))
  }
}

// --- run settings ---------------------------------------------------------

fn encode_settings(settings: RunSettings) -> JsonValue {
  json.Object([
    #("compaction", encode_compaction_settings(settings.compaction)),
    #("steeringMode", json.String(queue_mode_to_string(settings.steering_mode))),
    #(
      "followUpMode",
      json.String(queue_mode_to_string(settings.follow_up_mode)),
    ),
    #("toolExecution", case settings.tool_execution {
      Sequential -> json.String("sequential")
      Parallel -> json.String("parallel")
    }),
  ])
}

fn decode_settings(value: JsonValue) -> Result(RunSettings, CorruptionReport) {
  let where = "machine/codec.settings"
  use fields <- result.try(fields_of(value, where))
  use compaction_value <- result.try(require(fields, "compaction", where))
  use compaction <- result.try(decode_compaction_settings(compaction_value))
  use steering_text <- result.try(require_string(fields, "steeringMode", where))
  use steering_mode <- result.try(parse_queue_mode(steering_text, where))
  use follow_text <- result.try(require_string(fields, "followUpMode", where))
  use follow_up_mode <- result.try(parse_queue_mode(follow_text, where))
  use execution_text <- result.try(require_string(
    fields,
    "toolExecution",
    where,
  ))
  use tool_execution <- result.try(case execution_text {
    "sequential" -> Ok(Sequential)
    "parallel" -> Ok(Parallel)
    other ->
      Error(corruption.report(
        at: where,
        on: "toolExecution",
        expected: "sequential or parallel",
        context: other,
      ))
  })
  Ok(RunSettings(compaction:, steering_mode:, follow_up_mode:, tool_execution:))
}

/// Encodes `CompactionSettings`.
pub fn encode_compaction_settings(settings: CompactionSettings) -> JsonValue {
  json.Object([
    #("enabled", json.Bool(settings.enabled)),
    #("reserveTokens", json.Int(settings.reserve_tokens)),
    #("keepRecentTokens", json.Int(settings.keep_recent_tokens)),
  ])
}

/// Decodes `CompactionSettings`. Total.
pub fn decode_compaction_settings(
  value: JsonValue,
) -> Result(CompactionSettings, CorruptionReport) {
  let where = "machine/codec.compaction_settings"
  use fields <- result.try(fields_of(value, where))
  use enabled <- result.try(require_bool(fields, "enabled", where))
  use reserve_tokens <- result.try(require_int(fields, "reserveTokens", where))
  use keep_recent_tokens <- result.try(require_int(
    fields,
    "keepRecentTokens",
    where,
  ))
  Ok(CompactionSettings(enabled:, reserve_tokens:, keep_recent_tokens:))
}

fn queue_mode_to_string(mode: QueueMode) -> String {
  case mode {
    ConsumeAll -> "all"
    OneAtATime -> "one-at-a-time"
  }
}

fn parse_queue_mode(
  text: String,
  where: String,
) -> Result(QueueMode, CorruptionReport) {
  case text {
    "all" -> Ok(ConsumeAll)
    "one-at-a-time" -> Ok(OneAtATime)
    other ->
      Error(corruption.report(
        at: where,
        on: "queue mode",
        expected: "all or one-at-a-time",
        context: other,
      ))
  }
}

fn encode_retry(retry: NormalizedRetryPolicy) -> JsonValue {
  json.Object([
    #("maxAttempts", json.Int(retry.max_attempts)),
    #("baseDelayMs", json.Int(retry.base_delay_ms)),
  ])
}

fn decode_retry(
  value: JsonValue,
) -> Result(NormalizedRetryPolicy, CorruptionReport) {
  let where = "machine/codec.retry"
  use fields <- result.try(fields_of(value, where))
  use max_attempts <- result.try(require_int(fields, "maxAttempts", where))
  use base_delay_ms <- result.try(require_int(fields, "baseDelayMs", where))
  Ok(NormalizedRetryPolicy(max_attempts:, base_delay_ms:))
}

// --- operation state ------------------------------------------------------

/// Encodes an `OperationState` (the `op.state` payload — the durable
/// program counter).
///
/// ## Examples
///
/// ```gleam
/// // Round-trips for every constructor; see the state-coverage tests.
/// // codec.decode_state(codec.encode_state(state)) == Ok(state)
/// ```
///
pub fn encode_state(state: OperationState) -> JsonValue {
  case state {
    RunState(control:, settings:, phase:, inbox:, latest_assistant:) ->
      json.Object([
        #("kind", json.String("run")),
        #("control", encode_control(control)),
        #("settings", encode_settings(settings)),
        #("phase", encode_phase(phase)),
        #("inbox", encode_inbox(inbox)),
        #("latestAssistantEntryId", encode_optional_entry_id(latest_assistant)),
      ])
    CompactionState(control:, custom_instructions:, structural:) ->
      object_of([
        #("kind", Some(json.String("compaction"))),
        #("control", Some(encode_control(control))),
        #("customInstructions", option.map(custom_instructions, json.String)),
        #("structural", Some(encode_structural(structural))),
      ])
    NavigationState(control:, navigation:) ->
      json.Object([
        #("kind", json.String("navigation")),
        #("control", encode_control(control)),
        #("navigation", encode_navigation(navigation)),
      ])
  }
}

/// Decodes an `OperationState`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_state(json.String("run"))
/// ```
///
pub fn decode_state(
  value: JsonValue,
) -> Result(OperationState, CorruptionReport) {
  let where = "machine/codec.state"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  use control_value <- result.try(require(fields, "control", where))
  use control <- result.try(decode_control(control_value))
  case kind {
    "run" -> {
      use settings_value <- result.try(require(fields, "settings", where))
      use settings <- result.try(decode_settings(settings_value))
      use phase_value <- result.try(require(fields, "phase", where))
      use phase <- result.try(decode_phase(phase_value))
      use inbox_value <- result.try(require(fields, "inbox", where))
      use inbox <- result.try(decode_inbox(inbox_value))
      use latest_value <- result.try(require(
        fields,
        "latestAssistantEntryId",
        where,
      ))
      use latest_assistant <- result.try(decode_optional_entry_id(
        latest_value,
        where,
      ))
      Ok(RunState(control:, settings:, phase:, inbox:, latest_assistant:))
    }
    "compaction" -> {
      use custom_instructions <- result.try(optional_string(
        fields,
        "customInstructions",
        where,
      ))
      use structural_value <- result.try(require(fields, "structural", where))
      use structural <- result.try(decode_structural(structural_value))
      Ok(CompactionState(control:, custom_instructions:, structural:))
    }
    "navigation" -> {
      use navigation_value <- result.try(require(fields, "navigation", where))
      use navigation <- result.try(decode_navigation(navigation_value))
      Ok(NavigationState(control:, navigation:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "run, compaction, or navigation",
        context: other,
      ))
  }
}

fn encode_inbox(inbox: Inbox) -> JsonValue {
  json.Object([
    #("steer", json.Array(list.map(inbox.steer, encode_entry_id))),
    #("followUp", json.Array(list.map(inbox.follow_up, encode_entry_id))),
    #("writes", json.Array(list.map(inbox.writes, encode_entry_id))),
  ])
}

fn decode_inbox(value: JsonValue) -> Result(Inbox, CorruptionReport) {
  let where = "machine/codec.inbox"
  use fields <- result.try(fields_of(value, where))
  use steer_value <- result.try(require_array(fields, "steer", where))
  use steer <- result.try(list.try_map(steer_value, decode_entry_id_value))
  use follow_value <- result.try(require_array(fields, "followUp", where))
  use follow_up <- result.try(list.try_map(follow_value, decode_entry_id_value))
  use writes_value <- result.try(require_array(fields, "writes", where))
  use writes <- result.try(list.try_map(writes_value, decode_entry_id_value))
  Ok(Inbox(steer:, follow_up:, writes:))
}

fn encode_phase(phase: RunPhase) -> JsonValue {
  case phase {
    Starting -> json.Object([#("kind", json.String("starting"))])
    Checkpoint(checkpoint:) ->
      json.Object([
        #("kind", json.String("checkpoint")),
        #("checkpoint", encode_checkpoint(checkpoint)),
      ])
    Assistant(generation:) ->
      json.Object([
        #("kind", json.String("assistant")),
        #("generation", encode_generation(generation)),
      ])
    Tools(batch:) ->
      json.Object([
        #("kind", json.String("tools")),
        #("batch", encode_batch(batch)),
      ])
    Compacting(reason:, structural:, resume_after:) ->
      json.Object([
        #("kind", json.String("compaction")),
        #("reason", case reason {
          ThresholdReason -> json.String("threshold")
          OverflowReason -> json.String("overflow")
        }),
        #("structural", encode_structural(structural)),
        #("resumeAfter", encode_checkpoint(resume_after)),
      ])
    AwaitingDeferred(deferred:) ->
      json.Object([
        #("kind", json.String("deferred")),
        #("deferred", encode_deferred(deferred)),
      ])
    FailureDrain(error:, provenance:) ->
      json.Object([
        #("kind", json.String("failure_drain")),
        #("error", encode_operation_error(error)),
        #("provenance", encode_provenance(provenance)),
      ])
  }
}

fn decode_phase(value: JsonValue) -> Result(RunPhase, CorruptionReport) {
  let where = "machine/codec.phase"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  case kind {
    "starting" -> Ok(Starting)
    "checkpoint" -> {
      use checkpoint_value <- result.try(require(fields, "checkpoint", where))
      use checkpoint <- result.try(decode_checkpoint(checkpoint_value))
      Ok(Checkpoint(checkpoint:))
    }
    "assistant" -> {
      use generation_value <- result.try(require(fields, "generation", where))
      use generation <- result.try(decode_generation(generation_value))
      Ok(Assistant(generation:))
    }
    "tools" -> {
      use batch_value <- result.try(require(fields, "batch", where))
      use batch <- result.try(decode_batch(batch_value))
      Ok(Tools(batch:))
    }
    "compaction" -> {
      use reason_text <- result.try(require_string(fields, "reason", where))
      use reason <- result.try(case reason_text {
        "threshold" -> Ok(ThresholdReason)
        "overflow" -> Ok(OverflowReason)
        other ->
          Error(corruption.report(
            at: where,
            on: "reason",
            expected: "threshold or overflow",
            context: other,
          ))
      })
      use structural_value <- result.try(require(fields, "structural", where))
      use structural <- result.try(decode_structural(structural_value))
      use resume_value <- result.try(require(fields, "resumeAfter", where))
      use resume_after <- result.try(decode_checkpoint(resume_value))
      Ok(Compacting(reason:, structural:, resume_after:))
    }
    "deferred" -> {
      use deferred_value <- result.try(require(fields, "deferred", where))
      use deferred <- result.try(decode_deferred(deferred_value))
      Ok(AwaitingDeferred(deferred:))
    }
    "failure_drain" -> {
      use error_value <- result.try(require(fields, "error", where))
      use error <- result.try(decode_operation_error(error_value))
      use provenance_value <- result.try(require(fields, "provenance", where))
      use provenance <- result.try(decode_provenance(provenance_value))
      Ok(FailureDrain(error:, provenance:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "a run phase kind",
        context: other,
      ))
  }
}

fn encode_checkpoint(checkpoint: CheckpointPhase) -> JsonValue {
  let continuation = case checkpoint.continuation {
    NeedAssistant(overflow_recovery_used:) ->
      json.Object([
        #("kind", json.String("need_assistant")),
        #("overflowRecoveryUsed", json.Bool(overflow_recovery_used)),
      ])
    MayFinish(include_final_assistant:) ->
      json.Object([
        #("kind", json.String("may_finish")),
        #("includeFinalAssistant", json.Bool(include_final_assistant)),
      ])
  }
  object_of([
    #("continuation", Some(continuation)),
    #("triggerEntryId", Some(encode_entry_id(checkpoint.trigger))),
    #(
      "thresholdCheckedTriggerEntryId",
      option.map(checkpoint.threshold_checked, encode_entry_id),
    ),
    #("skipInboxOnce", Some(json.Bool(checkpoint.skip_inbox_once))),
  ])
}

fn decode_checkpoint(
  value: JsonValue,
) -> Result(CheckpointPhase, CorruptionReport) {
  let where = "machine/codec.checkpoint"
  use fields <- result.try(fields_of(value, where))
  use continuation_value <- result.try(require(fields, "continuation", where))
  use continuation <- result.try(decode_continuation(continuation_value))
  use trigger <- result.try(require_entry_id(fields, "triggerEntryId", where))
  use threshold_checked <- result.try(optional_entry_id(
    fields,
    "thresholdCheckedTriggerEntryId",
    where,
  ))
  use skip_inbox_once <- result.try(require_bool(fields, "skipInboxOnce", where))
  Ok(CheckpointPhase(
    continuation:,
    trigger:,
    threshold_checked:,
    skip_inbox_once:,
  ))
}

fn decode_continuation(
  value: JsonValue,
) -> Result(Continuation, CorruptionReport) {
  let where = "machine/codec.continuation"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  case kind {
    "need_assistant" -> {
      use overflow_recovery_used <- result.try(require_bool(
        fields,
        "overflowRecoveryUsed",
        where,
      ))
      Ok(NeedAssistant(overflow_recovery_used:))
    }
    "may_finish" -> {
      use include_final_assistant <- result.try(require_bool(
        fields,
        "includeFinalAssistant",
        where,
      ))
      Ok(MayFinish(include_final_assistant:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "need_assistant or may_finish",
        context: other,
      ))
  }
}

fn encode_generation_context(context: GenerationContext) -> JsonValue {
  json.Object([
    #("stepId", json.String(context.step_id)),
    #("triggerEntryId", encode_entry_id(context.trigger)),
    #("configuration", encode_configuration(context.configuration)),
    #("streamOptions", context.stream_options),
    #("retryPolicy", encode_retry(context.retry)),
    #("overflowRecoveryUsed", json.Bool(context.overflow_recovery_used)),
  ])
}

fn decode_generation_context(
  value: JsonValue,
) -> Result(GenerationContext, CorruptionReport) {
  let where = "machine/codec.generation_context"
  use fields <- result.try(fields_of(value, where))
  use step_id <- result.try(require_string(fields, "stepId", where))
  use trigger <- result.try(require_entry_id(fields, "triggerEntryId", where))
  use configuration_value <- result.try(require(fields, "configuration", where))
  use configuration <- result.try(decode_configuration(configuration_value))
  use stream_options <- result.try(require(fields, "streamOptions", where))
  use retry_value <- result.try(require(fields, "retryPolicy", where))
  use retry <- result.try(decode_retry(retry_value))
  use overflow_recovery_used <- result.try(require_bool(
    fields,
    "overflowRecoveryUsed",
    where,
  ))
  Ok(GenerationContext(
    step_id:,
    trigger:,
    configuration:,
    stream_options:,
    retry:,
    overflow_recovery_used:,
  ))
}

fn encode_generation(generation: Generation) -> JsonValue {
  case generation {
    GenerationReady(context:, next_attempt:) ->
      json.Object([
        #("status", json.String("ready")),
        #("context", encode_generation_context(context)),
        #("nextAttempt", json.Int(next_attempt)),
      ])
    GenerationEffectPending(
      context:,
      attempt:,
      response_entry:,
      usage:,
      intended_output_limit:,
      context_window:,
      request_api:,
    ) ->
      json.Object([
        #("status", json.String("effect_pending")),
        #("context", encode_generation_context(context)),
        #("attempt", json.Int(attempt)),
        #("responseEntryId", encode_entry_id(response_entry)),
        #("usageId", json.String(ids.usage_id_to_string(usage))),
        #("intendedOutputLimit", json.Int(intended_output_limit)),
        #("contextWindow", json.Int(context_window)),
        #("requestApi", json.String(request_api)),
      ])
    GenerationRetryWait(context:, next_attempt:, not_before:, error_message:) ->
      json.Object([
        #("status", json.String("retry_wait")),
        #("context", encode_generation_context(context)),
        #("nextAttempt", json.Int(next_attempt)),
        #("notBefore", json.Int(not_before)),
        #("errorMessage", json.String(error_message)),
      ])
  }
}

fn decode_generation(value: JsonValue) -> Result(Generation, CorruptionReport) {
  let where = "machine/codec.generation"
  use fields <- result.try(fields_of(value, where))
  use status <- result.try(require_string(fields, "status", where))
  use context_value <- result.try(require(fields, "context", where))
  use context <- result.try(decode_generation_context(context_value))
  case status {
    "ready" -> {
      use next_attempt <- result.try(require_int(fields, "nextAttempt", where))
      Ok(GenerationReady(context:, next_attempt:))
    }
    "effect_pending" -> {
      use attempt <- result.try(require_int(fields, "attempt", where))
      use response_entry <- result.try(require_entry_id(
        fields,
        "responseEntryId",
        where,
      ))
      use usage <- result.try(require_usage_id(fields, "usageId", where))
      use intended_output_limit <- result.try(require_int(
        fields,
        "intendedOutputLimit",
        where,
      ))
      use context_window <- result.try(require_int(
        fields,
        "contextWindow",
        where,
      ))
      use request_api <- result.try(require_string(fields, "requestApi", where))
      Ok(GenerationEffectPending(
        context:,
        attempt:,
        response_entry:,
        usage:,
        intended_output_limit:,
        context_window:,
        request_api:,
      ))
    }
    "retry_wait" -> {
      use next_attempt <- result.try(require_int(fields, "nextAttempt", where))
      use not_before <- result.try(require_int(fields, "notBefore", where))
      use error_message <- result.try(require_string(
        fields,
        "errorMessage",
        where,
      ))
      Ok(GenerationRetryWait(
        context:,
        next_attempt:,
        not_before:,
        error_message:,
      ))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "ready, effect_pending, or retry_wait",
        context: other,
      ))
  }
}

fn encode_batch(batch: ToolBatch) -> JsonValue {
  json.Object([
    #("assistantEntryId", encode_entry_id(batch.assistant_entry)),
    #("configuration", encode_configuration(batch.configuration)),
    #("turnId", json.String(batch.turn_id)),
    #("calls", json.Array(list.map(batch.calls, encode_call))),
  ])
}

fn decode_batch(value: JsonValue) -> Result(ToolBatch, CorruptionReport) {
  let where = "machine/codec.batch"
  use fields <- result.try(fields_of(value, where))
  use assistant_entry <- result.try(require_entry_id(
    fields,
    "assistantEntryId",
    where,
  ))
  use configuration_value <- result.try(require(fields, "configuration", where))
  use configuration <- result.try(decode_configuration(configuration_value))
  use turn_id <- result.try(require_string(fields, "turnId", where))
  use calls_value <- result.try(require_array(fields, "calls", where))
  use calls <- result.try(list.try_map(calls_value, decode_call))
  Ok(ToolBatch(assistant_entry:, configuration:, turn_id:, calls:))
}

fn encode_call(call: ToolCallState) -> JsonValue {
  case call {
    CallPlanned(source_index:, result_entry:) ->
      json.Object([
        #("status", json.String("planned")),
        #("sourceIndex", json.Int(source_index)),
        #("resultEntryId", encode_entry_id(result_entry)),
      ])
    CallEffectPending(source_index:, result_entry:, replay:) ->
      json.Object([
        #("status", json.String("effect_pending")),
        #("sourceIndex", json.Int(source_index)),
        #("resultEntryId", encode_entry_id(result_entry)),
        #("replay", case replay {
          ReplayNever -> json.String("never")
          ReplaySafe -> json.String("safe")
        }),
      ])
    CallOutcomeReady(source_index:, result_entry:, terminate:) ->
      json.Object([
        #("status", json.String("outcome_ready")),
        #("sourceIndex", json.Int(source_index)),
        #("resultEntryId", encode_entry_id(result_entry)),
        #("terminate", json.Bool(terminate)),
      ])
    CallCompleted(source_index:, result_entry:, terminate:) ->
      json.Object([
        #("status", json.String("completed")),
        #("sourceIndex", json.Int(source_index)),
        #("resultEntryId", encode_entry_id(result_entry)),
        #("terminate", json.Bool(terminate)),
      ])
  }
}

fn decode_call(value: JsonValue) -> Result(ToolCallState, CorruptionReport) {
  let where = "machine/codec.call"
  use fields <- result.try(fields_of(value, where))
  use status <- result.try(require_string(fields, "status", where))
  use source_index <- result.try(require_int(fields, "sourceIndex", where))
  use result_entry <- result.try(require_entry_id(
    fields,
    "resultEntryId",
    where,
  ))
  case status {
    "planned" -> Ok(CallPlanned(source_index:, result_entry:))
    "effect_pending" -> {
      use replay_text <- result.try(require_string(fields, "replay", where))
      use replay <- result.try(case replay_text {
        "never" -> Ok(ReplayNever)
        "safe" -> Ok(ReplaySafe)
        other ->
          Error(corruption.report(
            at: where,
            on: "replay",
            expected: "never or safe",
            context: other,
          ))
      })
      Ok(CallEffectPending(source_index:, result_entry:, replay:))
    }
    "outcome_ready" -> {
      use terminate <- result.try(require_bool(fields, "terminate", where))
      Ok(CallOutcomeReady(source_index:, result_entry:, terminate:))
    }
    "completed" -> {
      use terminate <- result.try(require_bool(fields, "terminate", where))
      Ok(CallCompleted(source_index:, result_entry:, terminate:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "a tool call status",
        context: other,
      ))
  }
}

fn encode_deferred(deferred: DeferredState) -> JsonValue {
  case deferred {
    DeferredSuspended(
      step_id:,
      source_entry:,
      poll:,
      configuration:,
      stream_options:,
    ) ->
      json.Object([
        #("status", json.String("suspended")),
        #("stepId", json.String(step_id)),
        #("sourceEntryId", encode_entry_id(source_entry)),
        #("poll", json.Int(poll)),
        #("configuration", encode_configuration(configuration)),
        #("streamOptions", stream_options),
      ])
    DeferredEffectPending(
      step_id:,
      source_entry:,
      poll:,
      response_entry:,
      usage:,
      configuration:,
      stream_options:,
    ) ->
      json.Object([
        #("status", json.String("effect_pending")),
        #("stepId", json.String(step_id)),
        #("sourceEntryId", encode_entry_id(source_entry)),
        #("poll", json.Int(poll)),
        #("responseEntryId", encode_entry_id(response_entry)),
        #("usageId", json.String(ids.usage_id_to_string(usage))),
        #("configuration", encode_configuration(configuration)),
        #("streamOptions", stream_options),
      ])
  }
}

fn decode_deferred(
  value: JsonValue,
) -> Result(DeferredState, CorruptionReport) {
  let where = "machine/codec.deferred"
  use fields <- result.try(fields_of(value, where))
  use status <- result.try(require_string(fields, "status", where))
  use step_id <- result.try(require_string(fields, "stepId", where))
  use source_entry <- result.try(require_entry_id(
    fields,
    "sourceEntryId",
    where,
  ))
  use poll <- result.try(require_int(fields, "poll", where))
  use configuration_value <- result.try(require(fields, "configuration", where))
  use configuration <- result.try(decode_configuration(configuration_value))
  use stream_options <- result.try(require(fields, "streamOptions", where))
  case status {
    "suspended" ->
      Ok(DeferredSuspended(
        step_id:,
        source_entry:,
        poll:,
        configuration:,
        stream_options:,
      ))
    "effect_pending" -> {
      use response_entry <- result.try(require_entry_id(
        fields,
        "responseEntryId",
        where,
      ))
      use usage <- result.try(require_usage_id(fields, "usageId", where))
      Ok(DeferredEffectPending(
        step_id:,
        source_entry:,
        poll:,
        response_entry:,
        usage:,
        configuration:,
        stream_options:,
      ))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "suspended or effect_pending",
        context: other,
      ))
  }
}

fn encode_summary_context(context: SummaryContext) -> JsonValue {
  json.Object([
    #("taskId", json.String(context.task_id)),
    #("resultEntryId", encode_entry_id(context.result_entry)),
    #("kind", case context.kind {
      CompactionSummary -> json.String("compaction")
      BranchSummary -> json.String("branch_summary")
    }),
    #("configuration", encode_configuration(context.configuration)),
    #("streamOptions", context.stream_options),
    #("retryPolicy", encode_retry(context.retry)),
    #("reason", case context.reason {
      ManualSummary -> json.String("manual")
      ThresholdSummary -> json.String("threshold")
      OverflowSummary -> json.String("overflow")
    }),
  ])
}

fn decode_summary_context(
  value: JsonValue,
) -> Result(SummaryContext, CorruptionReport) {
  let where = "machine/codec.summary_context"
  use fields <- result.try(fields_of(value, where))
  use task_id <- result.try(require_string(fields, "taskId", where))
  use result_entry <- result.try(require_entry_id(
    fields,
    "resultEntryId",
    where,
  ))
  use kind_text <- result.try(require_string(fields, "kind", where))
  use kind <- result.try(case kind_text {
    "compaction" -> Ok(CompactionSummary)
    "branch_summary" -> Ok(BranchSummary)
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "compaction or branch_summary",
        context: other,
      ))
  })
  use configuration_value <- result.try(require(fields, "configuration", where))
  use configuration <- result.try(decode_configuration(configuration_value))
  use stream_options <- result.try(require(fields, "streamOptions", where))
  use retry_value <- result.try(require(fields, "retryPolicy", where))
  use retry <- result.try(decode_retry(retry_value))
  use reason_text <- result.try(require_string(fields, "reason", where))
  use reason <- result.try(case reason_text {
    "manual" -> Ok(ManualSummary)
    "threshold" -> Ok(ThresholdSummary)
    "overflow" -> Ok(OverflowSummary)
    other ->
      Error(corruption.report(
        at: where,
        on: "reason",
        expected: "manual, threshold, or overflow",
        context: other,
      ))
  })
  Ok(SummaryContext(
    task_id:,
    result_entry:,
    kind:,
    configuration:,
    stream_options:,
    retry:,
    reason:,
  ))
}

fn encode_summary_generation(generation: SummaryGeneration) -> JsonValue {
  case generation {
    SummaryReady(context:, next_attempt:) ->
      json.Object([
        #("status", json.String("ready")),
        #("context", encode_summary_context(context)),
        #("nextAttempt", json.Int(next_attempt)),
      ])
    SummaryEffectPending(context:, attempt:, request:, usage_ids:) ->
      object_of([
        #("status", Some(json.String("effect_pending"))),
        #("context", Some(encode_summary_context(context))),
        #("attempt", Some(json.Int(attempt))),
        #(
          "request",
          option.map(request, fn(request) {
            json.Object([
              #("index", json.Int(request.index)),
              #("usageId", json.String(ids.usage_id_to_string(request.usage))),
            ])
          }),
        ),
        #(
          "usageIds",
          Some(
            json.Array(
              list.map(usage_ids, fn(id) {
                json.String(ids.usage_id_to_string(id))
              }),
            ),
          ),
        ),
      ])
    SummaryRetryWait(context:, next_attempt:, not_before:, error_message:) ->
      json.Object([
        #("status", json.String("retry_wait")),
        #("context", encode_summary_context(context)),
        #("nextAttempt", json.Int(next_attempt)),
        #("notBefore", json.Int(not_before)),
        #("errorMessage", json.String(error_message)),
      ])
  }
}

fn decode_summary_generation(
  value: JsonValue,
) -> Result(SummaryGeneration, CorruptionReport) {
  let where = "machine/codec.summary_generation"
  use fields <- result.try(fields_of(value, where))
  use status <- result.try(require_string(fields, "status", where))
  use context_value <- result.try(require(fields, "context", where))
  use context <- result.try(decode_summary_context(context_value))
  case status {
    "ready" -> {
      use next_attempt <- result.try(require_int(fields, "nextAttempt", where))
      Ok(SummaryReady(context:, next_attempt:))
    }
    "effect_pending" -> {
      use attempt <- result.try(require_int(fields, "attempt", where))
      use request <- result.try(case get(fields, "request") {
        Error(Nil) -> Ok(None)
        Ok(request_value) -> {
          use request_fields <- result.try(fields_of(request_value, where))
          use index <- result.try(require_int(request_fields, "index", where))
          use usage <- result.try(require_usage_id(
            request_fields,
            "usageId",
            where,
          ))
          Ok(Some(SummaryRequest(index:, usage:)))
        }
      })
      use usage_values <- result.try(require_array(fields, "usageIds", where))
      use usage_ids <- result.try(
        list.try_map(usage_values, fn(item) {
          use text <- result.try(as_string(item, where))
          ids.parse_usage_id(text)
        }),
      )
      Ok(SummaryEffectPending(context:, attempt:, request:, usage_ids:))
    }
    "retry_wait" -> {
      use next_attempt <- result.try(require_int(fields, "nextAttempt", where))
      use not_before <- result.try(require_int(fields, "notBefore", where))
      use error_message <- result.try(require_string(
        fields,
        "errorMessage",
        where,
      ))
      Ok(SummaryRetryWait(context:, next_attempt:, not_before:, error_message:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "ready, effect_pending, or retry_wait",
        context: other,
      ))
  }
}

fn encode_structural(structural: StructuralDecision) -> JsonValue {
  case structural {
    Deciding(task_id:) ->
      json.Object([
        #("taskId", json.String(task_id)),
        #("status", json.String("deciding")),
      ])
    Generating(task_id:, generation:) ->
      json.Object([
        #("taskId", json.String(task_id)),
        #("status", json.String("generating")),
        #("generation", encode_summary_generation(generation)),
      ])
  }
}

fn decode_structural(
  value: JsonValue,
) -> Result(StructuralDecision, CorruptionReport) {
  let where = "machine/codec.structural"
  use fields <- result.try(fields_of(value, where))
  use task_id <- result.try(require_string(fields, "taskId", where))
  use status <- result.try(require_string(fields, "status", where))
  case status {
    "deciding" -> Ok(Deciding(task_id:))
    "generating" -> {
      use generation_value <- result.try(require(fields, "generation", where))
      use generation <- result.try(decode_summary_generation(generation_value))
      Ok(Generating(task_id:, generation:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "deciding or generating",
        context: other,
      ))
  }
}

fn encode_navigation(navigation: Navigation) -> JsonValue {
  case navigation {
    UnsummarizedNavigation(target:, label:) ->
      object_of([
        #("summarize", Some(json.Bool(False))),
        #("targetId", Some(encode_optional_entry_id(target))),
        #("label", option.map(label, json.String)),
      ])
    SummarizedNavigation(target:, label:, custom_instructions:, structural:) ->
      object_of([
        #("summarize", Some(json.Bool(True))),
        #("targetId", Some(encode_entry_id(target))),
        #("label", option.map(label, json.String)),
        #("customInstructions", option.map(custom_instructions, json.String)),
        #("structural", Some(encode_structural(structural))),
      ])
  }
}

fn decode_navigation(value: JsonValue) -> Result(Navigation, CorruptionReport) {
  let where = "machine/codec.navigation"
  use fields <- result.try(fields_of(value, where))
  use summarize <- result.try(require_bool(fields, "summarize", where))
  use label <- result.try(optional_string(fields, "label", where))
  case summarize {
    False -> {
      use target_value <- result.try(require(fields, "targetId", where))
      use target <- result.try(decode_optional_entry_id(target_value, where))
      Ok(UnsummarizedNavigation(target:, label:))
    }
    True -> {
      use target <- result.try(require_entry_id(fields, "targetId", where))
      use custom_instructions <- result.try(optional_string(
        fields,
        "customInstructions",
        where,
      ))
      use structural_value <- result.try(require(fields, "structural", where))
      use structural <- result.try(decode_structural(structural_value))
      Ok(SummarizedNavigation(
        target:,
        label:,
        custom_instructions:,
        structural:,
      ))
    }
  }
}

// --- terminal results -----------------------------------------------------

/// Encodes a `LastResult` (the `strand.last_result` payload).
pub fn encode_last_result(result: LastResult) -> JsonValue {
  case result {
    RunLastResult(operation:, leaf:, outcome:, final_assistant:) -> {
      let #(outcome_text, error, completion) = case outcome {
        RunCompleted(completion: CompletedByAssistant) -> #(
          "completed",
          None,
          Some("assistant"),
        )
        RunCompleted(completion: CompletedByTerminatedTools) -> #(
          "completed",
          None,
          Some("terminated_tools"),
        )
        RunFailed(error:) -> #("failed", Some(error), None)
        RunAborted -> #("aborted", None, None)
      }
      object_of([
        #("kind", Some(json.String("run"))),
        #("operationId", Some(json.String(ids.op_id_to_string(operation)))),
        #("leafId", Some(encode_optional_entry_id(leaf))),
        #("outcome", Some(json.String(outcome_text))),
        #("error", option.map(error, encode_operation_error)),
        #("runCompletion", option.map(completion, json.String)),
        #("finalAssistantEntryId", option.map(final_assistant, encode_entry_id)),
      ])
    }
    CompactionLastResult(operation:, leaf:, outcome:) -> {
      let #(outcome_text, error) = encode_structural_outcome(outcome)
      object_of([
        #("kind", Some(json.String("compaction"))),
        #("operationId", Some(json.String(ids.op_id_to_string(operation)))),
        #("leafId", Some(encode_optional_entry_id(leaf))),
        #("outcome", Some(json.String(outcome_text))),
        #("error", option.map(error, encode_operation_error)),
      ])
    }
    NavigationLastResult(operation:, leaf:, old_leaf:, outcome:, summary:) -> {
      let #(outcome_text, error) = encode_structural_outcome(outcome)
      object_of([
        #("kind", Some(json.String("navigation"))),
        #("operationId", Some(json.String(ids.op_id_to_string(operation)))),
        #("leafId", Some(encode_optional_entry_id(leaf))),
        #("oldLeafId", Some(encode_optional_entry_id(old_leaf))),
        #("outcome", Some(json.String(outcome_text))),
        #("error", option.map(error, encode_operation_error)),
        #("summaryEntryId", option.map(summary, encode_entry_id)),
      ])
    }
  }
}

fn encode_structural_outcome(
  outcome: StructuralOutcome,
) -> #(String, Option(OperationError)) {
  case outcome {
    StructuralCompleted -> #("completed", None)
    StructuralDeclined -> #("declined", None)
    StructuralFailed(error:) -> #("failed", Some(error))
    StructuralAborted -> #("aborted", None)
  }
}

/// Decodes a `LastResult`. Total.
pub fn decode_last_result(
  value: JsonValue,
) -> Result(LastResult, CorruptionReport) {
  let where = "machine/codec.last_result"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  use id_text <- result.try(require_string(fields, "operationId", where))
  use operation <- result.try(ids.parse_op_id(id_text))
  use leaf_value <- result.try(require(fields, "leafId", where))
  use leaf <- result.try(decode_optional_entry_id(leaf_value, where))
  use outcome_text <- result.try(require_string(fields, "outcome", where))
  use error <- result.try(case get(fields, "error") {
    Error(Nil) -> Ok(None)
    Ok(error_value) -> result.map(decode_operation_error(error_value), Some)
  })
  case kind {
    "run" -> {
      use final_assistant <- result.try(optional_entry_id(
        fields,
        "finalAssistantEntryId",
        where,
      ))
      use completion <- result.try(optional_string(
        fields,
        "runCompletion",
        where,
      ))
      use outcome <- result.try(case outcome_text, error, completion {
        "completed", None, Some("assistant") ->
          Ok(RunCompleted(completion: CompletedByAssistant))
        "completed", None, Some("terminated_tools") ->
          Ok(RunCompleted(completion: CompletedByTerminatedTools))
        "failed", Some(error), None -> Ok(RunFailed(error:))
        "aborted", None, None -> Ok(RunAborted)
        _, _, _ ->
          Error(corruption.report(
            at: where,
            on: "run outcome",
            expected: "a coherent outcome/error/runCompletion triple",
            context: outcome_text,
          ))
      })
      Ok(RunLastResult(operation:, leaf:, outcome:, final_assistant:))
    }
    "compaction" -> {
      use outcome <- result.try(decode_structural_outcome(
        outcome_text,
        error,
        where,
      ))
      Ok(CompactionLastResult(operation:, leaf:, outcome:))
    }
    "navigation" -> {
      use old_leaf_value <- result.try(require(fields, "oldLeafId", where))
      use old_leaf <- result.try(decode_optional_entry_id(old_leaf_value, where))
      use summary <- result.try(optional_entry_id(
        fields,
        "summaryEntryId",
        where,
      ))
      use outcome <- result.try(decode_structural_outcome(
        outcome_text,
        error,
        where,
      ))
      Ok(NavigationLastResult(operation:, leaf:, old_leaf:, outcome:, summary:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "run, compaction, or navigation",
        context: other,
      ))
  }
}

fn decode_structural_outcome(
  outcome_text: String,
  error: Option(OperationError),
  where: String,
) -> Result(StructuralOutcome, CorruptionReport) {
  case outcome_text, error {
    "completed", None -> Ok(StructuralCompleted)
    "declined", None -> Ok(StructuralDeclined)
    "failed", Some(error) -> Ok(StructuralFailed(error:))
    "aborted", None -> Ok(StructuralAborted)
    _, _ ->
      Error(corruption.report(
        at: where,
        on: "outcome",
        expected: "a coherent outcome/error pair",
        context: outcome_text,
      ))
  }
}

// --- pending entries ------------------------------------------------------

/// Encodes a `PendingEntry` (the `pending.entry/{id}` payload).
pub fn encode_pending_entry(pending: PendingEntry) -> JsonValue {
  case pending {
    PendingMessage(message:) ->
      json.Object([
        #("type", json.String("message")),
        #("payload", core_codec.encode_message(message)),
      ])
    PendingCustom(custom_type:, data:) ->
      object_of([
        #("type", Some(json.String("custom"))),
        #("customType", Some(json.String(custom_type))),
        #("data", data |> option.map(fn(data) { data })),
      ])
  }
}

/// Decodes a `PendingEntry`. Total.
pub fn decode_pending_entry(
  value: JsonValue,
) -> Result(PendingEntry, CorruptionReport) {
  let where = "machine/codec.pending_entry"
  use fields <- result.try(fields_of(value, where))
  use entry_type <- result.try(require_string(fields, "type", where))
  case entry_type {
    "message" -> {
      use payload <- result.try(require(fields, "payload", where))
      use message <- result.try(core_codec.decode_message(payload))
      Ok(PendingMessage(message:))
    }
    "custom" -> {
      use custom_type <- result.try(require_string(fields, "customType", where))
      let data = optional_json(fields, "data")
      Ok(PendingCustom(custom_type:, data:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "type",
        expected: "message or custom",
        context: other,
      ))
  }
}

// --- structural preparation -----------------------------------------------

/// Encodes a `StructuralPreparation` (the write-once `op.preparation`
/// payload).
pub fn encode_preparation(preparation: StructuralPreparation) -> JsonValue {
  case preparation {
    CompactionPreparation(
      messages_to_summarize:,
      turn_prefix_messages:,
      retained_tail:,
      is_split_turn:,
      tokens_before:,
      previous_summary:,
      file_ops:,
      settings:,
    ) ->
      object_of([
        #("kind", Some(json.String("compaction"))),
        #("messagesToSummarize", Some(encode_messages(messages_to_summarize))),
        #("turnPrefixMessages", Some(encode_messages(turn_prefix_messages))),
        #("retainedTail", Some(encode_messages(retained_tail))),
        #("isSplitTurn", Some(json.Bool(is_split_turn))),
        #("tokensBefore", Some(json.Int(tokens_before))),
        #("previousSummary", option.map(previous_summary, json.String)),
        #("fileOps", Some(encode_file_ops(file_ops))),
        #("settings", Some(encode_compaction_settings(settings))),
      ])
    BranchSummaryPreparation(messages:, file_ops:, total_tokens:) ->
      json.Object([
        #("kind", json.String("branch_summary")),
        #("messages", encode_messages(messages)),
        #("fileOps", encode_file_ops(file_ops)),
        #("totalTokens", json.Int(total_tokens)),
      ])
  }
}

/// Decodes a `StructuralPreparation`. Total.
pub fn decode_preparation(
  value: JsonValue,
) -> Result(StructuralPreparation, CorruptionReport) {
  let where = "machine/codec.preparation"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "kind", where))
  case kind {
    "compaction" -> {
      use summarize_value <- result.try(require_array(
        fields,
        "messagesToSummarize",
        where,
      ))
      use messages_to_summarize <- result.try(list.try_map(
        summarize_value,
        core_codec.decode_message,
      ))
      use prefix_value <- result.try(require_array(
        fields,
        "turnPrefixMessages",
        where,
      ))
      use turn_prefix_messages <- result.try(list.try_map(
        prefix_value,
        core_codec.decode_message,
      ))
      use tail_value <- result.try(require_array(fields, "retainedTail", where))
      use retained_tail <- result.try(list.try_map(
        tail_value,
        core_codec.decode_message,
      ))
      use is_split_turn <- result.try(require_bool(fields, "isSplitTurn", where))
      use tokens_before <- result.try(require_int(fields, "tokensBefore", where))
      use previous_summary <- result.try(optional_string(
        fields,
        "previousSummary",
        where,
      ))
      use file_ops_value <- result.try(require(fields, "fileOps", where))
      use file_ops <- result.try(decode_file_ops(file_ops_value))
      use settings_value <- result.try(require(fields, "settings", where))
      use settings <- result.try(decode_compaction_settings(settings_value))
      Ok(CompactionPreparation(
        messages_to_summarize:,
        turn_prefix_messages:,
        retained_tail:,
        is_split_turn:,
        tokens_before:,
        previous_summary:,
        file_ops:,
        settings:,
      ))
    }
    "branch_summary" -> {
      use messages_value <- result.try(require_array(fields, "messages", where))
      use messages <- result.try(list.try_map(
        messages_value,
        core_codec.decode_message,
      ))
      use file_ops_value <- result.try(require(fields, "fileOps", where))
      use file_ops <- result.try(decode_file_ops(file_ops_value))
      use total_tokens <- result.try(require_int(fields, "totalTokens", where))
      Ok(BranchSummaryPreparation(messages:, file_ops:, total_tokens:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "compaction or branch_summary",
        context: other,
      ))
  }
}

fn encode_messages(messages: List(AgentMessage)) -> JsonValue {
  json.Array(list.map(messages, core_codec.encode_message))
}

fn encode_file_ops(file_ops: FileOperations) -> JsonValue {
  json.Object([
    #("read", json.Array(list.map(file_ops.read, json.String))),
    #("written", json.Array(list.map(file_ops.written, json.String))),
    #("edited", json.Array(list.map(file_ops.edited, json.String))),
  ])
}

fn decode_file_ops(
  value: JsonValue,
) -> Result(FileOperations, CorruptionReport) {
  let where = "machine/codec.file_ops"
  use fields <- result.try(fields_of(value, where))
  use read_value <- result.try(require_array(fields, "read", where))
  use read <- result.try(
    list.try_map(read_value, fn(item) { as_string(item, where) }),
  )
  use written_value <- result.try(require_array(fields, "written", where))
  use written <- result.try(
    list.try_map(written_value, fn(item) { as_string(item, where) }),
  )
  use edited_value <- result.try(require_array(fields, "edited", where))
  use edited <- result.try(
    list.try_map(edited_value, fn(item) { as_string(item, where) }),
  )
  Ok(FileOperations(read:, written:, edited:))
}

// --- shared helpers -------------------------------------------------------

type Fields =
  List(#(String, JsonValue))

/// Builds an object keeping only the `Some` fields — the encoder-side half
/// of the module doc's absent-vs-null distinction. The `Option` here is
/// about the *field*, not the payload: `None` omits it from the wire
/// entirely, while `Some(json.Null)` still writes a literal `null`. This
/// is how opaque fields typed `Option(JsonValue)` (`details`, `data`) tell
/// "the caller supplied no value" apart from "the caller supplied JSON
/// null" — `option.map(identity)` over the stored option preserves that
/// distinction through to the wire.
fn object_of(pairs: List(#(String, Option(JsonValue)))) -> JsonValue {
  json.Object(
    list.filter_map(pairs, fn(pair) {
      case pair {
        #(name, Some(value)) -> Ok(#(name, value))
        #(_, None) -> Error(Nil)
      }
    }),
  )
}

fn fields_of(
  value: JsonValue,
  where: String,
) -> Result(Fields, CorruptionReport) {
  case value {
    json.Object(fields:) -> Ok(fields)
    other ->
      Error(corruption.report(
        at: where,
        on: "value",
        expected: "a json object",
        context: json.to_string(other),
      ))
  }
}

fn get(fields: Fields, name: String) -> Result(JsonValue, Nil) {
  list.find_map(fields, fn(field) {
    case field {
      #(field_name, value) if field_name == name -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

fn require(
  fields: Fields,
  name: String,
  where: String,
) -> Result(JsonValue, CorruptionReport) {
  case get(fields, name) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a present field",
        context: "absent",
      ))
  }
}

fn optional_json(fields: Fields, name: String) -> Option(JsonValue) {
  case get(fields, name) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn as_string(
  value: JsonValue,
  where: String,
) -> Result(String, CorruptionReport) {
  case value {
    json.String(value:) -> Ok(value)
    other ->
      Error(corruption.report(
        at: where,
        on: "value",
        expected: "a string",
        context: json.to_string(other),
      ))
  }
}

fn require_string(
  fields: Fields,
  name: String,
  where: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.String(value:) -> Ok(value)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a string",
        context: json.to_string(other),
      ))
  }
}

fn optional_string(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Option(String), CorruptionReport) {
  case get(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.String(value:)) -> Ok(Some(value))
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a string or null",
        context: json.to_string(other),
      ))
  }
}

fn require_int(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.Int(value:) -> Ok(value)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

fn require_bool(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Bool, CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.Bool(value:) -> Ok(value)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a boolean",
        context: json.to_string(other),
      ))
  }
}

fn require_array(
  fields: Fields,
  name: String,
  where: String,
) -> Result(List(JsonValue), CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.Array(items:) -> Ok(items)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an array",
        context: json.to_string(other),
      ))
  }
}

fn encode_entry_id(id: EntryId) -> JsonValue {
  json.String(ids.entry_id_to_string(id))
}

fn encode_optional_entry_id(id: Option(EntryId)) -> JsonValue {
  case id {
    Some(id) -> encode_entry_id(id)
    None -> json.Null
  }
}

fn decode_entry_id_value(
  value: JsonValue,
) -> Result(EntryId, CorruptionReport) {
  let where = "machine/codec.entry_id"
  use text <- result.try(as_string(value, where))
  ids.parse_entry_id(text)
}

fn decode_optional_entry_id(
  value: JsonValue,
  where: String,
) -> Result(Option(EntryId), CorruptionReport) {
  case value {
    json.Null -> Ok(None)
    json.String(text) -> result.map(ids.parse_entry_id(text), Some)
    other ->
      Error(corruption.report(
        at: where,
        on: "entry id",
        expected: "null or an entry id string",
        context: json.to_string(other),
      ))
  }
}

fn require_entry_id(
  fields: Fields,
  name: String,
  where: String,
) -> Result(EntryId, CorruptionReport) {
  use text <- result.try(require_string(fields, name, where))
  ids.parse_entry_id(text)
}

fn optional_entry_id(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Option(EntryId), CorruptionReport) {
  case get(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) -> result.map(ids.parse_entry_id(text), Some)
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an entry id string or null",
        context: json.to_string(other),
      ))
  }
}

fn require_usage_id(
  fields: Fields,
  name: String,
  where: String,
) -> Result(UsageId, CorruptionReport) {
  use text <- result.try(require_string(fields, name, where))
  ids.parse_usage_id(text)
}
