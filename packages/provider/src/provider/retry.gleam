//// Retry policy normalization and canonical overflow detection.
////
//// Pure classification the gateway's fallback walk and the machine's
//// retry loop both consume: which `ProviderError`s are worth retrying
//// (with what backoff hint), and which error messages indicate a context
//// overflow. Overflow matters here because the machine's classification
//// order (spec §1.3) checks overflow *before* retryable error — an
//// oversized request must compact, not retry unchanged — so the overflow
//// patterns and the retry classifier live together.

import gleam/int
import gleam/option.{type Option, None}
import gleam/string
import provider/internal/error_code
import provider/stream.{
  type ProviderError, CancellationUnconfirmed, DrainProofLost, HttpError,
  MalformedStream, NoIdentity, NoSecret, ProviderCancelled, StreamDisconnected,
  StreamError, TransportFailed, UnknownProvider, UnmappedStopReason,
}

/// Whether an error is worth retrying.
///
/// Constructor invariants: `Retryable.backoff_hint_ms` is the provider's
/// requested wait (from `retry-after`) when one was given; callers
/// combine it with their own backoff policy, taking the maximum.
pub type RetryClass {
  /// Retry may succeed: transient load, rate limit, or transport fault.
  Retryable(backoff_hint_ms: Option(Int))

  /// Retry is limited to this many total generation attempts.
  RetryableWithin(backoff_hint_ms: Option(Int), max_attempts: Int)

  /// Retrying the identical request cannot help.
  Terminal
}

/// A bounded exponential backoff policy, mirroring the machine's
/// `retry_wait` configuration shape.
///
/// Constructor invariants: `max_retries` is the number of retry attempts
/// after the initial call (0 = never retry); `base_delay_ms` is positive
/// and doubles per attempt.
pub type RetryPolicy {
  RetryPolicy(max_retries: Int, base_delay_ms: Int)
}

/// Classifies a provider error as retryable or terminal.
///
/// Recognized permanent request, access, quota, policy and context codes
/// take precedence over transient statuses and message heuristics. Other
/// HTTP 408/429/5xx, named transient errors, transport failures and disconnects
/// use the configured retry policy. Unknown Responses stream failures use
/// three total generation attempts through `RetryableWithin`.
///
/// An ordinary HTTP 429 bypasses the overflow text heuristic: throttling
/// prose can mention a token limit without describing an oversized request.
/// Other statuses check overflow before retry. Streamed throttling prose is
/// retryable only after excluding recognized permanent codes, so appended
/// diagnostics cannot turn a denial into a retry. HTTP and streamed errors
/// retain their structured retry advice; callers take the larger of the
/// provider delay and their local backoff. Malformed streams remain terminal
/// except for the explicitly recoverable missing-part closure variant.
///
/// ## Examples
///
/// ```gleam
/// assert retry.classify(stream.TransportFailed("closed"))
///   == retry.Retryable(backoff_hint_ms: option.None)
/// ```
///
/// ```gleam
/// assert retry.classify(stream.UnmappedStopReason("novel")) == retry.Terminal
/// ```
///
pub fn classify(error: ProviderError) -> RetryClass {
  // Categorize error by variant and status code to determine retryability.
  case error {
    stream.WithContext(inner, _) -> classify(inner)
    ProviderCancelled -> Terminal
    CancellationUnconfirmed -> Terminal
    DrainProofLost -> Terminal
    TransportFailed(reason: _) -> Retryable(backoff_hint_ms: None)
    StreamDisconnected(context: _) -> Retryable(backoff_hint_ms: None)
    HttpError(status: 429, api_error_type:, message: _, retry_after_ms:) ->
      case error_code.is_permanent(api_error_type) {
        True -> Terminal
        False -> Retryable(backoff_hint_ms: retry_after_ms)
      }
    HttpError(status:, api_error_type:, message:, retry_after_ms:) -> {
      let transient_status =
        status == 408
        || status >= 500
        || is_transient_error_type(api_error_type)

      // Check whether error is an overflow or permanent failure before retrying.
      case
        error_code.is_permanent(api_error_type)
        || is_overflow_message(message)
        || !transient_status
      {
        True -> Terminal
        False -> Retryable(backoff_hint_ms: retry_after_ms)
      }
    }
    StreamError(api_error_type: "responses_error", message:, retry_after_ms:) ->
      case is_overflow_message(message) {
        True -> Terminal
        False ->
          RetryableWithin(backoff_hint_ms: retry_after_ms, max_attempts: 3)
      }
    StreamError(api_error_type:, message:, retry_after_ms:) ->
      case
        !error_code.is_permanent(api_error_type)
        && {
          is_throttle_message(message)
          || is_throttle_message(api_error_type)
          || {
            !is_overflow_message(message)
            && is_transient_error_type(api_error_type)
          }
        }
      {
        True -> Retryable(backoff_hint_ms: retry_after_ms)
        False -> Terminal
      }
    stream.RecoverableStreamCorruption(_) ->
      RetryableWithin(backoff_hint_ms: None, max_attempts: 3)
    MalformedStream(report: _) -> Terminal
    UnmappedStopReason(raw: _) -> Terminal
    NoIdentity(role: _) -> Terminal
    UnknownProvider(provider: _) -> Terminal
    NoSecret(provider: _, secret_name: _) -> Terminal
  }
}

// The vocabulary a throttled response uses when the status code is not
// available to say so. It shares the first three substrings with the
// `excluded` set in `is_overflow_message`, which is what keeps a
// throttling message out of the compaction path, and adds the error
// code form a proxy puts in an error object rather than in prose. The
// bare digits "429" are deliberately not matched: under an unbounded
// retry budget a false positive retries forever, and a request id or a
// byte count can contain those digits.
/// Detects rate limit and throttling phrases in error messages.
fn is_throttle_message(message: String) -> Bool {
  let lowered = string.lowercase(message)
  string.contains(lowered, "rate limit")
  || string.contains(lowered, "rate_limit")
  || string.contains(lowered, "too many requests")
  || string.contains(lowered, "throttling")
}

/// Checks whether an API error code signifies a transient provider failure.
fn is_transient_error_type(error_type: String) -> Bool {
  case error_type {
    "overloaded_error" | "rate_limit_error" | "api_error" | "timeout_error" ->
      True
    "server_error" | "internal_server_error" -> True
    _ -> False
  }
}

/// The delay before retry attempt `attempt` (1-indexed), in milliseconds:
/// `base_delay_ms * 2^(attempt - 1)`, or the provider's backoff hint when
/// it asks for longer. Returns `Error(Nil)` once the policy's attempts
/// are exhausted.
///
/// ## Examples
///
/// ```gleam
/// let policy = retry.RetryPolicy(max_retries: 3, base_delay_ms: 1000)
/// assert retry.backoff_ms(policy, attempt: 2, hint: option.None) == Ok(2000)
/// ```
///
/// ```gleam
/// let policy = retry.RetryPolicy(max_retries: 3, base_delay_ms: 1000)
/// assert retry.backoff_ms(policy, attempt: 4, hint: option.None)
///   == Error(Nil)
/// ```
///
pub fn backoff_ms(
  policy: RetryPolicy,
  attempt attempt: Int,
  hint hint: Option(Int),
) -> Result(Int, Nil) {
  // Verify attempt is within policy retry limit before computing backoff delay.
  case attempt >= 1 && attempt <= policy.max_retries {
    False -> Error(Nil)
    True -> {
      let exponential = policy.base_delay_ms * exponent_of_two(attempt - 1)
      Ok(int.max(exponential, option.unwrap(hint, 0)))
    }
  }
}

fn exponent_of_two(power: Int) -> Int {
  case power <= 0 {
    True -> 1
    False -> 2 * exponent_of_two(power - 1)
  }
}

/// Whether an error message indicates a context-window overflow. This is
/// the harness's canonical overflow message matcher (spec §1.3's
/// "message-pattern" classification source): a substring vocabulary
/// distilled from real provider wire messages. Deliberately a heuristic —
/// providers phrase context-limit failures as free text — and the
/// adapter-computed usage check is preferred wherever usage is available.
///
/// Matched (with the provider that phrases it that way):
/// "prompt is too long" (Anthropic), "request_too_large" (Anthropic HTTP
/// 413), "exceeds the context window" (OpenAI), "maximum context length"
/// (OpenAI-compatible proxies, OpenRouter, Mistral), "context_length_
/// exceeded" (generic error codes), "context window exceeds limit"
/// (MiniMax), "reduce the length of the messages" (Groq), "input is too
/// long for requested model" (Bedrock), "too many tokens" and "token
/// limit exceeded" (generic fallbacks). Messages that also look like
/// throttling ("rate limit", "too many requests", "throttling") are
/// excluded, since e.g. Bedrock throttling mentions tokens.
///
/// ## Examples
///
/// ```gleam
/// assert retry.is_overflow_message(
///   "prompt is too long: 213462 tokens > 200000 maximum",
/// )
/// ```
///
/// ```gleam
/// assert !retry.is_overflow_message(
///   "ThrottlingException: Too many tokens, please wait",
/// )
/// ```
///
pub fn is_overflow_message(message: String) -> Bool {
  let lowered = string.lowercase(message)
  let excluded =
    string.contains(lowered, "rate limit")
    || string.contains(lowered, "too many requests")
    || string.contains(lowered, "throttling")
  let matched =
    string.contains(lowered, "prompt is too long")
    || string.contains(lowered, "request_too_large")
    || string.contains(lowered, "exceeds the context window")
    || string.contains(lowered, "maximum context length")
    || string.contains(lowered, "context_length_exceeded")
    || string.contains(lowered, "context length exceeded")
    || string.contains(lowered, "context window exceeds limit")
    || string.contains(lowered, "reduce the length of the messages")
    || string.contains(lowered, "input is too long for requested model")
    || string.contains(lowered, "too many tokens")
    || string.contains(lowered, "token limit exceeded")
  matched && !excluded
}

/// Builds the canonical overflow message adapters settle with when they
/// compute overflow from usage (spec §1.5): phrased to match
/// `is_overflow_message`, carrying the observed input and the window.
///
/// ## Examples
///
/// ```gleam
/// assert retry.is_overflow_message(retry.overflow_message(
///   input_tokens: 250_000,
///   context_window: 200_000,
/// ))
/// ```
///
pub fn overflow_message(
  input_tokens input_tokens: Int,
  context_window context_window: Int,
) -> String {
  "prompt is too long: "
  <> int.to_string(input_tokens)
  <> " tokens > "
  <> int.to_string(context_window)
  <> " maximum"
}
