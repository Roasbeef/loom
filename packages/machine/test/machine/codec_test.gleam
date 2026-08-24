//// Codec roundtrips for every register payload type, including a state
//// list that touches every `OperationState` constructor (the WP-D
//// constructor-coverage exit criterion), plus adversarial decodes.

import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation.{
  type OperationState, Assistant, AwaitingDeferred, BranchSummary,
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
  PendingCustom, PendingMessage, ReplayNever, ReplaySafe, ResponseProvenance,
  RunAborted, RunCompleted, RunFailed, RunIntent, RunLastResult, RunSettings,
  RunState, Running, Sequential, Starting, StructuralAborted,
  StructuralCompleted, StructuralDeclined, StructuralFailed,
  StructuralProvenance, SummarizedNavigation, SummaryContext,
  SummaryEffectPending, SummaryReady, SummaryRequest, SummaryRetryWait,
  ThresholdReason, ThresholdSummary, ToolBatch, Tools, UnsummarizedNavigation,
}
import machine/strand.{
  ModelIdentity, StrandConfiguration, StrandState, ThinkingHigh, ThinkingLow,
  ThinkingMax, ThinkingMedium, ThinkingMinimal, ThinkingOff, ThinkingXHigh,
}
import support/fixture

fn entry_id(n: Int) -> ids.EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000 + n), seed: n))
  id
}

fn usage_id(n: Int) -> ids.UsageId {
  let #(id, _generator) =
    ids.mint_usage(ids.generator(clock.fixed(at: 2000 + n), seed: n))
  id
}

fn op_id(n: Int) -> ids.OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 3000 + n), seed: n))
  id
}

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingMedium,
    active_tool_names: ["bash", "read"],
  )
}

fn settings() -> operation.RunSettings {
  RunSettings(
    compaction: CompactionSettings(
      enabled: True,
      reserve_tokens: 1,
      keep_recent_tokens: 2,
    ),
    steering_mode: ConsumeAll,
    follow_up_mode: OneAtATime,
    tool_execution: Sequential,
  )
}

fn generation_context() -> operation.GenerationContext {
  GenerationContext(
    step_id: "step-1",
    trigger: entry_id(1),
    configuration: configuration(),
    stream_options: json.Object([#("deferred", json.Bool(False))]),
    retry: NormalizedRetryPolicy(max_attempts: 3, base_delay_ms: 250),
    overflow_recovery_used: True,
  )
}

fn summary_context() -> operation.SummaryContext {
  SummaryContext(
    task_id: "task-1",
    result_entry: entry_id(2),
    kind: CompactionSummary,
    configuration: configuration(),
    stream_options: json.Object([]),
    retry: NormalizedRetryPolicy(max_attempts: 2, base_delay_ms: 100),
    reason: OverflowSummary,
  )
}

fn checkpoint() -> operation.CheckpointPhase {
  CheckpointPhase(
    continuation: NeedAssistant(overflow_recovery_used: False),
    trigger: entry_id(3),
    threshold_checked: Some(entry_id(3)),
    skip_inbox_once: True,
  )
}

fn run(phase: operation.RunPhase) -> OperationState {
  RunState(
    control: Running,
    settings: settings(),
    phase:,
    inbox: Inbox(steer: [entry_id(10)], follow_up: [], writes: [entry_id(11)]),
    latest_assistant: Some(entry_id(12)),
  )
}

/// Every `OperationState` constructor — and every constructor of every
/// nested phase type — appears at least once in this list.
fn all_states() -> List(OperationState) {
  [
    run(Starting),
    run(Checkpoint(checkpoint: checkpoint())),
    run(
      Checkpoint(checkpoint: CheckpointPhase(
        continuation: MayFinish(include_final_assistant: True),
        trigger: entry_id(4),
        threshold_checked: None,
        skip_inbox_once: False,
      )),
    ),
    run(
      Assistant(generation: GenerationReady(
        context: generation_context(),
        next_attempt: 1,
      )),
    ),
    run(
      Assistant(generation: GenerationEffectPending(
        context: generation_context(),
        attempt: 2,
        response_entry: entry_id(5),
        usage: usage_id(1),
        intended_output_limit: 4096,
        context_window: 200_000,
      )),
    ),
    run(
      Assistant(generation: GenerationRetryWait(
        context: generation_context(),
        next_attempt: 3,
        not_before: 99,
        error_message: "overloaded",
      )),
    ),
    run(
      Tools(
        batch: ToolBatch(
          assistant_entry: entry_id(6),
          configuration: configuration(),
          turn_id: "step-2",
          calls: [
            CallCompleted(
              source_index: 0,
              result_entry: entry_id(7),
              terminate: False,
            ),
            CallOutcomeReady(
              source_index: 1,
              result_entry: entry_id(8),
              terminate: True,
            ),
            CallEffectPending(
              source_index: 2,
              result_entry: entry_id(9),
              replay: ReplayNever,
            ),
            CallEffectPending(
              source_index: 3,
              result_entry: entry_id(13),
              replay: ReplaySafe,
            ),
            CallPlanned(source_index: 4, result_entry: entry_id(14)),
          ],
        ),
      ),
    ),
    run(Compacting(
      reason: ThresholdReason,
      structural: Deciding(task_id: "task-1"),
      resume_after: checkpoint(),
    )),
    run(Compacting(
      reason: OverflowReason,
      structural: Generating(
        task_id: "task-1",
        generation: SummaryReady(context: summary_context(), next_attempt: 1),
      ),
      resume_after: checkpoint(),
    )),
    run(Compacting(
      reason: OverflowReason,
      structural: Generating(
        task_id: "task-1",
        generation: SummaryEffectPending(
          context: summary_context(),
          attempt: 1,
          request: Some(SummaryRequest(index: 0, usage: usage_id(2))),
          usage_ids: [usage_id(3)],
        ),
      ),
      resume_after: checkpoint(),
    )),
    run(Compacting(
      reason: ThresholdReason,
      structural: Generating(
        task_id: "task-1",
        generation: SummaryEffectPending(
          context: summary_context(),
          attempt: 2,
          request: None,
          usage_ids: [],
        ),
      ),
      resume_after: checkpoint(),
    )),
    run(Compacting(
      reason: ThresholdReason,
      structural: Generating(
        task_id: "task-1",
        generation: SummaryRetryWait(
          context: summary_context(),
          next_attempt: 2,
          not_before: 500,
          error_message: "retryable",
        ),
      ),
      resume_after: checkpoint(),
    )),
    run(
      AwaitingDeferred(deferred: DeferredSuspended(
        step_id: "step-3",
        source_entry: entry_id(15),
        poll: 2,
        configuration: configuration(),
        stream_options: json.Null,
      )),
    ),
    run(
      AwaitingDeferred(deferred: DeferredEffectPending(
        step_id: "step-3",
        source_entry: entry_id(15),
        poll: 3,
        response_entry: entry_id(16),
        usage: usage_id(4),
        configuration: configuration(),
        stream_options: json.Null,
      )),
    ),
    run(FailureDrain(
      error: OperationError(
        code: "provider_error",
        message: "boom",
        details: None,
      ),
      provenance: ResponseProvenance(entry: entry_id(17)),
    )),
    run(FailureDrain(
      error: OperationError(
        code: "context_overflow",
        message: "overflow",
        details: Some(json.Int(1)),
      ),
      provenance: StructuralProvenance(task_id: "task-9"),
    )),
    run(FailureDrain(
      error: OperationError(
        code: "model_unavailable",
        message: "gone",
        details: None,
      ),
      provenance: ConfigurationProvenance,
    )),
    RunState(
      control: CancelRequested(
        requested_at: 42,
        drained_steer: [entry_id(18)],
        drained_follow_up: [entry_id(19)],
      ),
      settings: settings(),
      phase: Starting,
      inbox: Inbox(steer: [], follow_up: [], writes: []),
      latest_assistant: None,
    ),
    CompactionState(
      control: Running,
      custom_instructions: Some("focus on decisions"),
      structural: Deciding(task_id: "task-2"),
    ),
    CompactionState(
      control: CancelRequested(
        requested_at: 7,
        drained_steer: [],
        drained_follow_up: [],
      ),
      custom_instructions: None,
      structural: Generating(
        task_id: "task-2",
        generation: SummaryReady(context: summary_context(), next_attempt: 1),
      ),
    ),
    NavigationState(
      control: Running,
      navigation: UnsummarizedNavigation(target: None, label: None),
    ),
    NavigationState(
      control: Running,
      navigation: UnsummarizedNavigation(
        target: Some(entry_id(20)),
        label: Some("fork point"),
      ),
    ),
    NavigationState(
      control: Running,
      navigation: SummarizedNavigation(
        target: entry_id(21),
        label: None,
        custom_instructions: Some("short"),
        structural: Deciding(task_id: "task-3"),
      ),
    ),
    NavigationState(
      control: Running,
      navigation: SummarizedNavigation(
        target: entry_id(22),
        label: Some("kept"),
        custom_instructions: None,
        structural: Generating(
          task_id: "task-4",
          generation: SummaryReady(
            context: SummaryContext(
              task_id: "task-4",
              result_entry: entry_id(23),
              kind: BranchSummary,
              configuration: configuration(),
              stream_options: json.Null,
              retry: NormalizedRetryPolicy(max_attempts: 1, base_delay_ms: 0),
              reason: ManualSummary,
            ),
            next_attempt: 1,
          ),
        ),
      ),
    ),
    run(Compacting(
      reason: ThresholdReason,
      structural: Generating(
        task_id: "task-5",
        generation: SummaryReady(
          context: SummaryContext(
            task_id: "task-5",
            result_entry: entry_id(24),
            kind: CompactionSummary,
            configuration: configuration(),
            stream_options: json.Null,
            retry: NormalizedRetryPolicy(max_attempts: 2, base_delay_ms: 10),
            reason: ThresholdSummary,
          ),
          next_attempt: 1,
        ),
      ),
      resume_after: checkpoint(),
    )),
  ]
}

pub fn state_constructor_coverage_roundtrip_test() {
  list.each(all_states(), fn(state) {
    assert codec.decode_state(codec.encode_state(state)) == Ok(state)
  })
}

pub fn configuration_roundtrip_all_thinking_levels_test() {
  list.each(
    [
      ThinkingOff, ThinkingMinimal, ThinkingLow, ThinkingMedium, ThinkingHigh,
      ThinkingXHigh, ThinkingMax,
    ],
    fn(level) {
      let configuration =
        StrandConfiguration(
          model: ModelIdentity(provider: "p", model_id: "m"),
          thinking_level: level,
          active_tool_names: [],
        )
      assert codec.decode_configuration(codec.encode_configuration(
          configuration,
        ))
        == Ok(configuration)
    },
  )
}

pub fn strand_state_roundtrip_test() {
  let states = [
    StrandState(current_operation: None, pending_next_run: []),
    StrandState(current_operation: Some(op_id(1)), pending_next_run: [
      entry_id(1),
      entry_id(2),
    ]),
  ]
  list.each(states, fn(state) {
    assert codec.decode_strand_state(codec.encode_strand_state(state))
      == Ok(state)
  })
}

pub fn operation_roundtrip_test() {
  let operations = [
    Operation(
      id: op_id(2),
      strand: "main",
      source_leaf: Some(entry_id(1)),
      started_at: 5,
      intent: RunIntent(prompt_entries: [entry_id(2)]),
    ),
    Operation(
      id: op_id(3),
      strand: "sub:1",
      source_leaf: None,
      started_at: 6,
      intent: CompactionIntent(custom_instructions: Some("shorter")),
    ),
    Operation(
      id: op_id(4),
      strand: "main",
      source_leaf: Some(entry_id(3)),
      started_at: 7,
      intent: NavigationIntent(
        target: Some(entry_id(4)),
        summarize: True,
        label: Some("branch"),
        custom_instructions: None,
      ),
    ),
    Operation(
      id: op_id(5),
      strand: "main",
      source_leaf: None,
      started_at: 8,
      intent: NavigationIntent(
        target: None,
        summarize: False,
        label: None,
        custom_instructions: None,
      ),
    ),
  ]
  list.each(operations, fn(operation) {
    assert codec.decode_operation(codec.encode_operation(operation))
      == Ok(operation)
  })
}

pub fn last_result_roundtrip_test() {
  let results = [
    RunLastResult(
      operation: op_id(6),
      leaf: Some(entry_id(5)),
      outcome: RunCompleted(completion: CompletedByAssistant),
      final_assistant: Some(entry_id(5)),
    ),
    RunLastResult(
      operation: op_id(6),
      leaf: Some(entry_id(5)),
      outcome: RunCompleted(completion: CompletedByTerminatedTools),
      final_assistant: None,
    ),
    RunLastResult(
      operation: op_id(6),
      leaf: None,
      outcome: RunFailed(error: OperationError(
        code: "provider_error",
        message: "x",
        details: None,
      )),
      final_assistant: None,
    ),
    RunLastResult(
      operation: op_id(6),
      leaf: Some(entry_id(6)),
      outcome: RunAborted,
      final_assistant: Some(entry_id(6)),
    ),
    CompactionLastResult(
      operation: op_id(7),
      leaf: Some(entry_id(7)),
      outcome: StructuralCompleted,
    ),
    CompactionLastResult(
      operation: op_id(7),
      leaf: None,
      outcome: StructuralDeclined,
    ),
    CompactionLastResult(
      operation: op_id(7),
      leaf: None,
      outcome: StructuralFailed(error: OperationError(
        code: "model_unavailable",
        message: "y",
        details: None,
      )),
    ),
    NavigationLastResult(
      operation: op_id(8),
      leaf: Some(entry_id(8)),
      old_leaf: Some(entry_id(9)),
      outcome: StructuralCompleted,
      summary: Some(entry_id(8)),
    ),
    NavigationLastResult(
      operation: op_id(8),
      leaf: None,
      old_leaf: None,
      outcome: StructuralAborted,
      summary: None,
    ),
  ]
  list.each(results, fn(result) {
    assert codec.decode_last_result(codec.encode_last_result(result))
      == Ok(result)
  })
}

pub fn pending_entry_roundtrip_test() {
  let pendings = [
    PendingMessage(message: fixture.user("hello")),
    PendingMessage(message: fixture.assistant_calls(["bash"])),
    PendingCustom(custom_type: "note", data: Some(json.Object([]))),
    PendingCustom(custom_type: "marker", data: None),
  ]
  list.each(pendings, fn(pending) {
    assert codec.decode_pending_entry(codec.encode_pending_entry(pending))
      == Ok(pending)
  })
}

pub fn preparation_roundtrip_test() {
  let preparations = [
    fixture.preparation(),
    CompactionPreparation(
      messages_to_summarize: [],
      turn_prefix_messages: [fixture.user("prefix")],
      retained_tail: [],
      is_split_turn: True,
      tokens_before: 0,
      previous_summary: Some("previous"),
      file_ops: FileOperations(read: [], written: ["b"], edited: ["c"]),
      settings: CompactionSettings(
        enabled: False,
        reserve_tokens: 0,
        keep_recent_tokens: 0,
      ),
    ),
    BranchSummaryPreparation(
      messages: [fixture.user("m")],
      file_ops: FileOperations(read: [], written: [], edited: []),
      total_tokens: 12,
    ),
  ]
  list.each(preparations, fn(preparation) {
    assert codec.decode_preparation(codec.encode_preparation(preparation))
      == Ok(preparation)
  })
}

// --- adversarial decodes --------------------------------------------------

const junk = [
  json.Null,
  json.Bool(True),
  json.Int(7),
  json.Float(1.5),
  json.String("run"),
  json.Array([json.Int(1)]),
  json.Object([]),
  json.Object([#("kind", json.String("nonsense"))]),
  json.Object([#("kind", json.Int(3))]),
  json.Object([#("kind", json.String("run")), #("control", json.Null)]),
]

pub fn decode_state_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_state(value)
  })
}

pub fn decode_operation_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_operation(value)
  })
}

pub fn decode_last_result_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_last_result(value)
  })
}

pub fn decode_pending_entry_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_pending_entry(value)
  })
}

pub fn decode_preparation_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_preparation(value)
  })
}

pub fn decode_configuration_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_configuration(value)
  })
}

pub fn decode_strand_state_adversarial_test() {
  list.each(junk, fn(value) {
    let assert Error(_report) = codec.decode_strand_state(value)
  })
}

pub fn decode_state_bad_entry_id_test() {
  // A structurally plausible run state whose id strings are not uuids.
  let encoded = codec.encode_state(run(Checkpoint(checkpoint: checkpoint())))
  let assert Error(_report) = codec.decode_state(replace_uuid_strings(encoded))
}

// Replaces every string leaf that looks like a uuid with junk.
fn replace_uuid_strings(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.Object(fields:) ->
      json.Object(
        list.map(fields, fn(field) {
          let #(name, field_value) = field
          #(name, replace_uuid_strings(field_value))
        }),
      )
    json.Array(items:) -> json.Array(list.map(items, replace_uuid_strings))
    json.String(text) ->
      case string.length(text) == 36 {
        True -> json.String("not-a-uuid")
        False -> json.String(text)
      }
    other -> other
  }
}
