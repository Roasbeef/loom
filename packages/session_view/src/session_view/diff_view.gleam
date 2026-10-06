//// A unified diff read into lines a host can colour: what each line is, and
//// for a hunk's lines the line number it has in the old and the new file.
////
//// The page draws every diff it holds the same way (the opened edit step in
//// the transcript, the Changes tab), and a terminal that coloured its diffs
//// would want the same reading, so the parser is here and takes no side. It
//// reads a diff as text and decides one thing per line: its `Kind`, a closed
//// type, from the line's first characters. A host chooses a style from the
//// kind and never from the text. The text is session text, a file's own
//// lines, and is meant to be drawn as a text node.
////
//// A diff is either whole (`diff --git`, `index`, `---`, `+++`, then hunks) or
//// the headerless hunks an edit result reports (`changes_view`). Header lines
//// are told apart only before the first hunk, so an added line that begins
//// `++` inside a hunk is an added line. A line that begins `\` is git's `\ No
//// newline at end of file` marker. A carriage return before a line's end, as
//// a CRLF diff has, is not part of the line.
////
//// Everything is bounded. `parse` keeps at most `max_lines` lines and counts
//// the rest, so a host can say how many it left out, and a line's text is not
//// cut here: the host's box scrolls it.
////
//// The module is portable: it imports the standard library only and performs
//// no I/O.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The most lines `parse` keeps. A longer diff is cut there and the rest are
/// counted in `Diff.cut`.
pub const max_lines = 400

/// What a line of a diff is.
pub type Kind {
  /// A line before the first hunk that names the files: `diff --git`,
  /// `index`, `---` or `+++`.
  FileHeader

  /// A hunk header, `@@ -9,6 +9,12 @@`.
  Hunk

  /// A line the change added.
  Added

  /// A line the change removed.
  Removed

  /// An unchanged line shown for context.
  Context

  /// git's `\ No newline at end of file` note.
  NoNewline
}

/// One line of a diff.
pub type Line {
  Line(
    /// What the line is, which decides its style.
    kind: Kind,
    /// The line's number in the old file, for a removed or context line when
    /// a hunk header gave the counters.
    old: Option(Int),
    /// The line's number in the new file, for an added or context line when a
    /// hunk header gave the counters.
    new: Option(Int),
    /// The line's text. For an added, removed or context line it is the line
    /// without its leading `+`, `-` or space; for the others it is the whole
    /// line. Session text.
    text: String,
  )
}

/// A diff read, and how much of it was left out.
pub type Diff {
  Diff(
    /// The lines kept, in order.
    lines: List(Line),
    /// How many lines past `max_lines` were left out.
    cut: Int,
  )
}

/// Reads a whole diff, keeping at most `max_lines` of its lines.
///
/// ## Examples
///
/// ```gleam
/// assert diff_view.parse("@@ -1 +1 @@\n-a\n+b").cut == 0
/// ```
pub fn parse(diff: String) -> Diff {
  let all = without_final_blank(string.split(diff, "\n"))
  let kept = list.take(all, max_lines)
  Diff(lines: of_lines(kept), cut: int.max(0, list.length(all) - max_lines))
}

/// Reads diff lines already split, as a host that bounds them itself holds
/// them. Every line is read; nothing is cut, except the empty string a
/// trailing newline leaves at the end, which is not a line.
///
/// ## Examples
///
/// ```gleam
/// assert diff_view.of_lines(["@@ -4,2 +4,2 @@", "-a", "+b"])
///   == [
///     diff_view.Line(diff_view.Hunk, None, None, "@@ -4,2 +4,2 @@"),
///     diff_view.Line(diff_view.Removed, Some(4), None, "a"),
///     diff_view.Line(diff_view.Added, None, Some(4), "b"),
///   ]
/// ```
pub fn of_lines(lines: List(String)) -> List(Line) {
  list.fold(without_final_blank(lines), #([], Before), fn(acc, raw) {
    let #(out, place) = acc
    let #(line, next) = read(strip_return(raw), place)
    #([line, ..out], next)
  })
  |> fn(done) { list.reverse(done.0) }
}

// A diff that ends in a newline splits into a final empty string, which is
// the end of the text and not a line of it: a context line is never empty in
// git's format, it is a single space. Left in, it would draw as an empty
// context row with line numbers.
fn without_final_blank(lines: List(String)) -> List(String) {
  case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
}

// Where the reader is in the diff: before any hunk, or inside one with the
// next old and new line numbers, which are unknown when the header gave none.
type Place {
  Before
  Inside(old: Option(Int), new: Option(Int))
}

fn read(line: String, place: Place) -> #(Line, Place) {
  case line, place {
    "@@" <> _, _ -> {
      let #(old, new) = counters(line)
      #(Line(Hunk, None, None, line), Inside(old, new))
    }
    "\\" <> _, _ -> #(Line(NoNewline, None, None, line), place)
    _, Before ->
      case header(line) {
        True -> #(Line(FileHeader, None, None, line), Before)
        False -> #(Line(Context, None, None, line), Before)
      }
    "+" <> text, Inside(old:, new:) -> #(
      Line(Added, None, new, text),
      Inside(old, step(new)),
    )
    "-" <> text, Inside(old:, new:) -> #(
      Line(Removed, old, None, text),
      Inside(step(old), new),
    )
    " " <> text, Inside(old:, new:) -> #(
      Line(Context, old, new, text),
      Inside(step(old), step(new)),
    )
    _, Inside(old:, new:) -> #(
      Line(Context, old, new, line),
      Inside(step(old), step(new)),
    )
  }
}

fn step(number: Option(Int)) -> Option(Int) {
  option.map(number, fn(n) { n + 1 })
}

fn header(line: String) -> Bool {
  string.starts_with(line, "diff ")
  || string.starts_with(line, "index ")
  || string.starts_with(line, "--- ")
  || string.starts_with(line, "+++ ")
}

fn strip_return(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

// The first old and new line numbers a hunk header gives, `@@ -9,6 +9,12 @@`,
// or nothing for either that is missing or not a number.
fn counters(header: String) -> #(Option(Int), Option(Int)) {
  let words = string.split(header, " ")
  #(
    list.find_map(words, number_after(_, "-")) |> option.from_result,
    list.find_map(words, number_after(_, "+")) |> option.from_result,
  )
}

fn number_after(word: String, sign: String) -> Result(Int, Nil) {
  case string.starts_with(word, sign), string.length(word) > 1 {
    True, True -> {
      let digits = string.drop_start(word, 1)
      let first = case string.split_once(digits, ",") {
        Ok(#(before, _)) -> before
        Error(Nil) -> digits
      }
      int.parse(first)
    }
    _, _ -> Error(Nil)
  }
}

/// Which of `Some` or `None` a gutter shows: the number as text, or nothing.
///
/// ## Examples
///
/// ```gleam
/// assert diff_view.number_text(Some(7)) == "7"
/// assert diff_view.number_text(None) == ""
/// ```
pub fn number_text(number: Option(Int)) -> String {
  case number {
    Some(n) -> int.to_string(n)
    None -> ""
  }
}
