//// The single native JSON boundary; no external enters the pure core.
////
//// OTP's decoder callbacks cannot be called from the portable standard
//// library. ADR-023 records this measured, scoped FFI exception. The Gleam
//// bodies remain the JavaScript implementation, with the same public values.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}

/// Invoke OTP's callback decoder on Erlang and the reference parser elsewhere.
/// Every native refusal delegates to `core/json.parse` for the exact report.
///
/// ## Examples
///
/// ```gleam
/// assert ffi_json.parse("null", json.max_depth) == Ok(json.Null)
/// ```
@external(erlang, "json_codec_ffi", "parse")
pub fn parse(
  text: String,
  _maximum_depth: Int,
) -> Result(JsonValue, CorruptionReport) {
  json.parse(text)
}
