//// Mouse selection over a rendered frame, and the clipboard write it ends in.
////
//// The client enables mouse tracking so the wheel can scroll the transcript,
//// and a terminal that reports the mouse to an application stops selecting
//// text for it: every drag arrives here as events instead of becoming a
//// highlight the terminal owns. Copying anything out of Loom therefore has
//// to be the client's own work. This module is that work, kept pure: a
//// `Selection` is two cell positions inside one screen area, the text it
//// covers is read back from the frame the terminal is showing, and the
//// clipboard write is an escape sequence the caller decides whether to emit.
////
//// ## Why the selection is clipped to an area
////
//// A terminal selects in reading order across the whole screen, which is
//// right for a shell and wrong for a framed layout: the middle rows of a
//// three-row selection in the transcript would carry the panel's border
//// glyphs and the agent rail beside it. The press therefore names the area
//// it landed in — the transcript, the rail, the prompt — and the selection
//// reads and highlights in that area's columns only, so what lands on the
//// clipboard is the prose and not the furniture around it.
////
//// ## Why the text comes from the frame
////
//// The frame is the one thing the operator and the client agree on. Reading
//// the selected rows back from the `Buffer` on screen copies exactly what
//// was highlighted, wrapped as it was drawn, with no second rendering path
//// that could disagree with the first. `tui/frame` already folds a wide
//// glyph's continuation cell into the glyph and trims the trailing blanks a
//// full-rectangle paint leaves, so a row copied here is a row of the golden
//// file, and the two cannot drift.

import etui/buffer.{type Buffer}
import etui/geometry.{type Position, type Rect, Position}
import etui/style
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import tui/frame

/// A selection in progress or settled: where the button went down, where
/// the pointer is now, and the area both are held to.
pub type Selection {
  Selection(
    /// The screen area the press landed in. Every row of the selection is
    /// clipped to its columns, and `extend` clamps the head into it.
    area: Rect,
    /// Where the button went down. Fixed for the life of the selection.
    anchor: Position,
    /// Where the pointer is, or was when the button came up. May precede
    /// the anchor in reading order; `bounds` sorts the two.
    head: Position,
  )
}

/// Begins a selection at the cell the button went down on.
///
/// ## Examples
///
/// ```gleam
/// let area = geometry.rect_new(1, 1, 40, 10)
/// let sel = selection.start(area, Position(5, 3))
/// assert sel.anchor == sel.head
/// ```
pub fn start(area: Rect, at: Position) -> Selection {
  let anchor = clamp(area, at)
  Selection(area:, anchor:, head: anchor)
}

/// Moves the head to where the pointer is, clamped into the area.
///
/// Clamping rather than ignoring an outside position is what lets a drag
/// that overshoots the panel's edge select to the edge, which is how every
/// terminal and editor behaves and what a hand expects.
///
/// ## Examples
///
/// ```gleam
/// let area = geometry.rect_new(0, 0, 10, 4)
/// let sel = selection.start(area, Position(2, 1))
/// assert selection.extend(sel, Position(30, 9)).head == Position(9, 3)
/// ```
pub fn extend(selection: Selection, to: Position) -> Selection {
  Selection(..selection, head: clamp(selection.area, to))
}

/// Reports whether the button came up where it went down.
///
/// A click selects nothing; it is how a settled highlight is dismissed.
///
/// ## Examples
///
/// ```gleam
/// let sel = selection.start(geometry.rect_new(0, 0, 10, 4), Position(2, 1))
/// assert selection.is_click(sel)
/// ```
pub fn is_click(selection: Selection) -> Bool {
  selection.anchor == selection.head
}

/// The rows the selection covers, one single-row rectangle each, in order.
///
/// Reading order inside the area: the first row runs from the earlier
/// endpoint to the area's right edge, the last row from the area's left
/// edge to the later endpoint inclusive, and every row between spans the
/// area. A single-row selection is both first and last.
///
/// ## Examples
///
/// ```gleam
/// let area = geometry.rect_new(0, 0, 10, 4)
/// let sel =
///   selection.start(area, Position(7, 2))
///   |> selection.extend(Position(2, 1))
/// assert selection.rows(sel)
///   == [geometry.rect_new(2, 1, 8, 1), geometry.rect_new(0, 2, 8, 1)]
/// ```
pub fn rows(selection: Selection) -> List(Rect) {
  let #(first, last) = bounds(selection)
  let area = selection.area
  int.range(first.y, last.y + 1, [], fn(rows, y) { [y, ..rows] })
  |> list.reverse
  |> list.map(fn(y) {
    let left = case y == first.y {
      True -> first.x
      False -> area.position.x
    }
    let right = case y == last.y {
      True -> last.x + 1
      False -> geometry.right(area)
    }
    geometry.rect_new(left, y, right - left, 1)
  })
}

/// The selected text as the frame shows it, one line per selected row.
///
/// Each row is trimmed of the trailing blanks the paint leaves, and rows
/// are joined with newlines and no trailing newline, so a one-row
/// selection pastes inline and a multi-row one pastes as lines.
///
/// ## Examples
///
/// ```gleam
/// let text = selection.text(frame_on_screen, sel)
/// ```
pub fn text(buffer: Buffer, selection: Selection) -> String {
  rows(selection)
  |> list.map(fn(row) {
    frame.row_text(buffer, row.position.x, row.position.y, row.size.width)
  })
  |> string.join("\n")
}

/// Draws the selection over a frame by reversing every covered cell.
///
/// The reverse modifier is added to each cell's own style rather than the
/// cell being restyled wholesale, so a highlighted heading is still bold
/// and a highlighted tool row still carries its colour, inverted. That is
/// what a terminal's own highlight looks like, which is what a hand that
/// just dragged expects to see.
///
/// ## Examples
///
/// ```gleam
/// let shown = selection.highlight(frame, sel)
/// ```
pub fn highlight(buffer: Buffer, selection: Selection) -> Buffer {
  rows(selection)
  |> list.fold(buffer, fn(buffer, row) {
    int.range(row.position.x, geometry.right(row), buffer, fn(buffer, x) {
      let at = Position(x, row.position.y)
      let cell = buffer.get_cell(buffer, at)
      buffer.set_cell(
        buffer,
        at,
        buffer.Cell(
          ..cell,
          style: style.add_modifier(cell.style, style.reverse()),
        ),
      )
    })
  })
}

/// The OSC 52 sequence that places text on the terminal's clipboard.
///
/// `c` names the system clipboard selection, and the payload is base64 so
/// no byte of the text can be read as a terminal instruction on the way.
/// Whether the terminal honours it is the terminal's policy: Herdr, kitty,
/// WezTerm, Ghostty and Alacritty do by default; iTerm2 behind a
/// preference; Terminal.app not at all. The client cannot tell, so the
/// notice it shows says what was sent rather than promising it arrived.
///
/// ## Examples
///
/// ```gleam
/// assert selection.clipboard_sequence("hi")
///   == "\u{001B}]52;c;aGk=\u{001B}\\"
/// ```
pub fn clipboard_sequence(text: String) -> String {
  "\u{001B}]52;c;"
  <> bit_array.base64_encode(bit_array.from_string(text), True)
  <> "\u{001B}\\"
}

/// A notice naming how much was copied.
///
/// ## Examples
///
/// ```gleam
/// assert selection.copied_notice(1) == "copied 1 line"
/// assert selection.copied_notice(3) == "copied 3 lines"
/// ```
pub fn copied_notice(lines: Int) -> String {
  case lines {
    1 -> "copied 1 line"
    n -> "copied " <> int.to_string(n) <> " lines"
  }
}

// The two endpoints in reading order: by row first, then by column.
fn bounds(selection: Selection) -> #(Position, Position) {
  let Selection(anchor:, head:, ..) = selection
  case anchor.y < head.y || { anchor.y == head.y && anchor.x <= head.x } {
    True -> #(anchor, head)
    False -> #(head, anchor)
  }
}

// The nearest cell inside the area. An empty area has no inside, and a
// press cannot land in one, so the degenerate case only has to be total.
fn clamp(area: Rect, at: Position) -> Position {
  Position(
    int.clamp(
      at.x,
      area.position.x,
      int.max(area.position.x, geometry.right(area) - 1),
    ),
    int.clamp(
      at.y,
      area.position.y,
      int.max(area.position.y, geometry.bottom(area) - 1),
    ),
  )
}
