//// Structured corruption reports.
////
//// Every durability or wire boundary in Loom decodes with a total decoder
//// returning `Result(t, CorruptionReport)`. This module defines that error
//// type: a small structured record saying *where* the bad data was met,
//// *which* key or id it concerned, *what* the decoder expected, and the raw
//// context it saw instead. Reports are plain data — they carry no stack
//// traces and are themselves safely encodable (see `core/codec`).

/// A structured description of data that failed a total decode.
///
/// Invariants: all four fields are human-readable descriptions, never
/// machine-parsed. `boundary` names the decoding site (conventionally the
/// module and decoder, e.g. `"core/json.parse"`), `subject` names the key,
/// id, field path, or offset concerned, `expected` states what a well-formed
/// value would have looked like, and `context` carries an excerpt of the raw
/// input actually seen. Any field may be `""` when there is nothing to say.
pub type CorruptionReport {
  CorruptionReport(
    boundary: String,
    subject: String,
    expected: String,
    context: String,
  )
}

/// Builds a corruption report. Identical to calling the constructor, kept as
/// a labelled smart-constructor so call sites read as prose.
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
  CorruptionReport(boundary:, subject:, expected:, context:)
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
