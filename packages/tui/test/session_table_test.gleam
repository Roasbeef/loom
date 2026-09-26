import etui/buffer
import etui/geometry.{Position}
import etui/style
import gleam/list
import gleam/string
import tui/daemon/protocol as control_protocol
import tui/frame
import tui/session_table
import tui/theme

fn session(id: String, status: control_protocol.Lifecycle, name: String) {
  control_protocol.Session(
    session_id: id,
    workspace: "/w",
    name:,
    created_at: 0,
    status:,
  )
}

// The columns line up on the widest cell, a CJK name counted as two cells
// per glyph, and the plain rendering of the same buffer reads as a table.
pub fn render_aligns_columns_by_cell_width_test() {
  let drawn =
    session_table.render([
      session("s-1", control_protocol.Resident("i"), "漢字"),
      session("s-long-id", control_protocol.Saved, "plain"),
    ])

  assert frame.buffer_to_lines(drawn)
    == [
      "SESSION    STATE     WORKSPACE  NAME",
      "s-1        resident  /w         漢字",
      "s-long-id  saved     /w         plain",
    ]
}

// The lifecycle carries its colour into the cell, and the styled print
// closes a style the line leaves open, so the bold header stops at its end
// while a row ending in plain text needs no reset.
pub fn styled_rows_colour_state_and_reset_test() {
  let drawn =
    session_table.render([
      session("s-1", control_protocol.RecoveryBlocked, "n"),
    ])

  // The state column starts after the header's seven cells and the gutter.
  let cell = buffer.get_cell(drawn, Position(x: 9, y: 1))
  assert buffer.cell_symbol(cell) == "b"
  assert buffer.cell_fg(cell) == theme.danger_text().fg

  let assert [header, row] = string.split(frame.buffer_to_styled(drawn), "\n")
    as "one header and one session row"
  assert string.ends_with(header, "NAME" <> style.ansi_reset())
  assert string.ends_with(row, "  n")
  assert !list.any([header, row], string.contains(_, "H\u{001B}"))
}
