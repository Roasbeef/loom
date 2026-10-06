//// The session picker's layout, read off whole terminal frames at 120 and
//// 80 columns. The picker is a table: a reader runs an eye down one column
//// (the state words, the ages) without reading the names, so these tests
//// pin that every row puts each column in the same cells, that the
//// highlighted row is one bar, and that what does not fit is cut at a word
//// or counted rather than clipped.

import etui/backend
import etui/buffer
import etui/geometry
import etui/style
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/daemon/protocol
import tui/frame
import tui/model as tui_model
import tui/render
import tui/session_selector
import tui/theme
import tui/view_set
import tui/workspace

const minute = 60_000

const day = 86_400_000

fn session(
  now: Int,
  id: String,
  workspace: String,
  name: String,
  age: Int,
  status: protocol.Lifecycle,
) -> protocol.Session {
  protocol.Session(id, workspace, name, now - age, status, option.None)
}

// Eight sessions over four workspaces, in every presence the picker draws.
fn page(now: Int) -> protocol.Page {
  let loom = "/Users/operator/code/loom"
  protocol.Page(
    1,
    [
      session(
        now,
        "s-herdr",
        loom,
        "herdr-update",
        12 * minute,
        protocol.Resident("a"),
      ),
      session(now, "s-main", loom, "main", 2 * day, protocol.Resident("b")),
      session(
        now,
        "s-reconnect",
        loom,
        "reconnect",
        3 * day,
        protocol.RecoveryBlocked,
      ),
      session(
        now,
        "s-long",
        loom,
        "a-very-long-session-name-that-goes-on-and-on-and-on",
        5 * day,
        protocol.Saved,
      ),
      session(
        now,
        "s-weft",
        "/Users/operator/code/weft",
        "managed-tasks",
        day,
        protocol.Resident("c"),
      ),
      session(
        now,
        "s-lnd",
        "/Users/operator/code/lnd",
        "static-panic-analysis",
        240 * minute,
        protocol.Resident("d"),
      ),
      session(
        now,
        "s-htlc",
        "/Users/operator/code/lnd",
        "htlc interceptor",
        7 * day,
        protocol.Saved,
      ),
      session(
        now,
        "s-badge",
        "/Users/operator/code/pi-gui",
        "fix readme badge",
        14 * day,
        protocol.Saved,
      ),
    ],
    None,
  )
}

fn activity() -> List(protocol.Activity) {
  [
    protocol.Activity(
      "s-herdr",
      protocol.Working,
      5,
      4,
      0,
      None,
      None,
      None,
      [],
    ),
    protocol.Activity(
      "s-main",
      protocol.NeedsYou,
      3,
      1,
      1,
      None,
      Some("Waiting on your approval for a network fetch to proxy.golang.org."),
      Some("moonshotai/Kimi-K3"),
      [protocol.GlanceLine("sub:main/bootstrap-77aa10", "Boot", "finished")],
    ),
    protocol.Activity(
      "s-weft",
      protocol.NeedsYou,
      1,
      0,
      0,
      Some(protocol.LastFailed),
      None,
      None,
      [],
    ),
    protocol.Activity("s-lnd", protocol.Idle, 3, 0, 0, None, None, None, []),
  ]
}

fn picker(now: Int) -> session_selector.State {
  let state = session_selector.new(page(now), "s-main")
  session_selector.observe(
    state,
    session_selector.resident_ids(state),
    activity(),
  )
}

// The whole terminal frame with the picker open, through the real renderer.
// The page is built against the wall clock the resize stamped, so the ages
// are exact, and the frame is painted afresh rather than read from the
// cache the resize filled before the picker was open.
fn painted(
  build: fn(Int) -> session_selector.State,
  width: Int,
  height: Int,
) -> buffer.Buffer {
  let model =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/Users/operator/code/loom", None),
      fn() { 0 },
    )
  let model = tui.update(backend.Resize(width, height), model)
  let model =
    tui_model.Model(
      ..model,
      view: view_set.overlay(
        model.view,
        tui_model.DaemonSelector(build(model.view.wall_ms)),
      ),
    )
  let #(buf, _) =
    render.render_frame(model, geometry.rect_new(0, 0, width, height))
  buf
}

fn line_with(lines: List(String), needle: String) -> String {
  let assert Ok(line) = list.find(lines, string.contains(_, needle))
    as "the frame draws the expected text"
  line
}

// The cell a needle starts in, counted in cells rather than bytes.
fn column(line: String, needle: String) -> Int {
  let assert Ok(#(before, _)) = string.split_once(line, needle)
    as "the line holds the needle"
  string.length(before)
}

pub fn wide_picker_aligns_every_column_and_previews_the_selection_test() {
  let lines = painted(picker, 120, 40) |> frame.buffer_to_lines
  let working = line_with(lines, "herdr-update")
  let needs = line_with(lines, "▸ ! main")
  let blocked = line_with(lines, "reconnect")
  let saved = line_with(lines, "fix readme badge")

  // The state words share a column, and so do the summaries and the ages.
  assert column(working, "working") == column(needs, "needs you")
  assert column(needs, "needs you") == column(blocked, "blocked")
  assert column(blocked, "blocked") == column(saved, "saved")
  assert column(working, "4 of 5 strands") == column(needs, "1 approval")
  assert column(working, "12m") == column(needs, "2d") - 1
  assert column(blocked, "3d") == column(saved, "2w")

  // A long name is cut with an ellipsis at its column, never into the
  // state word beside it.
  let long = line_with(lines, "a-very-long")
  assert string.contains(long, "…")
  assert column(long, "saved") == column(saved, "saved")

  // The headings shorten the path to the home directory and count rows.
  let heading = line_with(lines, "LOOM")
  assert string.contains(heading, "~/code/loom")
  assert string.contains(heading, "4  │ loom · main")

  // The preview has its fixed labels and the session's own words.
  assert string.contains(line_with(lines, "LAST MESSAGE"), "LAST MESSAGE")
  assert string.contains(line_with(lines, "STRANDS"), "3, 1 working")
  assert string.contains(line_with(lines, "MODEL "), "moonshotai/Kimi-K3")
  assert string.contains(line_with(lines, "WORKSPACE "), "~/code/loom")
  assert list.all(lines, fn(line) { string.length(line) <= 120 })
}

pub fn narrow_picker_expands_the_selection_and_counts_what_it_hides_test() {
  let lines = painted(picker, 80, 24) |> frame.buffer_to_lines
  let needs = line_with(lines, "▸ ! main")
  let working = line_with(lines, "herdr-update")

  // No preview: the state word and the age follow the name, aligned.
  assert !list.any(lines, string.contains(_, "LAST MESSAGE"))
  assert column(working, "working") == column(needs, "needs you")
  assert column(working, "12m") == column(needs, "2d") - 1

  // The highlighted row's second line carries its reason and message, cut
  // at a word with an ellipsis.
  let assert [_, second, ..] =
    list.drop_while(lines, fn(line) { !string.contains(line, "▸ ! main") })
    as "the highlighted row is drawn"
  assert string.contains(second, "1 approval pending · Waiting on your")
  assert string.contains(second, "fetch…")

  // Rows past the frame are counted, not clipped.
  assert string.contains(line_with(lines, "more below"), "↓ 3 more below")
  assert list.all(lines, fn(line) { string.length(line) <= 80 })
}

pub fn the_highlighted_row_is_one_raised_bar_test() {
  let buf = painted(picker, 120, 40)
  let lines = frame.buffer_to_lines(buf)
  let assert Ok(#(y, line)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, "▸ ! main") })
    as "the highlighted row is drawn"
  let start = column(line, "▸")
  let divider = column(string.drop_start(line, start), "│") + start

  // Every cell from the marker to the margin before the divider is raised.
  let cells =
    list.repeat(Nil, divider - 1 - start)
    |> list.index_map(fn(_, offset) { start + offset })
  assert list.all(cells, fn(x) {
    buffer.cell_bg(buffer.get_cell(buf, geometry.Position(x, y)))
    == theme.raised
  })
  assert buffer.cell_style(buffer.get_cell(buf, geometry.Position(start, y)))
    == style.new(theme.signal, theme.raised, style.bold())
}

pub fn the_padding_inside_the_border_has_the_modal_background_test() {
  let buf = painted(picker, 80, 24)
  let lines = frame.buffer_to_lines(buf)
  let assert Ok(#(y, line)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, "herdr-update") })
    as "a row is drawn"
  let border = column(line, "│")
  assert buffer.cell_bg(buffer.get_cell(buf, geometry.Position(border + 1, y)))
    == theme.graphite
}

pub fn a_confirmation_keeps_its_answer_keys_on_their_own_row_test() {
  let confirming = fn(now) {
    session_selector.State(
      ..picker(now),
      prompt: session_selector.ConfirmingArchive("s-main"),
    )
  }
  let lines = painted(confirming, 80, 24) |> frame.buffer_to_lines
  assert string.contains(
    line_with(lines, "Stop and archive"),
    "Stop and archive main (s-main)? Its history is kept.",
  )
  assert string.contains(
    line_with(lines, "y archive"),
    "y archive · any other key keeps it",
  )
  assert !list.any(lines, string.contains(_, "↑↓ move"))
}

pub fn twins_carry_their_short_identity_test() {
  let twins = fn(now) {
    let rows = [
      session(
        now,
        "01a07d71-e1fb-7cc1",
        "/work/loom",
        "loom · main",
        day,
        protocol.Saved,
      ),
      session(
        now,
        "01a07d74-272d-7cc1",
        "/work/loom",
        "loom · main",
        day,
        protocol.Saved,
      ),
      session(
        now,
        "01a07d75-0000-7cc1",
        "/work/loom",
        "other",
        day,
        protocol.Saved,
      ),
    ]
    session_selector.new(protocol.Page(1, rows, None), "")
  }
  let lines = painted(twins, 120, 40) |> frame.buffer_to_lines
  assert string.contains(
    line_with(lines, "01a07d71-e1fb"),
    "loom · main · 01a07d71-e1fb",
  )
  assert string.contains(
    line_with(lines, "01a07d74-272d"),
    "loom · main · 01a07d74-272d",
  )
  assert !string.contains(line_with(lines, "other"), "01a07d75")
}

pub fn ages_read_in_the_largest_whole_unit_test() {
  let lines = painted(picker, 120, 40) |> frame.buffer_to_lines
  assert string.contains(line_with(lines, "herdr-update"), "12m")
  assert string.contains(line_with(lines, "static-panic"), "4h")
  assert string.contains(line_with(lines, "htlc"), "1w")
  assert string.contains(line_with(lines, "fix readme"), "2w")
}

// The picker owns the screen below the identity line: the transcript behind
// it must not show in the margins beside the frame, at any width.
pub fn nothing_behind_the_picker_shows_beside_it_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let shown = painted(picker, size.0, size.1) |> frame.buffer_to_lines
    assert !list.any(shown, string.contains(_, "gateway paths ready"))
    assert !list.any(shown, string.contains(_, "Native client"))
    let assert [identity, ..] = shown as "a frame has rows"
    assert string.contains(identity, "◆")
  })
}

// The attached session's mark is quiet; only the cursor's mark is amber.
pub fn only_the_cursor_mark_is_amber_test() {
  let buf =
    painted(
      fn(now) {
        session_selector.State(..picker(now), current: "s-herdr", selected: 1)
      },
      120,
      40,
    )
  let lines = frame.buffer_to_lines(buf)
  let assert Ok(#(y, line)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, "› ● herdr-update") })
    as "the attached row is marked"
  let at = column(line, "›")
  assert buffer.cell_fg(buffer.get_cell(buf, geometry.Position(at, y)))
    == theme.quiet
}

// A name with no break in it is cut with an ellipsis in the preview's
// heading, never broken across lines.
pub fn a_long_unbroken_name_is_cut_in_the_preview_test() {
  let long = fn(now) {
    session_selector.new(
      protocol.Page(
        1,
        [
          session(
            now,
            "s-long",
            "/Users/operator/code/loom",
            "an-unbroken-session-name-much-longer-than-the-preview-pane",
            day,
            protocol.Saved,
          ),
        ],
        None,
      ),
      "",
    )
  }
  let shown = painted(long, 120, 40) |> frame.buffer_to_lines
  let heading = line_with(shown, "│ loom · an-unbroken")
  assert string.ends_with(string.trim_end(string.drop_end(heading, 1)), "…")
}
