//// The public API-key Responses dialect, independent of Chat Completions.
////
//// Each output item owns indexed parts until their delta, part, item and
//// final-response witnesses agree. Deltas remain ephemeral; only the final
//// verified response settles. Authentication appears only in build_request's
//// outbound header, never in the pure accumulator or diagnostic metadata.
////
//// ## Flow
////
//// `build_request` → `response_machine` → `on_chunk` → `handle_sse` → `dispatch` → `close_item` → `terminal` → `settle`
////
//// 1. `build_request` posts the stateless request; the body comes from
////    `responses_request.body`.
//// 2. `response_machine` starts an `Accumulator` in the `Streaming` life and
////    wires the transport callbacks to it.
//// 3. `on_chunk` bounds the attempt's bytes, feeds a 200 body to the SSE
////    parser and each event to `handle_sse`; other statuses collect the error
////    body for `http_error`. `disconnect_context` retains only structural facts,
////    with `request_id` and `media_type` discarding untrusted header values.
//// 4. `handle_sse` checks the event name against the JSON `"type"` and the
////    sequence number with `sequence`, then calls `dispatch`.
//// 5. `dispatch` gives every supported event its own transition: `add_item`,
////    `add_part`, `change_part`, `close_part`, `add_annotation`, `arguments`
////    and `close_item`; an unknown event goes to `malformed`.
//// 6. `close_item` checks the finished item with `verify_item` against the
////    provider's canonical copy.
//// 7. `terminal` compares the final response with every item witnessed so
////    far, maps the status to a stop reason, and `settle` builds the one
////    assistant message. `fail` and `malformed` move the machine to
////    `Terminal` so only one terminal event ever escapes.

import core/accounting
import core/corruption
import core/json.{type JsonValue}
import core/message
import core/usage_evidence
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/http
import provider/internal/diagnostic
import provider/internal/responses_items as items
import provider/internal/responses_request
import provider/internal/usage_witness
import provider/internal/wire
import provider/model.{type ProviderRequest, type ResolvedModel}
import provider/retry
import provider/stream.{type StreamEvent}

/// The distinct durable API identity for this adapter.
pub const api_name = "openai-responses"

/// The durable dialect identity of a Codex subscription settlement.
pub const subscription_api_name = "codex-subscription"

/// Builds a stateless streaming Responses request. The base includes the API
/// root; the gateway normalizes its trailing slash before dispatch.
///
/// ## Examples
///
/// ```gleam
/// // responses.build_request(base_url: "https://api.openai.com/v1",
/// //   api_key: key, resolved: resolved, request: request)
/// ```
pub fn build_request(
  base_url base_url: String,
  api_key api_key: String,
  resolved resolved: ResolvedModel,
  request request: ProviderRequest,
) -> http.HttpRequest {
  build_request_with_access(base_url, api_key, resolved, request, None)
}

/// Builds an API-key request with an explicit operator access selection.
///
/// ## Examples
///
/// ```gleam
/// // build_request_with_access(base, key, resolved, request, Some(model.DaybreakBlue))
/// ```
pub fn build_request_with_access(
  base_url: String,
  api_key: String,
  resolved: ResolvedModel,
  request: ProviderRequest,
  access: Option(model.CyberAccessProgram),
) -> http.HttpRequest {
  build_request_with_options(base_url, api_key, resolved, request, access, None)
}

/// Builds a Responses request with explicit access and serving policy.
///
/// ## Examples
///
/// ```gleam
/// // build_request_with_options(..., None, Some(model.FastServiceTier))
/// ```
pub fn build_request_with_options(
  base_url: String,
  api_key: String,
  resolved: ResolvedModel,
  request: ProviderRequest,
  access: Option(model.CyberAccessProgram),
  tier: Option(model.ResponsesServiceTier),
) -> http.HttpRequest {
  http.HttpRequest(
    method: "POST",
    url: base_url <> "/responses",
    headers: [
      #("authorization", "Bearer " <> api_key),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: responses_request.body_with_options(resolved, request, access, tier),
  )
}

/// Builds an uncredentialed request for the trusted subscription bridge.
/// Its relative path cannot redirect an OAuth token to a configured host.
///
/// ## Examples
///
/// ```gleam
/// // responses.build_subscription_request(resolved, request)
/// ```
pub fn build_subscription_request(
  resolved: ResolvedModel,
  request: ProviderRequest,
) -> http.HttpRequest {
  build_subscription_request_with_access(resolved, request, None)
}

/// Builds a subscription request with an explicit operator access selection.
///
/// ## Examples
///
/// ```gleam
/// // build_subscription_request_with_access(resolved, request, Some(model.DaybreakBlue))
/// ```
pub fn build_subscription_request_with_access(
  resolved: ResolvedModel,
  request: ProviderRequest,
  access: Option(model.CyberAccessProgram),
) -> http.HttpRequest {
  build_subscription_request_with_options(resolved, request, access, None)
}

/// Builds a Responses request with explicit access and serving policy.
///
/// ## Examples
///
/// ```gleam
/// // build_subscription_request_with_options(..., None, Some(model.FastServiceTier))
/// ```
pub fn build_subscription_request_with_options(
  resolved: ResolvedModel,
  request: ProviderRequest,
  access: Option(model.CyberAccessProgram),
  tier: Option(model.ResponsesServiceTier),
) -> http.HttpRequest {
  http.HttpRequest(
    method: "POST",
    url: "/responses",
    headers: [
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: responses_request.subscription_body_with_options(
      resolved,
      request,
      access,
      tier,
    ),
  )
}

// A failed semantic witness closes the attempt just as settlement does. Both
// paths enter Terminal before returning their one public terminal event.
type Life {
  Streaming
  Terminal
}

// TextDone proves the byte-level witness; Closed separately proves the whole
// part, including annotations. An item cannot skip either boundary.
type Closure {
  Open
  TextDone
  Closed
}

// Summary indices have their own namespace. The other three kinds share the
// content-index namespace and therefore cannot reuse each other's positions.
type PartKind {
  OutputText
  Refusal
  Summary
  Reasoning
}

// The wire index routes provider events, while block names the immutable Loom
// delta position. Neither is inferred later from the position in this list.
type Part {
  Part(
    index: Int,
    block: Int,
    kind: PartKind,
    text: String,
    annotations: List(JsonValue),
    closure: Closure,
  )
}

// Function calls own argument bytes directly. Messages and reasoning items own
// typed parts; the distinction prevents a text event from editing a call.
type ItemKind {
  Message
  Thought
  Function(
    call_id: String,
    name: String,
    namespace: Option(String),
    block: Int,
    arguments: String,
    closure: Closure,
  )
}

// A canonical done item replaces no live content: it is retained only after
// agreeing with the accumulated parts. Encrypted-only reasoning has no part
// event, so its durable empty block receives an index at item completion.
type Item {
  Item(
    index: Int,
    id: String,
    kind: ItemKind,
    phase: Option(String),
    parts: List(Part),
    done: Option(JsonValue),
    empty_block: Option(Int),
  )
}

/// Pure state for one attempt. Items remain keyed by both provider index and
/// identity; terminal state makes every later chunk an explicit no-op.
pub opaque type Accumulator {
  /// One attempt's parser and validation state; no request or credential is
  /// retained here. The response byte count includes discarded SSE framing.
  Accumulator(
    /// The fixed API dialect selected before any remote bytes arrive.
    api: String,
    /// Configured identity and limits, not the remote model's claims.
    resolved: ResolvedModel,
    /// Injected settlement timestamp.
    now: Int,
    /// HTTP status received before body chunks.
    status: Int,
    /// Validated upstream correlation ID, or a fixed absence/refusal marker.
    request_id: String,
    /// Fixed media-type category, never the remote header value.
    media_type: String,
    /// Parsed retry delay, used only for HTTP errors.
    retry_after: Option(Int),
    /// Error-body bytes retained under the shared 64 KiB bound.
    error_body: BitArray,
    /// Shared bounded incremental SSE parser.
    sse: stream.SseParser,
    /// Whether further remote input may still change the attempt.
    life: Life,
    /// Original response ID and remote model, checked at every witness.
    identity: Option(#(String, String)),
    /// Last present sequence number; omission does not erase it.
    sequence: Option(Int),
    /// Bounded structural witness for the last complete event, never remote text.
    event: String,
    /// Bounded numeric positions from the same event, separated for label limits.
    positions: String,
    /// Independently addressable item states, retained through final proof.
    items: List(Item),
    /// Next never-reused durable block position.
    next_block: Int,
    /// Total delivered body bytes for this attempt.
    bytes: Int,
    /// Latest measured snapshot, never the sum of repeated provider reports.
    usage: message.Usage,
    /// Fixed count paths whose omission a later snapshot cannot erase.
    witness: usage_witness.Witness,
  )
}

/// Supplies the same sans-I/O fold as the other adapters. EOF cannot substitute
/// for a final Responses witness.
///
/// ## Examples
///
/// ```gleam
/// // let machine = responses.response_machine(resolved, now: 1000)
/// ```
pub fn response_machine(
  resolved: ResolvedModel,
  now now: Int,
) -> stream.ResponseMachine(Accumulator) {
  machine_for(resolved, now, api_name)
}

/// Supplies the same verified Responses fold with subscription identity.
///
/// ## Examples
///
/// ```gleam
/// // responses.subscription_response_machine(resolved, now: 1000)
/// ```
pub fn subscription_response_machine(
  resolved: ResolvedModel,
  now now: Int,
) -> stream.ResponseMachine(Accumulator) {
  machine_for(resolved, now, subscription_api_name)
}

/// Builds an Accumulator and ResponseMachine configured for the resolved model.
fn machine_for(
  resolved: ResolvedModel,
  now: Int,
  api: String,
) -> stream.ResponseMachine(Accumulator) {
  stream.ResponseMachine(
    init: Accumulator(
      api:,
      resolved:,
      now:,
      status: 0,
      request_id: "absent",
      media_type: "absent",
      retry_after: None,
      error_body: <<>>,
      sse: stream.new_parser(),
      life: Streaming,
      identity: None,
      sequence: None,
      event: "event=none",
      positions: "",
      items: [],
      next_block: 0,
      bytes: 0,
      usage: accounting.unknown_usage(billing(api)),
      witness: usage_witness.new(),
    ),
    on_status: fn(acc, status, headers) {
      case acc.life {
        Terminal -> acc
        Streaming ->
          Accumulator(
            ..acc,
            status:,
            request_id: request_id(headers),
            media_type: media_type(headers),
            retry_after: wire.retry_after_ms(headers),
          )
      }
    },
    on_chunk: on_chunk,
    usage: fn(acc) { acc.usage },
    on_end: fn(acc) {
      case acc.status {
        200 ->
          fail(
            acc,
            stream.StreamDisconnected(
              "Responses ended before a verified terminal; "
              <> disconnect_context(acc),
            ),
          ).1
        status -> fail(acc, http_error(acc, status)).1
      }
    },
    on_failure: fn(acc, _) {
      fail(
        acc,
        stream.TransportFailed(
          "Responses transport failed; " <> disconnect_context(acc),
        ),
      ).1
    },
  )
}

// Disconnect diagnostics describe the last complete event even when the final
// chunk is only a partial SSE frame. A known HTTP status is not proof that a
// Responses terminal arrived, and none of these facts establish capacity.
/// Formats diagnostic disconnect context string from accumulator state.
fn disconnect_context(acc: Accumulator) -> String {
  "status="
  <> diagnostic_number(Some(acc.status))
  <> "; "
  <> acc.event
  <> "; last_seq="
  <> diagnostic_number(acc.sequence)
  <> "; bytes="
  <> diagnostic_number(Some(acc.bytes))
  <> "; media="
  <> acc.media_type
  <> "; upstream_request_id="
  <> acc.request_id
}

// Correlation IDs are the only remote strings retained here. Accept only the
// fixed OpenAI request-ID shape; a proxy's arbitrary header is not log text.
/// Extracts and validates x-request-id header matching req_ prefix with 32 hex characters.
fn request_id(headers: List(#(String, String))) -> String {
  case list.key_find(headers, "x-request-id") {
    Error(Nil) -> "absent"
    Ok(value) ->
      case bit_array.from_string(value) {
        <<"req_":utf8, suffix:bytes-size(32)>> ->
          case hex_bytes(suffix) {
            True -> value
            False -> "invalid"
          }
        _ -> "invalid"
      }
  }
}

// The validated suffix is exactly 32 bytes, so this walk is constant-bounded.
/// Verifies that all bytes in bit array are valid hexadecimal characters.
fn hex_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<digit:8, rest:bits>> if digit >= 48 && digit <= 57 -> hex_bytes(rest)
    <<digit:8, rest:bits>> if digit >= 97 && digit <= 102 -> hex_bytes(rest)
    _ -> False
  }
}

// A media category distinguishes an SSE stream from a 200 proxy error page.
// Parameters and unfamiliar values are discarded, including oversized headers.
/// Extracts media type category from content-type header.
fn media_type(headers: List(#(String, String))) -> String {
  // Extract content-type header if present.
  case list.key_find(headers, "content-type") {
    Error(Nil) -> "absent"
    Ok(value) -> {
      use <- bool.guard(
        bit_array.byte_size(bit_array.from_string(value)) > 128,
        "other",
      )

      // Map parsed media type string to known category.
      case
        value
        |> string.split(";")
        |> list.first
        |> result.map(string.trim)
        |> result.map(string.lowercase)
      {
        Ok("text/event-stream") -> "sse"
        Ok("application/json") -> "json"
        Ok("text/html") -> "html"
        Ok(_) | Error(Nil) -> "other"
      }
    }
  }
}

// Framing and attempt limits are independent of semantic assembly. Reverse
// accumulation avoids copying every earlier delta for each event in a chunk.
/// Folds incoming SSE body chunks into accumulator and parses events.
fn on_chunk(
  acc: Accumulator,
  chunk: BitArray,
) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(acc.life == Terminal, #(acc, []))
  let acc = Accumulator(..acc, bytes: acc.bytes + bit_array.byte_size(chunk))
  use <- bool.lazy_guard(acc.bytes > 16_777_216, fn() {
    malformed(acc, "stream_bytes")
  })

  // Process 200 streaming events or collect error response body.
  case acc.status {
    200 -> {
      let #(sse, events) = stream.feed(acc.sse, chunk)
      let #(acc, reversed) =
        list.fold(events, #(Accumulator(..acc, sse:), []), fn(state, event) {
          let #(acc, emitted) = state
          let #(acc, next) = handle_sse(acc, event)
          #(
            acc,
            list.fold(next, emitted, fn(events, event) { [event, ..events] }),
          )
        })
      #(acc, list.reverse(reversed))
    }
    _ ->
      case diagnostic.append_error_body(acc.error_body, chunk) {
        Ok(error_body) -> #(Accumulator(..acc, error_body:), [])
        Error(Nil) -> malformed(acc, "error_body_bytes")
      }
  }
}

// The failure describes the violated boundary, never the remote data. A JSON
// parser excerpt could otherwise copy provider-reflected credentials here.
/// Emits a MalformedStream terminal event for a protocol boundary failure.
fn malformed(
  acc: Accumulator,
  reason: String,
) -> #(Accumulator, List(StreamEvent)) {
  fail(
    acc,
    stream.MalformedStream(corruption.report(
      at: "provider/adapter/responses",
      on: "provider stream; " <> acc.event,
      expected: "consistent Responses item and terminal witnesses",
      context: "reason="
        <> reason
        <> acc.positions
        <> "; last_seq="
        <> diagnostic_number(acc.sequence)
        <> "; bytes="
        <> diagnostic_number(Some(acc.bytes)),
    )),
  )
}

/// Transitions accumulator to Terminal state and returns a Failed stream event.
fn fail(
  acc: Accumulator,
  error: stream.ProviderError,
) -> #(Accumulator, List(StreamEvent)) {
  case acc.life {
    Terminal -> #(acc, [])
    Streaming -> #(Accumulator(..acc, life: Terminal), [
      stream.Failed(error, accounting.from_usage(acc.usage)),
    ])
  }
}

// The adapter's short-circuit combinator keeps decoder failures on the same
// once-only terminal path as failures discovered by the transition guards.
/// Unwraps Result or fails accumulator with MalformedStream.
fn or_malformed(
  value: Result(a, Nil),
  acc: Accumulator,
  reason: String,
  then: fn(a) -> #(Accumulator, List(StreamEvent)),
) -> #(Accumulator, List(StreamEvent)) {
  or_invalid(result.replace_error(value, reason), acc, then)
}

// Internal semantic validators carry a fixed reason through their composed
// checks. No remote string is ever used as this error value.
/// Unwraps Result or fails accumulator with InvalidStream.
fn or_invalid(
  value: Result(a, String),
  acc: Accumulator,
  then: fn(a) -> #(Accumulator, List(StreamEvent)),
) -> #(Accumulator, List(StreamEvent)) {
  case value {
    Ok(value) -> then(value)
    Error(reason) -> malformed(acc, reason)
  }
}

// SSE event names, when present, must agree with the JSON discriminator.
// Parsing remains total, and an already terminal attempt ignores even junk.
/// Parses SSE messages, validates sequence ordering, and dispatches events.
fn handle_sse(
  acc: Accumulator,
  event: stream.SseEvent,
) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(acc.life == Terminal, #(acc, []))
  let acc = Accumulator(..acc, event: "event=unparsed", positions: "")

  // Process SSE framing error or parse message payload.
  case event {
    stream.SseMalformed(..) -> malformed(acc, "sse_framing")
    stream.SseMessage(event: name, data:) -> {
      use value <- or_malformed(
        result.replace_error(json.parse(data), Nil),
        acc,
        "json_decode",
      )
      let #(event, positions) = event_witness(value)
      let acc = Accumulator(..acc, event:, positions:)
      use kind <- or_malformed(
        wire.string_field(value, "type"),
        acc,
        "event_type",
      )
      use <- bool.lazy_guard(name != None && name != Some(kind), fn() {
        malformed(acc, "event_name")
      })
      use sequence <- or_malformed(
        sequence(acc.sequence, value),
        acc,
        "sequence",
      )
      dispatch(Accumulator(..acc, sequence:), kind, value)
    }
  }
}

// Only protocol literals and bounded numbers cross into a failure report. An
// unknown event name may contain reflected secrets, so it is never echoed.
/// Extracts safe diagnostic event name and position markers from message payload.
fn event_witness(value: JsonValue) -> #(String, String) {
  let kind = wire.string_field_or(value, "type", "")

  // Normalize event type to known literal or sanitize unrecognized name.
  let kind = case kind {
    "keepalive"
    | "response.created"
    | "response.in_progress"
    | "response.metadata"
    | "response.output_item.added"
    | "response.content_part.added"
    | "response.reasoning_summary_part.added"
    | "response.output_text.delta"
    | "response.refusal.delta"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_text.delta"
    | "response.output_text.done"
    | "response.refusal.done"
    | "response.reasoning_summary_text.done"
    | "response.reasoning_text.done"
    | "response.content_part.done"
    | "response.reasoning_summary_part.done"
    | "response.output_text.annotation.added"
    | "response.function_call_arguments.delta"
    | "response.function_call_arguments.done"
    | "response.output_item.done"
    | "response.completed"
    | "response.incomplete"
    | "response.cancelled"
    | "response.failed"
    | "error" -> kind
    _ -> "unknown"
  }

  #(
    "event=" <> kind <> "; seq=" <> diagnostic_field(value, "sequence_number"),
    "; output="
      <> diagnostic_field(value, "output_index")
      <> "; content="
      <> diagnostic_field(value, "content_index")
      <> "; summary="
      <> diagnostic_field(value, "summary_index")
      <> "; annotation="
      <> diagnostic_field(value, "annotation_index"),
  )
}

// Missing and malformed numbers remain distinguishable without serializing the
// provider value. Large arbitrary-precision integers receive a fixed marker.
/// Formats an optional field name into diagnostic string representation.
fn diagnostic_field(value: JsonValue, name: String) -> String {
  case wire.field(value, name) {
    Error(Nil) -> "absent"
    Ok(json.Int(number)) -> diagnostic_number(Some(number))
    Ok(_) -> "invalid"
  }
}

/// Formats an optional integer value into diagnostic string representation.
fn diagnostic_number(value: Option(Int)) -> String {
  case value {
    None -> "absent"
    Some(number) if number < -2_147_483_648 || number > 2_147_483_647 -> "range"
    Some(number) -> int.to_string(number)
  }
}

// Compatible endpoints may omit sequence numbers. A later present value must
// still advance beyond the last observed one, including across omissions.
/// Validates monotonic increment of stream sequence numbers.
fn sequence(
  previous: Option(Int),
  value: JsonValue,
) -> Result(Option(Int), Nil) {
  case wire.field(value, "sequence_number") {
    Error(Nil) -> Ok(previous)
    Ok(json.Int(next)) ->
      case previous {
        Some(old) if next <= old -> Error(Nil)
        _ if next < 0 -> Error(Nil)
        _ -> Ok(Some(next))
      }
    Ok(_) -> Error(Nil)
  }
}

// Every supported semantic event has an explicit transition. Unknown content
// fails instead of silently changing the meaning of a tool or assistant turn.
/// Dispatches parsed event document to appropriate state machine transition.
fn dispatch(
  acc: Accumulator,
  kind: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case kind {
    // Subscription streams send this control frame during long reasoning.
    // Framing and sequence validation already ran; no semantic witness changes.
    "keepalive" -> #(acc, [])

    // Subscription inference may send moderation metadata between content
    // events. It changes no item or terminal witness, but must belong to the
    // response whose identity was established by response.created.
    "response.metadata" -> {
      use response_id <- or_malformed(
        wire.string_field(value, "response_id"),
        acc,
        "metadata_response_id",
      )

      // Verify metadata response ID matches initial response identity.
      case acc.identity {
        Some(#(id, _)) if id == response_id -> #(acc, [])
        _ -> malformed(acc, "metadata_identity")
      }
    }

    "response.created" | "response.in_progress" -> {
      use response <- or_malformed(
        wire.field(value, "response"),
        acc,
        "response_field",
      )
      use acc <- or_malformed(
        record_usage(acc, response, usage_evidence.Partial),
        acc,
        "initial_usage",
      )
      use identity <- or_malformed(
        identity(acc, response),
        acc,
        "initial_identity",
      )
      use <- bool.lazy_guard(
        wire.string_field(response, "status") != Ok("in_progress"),
        fn() { malformed(acc, "initial_status") },
      )
      #(Accumulator(..acc, identity: Some(identity)), [])
    }
    "response.output_item.added" -> add_item(acc, value)
    "response.content_part.added" | "response.reasoning_summary_part.added" ->
      add_part(acc, kind, value)
    "response.output_text.delta"
    | "response.refusal.delta"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_text.delta" -> change_part(acc, kind, value)
    "response.output_text.done"
    | "response.refusal.done"
    | "response.reasoning_summary_text.done"
    | "response.reasoning_text.done" -> change_part(acc, kind, value)
    "response.content_part.done" | "response.reasoning_summary_part.done" ->
      close_part(acc, kind, value)
    "response.output_text.annotation.added" -> add_annotation(acc, value)
    "response.function_call_arguments.delta"
    | "response.function_call_arguments.done" -> arguments(acc, kind, value)
    "response.output_item.done" -> close_item(acc, value)
    "response.completed" | "response.incomplete" | "response.cancelled" ->
      terminal(acc, kind, value)
    "response.failed" -> {
      let response =
        result.unwrap(wire.field(value, "response"), json.Object([]))
      use acc <- or_malformed(
        record_usage(acc, response, usage_evidence.Complete),
        acc,
        "failed_usage",
      )
      let error = result.unwrap(wire.field(response, "error"), json.Null)
      let #(code, description) = error_fields(error)
      fail(acc, stream.StreamError(code, description))
    }
    "error" -> {
      let #(code, description) = error_fields(value)
      fail(acc, stream.StreamError(code, description))
    }
    _ -> malformed(acc, "event_unsupported")
  }
}

/// Extracts and validates response ID and model from response object.
fn identity(
  acc: Accumulator,
  response: JsonValue,
) -> Result(#(String, String), Nil) {
  use id <- result.try(items.nonempty(response, "id"))
  use model <- result.try(items.nonempty(response, "model"))

  // Verify identity consistency against previous established identity.
  case acc.identity {
    None -> Ok(#(id, model))
    Some(existing) if existing == #(id, model) -> Ok(existing)
    Some(_) -> Error(Nil)
  }
}

// Known error codes retain retry and overflow semantics without copying the
// remote message, which may contain request headers or credentials.
/// Maps raw error object to sanitized error code and safe description.
fn error_fields(value: JsonValue) -> #(String, String) {
  let code =
    wire.string_field_or(value, "code", wire.string_field_or(value, "type", ""))

  // Classify error code into standard provider error category.
  case code {
    "overloaded_error"
    | "rate_limit_error"
    | "api_error"
    | "timeout_error"
    | "server_error"
    | "internal_server_error" -> #(
      code,
      "Responses provider reported a transient failure",
    )
    "rate_limit_exceeded" -> #(
      "rate_limit_error",
      "Responses provider rate limit exceeded",
    )
    "context_length_exceeded" -> #(
      "context_length_exceeded",
      "maximum context length exceeded",
    )
    _ -> #("responses_error", "Responses provider reported failure")
  }
}

/// Constructs a ProviderError from collected error response body.
fn http_error(acc: Accumulator, status: Int) -> stream.ProviderError {
  let value =
    acc.error_body
    |> bit_array.to_string
    |> result.try(fn(text) { json.parse(text) |> result.replace_error(Nil) })
    |> result.try(wire.field(_, "error"))
    |> result.unwrap(json.Null)
  let #(code, description) = error_fields(value)
  stream.HttpError(status, code, description, acc.retry_after)
}

// Item publication reserves both identities before any deltas are accepted.
// A call's synthetic block is allocated here because it has no part-added event.
/// Handles response.output_item.added event to initialize message or call item.
fn add_item(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use index <- or_malformed(
    wire.int_field(value, "output_index"),
    acc,
    "item_index",
  )
  use value <- or_malformed(wire.field(value, "item"), acc, "item_field")
  use id <- or_malformed(items.nonempty(value, "id"), acc, "item_id")
  use kind <- or_malformed(wire.string_field(value, "type"), acc, "item_type")

  // Extract optional message phase if item is a message.
  use phase <- or_malformed(
    case kind {
      "message" -> items.message_phase(value)
      _ -> Ok(None)
    },
    acc,
    "item_phase",
  )

  use start_status <- or_malformed(
    items.optional_string(value, "status"),
    acc,
    "item_status",
  )

  // Message items can arrive marked completed before their parts stream. That
  // metadata never closes our item: every content and item witness is required.
  use <- bool.lazy_guard(
    start_status != None
      && start_status != Some("in_progress")
      && start_status != Some("completed"),
    fn() { malformed(acc, "item_start_status") },
  )
  use <- bool.lazy_guard(
    acc.identity == None
      || index < 0
      || list.any(acc.items, fn(item) { item.index == index || item.id == id }),
    fn() { malformed(acc, "item_start_identity") },
  )

  // Validate item type and structure before creating item record.
  use kind <- or_malformed(
    case kind {
      "message" -> {
        use <- bool.guard(
          wire.string_field(value, "role") != Ok("assistant")
            || wire.array_field(value, "content") != Ok([]),
          Error(Nil),
        )
        Ok(Message)
      }
      "reasoning" -> {
        use <- bool.guard(
          wire.array_field(value, "summary") != Ok([]),
          Error(Nil),
        )
        Ok(Thought)
      }
      "function_call" -> {
        use call_id <- result.try(items.nonempty(value, "call_id"))
        use name <- result.try(items.nonempty(value, "name"))
        use namespace <- result.try(items.function_namespace(value))

        // A subscription request offers only the fixed local namespace. A
        // remote label cannot turn another namespace into Loom authority.
        use <- bool.guard(
          acc.api == subscription_api_name && namespace != Some("loom"),
          Error(Nil),
        )
        use <- bool.guard(
          wire.string_field(value, "arguments") != Ok(""),
          Error(Nil),
        )
        use <- bool.guard(
          list.any(acc.items, fn(item) {
            case item.kind {
              Function(call_id: other, ..) -> other == call_id
              _ -> False
            }
          }),
          Error(Nil),
        )
        Ok(Function(
          call_id:,
          name:,
          namespace:,
          block: acc.next_block,
          arguments: "",
          closure: Open,
        ))
      }
      _ -> Error(Nil)
    },
    acc,
    "item_start",
  )

  // Increment block index if item is a function call.
  let next_block = case kind {
    Function(..) -> acc.next_block + 1
    _ -> acc.next_block
  }

  #(
    Accumulator(
      ..acc,
      items: [
        Item(
          index:,
          id:,
          kind:,
          phase:,
          parts: [],
          done: None,
          empty_block: None,
        ),
        ..acc.items
      ],
      next_block:,
    ),
    [],
  )
}

// Both provider keys must name the same live item. A late fragment cannot
// reopen an item whose closing witness has already been accepted.
/// Locates matching unclosed item by output index and item ID.
fn find_item(acc: Accumulator, value: JsonValue) -> Result(Item, Nil) {
  use index <- result.try(wire.int_field(value, "output_index"))
  use id <- result.try(items.nonempty(value, "item_id"))
  list.find(acc.items, fn(item) {
    item.index == index && item.id == id && item.done == None
  })
}

/// Updates matching item in accumulator items list.
fn replace(acc: Accumulator, item: Item) -> Accumulator {
  Accumulator(
    ..acc,
    items: list.map(acc.items, fn(old) {
      case old.index == item.index {
        True -> item
        False -> old
      }
    }),
  )
}

/// Extracts part index from event payload based on event family.
fn part_index(kind: String, value: JsonValue) -> Result(Int, Nil) {
  case kind {
    "response.reasoning_summary_part.added"
    | "response.reasoning_summary_part.done"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_summary_text.done" ->
      wire.int_field(value, "summary_index")
    _ -> wire.int_field(value, "content_index")
  }
}

// A part starts empty and receives its permanent delta index exactly once.
// The event family and part kind must agree on the index namespace.
/// Adds a new content part to an active item.
fn add_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc, "part_item")
  use index <- or_malformed(part_index(event, value), acc, "part_index")
  use raw <- or_malformed(wire.field(value, "part"), acc, "part_field")
  use raw <- or_malformed(items.part(raw), acc, "part_decode")

  // Determine part kind based on wire type and parent item kind.
  use kind <- or_malformed(
    case wire.string_field(raw, "type"), item.kind {
      Ok("output_text"), Message -> Ok(OutputText)
      Ok("refusal"), Message -> Ok(Refusal)
      Ok("summary_text"), Thought -> Ok(Summary)
      Ok("reasoning_text"), Thought -> Ok(Reasoning)
      _, _ -> Error(Nil)
    },
    acc,
    "part_kind",
  )

  use <- bool.lazy_guard(
    index < 0
      || list.any(item.parts, fn(part) {
      part.index == index && same_namespace(part.kind, kind)
    })
      || { kind == Summary }
      != { event == "response.reasoning_summary_part.added" }
      || part_text(raw, kind) != ""
      || result.unwrap(wire.array_field(raw, "annotations"), []) != [],
    fn() { malformed(acc, "part_start") },
  )
  let part =
    Part(
      index:,
      block: acc.next_block,
      kind:,
      text: "",
      annotations: [],
      closure: Open,
    )
  #(
    Accumulator(
      ..replace(acc, Item(..item, parts: [part, ..item.parts])),
      next_block: acc.next_block + 1,
    ),
    [],
  )
}

/// Maps event type string to corresponding PartKind.
fn event_part_kind(kind: String) -> PartKind {
  case kind {
    "response.refusal.delta" | "response.refusal.done" -> Refusal
    "response.reasoning_summary_text.delta"
    | "response.reasoning_summary_text.done" -> Summary
    "response.reasoning_text.delta" | "response.reasoning_text.done" ->
      Reasoning
    _ -> OutputText
  }
}

fn same_namespace(left: PartKind, right: PartKind) -> Bool {
  { left == Summary } == { right == Summary }
}

/// Extracts text string from a content part JSON value based on part kind.
fn part_text(value: JsonValue, kind: PartKind) -> String {
  wire.string_field_or(
    value,
    case kind {
      Refusal -> "refusal"
      _ -> "text"
    },
    "",
  )
}

// A text-done event compares exact bytes and emits nothing. Only an open part
// accepts deltas, so duplicate completion cannot append content twice.
/// Updates content part text or marks part as text-done.
fn change_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc, "text_item")
  use index <- or_malformed(part_index(event, value), acc, "text_index")

  // Find the matching open part in the active output item.
  let kind = event_part_kind(event)
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.kind == kind && part.closure == Open
    }),
    acc,
    "text_part",
  )

  // Check whether this event completes the active text part.
  let done =
    list.contains(
      [
        "response.output_text.done",
        "response.refusal.done",
        "response.reasoning_summary_text.done",
        "response.reasoning_text.done",
      ],
      event,
    )
  use text <- or_malformed(
    wire.string_field(value, case done, kind {
      False, _ -> "delta"
      True, Refusal -> "refusal"
      True, _ -> "text"
    }),
    acc,
    "text_field",
  )
  use <- bool.lazy_guard(done && text != part.text, fn() {
    malformed(acc, "text_done_witness")
  })

  // Update the matched part and reassemble the parent item.
  let next = case done {
    True -> Part(..part, closure: TextDone)
    False -> Part(..part, text: part.text <> text)
  }

  let item =
    Item(
      ..item,
      parts: list.map(item.parts, fn(old) {
        case old.block == part.block {
          True -> next
          False -> old
        }
      }),
    )

  // Emit text or thinking delta if not done.
  let events = case done, kind {
    True, _ -> []
    False, OutputText | False, Refusal -> [
      stream.Delta(stream.TextDelta(part.block, text)),
    ]
    False, Summary | False, Reasoning -> [
      stream.Delta(stream.ThinkingDelta(part.block, text)),
    ]
  }

  #(replace(acc, item), events)
}

/// Encodes a Part record into its wire JSON representation.
fn part_value(part: Part) -> JsonValue {
  case part.kind {
    OutputText ->
      json.Object([
        #("type", json.String("output_text")),
        #("text", json.String(part.text)),
        #("annotations", json.Array(part.annotations)),
      ])
    Refusal ->
      json.Object([
        #("type", json.String("refusal")),
        #("refusal", json.String(part.text)),
      ])
    Summary ->
      json.Object([
        #("type", json.String("summary_text")),
        #("text", json.String(part.text)),
      ])
    Reasoning ->
      json.Object([
        #("type", json.String("reasoning_text")),
        #("text", json.String(part.text)),
      ])
  }
}

// The part witness additionally covers annotations and the content kind;
// equal text alone is not enough to close a different semantic part.
/// Closes an open content part after verifying completion.
fn close_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc, "part_done_item")
  use index <- or_malformed(part_index(event, value), acc, "part_done_index")
  use raw <- or_malformed(wire.field(value, "part"), acc, "part_done_field")
  use raw <- or_malformed(items.part(raw), acc, "part_done_decode")
  use <- bool.lazy_guard(
    { wire.string_field(raw, "type") == Ok("summary_text") }
      != { event == "response.reasoning_summary_part.done" },
    fn() { malformed(acc, "part_done_namespace") },
  )
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.closure == TextDone && part_value(part) == raw
    }),
    acc,
    "part_done_witness",
  )
  #(
    replace(
      acc,
      Item(
        ..item,
        parts: list.map(item.parts, fn(old) {
          case old.block == part.block {
            True -> Part(..old, closure: Closed)
            False -> old
          }
        }),
      ),
    ),
    [],
  )
}

// An annotation is a bounded replay field, not a new text delta. Its index
// must append to the exact part's citation sequence before that part closes.
/// Adds a citation annotation to an active content part.
fn add_annotation(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc, "annotation_item")
  use index <- or_malformed(
    wire.int_field(value, "content_index"),
    acc,
    "annotation_content_index",
  )
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.kind == OutputText && part.closure != Closed
    }),
    acc,
    "annotation_part",
  )
  use annotation_index <- or_malformed(
    wire.int_field(value, "annotation_index"),
    acc,
    "annotation_index",
  )
  use <- bool.lazy_guard(
    annotation_index != list.length(part.annotations),
    fn() { malformed(acc, "annotation_order") },
  )
  use raw <- or_malformed(
    wire.field(value, "annotation"),
    acc,
    "annotation_field",
  )
  use annotation <- or_malformed(
    items.annotation(raw),
    acc,
    "annotation_decode",
  )
  let next =
    Part(..part, annotations: list.append(part.annotations, [annotation]))
  #(
    replace(
      acc,
      Item(
        ..item,
        parts: list.map(item.parts, fn(old) {
          case old.block == part.block {
            True -> next
            False -> old
          }
        }),
      ),
    ),
    [],
  )
}

// Argument text is provider protocol until all witnesses agree. Whether that
// agreed text is valid model-authored JSON is decided later by wire.tool_arguments.
/// Handles streaming function call arguments delta and done events.
fn arguments(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc, "arguments_item")

  // Extract function call fields from active unclosed function item.
  use fields <- or_malformed(
    case item.kind {
      Function(call_id:, name:, namespace:, block:, arguments:, closure: Open) ->
        Ok(#(call_id, name, namespace, block, arguments))
      _ -> Error(Nil)
    },
    acc,
    "arguments_open",
  )

  let #(call_id, name, namespace, block, previous) = fields
  use named <- or_malformed(
    items.optional_string(value, "name"),
    acc,
    "arguments_name",
  )
  use called <- or_malformed(
    items.optional_string(value, "call_id"),
    acc,
    "arguments_call_id",
  )
  use namespaced <- or_malformed(
    items.function_namespace(value),
    acc,
    "arguments_namespace",
  )

  // Deltas may omit the namespace, but an explicit witness must agree with
  // the item that allocated this block before any arguments were emitted.
  use <- bool.lazy_guard(
    { named != None && named != Some(name) }
      || { called != None && called != Some(call_id) }
      || { namespaced != None && namespaced != namespace },
    fn() { malformed(acc, "arguments_identity") },
  )
  let done = event == "response.function_call_arguments.done"
  use text <- or_malformed(
    wire.string_field(value, case done {
      True -> "arguments"
      False -> "delta"
    }),
    acc,
    "arguments_field",
  )
  use <- bool.lazy_guard(done && text != previous, fn() {
    malformed(acc, "arguments_done_witness")
  })

  // Update argument text and emit ToolCallDelta if not done.
  let #(arguments, closure, events) = case done {
    True -> #(previous, TextDone, [])
    False -> #(previous <> text, Open, [
      stream.Delta(stream.ToolCallDelta(block, call_id, name, text)),
    ])
  }

  #(
    replace(
      acc,
      Item(
        ..item,
        kind: Function(
          call_id:,
          name:,
          namespace:,
          block:,
          arguments:,
          closure:,
        ),
      ),
    ),
    events,
  )
}

// Canonicalization removes unknown metadata before comparison, but it cannot
// replace any streamed content. Every part must already have its own closure.
/// Finalizes an output item and verifies consistency against canonical item payload.
fn close_item(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use index <- or_malformed(
    wire.int_field(value, "output_index"),
    acc,
    "item_done_index",
  )
  use raw <- or_malformed(wire.field(value, "item"), acc, "item_done_field")
  use canonical <- or_malformed(items.item(raw), acc, "item_done_decode")
  use item <- or_malformed(
    list.find(acc.items, fn(item) {
      item.index == index
      && item.done == None
      && wire.string_field(canonical, "id") == Ok(item.id)
    }),
    acc,
    "item_done_lookup",
  )
  use Nil <- or_invalid(verify_item(item, canonical), acc)

  // Allocate empty thinking block if item is an empty thought.
  let #(empty_block, next_block) = case item.kind, item.parts {
    Thought, [] -> #(Some(acc.next_block), acc.next_block + 1)
    _, _ -> #(None, acc.next_block)
  }

  #(
    Accumulator(
      ..replace(acc, Item(..item, done: Some(canonical), empty_block:)),
      next_block:,
    ),
    [],
  )
}

// Part arrays are indexed arrays, not sparse maps. Summary and content arrays
// each prove their own contiguous positions before matching the item witness.
/// Verifies completed item consistency and part continuity against canonical value.
fn verify_item(item: Item, canonical: JsonValue) -> Result(Nil, String) {
  // A supplied initial phase is a witness, not a default. An omitted phase
  // may be learned at completion, but an observed one cannot be rewritten.
  use <- bool.guard(
    item.phase != None
      && item.phase != option.from_result(wire.string_field(canonical, "phase")),
    Error("item_phase_mismatch"),
  )
  use <- bool.guard(
    list.any(item.parts, fn(part) { part.closure != Closed }),
    Error("item_parts_unclosed"),
  )
  use <- bool.guard(
    wire.string_field(canonical, "status") == Ok("in_progress"),
    Error("item_status_in_progress"),
  )
  let parts = list.sort(item.parts, fn(a, b) { int.compare(a.index, b.index) })
  use <- bool.guard(
    !contiguous(list.filter(parts, fn(part) { part.kind == Summary }))
      || !contiguous(list.filter(parts, fn(part) { part.kind != Summary })),
    Error("item_parts_noncontiguous"),
  )

  // Match item kind and verify fields match canonical item object.
  case item.kind {
    Function(call_id:, name:, namespace:, arguments:, closure: TextDone, ..) -> {
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("function_call")
          || wire.string_field(canonical, "call_id") != Ok(call_id)
          || wire.string_field(canonical, "name") != Ok(name)
          || items.function_namespace(canonical) != Ok(namespace)
          || wire.string_field(canonical, "arguments") != Ok(arguments),
        Error("item_function_mismatch"),
      )
      Ok(Nil)
    }
    Function(..) -> Error("item_arguments_unclosed")
    Message -> {
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("message")
          || wire.array_field(canonical, "content")
          != Ok(list.map(parts, part_value)),
        Error("item_message_mismatch"),
      )
      Ok(Nil)
    }
    Thought -> {
      let summary = list.filter(parts, fn(part) { part.kind == Summary })
      let content = list.filter(parts, fn(part) { part.kind == Reasoning })
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("reasoning")
          || wire.array_field(canonical, "summary")
          != Ok(list.map(summary, part_value))
          || result.unwrap(wire.array_field(canonical, "content"), [])
          != list.map(content, part_value),
        Error("item_reasoning_mismatch"),
      )
      Ok(Nil)
    }
  }
}

fn contiguous(parts: List(Part)) -> Bool {
  list.all(
    list.index_map(parts, fn(part, index) { part.index == index }),
    fn(value) { value },
  )
}

// A terminal proves response identity, status and absence of error. Subscription
// terminals may carry an empty output array after streaming the item witnesses;
// every item must still have closed. A populated array must match those items.
// EOF is never this proof.
/// Processes terminal response event, validating all items and establishing outcome.
fn terminal(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use response <- or_malformed(
    wire.field(value, "response"),
    acc,
    "terminal_response",
  )

  // Record response usage evidence and extract identity fact.
  use acc <- or_malformed(
    record_usage(acc, response, usage_evidence.Complete),
    acc,
    "terminal_usage",
  )
  use identity <- or_malformed(
    identity(acc, response),
    acc,
    "terminal_identity",
  )

  // Guard against unexpected missing creation context or response error.
  use <- bool.lazy_guard(acc.identity == None, fn() {
    malformed(acc, "terminal_before_created")
  })
  use <- bool.lazy_guard(wire.field(response, "error") != Error(Nil), fn() {
    malformed(acc, "terminal_error")
  })

  // Extract output array and decode individual output items.
  use output <- or_malformed(
    wire.array_field(response, "output"),
    acc,
    "terminal_output",
  )
  use output <- or_malformed(
    list.try_map(output, items.item),
    acc,
    "terminal_item_decode",
  )

  // Order output items and extract finished item payloads.
  let ordered = list.sort(acc.items, fn(a, b) { int.compare(a.index, b.index) })
  let expected =
    list.filter_map(ordered, fn(item) {
      case item.done {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    })

  // Live plan inference does not repeat output in its terminal envelope. Only
  // this dialect may use the already validated closing witnesses in its place;
  // the count below still refuses any item whose closing witness never arrived.
  let output = case acc.api, output {
    "codex-subscription", [] -> expected
    _, _ -> output
  }

  use <- bool.lazy_guard(output != expected, fn() {
    malformed(acc, "terminal_output_mismatch")
  })
  use <- bool.lazy_guard(list.length(output) != list.length(ordered), fn() {
    malformed(acc, "terminal_items_unclosed")
  })
  use <- bool.lazy_guard(
    !list.all(
      list.index_map(ordered, fn(item, index) { item.index == index }),
      fn(value) { value },
    ),
    fn() { malformed(acc, "terminal_items_noncontiguous") },
  )

  // Verify completion status and confirm no incomplete items remain.
  use status <- or_malformed(
    wire.string_field(response, "status"),
    acc,
    "terminal_status",
  )
  use <- bool.lazy_guard(
    status == "completed"
      && list.any(output, fn(item) {
      wire.string_field(item, "status") == Ok("incomplete")
    }),
    fn() { malformed(acc, "terminal_incomplete_item") },
  )
  let has_calls =
    list.any(ordered, fn(item) {
      case item.kind {
        Function(..) -> True
        _ -> False
      }
    })
  let refusal =
    list.any(ordered, fn(item) {
      list.any(item.parts, fn(part) { part.kind == Refusal })
    })

  // Determine stop reason from terminal event and status.
  let stop = case event, status {
    "response.completed", "completed" ->
      Ok(#(
        case has_calls {
          True -> message.ToolUse
          False -> message.Stop
        },
        "completed",
        None,
      ))
    "response.cancelled", "cancelled" ->
      Ok(#(message.Aborted, "cancelled", None))
    "response.incomplete", "incomplete" -> incomplete(response)
    _, _ -> Error("invalid_status")
  }

  // Check for error status or refusal to settle terminal event.
  case stop {
    Error("invalid_status") -> malformed(acc, "terminal_status_mismatch")
    Error(_reason) ->
      fail(
        acc,
        stream.UnmappedStopReason("Responses incomplete reason is unsupported"),
      )
    Ok(#(stop, raw, error)) -> {
      // Override stop reason to Errored if refusal was recorded.
      let #(stop, raw, error) = case refusal {
        True -> #(
          message.Errored,
          "refusal",
          Some("Responses provider refused the request"),
        )
        False -> #(stop, raw, error)
      }

      settle(acc, identity, output, response, stop, raw, error)
    }
  }
}

// Only the two known incomplete reasons carry defined partial-result semantics.
// Unknown provider labels are not copied into errors or interpreted as success.
/// Maps incomplete details reason string to stop reason and error text.
fn incomplete(
  response: JsonValue,
) -> Result(#(message.StopReason, String, Option(String)), String) {
  let reason =
    response
    |> wire.field("incomplete_details")
    |> result.try(wire.string_field(_, "reason"))
    |> result.unwrap("")

  // Map incomplete reason code to stop reason.
  case reason {
    "max_output_tokens" -> Ok(#(message.Length, reason, None))
    "content_filter" ->
      Ok(#(message.Errored, reason, Some("Responses provider content filter")))
    _ -> Error(reason)
  }
}

// Accounting uses the shared clamped vocabulary and overflow rule. Content is
// then ordered by the delta indices already exposed to callers, while replay
// retains the provider order through compact, independently validated metadata.
/// Finalizes stream settlement creating settled message and terminal event.
fn settle(
  acc: Accumulator,
  identity: #(String, String),
  output: List(JsonValue),
  _response: JsonValue,
  stop: message.StopReason,
  raw: String,
  error: Option(String),
) -> #(Accumulator, List(StreamEvent)) {
  let usage = acc.usage
  let prompt = usage.input + usage.cache_read + usage.cache_write

  // Check whether prompt tokens exceeded context window limit.
  let #(stop, error) = case
    prompt > acc.resolved.context_window && usage.output <= 64
  {
    True -> #(
      message.Errored,
      Some(retry.overflow_message(prompt, acc.resolved.context_window)),
    )
    False -> #(stop, error)
  }

  let ordered = list.sort(acc.items, fn(a, b) { int.compare(a.index, b.index) })
  let order = list.flat_map(ordered, block_order)
  let content =
    list.zip(order, items.blocks(output))
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.1 })
  let diagnostics =
    json.Object([
      #(
        items.namespace,
        json.Object([
          #("output", json.Array(list.map(output, items.template))),
          #("block_order", json.Array(list.map(order, json.Int))),
        ]),
      ),
    ])

  // A reasoning item requires its original ID. Refuse a witness which cannot
  // fit the bounded metadata rather than settle history that cannot replay.
  use <- bool.lazy_guard(
    bit_array.byte_size(bit_array.from_string(json.to_string(diagnostics)))
      > 65_536,
    fn() { malformed(acc, "replay_metadata_bytes") },
  )
  let assistant =
    message.AssistantMessage(
      content:,
      api: acc.api,
      provider: acc.resolved.provider,
      model: acc.resolved.model_id,
      response_model: Some(identity.1),
      response_id: Some(identity.0),
      diagnostics: Some(diagnostics),
      usage:,
      stop_reason: stop,
      deferred: None,
      error_message: error,
      raw_stop_reason: Some(raw),
      end_turn: Some(stop == message.Stop),
      timestamp: acc.now,
    )
  use settled <- or_malformed(stream.settle(assistant), acc, "settled_message")
  #(Accumulator(..acc, life: Terminal), [
    stream.Settled(settled, accounting.from_usage(usage)),
  ])
}

// Wire output order and delta arrival order can differ under interleaving.
// This permutation keeps durable block indices equal to the emitted indices,
// while the compact replay template restores the provider's own item order.
/// Returns the emitted block indices for a completed item.
fn block_order(item: Item) -> List(Int) {
  let parts = list.sort(item.parts, fn(a, b) { int.compare(a.index, b.index) })

  // Map item parts to their allocated stream block indices.
  case item.kind {
    Function(block:, ..) -> [block]
    Message -> list.map(parts, fn(part) { part.block })
    Thought ->
      case parts, item.empty_block {
        [], Some(block) -> [block]
        _, _ ->
          list.append(
            list.filter(parts, fn(part) { part.kind == Summary }),
            list.filter(parts, fn(part) { part.kind == Reasoning }),
          )
          |> list.map(fn(part) { part.block })
      }
  }
}

// The credential channel determines billing identity, independently of model
// names or configured rate cards. Subscription tokens do not measure credits.
fn billing(api: String) -> usage_evidence.Billing {
  case api == subscription_api_name {
    True -> usage_evidence.ChatGptPlan
    False -> usage_evidence.Api
  }
}

// A terminal replaces the previous snapshot. Missing final usage retains any
// measured prefix as partial; absence never establishes a remote zero cost.
/// Validates and records usage metadata in accumulator.
fn record_usage(
  acc: Accumulator,
  response: JsonValue,
  coverage: usage_evidence.Coverage,
) -> Result(Accumulator, Nil) {
  // Extract and record usage metadata if present in response.
  case wire.field(response, "usage") {
    Error(Nil) -> Ok(acc)
    Ok(value) -> {
      use Nil <- result.try(validate_usage(value))
      let required = [
        "input_tokens",
        "output_tokens",
        "input_tokens_details.cached_tokens",
      ]
      let witness = usage_witness.observe(acc.witness, value, required)
      let evidence =
        response_usage_evidence(witness, value, coverage, billing(acc.api))
      Ok(Accumulator(..acc, witness:, usage: usage(value, evidence, acc.usage)))
    }
  }
}

// Final output must be present in the terminal itself; an initial zero output
// cannot establish that the provider did no work after its created event.
/// Builds evidence record for response usage metadata based on coverage.
fn response_usage_evidence(
  witness: usage_witness.Witness,
  value: JsonValue,
  coverage: usage_evidence.Coverage,
  source: usage_evidence.Billing,
) -> usage_evidence.Evidence {
  case coverage, wire.int_field(value, "output_tokens") {
    usage_evidence.Complete, Ok(_) ->
      usage_witness.finished(
        witness,
        ["input_tokens", "output_tokens", "input_tokens_details.cached_tokens"],
        source,
      )
    usage_evidence.Complete, Error(Nil) | usage_evidence.Partial, _ ->
      usage_witness.snapshot(witness, source)
  }
}

// Present malformed counts cannot masquerade as omitted counts. Compatible
// endpoints may omit fields; integer bounds retain the shared clamping policy.
/// Validates usage metadata structure and numeric field types.
fn validate_usage(value: JsonValue) -> Result(Nil, Nil) {
  // Ensure usage value is a JSON object.
  use fields <- result.try(case value {
    json.Object(fields:) -> Ok(fields)
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> Error(Nil)
  })

  use Nil <- result.try(
    validate_counts(fields, ["input_tokens", "output_tokens", "total_tokens"]),
  )
  use Nil <- result.try(
    validate_details(fields, "input_tokens_details", [
      "cached_tokens",
      "cache_write_tokens",
    ]),
  )
  validate_details(fields, "output_tokens_details", ["reasoning_tokens"])
}

/// Validates nested details object contains valid counts.
fn validate_details(
  fields: List(#(String, JsonValue)),
  name: String,
  counts: List(String),
) -> Result(Nil, Nil) {
  case list.key_find(fields, name) {
    Error(Nil) | Ok(json.Null) -> Ok(Nil)
    Ok(json.Object(fields:)) -> validate_counts(fields, counts)
    Ok(json.Bool(_))
    | Ok(json.Int(_))
    | Ok(json.Float(_))
    | Ok(json.String(_))
    | Ok(json.Array(_)) -> Error(Nil)
  }
}

/// Validates that specified count keys have integer or null values.
fn validate_counts(
  fields: List(#(String, JsonValue)),
  names: List(String),
) -> Result(Nil, Nil) {
  use _ <- result.map(
    list.try_map(names, fn(name) {
      case list.key_find(fields, name) {
        Error(Nil) | Ok(json.Null) | Ok(json.Int(_)) -> Ok(Nil)
        Ok(json.Bool(_))
        | Ok(json.Float(_))
        | Ok(json.String(_))
        | Ok(json.Array(_))
        | Ok(json.Object(_)) -> Error(Nil)
      }
    }),
  )
  Nil
}

// Reported input includes cache reads and writes. Clamp before subtracting so
// the split conserves the whole prompt even when a proxy reports impossible counts.
/// Computes canonical usage token counters from wire usage object.
fn usage(
  value: JsonValue,
  evidence: usage_evidence.Evidence,
  previous: message.Usage,
) -> message.Usage {
  let prompt =
    wire.count_field_or(
      value,
      "input_tokens",
      previous.input + previous.cache_read + previous.cache_write,
    )
  let output = wire.count_field_or(value, "output_tokens", previous.output)
  let input_details =
    result.unwrap(wire.field(value, "input_tokens_details"), json.Null)
  let output_details =
    result.unwrap(wire.field(value, "output_tokens_details"), json.Null)
  let cache_read =
    int.min(
      prompt,
      wire.count_field_or(input_details, "cached_tokens", previous.cache_read),
    )
  let cache_write =
    int.min(
      prompt - cache_read,
      wire.count_field_or(
        input_details,
        "cache_write_tokens",
        previous.cache_write,
      ),
    )
  message.Usage(
    evidence:,
    input: prompt - cache_read - cache_write,
    output:,
    cache_read:,
    cache_write:,
    cache_write_1h: None,
    reasoning: option.or(
      wire.optional_count_field(output_details, "reasoning_tokens"),
      previous.reasoning,
    ),
    total_tokens: wire.count_field_or(value, "total_tokens", prompt + output),
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}
