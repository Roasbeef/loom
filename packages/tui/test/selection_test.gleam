import etui/buffer
import etui/geometry.{Position}
import etui/style
import gleam/list
import gleam/string
import tui/frame
import tui/selection

// A 12x4 screen whose text sits inside a one-cell frame, the way the
// transcript sits inside its border, so the clipping to an area shows.
fn framed() -> #(buffer.Buffer, geometry.Rect) {
  let screen = geometry.rect_new(0, 0, 12, 4)
  let plain = style.default_style()
  let buf =
    buffer.buffer_new(screen)
    |> buffer.set_string(Position(0, 1), "|alpha bet |", plain)
    |> buffer.set_string(Position(0, 2), "|gamma     |", plain)
  #(buf, geometry.rect_new(1, 1, 10, 2))
}

pub fn a_drag_selects_in_reading_order_within_its_area_test() {
  let #(buf, area) = framed()
  let sel =
    selection.start(area, Position(3, 1))
    |> selection.extend(Position(5, 2))
  assert selection.rows(sel)
    == [geometry.rect_new(3, 1, 8, 1), geometry.rect_new(1, 2, 5, 1)]

  // The first row runs to the area's edge and stops short of the border;
  // the second starts at the area's left edge, not the screen's.
  assert selection.text(buf, sel) == "pha bet\ngamma"
}

pub fn a_backwards_drag_reads_the_same_as_a_forwards_one_test() {
  let #(buf, area) = framed()
  let forwards =
    selection.start(area, Position(3, 1))
    |> selection.extend(Position(5, 2))
  let backwards =
    selection.start(area, Position(5, 2))
    |> selection.extend(Position(3, 1))
  assert selection.text(buf, forwards) == selection.text(buf, backwards)
  assert selection.rows(forwards) == selection.rows(backwards)
}

pub fn a_drag_past_the_area_edge_selects_to_the_edge_test() {
  let #(buf, area) = framed()
  let sel =
    selection.start(area, Position(1, 1))
    |> selection.extend(Position(40, 9))
  assert sel.head == Position(10, 2)
  assert selection.text(buf, sel) == "alpha bet\ngamma"
}

pub fn a_click_is_not_a_selection_test() {
  let #(_, area) = framed()
  let sel = selection.start(area, Position(4, 1))
  assert selection.is_click(sel)
  assert !selection.is_click(selection.extend(sel, Position(5, 1)))
}

pub fn a_highlight_reverses_only_the_selected_cells_test() {
  let #(buf, area) = framed()
  let sel =
    selection.start(area, Position(3, 1))
    |> selection.extend(Position(4, 1))
  let shown = selection.highlight(buf, sel)
  let reversed = fn(x, y) {
    style.has(
      buffer.cell_modifier(buffer.get_cell(shown, Position(x, y))),
      style.reverse(),
    )
  }
  assert reversed(3, 1)
  assert reversed(4, 1)
  assert !reversed(2, 1)
  assert !reversed(5, 1)
  assert !reversed(3, 2)

  // Content is untouched: the highlight is a style, and the text read back
  // from a highlighted frame is the same text.
  assert frame.buffer_to_lines(shown) == frame.buffer_to_lines(buf)
}

pub fn a_selected_wide_glyph_copies_once_test() {
  let screen = geometry.rect_new(0, 0, 6, 1)
  let buf =
    buffer.set_string(
      buffer.buffer_new(screen),
      Position(0, 0),
      "\u{4F60}\u{597D}ok",
      style.default_style(),
    )
  let sel =
    selection.start(screen, Position(0, 0))
    |> selection.extend(Position(5, 0))
  assert selection.text(buf, sel) == "\u{4F60}\u{597D}ok"
}

pub fn the_clipboard_write_is_osc_52_over_base64_test() {
  assert selection.clipboard_sequence("hi") == "\u{001B}]52;c;aGk=\u{001B}\\"

  // Nothing of the text survives unencoded, so a copied escape sequence
  // cannot be replayed by the terminal on the way to the clipboard.
  let hostile = "\u{001B}[2J\n\u{0007}"
  let sent = selection.clipboard_sequence(hostile)
  assert list.all(["\u{001B}[", "\n", "\u{0007}"], fn(bytes) {
    !string.contains(sent, bytes)
  })
}

pub fn the_copied_notice_counts_lines_test() {
  assert selection.copied_notice(1) == "copied 1 line"
  assert selection.copied_notice(4) == "copied 4 lines"
}
