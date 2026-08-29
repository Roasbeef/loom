import core/corruption
import gleam/option.{None, Some}
import provider/retry
import provider/stream

// --- classification table -------------------------------------------------

pub fn transport_failures_are_retryable_test() {
  assert retry.classify(stream.TransportFailed(reason: "connection refused"))
    == retry.Retryable(backoff_hint_ms: None)
  assert retry.classify(stream.StreamDisconnected(context: "mid-stream"))
    == retry.Retryable(backoff_hint_ms: None)
}

pub fn cancellation_is_terminal_test() {
  assert retry.classify(stream.ProviderCancelled) == retry.Terminal
}

pub fn rate_limit_carries_backoff_hint_test() {
  let error =
    stream.HttpError(
      status: 429,
      api_error_type: "rate_limit_error",
      message: "Rate limited",
      retry_after_ms: Some(7000),
    )
  assert retry.classify(error) == retry.Retryable(backoff_hint_ms: Some(7000))
}

pub fn overloaded_and_server_errors_are_retryable_test() {
  let overloaded =
    stream.HttpError(
      status: 529,
      api_error_type: "overloaded_error",
      message: "Overloaded",
      retry_after_ms: None,
    )
  assert retry.classify(overloaded) == retry.Retryable(backoff_hint_ms: None)
  let five_hundred =
    stream.HttpError(
      status: 500,
      api_error_type: "api_error",
      message: "Internal server error",
      retry_after_ms: None,
    )
  assert retry.classify(five_hundred) == retry.Retryable(backoff_hint_ms: None)
  assert retry.classify(stream.StreamError(
      api_error_type: "overloaded_error",
      message: "Overloaded",
    ))
    == retry.Retryable(backoff_hint_ms: None)
}

pub fn client_errors_are_terminal_test() {
  let invalid =
    stream.HttpError(
      status: 400,
      api_error_type: "invalid_request_error",
      message: "messages: at least one message is required",
      retry_after_ms: None,
    )
  assert retry.classify(invalid) == retry.Terminal
  let unauthorized =
    stream.HttpError(
      status: 401,
      api_error_type: "authentication_error",
      message: "invalid x-api-key",
      retry_after_ms: None,
    )
  assert retry.classify(unauthorized) == retry.Terminal
}

pub fn overflow_dressed_as_413_is_terminal_test() {
  // The machine's classification order compacts overflow instead of
  // retrying; the classifier must not race it.
  let overflow =
    stream.HttpError(
      status: 413,
      api_error_type: "request_too_large",
      message: "prompt is too long: 250000 tokens > 200000 maximum",
      retry_after_ms: None,
    )
  assert retry.classify(overflow) == retry.Terminal
}

pub fn configuration_errors_are_terminal_test() {
  assert retry.classify(stream.UnmappedStopReason(raw: "novel"))
    == retry.Terminal
  assert retry.classify(stream.NoIdentity(role: "main")) == retry.Terminal
  assert retry.classify(stream.UnknownProvider(provider: "ghost"))
    == retry.Terminal
  assert retry.classify(stream.NoSecret(
      provider: "anthropic",
      secret_name: "ANTHROPIC_API_KEY",
    ))
    == retry.Terminal
  assert retry.classify(
      stream.MalformedStream(report: corruption.report(
        at: "test",
        on: "x",
        expected: "json",
        context: "junk",
      )),
    )
    == retry.Terminal
}

// --- backoff --------------------------------------------------------------

pub fn backoff_doubles_per_attempt_test() {
  let policy = retry.RetryPolicy(max_retries: 3, base_delay_ms: 1000)
  assert retry.backoff_ms(policy, attempt: 1, hint: None) == Ok(1000)
  assert retry.backoff_ms(policy, attempt: 2, hint: None) == Ok(2000)
  assert retry.backoff_ms(policy, attempt: 3, hint: None) == Ok(4000)
  assert retry.backoff_ms(policy, attempt: 4, hint: None) == Error(Nil)
}

pub fn backoff_honors_longer_provider_hint_test() {
  let policy = retry.RetryPolicy(max_retries: 3, base_delay_ms: 1000)
  assert retry.backoff_ms(policy, attempt: 1, hint: Some(9000)) == Ok(9000)
  assert retry.backoff_ms(policy, attempt: 3, hint: Some(100)) == Ok(4000)
}

// --- overflow message patterns ---------------------------------------------

pub fn overflow_patterns_match_real_provider_wording_test() {
  assert retry.is_overflow_message(
    "prompt is too long: 213462 tokens > 200000 maximum",
  )
  assert retry.is_overflow_message(
    "413 {\"error\":{\"type\":\"request_too_large\",\"message\":\"Request exceeds the maximum size\"}}",
  )
  assert retry.is_overflow_message(
    "Your input exceeds the context window of this model",
  )
  assert retry.is_overflow_message(
    "Requested token count exceeds the model's maximum context length of 131072 tokens",
  )
  assert retry.is_overflow_message(
    "Please reduce the length of the messages or completion",
  )
  assert retry.is_overflow_message(
    "invalid params, context window exceeds limit",
  )
  assert retry.is_overflow_message("error code context_length_exceeded")
}

pub fn overflow_patterns_exclude_throttling_test() {
  assert !retry.is_overflow_message(
    "ThrottlingException: Too many tokens, please wait before trying again.",
  )
  assert !retry.is_overflow_message("rate limit exceeded, too many tokens used")
  assert !retry.is_overflow_message("Overloaded")
}

pub fn canonical_message_round_trips_test() {
  assert retry.overflow_message(input_tokens: 250_000, context_window: 200_000)
    == "prompt is too long: 250000 tokens > 200000 maximum"
  assert retry.is_overflow_message(retry.overflow_message(
    input_tokens: 1,
    context_window: 2,
  ))
}
