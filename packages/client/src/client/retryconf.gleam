//// The operator's `[retry]` table: how a session's provider retry
//// ladder is configured from `loom.toml`.
////
//// The runtime already has a retry policy for every session, and until
//// this module existed it was the only one available: a host could set
//// `api.Options.retry_policy`, but nothing an operator could write
//// reached it. The default never gives up on a retryable failure, so
//// the table exists mainly for the operator who wants the opposite — a
//// bounded ladder that fails the run rather than long-polling a
//// provider that is refusing.
////
//// There is one source for the default values and it is
//// `runtime/api.default_retry_policy`. A key the document omits is
//// filled from there rather than from a number repeated here, so
//// changing the runtime's default changes what an unconfigured server
//// and a half-configured table both do.
////
//// Parsing is total and performs no I/O: the text comes in, a policy or
//// a sentence an operator can act on comes out. Every refusal names the
//// key it is about, because the operator is looking at a file.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import machine/operation.{
  type NormalizedRetryPolicy, type RetryBudget, Bounded, NormalizedRetryPolicy,
  Unbounded,
}
import runtime/api
import tom

/// The policy a document with no `[retry]` table gets, which is the
/// runtime's own default.
///
/// ## Examples
///
/// ```gleam
/// assert retryconf.default_policy == api.default_retry_policy
/// ```
///
pub const default_policy = api.default_retry_policy

/// The spelling of `attempts` that asks for a ladder which never gives
/// up. It is a word rather than a sentinel number because there is no
/// integer that means "forever" and an operator should not have to pick
/// one.
pub const unbounded_attempts = "unbounded"

/// Reads the `[retry]` table out of a configuration document, or returns
/// the runtime default when the document has none.
///
/// Each key stands on its own: a table that sets only `max_delay_ms`
/// keeps the default attempts and base delay. That is what makes the
/// common edit — capping the wait, or bounding the attempts — a one-line
/// table rather than a transcription of all three numbers.
///
/// ## Examples
///
/// ```gleam
/// assert retryconf.parse_policy("") == Ok(retryconf.default_policy)
/// ```
///
/// ```gleam
/// assert retryconf.parse_policy("[retry]\nattempts = 5\n")
///   == Ok(operation.NormalizedRetryPolicy(
///     attempts: operation.Bounded(max_attempts: 5),
///     base_delay_ms: 1000,
///     max_delay_ms: 60_000,
///   ))
/// ```
///
pub fn parse_policy(text: String) -> Result(NormalizedRetryPolicy, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "the configuration is not valid TOML: " <> string.inspect(error)
    }),
  )
  case dict.get(document, "retry") {
    Error(Nil) -> Ok(default_policy)
    Ok(tom.Table(fields)) -> policy_table(fields)
    Ok(_other) -> Error("[retry] must be a table")
  }
}

fn policy_table(
  fields: Dict(String, tom.Toml),
) -> Result(NormalizedRetryPolicy, String) {
  use Nil <- result.try(
    known_keys(dict.keys(fields), ["attempts", "base_delay_ms", "max_delay_ms"]),
  )
  use attempts <- result.try(attempts_key(fields))
  use base_delay_ms <- result.try(delay_key(
    fields,
    "base_delay_ms",
    default_policy.base_delay_ms,
  ))
  use max_delay_ms <- result.try(delay_key(
    fields,
    "max_delay_ms",
    default_policy.max_delay_ms,
  ))
  Ok(NormalizedRetryPolicy(attempts:, base_delay_ms:, max_delay_ms:))
}

// A budget is either a count or the word, and the two spellings are
// deliberate rather than one number with a magic value: `attempts = 0`
// reads like "do not retry" to a writer and like "do not try" to the
// ladder, so it is refused instead of guessed at.
fn attempts_key(fields: Dict(String, tom.Toml)) -> Result(RetryBudget, String) {
  case dict.get(fields, "attempts") {
    Error(Nil) -> Ok(default_policy.attempts)
    Ok(tom.String(word)) if word == unbounded_attempts -> Ok(Unbounded)
    Ok(tom.Int(count)) if count > 0 -> Ok(Bounded(max_attempts: count))
    Ok(_other) ->
      Error(
        "retry.attempts must be a whole number of at least 1, or the "
        <> "string \""
        <> unbounded_attempts
        <> "\": a bounded ladder fails the run once it is spent, and "
        <> "\""
        <> unbounded_attempts
        <> "\" keeps asking until the provider answers or the run is "
        <> "cancelled",
      )
  }
}

// Both delays share this because they differ only in name and default:
// the base is the first wait, the maximum is the ceiling that wait
// doubles towards, and zero is a legitimate answer for either.
fn delay_key(
  fields: Dict(String, tom.Toml),
  key: String,
  fallback: Int,
) -> Result(Int, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(fallback)
    Ok(tom.Int(milliseconds)) if milliseconds >= 0 -> Ok(milliseconds)
    Ok(_other) ->
      Error(
        "retry."
        <> key
        <> " must be a whole number of milliseconds, zero or more (the "
        <> "default is "
        <> int.to_string(fallback)
        <> ")",
      )
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in the [retry] table (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}
