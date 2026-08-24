//// Durability-boundary JSON codecs for every durable core type.
////
//// Encoders map values to `core/json` `JsonValue`; decoders are total,
//// returning `Result(t, CorruptionReport)` for any input that does not
//// match — wrong shapes and wrong types are reports, never crashes.
////
//// Wire-field vocabulary is pi's, verbatim (`parentId`, `cacheRead`,
//// `stopReason`, `retainedTail`, …), per ADR-001: keeping pi's exact JSON
//// field names makes the format-4 import a mechanical decode-and-re-mint.
//// Two decode conveniences beyond strict inversion of the encoders:
//// a user message's `content` may be a bare string (normalized to one text
//// block, pi's shorthand form), and optional typed fields accept an
//// explicit `null` as absence. Opaque `Json` payload fields (`data`,
//// `details`, `diagnostics`, `payload`) distinguish absent from `null`:
//// absent decodes to `None`, a present `null` to `Some(json.Null)`.

import core/corruption.{type CorruptionReport}
import core/entry.{
  type Entry, type UsageRow, BranchSummaryEntry, CompactionEntry, CustomEntry,
  MessageEntry, UsageRow,
}
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type AssistantBlock, type DeferredHandle, type StopReason,
  type ToolCall, type ToolResultBlock, type Usage, type UsageCost,
  type UserBlock, Aborted, AssistantMessage, AssistantText, AssistantThinking,
  AssistantToolCall, CustomMessage, Deferred, DeferredHandle, Errored, Length,
  Pending, Stop, ToolCall, ToolResultImage, ToolResultMessage, ToolResultText,
  ToolUse, Usage, UsageCost, UserImage, UserMessage, UserText,
}
import core/register.{type RegisterValue, RegisterValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// --- usage --------------------------------------------------------------

/// Encodes a `Usage` in pi's wire shape.
///
/// ## Examples
///
/// ```gleam
/// let usage =
///   message.Usage(1, 2, 0, 0, None, None, 3, message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0))
/// assert codec.decode_usage(codec.encode_usage(usage)) == Ok(usage)
/// ```
///
pub fn encode_usage(usage: Usage) -> JsonValue {
  object_of([
    #("input", Some(json.Int(usage.input))),
    #("output", Some(json.Int(usage.output))),
    #("cacheRead", Some(json.Int(usage.cache_read))),
    #("cacheWrite", Some(json.Int(usage.cache_write))),
    #("cacheWrite1h", option.map(usage.cache_write_1h, json.Int)),
    #("reasoning", option.map(usage.reasoning, json.Int)),
    #("totalTokens", Some(json.Int(usage.total_tokens))),
    #("cost", Some(encode_usage_cost(usage.cost))),
  ])
}

/// Decodes a `Usage`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_usage(json.String("nope"))
/// ```
///
pub fn decode_usage(value: JsonValue) -> Result(Usage, CorruptionReport) {
  let where = "core/codec.usage"
  use fields <- result.try(fields_of(value, where))
  use input <- result.try(require_int(fields, "input", where))
  use output <- result.try(require_int(fields, "output", where))
  use cache_read <- result.try(require_int(fields, "cacheRead", where))
  use cache_write <- result.try(require_int(fields, "cacheWrite", where))
  use cache_write_1h <- result.try(optional_int(fields, "cacheWrite1h", where))
  use reasoning <- result.try(optional_int(fields, "reasoning", where))
  use total_tokens <- result.try(require_int(fields, "totalTokens", where))
  use cost_value <- result.try(require(fields, "cost", where))
  use cost <- result.try(decode_usage_cost(cost_value))
  Ok(Usage(
    input:,
    output:,
    cache_read:,
    cache_write:,
    cache_write_1h:,
    reasoning:,
    total_tokens:,
    cost:,
  ))
}

fn encode_usage_cost(cost: UsageCost) -> JsonValue {
  json.Object([
    #("input", json.Float(cost.input)),
    #("output", json.Float(cost.output)),
    #("cacheRead", json.Float(cost.cache_read)),
    #("cacheWrite", json.Float(cost.cache_write)),
    #("total", json.Float(cost.total)),
  ])
}

fn decode_usage_cost(value: JsonValue) -> Result(UsageCost, CorruptionReport) {
  let where = "core/codec.usage.cost"
  use fields <- result.try(fields_of(value, where))
  use input <- result.try(require_float(fields, "input", where))
  use output <- result.try(require_float(fields, "output", where))
  use cache_read <- result.try(require_float(fields, "cacheRead", where))
  use cache_write <- result.try(require_float(fields, "cacheWrite", where))
  use total <- result.try(require_float(fields, "total", where))
  Ok(UsageCost(input:, output:, cache_read:, cache_write:, total:))
}

// --- messages -----------------------------------------------------------

/// Encodes an `AgentMessage` in pi's wire shape, discriminated by `role`.
///
/// ## Examples
///
/// ```gleam
/// let msg = message.UserMessage([message.UserText("hi", None)], 0)
/// assert codec.decode_message(codec.encode_message(msg)) == Ok(msg)
/// ```
///
pub fn encode_message(message: AgentMessage) -> JsonValue {
  case message {
    UserMessage(content:, timestamp:) ->
      object_of([
        #("role", Some(json.String("user"))),
        #("content", Some(json.Array(list.map(content, encode_user_block)))),
        #("timestamp", Some(json.Int(timestamp))),
      ])
    AssistantMessage(
      content:,
      api:,
      provider:,
      model:,
      response_model:,
      response_id:,
      diagnostics:,
      usage:,
      stop_reason:,
      deferred:,
      error_message:,
      raw_stop_reason:,
      end_turn:,
      timestamp:,
    ) ->
      object_of([
        #("role", Some(json.String("assistant"))),
        #(
          "content",
          Some(json.Array(list.map(content, encode_assistant_block))),
        ),
        #("api", Some(json.String(api))),
        #("provider", Some(json.String(provider))),
        #("model", Some(json.String(model))),
        #("responseModel", option.map(response_model, json.String)),
        #("responseId", option.map(response_id, json.String)),
        #("diagnostics", diagnostics),
        #("usage", Some(encode_usage(usage))),
        #("stopReason", Some(json.String(stop_reason_to_string(stop_reason)))),
        #("deferred", option.map(deferred, encode_deferred_handle)),
        #("errorMessage", option.map(error_message, json.String)),
        #("rawStopReason", option.map(raw_stop_reason, json.String)),
        #("endTurn", option.map(end_turn, json.Bool)),
        #("timestamp", Some(json.Int(timestamp))),
      ])
    ToolResultMessage(
      tool_call_id:,
      tool_name:,
      content:,
      details:,
      usage:,
      added_tool_names:,
      is_error:,
      timestamp:,
    ) ->
      object_of([
        #("role", Some(json.String("toolResult"))),
        #("toolCallId", Some(json.String(tool_call_id))),
        #("toolName", Some(json.String(tool_name))),
        #(
          "content",
          Some(json.Array(list.map(content, encode_tool_result_block))),
        ),
        #("details", details),
        #("usage", option.map(usage, encode_usage)),
        #(
          "addedToolNames",
          option.map(added_tool_names, fn(names) {
            json.Array(list.map(names, json.String))
          }),
        ),
        #("isError", Some(json.Bool(is_error))),
        #("timestamp", Some(json.Int(timestamp))),
      ])
    CustomMessage(schema:, payload:) ->
      json.Object([
        #("role", json.String("custom")),
        #("schema", json.String(schema)),
        #("payload", payload),
      ])
  }
}

/// Decodes an `AgentMessage`, dispatching on `role`. Total; an unknown
/// role is corruption — pi's open custom-message roles arrive here only
/// through the import shim, which maps them to the `"custom"` form.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) =
///   codec.decode_message(json.Object([#("role", json.String("oracle"))]))
/// ```
///
pub fn decode_message(
  value: JsonValue,
) -> Result(AgentMessage, CorruptionReport) {
  let where = "core/codec.message"
  use fields <- result.try(fields_of(value, where))
  use role <- result.try(require_string(fields, "role", where))
  case role {
    "user" -> decode_user_message(fields)
    "assistant" -> decode_assistant_message(fields)
    "toolResult" -> decode_tool_result_message(fields)
    "custom" -> decode_custom_message(fields)
    other ->
      Error(corruption.report(
        at: where,
        on: "role",
        expected: "user, assistant, toolResult, or custom",
        context: other,
      ))
  }
}

fn decode_user_message(
  fields: Fields,
) -> Result(AgentMessage, CorruptionReport) {
  let where = "core/codec.message.user"
  use timestamp <- result.try(require_int(fields, "timestamp", where))
  use content_value <- result.try(require(fields, "content", where))
  use content <- result.try(case content_value {
    // pi's shorthand: a bare string is one text block.
    json.String(text) -> Ok([UserText(text:, text_signature: None)])
    json.Array(items) -> list.try_map(items, decode_user_block)
    other ->
      Error(corruption.report(
        at: where,
        on: "content",
        expected: "a string or an array of content blocks",
        context: json.to_string(other),
      ))
  })
  Ok(UserMessage(content:, timestamp:))
}

fn decode_assistant_message(
  fields: Fields,
) -> Result(AgentMessage, CorruptionReport) {
  let where = "core/codec.message.assistant"
  use content_items <- result.try(require_array(fields, "content", where))
  use content <- result.try(list.try_map(content_items, decode_assistant_block))
  use api <- result.try(require_string(fields, "api", where))
  use provider <- result.try(require_string(fields, "provider", where))
  use model <- result.try(require_string(fields, "model", where))
  use response_model <- result.try(optional_string(
    fields,
    "responseModel",
    where,
  ))
  use response_id <- result.try(optional_string(fields, "responseId", where))
  let diagnostics = optional_json(fields, "diagnostics")
  use usage_value <- result.try(require(fields, "usage", where))
  use usage <- result.try(decode_usage(usage_value))
  use stop_reason_text <- result.try(require_string(fields, "stopReason", where))
  use stop_reason <- result.try(parse_stop_reason(stop_reason_text, where))
  use deferred <- result.try(case optional_json(fields, "deferred") {
    None | Some(json.Null) -> Ok(None)
    Some(handle_value) -> result.map(decode_deferred_handle(handle_value), Some)
  })
  use error_message <- result.try(optional_string(fields, "errorMessage", where))
  use raw_stop_reason <- result.try(optional_string(
    fields,
    "rawStopReason",
    where,
  ))
  use end_turn <- result.try(optional_bool(fields, "endTurn", where))
  use timestamp <- result.try(require_int(fields, "timestamp", where))
  Ok(AssistantMessage(
    content:,
    api:,
    provider:,
    model:,
    response_model:,
    response_id:,
    diagnostics:,
    usage:,
    stop_reason:,
    deferred:,
    error_message:,
    raw_stop_reason:,
    end_turn:,
    timestamp:,
  ))
}

fn decode_tool_result_message(
  fields: Fields,
) -> Result(AgentMessage, CorruptionReport) {
  let where = "core/codec.message.tool_result"
  use tool_call_id <- result.try(require_string(fields, "toolCallId", where))
  use tool_name <- result.try(require_string(fields, "toolName", where))
  use content_items <- result.try(require_array(fields, "content", where))
  use content <- result.try(list.try_map(
    content_items,
    decode_tool_result_block,
  ))
  let details = optional_json(fields, "details")
  use usage <- result.try(case optional_json(fields, "usage") {
    None | Some(json.Null) -> Ok(None)
    Some(usage_value) -> result.map(decode_usage(usage_value), Some)
  })
  use added_tool_names <- result.try(
    case optional_json(fields, "addedToolNames") {
      None | Some(json.Null) -> Ok(None)
      Some(json.Array(items)) ->
        items
        |> list.try_map(fn(item) { as_string(item, "addedToolNames", where) })
        |> result.map(Some)
      Some(other) ->
        Error(corruption.report(
          at: where,
          on: "addedToolNames",
          expected: "an array of strings",
          context: json.to_string(other),
        ))
    },
  )
  use is_error <- result.try(require_bool(fields, "isError", where))
  use timestamp <- result.try(require_int(fields, "timestamp", where))
  Ok(ToolResultMessage(
    tool_call_id:,
    tool_name:,
    content:,
    details:,
    usage:,
    added_tool_names:,
    is_error:,
    timestamp:,
  ))
}

fn decode_custom_message(
  fields: Fields,
) -> Result(AgentMessage, CorruptionReport) {
  let where = "core/codec.message.custom"
  use schema <- result.try(require_string(fields, "schema", where))
  use payload <- result.try(require(fields, "payload", where))
  Ok(CustomMessage(schema:, payload:))
}

// --- content blocks -----------------------------------------------------

fn encode_user_block(block: UserBlock) -> JsonValue {
  case block {
    UserText(text:, text_signature:) -> encode_text_block(text, text_signature)
    UserImage(data:, mime_type:) -> encode_image_block(data, mime_type)
  }
}

fn decode_user_block(value: JsonValue) -> Result(UserBlock, CorruptionReport) {
  let where = "core/codec.message.user.content"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "type", where))
  case kind {
    "text" -> {
      use #(text, text_signature) <- result.map(decode_text_block(fields, where))
      UserText(text:, text_signature:)
    }
    "image" -> {
      use #(data, mime_type) <- result.map(decode_image_block(fields, where))
      UserImage(data:, mime_type:)
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "type",
        expected: "text or image",
        context: other,
      ))
  }
}

fn encode_assistant_block(block: AssistantBlock) -> JsonValue {
  case block {
    AssistantText(text:, text_signature:) ->
      encode_text_block(text, text_signature)
    AssistantThinking(thinking:, thinking_signature:, redacted:) ->
      object_of([
        #("type", Some(json.String("thinking"))),
        #("thinking", Some(json.String(thinking))),
        #("thinkingSignature", option.map(thinking_signature, json.String)),
        #("redacted", encode_default_false(redacted)),
      ])
    AssistantToolCall(call:) -> encode_tool_call(call)
  }
}

fn decode_assistant_block(
  value: JsonValue,
) -> Result(AssistantBlock, CorruptionReport) {
  let where = "core/codec.message.assistant.content"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "type", where))
  case kind {
    "text" -> {
      use #(text, text_signature) <- result.map(decode_text_block(fields, where))
      AssistantText(text:, text_signature:)
    }
    "thinking" -> {
      use thinking <- result.try(require_string(fields, "thinking", where))
      use thinking_signature <- result.try(optional_string(
        fields,
        "thinkingSignature",
        where,
      ))
      use redacted <- result.try(optional_bool(fields, "redacted", where))
      Ok(AssistantThinking(
        thinking:,
        thinking_signature:,
        redacted: option.unwrap(redacted, or: False),
      ))
    }
    "toolCall" -> result.map(decode_tool_call(fields), AssistantToolCall)
    other ->
      Error(corruption.report(
        at: where,
        on: "type",
        expected: "text, thinking, or toolCall",
        context: other,
      ))
  }
}

fn encode_tool_result_block(block: ToolResultBlock) -> JsonValue {
  case block {
    ToolResultText(text:, text_signature:) ->
      encode_text_block(text, text_signature)
    ToolResultImage(data:, mime_type:) -> encode_image_block(data, mime_type)
  }
}

fn decode_tool_result_block(
  value: JsonValue,
) -> Result(ToolResultBlock, CorruptionReport) {
  let where = "core/codec.message.tool_result.content"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "type", where))
  case kind {
    "text" -> {
      use #(text, text_signature) <- result.map(decode_text_block(fields, where))
      ToolResultText(text:, text_signature:)
    }
    "image" -> {
      use #(data, mime_type) <- result.map(decode_image_block(fields, where))
      ToolResultImage(data:, mime_type:)
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "type",
        expected: "text or image",
        context: other,
      ))
  }
}

fn encode_text_block(
  text: String,
  text_signature: Option(String),
) -> JsonValue {
  object_of([
    #("type", Some(json.String("text"))),
    #("text", Some(json.String(text))),
    #("textSignature", option.map(text_signature, json.String)),
  ])
}

fn decode_text_block(
  fields: Fields,
  where: String,
) -> Result(#(String, Option(String)), CorruptionReport) {
  use text <- result.try(require_string(fields, "text", where))
  use text_signature <- result.try(optional_string(
    fields,
    "textSignature",
    where,
  ))
  Ok(#(text, text_signature))
}

fn encode_image_block(data: String, mime_type: String) -> JsonValue {
  json.Object([
    #("type", json.String("image")),
    #("data", json.String(data)),
    #("mimeType", json.String(mime_type)),
  ])
}

fn decode_image_block(
  fields: Fields,
  where: String,
) -> Result(#(String, String), CorruptionReport) {
  use data <- result.try(require_string(fields, "data", where))
  use mime_type <- result.try(require_string(fields, "mimeType", where))
  Ok(#(data, mime_type))
}

fn encode_tool_call(call: ToolCall) -> JsonValue {
  object_of([
    #("type", Some(json.String("toolCall"))),
    #("id", Some(json.String(call.id))),
    #("name", Some(json.String(call.name))),
    #("arguments", Some(call.arguments)),
    #("thoughtSignature", option.map(call.thought_signature, json.String)),
    #("namespace", option.map(call.namespace, json.String)),
  ])
}

fn decode_tool_call(fields: Fields) -> Result(ToolCall, CorruptionReport) {
  let where = "core/codec.message.tool_call"
  use id <- result.try(require_string(fields, "id", where))
  use name <- result.try(require_string(fields, "name", where))
  use arguments <- result.try(require(fields, "arguments", where))
  use thought_signature <- result.try(optional_string(
    fields,
    "thoughtSignature",
    where,
  ))
  use namespace <- result.try(optional_string(fields, "namespace", where))
  Ok(ToolCall(id:, name:, arguments:, thought_signature:, namespace:))
}

// --- stop reasons and deferred handles ----------------------------------

fn stop_reason_to_string(reason: StopReason) -> String {
  case reason {
    Pending -> "pending"
    Stop -> "stop"
    Length -> "length"
    ToolUse -> "toolUse"
    Errored -> "error"
    Aborted -> "aborted"
    Deferred -> "deferred"
  }
}

fn parse_stop_reason(
  text: String,
  where: String,
) -> Result(StopReason, CorruptionReport) {
  case text {
    "pending" -> Ok(Pending)
    "stop" -> Ok(Stop)
    "length" -> Ok(Length)
    "toolUse" -> Ok(ToolUse)
    "error" -> Ok(Errored)
    "aborted" -> Ok(Aborted)
    "deferred" -> Ok(Deferred)
    other ->
      Error(corruption.report(
        at: where,
        on: "stopReason",
        expected: "a known stop reason",
        context: other,
      ))
  }
}

fn encode_deferred_handle(handle: DeferredHandle) -> JsonValue {
  object_of([
    #("provider", Some(json.String(handle.provider))),
    #("modelId", Some(json.String(handle.model_id))),
    #("api", Some(json.String(handle.api))),
    #("id", Some(json.String(handle.id))),
    #("expiresAt", option.map(handle.expires_at, json.Int)),
    #("pollAfterMs", option.map(handle.poll_after_ms, json.Int)),
    #("data", handle.data),
  ])
}

fn decode_deferred_handle(
  value: JsonValue,
) -> Result(DeferredHandle, CorruptionReport) {
  let where = "core/codec.message.deferred"
  use fields <- result.try(fields_of(value, where))
  use provider <- result.try(require_string(fields, "provider", where))
  use model_id <- result.try(require_string(fields, "modelId", where))
  use api <- result.try(require_string(fields, "api", where))
  use id <- result.try(require_string(fields, "id", where))
  use expires_at <- result.try(optional_int(fields, "expiresAt", where))
  use poll_after_ms <- result.try(optional_int(fields, "pollAfterMs", where))
  let data = optional_json(fields, "data")
  Ok(DeferredHandle(
    provider:,
    model_id:,
    api:,
    id:,
    expires_at:,
    poll_after_ms:,
    data:,
  ))
}

// --- entries ------------------------------------------------------------

/// Encodes an `Entry` in pi's wire shape, discriminated by `type`.
///
/// ## Examples
///
/// ```gleam
/// let value = codec.encode_entry(entry)
/// assert codec.decode_entry(value) == Ok(entry)
/// ```
///
pub fn encode_entry(entry: Entry) -> JsonValue {
  case entry {
    MessageEntry(id:, parent:, seq:, ts:, message:, terminate:) ->
      object_of([
        #("id", Some(encode_entry_id(id))),
        #("parentId", Some(encode_parent(parent))),
        #("seq", Some(json.Int(seq))),
        #("timestamp", Some(json.Int(ts))),
        #("type", Some(json.String("message"))),
        #("message", Some(encode_message(message))),
        #("terminate", encode_default_false(terminate)),
      ])
    CompactionEntry(
      id:,
      parent:,
      seq:,
      ts:,
      summary:,
      retained_tail:,
      tokens_before:,
      from_hook:,
      usage:,
    ) ->
      object_of([
        #("id", Some(encode_entry_id(id))),
        #("parentId", Some(encode_parent(parent))),
        #("seq", Some(json.Int(seq))),
        #("timestamp", Some(json.Int(ts))),
        #("type", Some(json.String("compaction"))),
        #("summary", Some(json.String(summary))),
        #(
          "retainedTail",
          Some(json.Array(list.map(retained_tail, encode_message))),
        ),
        #("tokensBefore", Some(json.Int(tokens_before))),
        #("fromHook", Some(json.Bool(from_hook))),
        #("usage", option.map(usage, encode_usage)),
      ])
    BranchSummaryEntry(
      id:,
      parent:,
      seq:,
      ts:,
      from_id:,
      summary:,
      from_hook:,
      usage:,
    ) ->
      object_of([
        #("id", Some(encode_entry_id(id))),
        #("parentId", Some(encode_parent(parent))),
        #("seq", Some(json.Int(seq))),
        #("timestamp", Some(json.Int(ts))),
        #("type", Some(json.String("branch_summary"))),
        #("fromId", Some(encode_entry_id(from_id))),
        #("summary", Some(json.String(summary))),
        #("fromHook", Some(json.Bool(from_hook))),
        #("usage", option.map(usage, encode_usage)),
      ])
    CustomEntry(id:, parent:, seq:, ts:, custom_type:, data:) ->
      object_of([
        #("id", Some(encode_entry_id(id))),
        #("parentId", Some(encode_parent(parent))),
        #("seq", Some(json.Int(seq))),
        #("timestamp", Some(json.Int(ts))),
        #("type", Some(json.String("custom"))),
        #("customType", Some(json.String(custom_type))),
        #("data", data),
      ])
  }
}

/// Decodes an `Entry`, dispatching on `type`. Total; unknown entry types
/// are corruption — the entry-type set is closed.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_entry(json.Null)
/// ```
///
pub fn decode_entry(value: JsonValue) -> Result(Entry, CorruptionReport) {
  let where = "core/codec.entry"
  use fields <- result.try(fields_of(value, where))
  use id <- result.try(require_entry_id(fields, "id", where))
  use parent <- result.try(decode_parent(fields, where))
  use seq <- result.try(require_int(fields, "seq", where))
  use ts <- result.try(require_int(fields, "timestamp", where))
  use kind <- result.try(require_string(fields, "type", where))
  case kind {
    "message" -> {
      use message_value <- result.try(require(fields, "message", where))
      use message <- result.try(decode_message(message_value))
      use terminate <- result.try(optional_bool(fields, "terminate", where))
      Ok(MessageEntry(
        id:,
        parent:,
        seq:,
        ts:,
        message:,
        terminate: option.unwrap(terminate, or: False),
      ))
    }
    "compaction" -> {
      use summary <- result.try(require_string(fields, "summary", where))
      use tail_items <- result.try(require_array(fields, "retainedTail", where))
      use retained_tail <- result.try(list.try_map(tail_items, decode_message))
      use tokens_before <- result.try(require_int(fields, "tokensBefore", where))
      use from_hook <- result.try(require_bool(fields, "fromHook", where))
      use usage <- result.try(decode_optional_usage(fields))
      Ok(CompactionEntry(
        id:,
        parent:,
        seq:,
        ts:,
        summary:,
        retained_tail:,
        tokens_before:,
        from_hook:,
        usage:,
      ))
    }
    "branch_summary" -> {
      use from_id <- result.try(require_entry_id(fields, "fromId", where))
      use summary <- result.try(require_string(fields, "summary", where))
      use from_hook <- result.try(require_bool(fields, "fromHook", where))
      use usage <- result.try(decode_optional_usage(fields))
      Ok(BranchSummaryEntry(
        id:,
        parent:,
        seq:,
        ts:,
        from_id:,
        summary:,
        from_hook:,
        usage:,
      ))
    }
    "custom" -> {
      use custom_type <- result.try(require_string(fields, "customType", where))
      let data = optional_json(fields, "data")
      Ok(CustomEntry(id:, parent:, seq:, ts:, custom_type:, data:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "type",
        expected: "message, compaction, branch_summary, or custom",
        context: other,
      ))
  }
}

fn encode_entry_id(id: EntryId) -> JsonValue {
  json.String(ids.entry_id_to_string(id))
}

fn encode_parent(parent: Option(EntryId)) -> JsonValue {
  case parent {
    Some(id) -> encode_entry_id(id)
    None -> json.Null
  }
}

fn decode_parent(
  fields: Fields,
  where: String,
) -> Result(Option(EntryId), CorruptionReport) {
  use value <- result.try(require(fields, "parentId", where))
  case value {
    json.Null -> Ok(None)
    json.String(text) -> result.map(ids.parse_entry_id(text), Some)
    other ->
      Error(corruption.report(
        at: where,
        on: "parentId",
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

fn decode_optional_usage(
  fields: Fields,
) -> Result(Option(Usage), CorruptionReport) {
  case optional_json(fields, "usage") {
    None | Some(json.Null) -> Ok(None)
    Some(value) -> result.map(decode_usage(value), Some)
  }
}

// --- usage rows ---------------------------------------------------------

/// Encodes a `UsageRow` in pi's wire shape.
///
/// ## Examples
///
/// ```gleam
/// let value = codec.encode_usage_row(row)
/// assert codec.decode_usage_row(value) == Ok(row)
/// ```
///
pub fn encode_usage_row(row: UsageRow) -> JsonValue {
  object_of([
    #("id", Some(json.String(ids.usage_id_to_string(row.id)))),
    #("seq", Some(json.Int(row.seq))),
    #(
      "entryId",
      option.map(row.entry_id, fn(id) {
        json.String(ids.entry_id_to_string(id))
      }),
    ),
    #("adjustment", Some(json.Bool(row.adjustment))),
    #("usage", Some(encode_usage(row.usage))),
    #("details", row.details),
  ])
}

/// Decodes a `UsageRow`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_usage_row(json.Int(3))
/// ```
///
pub fn decode_usage_row(
  value: JsonValue,
) -> Result(UsageRow, CorruptionReport) {
  let where = "core/codec.usage_row"
  use fields <- result.try(fields_of(value, where))
  use id_text <- result.try(require_string(fields, "id", where))
  use id <- result.try(ids.parse_usage_id(id_text))
  use seq <- result.try(require_int(fields, "seq", where))
  use entry_id <- result.try(case optional_json(fields, "entryId") {
    None | Some(json.Null) -> Ok(None)
    Some(json.String(text)) -> result.map(ids.parse_entry_id(text), Some)
    Some(other) ->
      Error(corruption.report(
        at: where,
        on: "entryId",
        expected: "an entry id string",
        context: json.to_string(other),
      ))
  })
  use adjustment <- result.try(require_bool(fields, "adjustment", where))
  use usage_value <- result.try(require(fields, "usage", where))
  use usage <- result.try(decode_usage(usage_value))
  let details = optional_json(fields, "details")
  Ok(UsageRow(id:, seq:, entry_id:, adjustment:, usage:, details:))
}

// --- register values ----------------------------------------------------

/// Encodes a `RegisterValue`: the payload itself, unchanged.
///
/// ## Examples
///
/// ```gleam
/// assert codec.encode_register_value(register.value(json.Int(1)))
///   == json.Int(1)
/// ```
///
pub fn encode_register_value(value: RegisterValue) -> JsonValue {
  value.payload
}

/// Decodes a `RegisterValue`: any `Json` payload is valid — interpreting
/// it belongs to the namespace's owning package.
///
/// ## Examples
///
/// ```gleam
/// assert codec.decode_register_value(json.Null)
///   == Ok(register.value(json.Null))
/// ```
///
pub fn decode_register_value(
  value: JsonValue,
) -> Result(RegisterValue, CorruptionReport) {
  Ok(RegisterValue(payload: value))
}

// --- corruption reports -------------------------------------------------

/// Encodes a `CorruptionReport` so failed decodes can themselves be stored
/// or transmitted safely.
///
/// ## Examples
///
/// ```gleam
/// let report = corruption.report(at: "b", on: "s", expected: "e", context: "c")
/// assert codec.decode_corruption_report(codec.encode_corruption_report(report))
///   == Ok(report)
/// ```
///
pub fn encode_corruption_report(report: CorruptionReport) -> JsonValue {
  json.Object([
    #("boundary", json.String(report.boundary)),
    #("subject", json.String(report.subject)),
    #("expected", json.String(report.expected)),
    #("context", json.String(report.context)),
  ])
}

/// Decodes a `CorruptionReport`. Total.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_corruption_report(json.Null)
/// ```
///
pub fn decode_corruption_report(
  value: JsonValue,
) -> Result(CorruptionReport, CorruptionReport) {
  let where = "core/codec.corruption_report"
  use fields <- result.try(fields_of(value, where))
  use boundary <- result.try(require_string(fields, "boundary", where))
  use subject <- result.try(require_string(fields, "subject", where))
  use expected <- result.try(require_string(fields, "expected", where))
  use context <- result.try(require_string(fields, "context", where))
  Ok(corruption.report(at: boundary, on: subject, expected:, context:))
}

// --- decoding helpers ---------------------------------------------------

type Fields =
  List(#(String, JsonValue))

// Builds an object from optional fields, omitting the `None`s. Encoders
// pass `Some` for required fields.
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

// `False` encodes as an omitted field, matching pi's `field?: true` shape.
fn encode_default_false(flag: Bool) -> Option(JsonValue) {
  case flag {
    True -> Some(json.Bool(True))
    False -> None
  }
}

fn fields_of(
  value: JsonValue,
  where: String,
) -> Result(Fields, CorruptionReport) {
  case value {
    json.Object(fields) -> Ok(fields)
    other ->
      Error(corruption.report(
        at: where,
        on: "value",
        expected: "an object",
        context: json.to_string(other),
      ))
  }
}

// First occurrence wins for duplicate keys, matching `core/json` policy.
fn get(fields: Fields, name: String) -> Result(JsonValue, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(field_name, value), ..] if field_name == name -> Ok(value)
    [_, ..rest] -> get(rest, name)
  }
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
        expected: "the field to be present",
        context: "absent",
      ))
  }
}

// Absent means `None`; a present `null` is kept, for opaque payloads.
fn optional_json(fields: Fields, name: String) -> Option(JsonValue) {
  case get(fields, name) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn as_string(
  value: JsonValue,
  name: String,
  where: String,
) -> Result(String, CorruptionReport) {
  case value {
    json.String(text) -> Ok(text)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
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
  as_string(value, name, where)
}

fn require_int(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.Int(number) -> Ok(number)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

// Accepts both number forms: `0` and `0.0` are the same wire cost.
fn require_float(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Float, CorruptionReport) {
  use value <- result.try(require(fields, name, where))
  case value {
    json.Float(number) -> Ok(number)
    json.Int(number) -> Ok(int.to_float(number))
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a number",
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
    json.Bool(flag) -> Ok(flag)
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
    json.Array(items) -> Ok(items)
    other ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an array",
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
    Ok(value) -> result.map(as_string(value, name, where), Some)
  }
}

fn optional_int(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Option(Int), CorruptionReport) {
  case get(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.Int(number)) -> Ok(Some(number))
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

fn optional_bool(
  fields: Fields,
  name: String,
  where: String,
) -> Result(Option(Bool), CorruptionReport) {
  case get(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.Bool(flag)) -> Ok(Some(flag))
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a boolean",
        context: json.to_string(other),
      ))
  }
}
