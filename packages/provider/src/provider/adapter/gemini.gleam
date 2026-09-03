//// The Gemini `generateContent` adapter.
////
//// The third wire dialect, and the first that is neither Messages nor
//// chat-completions shaped. `build_request` posts one
//// `models/<id>:streamGenerateContent?alt=sse` request to the Gemini
//// Developer API; `response_machine` folds the SSE stream — unnamed
//// events whose `data:` is a whole `GenerateContentResponse` document,
//// with no terminator sentinel — into deltas and one settled assistant
//// message.
////
//// Three things make Gemini a different animal from the other two
//// dialects, and each shaped a decision here:
////
//// - **Parts, not deltas.** A chunk carries `candidates[0].content.parts`,
////   and each part is a complete unit: a text fragment, a thought
////   fragment (`thought: true`), or a whole `functionCall` with its
////   arguments already parsed. There are no content-block indices and no
////   streamed argument fragments, so blocks are cut where the part kind
////   changes — a run of thought parts is one thinking block, the run of
////   answer parts after it one text block — and a function call is one
////   block delivered in a single delta.
//// - **Thought signatures are load-bearing.** A `thoughtSignature` may
////   ride on any part; the model needs it back on replay, and a
////   `functionCall` replayed without one is refused outright (HTTP 400,
////   "Function call is missing a thought_signature"). The signature is
////   kept on the block it arrived with — `text_signature` on text,
////   `thought_signature` on the tool call — and an empty text part
////   carrying only a signature attaches it to the block in progress. A
////   tool call with no stored signature (one made by a different model
////   earlier in the same conversation) replays with the
////   `skip_thought_signature_validator` sentinel the API documents for
////   exactly that case. An unsigned thought summary is not replayed — the
////   API does not want it back — but a signed one is, as a `thought` part,
////   because the signature on it is state the model asked to see again.
//// - **Reasoning is configured by model generation.** Gemini 3 takes a
////   `thinkingLevel` word and rejects a token budget; Gemini 2.5 takes a
////   `thinkingBudget` and rejects the word. The adapter reads the
////   generation off the model id, which is what pi and oh-my-pi both do
////   and the only place the fact is available.
////
//// Normative behavior mirrors the other adapters: total `finishReason`
//// mapping with unknown values settling as `Failed(UnmappedStopReason)`
//// in-band; adapter-computed overflow settling as `error` with the
//// canonical overflow message; usage counters clamped into
//// `[0, wire.max_usage_count]` at the read. `promptTokenCount` is the
//// whole prompt, so the cached half (`cachedContentTokenCount`) is split
//// back out of it as `cache_read`; `thoughtsTokenCount` is billed output
//// and is added to `candidatesTokenCount`, and also reported as
//// `reasoning`. This dialect declares no cache breakpoints: Gemini's
//// implicit caching is server-side and prefix-matched, as OpenAI's is.
////
//// The API key is accepted as an argument and written into one
//// `x-goog-api-key` header; it is never stored in the accumulator, any
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
import provider/internal/diagnostic
import provider/internal/wire
import provider/model.{
  type ProviderRequest, type ResolvedModel, type ThinkingLevel, type ToolSpec,
  ThinkingHigh, ThinkingLow, ThinkingMedium, ThinkingOff,
}
import provider/retry
import provider/stream.{
  type ResponseMachine, type SseEvent, type StreamEvent, Delta, Failed,
  HttpError, MalformedStream, ResponseMachine, Settled, SseMalformed, SseMessage,
  StreamDisconnected, StreamError, TextDelta, ThinkingDelta, ToolCallDelta,
  UnmappedStopReason,
}

/// The `api` string stamped on assistant messages produced here.
pub const api_name = "gemini-generate-content"

/// The sentinel the API accepts in place of a missing thought signature
/// on a replayed function call. Documented at
/// https://ai.google.dev/gemini-api/docs/thought-signatures.
pub const skip_signature_sentinel = "skip_thought_signature_validator"

// Same negligible-output guard as the Anthropic adapter; see there.
const negligible_output_tokens = 64

// --- request construction -----------------------------------------------

/// Builds the streaming `generateContent` request. `base_url` includes the
/// API version root (e.g. `"https://generativelanguage.googleapis.com/v1beta"`);
/// the model id is a path segment, and the key flows into the
/// `x-goog-api-key` header and nowhere else.
///
/// Thinking levels become a `thinkingConfig` with `includeThoughts` set:
/// a `thinkingLevel` word for Gemini 3, a `thinkingBudget` for Gemini 2.5
/// (see `thinking_config`). `ThinkingOff` sends no thinking configuration
/// at all, leaving the model's own default in force — Gemini 3 cannot
/// turn reasoning off, so "off" here means "do not show it to me".
///
/// ## Examples
///
/// ```gleam
/// // gemini.build_request(
/// //   base_url: "https://generativelanguage.googleapis.com/v1beta",
/// //   api_key: key,
/// //   resolved: resolved,
/// //   request: request,
/// // ) // -> HttpRequest(method: "POST", url: ".../models/gemini-3.5-flash:streamGenerateContent?alt=sse", ..)
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
  let generation_config =
    list.append(
      [#("maxOutputTokens", json.Int(max_tokens))],
      case thinking_config(resolved.model_id, resolved.thinking) {
        Some(config) -> [#("thinkingConfig", config)]
        None -> []
      },
    )
  let body =
    json.Object(
      list.flatten([
        case request.system {
          Some(system) -> [#("systemInstruction", text_parts(system))]
          None -> []
        },
        [#("contents", json.Array(encode_contents(request.messages)))],
        case request.tools {
          [] -> []
          tools -> [
            #(
              "tools",
              json.Array([
                json.Object([
                  #(
                    "functionDeclarations",
                    json.Array(list.map(tools, encode_tool)),
                  ),
                ]),
              ]),
            ),
          ]
        },
        [#("generationConfig", json.Object(generation_config))],
      ]),
    )
  HttpRequest(
    method: "POST",
    url: base_url
      <> "/models/"
      <> resolved.model_id
      <> ":streamGenerateContent?alt=sse",
    headers: [
      #("x-goog-api-key", api_key),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: json.to_string(body),
  )
}

/// Which reasoning knob a model generation exposes. Gemini 3 and later
/// take a level word; Gemini 2.5 takes a token budget and rejects the
/// word with "Thinking level is not supported for this model".
pub type ThinkingDial {
  /// `thinkingLevel: "LOW" | "MEDIUM" | "HIGH"`.
  LevelWord

  /// `thinkingBudget: <tokens>`.
  TokenBudget
}

/// Reads the reasoning dial off a model id. Only the `gemini-2.` family
/// is budget-shaped; everything else, including ids this adapter has
/// never seen, is assumed to speak the newer level vocabulary, because
/// that is the direction the API is moving and the older one is closed.
///
/// ## Examples
///
/// ```gleam
/// assert gemini.thinking_dial("gemini-2.5-flash") == gemini.TokenBudget
/// ```
///
/// ```gleam
/// assert gemini.thinking_dial("gemini-3.5-flash") == gemini.LevelWord
/// ```
///
pub fn thinking_dial(model_id: String) -> ThinkingDial {
  case string.starts_with(model_id, "gemini-2.") {
    True -> TokenBudget
    False -> LevelWord
  }
}

/// The `thinkingConfig` object for a level, or `None` for `ThinkingOff`.
/// The budgets are pi's for the 2.5 family — 2048, 8192 and 24576 tokens —
/// and sit under every 2.5 model's ceiling.
///
/// ## Examples
///
/// ```gleam
/// assert gemini.thinking_config("gemini-3.5-flash", model.ThinkingLow)
///   == option.Some(json.Object([
///     #("includeThoughts", json.Bool(True)),
///     #("thinkingLevel", json.String("LOW")),
///   ]))
/// ```
///
/// ```gleam
/// assert gemini.thinking_config("gemini-2.5-flash", model.ThinkingOff)
///   == option.None
/// ```
///
pub fn thinking_config(
  model_id: String,
  level: ThinkingLevel,
) -> Option(JsonValue) {
  let knob = case thinking_dial(model_id), level {
    _, ThinkingOff -> None
    LevelWord, ThinkingLow -> Some(#("thinkingLevel", json.String("LOW")))
    LevelWord, ThinkingMedium -> Some(#("thinkingLevel", json.String("MEDIUM")))
    LevelWord, ThinkingHigh -> Some(#("thinkingLevel", json.String("HIGH")))
    TokenBudget, ThinkingLow -> Some(#("thinkingBudget", json.Int(2048)))
    TokenBudget, ThinkingMedium -> Some(#("thinkingBudget", json.Int(8192)))
    TokenBudget, ThinkingHigh -> Some(#("thinkingBudget", json.Int(24_576)))
  }
  option.map(knob, fn(knob) {
    json.Object([#("includeThoughts", json.Bool(True)), knob])
  })
}

fn encode_tool(tool: ToolSpec) -> JsonValue {
  json.Object([
    #("name", json.String(tool.name)),
    #("description", json.String(tool.description)),
    // `parametersJsonSchema` takes full JSON Schema; the older
    // `parameters` field is an OpenAPI subset that rejects `anyOf` and
    // friends, which Loom's tool schemas use.
    #("parametersJsonSchema", tool.input_schema),
  ])
}

fn text_parts(text: String) -> JsonValue {
  json.Object([
    #("parts", json.Array([json.Object([#("text", json.String(text))])])),
  ])
}

// One `contents` entry under construction. `FunctionResponses` marks a
// user turn that holds only tool results, because parallel tool results
// must land in a single turn ("number of function response parts is not
// equal to number of function call parts" otherwise) while every other
// turn boundary is kept as the conversation had it. Images a tool
// returned cannot ride inside a `functionResponse` on every generation,
// so they wait on the turn as `pending_images` and follow it as a user
// turn of their own once the batch is closed — flushing them as each
// result arrived would put an image turn between two results of one
// batch, which is the refusal above by another route.
type Turn {
  Turn(role: String, parts: List(JsonValue), kind: TurnKind)
}

type TurnKind {
  FunctionResponses(pending_images: List(JsonValue))
  Ordinary
}

fn encode_contents(messages: List(AgentMessage)) -> List(JsonValue) {
  messages
  |> list.fold([], fn(turns, message) { push_message(turns, message) })
  |> flush_images
  |> list.reverse
  |> list.map(fn(turn) {
    json.Object([
      #("role", json.String(turn.role)),
      #("parts", json.Array(turn.parts)),
    ])
  })
}

// Turns are accumulated head-first, so the turn in progress is the head.
fn push_message(turns: List(Turn), message: AgentMessage) -> List(Turn) {
  case message {
    UserMessage(content:, timestamp: _) ->
      push_turn(turns, "user", list.map(content, encode_user_block), Ordinary)
    AssistantMessage(content:, ..) ->
      push_turn(
        turns,
        "model",
        list.filter_map(content, encode_assistant_block),
        Ordinary,
      )
    ToolResultMessage(tool_call_id:, tool_name:, content:, is_error:, ..) -> {
      // The frozen message shape carries `is_error` as a `Bool`; it is
      // named here once so the encoder below reads the outcome, not a
      // polarity.
      let outcome = case is_error {
        True -> ToolFailed
        False -> ToolSucceeded
      }
      push_tool_result(turns, tool_call_id, tool_name, content, outcome)
    }
    CustomMessage(schema: _, payload: _) -> turns
  }
}

// A turn with no parts is not sent: the API rejects an empty `parts`
// array, and an assistant turn that was all unsigned thinking has
// nothing the model needs back. Any turn closes the function-response
// batch in progress, so its images are flushed first.
fn push_turn(
  turns: List(Turn),
  role: String,
  parts: List(JsonValue),
  kind: TurnKind,
) -> List(Turn) {
  case parts {
    [] -> turns
    _ -> [Turn(role:, parts:, kind:), ..flush_images(turns)]
  }
}

// Closes a function-response batch: the images its results carried go
// out as one user turn after it, as pi sends them. Anything else at the
// head is left alone.
fn flush_images(turns: List(Turn)) -> List(Turn) {
  case turns {
    [
      Turn(
        role:,
        parts:,
        kind: FunctionResponses(pending_images: [_, ..] as images),
      ),
      ..earlier
    ] -> [
      Turn(
        role: "user",
        parts: [
          json.Object([#("text", json.String("Tool result image:"))]),
          ..images
        ],
        kind: Ordinary,
      ),
      Turn(role:, parts:, kind: FunctionResponses(pending_images: [])),
      ..earlier
    ]
    _ -> turns
  }
}

// How a tool call ended, which picks the `response` key the API
// documents: `output` for a result, `error` for a failure.
type ToolOutcome {
  ToolSucceeded
  ToolFailed
}

// A tool result joins the function-response turn in progress when there
// is one, so parallel results stay in one turn, and its images join that
// turn's pending list to be flushed when the batch closes.
fn push_tool_result(
  turns: List(Turn),
  call_id: String,
  tool_name: String,
  content: List(message.ToolResultBlock),
  outcome: ToolOutcome,
) -> List(Turn) {
  let text =
    content
    |> list.filter_map(tool_result_text_block)
    |> string.join("\n")
  let images = list.filter_map(content, tool_result_image_part)
  let response_key = case outcome {
    ToolFailed -> "error"
    ToolSucceeded -> "output"
  }
  let response =
    json.Object([
      #(
        "functionResponse",
        json.Object([
          #("name", json.String(tool_name)),
          #("response", json.Object([#(response_key, json.String(text))])),
          #("id", json.String(call_id)),
        ]),
      ),
    ])

  case turns {
    [
      Turn(role: "user", parts:, kind: FunctionResponses(pending_images:)),
      ..earlier
    ] -> [
      Turn(
        role: "user",
        parts: list.append(parts, [response]),
        kind: FunctionResponses(pending_images: list.append(
          pending_images,
          images,
        )),
      ),
      ..earlier
    ]
    _ -> [
      Turn(
        role: "user",
        parts: [response],
        kind: FunctionResponses(pending_images: images),
      ),
      ..turns
    ]
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

fn tool_result_image_part(
  block: message.ToolResultBlock,
) -> Result(JsonValue, Nil) {
  case block {
    ToolResultText(text: _, text_signature: _) -> Error(Nil)
    ToolResultImage(data:, mime_type:) -> Ok(inline_data(data, mime_type))
  }
}

fn inline_data(data: String, mime_type: String) -> JsonValue {
  json.Object([
    #(
      "inlineData",
      json.Object([
        #("mimeType", json.String(mime_type)),
        #("data", json.String(data)),
      ]),
    ),
  ])
}

fn encode_user_block(block: message.UserBlock) -> JsonValue {
  case block {
    UserText(text:, text_signature: _) ->
      json.Object([#("text", json.String(text))])
    UserImage(data:, mime_type:) -> inline_data(data, mime_type)
  }
}

fn encode_assistant_block(
  block: message.AssistantBlock,
) -> Result(JsonValue, Nil) {
  case block {
    // The API rejects empty text parts, so they are dropped on replay.
    AssistantText(text: "", text_signature: _) -> Error(Nil)
    AssistantText(text:, text_signature:) ->
      Ok(with_signature([#("text", json.String(text))], text_signature))

    // An unsigned thought summary is display data and is not sent back;
    // a signed one carries state the model asked to have returned, and
    // dropping it would leave the call that follows leaning on the skip
    // sentinel instead of its real signature.
    AssistantThinking(thinking: _, thinking_signature: None, redacted: _) ->
      Error(Nil)
    AssistantThinking(thinking:, thinking_signature: Some(signature), ..) ->
      Ok(with_signature(
        [#("text", json.String(thinking)), #("thought", json.Bool(True))],
        Some(signature),
      ))
    AssistantToolCall(call: ToolCall(
      id:,
      name:,
      arguments:,
      thought_signature:,
      namespace: _,
    )) ->
      Ok(with_signature(
        [
          #(
            "functionCall",
            json.Object([
              #("name", json.String(name)),
              #("args", arguments),
              #("id", json.String(id)),
            ]),
          ),
        ],
        Some(option.unwrap(thought_signature, skip_signature_sentinel)),
      ))
  }
}

fn with_signature(
  fields: List(#(String, JsonValue)),
  signature: Option(String),
) -> JsonValue {
  case signature {
    Some(signature) ->
      json.Object(
        list.append(fields, [#("thoughtSignature", json.String(signature))]),
      )
    None -> json.Object(fields)
  }
}

// --- stop-reason mapping ------------------------------------------------

/// Maps a raw `finishReason` to the harness vocabulary. Total over known
/// values; `Error(Nil)` for unknown values, which the caller surfaces as
/// `Failed(UnmappedStopReason)` — never a crash. `STOP` maps to `Stop`
/// here; settlement promotes it to `ToolUse` when the response carried a
/// function call, because Gemini has no distinct tool-use finish reason.
///
/// ## Examples
///
/// ```gleam
/// assert gemini.map_finish_reason("MAX_TOKENS")
///   == Ok(#(message.Length, option.None))
/// ```
///
/// ```gleam
/// assert gemini.map_finish_reason("NOVEL_REASON") == Error(Nil)
/// ```
///
pub fn map_finish_reason(
  raw: String,
) -> Result(#(StopReason, Option(String)), Nil) {
  case raw {
    "STOP" -> Ok(#(Stop, None))
    "MAX_TOKENS" -> Ok(#(Length, None))

    // Everything else the enum names is a refusal or a malformed
    // generation: the turn ended, and nothing useful can be retried
    // unchanged. pi maps the same set to its `error`.
    "SAFETY"
    | "RECITATION"
    | "BLOCKLIST"
    | "PROHIBITED_CONTENT"
    | "SPII"
    | "LANGUAGE"
    | "MALFORMED_FUNCTION_CALL"
    | "UNEXPECTED_TOOL_CALL"
    | "IMAGE_SAFETY"
    | "IMAGE_PROHIBITED_CONTENT"
    | "IMAGE_RECITATION"
    | "IMAGE_OTHER"
    | "NO_IMAGE"
    | "FINISH_REASON_UNSPECIFIED"
    | "OTHER" -> Ok(#(Errored, Some("provider finishReason: " <> raw)))
    _ -> Error(Nil)
  }
}

// --- response accumulation ----------------------------------------------

/// The pure streamed-response state for one `generateContent` attempt.
pub opaque type Accumulator {
  /// Invariants: `blocks` is in reverse arrival order and each block's
  /// `index` is its arrival position, so the head is the block in
  /// progress; `status` is 0 until the response status arrives; once
  /// `done` is `True` no further event changes anything.
  Accumulator(
    resolved: ResolvedModel,
    now: Int,
    status: Int,
    retry_after_ms: Option(Int),
    error_body: BitArray,
    sse: stream.SseParser,
    blocks: List(GmBlock),
    prompt_tokens: Int,
    candidates_tokens: Int,
    thoughts_tokens: Option(Int),
    cached_tokens: Int,
    total_tokens: Option(Int),
    stop: Option(StopReason),
    raw_stop: Option(String),
    error_message: Option(String),
    response_id: Option(String),
    response_model: Option(String),
    done: Bool,
  )
}

// Blocks are cut where the part kind changes; a signature seen on any
// part of a block is retained on the block. A tool block is complete on
// arrival — the wire delivers whole function calls, never fragments.
type GmBlock {
  GmText(index: Int, text: String, signature: Option(String))
  GmThinking(index: Int, thinking: String, signature: Option(String))
  GmTool(
    index: Int,
    call_id: String,
    name: String,
    arguments: JsonValue,
    signature: Option(String),
  )
}

/// The response machine for one `generateContent` request attempt. `now`
/// is the Unix-ms timestamp stamped on the settled assistant message.
///
/// ## Examples
///
/// ```gleam
/// // let machine = gemini.response_machine(resolved, now: 1000)
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
      candidates_tokens: 0,
      thoughts_tokens: None,
      cached_tokens: 0,
      total_tokens: None,
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
      let #(acc, reversed_events) =
        list.fold(sse_events, #(acc, []), fn(folded, sse_event) {
          let #(acc, reversed_events) = folded
          let #(acc, new_events) = handle_sse(acc, sse_event)
          #(
            acc,
            list.fold(new_events, reversed_events, fn(events, event) {
              [event, ..events]
            }),
          )
        })
      #(acc, list.reverse(reversed_events))
    }
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

// This dialect has no end-of-stream sentinel: the body simply closes
// after the chunk that carried `finishReason`. A body that closes without
// one is a disconnect.
fn on_end(acc: Accumulator) -> List(StreamEvent) {
  use <- bool.guard(when: acc.done, return: [])
  case acc.status {
    200 -> settle(acc).1
    status -> [Failed(http_error(status, acc))]
  }
}

// Parses the collected error body — `{"error":{"code","message","status"}}`
// — into a redacted HttpError. `status` is the gRPC-style word
// (`RESOURCE_EXHAUSTED`, `INVALID_ARGUMENT`) and is the closest thing the
// dialect has to a machine-readable error type.
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
        api_error_type: wire.string_field_or(error, "status", or: ""),
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
      handle_document(acc, document)
    }
  }
}

// A document carrying a top-level `error` is how the API reports a
// failure after the stream has opened.
fn handle_document(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case wire.field(document, "error") {
    Ok(error) ->
      fail(
        acc,
        StreamError(
          api_error_type: wire.string_field_or(error, "status", or: ""),
          message: wire.string_field_or(error, "message", or: ""),
        ),
      )
    Error(Nil) -> handle_response_document(acc, document)
  }
}

fn corruption_report(expected: String, context: String) -> CorruptionReport {
  corruption.report(
    at: "provider/adapter/gemini",
    on: "provider stream",
    expected:,
    context:,
  )
}

fn handle_response_document(
  acc: Accumulator,
  document: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let acc =
    Accumulator(
      ..acc,
      response_id: option.or(
        option.from_result(wire.string_field(document, "responseId")),
        acc.response_id,
      ),
      response_model: option.or(
        option.from_result(wire.string_field(document, "modelVersion")),
        acc.response_model,
      ),
    )
  let acc = case wire.field(document, "usageMetadata") {
    Ok(usage) -> extract_usage(acc, usage)
    Error(Nil) -> acc
  }
  case wire.array_field(document, "candidates") {
    Ok([candidate, ..]) -> handle_candidate(acc, candidate)
    _ -> #(acc, [])
  }
}

// Every count defaults to the accumulator's current value, never to zero,
// so a later chunk carrying a partial usage object cannot erase counts an
// earlier chunk already reported. Every chunk repeats the running usage,
// and the last one is the whole response.
fn extract_usage(acc: Accumulator, usage: JsonValue) -> Accumulator {
  Accumulator(
    ..acc,
    prompt_tokens: wire.count_field_or(
      usage,
      "promptTokenCount",
      or: acc.prompt_tokens,
    ),
    candidates_tokens: wire.count_field_or(
      usage,
      "candidatesTokenCount",
      or: acc.candidates_tokens,
    ),
    thoughts_tokens: option.or(
      wire.optional_count_field(usage, "thoughtsTokenCount"),
      acc.thoughts_tokens,
    ),
    cached_tokens: wire.count_field_or(
      usage,
      "cachedContentTokenCount",
      or: acc.cached_tokens,
    ),
    total_tokens: option.or(
      wire.optional_count_field(usage, "totalTokenCount"),
      acc.total_tokens,
    ),
  )
}

fn handle_candidate(
  acc: Accumulator,
  candidate: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let parts =
    wire.field(candidate, "content")
    |> result.try(wire.array_field(_, "parts"))
    |> result.unwrap([])
  let #(acc, events) =
    list.fold(parts, #(acc, []), fn(folded, part) {
      let #(acc, events) = folded
      let #(acc, new_events) = handle_part(acc, part)
      #(acc, list.append(events, new_events))
    })
  case wire.string_field(candidate, "finishReason") {
    Error(Nil) -> #(acc, events)
    Ok(raw) -> apply_finish_reason(acc, raw, events)
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

// Whether a text part is a thought summary or answer text.
type PartKind {
  Thought
  Answer
}

// A part is a function call, a text part, or something this adapter does
// not render (inline media in a response, executable code). A text part
// that is empty and carries a signature is the API's way of signing the
// block already in progress.
fn handle_part(
  acc: Accumulator,
  part: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  let signature =
    option.from_result(wire.string_field(part, "thoughtSignature"))
  case wire.field(part, "functionCall"), wire.string_field(part, "text") {
    Ok(call), _ -> append_tool(acc, call, signature)
    Error(Nil), Ok("") -> #(sign_head(acc, signature), [])
    Error(Nil), Ok(text) -> append_text(acc, part_kind(part), text, signature)
    Error(Nil), Error(Nil) -> #(acc, [])
  }
}

fn part_kind(part: JsonValue) -> PartKind {
  case wire.field(part, "thought") {
    Ok(json.Bool(True)) -> Thought
    _ -> Answer
  }
}

// A text or thought part extends the block in progress when it is of the
// same kind, and opens a new block otherwise. The index is the block's
// arrival position, so consumers see one delta stream per block.
fn append_text(
  acc: Accumulator,
  kind: PartKind,
  text: String,
  signature: Option(String),
) -> #(Accumulator, List(StreamEvent)) {
  case kind, acc.blocks {
    Answer, [GmText(index:, text: so_far, signature: existing), ..rest] -> #(
      Accumulator(..acc, blocks: [
        GmText(
          index:,
          text: so_far <> text,
          signature: option.or(signature, existing),
        ),
        ..rest
      ]),
      [Delta(TextDelta(index:, text:))],
    )
    Thought, [GmThinking(index:, thinking: so_far, signature: existing), ..rest]
    -> #(
      Accumulator(..acc, blocks: [
        GmThinking(
          index:,
          thinking: so_far <> text,
          signature: option.or(signature, existing),
        ),
        ..rest
      ]),
      [Delta(ThinkingDelta(index:, thinking: text))],
    )
    Answer, blocks -> {
      let index = list.length(blocks)
      #(
        Accumulator(..acc, blocks: [GmText(index:, text:, signature:), ..blocks]),
        [Delta(TextDelta(index:, text:))],
      )
    }
    Thought, blocks -> {
      let index = list.length(blocks)
      #(
        Accumulator(..acc, blocks: [
          GmThinking(index:, thinking: text, signature:),
          ..blocks
        ]),
        [Delta(ThinkingDelta(index:, thinking: text))],
      )
    }
  }
}

// Attaches a trailing signature to the block in progress. With no block
// to sign, or no signature, nothing changes.
fn sign_head(acc: Accumulator, signature: Option(String)) -> Accumulator {
  case signature, acc.blocks {
    Some(_), [GmText(index:, text:, signature: _), ..rest] ->
      Accumulator(..acc, blocks: [GmText(index:, text:, signature:), ..rest])
    Some(_), [GmThinking(index:, thinking:, signature: _), ..rest] ->
      Accumulator(..acc, blocks: [
        GmThinking(index:, thinking:, signature:),
        ..rest
      ])
    Some(_), [GmTool(index:, call_id:, name:, arguments:, signature: _), ..rest]
    ->
      Accumulator(..acc, blocks: [
        GmTool(index:, call_id:, name:, arguments:, signature:),
        ..rest
      ])
    _, _ -> acc
  }
}

// A function call arrives whole. The API sends an `id` on newer models
// and nothing on older ones; a call without one is named by its function
// and arrival position, which is unique within the message and is what
// the matching tool result will echo.
fn append_tool(
  acc: Accumulator,
  call: JsonValue,
  signature: Option(String),
) -> #(Accumulator, List(StreamEvent)) {
  let index = list.length(acc.blocks)
  let name = wire.string_field_or(call, "name", or: "")
  let call_id =
    wire.string_field(call, "id")
    |> result.lazy_unwrap(fn() { name <> "_" <> int.to_string(index) })
  let arguments = result.unwrap(wire.field(call, "args"), json.Object([]))
  #(
    Accumulator(..acc, blocks: [
      GmTool(index:, call_id:, name:, arguments:, signature:),
      ..acc.blocks
    ]),
    [
      Delta(ToolCallDelta(
        index:,
        call_id:,
        name:,
        arguments_json: json.to_string(arguments),
      )),
    ],
  )
}

// --- settlement ---------------------------------------------------------

fn settle(acc: Accumulator) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(when: acc.done, return: #(acc, []))
  case acc.stop {
    None ->
      fail(
        acc,
        StreamDisconnected(context: "response body ended before a finishReason"),
      )
    Some(stop) -> settle_with_stop(acc, stop)
  }
}

fn settle_with_stop(
  acc: Accumulator,
  stop: StopReason,
) -> #(Accumulator, List(StreamEvent)) {
  let content = build_blocks(list.reverse(acc.blocks))
  let usage = build_usage(acc)

  // Gemini ends a tool-calling turn with plain `STOP`; the presence of a
  // function call is what makes it a tool-use turn, and by the same token
  // a turn that asked for tools has not ended, whatever the raw word says.
  let called_tools = list.any(content, is_tool_call)
  let stop = case stop, called_tools {
    Stop, True -> ToolUse
    _, _ -> stop
  }

  // Spec §1.5 words this as input plus cache-read; this dialect reports
  // no cache write, so the two terms are the whole prompt.
  let input_tokens = usage.input + usage.cache_read
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
      end_turn: option.map(acc.raw_stop, fn(raw) {
        raw == "STOP" && !called_tools
      }),
      timestamp: acc.now,
    )

  // Unreachable by construction (the stop reason above is never
  // Pending), reported totally rather than asserted.
  use settled <- or_fail(stream.settle(assistant), acc, fn(_nil) {
    MalformedStream(corruption_report(
      "a settled assistant message",
      "stop reason pending at end of stream",
    ))
  })
  #(Accumulator(..acc, done: True), [Settled(message: settled, usage:)])
}

fn is_tool_call(block: message.AssistantBlock) -> Bool {
  case block {
    AssistantToolCall(call: _) -> True
    AssistantText(text: _, text_signature: _) -> False
    AssistantThinking(thinking: _, thinking_signature: _, redacted: _) -> False
  }
}

// The settlement combinator: run `then` on success, or fail the stream
// with `to_error(err)` — see the OpenAI adapter's `or_fail`.
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

// Arguments arrived as parsed JSON, so unlike the other two dialects
// there is no argument text to fail on here.
fn build_blocks(blocks: List(GmBlock)) -> List(message.AssistantBlock) {
  list.map(blocks, fn(block) {
    case block {
      GmText(index: _, text:, signature:) ->
        AssistantText(text:, text_signature: signature)
      GmThinking(index: _, thinking:, signature:) ->
        AssistantThinking(
          thinking:,
          thinking_signature: signature,
          redacted: False,
        )
      GmTool(index: _, call_id:, name:, arguments:, signature:) ->
        AssistantToolCall(call: ToolCall(
          id: call_id,
          name:,
          arguments:,
          thought_signature: signature,
          namespace: None,
        ))
    }
  })
}

fn build_usage(acc: Accumulator) -> Usage {
  // `promptTokenCount` is the whole prompt, cached reads included; split
  // the read back out so the ledger's `input` means what it means for the
  // other adapters. Thought tokens are billed as output and are folded
  // into it, while `reasoning` keeps the breakdown.
  let cache_read = int.min(acc.cached_tokens, acc.prompt_tokens)
  let thoughts = option.unwrap(acc.thoughts_tokens, 0)
  let output = acc.candidates_tokens + thoughts
  Usage(
    input: acc.prompt_tokens - cache_read,
    output:,
    cache_read:,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: acc.thoughts_tokens,
    total_tokens: option.unwrap(acc.total_tokens, acc.prompt_tokens + output),
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
