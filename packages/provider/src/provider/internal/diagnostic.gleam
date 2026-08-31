//// Bounds and redacts diagnostics derived from a provider response.
////
//// Provider adapters need enough error text to classify context overflow and
//// explain a failed request, but that text is controlled by the remote
//// endpoint. Two boundaries keep it safe. Adapters use `append_error_body` to
//// stop buffering a non-success response at a fixed byte budget. The gateway
//// then uses `scrub_event` with the request's API key before a delta or
//// terminal can leave the provider package. Keeping the key at the gateway is
//// deliberate: response machines remain pure and never retain credentials,
//// while successful provider reflection is scrubbed just like an error.

import core/corruption
import core/json
import core/message
import gleam/bit_array
import gleam/list
import gleam/option
import gleam/string
import provider/stream.{
  type ProviderError, CancellationUnconfirmed, Delta, DrainProofLost, Failed,
  HttpError, MalformedStream, NoIdentity, NoSecret, ProviderCancelled, Settled,
  StreamDisconnected, StreamError, TextDelta, ThinkingDelta, ToolCallDelta,
  TransportFailed, UnknownProvider, UnmappedStopReason,
}

/// The largest non-success HTTP body retained by an adapter. A normal JSON API
/// error is measured in hundreds of bytes; 64 KiB leaves ample diagnostic room
/// while preventing a hostile endpoint from growing the harness heap until the
/// connection closes.
pub const max_error_body_bytes = 65_536

const max_message_bytes = 400

const max_label_bytes = 128

/// Appends one HTTP error-body chunk when the cumulative byte budget permits
/// it. `Error(Nil)` means the caller must settle the attempt immediately rather
/// than retain a truncated body and continue reading an unbounded response.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(body) =
///   diagnostic.append_error_body(<<>>, <<"unavailable":utf8>>)
/// assert body == <<"unavailable":utf8>>
/// ```
///
pub fn append_error_body(
  body: BitArray,
  chunk: BitArray,
) -> Result(BitArray, Nil) {
  let remaining = max_error_body_bytes - bit_array.byte_size(body)
  case bit_array.byte_size(chunk) > remaining {
    True -> Error(Nil)
    False -> Ok(bit_array.append(body, chunk))
  }
}

/// Removes the request credential and bounds every free-form string carried by
/// a provider error. The gateway calls this before retry classification, so a
/// reflected key cannot reach a fallback, a client event, a log, or a durable
/// assistant error. Empty secrets are ignored because replacing the empty
/// string would alter every diagnostic.
///
/// ## Examples
///
/// ```gleam
/// let error = diagnostic.scrub_error(
///   stream.TransportFailed("request used sk-secret"),
///   secret: "sk-secret",
/// )
/// assert stream.describe_error(error) == "transport failed: request used [REDACTED]"
/// ```
///
pub fn scrub_error(
  error: ProviderError,
  secret secret: String,
) -> ProviderError {
  case error {
    ProviderCancelled -> ProviderCancelled
    CancellationUnconfirmed -> CancellationUnconfirmed
    DrainProofLost -> DrainProofLost
    TransportFailed(reason:) ->
      TransportFailed(reason: scrub_message(reason, secret))
    HttpError(status:, api_error_type:, message:, retry_after_ms:) ->
      HttpError(
        status:,
        api_error_type: scrub_label(api_error_type, secret),
        message: scrub_message(message, secret),
        retry_after_ms:,
      )
    StreamError(api_error_type:, message:) ->
      StreamError(
        api_error_type: scrub_label(api_error_type, secret),
        message: scrub_message(message, secret),
      )
    StreamDisconnected(context:) ->
      StreamDisconnected(context: scrub_message(context, secret))
    MalformedStream(report:) ->
      MalformedStream(report: corruption.report(
        at: scrub_label(report.boundary, secret),
        on: scrub_label(report.subject, secret),
        expected: scrub_message(report.expected, secret),
        context: scrub_message(report.context, secret),
      ))
    UnmappedStopReason(raw:) ->
      UnmappedStopReason(raw: scrub_label(raw, secret))
    NoIdentity(role:) -> NoIdentity(role: scrub_label(role, secret))
    UnknownProvider(provider:) ->
      UnknownProvider(provider: scrub_label(provider, secret))
    NoSecret(provider:, secret_name:) ->
      NoSecret(
        provider: scrub_label(provider, secret),
        secret_name: scrub_label(secret_name, secret),
      )
  }
}

/// Removes the request credential from every provider-originated string in a
/// stream event. The gateway applies this to deltas before display and to a
/// settled assistant before it can enter durable history. A broken opaque
/// settlement proof fails closed as a constant malformed-stream error rather
/// than returning the unsanitized value.
///
/// ## Examples
///
/// ```gleam
/// let event = stream.Delta(stream.TextDelta(0, "echo sk-secret"))
/// assert diagnostic.scrub_event(event, "sk-secret")
///   == stream.Delta(stream.TextDelta(0, "echo [REDACTED]"))
/// ```
///
pub fn scrub_event(
  event: stream.StreamEvent,
  secret: String,
) -> stream.StreamEvent {
  case event {
    Delta(delta:) -> Delta(scrub_delta(delta, secret))
    Failed(error:) -> Failed(error: scrub_error(error, secret))
    Settled(message: settled, usage:) ->
      case scrub_settled(settled, secret) {
        Ok(settled) -> Settled(message: settled, usage:)
        Error(Nil) ->
          Failed(
            error: MalformedStream(corruption.report(
              at: "provider/internal/diagnostic.scrub_event",
              on: "settled provider response",
              expected: "a settled assistant message",
              context: "the settlement proof did not contain an assistant message",
            )),
          )
      }
  }
}

fn scrub_delta(delta: stream.Delta, secret: String) -> stream.Delta {
  case delta {
    TextDelta(index:, text:) -> TextDelta(index:, text: scrub(text, secret))
    ThinkingDelta(index:, thinking:) ->
      ThinkingDelta(index:, thinking: scrub(thinking, secret))
    ToolCallDelta(index:, call_id:, name:, arguments_json:) ->
      ToolCallDelta(
        index:,
        call_id: scrub(call_id, secret),
        name: scrub(name, secret),
        arguments_json: scrub(arguments_json, secret),
      )
  }
}

fn scrub_settled(
  settled: stream.SettledAssistantMessage,
  secret: String,
) -> Result(stream.SettledAssistantMessage, Nil) {
  case stream.message(settled) {
    message.AssistantMessage(
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
      stream.settle(message.AssistantMessage(
        content: list.map(content, fn(block) {
          scrub_assistant_block(block, secret)
        }),
        api: scrub(api, secret),
        provider: scrub(provider, secret),
        model: scrub(model, secret),
        response_model: option.map(response_model, fn(value) {
          scrub(value, secret)
        }),
        response_id: option.map(response_id, fn(value) { scrub(value, secret) }),
        diagnostics: option.map(diagnostics, fn(value) {
          scrub_json(value, secret)
        }),
        usage:,
        stop_reason:,
        deferred: option.map(deferred, fn(value) {
          scrub_deferred(value, secret)
        }),
        error_message: option.map(error_message, fn(value) {
          scrub(value, secret)
        }),
        raw_stop_reason: option.map(raw_stop_reason, fn(value) {
          scrub(value, secret)
        }),
        end_turn:,
        timestamp:,
      ))
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> Error(Nil)
  }
}

fn scrub_assistant_block(
  block: message.AssistantBlock,
  secret: String,
) -> message.AssistantBlock {
  case block {
    message.AssistantText(text:, text_signature:) ->
      message.AssistantText(
        text: scrub(text, secret),
        text_signature: option.map(text_signature, fn(value) {
          scrub(value, secret)
        }),
      )
    message.AssistantThinking(thinking:, thinking_signature:, redacted:) ->
      message.AssistantThinking(
        thinking: scrub(thinking, secret),
        thinking_signature: option.map(thinking_signature, fn(value) {
          scrub(value, secret)
        }),
        redacted:,
      )
    message.AssistantToolCall(call:) ->
      message.AssistantToolCall(call: scrub_tool_call(call, secret))
  }
}

fn scrub_tool_call(call: message.ToolCall, secret: String) -> message.ToolCall {
  let message.ToolCall(id:, name:, arguments:, thought_signature:, namespace:) =
    call
  message.ToolCall(
    id: scrub(id, secret),
    name: scrub(name, secret),
    arguments: scrub_json(arguments, secret),
    thought_signature: option.map(thought_signature, fn(value) {
      scrub(value, secret)
    }),
    namespace: option.map(namespace, fn(value) { scrub(value, secret) }),
  )
}

fn scrub_deferred(
  deferred: message.DeferredHandle,
  secret: String,
) -> message.DeferredHandle {
  let message.DeferredHandle(
    provider:,
    model_id:,
    api:,
    id:,
    expires_at:,
    poll_after_ms:,
    data:,
  ) = deferred
  message.DeferredHandle(
    provider: scrub(provider, secret),
    model_id: scrub(model_id, secret),
    api: scrub(api, secret),
    id: scrub(id, secret),
    expires_at:,
    poll_after_ms:,
    data: option.map(data, fn(value) { scrub_json(value, secret) }),
  )
}

fn scrub_json(value: json.JsonValue, secret: String) -> json.JsonValue {
  case value {
    json.Object(fields:) ->
      json.Object(
        list.map(fields, fn(field) {
          #(scrub(field.0, secret), scrub_json(field.1, secret))
        }),
      )
    json.Array(items:) ->
      json.Array(list.map(items, fn(item) { scrub_json(item, secret) }))
    json.String(value:) -> json.String(scrub(value, secret))
    json.Int(..) | json.Float(..) | json.Bool(..) | json.Null -> value
  }
}

fn scrub_message(value: String, secret: String) -> String {
  scrub(value, secret) |> bound(max_message_bytes)
}

fn scrub_label(value: String, secret: String) -> String {
  scrub(value, secret) |> bound(max_label_bytes)
}

fn scrub(value: String, secret: String) -> String {
  case secret {
    "" -> value
    _ -> string.replace(value, each: secret, with: "[REDACTED]")
  }
}

// Test only the prefix needed to answer the bound. Walking the entire remote
// string merely to learn that it is long would make diagnostics proportional
// to attacker-controlled input after the byte budget had already done its job.
fn bound(value: String, bytes: Int) -> String {
  let encoded = bit_array.from_string(value)
  case bit_array.byte_size(encoded) <= bytes {
    True -> value
    False -> utf8_prefix(encoded, bytes) <> "…"
  }
}

// A byte cut may split one UTF-8 codepoint. Backing up can inspect at most
// three additional prefixes, so a remote string cannot turn truncation itself
// into work proportional to the untrusted suffix.
fn utf8_prefix(value: BitArray, bytes: Int) -> String {
  case bit_array.slice(value, at: 0, take: bytes) {
    Error(Nil) -> ""
    Ok(prefix) ->
      case bit_array.to_string(prefix) {
        Ok(text) -> text
        Error(Nil) -> utf8_prefix(value, bytes - 1)
      }
  }
}
