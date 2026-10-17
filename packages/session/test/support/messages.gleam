//// Deterministic message builders for the session tests: settled user,
//// assistant and tool-result messages numbered by the caller, so equal
//// builders compare equal across runs. The randomized property tests draw
//// their scripts from qcheck generators in their own modules; nothing here
//// is random.

import core/accounting
import core/json.{type JsonValue}
import core/message.{type AgentMessage, type ToolCall}
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

/// A zero-cost, zero-token usage value.
pub fn zero_usage() -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    evidence: usage_evidence.priced_api(),
  )
}

/// A small non-zero usage value carrying `tokens` input tokens.
pub fn some_usage(tokens: Int) -> message.Usage {
  message.Usage(..zero_usage(), input: tokens, total_tokens: tokens)
}

/// A user message with numbered text.
pub fn user_msg(n: Int) -> AgentMessage {
  user_text("user-" <> int.to_string(n))
}

/// A user message with the given text.
pub fn user_text(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: n_of_text(text),
    origin: None,
  )
}

// A stable fake timestamp derived from the text so equal builders compare
// equal across runs.
fn n_of_text(text: String) -> Int {
  string.byte_size(text)
}

/// A settled assistant message: numbered text plus the given tool-call
/// blocks and stop reason.
pub fn assistant_msg(
  n: Int,
  stop: message.StopReason,
  calls: List(ToolCall),
) -> AgentMessage {
  message.AssistantMessage(
    content: [
      message.AssistantText(
        text: "assistant-" <> int.to_string(n),
        text_signature: None,
      ),
      ..list.map(calls, fn(call) { message.AssistantToolCall(call:) })
    ],
    api: "fake",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: zero_usage(),
    stop_reason: stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: n,
  )
}

/// A numbered tool call with the given arguments.
pub fn tool_call(n: Int, arguments: JsonValue) -> ToolCall {
  message.ToolCall(
    id: "call-" <> int.to_string(n),
    name: "tool-" <> int.to_string(n),
    arguments:,
    thought_signature: None,
    namespace: None,
  )
}

/// The (successful) result of a tool call, with numbered text.
pub fn tool_result(call: ToolCall, n: Int) -> AgentMessage {
  message.ToolResultMessage(
    tool_call_id: call.id,
    tool_name: call.name,
    content: [
      message.ToolResultText(
        text: "result-" <> int.to_string(n),
        text_signature: None,
      ),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: n,
  )
}
