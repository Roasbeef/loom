//// The parser for a triage model's answer, total over any text a model can
//// return (`docs/design-notes/insight-triage.md`, sections 3.2 and 4.3).
////
//// The request asks for one line per row in the form
//// `<number> <weight> <reason>`. The answer is data under a closed schema:
//// a weight from three words, a row number the request issued, and a reason
//// of at most `attention.head_limit` graphemes with no control character.
//// The parser never looks anything up by a name the model supplied, so a
//// hostile reason cannot select another row, and the worst a wrong label does
//// is move one row within the Insights group.
////
//// ## What is refused
////
//// An answer is refused whole, with the reason, when a line is not in the
//// form, when a weight is not one of the three words, when a reason holds a
//// control character, or when no line labels a row the request issued. It is
//// never repaired: a model that cannot follow a three-word schema has not
//// said what its labels mean. A number outside the request is dropped, and so
//// is a second line for a number already labelled, since a label never
//// changes once written.

import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import session_view/attention

/// How soon the owner should open a row, in the model's opinion.
pub type Weight {
  High
  Normal
  Low
}

/// One row's label: the row's number in the request, its weight and the
/// reason the model gave.
pub type Label {
  Label(
    /// The row's position in the request, from one.
    row: Int,
    /// The model's weight for the row.
    weight: Weight,
    /// One line of at most `attention.head_limit` graphemes. Untrusted text.
    why: String,
  )
}

/// Why an answer was refused.
pub type Refusal {
  /// A line was not `<number> <weight> <reason>`.
  BadLine(line: String)

  /// A line's weight was not `high`, `normal` or `low`.
  BadWeight(word: String)

  /// A line's reason held a control character.
  ControlCharacter(line: String)

  /// No line labelled a row the request issued.
  NoLabels
}

/// The words a weight is written as.
///
/// ## Examples
///
/// ```gleam
/// assert answer.weight_word(answer.High) == "high"
/// ```
pub fn weight_word(weight: Weight) -> String {
  case weight {
    High -> "high"
    Normal -> "normal"
    Low -> "low"
  }
}

/// Why an answer was refused, in words that quote none of it, so a report that
/// prints them shows nothing the owner has not yet marked against.
///
/// ## Examples
///
/// ```gleam
/// assert answer.describe(answer.NoLabels) == "no line labels a row the request issued"
/// ```
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    BadLine(..) -> "a line is not in the form number, weight, reason"
    BadWeight(..) -> "a weight is not high, normal or low"
    ControlCharacter(..) -> "a line holds a control character"
    NoLabels -> "no line labels a row the request issued"
  }
}

/// Reads the model's answer to a request that numbered `rows` rows.
///
/// ## Examples
///
/// ```gleam
/// assert answer.parse("1 high It failed three times.", 2)
///   == Ok([answer.Label(1, answer.High, "It failed three times.")])
/// ```
///
/// ```gleam
/// assert answer.parse("1 urgent No.", 2) == Error(answer.BadWeight("urgent"))
/// ```
pub fn parse(text: String, rows: Int) -> Result(List(Label), Refusal) {
  let lines =
    string.split(text, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" && !string.starts_with(line, "```") })

  use read <- result.try(list.try_map(lines, read_line))
  let issued =
    list.filter(read, fn(label) { label.row >= 1 && label.row <= rows })
  let labels = first_of_each(issued)

  // An answer that labels nothing the request issued says nothing, which is
  // refused and not read as "every row is normal".
  case labels {
    [] -> Error(NoLabels)
    [_, ..] -> Ok(labels)
  }
}

/// One line of the answer.
fn read_line(line: String) -> Result(Label, Refusal) {
  use _ <- result.try(refuse_control(line))
  use #(first, rest) <- result.try(
    string.split_once(line, " ") |> result.replace_error(BadLine(line)),
  )
  use row <- result.try(
    int.parse(trim_end(first, [".", ":", ")"]))
    |> result.replace_error(BadLine(line)),
  )
  let #(word, why) = split_word(rest)
  use weight <- result.try(weight_of(word))

  Ok(Label(row:, weight:, why: cut(why)))
}

/// A line with a control character is refused whole.
fn refuse_control(line: String) -> Result(Nil, Refusal) {
  case has_control(line) {
    True -> Error(ControlCharacter(line))
    False -> Ok(Nil)
  }
}

/// The weight word at the front of what follows the row number, and the rest.
fn split_word(rest: String) -> #(String, String) {
  let rest = string.trim(rest)

  // A line with only a weight has an empty reason.
  case string.split_once(rest, " ") {
    Ok(pair) -> pair
    Error(Nil) -> #(rest, "")
  }
}

/// The weight a word names, ignoring case and a closing `:` or `,`.
fn weight_of(word: String) -> Result(Weight, Refusal) {
  case string.lowercase(trim_end(word, [":", ","])) {
    "high" -> Ok(High)
    "normal" -> Ok(Normal)
    "low" -> Ok(Low)
    _ -> Error(BadWeight(word))
  }
}

/// The reason with its separator and spacing removed, cut to the head limit on
/// a grapheme boundary and ended with `…` when it was cut.
fn cut(why: String) -> String {
  let trimmed = string.trim(why) |> trim_start(["-", ":", "—"]) |> string.trim

  // Only a reason over the limit is cut, and the cut says so.
  case string.length(trimmed) > attention.head_limit {
    True -> string.slice(trimmed, 0, attention.head_limit - 1) <> "…"
    False -> trimmed
  }
}

/// A text without any of `marks` at its end.
fn trim_end(text: String, marks: List(String)) -> String {
  case list.find(marks, fn(mark) { string.ends_with(text, mark) }) {
    Ok(mark) -> trim_end(string.drop_end(text, string.length(mark)), marks)
    Error(Nil) -> text
  }
}

/// A text without any of `marks` at its start.
fn trim_start(text: String, marks: List(String)) -> String {
  case list.find(marks, fn(mark) { string.starts_with(text, mark) }) {
    Ok(mark) -> trim_start(string.drop_start(text, string.length(mark)), marks)
    Error(Nil) -> text
  }
}

/// Whether a text holds a control character: a code point below space, or
/// delete.
fn has_control(text: String) -> Bool {
  string.to_utf_codepoints(text)
  |> list.any(fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code < 32 || code == 127
  })
}

/// The labels in order, keeping only the first for each row.
fn first_of_each(labels: List(Label)) -> List(Label) {
  let #(kept, _) =
    list.fold(labels, #([], set.new()), fn(state, label) {
      let #(kept, seen) = state

      // A second line for a row already labelled changes nothing.
      case set.contains(seen, label.row) {
        True -> state
        False -> #([label, ..kept], set.insert(seen, label.row))
      }
    })

  list.reverse(kept)
}
