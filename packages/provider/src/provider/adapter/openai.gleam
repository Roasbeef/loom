//// The OpenAI-compatible chat-completions adapter.
////
//// Same shape as the Anthropic adapter, in the chat-completions dialect:
//// `build_request` produces a streaming `/chat/completions` request, and
//// `response_machine` folds the SSE stream — unnamed events whose `data:`
//// is a chunk JSON document, terminated by the literal `[DONE]` — into
//// deltas and one settled assistant message. Tool calls arrive as
//// `choices[0].delta.tool_calls` fragments carrying a provider-side
//// index; text and reasoning arrive as bare string fragments.
////
//// Normative behavior mirrors the Anthropic adapter: total
//// `finish_reason` mapping with unknown values settling as
//// `Failed(UnmappedStopReason)` in-band, and adapter-computed overflow
//// settling as `error` with the canonical overflow message. Usage is
//// extracted from the final usage chunk (`stream_options.include_usage`
//// is always requested): `prompt_tokens` covers the whole prompt, so the
//// cached halves are split back out of it — `cached_tokens` becomes
//// `cache_read`, `cache_write_tokens` becomes `cache_write`, and what
//// remains is `input`, which is the vocabulary the ledger shares with
//// the Anthropic adapter. Usage counters are
//// clamped into `[0, wire.max_usage_count]` at the read (see
//// `provider/internal/wire`'s module documentation), so no count an
//// untrusted proxy reports can ever reach a settled message the durable
//// planes cannot encode; beyond that range check the counters remain
//// provider-reported facts that steer accounting and overflow
//// classification only.
////
//// This dialect declares no cache breakpoints, and that is not an
//// omission: OpenAI-compatible prompt caching is automatic. The server
//// matches the rendered prefix by itself on any prompt over the model's
//// minimum, with no per-block marker to place and no request field to
//// set. What the adapter owes caching is therefore only prefix
//// stability, which it already has — the system prompt is emitted as the
//// first message, ahead of all history, and every field below it is
//// built in a fixed order from the request. The optional
//// `prompt_cache_key` routing hint is deliberately not sent: it wants a
//// stable per-session identifier, which no value in `ProviderRequest`
//// supplies, and inventing one here would be a guess rather than a
//// routing improvement.
////
//// The API key is accepted as an argument and written into one
//// `authorization` header; it is never stored in the accumulator, any
//// event, or any error (spec §3.3 invariant 4).

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type StopReason, type Usage, AssistantMessage,
  AssistantText, AssistantThinking, AssistantToolCall, CustomMessage, Errored,
  Length, Stop, ToolCall, ToolResultImage, ToolResultMessage, ToolResultText,
  ToolUse, Usage, UsageCost, UserImage, UserMessage, UserText,
}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/http.{type HttpRequest, HttpRequest}
import provider/internal/wire
import provider/model.{
  type ProviderRequest, type ResolvedModel, type ToolSpec, ThinkingHigh,
  ThinkingLow, ThinkingMedium, ThinkingOff,
}
import provider/retry
import provider/stream.{
  type ResponseMachine, type SseEvent, type StreamEvent, Delta, Failed,
  HttpError, MalformedStream, ResponseMachine, Settled, SseMalformed, SseMessage,
  StreamDisconnected, StreamError, TextDelta, ThinkingDelta, ToolCallDelta,
  UnmappedStopReason,
}

/// The `api` string stamped on assistant messages produced here.
pub const api_name = "openai-completions"

// Same negligible-output guard as the Anthropic adapter; see there.
const negligible_output_tokens = 64

// --- request construction -----------------------------------------------

/// Builds the streaming chat-completions request. `base_url` includes the
/// API root (e.g. `"https://api.openai.com/v1"`); the key flows into the
/// `authorization` header and nowhere else.
///
/// Thinking levels map to `reasoning_effort` `"low"` / `"medium"` /
/// `"high"`; `ThinkingOff` sends no reasoning field. Assistant thinking
/// blocks are not replayed — the chat-completions dialect has no
/// interoperable encrypted-reasoning replay — and `CustomMessage` values
/// are skipped as in the Anthropic adapter.
///
/// ## Examples
///
/// ```gleam
/// // openai.build_request(
/// //   base_url: "https://api.openai.com/v1",
/// //   api_key: key,
/// //   resolved: resolved,
/// //   request: request,
/// // ) // -> HttpRequest(method: "POST", url: ".../chat/completions", ..)
/// ```
///
pub fn build_request(
  base_url base_url: String,
  api_key api_key: String,
  resolved resolved: ResolvedModel,
  request request: ProviderRequest,
) -> HttpRequest {
  let max_tokens =
    option.unwrap(request.max_output_tokens, resolved.max_output_tokens)
  let reasoning_effort = case resolved.thinking {
    ThinkingOff -> None
    ThinkingLow -> Some("low")
    ThinkingMedium -> Some("medium")
    ThinkingHigh -> Some("high")
  }
  let body =
    json.Object(
      list.flatten([
        [
          #("model", json.String(resolved.model_id)),
          #("stream", json.Bool(True)),
          #(
            "stream_options",
            json.Object([#("include_usage", json.Bool(True))]),
          ),
          #("max_completion_tokens", json.Int(max_tokens)),
        ],
        case reasoning_effort {
          Some(effort) -> [#("reasoning_effort", json.String(effort))]
          None -> []
        },
        case request.tools {
          [] -> []
          tools -> [#("tools", json.Array(list.map(tools, encode_tool)))]
        },
        [#("messages", json.Array(encode_messages(request)))],
      ]),
    )
  HttpRequest(
    method: "POST",
    url: base_url <> "/chat/completions",
    headers: [
      #("authorization", "Bearer " <> api_key),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: json.to_string(body),
  )
}

fn encode_tool(tool: ToolSpec) -> JsonValue {
  json.Object([
    #("type", json.String("function")),
    #(
      "function",
      json.Object([
        #("name", json.String(tool.name)),
        #("description", json.String(tool.description)),
        #("parameters", tool.input_schema),
      ]),
    ),
  ])
}

fn encode_messages(request: ProviderRequest) -> List(JsonValue) {
  let system = case request.system {
    Some(system) -> [
      json.Object([
        #("role", json.String("system")),
        #("content", json.String(system)),
      ]),
    ]
    None -> []
  }
  list.append(system, list.filter_map(request.messages, encode_message))
}

fn encode_message(message: AgentMessage) -> Result(JsonValue, Nil) {
  case message {
    UserMessage(content:, timestamp: _) ->
      Ok(
        json.Object([
          #("role", json.String("user")),
          #("content", json.Array(list.map(content, encode_user_block))),
        ]),
      )
    AssistantMessage(content:, ..) -> {
      let text =
        content
        |> list.filter_map(assistant_text_block)
        |> string.concat
      let tool_calls = list.filter_map(content, assistant_tool_call_block)
      Ok(
        json.Object(
          list.flatten([
            [#("role", json.String("assistant"))],
            // "Either content or tool_calls, but never neither": an
            // all-tool-call turn sends null content.
            case text, tool_calls {
              "", [_, ..] -> [#("content", json.Null)]
              _, _ -> [#("content", json.String(text))]
            },
            case tool_calls {
              [] -> []
              calls -> [#("tool_calls", json.Array(calls))]
            },
          ]),
        ),
      )
    }
    ToolResultMessage(tool_call_id:, content:, is_error: _, ..) ->
      Ok(
        json.Object([
          #("role", json.String("tool")),
          #("tool_call_id", json.String(tool_call_id)),
          #(
            "content",
            json.String(
              content
              |> list.filter_map(tool_result_text_block)
              |> string.concat,
            ),
          ),
        ]),
      )
    CustomMessage(schema: _, payload: _) -> Error(Nil)
  }
}

fn assistant_text_block(block: message.AssistantBlock) -> Result(String, Nil) {
  case block {
    AssistantText(text:, text_signature: _) -> Ok(text)
    _ -> Error(Nil)
  }
}

fn assistant_tool_call_block(
  block: message.AssistantBlock,
) -> Result(JsonValue, Nil) {
  case block {
    AssistantToolCall(call:) -> Ok(encode_tool_call(call))
    _ -> Error(Nil)
  }
}

fn tool_result_text_block(
  block: message.ToolResultBlock,
) -> Result(String, Nil) {
  case block {
    ToolResultText(text:, text_signature: _) -> Ok(text)
    ToolResultImage(data: _, mime_type: _) -> Error(Nil)
  }
}

fn encode_tool_call(call: message.ToolCall) -> JsonValue {
  let ToolCall(id:, name:, arguments:, thought_signature: _, namespace: _) =
    call
  json.Object([
    #("id", json.String(id)),
    #("type", json.String("function")),
    #(
      "function",
      json.Object([
        #("name", json.String(name)),
        #("arguments", json.String(json.to_string(arguments))),
      ]),
    ),
  ])
}

fn encode_user_block(block: message.UserBlock) -> JsonValue {
  case block {
    UserText(text:, text_signature: _) ->
      json.Object([#("type", json.String("text")), #("text", json.String(text))])
    UserImage(data:, mime_type:) ->
      json.Object([
        #("type", json.String("image_url")),
        #(
          "image_url",
          json.Object([
            #("url", json.String("data:" <> mime_type <> ";base64," <> data)),
          ]),
        ),
      ])
  }
}

// --- stop-reason mapping ------------------------------------------------

/// Maps a raw `finish_reason` to the harness vocabulary. Total over known
/// values; `Error(Nil)` for unknown values, which the caller surfaces as
/// `Failed(UnmappedStopReason)` — never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert openai.map_finish_reason("tool_calls")
///   == Ok(#(message.ToolUse, option.None))
/// ```
///
/// ```gleam
/// assert openai.map_finish_reason("novel_reason") == Error(Nil)
/// ```
///
pub fn map_finish_reason(
  raw: String,
) -> Result(#(StopReason, Option(String)), Nil) {
  case raw {
    "stop" -> Ok(#(Stop, None))
    "length" -> Ok(#(Length, None))
    "tool_calls" -> Ok(#(ToolUse, None))
    // The legacy function-calling dialect some proxies still emit.
    "function_call" -> Ok(#(ToolUse, None))
    "content_filter" ->
      Ok(#(Errored, Some("provider finish_reason: content_filter")))
    _ -> Error(Nil)
  }
}

// --- response accumulation ----------------------------------------------

/// The pure streamed-response state for one chat-completions attempt.
pub opaque type Accumulator {
  /// Invariants: `blocks` is in reverse arrival order and each block's
  /// `index` is its synthetic arrival position; `status` is 0 until the
  /// response status arrives; once `done` is `True` no further event
  /// changes anything.
  Accumulator(
    resolved: ResolvedModel,
    now: Int,
    status: Int,
    retry_after_ms: Option(Int),
    error_body: BitArray,
    sse: stream.SseParser,
    blocks: List(OaBlock),
    prompt_tokens: Int,
    completion_tokens: Int,
    cached_tokens: Int,
    cache_write_tokens: Int,
    total_tokens: Option(Int),
    reasoning_tokens: Option(Int),
    stop: Option(StopReason),
    raw_stop: Option(String),
    error_message: Option(String),
    response_id: Option(String),
    response_model: Option(String),
    done: Bool,
  )
}

// Blocks carry a synthetic index — the arrival position — because the
// chat-completions dialect has no content-block indices of its own.
// Tool calls additionally remember the provider's tool_calls index for
// fragment routing.
type OaBlock {
  OaText(index: Int, text: String)
  OaThinking(index: Int, thinking: String)
  OaTool(
    index: Int,
    provider_index: Int,
    call_id: String,
    name: String,
    arguments_json: String,
  )
}

/// The response machine for one chat-completions request attempt. `now`
/// is the Unix-ms timestamp stamped on the settled assistant message.
///
/// ## Examples
///
/// ```gleam
/// // let machine = openai.response_machine(resolved, now: 1000)
/// // stream.run(transport, request, machine, deliver, within: 300_000)
/// ```
///
pub fn response_machine(
  resolved: ResolvedModel,
  now now: Int,
) -> ResponseMachine(Accumulator) {
  ResponseMachine(
    init: Accumulator(
      resolved:,
      now:,
      status: 0,
      retry_after_ms: None,
      error_body: <<>>,
      sse: stream.new_parser(),
      blocks: [],
      prompt_tokens: 0,
      completion_tokens: 0,
      cached_tokens: 0,
      cache_write_tokens: 0,
      total_tokens: None,
      reasoning_tokens: None,
      stop: None,
      raw_stop: None,
      error_message: None,
      response_id: None,
      response_model: None,
      done: False,
    ),
    on_status: fn(acc, status, headers) {
      Accumulator(..acc, status:, retry_after_ms: wire.retry_after_ms(headers))
    },
    on_chunk: on_chunk,
    on_end: on_end,
    on_failure: fn(acc, reason) {
      case acc.done {
        True -> []
        False -> [Failed(stream.TransportFailed(reason:))]
      }
    },
  )
}

fn on_chunk(
  acc: Accumulator,
  chunk: BitArray,
) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(when: acc.done, return: #(acc, []))
  case acc.status {
    200 -> {
      let #(sse, sse_events) = stream.feed(acc.sse, chunk)
      let acc = Accumulator(..acc, sse:)
      list.fold(sse_events, #(acc, []), fn(folded, sse_event) {
        let #(acc, events) = folded
        let #(acc, new_events) = handle_sse(acc, sse_event)
        #(acc, list.append(events, new_events))
      })
    }
    _ -> #(
      Accumulator(..acc, error_body: bit_array.append(acc.error_body, chunk)),
      [],
    )
  }
}

fn on_end(acc: Accumulator) -> List(StreamEvent) {
  use <- bool.guard(when: acc.done, return: [])
  case acc.status {
    200 -> settle_or_disconnect(acc)
    status -> [Failed(http_error(status, acc))]
  }
}

// Some compatible providers end the stream without a `[DONE]` sentinel;
// a recorded finish_reason still settles the response.
fn settle_or_disconnect(acc: Accumulator) -> List(StreamEvent) {
  case acc.stop {
    Some(_) -> settle(acc).1
    None -> [
      Failed(StreamDisconnected(
        context: "response body ended before a finish_reason",
      )),
    ]
  }
}

// Parses the collected error body — `{"error":{"message","type","code"}}`
// — into a redacted HttpError.
fn http_error(status: Int, acc: Accumulator) -> stream.ProviderError {
  let body_text = result.unwrap(bit_array.to_string(acc.error_body), "")
  let error_field =
    json.parse(body_text)
    |> result.replace_error(Nil)
    |> result.try(wire.field(_, "error"))
  case error_field {
    Ok(error) ->
      HttpError(
        status:,
        api_error_type: result.unwrap(
          wire.string_field(error, "type"),
          or: wire.string_field_or(error, "code", or: ""),
        ),
        message: wire.string_field_or(error, "message", or: ""),
        retry_after_ms: acc.retry_after_ms,
      )
    Error(Nil) ->
      HttpError(
        status:,
        api_error_type: "",
        message: excerpt(body_text),
        retry_after_ms: acc.retry_after_ms,
      )
  }
}

fn excerpt(text: String) -> String {
  case string.length(text) > 400 {
    True -> string.slice(text, 0, 400) <> "…"
    False -> text
  }
}

fn handle_sse(
  acc: Accumulator,
  event: SseEvent,
) -> #(Accumulator, List(StreamEvent)) {
  case event {
    SseMalformed(reason:) ->
      fail(acc, MalformedStream(corruption_report("a utf-8 sse line", reason)))
    SseMessage(event: _, data: "[DONE]") -> settle(acc)
    SseMessage(event: _, data:) -> handle_sse_data(acc, data)
  }
}

fn handle_sse_data(
  acc: Accumulator,
  data: String,
) -> #(Accumulator, List(StreamEvent)) {
  use document <- or_fail(json.parse(data), acc, MalformedStream)
  handle_document(acc, document)
}

// A chunk document carrying its own `error` field is how some
// compatible proxies report a mid-stream failure (rather than an
// out-of-band `error` SSE event, which this dialect does not define).
fn handle_document(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case wire.field(document, "error") {
    Ok(error) ->
      fail(
        acc,
        StreamError(
          api_error_type: wire.string_field_or(error, "type", or: ""),
          message: wire.string_field_or(error, "message", or: ""),
        ),
      )
    Error(Nil) -> handle_chunk_document(acc, document)
  }
}

fn corruption_report(expected: String, context: String) -> CorruptionReport {
  corruption.report(
    at: "provider/adapter/openai",
    on: "provider stream",
    expected:,
    context:,
  )
}

fn handle_chunk_document(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let acc =
    Accumulator(
      ..acc,
      response_id: option.or(
        option.from_result(wire.string_field(document, "id")),
        acc.response_id,
      ),
      response_model: option.or(
        option.from_result(wire.string_field(document, "model")),
        acc.response_model,
      ),
    )
  let acc = case wire.field(document, "usage") {
    Ok(usage) -> extract_usage(acc, usage)
    Error(Nil) -> acc
  }
  case wire.array_field(document, "choices") {
    Ok([choice, ..]) -> handle_choice(acc, choice)
    _ -> #(acc, [])
  }
}

// Every count defaults to the accumulator's current value, never to zero,
// so a later chunk carrying a partial usage object cannot erase counts an
// earlier chunk already reported (mirrors the Anthropic adapter's
// handle_message_start).
fn extract_usage(acc: Accumulator, usage: JsonValue) -> Accumulator {
  Accumulator(
    ..acc,
    prompt_tokens: wire.count_field_or(
      usage,
      "prompt_tokens",
      or: acc.prompt_tokens,
    ),
    completion_tokens: wire.count_field_or(
      usage,
      "completion_tokens",
      or: acc.completion_tokens,
    ),
    total_tokens: option.or(
      wire.optional_count_field(usage, "total_tokens"),
      acc.total_tokens,
    ),
    cached_tokens: nested_count_or(
      usage,
      "prompt_tokens_details",
      "cached_tokens",
      acc.cached_tokens,
    ),
    // Endpoints that report no cache-write count leave this at zero,
    // which is the honest reading: nothing was reported.
    cache_write_tokens: nested_count_or(
      usage,
      "prompt_tokens_details",
      "cache_write_tokens",
      acc.cache_write_tokens,
    ),
    reasoning_tokens: nested_optional_count(
      usage,
      "completion_tokens_details",
      "reasoning_tokens",
      acc.reasoning_tokens,
    ),
  )
}

// Reads a counter nested one object down (`usage.prompt_tokens_details.
// cached_tokens`), defaulting to `previous` when either level is absent —
// mirrors the flat counters above, which default to the accumulator
// rather than to zero.
fn nested_count_or(
  document: JsonValue,
  field: String,
  key: String,
  previous: Int,
) -> Int {
  case wire.field(document, field) {
    Ok(nested) -> wire.count_field_or(nested, key, or: previous)
    Error(Nil) -> previous
  }
}

// The `Option`-valued sibling of `nested_count_or`, for counters with no
// natural zero default (reasoning tokens: absent means "not reported",
// not "reported as zero").
fn nested_optional_count(
  document: JsonValue,
  field: String,
  key: String,
  previous: Option(Int),
) -> Option(Int) {
  case wire.field(document, field) {
    Ok(nested) -> option.or(wire.optional_count_field(nested, key), previous)
    Error(Nil) -> previous
  }
}

fn handle_choice(
  acc: Accumulator,
  choice: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let finish = wire.string_field(choice, "finish_reason")
  let #(acc, events) = case wire.field(choice, "delta") {
    Ok(delta) -> handle_delta(acc, delta)
    Error(Nil) -> #(acc, [])
  }
  case events, finish {
    // A failure emitted by the delta handler wins; drop the finish.
    [Failed(..), ..], _ -> #(acc, events)
    _, Error(Nil) -> #(acc, events)
    _, Ok(raw) -> apply_finish_reason(acc, raw, events)
  }
}

fn apply_finish_reason(
  acc: Accumulator,
  raw: String,
  events: List(StreamEvent),
) -> #(Accumulator, List(StreamEvent)) {
  case map_finish_reason(raw) {
    Ok(#(stop, error_message)) -> #(
      Accumulator(
        ..acc,
        stop: Some(stop),
        raw_stop: Some(raw),
        error_message: option.or(error_message, acc.error_message),
      ),
      events,
    )
    Error(Nil) -> {
      let #(acc, failure) = fail(acc, UnmappedStopReason(raw:))
      #(acc, list.append(events, failure))
    }
  }
}

fn handle_delta(
  acc: Accumulator,
  delta: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let #(acc, text_events) = case wire.string_field(delta, "content") {
    Ok("") | Error(Nil) -> #(acc, [])
    Ok(text) -> append_text(acc, text)
  }
  // Reasoning arrives under `reasoning_content` (DeepSeek and most
  // compatible servers) or `reasoning` (OpenRouter).
  let reasoning = case wire.string_field(delta, "reasoning_content") {
    Ok(thinking) -> Ok(thinking)
    Error(Nil) -> wire.string_field(delta, "reasoning")
  }
  let #(acc, thinking_events) = case reasoning {
    Ok("") | Error(Nil) -> #(acc, [])
    Ok(thinking) -> append_thinking(acc, thinking)
  }
  let #(acc, tool_events) = case wire.array_field(delta, "tool_calls") {
    Ok(fragments) ->
      list.fold(fragments, #(acc, []), fn(folded, fragment) {
        let #(acc, events) = folded
        let #(acc, new_events) = append_tool_fragment(acc, fragment)
        #(acc, list.append(events, new_events))
      })
    Error(Nil) -> #(acc, [])
  }
  #(acc, list.flatten([text_events, thinking_events, tool_events]))
}

fn append_text(
  acc: Accumulator,
  text: String,
) -> #(Accumulator, List(StreamEvent)) {
  case find_text(acc.blocks) {
    Ok(index) -> {
      let blocks = list.map(acc.blocks, update_text_block(_, index, text))
      #(Accumulator(..acc, blocks:), [Delta(TextDelta(index:, text:))])
    }
    Error(Nil) -> {
      let index = list.length(acc.blocks)
      #(Accumulator(..acc, blocks: [OaText(index:, text:), ..acc.blocks]), [
        Delta(TextDelta(index:, text:)),
      ])
    }
  }
}

fn update_text_block(block: OaBlock, index: Int, text: String) -> OaBlock {
  case block {
    OaText(index: i, text: so_far) if i == index ->
      OaText(index: i, text: so_far <> text)
    other -> other
  }
}

fn find_text(blocks: List(OaBlock)) -> Result(Int, Nil) {
  case blocks {
    [] -> Error(Nil)
    [OaText(index:, text: _), ..] -> Ok(index)
    [_, ..rest] -> find_text(rest)
  }
}

fn append_thinking(
  acc: Accumulator,
  thinking: String,
) -> #(Accumulator, List(StreamEvent)) {
  case find_thinking(acc.blocks) {
    Ok(index) -> {
      let blocks =
        list.map(acc.blocks, update_thinking_block(_, index, thinking))
      #(Accumulator(..acc, blocks:), [Delta(ThinkingDelta(index:, thinking:))])
    }
    Error(Nil) -> {
      let index = list.length(acc.blocks)
      #(
        Accumulator(..acc, blocks: [OaThinking(index:, thinking:), ..acc.blocks]),
        [Delta(ThinkingDelta(index:, thinking:))],
      )
    }
  }
}

fn update_thinking_block(
  block: OaBlock,
  index: Int,
  thinking: String,
) -> OaBlock {
  case block {
    OaThinking(index: i, thinking: so_far) if i == index ->
      OaThinking(index: i, thinking: so_far <> thinking)
    other -> other
  }
}

fn find_thinking(blocks: List(OaBlock)) -> Result(Int, Nil) {
  case blocks {
    [] -> Error(Nil)
    [OaThinking(index:, thinking: _), ..] -> Ok(index)
    [_, ..rest] -> find_thinking(rest)
  }
}

fn append_tool_fragment(
  acc: Accumulator,
  fragment: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let provider_index = wire.int_field_or(fragment, "index", or: 0)
  let call_id = option.from_result(wire.string_field(fragment, "id"))
  let function =
    result.unwrap(wire.field(fragment, "function"), json.Object([]))
  let name = option.from_result(wire.string_field(function, "name"))
  let arguments = wire.string_field_or(function, "arguments", or: "")
  case find_tool(acc.blocks, provider_index) {
    Ok(#(index, existing_id, existing_name)) -> {
      let call_id = option.unwrap(call_id, existing_id)
      let name = option.unwrap(name, existing_name)
      let blocks =
        list.map(acc.blocks, update_tool_block(
          _,
          index,
          call_id,
          name,
          arguments,
        ))
      #(Accumulator(..acc, blocks:), [
        Delta(ToolCallDelta(index:, call_id:, name:, arguments_json: arguments)),
      ])
    }
    Error(Nil) -> {
      let index = list.length(acc.blocks)
      let call_id = option.unwrap(call_id, "")
      let name = option.unwrap(name, "")
      #(
        Accumulator(..acc, blocks: [
          OaTool(
            index:,
            provider_index:,
            call_id:,
            name:,
            arguments_json: arguments,
          ),
          ..acc.blocks
        ]),
        [
          Delta(ToolCallDelta(
            index:,
            call_id:,
            name:,
            arguments_json: arguments,
          )),
        ],
      )
    }
  }
}

fn update_tool_block(
  block: OaBlock,
  index: Int,
  call_id: String,
  name: String,
  arguments: String,
) -> OaBlock {
  case block {
    OaTool(index: i, provider_index: p, arguments_json:, ..) if i == index ->
      OaTool(
        index: i,
        provider_index: p,
        call_id:,
        name:,
        arguments_json: arguments_json <> arguments,
      )
    other -> other
  }
}

fn find_tool(
  blocks: List(OaBlock),
  provider_index: Int,
) -> Result(#(Int, String, String), Nil) {
  case blocks {
    [] -> Error(Nil)
    [OaTool(index:, provider_index: p, call_id:, name:, arguments_json: _), ..]
      if p == provider_index
    -> Ok(#(index, call_id, name))
    [_, ..rest] -> find_tool(rest, provider_index)
  }
}

// --- settlement ---------------------------------------------------------

fn settle(acc: Accumulator) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(when: acc.done, return: #(acc, []))
  case acc.stop {
    None ->
      fail(
        acc,
        StreamDisconnected(context: "stream ended without a finish_reason"),
      )
    Some(stop) -> settle_with_stop(acc, stop)
  }
}

fn settle_with_stop(
  acc: Accumulator,
  stop: StopReason,
) -> #(Accumulator, List(StreamEvent)) {
  use content <- or_fail(
    build_blocks(list.reverse(acc.blocks), []),
    acc,
    MalformedStream,
  )
  let usage = build_usage(acc)
  // Spec §1.5 words this as input plus cache-read, from before either
  // adapter reported a cache *write*. The quantity it names is the whole
  // prompt, so the write half belongs in the sum too; with nothing
  // cached the three terms collapse to the spec's two.
  let input_tokens = usage.input + usage.cache_read + usage.cache_write
  let overflowed =
    input_tokens > acc.resolved.context_window
    && usage.output <= negligible_output_tokens
  let #(stop, error_message) = case overflowed {
    True -> #(
      Errored,
      Some(retry.overflow_message(
        input_tokens:,
        context_window: acc.resolved.context_window,
      )),
    )
    False -> #(stop, acc.error_message)
  }
  let assistant =
    AssistantMessage(
      content:,
      api: api_name,
      provider: acc.resolved.provider,
      model: acc.resolved.model_id,
      response_model: acc.response_model,
      response_id: acc.response_id,
      diagnostics: None,
      usage:,
      stop_reason: stop,
      deferred: None,
      error_message:,
      raw_stop_reason: acc.raw_stop,
      end_turn: option.map(acc.raw_stop, fn(raw) { raw == "stop" }),
      timestamp: acc.now,
    )
  // Unreachable by construction (the stop reason above is never
  // Pending), reported totally rather than asserted.
  use settled <- or_fail(stream.settle(assistant), acc, fn(_nil) {
    MalformedStream(corruption_report(
      "a settled assistant message",
      "stop reason pending at [DONE]",
    ))
  })
  #(Accumulator(..acc, done: True), [Settled(message: settled, usage:)])
}

// The settlement combinator: run `then` on success, or fail the stream
// with `to_error(err)` — the adapter's counterpart to `machine/planner`'s
// `or_fault`, for the handful of settlement steps that must end the
// stream in-band rather than propagate a bare `Result`.
fn or_fail(
  result: Result(a, e),
  acc: Accumulator,
  to_error: fn(e) -> stream.ProviderError,
  then: fn(a) -> #(Accumulator, List(StreamEvent)),
) -> #(Accumulator, List(StreamEvent)) {
  case result {
    Error(err) -> fail(acc, to_error(err))
    Ok(value) -> then(value)
  }
}

fn build_blocks(
  blocks: List(OaBlock),
  built: List(message.AssistantBlock),
) -> Result(List(message.AssistantBlock), CorruptionReport) {
  case blocks {
    [] -> Ok(list.reverse(built))
    [OaText(index: _, text:), ..rest] ->
      build_blocks(rest, [AssistantText(text:, text_signature: None), ..built])
    [OaThinking(index: _, thinking:), ..rest] ->
      build_blocks(rest, [
        AssistantThinking(thinking:, thinking_signature: None, redacted: False),
        ..built
      ])
    [
      OaTool(index: _, provider_index: _, call_id:, name:, arguments_json:),
      ..rest
    ] -> {
      let parsed = case arguments_json {
        "" -> Ok(json.Object([]))
        _ -> json.parse(arguments_json)
      }
      use arguments <- result.try(parsed)
      build_blocks(rest, [
        AssistantToolCall(call: ToolCall(
          id: call_id,
          name:,
          arguments:,
          thought_signature: None,
          namespace: None,
        )),
        ..built
      ])
    }
  }
}

fn build_usage(acc: Accumulator) -> Usage {
  // `prompt_tokens` is the whole prompt, cached reads and cache writes
  // included; split both out so the ledger's vocabulary (`input` = tokens
  // neither read from nor written to cache) holds across adapters. The
  // clamps keep `input` non-negative whatever a proxy reports, and keep
  // `input + cache_read + cache_write` equal to `prompt_tokens`, which is
  // what makes the total below add up.
  let cache_read = int.min(acc.cached_tokens, acc.prompt_tokens)
  let cache_write =
    int.min(acc.cache_write_tokens, acc.prompt_tokens - cache_read)
  let input = acc.prompt_tokens - cache_read - cache_write
  Usage(
    input:,
    output: acc.completion_tokens,
    cache_read:,
    cache_write:,
    // The chat-completions dialect has one cache lifetime and reports no
    // per-TTL breakdown, so there is no one-hour subset to name.
    cache_write_1h: None,
    reasoning: acc.reasoning_tokens,
    total_tokens: option.unwrap(
      acc.total_tokens,
      acc.prompt_tokens + acc.completion_tokens,
    ),
    cost: UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

fn fail(
  acc: Accumulator,
  error: stream.ProviderError,
) -> #(Accumulator, List(StreamEvent)) {
  case acc.done {
    True -> #(acc, [])
    False -> #(Accumulator(..acc, done: True), [Failed(error:)])
  }
}
