//// Small JSON field helpers shared by the provider adapters.
////
//// Adapters read provider wire JSON through these lookups. They are
//// lenient by design where pi's adapters are lenient — a missing or
//// null numeric usage field reads as its default, because real proxies
//// omit fields — while structurally malformed documents are still
//// rejected by `core/json.parse` before these helpers ever run.
////
//// `tool_arguments` is the one helper here that is not a field lookup. It
//// lives beside them because two dialects accumulate a tool call's
//// arguments as text and must settle that text the same way, and because
//// how a malformed one settles is a leniency decision of exactly the kind
//// this module's header is about.
////
//// ## Usage-counter clamping
////
//// `core/json` integers are arbitrary precision, but usage counters
//// flow into settled messages the durable planes must encode —
//// `core/msgpack` rejects integers outside `[-2^63, 2^64 - 1]` — so the
//// lenient read must not let untrusted wire produce an unencodable
//// durable value. Usage counters are therefore read through
//// `count_field_or`/`optional_count_field`, which **clamp** into
//// `[0, max_usage_count]` rather than failing the stream: a count
//// outside that range is physically impossible (no real request moves a
//// trillion tokens), so only a lying or broken proxy is ever clamped and
//// no real billing fact can be hidden. Saturation is the record of the
//// lie — a counter equal to `max_usage_count` is itself the sentinel
//// that the wire claimed more. Negative counts clamp to zero: they are
//// equally unreal, and letting them through would skew the adapters'
//// overflow arithmetic downward. The bound is far enough below `2^63`
//// that any sum of clamped counters (totals are composed from at most a
//// handful) stays msgpack-encodable.

import core/corruption
import core/json.{type JsonValue}
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Looks up an object field, first occurrence wins. `Error(Nil)` for
/// non-objects, missing fields, and explicit `null`.
pub fn field(value: JsonValue, name: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields:) ->
      case list.key_find(fields, name) {
        Ok(json.Null) -> Error(Nil)
        Ok(found) -> Ok(found)
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// A string field, `Error(Nil)` when absent or not a string.
pub fn string_field(value: JsonValue, name: String) -> Result(String, Nil) {
  case field(value, name) {
    Ok(json.String(value: text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

/// An integer field, `Error(Nil)` when absent or not an integer.
pub fn int_field(value: JsonValue, name: String) -> Result(Int, Nil) {
  case field(value, name) {
    Ok(json.Int(value: number)) -> Ok(number)
    _ -> Error(Nil)
  }
}

/// An integer field read leniently: absent, null, or non-integer reads as
/// `or`. For provider usage counters, where proxies omit fields.
pub fn int_field_or(value: JsonValue, name: String, or fallback: Int) -> Int {
  case int_field(value, name) {
    Ok(number) -> number
    Error(Nil) -> fallback
  }
}

/// An optional integer field: present integer reads as `Some`, anything
/// else as `None`.
pub fn optional_int_field(value: JsonValue, name: String) -> Option(Int) {
  case int_field(value, name) {
    Ok(number) -> Some(number)
    Error(Nil) -> None
  }
}

/// The inclusive upper bound for provider-reported usage counters: one
/// trillion tokens, four-plus orders of magnitude above any real request
/// and far enough below `2^63` that sums of clamped counters stay
/// msgpack-encodable. See the module documentation for the clamping
/// rationale.
pub const max_usage_count = 1_000_000_000_000

/// A usage counter read leniently and clamped: absent, null, or
/// non-integer reads as `or`, and the result saturates into
/// `[0, max_usage_count]` so untrusted wire can never produce a count
/// the durable planes cannot encode.
pub fn count_field_or(value: JsonValue, name: String, or fallback: Int) -> Int {
  clamp_count(int_field_or(value, name, or: fallback))
}

/// An optional usage counter: a present integer reads as `Some`, clamped
/// into `[0, max_usage_count]`; anything else as `None`.
pub fn optional_count_field(value: JsonValue, name: String) -> Option(Int) {
  option.map(optional_int_field(value, name), clamp_count)
}

// Saturates a counter into the encodable, semantically-valid range.
fn clamp_count(count: Int) -> Int {
  int.clamp(count, min: 0, max: max_usage_count)
}

/// A string field read leniently: absent or non-string reads as `or`.
pub fn string_field_or(
  value: JsonValue,
  name: String,
  or fallback: String,
) -> String {
  case string_field(value, name) {
    Ok(text) -> text
    Error(Nil) -> fallback
  }
}

/// An array field's items, `Error(Nil)` when absent or not an array.
pub fn array_field(
  value: JsonValue,
  name: String,
) -> Result(List(JsonValue), Nil) {
  case field(value, name) {
    Ok(json.Array(items:)) -> Ok(items)
    _ -> Error(Nil)
  }
}

/// Parses a `retry-after` hint from response headers into milliseconds:
/// `retry-after-ms` wins over `retry-after` (whole seconds). HTTP-date
/// forms are not parsed. Header names are expected lowercase, as the
/// transport normalizes them.
pub fn retry_after_ms(headers: List(#(String, String))) -> Option(Int) {
  case list.key_find(headers, "retry-after-ms") {
    // A present but unparsable `retry-after-ms` does not fall back to
    // `retry-after`: the header was given and malformed, which is a
    // different fact than the header being absent.
    Ok(text) -> option.from_result(parse_int(text))
    Error(Nil) -> retry_after_seconds_ms(headers)
  }
}

fn retry_after_seconds_ms(headers: List(#(String, String))) -> Option(Int) {
  case list.key_find(headers, "retry-after") {
    Ok(text) ->
      option.map(option.from_result(parse_int(text)), fn(seconds) {
        seconds * 1000
      })
    Error(Nil) -> None
  }
}

fn parse_int(text: String) -> Result(Int, Nil) {
  case int.parse(string.trim(text)) {
    Ok(number) if number >= 0 -> Ok(number)
    _ -> Error(Nil)
  }
}

/// The settled `arguments` for one tool call, from the argument text the
/// model streamed.
///
/// Empty text is how a provider spells a call to a tool that takes no
/// arguments, so it settles as the empty object. Text that is not JSON at
/// all is the case worth explaining. It used to fail the whole stream:
/// `build_blocks` propagated the parse error, the adapter settled it as
/// `MalformedStream`, and `provider/retry.classify` marks that terminal —
/// so one unbalanced brace inside one call ended a turn whose other blocks
/// were perfectly good, with nothing the model could read and correct.
///
/// The parse failure is now carried rather than raised. It settles as
/// `core/message.malformed_arguments`, an ordinary JSON object holding the
/// raw text and the parser's complaint, which `machine/planner` recognizes
/// and refuses in-band as an `is_error` tool result before the call can
/// reach clearance or execution. `MalformedStream` is left to mean what it
/// says: bytes the *provider* produced that were not the protocol.
///
/// ## Examples
///
/// ```gleam
/// assert wire.tool_arguments("") == json.Object([])
/// assert wire.tool_arguments("{\"path\":\"a\"}")
///   == json.Object([#("path", json.String("a"))])
/// assert result.is_ok(message.malformed_arguments_of(
///   wire.tool_arguments("{\"path\":"),
/// ))
/// ```
///
pub fn tool_arguments(arguments_json: String) -> JsonValue {
  case arguments_json {
    "" -> json.Object([])
    text ->
      case json.parse(text) {
        Ok(json.Object(_) as arguments) -> arguments

        // Text that parses but is not an object is the same failure from
        // the model's side: a tool call's arguments are an object by
        // contract, every dialect's encoder replays them as one, and the
        // Anthropic and Gemini dialects refuse a request whose historical
        // `input` is `null` or a list. So the value is carried as
        // malformed rather than stored, for the same reason the parse
        // failure is.
        Ok(json.Array(_))
        | Ok(json.String(_))
        | Ok(json.Int(_))
        | Ok(json.Float(_))
        | Ok(json.Bool(_))
        | Ok(json.Null) ->
          message.malformed_arguments(
            raw: text,
            reason: "tool call arguments must be a JSON object",
          )

        // The report names the offset, what a well-formed document would
        // have had there, and a bounded excerpt of what was found; that is
        // exactly the correction the model needs, so it goes through
        // verbatim rather than being reworded into something vaguer.
        Error(report) ->
          message.malformed_arguments(
            raw: text,
            reason: corruption.describe(report),
          )
      }
  }
}
