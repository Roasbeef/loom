//// Provider retry hints survive the runtime's durable settlement bridge.

import core/codec
import core/json
import core/message
import gleam/option.{None, Some}
import gleam/string
import provider/stream
import runtime/effects
import support/harness

pub fn retry_hint_survives_settlement_without_provider_text_test() {
  let error =
    stream.HttpError(
      status: 429,
      api_error_type: "rate_limit_error",
      message: "arbitrary provider response",
      retry_after_ms: Some(1000),
    )
  let assert message.AssistantMessage(diagnostics:, raw_stop_reason:, ..) =
    effects.settle_failure(error, harness.configuration(), 50)
    as "Failures settle as assistant responses."
  assert raw_stop_reason == Some("retryable")
  assert diagnostics == Some(json.Object([#("retry_after_ms", json.Int(1000))]))

  // Cancellation remains terminal and cannot acquire a retry hint.
  let assert message.AssistantMessage(diagnostics:, raw_stop_reason:, ..) =
    effects.settle_failure(
      stream.CancellationUnconfirmed,
      harness.configuration(),
      50,
    )
    as "Unconfirmed cancellation settles terminally."
  assert raw_stop_reason == Some("terminal")
  assert diagnostics == None
}

pub fn contextual_failure_and_retry_hint_survive_durable_message_codec_test() {
  let observation =
    stream.FailureObservation(
      stream.RuntimeSource,
      stream.RequestDeadline,
      Some(3),
      Some(1000),
      Some(2000),
      Some("local-operation/request"),
    )
  let failure =
    stream.HttpError(429, "rate_limit_error", "provider text", Some(5000))
    |> stream.with_context(observation)
  let settled = effects.settle_failure(failure, harness.configuration(), 50)
  assert codec.decode_message(codec.encode_message(settled)) == Ok(settled)
  let assert message.AssistantMessage(
    diagnostics: Some(diagnostics),
    error_message: Some(description),
    ..,
  ) = settled
    as "the failed assistant record persists both machine and human diagnostics"
  let encoded = json.to_string(diagnostics)
  assert string.contains(encoded, "provider_failure")
  assert string.contains(encoded, "retry_after_ms")
  assert string.contains(encoded, "local-operation/request")
  assert !string.contains(encoded, "provider text")
  assert string.contains(description, "runtime: request deadline")
}
