import etui/backend
import etui/buffer
import etui/geometry
import etui/text
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/daemon/protocol
import tui/frame
import tui/session_selector
import tui/theme
import tui/workspace

fn sessions() -> List(protocol.Session) {
  ["01a07d71-e1fb", "01a07d74-272d"]
  |> list.map(fn(prefix) {
    protocol.Session(
      prefix <> "-7cc1-beeb-8da1658eec67",
      "/Users/operator/"
        <> string.repeat("long-parent-directory/", 8)
        <> "loom-worktree",
      "loom · main",
      1,
      protocol.RecoveryBlocked,
    )
  })
}

fn selector(selected: Int) -> session_selector.State {
  let rows = sessions()
  let assert Ok(first) = list.first(rows) as "the fixture has two sessions"
  session_selector.State(
    protocol.Page(1, rows, None),
    selected,
    first.session_id,
    session_selector.Browsing,
  )
}

fn row_with(painted: buffer.Buffer, needle: String) -> Int {
  let assert Ok(#(index, _)) =
    painted
    |> frame.buffer_to_lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(row) { string.contains(row.1, needle) })
    as "the expected selector text must survive clipping"
  index
}

fn line_at(painted: buffer.Buffer, row: Int) -> String {
  let assert Ok(line) =
    painted |> frame.buffer_to_lines |> list.drop(row) |> list.first
    as "the rendered row exists"
  line
}

pub fn session_selector_preserves_markers_labels_and_distinct_ids_test() {
  list.each([44, 80, 96, 292], fn(width) {
    let screen = geometry.rect_new(0, 0, width, 24)
    let painted =
      session_selector.render(buffer.buffer_new(screen), screen, selector(0))
    let selected = row_with(painted, "▸")
    let title = line_at(painted, selected)
    let detail = line_at(painted, selected + 1)
    assert row_with(painted, "●") == selected
    assert string.contains(title, "loom · main")
    assert string.contains(title, "[recovery blocked]")
    assert !string.contains(title, "long-parent-directory")
    assert string.contains(detail, "loom-worktree")
    assert string.contains(detail, "01a07d71-e1fb")
    assert row_with(painted, "01a07d74-272d") == selected + 3
    assert list.all(frame.buffer_to_lines(painted), fn(line) {
      text.cell_width(line) <= width
    })
    case width == 292 {
      True -> {
        assert string.contains(
          detail,
          string.repeat("long-parent-directory/", 4),
        )
      }
      False -> Nil
    }
  })
}

pub fn session_selector_scroll_keeps_the_selected_record_visible_test() {
  let rows =
    list.repeat(Nil, 12)
    |> list.index_map(fn(_, index) {
      protocol.Session(
        "session-" <> int.to_string(index),
        "/a/long/workspace/path/loom-worktree",
        "loom · main",
        1,
        protocol.Resident("generation"),
      )
    })
  let state =
    session_selector.State(
      protocol.Page(1, rows, None),
      11,
      "session-11",
      session_selector.Browsing,
    )
  let screen = geometry.rect_new(0, 0, 80, 16)
  let painted =
    session_selector.render(buffer.buffer_new(screen), screen, state)
  assert row_with(painted, "●") == row_with(painted, "▸")
  assert row_with(painted, "session-11") == row_with(painted, "▸") + 1
  assert row_with(painted, "↑↓ select") > row_with(painted, "session-11")
}

pub fn session_selector_arrows_repaint_the_cached_terminal_frame_test() {
  let initial =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/test/workspace", None),
      fn() { -1000 },
    )
  let initial = tui.Model(..initial, overlay: tui.DaemonSelector(selector(0)))
  let initial = tui.update(backend.Resize(96, 24), initial)
  let screen = geometry.rect_new(0, 0, 96, 24)
  let #(first, _) = tui.view(initial, screen)
  let down = tui.update(backend.KeyPress("down"), initial)
  let down = tui.update(backend.Tick, down)
  let #(second, _) = tui.view(down, screen)
  assert row_with(second, "▸") == row_with(first, "▸") + 2
  assert row_with(second, "●") == row_with(first, "●")
  assert first != second

  // A clock that does not advance exercises the deferred frame flush, not
  // merely the pure widget: the next terminal tick must expose both moves.
  let up = tui.update(backend.KeyPress("up"), down)
  let up = tui.update(backend.Tick, up)
  let #(third, _) = tui.view(up, screen)
  let selected = row_with(third, "▸")
  assert selected == row_with(first, "▸")
  let assert Ok(#(before, _)) = string.split_once(line_at(third, selected), "▸")
    as "the selected marker remains visible"
  let cell =
    buffer.get_cell(third, geometry.Position(text.cell_width(before), selected))
  assert cell.style == theme.overlay_signal()
}
