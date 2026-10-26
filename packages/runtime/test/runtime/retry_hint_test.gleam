//// Provider retry hints survive the runtime's durable settlement bridge.

import core/accounting
import core/codec
import core/corruption
import core/json
import core/message
import core/usage_evidence
import gleam/bit_array
import gleam/list as gleam_list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/responses
import provider/internal/diagnostic
import provider/model
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
    effects.settle_failure(
      error,
      harness.configuration(),
      50,
      accounting.from_usage(accounting.unknown_usage(usage_evidence.Other)),
    )
    as "Failures settle as assistant responses."
  assert raw_stop_reason == Some("retryable")
  assert diagnostics == Some(json.Object([#("retry_after_ms", json.Int(1000))]))

  // Cancellation remains terminal and cannot acquire a retry hint.
  let assert message.AssistantMessage(diagnostics:, raw_stop_reason:, ..) =
    effects.settle_failure(
      stream.CancellationUnconfirmed,
      harness.configuration(),
      50,
      accounting.from_usage(accounting.unknown_usage(usage_evidence.Other)),
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
  let settled =
    effects.settle_failure(
      failure,
      harness.configuration(),
      50,
      accounting.from_usage(accounting.unknown_usage(usage_evidence.Other)),
    )
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

// Exercise the adapter, gateway scrubber, failure bridge and durable codec
// together. A synthetic error would miss a dropped or truncated witness.
pub fn responses_validation_reason_survives_durable_failure_test() {
  let target =
    model.ResolvedModel("fixture", "fixture", model.ThinkingOff, 200_000, 8192)
  let machine = responses.subscription_response_machine(target, now: 0)
  let state = machine.on_status(machine.init, 200, [])
  let body =
    "event: canary-provider-secret\ndata: {\"type\":\"canary-provider-secret\",\"sequence_number\":7,\"output_index\":2,\"item_id\":\"canary-provider-secret\",\"delta\":\"canary-provider-secret\"}\n\n"
  let #(_, events) = machine.on_chunk(state, bit_array.from_string(body))
  let assert [stream.Failed(error, report)] = events
    as "The subscription adapter rejects the unknown event exactly once."
  let failure =
    diagnostic.scrub_error(error, secret: "request-credential")
    |> stream.with_context(stream.FailureObservation(
      stream.RuntimeSource,
      stream.TerminalResponse,
      Some(1),
      Some(300_000),
      Some(2000),
      Some("local/request"),
    ))
  let settled =
    effects.settle_failure(failure, harness.configuration(), 50, report)
  let encoded = codec.encode_message(settled)
  assert codec.decode_message(encoded) == Ok(settled)
  let assert message.AssistantMessage(
    error_message: Some(description),
    raw_stop_reason: Some("terminal"),
    ..,
  ) = settled
    as "Validation failures remain terminal and preserve the diagnostic text."
  assert string.contains(description, "reason=event_unsupported;")
  assert string.contains(description, "event=unknown; seq=7")
  assert string.contains(description, "output=2;")
  assert string.contains(description, "last_seq=7;")
  assert string.contains(description, "bytes=")
  assert string.contains(json.to_string(encoded), "local/request")
  assert !string.contains(description, "canary-provider-secret")
  assert !string.contains(json.to_string(encoded), "canary-provider-secret")
}

pub fn bounded_corruption_preserves_context_usage_and_cap_test() {
  let usage = accounting.unknown_usage(usage_evidence.Other)
  let failure =
    stream.RecoverableStreamCorruption(corruption.report(
      "responses",
      "response",
      "closed item",
      "reason=terminal_output_item_incomplete",
    ))
    |> stream.with_context(stream.FailureObservation(
      stream.RuntimeSource,
      stream.TerminalResponse,
      Some(1),
      Some(1000),
      Some(20),
      Some("local/request"),
    ))
  let settled =
    effects.settle_failure(
      failure,
      harness.configuration(),
      50,
      accounting.from_usage(usage),
    )
  assert codec.decode_message(codec.encode_message(settled)) == Ok(settled)
  let assert message.AssistantMessage(
    diagnostics: Some(json.Object(fields)),
    raw_stop_reason:,
    usage: retained,
    error_message: Some(description),
    ..,
  ) = settled
    as "Bounded corruption settles durably."
  assert raw_stop_reason == Some("retryable")
  assert retained == usage
  assert gleam_list.key_find(fields, "retry_max_attempts") == Ok(json.Int(3))
  assert string.contains(json.to_string(json.Object(fields)), "local/request")
  assert string.contains(description, "terminal_output_item_incomplete")
}
