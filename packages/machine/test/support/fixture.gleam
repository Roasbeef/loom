//// Shared message and preparation fixtures for the machine suite.

import core/json
import core/message.{
  type AgentMessage, type DeferredHandle, type StopReason, type Usage,
  AssistantMessage, AssistantText, AssistantToolCall, DeferredHandle, ToolCall,
  ToolResultMessage, ToolResultText, Usage, UsageCost, UserMessage, UserText,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import machine/classification.{type SettledAssistantMessage}
import machine/operation.{
  type StructuralPreparation, CompactionPreparation, CompactionSettings,
  FileOperations,
}

/// A user message with one text block.
pub fn user(text: String) -> AgentMessage {
  UserMessage(content: [UserText(text:, text_signature: None)], timestamp: 1)
}

/// A token usage with the given input/output counts.
pub fn usage_of(input: Int, output: Int) -> Usage {
  Usage(
    input:,
    output:,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + output,
    cost: UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

/// An assistant response with the given stop reason and text content.
pub fn assistant(
  stop_reason: StopReason,
  text: String,
  output_tokens: Int,
) -> AgentMessage {
  AssistantMessage(
    content: [AssistantText(text:, text_signature: None)],
    api: "acme-api",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage_of(100, output_tokens),
    stop_reason:,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 2,
  )
}

/// An assistant response requesting the named tool calls (one call block
/// per name, preceded by one text block so source indexes are non-zero).
pub fn assistant_calls(names: List(String)) -> AgentMessage {
  let calls =
    list.index_map(names, fn(name, index) {
      AssistantToolCall(call: ToolCall(
        id: "call_" <> name <> "_" <> int_text(index),
        name:,
        arguments: json.Object([#("arg", json.Int(index))]),
        thought_signature: None,
        namespace: None,
      ))
    })
  let base = assistant(message.ToolUse, "using tools", 10)
  case base {
    AssistantMessage(..) ->
      AssistantMessage(..base, content: [
        AssistantText(text: "using tools", text_signature: None),
        ..calls
      ])
    other -> other
  }
}

fn int_text(value: Int) -> String {
  case value {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    _ -> "n"
  }
}

/// An assistant error response with the given message.
pub fn assistant_error(error_message: String, retryable: Bool) -> AgentMessage {
  let base = assistant(message.Errored, "", 0)
  case base {
    AssistantMessage(..) ->
      AssistantMessage(
        ..base,
        content: [],
        error_message: Some(error_message),
        raw_stop_reason: case retryable {
          True -> Some("retryable")
          False -> None
        },
      )
    other -> other
  }
}

/// A deferred handle for the fixture model identity.
pub fn handle(id: String) -> DeferredHandle {
  DeferredHandle(
    provider: "acme",
    model_id: "loom-1",
    api: "acme-api",
    id:,
    expires_at: None,
    poll_after_ms: Some(1000),
    data: None,
  )
}

/// An assistant response settling as deferred with the given handle.
pub fn assistant_deferred(deferred: Option(DeferredHandle)) -> AgentMessage {
  let base = assistant(message.Deferred, "", 0)
  case base {
    AssistantMessage(..) -> AssistantMessage(..base, content: [], deferred:)
    other -> other
  }
}

/// A finalized tool result message.
pub fn tool_result(
  call_id: String,
  name: String,
  text: String,
) -> AgentMessage {
  ToolResultMessage(
    tool_call_id: call_id,
    tool_name: name,
    content: [ToolResultText(text:, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 3,
  )
}

/// Wraps a message as settled, crashing the test on refusal.
pub fn settled(message: AgentMessage) -> SettledAssistantMessage {
  let assert Ok(settled) = classification.settle(message)
    as "fixture must be a settled assistant message"
  settled
}

/// A small compaction preparation.
pub fn preparation() -> StructuralPreparation {
  CompactionPreparation(
    messages_to_summarize: [user("old context")],
    turn_prefix_messages: [],
    retained_tail: [user("recent tail")],
    is_split_turn: False,
    tokens_before: 5000,
    previous_summary: None,
    file_ops: FileOperations(read: ["a.txt"], written: [], edited: []),
    settings: CompactionSettings(
      enabled: True,
      reserve_tokens: 1000,
      keep_recent_tokens: 500,
    ),
  )
}
