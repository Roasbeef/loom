//// Cuts a model's Markdown to a byte budget, between blocks where it can.
////
//// A quote of an agent's message is bounded, and the bound should fall where
//// the reader still gets valid Markdown. A cut through a code fence leaves the
//// rest of the pane inside it, a cut through `**bold**` leaves two literal
//// asterisks, and a cut through a list item leaves half a sentence. A block
//// boundary, a blank line outside a code fence, avoids those, so the cut is
//// made there: whole blocks are kept while they fit, and a cut ends in a
//// paragraph holding an ellipsis.
////
//// A first block that is longer than the budget has no boundary before it, so
//// it is cut between its lines instead. A block that opens with a fence keeps
//// whole lines of its code and a closing fence, so the code box is never
//// empty and never left open. Any other block keeps whole lines, which for a
//// list means whole items. A block of one line longer than the budget is
//// flattened and cut at a word by `core/glance.clip`, which ends in its own
//// ellipsis.
////
//// What the cut does not guarantee: the fence scan treats any line that starts
//// with three backticks or three tildes as a fence marker that flips a single
//// open or closed state, so a fence closed by a different marker than it opened
//// with can end a block early. The Markdown parse that follows is total, so the
//// worst outcome is a block drawn as text, never a failure.
////
//// The module reads text and returns text. It draws nothing.
////
//// ## Flow
////
//// `clip` returns a text that fits as it is. Otherwise it splits the text with
//// `blocks`, keeps leading blocks with `fitting`, and when none fits cuts the
//// first block with `first_block`.

import core/glance
import gleam/list
import gleam/string

/// Whether the scan is inside a fenced code block.
type Fence {
  Open
  Closed
}

/// The text cut to at most `max_bytes` bytes of whole blocks, newlines kept, and
/// the text unchanged when it fits. Text with a dropped block ends in a
/// paragraph holding `…`.
///
/// ## Examples
///
/// ```gleam
/// assert block_clip.clip("one\n\ntwo", 100) == "one\n\ntwo"
/// assert block_clip.clip("one\n\ntwo", 5) == "one\n\n…"
/// ```
pub fn clip(text: String, max_bytes: Int) -> String {
  let trimmed = string.trim(text)

  // A text that fits is returned whole and is not split into blocks.
  case string.byte_size(trimmed) <= max_bytes {
    True -> trimmed
    False -> cut(blocks(trimmed), max_bytes)
  }
}

/// The leading blocks that fit with the ellipsis after them, or a cut of the
/// first block when not even one fits.
fn cut(blocks: List(String), max_bytes: Int) -> String {
  // Blocks are kept between boundaries first, and only a first block that is
  // too long by itself is cut inside.
  case fitting(blocks, max_bytes - ellipsis_bytes, []), blocks {
    [], [first, ..] -> first_block(first, max_bytes)
    [], [] -> ""
    kept, _ -> string.join(list.reverse(kept), "\n\n") <> "\n\n…"
  }
}

/// The first block cut between its lines to at most `max_bytes` bytes. A block
/// that opens with a fence keeps its opening line, whole lines of code and a
/// closing marker, and is just the ellipsis when no line of code fits. Any other
/// block keeps whole lines, and a single line that does not fit is flattened and
/// cut at a word.
fn first_block(block: String, max_bytes: Int) -> String {
  let lines = string.split(block, "\n")

  // A fenced block closes with the marker it opened with, which costs a newline
  // and three bytes after its code.
  case lines {
    [opener, ..code] ->
      case fence_marker(opener) {
        Ok(marker) ->
          fenced(opener, marker, code, max_bytes - ellipsis_bytes - 4)
        Error(Nil) ->
          case whole_lines(lines, max_bytes - ellipsis_bytes, []) {
            [] -> glance.clip(block, max_bytes)
            kept -> string.join(list.reverse(kept), "\n") <> "\n\n…"
          }
      }
    [] -> ""
  }
}

/// A cut fence: its opening line, the lines of code that fit in `left` bytes
/// after it, a closing marker and the ellipsis paragraph.
fn fenced(
  opener: String,
  marker: String,
  code: List(String),
  left: Int,
) -> String {
  // The code lines are taken against what is left once the opener is paid for.
  case whole_lines(code, left - string.byte_size(opener) - 1, []) {
    [] -> "…"
    kept ->
      opener
      <> "\n"
      <> string.join(list.reverse(kept), "\n")
      <> "\n"
      <> marker
      <> "\n\n…"
  }
}

/// The marker a line opens a fence with, or nothing when it does not open one.
fn fence_marker(line: String) -> Result(String, Nil) {
  let start = string.trim_start(line)

  // Either marker is three characters of one kind.
  case string.starts_with(start, "```"), string.starts_with(start, "~~~") {
    True, _ -> Ok("```")
    False, True -> Ok("~~~")
    False, False -> Error(Nil)
  }
}

/// The leading lines, newest first, whose joined size is within `left` bytes. A
/// later line that fits never jumps over an earlier one that does not.
fn whole_lines(
  lines: List(String),
  left: Int,
  kept: List(String),
) -> List(String) {
  // A line costs its bytes, and a newline too when it is not the first.
  case lines {
    [] -> kept
    [next, ..rest] -> {
      let cost = case kept {
        [] -> string.byte_size(next)
        [_, ..] -> string.byte_size(next) + 1
      }

      // The scan ends at the first line that does not fit.
      case cost <= left {
        True -> whole_lines(rest, left - cost, [next, ..kept])
        False -> kept
      }
    }
  }
}

/// The bytes the closing `\n\n…` costs: two newlines and the three-byte
/// ellipsis.
const ellipsis_bytes = 5

/// The blocks of a text, each with its lines joined by newlines. A blank line
/// ends a block unless a fence is open, so a code block with blank lines in it
/// stays one block.
fn blocks(text: String) -> List(String) {
  let #(done, current, _) =
    list.fold(string.split(text, "\n"), #([], [], Closed), step)

  list.reverse(close(done, current))
}

/// One line against the scan: a fence line flips the fence, a blank line outside
/// a fence ends the block, and any other line joins the current block.
fn step(
  state: #(List(String), List(String), Fence),
  line: String,
) -> #(List(String), List(String), Fence) {
  let #(done, current, fence) = state
  let marker = string.trim_start(line)
  let is_fence =
    string.starts_with(marker, "```") || string.starts_with(marker, "~~~")

  // A fence marker joins the block and flips the fence. Inside a fence every
  // line joins. Outside one, a blank line ends the block.
  case is_fence, fence {
    True, Closed -> #(done, [line, ..current], Open)
    True, Open -> #(done, [line, ..current], Closed)
    False, Open -> #(done, [line, ..current], Open)
    False, Closed ->
      // A blank line is the boundary the cut is allowed to use.
      case string.trim(line) == "" {
        True -> #(close(done, current), [], Closed)
        False -> #(done, [line, ..current], Closed)
      }
  }
}

/// The finished blocks with the current one added, when it has any lines.
fn close(done: List(String), current: List(String)) -> List(String) {
  case current {
    [] -> done
    _ -> [string.join(list.reverse(current), "\n"), ..done]
  }
}

/// The leading blocks, newest first, whose joined size is within `left` bytes.
fn fitting(
  blocks: List(String),
  left: Int,
  kept: List(String),
) -> List(String) {
  // A block is kept while its bytes, and the two newlines before it when it is
  // not the first, still fit.
  case blocks {
    [] -> kept
    [next, ..rest] -> {
      // The first block costs its own bytes, and a later one also the blank
      // line that separates it from the block before.
      let cost = case kept {
        [] -> string.byte_size(next)
        [_, ..] -> string.byte_size(next) + 2
      }

      // The block is kept when it fits, and the first one that does not ends
      // the scan, so a later short block never jumps over it.
      case cost <= left {
        True -> fitting(rest, left - cost, [next, ..kept])
        False -> kept
      }
    }
  }
}
