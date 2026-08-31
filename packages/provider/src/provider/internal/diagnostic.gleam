//// Bounds and redacts diagnostics derived from a provider response.
////
//// Provider adapters need enough error text to classify context overflow and
//// explain a failed request, but that text is controlled by the remote
//// endpoint. Two boundaries keep it safe. Adapters use `append_error_body` to
//// stop buffering a non-success response at a fixed byte budget. The gateway
//// then uses `scrub_error` with the request's API key before an error can drive
//// fallback or leave the provider package. Keeping the key at the gateway is
//// deliberate: response machines remain pure and never retain credentials.

import core/corruption
import gleam/bit_array
import gleam/string
import provider/stream.{
  type ProviderError, CancellationUnconfirmed, DrainProofLost, HttpError,
  MalformedStream, NoIdentity, NoSecret, ProviderCancelled, StreamDisconnected,
  StreamError, TransportFailed, UnknownProvider, UnmappedStopReason,
}

/// The largest non-success HTTP body retained by an adapter. A normal JSON API
/// error is measured in hundreds of bytes; 64 KiB leaves ample diagnostic room
/// while preventing a hostile endpoint from growing the harness heap until the
/// connection closes.
pub const max_error_body_bytes = 65_536

const max_message_length = 400

const max_label_length = 128

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

fn scrub_message(value: String, secret: String) -> String {
  scrub(value, secret) |> bound(max_message_length)
}

fn scrub_label(value: String, secret: String) -> String {
  scrub(value, secret) |> bound(max_label_length)
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
fn bound(value: String, length: Int) -> String {
  case string.drop_start(value, length) {
    "" -> value
    _ -> string.slice(value, at_index: 0, length:) <> "…"
  }
}
