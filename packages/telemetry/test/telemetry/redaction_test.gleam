//// The secret invariant, tested rather than asserted: no rendered log
//// line may carry a provider API key, the broker's clearance token, or
//// the cap channel's 32-byte token (`docs/architecture/effects.md`
//// security invariant 4, spec §3.3.4).
////
//// The shape of the test is deliberate: plant a known secret, render,
//// and grep the rendered bytes for it. A rule that only inspects field
//// keys would pass a secret smuggled inside a `reason` string, so every
//// planted secret is placed twice — once under a key the denylist
//// names, once under a key it does not.

import gleam/list
import gleam/string
import telemetry/context
import telemetry/field
import telemetry/level
import telemetry/record

// An Anthropic-shaped key: the `sk-ant-` prefix plus a long body.
const provider_key = "sk-ant-api03-9fJ2kQwErTyUiOpAsDfGhJkLzXcVbNm1234567890abcdefGH"

// A broker clearance token as hex: 32 random bytes, 64 hex characters.
const clearance_hex = "3f5a9c1d7b2e4086af13c5d9e07b6482913ac5de7f024b8619cd3a5e7f01b2c4"

// A cap channel token as base64url: the same 32 bytes, 43 characters.
const channel_token = "P1qcHXsuQIavE8XZ4HtkgpE6xd5_Aku4Gc06Xn8Bssc"

// A minted entry id. Loom identifiers are not secrets and must survive
// scrubbing, or the test above would pass vacuously on a scrubber that
// simply erased everything.
const entry_id = "01924f7e-3c1a-7abc-8def-0123456789ab"

fn planted() -> List(String) {
  [provider_key, clearance_hex, channel_token]
}

// Every planted secret twice: under a key the denylist names, and under
// an innocent key where only the value's shape can save it.
fn planted_fields() -> List(field.Field) {
  [
    field.text(key: "api_key", value: provider_key),
    field.text(key: "detail", value: "provider refused: " <> provider_key),
    field.text(key: "clearance_token", value: clearance_hex),
    field.text(key: "reason", value: "token " <> clearance_hex <> " expired"),
    field.text(key: "channel_token", value: channel_token),
    field.text(key: "frame", value: "hello " <> channel_token <> " world"),
  ]
}

fn rendered() -> String {
  record.render(record.Record(
    level: level.Error,
    event: "effect.failed",
    context: context.for_session("s-1")
      |> context.with_strand("main")
      |> context.with_op("op-7")
      |> context.with_step("step-2"),
    fields: planted_fields(),
  ))
}

pub fn no_planted_secret_survives_rendering_test() {
  let line = rendered()
  list.each(planted(), fn(secret) {
    assert !string.contains(line, secret)
      as { "the rendered line still carries a planted secret: " <> secret }
  })
}

pub fn a_secret_under_an_innocent_key_is_still_removed_test() {
  // The `detail`/`reason`/`frame` keys are not on any denylist; only the
  // value's shape can catch these.
  let line =
    record.render(
      record.Record(
        level: level.Warning,
        event: "provider.retry",
        context: context.anonymous,
        fields: [
          field.text(key: "detail", value: "auth failed for " <> provider_key),
        ],
      ),
    )
  assert !string.contains(line, provider_key)
  assert string.contains(line, "auth failed for")
}

pub fn redaction_leaves_the_rest_of_the_message_readable_test() {
  let line =
    record.render(
      record.Record(
        level: level.Error,
        event: "tool.failed",
        context: context.anonymous,
        fields: [
          field.text(
            key: "reason",
            value: "read of " <> clearance_hex <> " denied",
          ),
        ],
      ),
    )
  assert string.contains(line, "read of")
  assert string.contains(line, "denied")
  assert string.contains(line, field.redacted_marker)
}

pub fn a_loom_identifier_is_not_mistaken_for_a_secret_test() {
  let line =
    record.render(
      record.Record(
        level: level.Info,
        event: "entry.committed",
        context: context.anonymous,
        fields: [field.ident(key: "entry", value: entry_id)],
      ),
    )
  assert string.contains(line, entry_id)
}

pub fn a_denylisted_key_is_redacted_whatever_it_holds_test() {
  // Shape alone would let a short token through; the key rule is what
  // catches it.
  let line =
    record.render(
      record.Record(
        level: level.Debug,
        event: "broker.cleared",
        context: context.anonymous,
        fields: [field.text(key: "capability_token", value: "abc123")],
      ),
    )
  assert !string.contains(line, "abc123")
  assert string.contains(line, field.redacted_marker)
}

pub fn the_key_rule_survives_the_ident_escape_hatch_test() {
  // `ident` opts out of the shape rule, never out of the key rule.
  let line =
    record.render(
      record.Record(
        level: level.Debug,
        event: "broker.cleared",
        context: context.anonymous,
        fields: [field.ident(key: "clearance", value: "abc123")],
      ),
    )
  assert !string.contains(line, "abc123")
}

pub fn a_file_path_is_not_a_secret_test() {
  // The shape rule must not eat ordinary diagnostics: a long path is
  // several short segments, not one credential-shaped run.
  let path = "/home/user/loom/packages/telemetry/src/telemetry/field.gleam"
  let line =
    record.render(
      record.Record(
        level: level.Error,
        event: "fs.failed",
        context: context.anonymous,
        fields: [field.text(key: "path", value: path)],
      ),
    )
  assert string.contains(line, path)
}
