//// Cuts a model's Markdown to a byte budget at a block boundary.
////
//// A quote of an agent's message is bounded, and the bound has to fall where
//// the reader still gets valid Markdown. A cut through the middle of a code
//// fence leaves the rest of the pane inside it, a cut through `**bold**`
//// leaves two literal asterisks, and a cut through a list item leaves half a
//// sentence. A block boundary, a blank line that is not inside a fence, is
//// the only place that never produces those, so this module cuts there: it keeps
//// whole blocks while they fit and ends with a paragraph holding an ellipsis
//// when it dropped any.
////
//// The one case with no boundary to use is a first block that is longer than
//// the budget by itself. That block is flattened to one line and cut at a word
//// by `core/glance.clip`, which marks the cut with its own ellipsis, so the
//// result is a plain paragraph with no marker the cut could have left open.
////
//// The module reads text and returns text. It draws nothing, and the Markdown
//// parse that follows is `session_view/markdown.parse`, which is total.
////
//// ## Flow
////
//// `clip` splits the text into blocks with `blocks`, keeps those that fit with
//// `fitting`, and falls back to `core/glance.clip` when none fits.

import core/glance
import gleam/list
import gleam/string

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

  // A text that fits is returned whole, and a text of several blocks is cut
  // between them. The first block alone being too long leaves nothing to keep.
  case string.byte_size(trimmed) <= max_bytes, blocks(trimmed) {
    True, _ -> trimmed
    False, blocks ->
      case fitting(blocks, max_bytes - ellipsis_bytes, []) {
        [] -> glance.clip(trimmed, max_bytes)
        kept -> string.join(list.reverse(kept), "\n\n") <> "\n\n…"
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

/// Whether the scan is inside a fenced code block.
type Fence {
  Open
  Closed
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
      let cost = case kept {
        [] -> string.byte_size(next)
        _ -> string.byte_size(next) + 2
      }

      case cost <= left {
        True -> fitting(rest, left - cost, [next, ..kept])
        False -> kept
      }
    }
  }
}
