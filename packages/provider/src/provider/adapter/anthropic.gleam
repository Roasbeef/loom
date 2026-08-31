//// The Anthropic Messages API adapter.
////
//// Two pure halves: `build_request` translates a provider-neutral
//// `ProviderRequest` into the Messages API wire dialect, and
//// `response_machine` folds the streamed response — SSE events
//// `message_start`, `content_block_start`, `content_block_delta`,
//// `content_block_stop`, `message_delta`, `message_stop`, `error`, and
//// `ping` — into deltas and one settled assistant message.
////
//// Normative behavior (spec §1.5):
////
//// - Stop reasons map **totally**: a stop reason this adapter does not
////   know settles the stream as `Failed(UnmappedStopReason)` in-band,
////   never a crash.
//// - Adapter-computable overflow — `usage.input + usage.cache_read`
////   exceeding the resolved context window with negligible output —
////   settles as stop reason `error` with the canonical overflow message
////   (`retry.overflow_message`), preserving the raw stop reason.
////
//// Decoding posture: SSE `data:` payloads must parse as JSON (malformed
//// data fails the stream in-band as `MalformedStream`), while *fields*
//// are read with pi's leniency — absent usage counters read as zero,
//// unknown event and delta types are ignored as the Messages API
//// versioning policy prescribes for forward compatibility. Usage
//// counters are additionally clamped into `[0, wire.max_usage_count]`
//// at the read (see `provider/internal/wire`'s module documentation),
//// so no count an untrusted proxy reports can ever reach a settled
//// message the durable planes cannot encode. The counters remain
//// provider-reported facts beyond that range check: they steer usage
//// accounting and the overflow classification below, never any
//// security decision, so a lying proxy can at worst waste a
//// compact-and-retry cycle — no worse than the failure it could inject
//// directly.
////
//// Requests carry prompt-cache breakpoints. Placement is deterministic
//// and needs no per-request configuration; the reasoning, the price
//// arithmetic, and what a history rewrite costs are written out under
//// "prompt caching" below.
////
//// The API key is accepted as an argument and written into one request
//// header; it is never stored in the accumulator, any event, or any
//// error (spec §3.3 invariant 4).

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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/http.{type HttpRequest, HttpRequest}
import provider/internal/diagnostic
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
pub const api_name = "anthropic-messages"

// Output at or below this token count is "negligible" for the overflow
// computation: a response this short cannot be a substantive answer that
// merely tripped a counter (spec §1.5 requires the negligible-output
// guard so real answers are never discarded as overflow).
const negligible_output_tokens = 64

// --- request construction -----------------------------------------------

/// Builds the streaming Messages API request. The API key flows into the
/// `x-api-key` header and nowhere else.
///
/// Thinking levels map to `thinking.budget_tokens` 2048 / 8192 / 16384
/// (low / medium / high); `ThinkingOff` sends no thinking field.
/// `CustomMessage` values are skipped — projection owns their meaning —
/// and consecutive same-role turns (tool results in particular) merge
/// into one wire message as the API requires.
///
/// Four prompt-cache breakpoints ride along on every request: two
/// one-hour ones on the session-stable head (the tool array and the
/// system prompt) and two five-minute ones rolling along the tail (the
/// last block of each of the final two user turns). See the "prompt
/// caching" section below for why those four positions and those two
/// lifetimes.
///
/// ## Examples
///
/// ```gleam
/// // anthropic.build_request(
/// //   base_url: "https://api.anthropic.com",
/// //   api_key: key,
/// //   resolved: resolved,
/// //   request: request,
/// // ) // -> HttpRequest(method: "POST", url: ".../v1/messages", ..)
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
  let thinking = case resolved.thinking {
    ThinkingOff -> None
    ThinkingLow -> Some(2048)
    ThinkingMedium -> Some(8192)
    ThinkingHigh -> Some(16_384)
  }
  let body =
    json.Object(
      list.flatten([
        [
          #("model", json.String(resolved.model_id)),
          #("max_tokens", json.Int(max_tokens)),
          #("stream", json.Bool(True)),
        ],
        case request.system {
          Some(system) -> [#("system", encode_system(system))]
          None -> []
        },
        case thinking {
          Some(budget) -> [
            #(
              "thinking",
              json.Object([
                #("type", json.String("enabled")),
                #("budget_tokens", json.Int(budget)),
              ]),
            ),
          ]
          None -> []
        },
        case request.tools {
          [] -> []
          tools -> [#("tools", encode_tools(tools))]
        },
        [#("messages", json.Array(encode_messages(request.messages)))],
      ]),
    )
  HttpRequest(
    method: "POST",
    url: base_url <> "/v1/messages",
    headers: [
      #("x-api-key", api_key),
      #("anthropic-version", "2023-06-01"),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: json.to_string(body),
  )
}

fn encode_tool(tool: ToolSpec) -> JsonValue {
  json.Object([
    #("name", json.String(tool.name)),
    #("description", json.String(tool.description)),
    #("input_schema", tool.input_schema),
  ])
}

// Converts to wire turns and merges consecutive same-role turns; the
// Messages API requires tool results in the user turn that follows the
// calling assistant turn, and merging makes consecutive `ToolResult`
// messages one such turn.
fn encode_messages(messages: List(AgentMessage)) -> List(JsonValue) {
  messages
  |> list.filter_map(to_turn)
  |> merge_turns([])
  |> mark_tail_user_turns
  |> list.map(fn(turn) {
    let #(role, blocks) = turn
    json.Object([
      #("role", json.String(role)),
      #("content", json.Array(blocks)),
    ])
  })
}

fn to_turn(message: AgentMessage) -> Result(#(String, List(JsonValue)), Nil) {
  case message {
    UserMessage(content:, timestamp: _) ->
      Ok(#("user", list.map(content, encode_user_block)))
    AssistantMessage(content:, ..) ->
      Ok(#("assistant", list.filter_map(content, encode_assistant_block)))
    ToolResultMessage(
      tool_call_id:,
      content:,
      is_error:,
      tool_name: _,
      details: _,
      usage: _,
      added_tool_names: _,
      timestamp: _,
    ) ->
      Ok(
        #("user", [
          json.Object([
            #("type", json.String("tool_result")),
            #("tool_use_id", json.String(tool_call_id)),
            #(
              "content",
              json.Array(list.map(content, encode_tool_result_block)),
            ),
            #("is_error", json.Bool(is_error)),
          ]),
        ]),
      )
    // Custom messages are an application extension point; projection
    // renders them into user/assistant content before requests are built.
    CustomMessage(schema: _, payload: _) -> Error(Nil)
  }
}

fn merge_turns(
  turns: List(#(String, List(JsonValue))),
  merged: List(#(String, List(JsonValue))),
) -> List(#(String, List(JsonValue))) {
  case turns, merged {
    [], _ -> list.reverse(merged)
    [#(role, blocks), ..rest], [#(previous_role, previous_blocks), ..earlier]
      if role == previous_role
    ->
      merge_turns(rest, [
        #(role, list.append(previous_blocks, blocks)),
        ..earlier
      ])
    [turn, ..rest], _ -> merge_turns(rest, [turn, ..merged])
  }
}

fn encode_user_block(block: message.UserBlock) -> JsonValue {
  case block {
    UserText(text:, text_signature: _) ->
      json.Object([#("type", json.String("text")), #("text", json.String(text))])
    UserImage(data:, mime_type:) -> encode_image(data, mime_type)
  }
}

fn encode_image(data: String, mime_type: String) -> JsonValue {
  json.Object([
    #("type", json.String("image")),
    #(
      "source",
      json.Object([
        #("type", json.String("base64")),
        #("media_type", json.String(mime_type)),
        #("data", json.String(data)),
      ]),
    ),
  ])
}

fn encode_assistant_block(
  block: message.AssistantBlock,
) -> Result(JsonValue, Nil) {
  case block {
    // The API rejects empty text blocks, so they are dropped on replay.
    AssistantText(text: "", text_signature: _) -> Error(Nil)
    AssistantText(text:, text_signature: _) ->
      Ok(
        json.Object([
          #("type", json.String("text")),
          #("text", json.String(text)),
        ]),
      )
    AssistantThinking(thinking: _, thinking_signature:, redacted: True) ->
      Ok(
        json.Object([
          #("type", json.String("redacted_thinking")),
          #("data", json.String(option.unwrap(thinking_signature, ""))),
        ]),
      )
    AssistantThinking(thinking:, thinking_signature:, redacted: False) ->
      Ok(
        json.Object([
          #("type", json.String("thinking")),
          #("thinking", json.String(thinking)),
          #("signature", json.String(option.unwrap(thinking_signature, ""))),
        ]),
      )
    AssistantToolCall(call: ToolCall(
      id:,
      name:,
      arguments:,
      thought_signature: _,
      namespace: _,
    )) ->
      Ok(
        json.Object([
          #("type", json.String("tool_use")),
          #("id", json.String(id)),
          #("name", json.String(name)),
          #("input", arguments),
        ]),
      )
  }
}

fn encode_tool_result_block(block: message.ToolResultBlock) -> JsonValue {
  case block {
    ToolResultText(text:, text_signature: _) ->
      json.Object([#("type", json.String("text")), #("text", json.String(text))])
    ToolResultImage(data:, mime_type:) -> encode_image(data, mime_type)
  }
}

// --- prompt caching -----------------------------------------------------
//
// The Messages API caches by exact byte prefix over the render order
// `tools` -> `system` -> `messages`. A `cache_control` marker names a
// position; a later request whose bytes match up to that position reads
// the prefix at a tenth of the input price instead of paying for it
// again. The bytes *are* the key, so nothing here can serve a stale
// prefix and there is no invalidation to perform — placement is purely a
// cost decision, and the four positions below are the ones this
// harness's traffic shape argues for. Four is also the API's ceiling on
// breakpoints per request, so all four are spent, deterministically, on
// every request.
//
// **The head is the stable half.** Tool definitions and the system
// prompt render ahead of every message and change at most once a
// session, so they are the natural constant, and they take the one-hour
// lifetime: a write there costs 2x base input rather than 1.25x, but it
// is read on every turn for the rest of the session, and an hour of
// shelf life survives the minutes a human spends reading a diff — the
// gap that would otherwise expire a five-minute entry and re-charge the
// whole head at full price. Two breakpoints rather than one, because
// tools render first: a system prompt that does move still leaves the
// tool array cached behind its own earlier breakpoint.
//
// **The tail is the moving half**, and it takes the five-minute
// lifetime for the mirror-image reason. An entry written at the end of
// one turn is read by the next and then superseded, so it needs to
// survive one hop, not an hour, and for a single read 1.25x + 0.1x beats
// 2x + 0.1x. The two tail breakpoints sit on the last block of each of
// the final two *user* turns, which is a deliberate choice on both
// counts:
//
// - *User* turns, because every block kind a user turn can hold (text,
//   image, tool result) is documented as cacheable, while a `thinking`
//   block — which can end an assistant turn — is not. Requests always
//   end with a user turn (a prompt, or the results of the tool calls the
//   model just made), so the last turn is covered either way.
// - The final *two*, because merged turns strictly alternate roles: a
//   request whose last user turn is U gains an assistant turn and a new
//   user turn before the next request, whose two marked user turns are
//   then the new one and U. The breakpoint at U therefore lands on the
//   same bytes in both requests, which is an exact-position read rather
//   than a search. That matters because the API walks back at most 20
//   content blocks from a breakpoint hunting for an entry, and a single
//   agentic turn — parallel tool calls and their results — can exceed
//   20 blocks on its own.
//
// Ordering is load-bearing: the API requires every one-hour breakpoint
// to precede every five-minute one, which the head-then-tail layout
// satisfies by construction.
//
// What rewriting history costs: a precise rewrite or a compaction changes
// bytes at some position P, so breakpoints at or after P miss and are
// written afresh while everything before P still reads. That is the whole
// of the interaction — one turn priced as though the tail were new, after
// which the rolling pair has re-established itself. A prefix shorter than
// the model's minimum (512 tokens on the newest models, 4096 on some
// older ones) is silently not cached and not charged, so short requests
// need no special case here.

// The session-stable head's cache control. One hour, per the arithmetic
// in the section banner above.
fn cache_1h() -> JsonValue {
  json.Object([
    #("type", json.String("ephemeral")),
    #("ttl", json.String("1h")),
  ])
}

// The rolling tail's cache control. Omitting `ttl` is the API's
// five-minute default; sending it explicitly would change the bytes for
// no gain.
fn cache_5m() -> JsonValue {
  json.Object([#("type", json.String("ephemeral"))])
}

// Hangs a breakpoint on one content block. Every block this adapter
// builds is an object, so the fallback arm is unreachable in practice;
// it is written out rather than asserted because a caller-supplied tool
// schema is the one value here this module did not construct itself.
fn with_cache_control(block: JsonValue, control: JsonValue) -> JsonValue {
  case block {
    json.Object(fields:) ->
      json.Object(list.append(fields, [#("cache_control", control)]))
    other -> other
  }
}

// A breakpoint names a position, and the position for a tool array or a
// turn is its final block.
fn mark_last(blocks: List(JsonValue), control: JsonValue) -> List(JsonValue) {
  case list.reverse(blocks) {
    [] -> []
    [last, ..rest] -> list.reverse([with_cache_control(last, control), ..rest])
  }
}

// The tool array, with the head's breakpoint on its last definition.
fn encode_tools(tools: List(ToolSpec)) -> JsonValue {
  json.Array(mark_last(list.map(tools, encode_tool), cache_1h()))
}

// The system prompt travels as a one-element block array rather than a
// bare string: the string form renders identically but has nowhere to
// hang a breakpoint.
fn encode_system(system: String) -> JsonValue {
  json.Array([
    with_cache_control(
      json.Object([
        #("type", json.String("text")),
        #("text", json.String(system)),
      ]),
      cache_1h(),
    ),
  ])
}

// Marks the last block of each of the final two user turns. Assistant
// turns pass through untouched, and a conversation with fewer than two
// user turns simply gets fewer breakpoints.
fn mark_tail_user_turns(
  turns: List(#(String, List(JsonValue))),
) -> List(#(String, List(JsonValue))) {
  mark_user_turns(list.reverse(turns), 2, [])
}

// Walks the turn list newest-first, spending `remaining` breakpoints on
// the user turns it meets, and rebuilds the list oldest-first as it goes.
fn mark_user_turns(
  newest_first: List(#(String, List(JsonValue))),
  remaining: Int,
  marked: List(#(String, List(JsonValue))),
) -> List(#(String, List(JsonValue))) {
  case newest_first, remaining {
    [], _ -> marked
    // Budget spent: the rest of the conversation is already in
    // newest-first order, so one reverse restores it ahead of the marked
    // tail.
    rest, 0 -> list.append(list.reverse(rest), marked)
    [#("user", blocks), ..rest], _ ->
      mark_user_turns(rest, remaining - 1, [
        #("user", mark_last(blocks, cache_5m())),
        ..marked
      ])
    [turn, ..rest], _ -> mark_user_turns(rest, remaining, [turn, ..marked])
  }
}

// --- stop-reason mapping ------------------------------------------------

/// Maps a raw Messages API stop reason to the harness vocabulary, with an
/// error message where the mapping implies one. Total over known values;
/// `Error(Nil)` for unknown values, which the caller surfaces as
/// `Failed(UnmappedStopReason)` — never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert anthropic.map_stop_reason("end_turn")
///   == Ok(#(message.Stop, option.None))
/// ```
///
/// ```gleam
/// assert anthropic.map_stop_reason("novel_reason") == Error(Nil)
/// ```
///
pub fn map_stop_reason(
  raw: String,
) -> Result(#(StopReason, Option(String)), Nil) {
  case raw {
    "end_turn" -> Ok(#(Stop, None))
    "max_tokens" -> Ok(#(Length, None))
    "tool_use" -> Ok(#(ToolUse, None))
    // We supply no stop sequences, but proxies may still report this.
    "stop_sequence" -> Ok(#(Stop, None))
    // The provider paused a long turn; resubmitting continues it, so the
    // harness treats it as an ordinary stop.
    "pause_turn" -> Ok(#(Stop, None))
    "refusal" ->
      Ok(#(Errored, Some("the model refused to complete the request")))
    "sensitive" -> Ok(#(Errored, Some("provider stopped with: sensitive")))
    _ -> Error(Nil)
  }
}

// --- response accumulation ----------------------------------------------

/// The pure streamed-response state: SSE carry, accumulated blocks,
/// usage, and settlement facts. Driven by `response_machine`.
pub opaque type Accumulator {
  /// Invariants: `blocks` is in reverse arrival order; `status` is 0
  /// until the response status arrives; once `done` is `True` no further
  /// event changes anything.
  Accumulator(
    resolved: ResolvedModel,
    now: Int,
    status: Int,
    retry_after_ms: Option(Int),
    error_body: BitArray,
    sse: stream.SseParser,
    blocks: List(BlockAcc),
    input: Int,
    output: Int,
    cache_read: Int,
    cache_write: Int,
    cache_write_1h: Option(Int),
    reasoning: Option(Int),
    stop: Option(StopReason),
    raw_stop: Option(String),
    error_message: Option(String),
    response_id: Option(String),
    response_model: Option(String),
    done: Bool,
  )
}

type BlockAcc {
  TextAcc(index: Int, text: String)
  ThinkingAcc(index: Int, thinking: String, signature: String, redacted: Bool)
  ToolAcc(index: Int, call_id: String, name: String, arguments_json: String)
}

/// The response machine for one Messages API request attempt. `now` is
/// the Unix-ms timestamp stamped on the settled assistant message (read
/// from the gateway's injected clock at dispatch).
///
/// ## Examples
///
/// ```gleam
/// // let machine = anthropic.response_machine(resolved, now: 1000)
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
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
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
    // Error statuses stream their body too; collect it for the error
    // report at end-of-body.
    _ ->
      case diagnostic.append_error_body(acc.error_body, chunk) {
        Ok(error_body) -> #(Accumulator(..acc, error_body:), [])
        Error(Nil) ->
          fail(
            acc,
            MalformedStream(corruption_report(
              "an error response no larger than 65536 bytes",
              "provider error response exceeded its byte budget",
            )),
          )
      }
  }
}

fn on_end(acc: Accumulator) -> List(StreamEvent) {
  case acc.done, acc.status {
    True, _ -> []
    False, 200 -> [
      Failed(StreamDisconnected(
        context: "response body ended before message_stop",
      )),
    ]
    False, status -> [Failed(http_error(status, acc))]
  }
}

// Parses the collected error body — `{"type":"error","error":{...}}` —
// into a redacted HttpError; an unparsable body degrades to a bounded
// text excerpt.
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
        api_error_type: wire.string_field_or(error, "type", or: ""),
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
    SseMessage(event: _, data:) -> {
      use document <- or_fail(json.parse(data), acc, MalformedStream)
      handle_message(
        acc,
        wire.string_field_or(document, "type", or: ""),
        document,
      )
    }
  }
}

fn corruption_report(expected: String, context: String) -> CorruptionReport {
  corruption.report(
    at: "provider/adapter/anthropic",
    on: "provider stream",
    expected:,
    context:,
  )
}

fn handle_message(
  acc: Accumulator,
  event_type: String,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case event_type {
    "ping" -> #(acc, [])
    "message_start" -> #(handle_message_start(acc, document), [])
    "content_block_start" -> handle_block_start(acc, document)
    "content_block_delta" -> handle_block_delta(acc, document)
    "content_block_stop" -> #(acc, [])
    "message_delta" -> handle_message_delta(acc, document)
    "message_stop" -> settle(acc)
    "error" -> {
      let error = result.unwrap(wire.field(document, "error"), document)
      fail(
        acc,
        StreamError(
          api_error_type: wire.string_field_or(error, "type", or: ""),
          message: wire.string_field_or(error, "message", or: ""),
        ),
      )
    }
    // Unknown event types are ignored per the Messages API versioning
    // policy: new event kinds must not break existing clients.
    _ -> #(acc, [])
  }
}

// Counters default to the accumulator, never to zero: a duplicate
// `message_start` with an empty usage object must not erase counts an
// earlier event already reported (a proxy could otherwise suppress
// usage accounting).
fn handle_message_start(acc: Accumulator, document: JsonValue) -> Accumulator {
  case wire.field(document, "message") {
    Error(Nil) -> acc
    Ok(started) -> apply_message_start(acc, started)
  }
}

fn apply_message_start(acc: Accumulator, started: JsonValue) -> Accumulator {
  let usage = result.unwrap(wire.field(started, "usage"), json.Object([]))
  Accumulator(
    ..acc,
    response_id: option.or(
      option.from_result(wire.string_field(started, "id")),
      acc.response_id,
    ),
    response_model: option.or(
      option.from_result(wire.string_field(started, "model")),
      acc.response_model,
    ),
    input: wire.count_field_or(usage, "input_tokens", or: acc.input),
    output: wire.count_field_or(usage, "output_tokens", or: acc.output),
    cache_read: wire.count_field_or(
      usage,
      "cache_read_input_tokens",
      or: acc.cache_read,
    ),
    cache_write: wire.count_field_or(
      usage,
      "cache_creation_input_tokens",
      or: acc.cache_write,
    ),
    cache_write_1h: nested_optional_count(
      usage,
      "cache_creation",
      "ephemeral_1h_input_tokens",
      acc.cache_write_1h,
    ),
  )
}

// Reads an optional counter nested one object down (`usage.cache_creation.
// ephemeral_1h_input_tokens`, `usage.output_tokens_details.
// thinking_tokens`): absent at either level keeps `previous`, exactly as
// the flat counters default to the accumulator rather than to zero.
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

fn handle_block_start(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let index = wire.int_field_or(document, "index", or: 0)
  case wire.field(document, "content_block") {
    Error(Nil) -> #(acc, [])
    Ok(block) -> start_block(acc, index, block)
  }
}

fn start_block(
  acc: Accumulator,
  index: Int,
  block: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case wire.string_field_or(block, "type", or: "") {
    "text" ->
      start_text_block(acc, index, wire.string_field_or(block, "text", or: ""))
    "thinking" ->
      start_thinking_block(
        acc,
        index,
        thinking: wire.string_field_or(block, "thinking", or: ""),
        signature: wire.string_field_or(block, "signature", or: ""),
        redacted: False,
      )
    "redacted_thinking" ->
      start_thinking_block(
        acc,
        index,
        thinking: "[reasoning redacted]",
        signature: wire.string_field_or(block, "data", or: ""),
        redacted: True,
      )
    "tool_use" ->
      start_tool_block(
        acc,
        index,
        wire.string_field_or(block, "id", or: ""),
        wire.string_field_or(block, "name", or: ""),
      )
    // Unknown block types are ignored for forward compatibility.
    _ -> #(acc, [])
  }
}

fn start_text_block(
  acc: Accumulator,
  index: Int,
  text: String,
) -> #(Accumulator, List(StreamEvent)) {
  let acc = Accumulator(..acc, blocks: [TextAcc(index:, text:), ..acc.blocks])
  case text {
    "" -> #(acc, [])
    _ -> #(acc, [Delta(TextDelta(index:, text:))])
  }
}

fn start_thinking_block(
  acc: Accumulator,
  index: Int,
  thinking thinking: String,
  signature signature: String,
  redacted redacted: Bool,
) -> #(Accumulator, List(StreamEvent)) {
  #(
    Accumulator(..acc, blocks: [
      ThinkingAcc(index:, thinking:, signature:, redacted:),
      ..acc.blocks
    ]),
    [],
  )
}

fn start_tool_block(
  acc: Accumulator,
  index: Int,
  call_id: String,
  name: String,
) -> #(Accumulator, List(StreamEvent)) {
  #(
    Accumulator(..acc, blocks: [
      ToolAcc(index:, call_id:, name:, arguments_json: ""),
      ..acc.blocks
    ]),
    [Delta(ToolCallDelta(index:, call_id:, name:, arguments_json: ""))],
  )
}

fn handle_block_delta(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let index = wire.int_field_or(document, "index", or: 0)
  case wire.field(document, "delta") {
    Error(Nil) -> #(acc, [])
    Ok(delta) -> apply_block_delta(acc, index, delta)
  }
}

fn apply_block_delta(
  acc: Accumulator,
  index: Int,
  delta: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case wire.string_field_or(delta, "type", or: "") {
    "text_delta" -> {
      let text = wire.string_field_or(delta, "text", or: "")
      append_to_block(acc, index, text_delta_update(_, index, text))
    }
    "thinking_delta" -> {
      let thinking = wire.string_field_or(delta, "thinking", or: "")
      append_to_block(acc, index, thinking_delta_update(_, index, thinking))
    }
    "input_json_delta" -> {
      let fragment = wire.string_field_or(delta, "partial_json", or: "")
      append_to_block(acc, index, tool_delta_update(_, index, fragment))
    }
    "signature_delta" -> {
      let fragment = wire.string_field_or(delta, "signature", or: "")
      append_to_block(acc, index, signature_delta_update(_, fragment))
    }
    // Unknown delta types are ignored for forward compatibility.
    _ -> #(acc, [])
  }
}

fn text_delta_update(
  block: BlockAcc,
  index: Int,
  text: String,
) -> #(BlockAcc, List(StreamEvent)) {
  case block {
    TextAcc(index: i, text: so_far) -> #(
      TextAcc(index: i, text: so_far <> text),
      [Delta(TextDelta(index:, text:))],
    )
    other -> #(other, [])
  }
}

fn thinking_delta_update(
  block: BlockAcc,
  index: Int,
  thinking: String,
) -> #(BlockAcc, List(StreamEvent)) {
  case block {
    ThinkingAcc(index: i, thinking: so_far, signature:, redacted:) -> #(
      ThinkingAcc(index: i, thinking: so_far <> thinking, signature:, redacted:),
      [Delta(ThinkingDelta(index:, thinking:))],
    )
    other -> #(other, [])
  }
}

fn tool_delta_update(
  block: BlockAcc,
  index: Int,
  fragment: String,
) -> #(BlockAcc, List(StreamEvent)) {
  case block {
    ToolAcc(index: i, call_id:, name:, arguments_json:) -> #(
      ToolAcc(
        index: i,
        call_id:,
        name:,
        arguments_json: arguments_json <> fragment,
      ),
      [Delta(ToolCallDelta(index:, call_id:, name:, arguments_json: fragment))],
    )
    other -> #(other, [])
  }
}

// The signature is a replay artifact, never displayed live, so it has no
// corresponding `Delta` — unlike the other three deltas above.
fn signature_delta_update(
  block: BlockAcc,
  fragment: String,
) -> #(BlockAcc, List(StreamEvent)) {
  case block {
    ThinkingAcc(index: i, thinking:, signature:, redacted:) -> #(
      ThinkingAcc(
        index: i,
        thinking:,
        signature: signature <> fragment,
        redacted:,
      ),
      [],
    )
    other -> #(other, [])
  }
}

// Applies `update` to the block at `index`. `events == []` is a found
// guard, not an accumulator: block indices are provider-assigned and
// expected unique per stream, but this ensures only the first match
// updates even if a proxy ever duplicates one, rather than silently
// applying the delta twice.
fn append_to_block(
  acc: Accumulator,
  index: Int,
  update: fn(BlockAcc) -> #(BlockAcc, List(StreamEvent)),
) -> #(Accumulator, List(StreamEvent)) {
  let #(blocks, events) =
    list.fold(acc.blocks, #([], []), fn(folded, block) {
      let #(blocks, events) = folded
      case block_index(block) == index && events == [] {
        True -> {
          let #(updated, new_events) = update(block)
          #([updated, ..blocks], new_events)
        }
        False -> #([block, ..blocks], events)
      }
    })
  #(Accumulator(..acc, blocks: list.reverse(blocks)), events)
}

fn block_index(block: BlockAcc) -> Int {
  case block {
    TextAcc(index:, text: _) -> index
    ThinkingAcc(index:, thinking: _, signature: _, redacted: _) -> index
    ToolAcc(index:, call_id: _, name: _, arguments_json: _) -> index
  }
}

fn handle_message_delta(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let acc = case wire.field(document, "usage") {
    Error(Nil) -> acc
    Ok(usage) -> merge_delta_usage(acc, usage)
  }
  case wire.field(document, "delta") {
    Error(Nil) -> #(acc, [])
    Ok(delta) -> apply_stop_reason(acc, delta)
  }
}

fn merge_delta_usage(acc: Accumulator, usage: JsonValue) -> Accumulator {
  Accumulator(
    ..acc,
    input: wire.count_field_or(usage, "input_tokens", or: acc.input),
    output: wire.count_field_or(usage, "output_tokens", or: acc.output),
    cache_read: wire.count_field_or(
      usage,
      "cache_read_input_tokens",
      or: acc.cache_read,
    ),
    cache_write: wire.count_field_or(
      usage,
      "cache_creation_input_tokens",
      or: acc.cache_write,
    ),
    // The per-TTL breakdown rides on either usage-bearing event; now that
    // the head is written with a one-hour lifetime it is a real number
    // rather than an always-absent field, so it is read here as well as
    // at `message_start`.
    cache_write_1h: nested_optional_count(
      usage,
      "cache_creation",
      "ephemeral_1h_input_tokens",
      acc.cache_write_1h,
    ),
    reasoning: nested_optional_count(
      usage,
      "output_tokens_details",
      "thinking_tokens",
      acc.reasoning,
    ),
  )
}

fn apply_stop_reason(
  acc: Accumulator,
  delta: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case wire.string_field(delta, "stop_reason") {
    Error(Nil) -> #(acc, [])
    Ok(raw) -> apply_mapped_stop_reason(acc, raw)
  }
}

fn apply_mapped_stop_reason(
  acc: Accumulator,
  raw: String,
) -> #(Accumulator, List(StreamEvent)) {
  case map_stop_reason(raw) {
    Ok(#(stop, error_message)) -> #(
      Accumulator(
        ..acc,
        stop: Some(stop),
        raw_stop: Some(raw),
        error_message: option.or(error_message, acc.error_message),
      ),
      [],
    )
    Error(Nil) -> fail(acc, UnmappedStopReason(raw:))
  }
}

// --- settlement ---------------------------------------------------------

fn settle(acc: Accumulator) -> #(Accumulator, List(StreamEvent)) {
  case acc.stop {
    None ->
      fail(
        acc,
        StreamDisconnected(
          context: "message_stop arrived without a stop reason",
        ),
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
  // Adapter-computed overflow (spec §1.5): the request did not fit and
  // nothing substantive came back, so the response settles as `error`
  // with the canonical overflow message. The raw stop reason is
  // preserved for diagnostics.
  // Spec §1.5 words this as input plus cache-read, from before this
  // adapter declared cache breakpoints. The quantity it names is the
  // whole prompt — the Messages API reports it as `input_tokens +
  // cache_read_input_tokens + cache_creation_input_tokens` — so the
  // write half belongs in the sum. Leaving it out would shrink the
  // apparent prompt by exactly the tokens caching just wrote, and an
  // oversized request would retry unchanged instead of compacting.
  let input_tokens = acc.input + acc.cache_read + acc.cache_write
  let overflowed =
    input_tokens > acc.resolved.context_window
    && acc.output <= negligible_output_tokens
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
      end_turn: option.map(acc.raw_stop, fn(raw) { raw == "end_turn" }),
      timestamp: acc.now,
    )
  // Unreachable by construction (the stop reason above is never
  // Pending), reported totally rather than asserted.
  use settled <- or_fail(stream.settle(assistant), acc, fn(_nil) {
    MalformedStream(corruption_report(
      "a settled assistant message",
      "stop reason pending at message_stop",
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
  blocks: List(BlockAcc),
  built: List(message.AssistantBlock),
) -> Result(List(message.AssistantBlock), CorruptionReport) {
  case blocks {
    [] -> Ok(list.reverse(built))
    [TextAcc(index: _, text:), ..rest] ->
      build_blocks(rest, [AssistantText(text:, text_signature: None), ..built])
    [ThinkingAcc(index: _, thinking:, signature:, redacted:), ..rest] ->
      build_blocks(rest, [
        AssistantThinking(
          thinking:,
          thinking_signature: case signature {
            "" -> None
            _ -> Some(signature)
          },
          redacted:,
        ),
        ..built
      ])
    [ToolAcc(index: _, call_id:, name:, arguments_json:), ..rest] -> {
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
  Usage(
    input: acc.input,
    output: acc.output,
    cache_read: acc.cache_read,
    cache_write: acc.cache_write,
    cache_write_1h: acc.cache_write_1h,
    reasoning: acc.reasoning,
    // The Messages API reports no total; computed from components, the
    // same composition pi uses.
    total_tokens: acc.input + acc.output + acc.cache_read + acc.cache_write,
    // Pricing is out of WP-F scope; the ledger's costing layer owns it.
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
