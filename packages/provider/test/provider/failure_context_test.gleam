//// Failure facts survive wrapping without acquiring authority over drain proof.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/internal/diagnostic
import provider/retry
import provider/stream

fn observation(source, cause) {
  stream.FailureObservation(
    source,
    cause,
    Some(2),
    Some(1000),
    Some(100),
    Some("local-request"),
  )
}

pub fn wrapped_errors_preserve_retry_and_cancellation_classification_test() {
  let errors = [
    stream.ProviderCancelled,
    stream.CancellationUnconfirmed,
    stream.DrainProofLost,
    stream.HttpError(429, "rate_limit_error", "wait", Some(5000)),
    stream.HttpError(400, "invalid_request", "invalid", None),
    stream.TransportFailed("closed"),
  ]
  list.each(errors, fn(error) {
    let wrapped =
      stream.with_context(
        error,
        observation(stream.AttemptSource, stream.RequestDeadline),
      )
      |> stream.with_context(observation(
        stream.RuntimeSource,
        stream.CancellationRequested,
      ))
    assert retry.classify(wrapped) == retry.classify(error)
    assert stream.underlying_error(wrapped) == error
  })
}

pub fn context_normalizes_by_source_and_preserves_outer_initiator_test() {
  let wrapped =
    stream.ProviderCancelled
    |> stream.with_context(observation(
      stream.AttemptSource,
      stream.CancellationRequested,
    ))
    |> stream.with_context(observation(
      stream.GatewaySource,
      stream.CancellationRequested,
    ))
    |> stream.with_context(observation(
      stream.RelaySource,
      stream.CancellationRequested,
    ))
    |> stream.with_context(observation(
      stream.RuntimeSource,
      stream.RequestDeadline,
    ))
    |> stream.with_context(observation(
      stream.RuntimeSource,
      stream.TerminalResponse,
    ))
  assert list.length(stream.failure_context(wrapped)) == 4
  assert string.contains(
    stream.describe_error(wrapped),
    "runtime: request deadline",
  )
  assert !string.contains(stream.describe_error(wrapped), "explicit stop")
  let nested =
    stream.WithContext(
      wrapped,
      stream.FailureContext([
        observation(stream.GatewaySource, stream.CancellationRequested),
      ]),
    )
  let normalized =
    stream.with_context(
      nested,
      observation(stream.RuntimeSource, stream.RequestDeadline),
    )
  let assert stream.WithContext(inner, _) = normalized
    as "one normalized envelope remains"
  assert inner == stream.ProviderCancelled
  assert retry.classify(normalized) == retry.Terminal
}

pub fn contextual_diagnostics_are_bounded_and_scrubbed_before_publication_test() {
  let secret = "request-secret"
  let context =
    stream.FailureObservation(
      ..observation(stream.AttemptSource, stream.TerminalResponse),
      request_id: Some(secret),
    )
  let scrubbed =
    stream.with_context(
      stream.HttpError(429, secret, "reflected " <> secret, Some(1200)),
      context,
    )
    |> diagnostic.scrub_error(secret)
  let encoded =
    json.to_string(json.Object(stream.context_diagnostics(scrubbed)))
  assert !string.contains(encoded, secret)
  assert string.contains(encoded, "[REDACTED]")
  assert !string.contains(stream.describe_error(scrubbed), secret)
  assert retry.classify(scrubbed) == retry.Retryable(Some(1200))
  let oversized =
    stream.with_context(
      stream.ProviderCancelled,
      stream.FailureObservation(
        ..context,
        request_id: Some(string.repeat("x", 10_000)),
      ),
    )
  let assert [bounded] = stream.failure_context(oversized)
    as "only one local source was added"
  assert bounded.request_id == None
}
