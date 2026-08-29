//// Scripted fake effects for the runtime tests.
////
//// Effects are keyed deterministically so replay and synthetic rules
//// apply across crashes: the provider script is keyed by the *projected
//// conversation* (which assistant turn is being generated, derived from
//// the request context) and the attempt number — never by minted ids,
//// which differ across runs. Tool scripts are keyed by tool name and the
//// scripted call id. Invocations are counted in the recorder, which
//// outlives the tree.

import core/clock.{type Clock}
import core/json as core_json
import core/message.{
  type AgentMessage, AssistantMessage, AssistantText, AssistantToolCall,
  ToolCall, ToolResultMessage, ToolResultText, UserMessage, UserText,
}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import machine/operation.{type ReplayPolicy}
import provider/stream
import runtime/effects.{type Effects}
import support/recorder

/// What one scripted provider request does.
pub type ProviderResult {
  /// Settle with this (already settled) assistant message.
  Reply(message: AgentMessage)
  /// Fail in-band with this provider error.
  Refuse(error: stream.ProviderError)
  /// Never settle: the effect blocks until its process is killed.
  Hang
}

/// What one scripted tool execution does.
pub type ToolResult {
  /// Complete with a text result.
  ToolReply(text: String, is_error: Bool, terminate: Bool)
  /// Never settle: the effect blocks until its process is killed.
  ToolHang
}

/// Builds a scripted `Effects` record.
///
/// `registry` maps tool names to replay policies (clearance refuses
/// unknown names); `provider` and `tool` are the scripts.
pub fn effects(
  rec: Subject(recorder.Message),
  clock: Clock,
  registry: List(#(String, ReplayPolicy)),
  provider: fn(effects.RequestSpec) -> ProviderResult,
  tool: fn(effects.ToolRun) -> ToolResult,
) -> Effects {
  effects.Effects(
    clock:,
    entropy: fn() { 1_000_000 + recorder.bump(rec, "entropy") * 104_729 },
    timers: effects.real_timers(),
    provider: effects.ProviderSurface(
      request: fn(spec) {
        let _count = recorder.bump(rec, "provider")
        let events = process.new_subject()
        case provider(spec) {
          Reply(message:) -> {
            let assert Ok(settled) = stream.settle(message)
              as "provider scripts must reply with settled assistant messages"
            let usage = case message {
              AssistantMessage(usage:, ..) -> usage
              _ -> effects.zero_usage()
            }
            process.send(events, stream.Settled(message: settled, usage:))
          }
          Refuse(error:) -> process.send(events, stream.Failed(error:))
          Hang -> Nil
        }
        stream.immediate(events:, cancel: fn() { Nil })
      },
      timeout_ms: 60_000,
    ),
    tools: effects.ToolSurface(
      clear: fn(query: effects.ClearanceQuery) {
        case list.key_find(registry, query.call.name) {
          Ok(replay) ->
            effects.Cleared(effective_arguments: query.call.arguments, replay:)
          Error(Nil) ->
            effects.ClearanceRefused(
              reason: "unknown tool: " <> query.call.name,
            )
        }
      },
      run: fn(run: effects.ToolRun) {
        let _count =
          recorder.bump(rec, "tool:" <> run.call.name <> ":" <> run.call.id)
        case tool(run) {
          ToolReply(text:, is_error:, terminate:) ->
            effects.ToolCompleted(
              result: ToolResultMessage(
                tool_call_id: run.call.id,
                tool_name: run.call.name,
                content: [ToolResultText(text:, text_signature: None)],
                details: None,
                usage: None,
                added_tool_names: None,
                is_error:,
                timestamp: 0,
              ),
              terminate:,
            )
          ToolHang -> {
            // Block forever; the driver kills this process on abort, and
            // a tree kill leaves it parked harmlessly until the VM ends.
            let never: Subject(Nil) = process.new_subject()
            let _nil = process.receive_forever(never)
            effects.ToolFailed(reason: "unreachable")
          }
        }
      },
      replay_still_safe: fn(name) {
        case list.key_find(registry, name) {
          Ok(operation.ReplaySafe) -> True
          _ -> False
        }
      },
      // Scenario tools overlap freely unless a test injects its own
      // surface with exclusive modes.
      execution_mode: fn(_name) { effects.ConcurrentExecution },
    ),
    hooks: effects.default_hooks(),
  )
}

/// Which assistant turn a generation request is producing: the number of
/// assistant messages already in the projected context. Stable across
/// crashes and retries because dropped (errored/aborted) responses never
/// enter the projection.
pub fn turn(spec: effects.RequestSpec) -> Int {
  case spec {
    effects.GenerationRequest(context:, ..) ->
      list.fold(context, 0, fn(count, message) {
        case message {
          AssistantMessage(..) -> count + 1
          _ -> count
        }
      })
    effects.PollRequest(..) -> 0
    effects.SummaryRequest(..) -> 0
  }
}

/// The attempt number of a generation request (1-based).
pub fn attempt(spec: effects.RequestSpec) -> Int {
  case spec {
    effects.GenerationRequest(attempt:, ..) -> attempt
    effects.PollRequest(poll:, ..) -> poll
    effects.SummaryRequest(attempt:, ..) -> attempt
  }
}

// --- message builders -----------------------------------------------------

/// A user message with one text block.
pub fn user(text: String) -> AgentMessage {
  UserMessage(content: [UserText(text:, text_signature: None)], timestamp: 0)
}

/// A settled final assistant answer carrying `tokens` of usage.
pub fn answer(text: String, tokens: Int) -> AgentMessage {
  AssistantMessage(
    content: [AssistantText(text:, text_signature: None)],
    api: "fake",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(tokens),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: Some(True),
    timestamp: 0,
  )
}

/// A settled tool-use response: `calls` are `#(id, name)` pairs, given
/// fixed scripted ids so invocation counters are stable across runs.
pub fn tool_use(
  text: String,
  calls: List(#(String, String)),
  tokens: Int,
) -> AgentMessage {
  let blocks =
    list.map(calls, fn(pair) {
      let #(id, name) = pair
      AssistantToolCall(call: ToolCall(
        id:,
        name:,
        arguments: core_json_object(),
        thought_signature: None,
        namespace: None,
      ))
    })
  AssistantMessage(
    content: [AssistantText(text:, text_signature: None), ..blocks],
    api: "fake",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(tokens),
    stop_reason: message.ToolUse,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

fn core_json_object() -> core_json.JsonValue {
  core_json.Object([])
}

/// A usage aggregate reporting `tokens` total (all in output).
pub fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: 0,
    output: tokens,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

/// A retryable provider failure (HTTP 500).
pub fn retryable_error() -> stream.ProviderError {
  stream.HttpError(
    status: 500,
    api_error_type: "server_error",
    message: "scripted transient failure",
    retry_after_ms: None,
  )
}
