//// Small JSON field helpers shared by the provider adapters.
////
//// Adapters read provider wire JSON through these lookups. They are
//// lenient by design where pi's adapters are lenient — a missing or
//// null numeric usage field reads as its default, because real proxies
//// omit fields — while structurally malformed documents are still
//// rejected by `core/json.parse` before these helpers ever run.
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

import core/json.{type JsonValue}
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
    Ok(text) ->
      case parse_int(text) {
        Ok(ms) -> Some(ms)
        Error(Nil) -> None
      }
    Error(Nil) ->
      case list.key_find(headers, "retry-after") {
        Ok(text) ->
          case parse_int(text) {
            Ok(seconds) -> Some(seconds * 1000)
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
  }
}

fn parse_int(text: String) -> Result(Int, Nil) {
  case int.parse(string.trim(text)) {
    Ok(number) if number >= 0 -> Ok(number)
    _ -> Error(Nil)
  }
}
