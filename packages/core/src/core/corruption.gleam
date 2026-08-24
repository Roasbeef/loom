//// Structured corruption reports.
////
//// Every durability or wire boundary in Loom decodes with a total decoder
//// returning `Result(t, CorruptionReport)`. This module defines that error
//// type: a small structured record saying *where* the bad data was met,
//// *which* key or id it concerned, *what* the decoder expected, and the raw
//// context it saw instead. Reports are plain data — they carry no stack
//// traces and are themselves safely encodable (see `core/codec`).
////
//// The context excerpt is bounded: reports are built from adversarial
//// input, and an unbounded excerpt would let a hostile multi-megabyte
//// payload bloat every log line or persisted report derived from its
//// failure. `report` truncates `context` to `max_context_length`
//// graphemes, so a report's size is bounded regardless of its input.

import gleam/string

/// The maximum number of graphemes `report` keeps of a `context` excerpt.
/// Generous for the diagnostic excerpts decoders build (they trim first —
/// `core/json` to 24 codepoints, `core/msgpack` to 16 bytes) while
/// bounding the sites that embed a re-serialized offending value.
pub const max_context_length = 256

/// A structured description of data that failed a total decode.
///
/// Invariants: all four fields are human-readable descriptions, never
/// machine-parsed. `boundary` names the decoding site (conventionally the
/// module and decoder, e.g. `"core/json.parse"`), `subject` names the key,
/// id, field path, or offset concerned, `expected` states what a well-formed
/// value would have looked like, and `context` carries an excerpt of the raw
/// input actually seen. Any field may be `""` when there is nothing to say.
/// Build reports with `report`, which bounds `context` to
/// `max_context_length` graphemes; direct construction bypasses that bound
/// and should not be used with untrusted input.
pub type CorruptionReport {
  CorruptionReport(
    boundary: String,
    subject: String,
    expected: String,
    context: String,
  )
}

/// Builds a corruption report. Identical to calling the constructor except
/// that `context` is truncated to `max_context_length` graphemes (with a
/// trailing `…` marker when it was cut), so a report built from hostile
/// input has bounded size. Kept as a labelled smart-constructor so call
/// sites read as prose.
///
/// ## Examples
///
/// ```gleam
/// assert corruption.report(
///   at: "core/json.parse",
///   on: "offset 3",
///   expected: "a digit",
///   context: "\"x\"",
/// ).boundary
///   == "core/json.parse"
/// ```
///
pub fn report(
  at boundary: String,
  on subject: String,
  expected expected: String,
  context context: String,
) -> CorruptionReport {
  CorruptionReport(boundary:, subject:, expected:, context: bound(context))
}

// Truncates oversized context excerpts, marking the cut with an ellipsis.
fn bound(context: String) -> String {
  case string.length(context) > max_context_length {
    True ->
      string.slice(context, at_index: 0, length: max_context_length) <> "…"
    False -> context
  }
}

/// Renders a report as a single human-readable line, for logs and error
/// messages.
///
/// ## Examples
///
/// ```gleam
/// let report =
///   corruption.report(at: "b", on: "s", expected: "e", context: "c")
/// assert corruption.describe(report)
///   == "corruption at b (s): expected e, got: c"
/// ```
///
pub fn describe(report: CorruptionReport) -> String {
  "corruption at "
  <> report.boundary
  <> " ("
  <> report.subject
  <> "): expected "
  <> report.expected
  <> ", got: "
  <> report.context
}
