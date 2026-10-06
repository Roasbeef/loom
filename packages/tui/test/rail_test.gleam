//// The docked rail, as geometry and as whole frames at 200, 120 and 80
//// columns.
////
//// The rail is one column beside the transcript, from the row under the
//// identity line to the last row. It docks only where the transcript keeps
//// 75 cells, by default from 160 columns and on request from 120, shows the
//// agents with the row renderer the strip and the workspace share, and hosts
//// the changes panel while the changes are open. These tests pin the
//// decision (`rail.columns`), what a frame looks like with and without it,
//// the keys that reach it, and that the strip steps aside while the rail
//// lists the agents. With `LOOM_RAIL_RENDERS` set to a directory, the last
//// test also writes the frames as text for a person to read.

import core/json
import etui/backend
import etui/geometry
import frame_scene
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host_bootstrap
import session_view/agent_view
import session_view/approval
import session_view/model as _
import session_view/shared_set
import simplifile
import tui
import tui/agent_strip
import tui/approval_panel
import tui/frame
import tui/layout
import tui/layout_memory
import tui/model.{type Model, Model} as tui_model
import tui/rail
import tui/submit
import tui/view_set
import tui_test/stepping

// ------------------------------------------------------------ the decision

pub fn the_rail_docks_by_width_and_choice_test() {
  let shown = Some(layout_memory.RailShown)
  let hidden = Some(layout_memory.RailHidden)

  // Below 120 the transcript could not keep 75 cells, whatever was chosen.
  assert rail.columns(119, shown, rail.Strands) == 0
  assert rail.columns(119, None, rail.Changes) == 0

  // From 120 a person can dock it; the rail is 44 cells and its separator.
  assert rail.columns(120, shown, rail.Strands) == 45
  assert rail.columns(120, None, rail.Strands) == 0
  assert rail.columns(159, None, rail.Strands) == 0
  assert rail.columns(159, shown, rail.Strands) == 45

  // From 160 it is docked unless it was hidden, and 56 cells wide.
  assert rail.columns(160, None, rail.Strands) == 57
  assert rail.columns(200, None, rail.Strands) == 57
  assert rail.columns(200, hidden, rail.Strands) == 0

  // Opening the changes docks it wherever it fits, whatever was chosen.
  assert rail.columns(120, hidden, rail.Changes) == 45
  assert rail.columns(200, hidden, rail.Changes) == 57

  // The transcript always keeps its 75.
  assert 120 - rail.columns(120, shown, rail.Strands) == 75
}

// ------------------------------------------------------------- the frames

fn agent(id: String, status: agent_view.Status, activity: String) {
  agent_view.Row(
    id:,
    name: id,
    operation: Some("op-" <> id),
    status:,
    task: "Check the doc comments against behaviour.",
    activity:,
    update: "",
    update_entry: None,
    pending: "",
    approvals: [],
    model: "moonshotai/Kimi-K3",
    recent: [],
    decision: "",
  )
}

// A session with a short conversation and four agents, one of which needs
// the operator.
fn scene() -> Model {
  let base =
    frame_scene.attach(frame_scene.model(), "fix readme badge", [
      frame_scene.user(1, "Which files make up the calculator?"),
      frame_scene.assistant(
        2,
        "Two modules: src/calc.gleam and its test, test/calc_test.gleam.",
        [],
      ),
      frame_scene.user(3, "What does calc.gleam export today?"),
      frame_scene.assistant(
        4,
        "It exports add and multiply, both over Int. The tests cover add only.",
        [],
      ),
    ])
  Model(
    ..base,
    shared: shared_set.agent_rows(base.shared, [
      agent("main", agent_view.Working, "Waiting for 2 reviewers"),
      agent("advisor", agent_view.Working, "1 nudge pending"),
      agent(
        "sub:main/tests-0a0b0c0d0e0f1011",
        agent_view.NeedsInput,
        "Needs approval · network",
      ),
      agent("sub:main/docs-9e21bb44aa00cc11", agent_view.Finished, "Finished"),
    ]),
  )
}

fn rows_of(model: Model, width: Int, height: Int) -> List(String) {
  frame_scene.screen(model, width, height) |> frame.buffer_to_lines
}

fn column(rows: List(String), x: Int, y: Int) -> String {
  case list.drop(rows, y) {
    [row, ..] -> string.slice(row, x, 1)
    [] -> ""
  }
}

fn downto(last: Int) -> List(Int) {
  int.range(from: 1, to: last + 1, with: [], run: fn(all, n) { [n, ..all] })
}

pub fn a_wide_terminal_docks_the_rail_on_strands_test() {
  let rows = rows_of(scene(), 200, 50)

  // The separator runs the height under the identity line, 57 columns from
  // the right edge, with the tab bar, heading and agents beside it.
  list.each(downto(49), fn(y) {
    assert column(rows, 143, y) == "│"
      as "the rail's separator runs to the last row"
  })
  assert column(rows, 143, 0) != "│" as "the identity line spans the screen"
  let text = string.join(rows, "\n")
  assert string.contains(text, "Strands ●1")
  assert string.contains(text, "Changes")
  assert string.contains(text, "STRANDS · 4")
  assert string.contains(text, "tests")
  assert string.contains(text, "Needs approval")
  assert string.contains(text, "Shift+Tab hides")
}

pub fn the_input_frame_spans_the_transcript_column_only_test() {
  let rows = rows_of(scene(), 200, 50)
  let assert Ok(top) = list.find(rows, string.contains(_, "To main"))
    as "the input frame's top rule is on screen"
  // The frame ends before the rail's separator, which is its own column.
  assert string.slice(top, 142, 1) == "╮"
  assert string.slice(top, 143, 1) == "│"
}

pub fn the_strip_steps_aside_while_the_rail_lists_agents_test() {
  // At 200 columns the rail lists the four agents, so nothing is listed
  // under the input as well.
  let docked = scene()
  assert layout.strip_height(Model(..docked, view: sized(docked, 200, 50))) == 0
  // At 120 with no choice the rail is not docked, and the strip lists them.
  let narrow = Model(..scene(), view: sized(scene(), 120, 40))
  assert layout.rail_columns(narrow) == 0
  assert layout.strip_height(narrow) > 0
}

fn sized(model: Model, width: Int, height: Int) -> tui_model.View {
  let resized = tui.update(backend.Resize(width, height), model)
  resized.view
}

pub fn shift_tab_docks_and_hides_the_rail_at_120_test() {
  let model = tui.update(backend.Resize(120, 40), scene())
  assert layout.rail_columns(model) == 0
  let #(docked, _) = stepping.step(backend.KeyPress("backtab"), model)
  assert layout.rail_columns(docked) == 45
  assert docked.view.rail == Some(layout_memory.RailShown)
  assert layout.transcript_width(docked) == 73
    as "the transcript keeps 75 cells less its margin"
  let rows = rows_of(docked, 120, 40)
  assert string.contains(string.join(rows, "\n"), "STRANDS · 4")
  assert layout.strip_height(docked) == 0
  let #(hidden, _) = stepping.step(backend.KeyPress("backtab"), docked)
  assert layout.rail_columns(hidden) == 0
  assert hidden.view.rail == Some(layout_memory.RailHidden)
  assert layout.strip_height(hidden) > 0
}

pub fn shift_tab_on_a_narrow_terminal_opens_the_sheet_unrecorded_test() {
  let model = tui.update(backend.Resize(80, 24), scene())
  let #(after, _) = stepping.step(backend.KeyPress("backtab"), model)
  assert layout.rail_columns(after) == 0
  assert layout.sheet_shown(after)
  assert after.view.rail == None as "a sheet is not a preference"
}

// What Escape does at a composer with nothing to dismiss is interrupt the
// strand. A probe of that, so the tests below can say it did not happen: the
// reducer answers it with effects or a notice, and a consumed key with neither.
fn escape_effects(model: Model) -> #(Model, Bool) {
  let #(after, effects) = stepping.step(backend.KeyPress("esc"), model)
  #(after, effects != [] || after.shared.notice != model.shared.notice)
}

pub fn escape_at_a_composer_is_the_interrupt_the_probe_sees_test() {
  let #(_, interrupted) =
    escape_effects(tui.update(backend.Resize(200, 50), scene()))
  assert interrupted as "the probe sees Escape's interrupt"
}

pub fn escape_at_a_cursor_whose_strip_is_gone_does_not_interrupt_test() {
  let model = tui.update(backend.Resize(120, 40), scene())
  let browsing =
    tui_model.store_strip(
      model,
      agent_strip.enter(
        tui_model.strip(model),
        layout.strip_lines(model),
        model.shared.active_strand,
      ),
    )
  assert browsing.view.strip_focus != agent_strip.Composing
  let settled =
    Model(
      ..browsing,
      shared: shared_set.agent_rows(browsing.shared, [
        agent("main", agent_view.Finished, "Finished"),
      ]),
    )
  assert !layout.strands_listed(settled)
  let #(after, interrupted) = escape_effects(settled)
  assert !interrupted as "the key is consumed by the reset"
  assert after.view.strip_focus == agent_strip.Composing
}

fn review() -> approval.Review {
  approval.Review(
    "esc",
    7,
    approval.Pending,
    "bash",
    "fetch https://proxy.golang.org/gleam_stdlib/@v/list",
    None,
    approval.Exact("digest", [
      json.Object([
        #("type", json.String("readable_root")),
        #("path", json.String("/work/report")),
      ]),
    ]),
    strand: None,
  )
}

pub fn an_approval_steps_the_rail_aside_without_moving_the_columns_test() {
  let before = tui.update(backend.Resize(200, 50), scene())
  let opened =
    Model(
      ..before,
      view: view_set.overlay(
        before.view,
        tui_model.ApprovalInspector(approval_panel.new(review())),
      ),
    )
  assert layout.rail_columns(opened) == layout.rail_columns(before)
    as "the rail's columns stay reserved"
  assert layout.column_width(opened) == layout.column_width(before)
    as "so the transcript is not re-wrapped"
  assert layout.rail_area(geometry.rect_new(0, 0, 200, 50), opened).size.width
    == 0
  let text = string.join(rows_of(opened, 200, 50), "\n")
  assert !string.contains(text, "STRANDS ·") as "the rail is not painted"
  assert string.contains(text, "1  Allow once")
  assert string.contains(
    string.join(rows_of(before, 200, 50), "\n"),
    "STRANDS ·",
  )
}

pub fn down_from_the_composer_puts_the_cursor_in_the_rail_test() {
  let model = tui.update(backend.Resize(200, 50), scene())
  let #(focused, _) = stepping.step(backend.KeyPress("down"), model)
  let assert agent_strip.Browsing(cursor) = focused.view.strip_focus
    as "down from the composer enters the agent list"
  assert cursor != "" as "the cursor rests on an agent"
  let text = string.join(rows_of(focused, 200, 50), "\n")
  assert string.contains(text, "Enter focus")
}

pub fn the_changes_open_in_the_rail_and_close_back_to_strands_test() {
  let model = tui.update(backend.Resize(120, 40), scene())
  let opened = submit.open_diff(model)
  assert layout.rail_columns(opened) == 45
    as "opening the changes docks the rail at 120 even though it was not"
  let text = string.join(rows_of(opened, 120, 40), "\n")
  assert string.contains(text, "Captured edits")
  let closed = submit.open_diff(opened)
  assert layout.rail_columns(closed) == 0
}

pub fn the_rail_keeps_the_layout_memory_in_step_test() {
  // The choice a person makes is what the memory holds, and a terminal that
  // was never asked holds none.
  let model = tui.update(backend.Resize(200, 50), scene())
  assert model.view.rail == None
  let #(hidden, _) = stepping.step(backend.KeyPress("backtab"), model)
  assert layout.rail_columns(hidden) == 0
  assert hidden.view.rail == Some(layout_memory.RailHidden)
}

// ------------------------------------------------------------ the renders

// Writes the frames a critic reads, when a directory is named.
pub fn the_rail_frames_can_be_written_for_review_test() {
  let wide = rows_of(scene(), 200, 50)
  let medium = rows_of(scene(), 120, 40)
  let docked =
    tui.update(backend.Resize(120, 40), scene())
    |> fn(model) { tui.update(backend.KeyPress("backtab"), model) }
    |> rows_of(120, 40)
  let narrow = rows_of(scene(), 80, 24)
  let changes =
    tui.update(backend.Resize(120, 40), scene())
    |> submit.open_diff
    |> rows_of(120, 40)
  assert list.length(wide) == 50
  assert list.length(medium) == 40
  assert list.length(narrow) == 24
  case host_bootstrap.getenv("LOOM_RAIL_RENDERS") {
    Ok(directory) -> {
      let assert Ok(Nil) = simplifile.create_directory_all(directory)
      list.each(
        [
          #("rail-200x50.txt", wide),
          #("rail-120x40-default.txt", medium),
          #("rail-120x40-docked.txt", docked),
          #("rail-120x40-changes.txt", changes),
          #("rail-80x24.txt", narrow),
        ],
        fn(entry) {
          let assert Ok(Nil) =
            simplifile.write(
              directory <> "/" <> entry.0,
              string.join(entry.1, "\n") <> "\n",
            )
        },
      )
    }
    Error(Nil) -> Nil
  }
}

// Twin sub-agents share a slug, so the strip's row shape tells them apart by
// the digest's head and cuts a long name in the middle. The rail draws that
// shape, so both twins are told apart at 120 columns beside the rail.
pub fn twins_in_the_rail_keep_the_part_that_tells_them_apart_test() {
  let base = scene()
  let twin = fn(digest: String) {
    agent(
      "sub:main/review-" <> digest,
      agent_view.Working,
      "Tracing publish_herdr",
    )
  }
  let model =
    Model(
      shared: shared_set.agent_rows(base.shared, [
        agent("main", agent_view.Working, "Waiting for reviewers"),
        twin("48f3a1b2c3d4e5f6"),
        twin("ec14a1b2c3d4e5f6"),
      ]),
      view: view_set.rail(base.view, Some(layout_memory.RailShown)),
    )
  let text = string.join(rows_of(model, 120, 40), "\n")
  assert string.contains(text, "review-48f3")
  assert string.contains(text, "review-ec14")
}

// One agent is a list the keyboard cannot enter, but it is still drawn with
// figures that move, so the clock keeps ticking for it.
pub fn a_single_agent_in_the_rail_is_still_drawn_and_ticked_test() {
  let base = scene()
  let one =
    Model(
      ..base,
      shared: shared_set.agent_rows(base.shared, [
        agent("main", agent_view.Working, "Working"),
      ]),
    )
  let docked = tui.update(backend.Resize(200, 50), one)
  assert layout.rail_lists_strands(docked)
  assert !layout.strands_listed(docked)
    as "one row has nothing for the cursor to enter"
  assert layout.agents_drawn(docked)
    as "but it is drawn, and its elapsed time moves with the clock"
}

// The changes in the rail have no border of their own: the tab is the title
// and the separator is the edge, so no `││` runs down the rail and no
// `captured changes` title repeats the tab.
pub fn the_changes_tab_has_no_inner_border_test() {
  let model = tui.update(backend.Resize(120, 40), scene())
  let opened = submit.open_diff(model)
  let rows = rows_of(opened, 120, 40)
  assert !list.any(list.take(rows, 30), string.contains(_, "││"))
    as "no panel border runs beside the separator above the input frame"
  assert !list.any(rows, string.contains(_, "captured changes"))
  assert string.contains(string.join(rows, "\n"), "Captured edits")
}

// Ctrl+g's accounting rows are compacted to the transcript's column, not the
// terminal's, so they are cut to fit beside the rail.
pub fn the_details_footer_is_compacted_to_the_column_test() {
  let docked =
    tui.update(backend.Resize(120, 40), scene())
    |> fn(model) { tui.update(backend.KeyPress("backtab"), model) }
  let expanded = tui.update(backend.KeyPress("ctrl+g"), docked)
  assert expanded.shared.details_expanded
  let rows = rows_of(expanded, 120, 40)
  assert layout.rail_columns(expanded) == 45
  // Every row keeps the rail's separator where it was.
  list.each(list.drop(rows, 1), fn(row) {
    assert string.slice(row, 75, 1) == "│"
      || string.slice(row, 74, 2) == "╮│"
      || string.slice(row, 74, 2) == "╯│"
  })
}
