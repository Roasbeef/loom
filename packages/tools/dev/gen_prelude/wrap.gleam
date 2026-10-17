//// Greedy line wrapping, with the same breaks as Python's `textwrap.wrap`.
////
//// The prelude generator wraps doc-comment prose before it is committed in
//// `tools/prelude`. The first generator was a Python script, and every line
//// break in that artifact came from `textwrap.wrap`. Reproducing those breaks
//// exactly keeps a port from rewriting the committed file, so this module
//// follows `textwrap`'s algorithm rather than inventing a simpler one. Two of
//// its behaviours are not obvious and are the reason this is not a ten-line
//// word splitter:
////
//// - A hyphenated word is a place to break. `read-only` may wrap after the
////   hyphen, but only where `textwrap`'s rule says the hyphen sits between
////   letters.
//// - A word longer than a whole line is cut, preferably after one of its
////   hyphens, instead of overflowing.
////
//// ## How work moves through this module
////
//// 1. `chunks` cuts the text into alternating runs of whitespace and word
////    pieces, using one regular expression ported from `textwrap`.
//// 2. `fill` builds lines. Each line takes chunks while they fit. A chunk
////    that cannot fit even on an empty line goes through `split_long_chunk`.
////    Whitespace trailing a line, or leading the next one, is dropped.
////
//// ## Two simplifications
////
//// Lengths count Unicode codepoints, as Python does, not graphemes. Tabs are
//// treated as one space rather than expanded to a tab stop, which is exact
//// for text that has no tabs. Doc-comment paragraphs have none.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp}
import gleam/string

/// Splits text into chunks, ported from `textwrap.TextWrapper.wordsep_re`.
///
/// A match is one of three things: a run of whitespace, a double hyphen
/// between words (an em dash typed as ASCII), or a word. A word ends at a
/// hyphen that sits between letters, at the next whitespace, or at the end of
/// the text. The lookbehinds are what limit a break after a hyphen to
/// `ab-cd` and `a-b-c`, and refuse it after `-x` or `1-2`.
///
/// Every character falls in exactly one of the alternatives, so the matches
/// tile the text and no separate pass is needed for the text between them.
const chunk_pattern =
  "[\\t\\n\\x0b\\x0c\\r ]+|(?<=[\\w!\"'&.,?])-{2,}(?=\\w)|[^\\t\\n\\x0b\\x0c\\r ]+?(?:-(?:(?<=[^\\d\\W]{2}-)|(?<=[^\\d\\W]-[^\\d\\W]-))(?=[^\\d\\W]-?[^\\d\\W])|(?=[\\t\\n\\x0b\\x0c\\r ]|\\z)|(?<=[\\w!\"'&.,?])(?=-{2,}\\w))"

/// Wraps text to lines of at most `width` codepoints.
///
/// Whitespace characters other than the space are first replaced by a space,
/// and a line never starts or ends with the whitespace at which it was
/// broken. A `width` below one is treated as one, so every call terminates.
///
/// ## Examples
///
/// ```gleam
/// assert wrap.wrap("one two three", 7) == ["one two", "three"]
/// ```
///
/// ```gleam
/// assert wrap.wrap("a read-only value", 10) == ["a read-", "only value"]
/// ```
pub fn wrap(text: String, width: Int) -> List(String) {
  text
  |> replace_whitespace
  |> chunks
  |> fill(int.max(width, 1), [])
}

/// Replaces tab, newline, vertical tab, form feed and carriage return with a
/// space, which is `textwrap`'s `replace_whitespace` step.
fn replace_whitespace(text: String) -> String {
  ["\t", "\n", "\u{b}", "\u{c}", "\r"]
  |> list.fold(text, fn(acc, character) { string.replace(acc, character, " ") })
}

/// The text cut into chunks by `chunk_pattern`.
///
/// The pattern is a constant, so failing to compile it is a bug in this
/// module and not a condition of any input. It is reported as a single chunk,
/// the whole text, which makes the output wrong but visible in the diff that
/// `make gen-prelude` produces.
fn chunks(text: String) -> List(String) {
  case regexp.from_string(chunk_pattern) {
    Ok(pattern) -> scan_chunks(pattern, text)
    Error(regexp.CompileError(..)) -> [text]
  }
}

/// Each match of the pattern, in order.
fn scan_chunks(pattern: Regexp, text: String) -> List(String) {
  pattern
  |> regexp.scan(text)
  |> list.map(fn(match) { match.content })
}

/// Builds lines from chunks until none remain.
///
/// `lines` holds the finished lines in reverse. Whitespace at the start of a
/// continuation line is dropped, because the break happened there. The first
/// line keeps whatever the text began with.
fn fill(chunks: List(String), width: Int, lines: List(String)) -> List(String) {
  case chunks {
    [] -> list.reverse(lines)

    [first, ..rest] ->
      case is_blank(first), lines {
        True, [_, ..] -> fill(rest, width, lines)
        True, [] -> next_line(chunks, width, lines)
        False, _ -> next_line(chunks, width, lines)
      }
  }
}

/// Takes one line off the front of the chunks and continues with the rest.
///
/// The line is complete when the next chunk does not fit. If that chunk would
/// not fit on a line of its own either, part of it fills the space that is
/// left. Trailing whitespace is trimmed last, so a line that ends exactly at
/// the width does not lose a character it did not need to.
fn next_line(
  chunks: List(String),
  width: Int,
  lines: List(String),
) -> List(String) {
  let #(taken, remaining) = take_fitting(chunks, width, [], 0)
  let #(taken, remaining) = cut_overlong_chunk(taken, remaining, width)
  let line = taken |> trim_trailing_blank |> list.reverse |> string.concat

  case line {
    "" -> fill(remaining, width, lines)
    _ -> fill(remaining, width, [line, ..lines])
  }
}

/// Moves chunks onto the line while their lengths sum to at most `width`.
///
/// The line is built in reverse, so the last chunk taken is first in the
/// list.
fn take_fitting(
  chunks: List(String),
  width: Int,
  taken: List(String),
  used: Int,
) -> #(List(String), List(String)) {
  case chunks {
    [chunk, ..rest] ->
      case used + length(chunk) <= width {
        True ->
          take_fitting(rest, width, [chunk, ..taken], used + length(chunk))
        False -> #(taken, chunks)
      }

    [] -> #(taken, [])
  }
}

/// If the next chunk is wider than any line, cuts the part that fits.
///
/// This is `textwrap`'s `_handle_long_word`. The chunk stays in the list with
/// its tail, so the rest wraps onto the following lines.
fn cut_overlong_chunk(
  taken: List(String),
  remaining: List(String),
  width: Int,
) -> #(List(String), List(String)) {
  case remaining {
    [chunk, ..rest] ->
      case length(chunk) > width {
        True -> {
          let space_left = int.max(width - used_width(taken), 1)
          let end = break_point(chunk, space_left)

          #([take(chunk, end), ..taken], [drop(chunk, end), ..rest])
        }
        False -> #(taken, remaining)
      }

    [] -> #(taken, remaining)
  }
}

/// How many codepoints of an overlong chunk go on the current line.
///
/// The chunk is known to be longer than `space_left`, since it is longer than
/// a whole line. The cut falls after the last hyphen that lies inside the
/// space left, provided at least one character other than a hyphen precedes
/// it, so that `--` and `-x` are never split. With no such hyphen the chunk is
/// cut where the space runs out.
fn break_point(chunk: String, space_left: Int) -> Int {
  case last_hyphen_before(chunk, space_left) {
    Some(hyphen) ->
      case hyphen > 0 && has_non_hyphen(take(chunk, hyphen)) {
        True -> hyphen + 1
        False -> space_left
      }

    None -> space_left
  }
}

/// The index of the last hyphen among the first `limit` codepoints.
fn last_hyphen_before(chunk: String, limit: Int) -> Option(Int) {
  chunk
  |> characters
  |> list.take(limit)
  |> list.index_fold(None, fn(found, character, index) {
    case character {
      "-" -> Some(index)
      _ -> found
    }
  })
}

/// Whether some character of the text is not a hyphen.
fn has_non_hyphen(text: String) -> Bool {
  text
  |> characters
  |> list.any(fn(character) { character != "-" })
}

/// Total length of the chunks on a line.
fn used_width(taken: List(String)) -> Int {
  taken
  |> list.map(length)
  |> int.sum
}

/// Drops a whitespace chunk from the end of a line.
///
/// The line is held in reverse, so the end of the line is the list's head.
fn trim_trailing_blank(taken: List(String)) -> List(String) {
  case taken {
    [last, ..rest] ->
      case is_blank(last) {
        True -> rest
        False -> taken
      }

    [] -> []
  }
}

/// Whether a chunk is only whitespace.
fn is_blank(chunk: String) -> Bool {
  string.trim(chunk) == ""
}

/// Length in codepoints.
fn length(text: String) -> Int {
  text |> string.to_utf_codepoints |> list.length
}

/// The text as one string per codepoint.
fn characters(text: String) -> List(String) {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) { string.from_utf_codepoints([codepoint]) })
}

/// The first `count` codepoints.
fn take(text: String, count: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> list.take(count)
  |> string.from_utf_codepoints
}

/// Everything after the first `count` codepoints.
fn drop(text: String, count: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> list.drop(count)
  |> string.from_utf_codepoints
}
