//// The operator's `[retry]` table: what an absent table, a full table
//// and each rejection produce.
////
//// The parser performs no I/O, so every test here is a string in and a
//// `Result` out. The defaults are asserted against
//// `runtime/api.default_retry_policy` rather than against three
//// literals, because the point of the module is that the numbers live
//// in one place: a test that copied them would go on passing after the
//// runtime changed its default and the table stopped matching it.

import client/catalog
import client/retryconf
import gleam/string
import machine/operation
import runtime/api

pub fn a_document_with_no_retry_table_gets_the_runtime_default_test() {
  assert retryconf.parse_policy("") == Ok(api.default_retry_policy)

  // Another table in the file is not this one, and a document that
  // configures everything else still retries the way an unconfigured
  // server does.
  assert retryconf.parse_policy("[jobs]\nmax_wall = 60\n")
    == Ok(api.default_retry_policy)
}

pub fn a_full_retry_table_is_read_key_for_key_test() {
  assert retryconf.parse_policy(
      "[retry]\nattempts = 4\nbase_delay_ms = 250\nmax_delay_ms = 5000\n",
    )
    == Ok(operation.NormalizedRetryPolicy(
      attempts: operation.Bounded(max_attempts: 4),
      base_delay_ms: 250,
      max_delay_ms: 5000,
    ))
}

pub fn the_word_unbounded_asks_for_a_ladder_that_never_gives_up_test() {
  assert retryconf.parse_policy("[retry]\nattempts = \"unbounded\"\n")
    == Ok(api.default_retry_policy)
}

pub fn an_omitted_key_keeps_its_default_test() {
  // Only the ceiling moves: the attempts and the base delay are still
  // the runtime's, which is what makes capping the wait a one-line
  // table.
  assert retryconf.parse_policy("[retry]\nmax_delay_ms = 0\n")
    == Ok(operation.NormalizedRetryPolicy(
      attempts: api.default_retry_policy.attempts,
      base_delay_ms: api.default_retry_policy.base_delay_ms,
      max_delay_ms: 0,
    ))
}

pub fn a_table_that_is_not_a_table_is_refused_test() {
  let assert Error(reason) = retryconf.parse_policy("retry = 3\n")
    as "a scalar cannot carry three keys"
  assert string.contains(reason, "[retry]")
}

pub fn an_unknown_retry_key_is_refused_test() {
  let assert Error(reason) =
    retryconf.parse_policy("[retry]\nbase_delay = 100\n")
    as "a typo is a refusal, not a silent default"
  assert string.contains(reason, "base_delay")
}

pub fn zero_attempts_is_refused_test() {
  // Zero reads like "do not retry" to whoever wrote it and like "do not
  // try" to the ladder, so the parser refuses rather than choosing.
  let assert Error(reason) = retryconf.parse_policy("[retry]\nattempts = 0\n")
    as "there is no run with no attempts in it"
  assert string.contains(reason, "retry.attempts")
}

pub fn an_attempts_value_of_the_wrong_type_is_refused_test() {
  let assert Error(reason) =
    retryconf.parse_policy("[retry]\nattempts = \"forever\"\n")
    as "only the one word is spelled out"
  assert string.contains(reason, "unbounded")
}

pub fn a_negative_delay_is_refused_test() {
  let assert Error(base_reason) =
    retryconf.parse_policy("[retry]\nbase_delay_ms = -1\n")
    as "a wait cannot run backwards"
  assert string.contains(base_reason, "retry.base_delay_ms")

  let assert Error(max_reason) =
    retryconf.parse_policy("[retry]\nmax_delay_ms = -1\n")
    as "the ceiling cannot run backwards either"
  assert string.contains(max_reason, "retry.max_delay_ms")
}

pub fn a_delay_that_is_not_a_number_is_refused_test() {
  let assert Error(reason) =
    retryconf.parse_policy("[retry]\nmax_delay_ms = \"a minute\"\n")
    as "milliseconds are written as milliseconds"
  assert string.contains(reason, "milliseconds")
}

pub fn a_document_that_is_not_toml_is_refused_test() {
  let assert Error(reason) = retryconf.parse_policy("[retry\n")
    as "an unclosed table header is not a policy"
  assert string.contains(reason, "TOML")
}

// `serve.load_config` runs `catalog.parse` over the whole file before it
// hands the same text to `retryconf.parse_policy`, and the catalogue owns the
// top-level table names. A `[retry]` table once decoded correctly behind a
// boot that refused it, so this pins both halves on one document: the
// catalogue admits the table, and the policy read from the same text is the
// operator's.
pub fn a_retry_table_survives_the_catalogue_and_reaches_the_policy_test() {
  let text =
    "[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]

[retry]
attempts = 3
base_delay_ms = 10
max_delay_ms = 40
"
  let assert Ok(_catalogue) = catalog.parse(text)
    as "the top-level key check must admit [retry]"

  assert retryconf.parse_policy(text)
    == Ok(operation.NormalizedRetryPolicy(
      attempts: operation.Bounded(max_attempts: 3),
      base_delay_ms: 10,
      max_delay_ms: 40,
    ))

  // A key inside the table is still judged by its own parser.
  let bad = string.replace(text, "attempts = 3", "attemps = 3")
  let assert Ok(_catalogue) = catalog.parse(bad)
  let assert Error(reason) = retryconf.parse_policy(bad)
  assert string.contains(reason, "unknown key `attemps`")
}
