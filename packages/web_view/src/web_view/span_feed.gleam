//// The lines of one timeline span, as Home holds them (protocol-change/134,
//// `sessions.span`).
////
//// A card says what a span was about; a reader who presses it wants the span's
//// own records as a short list. The daemon answers `sessions.span` with the lines
//// `session_view/span_lines` makes of them. This module is the types, the one
//// total decoder from that reply and the encoder the resident answers with. A
//// line's words are session text, wrapped in `session_brief.Untrusted`, so a page
//// draws them as text nodes only. It draws nothing and performs no I/O.
////
//// ## Flow
////
//// `of_lines` → `to_json` → `decode` → `line`
////
//// 1. `of_lines` wraps a span's lines in the wire's types.
//// 2. `to_json` is the reply the resident builds and `decode` is its inverse, a
////    line that does not read being left out.

import core/json.{type JsonValue}
import gleam/list

import gleam/result
import session_view/span_lines
import web_view/session_brief.{type Untrusted}

/// One line of a span.
pub type Line {
  Line(
    seq: Int,
    at: Int,
    kind: span_lines.Kind,
    /// The line's words, which an agent, a tool or a person wrote.
    words: Untrusted,
    outcome: span_lines.Outcome,
  )
}

/// A span's lines and how many older ones were left out.
pub type Feed {
  Feed(lines: List(Line), omitted: Int)
}

/// What the page holds of one span.
pub type Seen {
  /// The read is out.
  Loading

  /// The daemon answered with these lines.
  Read(feed: Feed)

  /// The daemon refused or did not answer. The words are its fixed ones.
  Refused(words: String)
}

/// A span's lines in the wire's types.
///
/// ## Examples
///
/// ```gleam
/// assert span_feed.of_lines([], 0) == span_feed.Feed([], 0)
/// ```
pub fn of_lines(lines: List(span_lines.Line), omitted: Int) -> Feed {
  Feed(
    lines: list.map(lines, fn(each) {
      Line(
        seq: each.seq,
        at: each.at,
        kind: each.kind,
        words: session_brief.untrusted(each.words),
        outcome: each.outcome,
      )
    }),
    omitted:,
  )
}

/// The reply a resident answers with: `{"span": {"lines": [...], "omitted": n}}`.
///
/// ## Examples
///
/// ```gleam
/// assert span_feed.decode(span_feed.to_json(feed)) == Ok(feed)
/// ```
pub fn to_json(feed: Feed) -> JsonValue {
  json.Object([
    #(
      "span",
      json.Object([
        #("lines", json.Array(list.map(feed.lines, line_json))),
        #("omitted", json.Int(feed.omitted)),
      ]),
    ),
  ])
}

/// The span of a reply `{"span": {...}}`, or nothing for a reply that is not one.
/// A damaged line is left out and the others are kept.
///
/// ## Examples
///
/// ```gleam
/// assert span_feed.decode(json.Null) == Error(Nil)
/// ```
pub fn decode(value: JsonValue) -> Result(Feed, Nil) {
  use fields <- result.try(object(value))
  use inner <- result.try(list.key_find(fields, "span"))
  use inner <- result.map(object(inner))

  Feed(
    lines: lines_of(inner),
    omitted: option.unwrap(option.from_result(whole(inner, "omitted")), 0),
  )
}

/// The lines of a span object, keeping the ones that read.
fn lines_of(fields: List(#(String, JsonValue))) -> List(Line) {
  // A section that is not a list holds nothing.
  case list.key_find(fields, "lines") {
    Ok(json.Array(raw)) ->
      list.filter_map(raw, fn(value) { object(value) |> result.try(line) })
    Ok(_) | Error(Nil) -> []
  }
}

/// One line, or nothing when a required member is missing or of the wrong type.
fn line(fields: List(#(String, JsonValue))) -> Result(Line, Nil) {
  use seq <- result.try(whole(fields, "seq"))
  use at <- result.try(whole(fields, "at"))
  use kind <- result.try(text(fields, "kind") |> result.try(kind_of))
  use words <- result.try(text(fields, "words"))
  use outcome <- result.map(text(fields, "outcome") |> result.try(outcome_of))

  Line(seq:, at:, kind:, words: session_brief.untrusted(words), outcome:)
}

/// The kind a word names, or nothing for a word this page does not know.
fn kind_of(word: String) -> Result(span_lines.Kind, Nil) {
  // Each word is the one `kind_word` gives its kind.
  case word {
    "prompt" -> Ok(span_lines.Prompted)
    "said" -> Ok(span_lines.Said)
    "step" -> Ok(span_lines.Step)
    "compaction" -> Ok(span_lines.Compacted)
    _ -> Error(Nil)
  }
}

/// The word for a kind.
fn kind_word(kind: span_lines.Kind) -> String {
  // The inverse of `kind_of`.
  case kind {
    span_lines.Prompted -> "prompt"
    span_lines.Said -> "said"
    span_lines.Step -> "step"
    span_lines.Compacted -> "compaction"
  }
}

/// The outcome a word names, or nothing for a word this page does not know.
fn outcome_of(word: String) -> Result(span_lines.Outcome, Nil) {
  // Each word is the one `outcome_word` gives its outcome.
  case word {
    "none" -> Ok(span_lines.NoOutcome)
    "running" -> Ok(span_lines.Running)
    "succeeded" -> Ok(span_lines.Succeeded)
    "failed" -> Ok(span_lines.Failed)
    _ -> Error(Nil)
  }
}

/// The word for an outcome.
fn outcome_word(outcome: span_lines.Outcome) -> String {
  // The inverse of `outcome_of`.
  case outcome {
    span_lines.NoOutcome -> "none"
    span_lines.Running -> "running"
    span_lines.Succeeded -> "succeeded"
    span_lines.Failed -> "failed"
  }
}

/// One line as the wire carries it. Its words are marked untrusted.
fn line_json(line: Line) -> JsonValue {
  json.Object([
    #("seq", json.Int(line.seq)),
    #("at", json.Int(line.at)),
    #("kind", json.String(kind_word(line.kind))),
    #("words", json.String(session_brief.untrusted_text(line.words))),
    #("trust", json.String("untrusted")),
    #("outcome", json.String(outcome_word(line.outcome))),
  ])
}

/// The fields of an object.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  // Only an object has fields.
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// A string field.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  // Only a string is text.
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// A whole non-negative number: a time, a sequence or a count.
fn whole(fields: List(#(String, JsonValue)), name: String) -> Result(Int, Nil) {
  // A negative number is not a count.
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}
