//// A rendered frame as plain text.
////
//// Etui hands a terminal a `Buffer`: a grid of styled cells that only a
//// terminal emulator can read back. Everything that inspects a frame
//// without one — a snapshot test, the `loom replay` command an agent runs
//// to see what the client would have drawn — needs the same grid as
//// characters. This module is that single conversion, so a golden file and
//// a replayed frame are compared on identical terms rather than on two
//// renderings that drifted.
////
//// Style is deliberately dropped. A text dump exists to answer "what does
//// this say and where", and colour would either bloat the answer with
//// escape sequences or reduce to an arbitrary encoding nobody reads. The
//// buffer is still the authority for colour; a test that cares about a
//// style asks the cell directly.

import etui/buffer.{type Buffer}
import etui/geometry.{Position}
import gleam/list
import gleam/string

/// One string per row of the buffer, top to bottom.
///
/// A wide grapheme occupies two cells: the glyph and a continuation marker
/// that is never drawn on its own. Emitting the continuation would widen
/// every CJK row by one space against the terminal that produced it, so the
/// marker is skipped and the glyph stands for both columns.
///
/// Trailing spaces are removed from each row. A frame paints its whole
/// rectangle, so almost every row would otherwise end in a run of blanks
/// that no reader wants and that editors and diff tools mangle.
///
/// ## Examples
///
/// ```gleam
/// let screen = geometry.rect_new(0, 0, 4, 2)
/// let buf = buffer.buffer_new(screen)
/// assert frame.buffer_to_lines(buf) == ["", ""]
/// ```
pub fn buffer_to_lines(buffer: Buffer) -> List(String) {
  let area = buffer.area(buffer)
  let top = area.position.y
  let left = area.position.x

  // Rows are built by index rather than by folding the cells, because the
  // buffer is addressed by absolute screen position: a frame drawn into an
  // inline viewport does not start at the origin.
  range_from(top, area.size.height)
  |> list.map(fn(y) { row_text(buffer, left, y, area.size.width) })
}

/// The whole frame as one newline-joined string, with no trailing newline.
///
/// This is what a golden file holds and what `loom replay` prints, so the
/// two cannot disagree about row separation.
///
/// ## Examples
///
/// ```gleam
/// let screen = geometry.rect_new(0, 0, 4, 2)
/// assert frame.buffer_to_text(buffer.buffer_new(screen)) == "\n"
/// ```
pub fn buffer_to_text(buffer: Buffer) -> String {
  buffer
  |> buffer_to_lines
  |> string.join("\n")
}

// The rows or columns an area covers: a count from a starting index, which
// is the shape a `Rect` gives us and the shape `list.range` does not.
fn range_from(start: Int, count: Int) -> List(Int) {
  range_down(start, count - 1, [])
}

// Built from the last index backwards so the accumulator comes out in order
// without a reverse.
fn range_down(start: Int, offset: Int, collected: List(Int)) -> List(Int) {
  case offset < 0 {
    True -> collected
    False -> range_down(start, offset - 1, [start + offset, ..collected])
  }
}

// One row, left to right, with continuation cells folded into the glyph
// that owns them and the trailing blank run removed.
fn row_text(buffer: Buffer, left: Int, y: Int, width: Int) -> String {
  range_from(left, width)
  |> list.fold("", fn(text, x) {
    let cell = buffer.get_cell(buffer, Position(x, y))
    case buffer.is_continuation(cell) {
      True -> text
      False -> text <> buffer.cell_symbol(cell)
    }
  })
  |> trim_trailing_spaces
}

// `string.trim_end` would also eat a trailing tab or newline, neither of
// which a cell can hold, so trimming spaces states exactly what is dropped.
fn trim_trailing_spaces(text: String) -> String {
  case string.ends_with(text, " ") {
    True -> trim_trailing_spaces(string.drop_end(text, 1))
    False -> text
  }
}
