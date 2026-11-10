//// Platform-selected JSON at the harness's byte boundaries.
////
//// The value type and reference implementation belong to pure `core`. This
//// package supplies interchangeable callbacks without adding an external to
//// that portable dependency graph. Erlang uses OTP's JSON callbacks to build
//// the same ordered value directly; JavaScript uses the reference functions.
//// Native refusals return through the reference parser so complete corruption
//// reports retain their original source positions, wording and context.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import json_codec/internal/ffi_json

/// The two total JSON operations selected by a host or a comparison fixture.
/// The callbacks carry no mutable selection or authority.
pub type Codec {
  Codec(
    /// Parse one complete document, preserving order and rejecting duplicates.
    parse: fn(String) -> Result(JsonValue, CorruptionReport),
    /// Serialize exactly as the portable encoder, including hand-built keys.
    to_string: fn(JsonValue) -> String,
  )
}

/// Select the platform implementation while retaining the portable contract.
///
/// ## Examples
///
/// ```gleam
/// assert json_codec.platform().parse("null") == Ok(json.Null)
/// ```
pub fn platform() -> Codec {
  Codec(parse:, to_string:)
}

/// Select the reference implementation explicitly for replay or embedding.
///
/// ## Examples
///
/// ```gleam
/// assert json_codec.portable().to_string(json.Null) == "null"
/// ```
pub fn portable() -> Codec {
  Codec(parse: json.parse, to_string: json.to_string)
}

/// Parse with the platform codec, returning the reference report on refusal.
///
/// ## Examples
///
/// ```gleam
/// assert json_codec.parse("[true]") == Ok(json.Array([json.Bool(True)]))
/// ```
pub fn parse(text: String) -> Result(JsonValue, CorruptionReport) {
  ffi_json.parse(text, json.max_depth)
}

/// Serialize with the reference encoder on every target.
///
/// ## Examples
///
/// ```gleam
/// assert json_codec.to_string(json.String("hello")) == "\"hello\""
/// ```
pub fn to_string(value: JsonValue) -> String {
  json.to_string(value)
}
