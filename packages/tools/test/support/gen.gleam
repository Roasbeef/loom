//// qcheck generators for the hashline property suite: lines and whole-file
//// contents with the shapes that stress line anchoring.
////
//// Fragments are drawn by index, so shrinking moves a line toward the
//// first fragment and toward fewer of them, and a file toward fewer, emptier
//// lines. A failing file is therefore reported as a handful of short plain
//// lines rather than a wall of CJK and emoji, with the shape that matters
//// (a blank run, a duplicated line, a missing final newline) kept only when
//// the failure needs it.

import gleam/list
import gleam/string
import qcheck

// Deliberately varied: ascii words, punctuation, accents, CJK, emoji,
// combining marks, and a carriage return for CRLF shapes. The plainest
// fragment comes first because shrinking moves toward index zero.
const fragments = [
  "let", "case", "fn", "->", "  ", "responder", "münchen", "søster", "日本語", "🦀",
  "e\u{0301}", "\r", "\"quoted\"", "0123456789", "___", "x = y + z",
]

/// One line of content: zero to four fragments concatenated, never
/// containing `\n`. Shrinks toward the empty line.
pub fn line() -> qcheck.Generator(String) {
  let fragment =
    qcheck.bounded_int(from: 0, to: list.length(fragments) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(fragments, index) {
        [chosen, ..] -> chosen
        [] -> ""
      }
    })
  qcheck.generic_list(
    elements_from: fragment,
    length_from: qcheck.bounded_int(from: 0, to: 4),
  )
  |> qcheck.map(string.concat)
}

/// Whole-file content of `min_lines` to `max_lines` lines, with or without
/// a trailing newline. Shrinks toward fewer lines and no trailing newline.
pub fn content(
  min_lines min_lines: Int,
  max_lines max_lines: Int,
) -> qcheck.Generator(String) {
  let lines =
    qcheck.generic_list(
      elements_from: line(),
      length_from: qcheck.bounded_int(from: min_lines, to: max_lines),
    )
  qcheck.map2(lines, trailing_newline(), join_content)
}

/// Whole-file content biased toward duplicate and blank lines: every line
/// comes from a pool of the empty line plus two drawn lines, so identical
/// siblings and blank runs are the norm — the shapes that defeat per-line
/// anchor checks. Shrinks toward blank lines.
pub fn duplicate_heavy_content(
  min_lines min_lines: Int,
  max_lines max_lines: Int,
) -> qcheck.Generator(String) {
  let picks =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 2),
      length_from: qcheck.bounded_int(from: min_lines, to: max_lines),
    )
  qcheck.map4(line(), line(), picks, trailing_newline(), fn(a, b, picks, tail) {
    let pool = ["", a, b]
    let lines =
      list.map(picks, fn(pick) {
        case list.drop(pool, pick) {
          [chosen, ..] -> chosen
          [] -> ""
        }
      })
    join_content(lines, tail)
  })
}

/// Content from either shape above, an even split. Shrinks toward the
/// plain shape.
pub fn either_content(
  min_lines min_lines: Int,
  max_lines max_lines: Int,
) -> qcheck.Generator(String) {
  qcheck.from_generators(content(min_lines:, max_lines:), [
    duplicate_heavy_content(min_lines:, max_lines:),
  ])
}

/// An unbounded-looking choice from `0` to `1000`, for the caller to wrap
/// into whatever range the generated value turns out to need (see `wrap`),
/// since a position cannot be drawn before the file it indexes exists.
/// Shrinks toward zero, which callers arrange to be the first line or the
/// plainest alternative.
pub fn pick() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 1000)
}

/// Wraps `pick` into `0..count - 1`; an empty range yields zero.
pub fn wrap(pick: Int, count: Int) -> Int {
  case count < 1 {
    True -> 0
    False -> pick % count
  }
}

// Whether the file ends in a newline, as a named pair of cases so the
// generators above do not thread a `Bool`.
type Ending {
  Unterminated
  Terminated
}

fn trailing_newline() -> qcheck.Generator(Ending) {
  qcheck.bounded_int(from: 0, to: 1)
  |> qcheck.map(fn(n) {
    case n {
      0 -> Unterminated
      _ -> Terminated
    }
  })
}

// Joins generated lines into a file. A file whose last line is empty and
// unterminated cannot exist: its text ends in `\n`, so `split_lines` reads
// that newline as a terminator and finds one line fewer than was drawn
// ("a", "" joins to "a\n", which is the one line "a"). Such a last line is
// written as "end" instead, so the line count a property asks for is the
// line count the file splits into rather than a number that only holds on
// the draws that happened to avoid the collision.
fn join_content(lines: List(String), ending: Ending) -> String {
  let lines = case ending, list.reverse(lines) {
    Unterminated, ["", ..before] -> list.reverse(["end", ..before])
    _, _ -> lines
  }
  let joined = string.join(lines, with: "\n")
  case ending, joined {
    Terminated, "" -> joined
    Terminated, _ -> joined <> "\n"
    Unterminated, _ -> joined
  }
}
