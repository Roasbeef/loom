//// The session catalogue as a styled table for `loom sessions list`.
////
//// The launcher's listing has two readers. A script or a pipe wants one
//// line per row with fixed separators, and gets exactly that from the
//// launcher untouched. A person at a terminal wants the columns aligned and
//// the lifecycle legible at a glance, which is what this module draws: an
//// etui buffer sized to its content, printed into the scrollback through
//// `frame.buffer_to_styled` rather than painted on an alternate screen.
////
//// Both readers see the resident track by default — the launcher filters
//// on `resident_track` before either format runs — and only `--all` widens
//// the rows this module ever receives back to the whole catalogue.
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
import session_view/text_hygiene
import tui/daemon/protocol as control_protocol
import tui/placement
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
/// transition, a move included, is amber because it will resolve on its own; a
/// blocked recovery is red because it will not. A session being moved names its
/// destination, since that is what the operator would ask next.
///
/// ## Examples
///
/// ```gleam
/// let #(word, _style) = session_table.state(control_protocol.Saved)
/// assert word == "saved"
/// let #(word, _style) = session_table.state(control_protocol.Moving("laptop"))
/// assert word == "moving to laptop"
/// ```
pub fn state(status: control_protocol.Lifecycle) -> #(String, style.Style) {
  case status {
    control_protocol.Saved -> #("saved", theme.quiet_text())
    control_protocol.Moving(to) -> #("moving to " <> to, signal())
    control_protocol.Reserved -> #("reserved", theme.quiet_text())
    control_protocol.FailedStart(..) -> #("failed", theme.danger_text())
    control_protocol.Opening(_) -> #("opening", signal())
    control_protocol.Resident(_) -> #("resident", theme.success_text())
    control_protocol.Stopping(_) -> #("stopping", signal())
    control_protocol.RecoveryBlocked -> #("blocked", theme.danger_text())
  }
}

/// The state as one token with no whitespace, for the plain listing that scripts
/// split on whitespace.
///
/// Every lifecycle is its table word except a session being moved, whose
/// destination rides in the same token as `moving:<orchestrator>`. That is the
/// shape `placement.label` gives a remote workspace, `executor:name`: a key, a
/// colon and a value in one token, so a parser that splits on whitespace still
/// gets the state and its value together. An orchestrator name has no whitespace
/// or colon.
///
/// ## Examples
///
/// ```gleam
/// assert session_table.state_token(control_protocol.Saved) == "saved"
/// assert session_table.state_token(control_protocol.Moving("laptop"))
///   == "moving:laptop"
/// ```
pub fn state_token(status: control_protocol.Lifecycle) -> String {
  case status {
    control_protocol.Moving(to) -> "moving:" <> to
    control_protocol.Saved
    | control_protocol.Reserved
    | control_protocol.FailedStart(..)
    | control_protocol.Opening(_)
    | control_protocol.Resident(_)
    | control_protocol.Stopping(_)
    | control_protocol.RecoveryBlocked -> state(status).0
  }
}

/// Whether a lifecycle belongs to the resident track `loom sessions list`
/// shows by default.
///
/// A saved registration and a bare reservation are the idle remainder —
/// neither holds a runtime or a cleanup in progress — so both answer
/// `False` here; every other lifecycle, including a transition, a move in
/// flight or a blocked recovery, still occupies the daemon and answers `True`.
///
/// ## Examples
///
/// ```gleam
/// assert session_table.resident_track(control_protocol.Resident("i"))
/// assert !session_table.resident_track(control_protocol.Saved)
/// ```
pub fn resident_track(status: control_protocol.Lifecycle) -> Bool {
  case status {
    control_protocol.Saved -> False
    control_protocol.Reserved -> False

    // A failed start is the one reservation worth showing without `--all`: it
    // is stuck, it says why, and the owner is meant to retry or delete it.
    control_protocol.FailedStart(..) -> True
    control_protocol.Moving(_) -> True
    control_protocol.Opening(_) -> True
    control_protocol.Resident(_) -> True
    control_protocol.Stopping(_) -> True
    control_protocol.RecoveryBlocked -> True
  }
}

/// Formats session fields into styled table cells.
fn cells(row: control_protocol.Session) -> List(#(String, style.Style)) {
  [
    #(row.session_id, theme.inline_code()),
    state(row.status),
    #(placement.label(row.executor, row.workspace), style.default_style()),
    #(
      text_hygiene.single_line(row.name) <> failure_note(row.status),
      style.default_style(),
    ),
  ]
}

/// What follows a row's name when its start failed: two spaces, the words and
/// the reason the daemon kept, drawn as one line. A lifecycle that did not fail
/// adds nothing, so every other row is as it was. The last column carries it,
/// so no other column's width moves.
///
/// ## Examples
///
/// ```gleam
/// assert session_table.failure_note(control_protocol.Saved) == ""
/// assert session_table.failure_note(control_protocol.FailedStart("no census", 1))
///   == "  failed to start: no census"
/// ```
pub fn failure_note(status: control_protocol.Lifecycle) -> String {
  case status {
    control_protocol.FailedStart(reason:, ..) ->
      "  failed to start: " <> text_hygiene.single_line(reason)
    control_protocol.Saved
    | control_protocol.Reserved
    | control_protocol.Moving(_)
    | control_protocol.Opening(_)
    | control_protocol.Resident(_)
    | control_protocol.Stopping(_)
    | control_protocol.RecoveryBlocked -> ""
  }
}

fn header_style() -> style.Style {
  style.new(theme.quiet, style.Default, style.bold())
}

fn signal() -> style.Style {
  style.new(theme.signal, style.Default, style.none())
}

/// Measures column widths across all rows in terminal cells.
fn column_widths(rows: List(List(#(String, style.Style)))) -> List(Int) {
  list.fold(rows, [], fn(widths, row) {
    let measured = list.map(row, fn(cell) { text.cell_width(cell.0) })

    // Combine with maximum column widths seen so far.
    case widths {
      [] -> measured
      _ -> list.map2(widths, measured, int.max)
    }
  })
}

/// Draws a single row of cells into the buffer at the given position.
fn draw_row(
  drawn: Buffer,
  row: List(#(String, style.Style)),
  widths: List(Int),
  x: Int,
  y: Int,
) -> Buffer {
  // Draw each cell recursively.
  case row, widths {
    [#(content, styled), ..rest], [width, ..more] -> {
      let drawn = buffer.set_string(drawn, Position(x:, y:), content, styled)
      draw_row(drawn, rest, more, x + width + gutter, y)
    }
    _, _ -> drawn
  }
}
