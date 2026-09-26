//// The session catalogue as a styled table for `loom sessions list`.
////
//// The launcher's listing has two readers. A script or a pipe wants one
//// line per row with fixed separators, and gets exactly that from the
//// launcher untouched. A person at a terminal wants the columns aligned and
//// the lifecycle legible at a glance, which is what this module draws: an
//// etui buffer sized to its content, printed into the scrollback through
//// `frame.buffer_to_styled` rather than painted on an alternate screen.
////
//// Drawing through a buffer rather than concatenating escape codes keeps
//// one width model for the whole client. A CJK session name is measured by
//// the same cell arithmetic the interactive picker uses, so the columns stay
//// aligned wherever the picker's would.

import etui/buffer.{type Buffer}
import etui/geometry.{Position}
import etui/style
import etui/text
import gleam/int
import gleam/list
import tui/daemon/protocol as control_protocol
import tui/text_hygiene
import tui/theme

// The gap between columns, in cells.
const gutter = 2

/// Draws the catalogue as a header row followed by one row per session.
///
/// Every column is as wide as its widest cell, so nothing is truncated: the
/// terminal soft-wraps a row wider than itself, which is a better failure
/// than an elided session id nobody can paste back into `loom sessions rm`.
///
/// ## Examples
///
/// ```gleam
/// let drawn = session_table.render(page.sessions)
/// io.println(frame.buffer_to_styled(drawn))
/// ```
pub fn render(sessions: List(control_protocol.Session)) -> Buffer {
  let rows = list.map(sessions, cells)
  let header = [
    #("SESSION", header_style()),
    #("STATE", header_style()),
    #("WORKSPACE", header_style()),
    #("NAME", header_style()),
  ]
  let all = [header, ..rows]
  let widths = column_widths(all)
  let width = int.sum(widths) + gutter * { list.length(widths) - 1 }
  let area = geometry.rect_new(0, 0, int.max(width, 1), list.length(all))

  list.index_fold(all, buffer.buffer_new(area), fn(drawn, row, y) {
    draw_row(drawn, row, widths, 0, y)
  })
}

/// The word and colour that name a lifecycle state.
///
/// Resident is the only state with a live runtime, so it alone is green; a
/// transition is amber because it will resolve on its own; a blocked
/// recovery is red because it will not.
///
/// ## Examples
///
/// ```gleam
/// let #(word, _style) = session_table.state(control_protocol.Saved)
/// assert word == "saved"
/// ```
pub fn state(status: control_protocol.Lifecycle) -> #(String, style.Style) {
  case status {
    control_protocol.Saved -> #("saved", theme.quiet_text())
    control_protocol.Reserved -> #("reserved", theme.quiet_text())
    control_protocol.Opening(_) -> #("opening", signal())
    control_protocol.Resident(_) -> #("resident", theme.success_text())
    control_protocol.Stopping(_) -> #("stopping", signal())
    control_protocol.RecoveryBlocked -> #("blocked", theme.danger_text())
  }
}

fn cells(row: control_protocol.Session) -> List(#(String, style.Style)) {
  [
    #(row.session_id, theme.inline_code()),
    state(row.status),
    #(row.workspace, style.default_style()),
    #(text_hygiene.single_line(row.name), style.default_style()),
  ]
}

fn header_style() -> style.Style {
  style.new(theme.quiet, style.Default, style.bold())
}

fn signal() -> style.Style {
  style.new(theme.signal, style.Default, style.none())
}

// Widths are measured in terminal cells, not graphemes, so a wide glyph
// counts twice exactly as it will be drawn.
fn column_widths(rows: List(List(#(String, style.Style)))) -> List(Int) {
  list.fold(rows, [], fn(widths, row) {
    let measured = list.map(row, fn(cell) { text.cell_width(cell.0) })
    case widths {
      [] -> measured
      _ -> list.map2(widths, measured, int.max)
    }
  })
}

fn draw_row(
  drawn: Buffer,
  row: List(#(String, style.Style)),
  widths: List(Int),
  x: Int,
  y: Int,
) -> Buffer {
  case row, widths {
    [#(content, styled), ..rest], [width, ..more] -> {
      let drawn = buffer.set_string(drawn, Position(x:, y:), content, styled)
      draw_row(drawn, rest, more, x + width + gutter, y)
    }
    _, _ -> drawn
  }
}
