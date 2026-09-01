//// Log field values, and the redaction rule that keeps secrets out of
//// them.
////
//// ## The rule
////
//// **No log line may carry a token, an API key, or a capability
//// token.** `docs/architecture/effects.md` and spec §3.3.4 say secrets
//// appear only in ProviderGateway request memory — never in envs,
//// transcripts, logs, or satellite-reachable state. Logs are the leg
//// with the most call sites and the least review, so the rule is
//// enforced here, in the one place every field passes through, rather
//// than asked of every author.
////
//// Two independent checks, because either alone has a known hole:
////
//// 1. **The key rule.** A field whose key names a credential
////    (`token`, `api_key`, `secret`, `authorization`, `clearance`, …)
////    is replaced by `Redacted` whatever it holds. This catches short
////    secrets that no shape rule could recognise.
//// 2. **The shape rule.** Every remaining `Text` value is scanned
////    token by token, and any token that looks like credential
////    material — a known vendor prefix, or an unbroken 32-character
////    run of credential alphabet — is replaced. This catches the
////    secret smuggled into an innocent key, which is how it actually
////    happens: `reason: "auth failed for sk-ant-…"`.
////
//// Only the offending token is replaced, not the whole value, so a
//// scrubbed line is still a readable diagnostic.
////
//// ## The escape hatch, and why it is typed
////
//// The shape rule is deliberately blunt: 32 unbroken alphabet
//// characters is also what a SHA-256 digest, a content hash, and some
//// long identifiers look like. Rather than grow exceptions into the
//// rule, values that are *known* to be loom-minted identifiers are
//// declared as `Ident` at the call site. `Ident` opts out of the shape
//// rule and nothing else — the key rule still applies to it — so every
//// exemption is a deliberate, greppable act by an author who knew what
//// the value was, and no exemption can hide a value whose key already
//// said "credential".
////
//// The 32-character threshold is chosen against what loom actually
//// holds: the broker's clearance token and the cap channel's token are
//// both 32 random bytes, which is 64 hex characters or 43 base64url
//// ones, and a provider key carries a vendor prefix. Ordinary
//// diagnostics — paths, module names, UUIDs, English — break into
//// tokens far shorter than that.

import gleam/int
import gleam/list
import gleam/string

/// The text a redacted value renders as. Chosen to be greppable and
/// obviously not a value: an operator seeing it knows a rule fired, not
/// that the field was empty.
pub const redacted_marker = "<redacted>"

/// A log field's value.
///
/// Constructor invariants:
///
/// - `Text` is free text and is *always* shape-scrubbed. Use it for
///   anything derived from a message, an error, or a foreign string.
/// - `Ident` is a loom-minted identifier — an entry id, an op id, a
///   digest, a strand name — and is exempt from the shape rule. It is
///   not exempt from the key rule. Reach for it only when you know what
///   the value is; a value you merely hope is safe is `Text`.
/// - `Redacted` is what the rules produce. Constructing it directly is
///   legal and means "this field exists and I am deliberately not
///   saying what it holds".
pub type Value {
  /// Free text. Shape-scrubbed.
  Text(String)

  /// A loom-minted identifier. Exempt from the shape rule only.
  Ident(String)

  /// A number. Never scrubbed — a count carries no credential.
  Count(Int)

  /// A boolean. Never scrubbed.
  Flag(Bool)

  /// A value deliberately withheld.
  Redacted
}

/// One key/value pair on a log record.
///
/// Constructor invariants: `key` is a short lower_snake_case name; keys
/// are unique within a record (`telemetry/record` keeps the first
/// occurrence of a duplicate, since `core/json` treats a duplicated
/// object key as corruption).
pub type Field {
  Field(key: String, value: Value)
}

/// A free-text field. The value is shape-scrubbed on render.
///
/// ## Examples
///
/// ```gleam
/// field.text(key: "reason", value: "the lease was lost")
/// ```
///
pub fn text(key key: String, value value: String) -> Field {
  Field(key:, value: Text(value))
}

/// An identifier field, exempt from the shape rule. See the module doc
/// before reaching for this.
///
/// ## Examples
///
/// ```gleam
/// field.ident(key: "entry", value: core_ids.entry_id_to_string(id))
/// ```
///
pub fn ident(key key: String, value value: String) -> Field {
  Field(key:, value: Ident(value))
}

/// A numeric field.
///
/// ## Examples
///
/// ```gleam
/// field.count(key: "attempt", value: 2)
/// ```
///
pub fn count(key key: String, value value: Int) -> Field {
  Field(key:, value: Count(value))
}

/// A boolean field.
///
/// ## Examples
///
/// ```gleam
/// field.flag(key: "replay", value: True)
/// ```
///
pub fn flag(key key: String, value value: Bool) -> Field {
  Field(key:, value: Flag(value))
}

/// Applies both redaction rules to one field. Idempotent, and total:
/// there is no input for which it fails or leaves a recognised secret
/// in place.
///
/// ## Examples
///
/// ```gleam
/// assert field.scrub(field.text(key: "api_key", value: "sk-x"))
///   == field.Field(key: "api_key", value: field.Redacted)
/// ```
///
pub fn scrub(field: Field) -> Field {
  case secret_key(field.key) {
    True -> Field(..field, value: Redacted)
    False ->
      case field.value {
        Text(value) -> Field(..field, value: Text(scrub_text(value)))
        Ident(_) | Count(_) | Flag(_) | Redacted -> field
      }
  }
}

/// Whether a field key names a credential. Substring matching, because
/// real keys compound (`api_key_secret`, `clearance_token_bytes`) and a
/// false positive costs one unreadable field while a false negative
/// costs a leaked secret.
///
/// ## Examples
///
/// ```gleam
/// assert field.secret_key("api_key_secret")
/// assert !field.secret_key("session")
/// ```
///
pub fn secret_key(key: String) -> Bool {
  let key = string.lowercase(key)
  key == "key"
  || list.any(credential_words, fn(word) { string.contains(key, word) })
}

// Substrings that make a key a credential name. `key` alone is too
// common a word to match on as a substring (`register_key`,
// `arguments_key`), so it is handled as an exact match above and only
// its compounds appear here.
const credential_words = [
  "api_key", "apikey", "private_key", "public_key", "secret_key", "session_key",
  "signing_key", "token", "secret", "password", "passwd", "passphrase",
  "credential", "authorization", "authorisation", "bearer", "cookie",
  "clearance",
]

/// Replaces every credential-shaped token in free text, leaving the
/// rest of the text intact so the line is still a diagnostic.
///
/// This is also what the Erlang handler calls to scrub log lines the
/// harness did not author (OTP reports, third-party libraries), which
/// arrive with no field types to reason about — see
/// `telemetry/internal/ffi_logger`.
///
/// ## Examples
///
/// ```gleam
/// // field.scrub_text("auth failed for sk-ant-...")
/// // -> "auth failed for <redacted>"
/// ```
///
pub fn scrub_text(text: String) -> String {
  text
  |> string.to_graphemes
  |> split_tokens([], [])
  |> list.map(fn(piece) {
    case piece {
      Token(word) ->
        case secret_shaped(word) {
          True -> redacted_marker
          False -> word
        }
      Gap(text) -> text
    }
  })
  |> string.concat
}

/// Whether one token looks like credential material: a known vendor
/// prefix, or a long unbroken run of credential alphabet. A UUID is
/// never credential-shaped — loom mints them everywhere and they carry
/// no authority.
///
/// ## Examples
///
/// ```gleam
/// assert field.secret_shaped("sk-ant-api03-abc")
/// assert !field.secret_shaped("01924f7e-3c1a-7abc-8def-0123456789ab")
/// ```
///
pub fn secret_shaped(word: String) -> Bool {
  case is_uuid(word) {
    True -> False
    False ->
      list.any(credential_prefixes, fn(prefix) {
        string.starts_with(word, prefix)
      })
      || at_least(word, credential_run)
  }
}

// Whether a token is at least `run` graphemes long, answered by dropping
// `run - 1` of them and asking whether anything is left.
//
// `string.length(word) >= run` walks the whole token, and this one runs per
// token of every scrubbed log field — including OTP report lines, where a
// single unbroken 100 KB value is an ordinary accident. The question is
// settled by the thirty-second grapheme either way.
fn at_least(word: String, run: Int) -> Bool {
  string.drop_start(word, run - 1) != ""
}

/// The unbroken token length at which a value is assumed to be
/// credential material. Both of loom's own tokens are 32 random bytes,
/// which is 43 base64url characters or 64 hex ones; ordinary
/// diagnostics tokenize far shorter.
pub const credential_run = 32

// Vendor prefixes that identify a credential regardless of length.
// Matched against a whole token, so `task-` cannot collide with `sk-`.
const credential_prefixes = [
  "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_",
  "glpat-", "xoxb-", "xoxp-", "xoxa-", "xapp-", "AKIA", "ASIA", "AIza", "ya29.",
]

// The pieces `scrub_text` walks: credential-alphabet runs, and the
// separators between them. `/` and `.` are separators rather than token
// characters so that a long path or a dotted module name breaks into
// short segments instead of reading as one 32-character run.
type Piece {
  Token(String)
  Gap(String)
}

fn split_tokens(
  graphemes: List(String),
  current: List(String),
  acc: List(Piece),
) -> List(Piece) {
  case graphemes {
    [] -> list.reverse(flush(current, acc))
    [grapheme, ..rest] ->
      case token_character(grapheme) {
        True -> split_tokens(rest, [grapheme, ..current], acc)
        False -> split_tokens(rest, [], [Gap(grapheme), ..flush(current, acc)])
      }
  }
}

fn flush(current: List(String), acc: List(Piece)) -> List(Piece) {
  case current {
    [] -> acc
    _ -> [Token(string.concat(list.reverse(current))), ..acc]
  }
}

fn token_character(grapheme: String) -> Bool {
  case grapheme {
    "-" | "_" | "+" | "=" -> True
    _ -> is_alphanumeric(grapheme)
  }
}

fn is_alphanumeric(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [codepoint] -> {
      let value = string.utf_codepoint_to_int(codepoint)
      { value >= 48 && value <= 57 }
      || { value >= 65 && value <= 90 }
      || { value >= 97 && value <= 122 }
    }
    _ -> False
  }
}

// The 8-4-4-4-12 hexadecimal shape. Loom's entry, usage and op ids are
// UUIDv7 and appear in error text constantly; treating them as secrets
// would make the shape rule unusable.
fn is_uuid(word: String) -> Bool {
  // Thirty-six bytes exactly, dashes included, and every grapheme that can
  // pass `hex_run` is one byte — so asking the binary its own size settles
  // most tokens for free, where `string.split` would walk all of a 100 KB
  // value to find out there are no dashes in it.
  case string.byte_size(word) == uuid_bytes {
    False -> False
    True -> uuid_runs(word)
  }
}

const uuid_bytes = 36

fn uuid_runs(word: String) -> Bool {
  case string.split(word, "-") {
    [a, b, c, d, e] ->
      hex_run(a, 8)
      && hex_run(b, 4)
      && hex_run(c, 4)
      && hex_run(d, 4)
      && hex_run(e, 12)
    _ -> False
  }
}

// `byte_size` rather than `string.length`: it is the binary's own size on
// the BEAM rather than a grapheme walk, and the hex test below makes the
// two agree on anything that can return `True` — a multi-byte grapheme
// costs more bytes than it does graphemes, so it can only make this
// comparison hold on a segment that then fails to be hexadecimal.
fn hex_run(text: String, length: Int) -> Bool {
  string.byte_size(text) == length
  && list.all(string.to_graphemes(text), fn(grapheme) {
    case int.base_parse(grapheme, 16) {
      Ok(_) -> True
      Error(Nil) -> False
    }
  })
}
