//// The `AgentMessage` family and the `Usage` cost shape.
////
//// Per ADR-001 these types mirror the structure of pi's provider-message
//// shapes (`packages/ai/src/types.ts` `UserMessage` / `AssistantMessage` /
//// `ToolResultMessage` and `Usage`, plus the agent-level custom-message
//// extension point), diverging only in representation: exhaustive Gleam
//// ADTs instead of TypeScript tagged unions, `Option` instead of optional
//// fields, and per-role content unions so a thinking block can never appear
//// in a user message. Field vocabulary is pi's; the JSON codecs in
//// `core/codec` keep pi's exact wire field names so the format-4 import is
//// a mechanical decode-and-re-mint.
////
//// Deliberate representation choices (see ADR-001 for the policy):
////
//// - pi's `UserMessage.content: string | Block[]` is normalized to a block
////   list; codecs still accept the bare-string form on decode.
//// - pi's `AssistantMessage.diagnostics` (redacted provider diagnostics)
////   is carried as opaque `Json` rather than modeled: it is debugging
////   data, and modeling it would couple `core` to pi's diagnostic ADT.
//// - Custom app messages, an open TypeScript interface in pi, become the
////   closed `CustomMessage` variant carrying a registered runtime schema
////   name plus an opaque `Json` payload.
//// - pi's `stopReason: "error"` maps to the `Errored` constructor because
////   `Error` would shadow the `Result` constructor.

import core/json.{type JsonValue}
import gleam/option.{type Option}

/// One message in a conversation, in provider-request shape.
///
/// Constructor invariants:
///
/// - `UserMessage`: `content` is non-empty for any message a provider will
///   accept; `timestamp` is Unix ms.
/// - `AssistantMessage`: `content` is in provider emission order; `usage`
///   covers exactly this response; a message whose `stop_reason` is
///   `Pending` is a streaming intermediate and must never be written to an
///   entry (pi §2.1: assistant entries are settled). `api`, `provider`, and
///   `model` name the resolved identity the response came from.
/// - `ToolResultMessage`: `tool_call_id` and `tool_name` reference a
///   `ToolCall` in a prior assistant message; `usage` is tool-execution
///   cost, not main-context cost; `is_error` marks in-band tool failure.
/// - `CustomMessage`: `schema` names a registered runtime schema that gives
///   `payload` meaning; the harness treats the payload as opaque data.
pub type AgentMessage {
  /// A user-authored turn.
  UserMessage(content: List(UserBlock), timestamp: Int)
  /// A provider response.
  AssistantMessage(
    content: List(AssistantBlock),
    api: String,
    provider: String,
    model: String,
    response_model: Option(String),
    response_id: Option(String),
    diagnostics: Option(JsonValue),
    usage: Usage,
    stop_reason: StopReason,
    deferred: Option(DeferredHandle),
    error_message: Option(String),
    raw_stop_reason: Option(String),
    end_turn: Option(Bool),
    timestamp: Int,
  )
  /// The result of executing one tool call.
  ToolResultMessage(
    tool_call_id: String,
    tool_name: String,
    content: List(ToolResultBlock),
    details: Option(JsonValue),
    usage: Option(Usage),
    added_tool_names: Option(List(String)),
    is_error: Bool,
    timestamp: Int,
  )
  /// An application-defined message under a registered runtime schema.
  CustomMessage(schema: String, payload: JsonValue)
}

/// A content block a user message may carry.
///
/// Constructor invariants: `UserText.text_signature` is provider metadata
/// and opaque; `UserImage.data` is base64-encoded image bytes and
/// `mime_type` is its media type (e.g. `"image/png"`).
pub type UserBlock {
  /// Text authored by the user.
  UserText(text: String, text_signature: Option(String))
  /// An image supplied by the user.
  UserImage(data: String, mime_type: String)
}

/// A content block an assistant message may carry.
///
/// Constructor invariants: `AssistantThinking.redacted` is `True` when the
/// thinking text was redacted by safety filters, in which case the opaque
/// encrypted payload lives in `thinking_signature` for multi-turn replay;
/// signatures are provider-opaque and must be replayed unmodified.
pub type AssistantBlock {
  /// Text produced by the model.
  AssistantText(text: String, text_signature: Option(String))
  /// A reasoning block, possibly redacted.
  AssistantThinking(
    thinking: String,
    thinking_signature: Option(String),
    redacted: Bool,
  )
  /// A request to invoke a tool.
  AssistantToolCall(call: ToolCall)
}

/// A content block a tool result may carry.
///
/// Constructor invariants: as for the user blocks — `data` is base64 image
/// bytes with its `mime_type`.
pub type ToolResultBlock {
  /// Text output from the tool.
  ToolResultText(text: String, text_signature: Option(String))
  /// An image produced by the tool.
  ToolResultImage(data: String, mime_type: String)
}

/// One tool invocation requested by the model.
///
/// Constructor invariants: `id` is the provider's call id, unique within
/// its assistant message and echoed by the matching tool result;
/// `arguments` is a `Json` object matching the tool's schema (validated at
/// the tool boundary, not here); `thought_signature` and `namespace` are
/// provider-specific opaque metadata.
pub type ToolCall {
  ToolCall(
    id: String,
    name: String,
    arguments: JsonValue,
    thought_signature: Option(String),
    namespace: Option(String),
  )
}

/// Why a provider response ended. Mirrors pi's `StopReason` union; the
/// codec maps `Errored` to the wire string `"error"`.
///
/// Constructor invariants: `Pending` marks a streaming intermediate and is
/// rejected before a message is written durably; `Deferred` requires the
/// message to carry a `DeferredHandle`.
pub type StopReason {
  /// The stream has not settled yet.
  Pending
  /// The model ended its turn normally.
  Stop
  /// The response hit a token limit.
  Length
  /// The model requested tool calls.
  ToolUse
  /// The request failed; `error_message` says why. Wire form `"error"`.
  Errored
  /// The request was aborted by the caller.
  Aborted
  /// The provider returned a durable handle to poll instead of a response.
  Deferred
}

/// A durable handle to a provider-side deferred response.
///
/// Constructor invariants: `provider`, `model_id`, and `api` identify where
/// to poll; `id` is the provider token (response id, or batch id plus row
/// id); `data` is provider conversion data needed to reconstruct the final
/// assistant message and is opaque here.
pub type DeferredHandle {
  DeferredHandle(
    provider: String,
    model_id: String,
    api: String,
    id: String,
    expires_at: Option(Int),
    poll_after_ms: Option(Int),
    data: Option(JsonValue),
  )
}

/// Token counts and cost for one provider response or tool execution.
/// Mirrors pi's `Usage`.
///
/// Constructor invariants: counts are non-negative; `reasoning`, when
/// reported, is a subset of `output` (already included in it);
/// `cache_write_1h`, when reported, is the subset of `cache_write` written
/// with one-hour retention; `total_tokens` is the provider-reported total.
pub type Usage {
  Usage(
    input: Int,
    output: Int,
    cache_read: Int,
    cache_write: Int,
    cache_write_1h: Option(Int),
    reasoning: Option(Int),
    total_tokens: Int,
    cost: UsageCost,
  )
}

/// Dollar cost breakdown for one `Usage`.
///
/// Constructor invariants: all fields are non-negative dollar amounts and
/// `total` is their sum as reported by the pricing model.
pub type UsageCost {
  UsageCost(
    input: Float,
    output: Float,
    cache_read: Float,
    cache_write: Float,
    total: Float,
  )
}
