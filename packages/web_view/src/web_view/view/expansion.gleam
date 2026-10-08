//// How much of an expanded row the page draws.
////
//// A row the reader expands shows what the terminal's `Ctrl+g` shows: the
//// whole program, the whole result, the whole reasoning block. The page
//// already holds those records, so the server draws that text beside the
//// compact rows, in the same patch, and `<loom-expand>` (`web_client`) shows
//// one or the other. That makes the expanded text part of every viewer's
//// document whether or not anyone opens it, so it is bounded here. A tool's
//// output can run to megabytes, and the page holds up to 300 rows.
////
//// The bound is per expanded row: `max_lines` lines and `max_characters`
//// bytes of text, whichever comes first. A row that fits is drawn whole and
//// gets nothing added. A row that does not is cut where the budget ends and
//// is followed by one line that says so and says how much the page shows,
//// so a reader never mistakes a cut for the end of the output. The cut
//// text is the head of the row: a program's start, a result's first lines.
////
//// Nothing here reads the text for meaning. It counts newlines and bytes and
//// cuts, so it cannot make the text into anything but the text it was.

import gleam/int
import gleam/list
import gleam/string
import session_view/transcript_line.{type Line, Line}
import web_view/utf8_window

/// The most lines one expanded row draws.
pub const max_lines = 300

/// The most bytes of text one expanded row draws. The cut moves back to a
/// UTF-8 codepoint boundary, so it never splits a multi-byte character.
pub const max_characters = 8000

/// Whether a line of text was drawn whole.
type Clip {
  /// Every character of it is in the result.
  Whole

  /// The budget ended inside it, and the result stops there.
  Clipped
}

/// The lines an expanded row draws: `lines` up to the budget, then, when
/// anything was left out, one line that says so.
///
/// ## Examples
///
/// ```gleam
/// assert expansion.capped([]) == []
/// ```
pub fn capped(lines: List(Line)) -> List(Line) {
  case take(lines, max_lines, max_characters, []) {
    #(kept, Whole) -> kept
    #(kept, Clipped) ->
      list.append(kept, [Line(transcript_line.System, notice())])
  }
}

/// What the line after a cut row says. It is the same for every row, because
/// the budget is: its only numbers are the two constants above.
pub fn notice() -> String {
  "… cut here. The page draws at most "
  <> int.to_string(max_lines)
  <> " lines or "
  <> int.to_string(max_characters)
  <> " bytes of an expanded row. Tool results offer paged viewing and a full download."
}

// Takes lines while the budget lasts. `rows` and `chars` are what is left;
// the result is the lines kept, in order, and whether all of `lines` fit.
fn take(
  lines: List(Line),
  rows: Int,
  chars: Int,
  kept: List(Line),
) -> #(List(Line), Clip) {
  case lines {
    [] -> #(list.reverse(kept), Whole)
    [Line(speaker:, text:), ..rest] ->
      case rows > 0 && chars > 0 {
        False -> #(list.reverse(kept), Clipped)
        True -> {
          let #(text, spanned, clip) = clipped(text, rows, chars)
          let kept = [Line(speaker:, text:), ..kept]
          case clip {
            Clipped -> #(list.reverse(kept), Clipped)
            Whole ->
              take(rest, rows - spanned, chars - string.byte_size(text), kept)
          }
        }
      }
  }
}

// One line's text cut to `rows` lines and `chars` bytes, with the number of
// lines the result spans. The byte check comes first and cuts by codepoints,
// so the split that counts newlines never sees more than the budget however
// long the text is.
fn clipped(text: String, rows: Int, chars: Int) -> #(String, Int, Clip) {
  let #(text, by_size) = case string.byte_size(text) > chars {
    True -> #(utf8_window.prefix(text, chars), Clipped)
    False -> #(text, Whole)
  }
  let rows_of = string.split(text, "\n")
  let spanned = list.length(rows_of)
  case spanned > rows, by_size {
    True, _ -> #(string.join(list.take(rows_of, rows), "\n"), rows, Clipped)
    False, size -> #(text, spanned, size)
  }
}
