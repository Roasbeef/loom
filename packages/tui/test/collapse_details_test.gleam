//// Shrinking the transcript clears the rows it stops using.
////
//// Toggling detail off is the one event that makes the rendered transcript
//// much shorter than it just was, and doing it from a scrolled position
//// moves the viewport as well as the content. A terminal client that
//// answered a shrink by drawing fewer rows and saying nothing about the
//// rest would leave the taller view's cells on screen — fragments of a
//// detail line at scattered columns below the last entry, which is what
//// issue #197 saw in the retired Go client.
////
//// Two properties keep that from happening here, and the check is written
//// against both. `refresh_render_cache` re-derives the wrapped rows and
//// re-clamps `scroll_offset` at the event boundary where
//// `details_expanded` changes, so the model never keeps an offset that
//// belongs to the taller rendering; and `render_frame` builds each frame
//// on a canvas it repaints in full, so a cell nobody draws into this frame
//// is blank rather than whatever the last frame left there. Neither is
//// visible from the outside, which is the reason to pin them from the
//// outside: the assertion is about the pane, not about either mechanism,
//// so it survives a change to how the repaint is arranged.

import etui/backend
import etui/buffer.{type Buffer}
import etui/geometry.{type Rect, Position}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/agents
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import tui_test/gateway

/// Collapsing detail from a scrolled transcript leaves no taller-view rows.
///
/// The premise is asserted before the property: with detail expanded and
/// the transcript scrolled back, every row of the pane carries a detail
/// line, so there is something for the collapse to leave behind. Then the
/// same run collapses, and the rows the shorter transcript does not reach
/// must be blank — not merely free of the marker, blank, because a stale
/// cell is a fragment of a row and not a whole one.
pub fn collapsing_details_repaints_the_rows_the_taller_view_used_test() {
  let scrolled = pane(list.flatten([traffic(), toggle_details(), scrollback()]))
  assert drawn_rows(scrolled) == list.length(scrolled.rows)
    as "premise: the expanded transcript occupies the whole pane, so a shrink has rows to vacate"
  assert list.any(scrolled.rows, shows_detail)
    as "premise: the scrolled pane is showing detail lines, not summaries"
  assert list.last(scrolled.rows) != Ok("")
    as "premise: the expanded transcript reaches the bottom row of the pane"

  let collapsed =
    pane(
      list.flatten([traffic(), toggle_details(), scrollback(), toggle_details()]),
    )
  assert !collapsed.model.details_expanded
    as "the second toggle put detail back"

  // The transcript draws its visible rows from the top of the pane, so the
  // collapsed view occupies exactly the first `drawn` of them and the rest
  // are nobody's. Both bounds are asserted: a collapsed transcript as tall
  // as the pane would leave no rows below it and the check would pass by
  // saying nothing.
  let drawn = drawn_rows(collapsed)
  assert drawn > 0 && drawn < list.length(collapsed.rows)
    as "the collapsed transcript must be shorter than the pane for this to check anything"
  assert list.all(list.drop(collapsed.rows, drawn), is_blank)
    as "a row below the collapsed transcript still held cells from the expanded one"

  // And the whole pane, not only its tail: a fragment can survive inside a
  // row the shorter view also writes to, past the end of what it wrote.
  assert !list.any(collapsed.rows, shows_detail)
    as "a detail line survived somewhere in the repainted pane"
  assert list.any(collapsed.rows, fn(row) { string.contains(row, "summary of") })
    as "the collapsed transcript rendered its summaries"
}

// The transcript pane of one finished run, beside the model that drew it.
type Pane {
  Pane(model: tui.Model, rows: List(String))
}

// Five failing tool results, each a summary line followed by twenty lines
// of detail. Collapsed, a result is its one truncated summary row;
// expanded, it is the tool name and every line, so the same transcript is
// ten rows in one mode and well over a hundred in the other. That gap is
// the repro: the pane has to shrink by more than it is tall.
fn traffic() -> List(virtual_backend.Step) {
  [
    deliver(gateway.full_snapshot("demo")),
    ..list.map(counting(1, 5), fn(index) {
      deliver(gateway.tool_result_entry("main", result_text(index), index))
    })
  ]
}

// The marker sits past the collapsed summary's truncation point, so it is
// on screen when and only when detail is expanded. The padding in front of
// it is what pushes it there.
fn result_text(index: Int) -> String {
  let label = int.to_string(index)
  let padding =
    counting(1, 20)
    |> list.map(fn(line) {
      "padding padding padding padding line " <> int.to_string(line)
    })
    |> string.join("\n")
  "summary of failure "
  <> label
  <> "\n"
  <> padding
  <> "\nexpanded-only-"
  <> label
}

fn toggle_details() -> List(virtual_backend.Step) {
  list.append(typed("/details"), [key("enter")])
}

// Three pages back into the expanded history, which is thirty rows: far
// enough that the pane is showing neither the head nor the tail of the
// taller rendering when detail goes away.
fn scrollback() -> List(virtual_backend.Step) {
  list.repeat(key("pageup"), 3)
}

// How many of the pane's rows the collapsed transcript actually draws.
// `render_transcript` drops the scroll offset from the newest-first rows
// and takes one pane's worth, so this is the same arithmetic read back off
// the model that performed it.
fn drawn_rows(pane: Pane) -> Int {
  let Pane(model:, rows:) = pane
  int.min(model.rendered_row_count - model.scroll_offset, list.length(rows))
}

fn shows_detail(row: String) -> Bool {
  string.contains(row, "expanded-only")
}

fn is_blank(row: String) -> Bool {
  row == ""
}

// One scripted run, read back as the interior rows of the transcript
// panel. The rows are taken from the frame by area rather than from the
// whole screen, because the border and the footer are painted every frame
// and would make a blank-row check pass on a pane full of debris.
fn pane(steps: List(virtual_backend.Step)) -> Pane {
  let inbox = connection.new_inbox()
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 96, height: 30),
      steps,
      inbox,
    )
  let assert Ok(run) = tui.run_script(quiet_model(inbox), script)
    as "the scripted backend cannot refuse to start"
  let assert Ok(last) = list.last(run.frames)
    as "every run draws at least its initial frame"

  // A point two cells in from the top left of the body lands in the
  // transcript interior at every size this test uses, and `hit_area`
  // answers with the same rectangle `render_transcript` drew into.
  let area = tui.hit_area(run.final, Position(2, 2))
  Pane(model: run.final, rows: area_rows(last, area))
}

fn area_rows(drawn: Buffer, area: Rect) -> List(String) {
  counting(area.position.y, area.size.height)
  |> list.map(fn(y) {
    frame.row_text(drawn, area.position.x, y, area.size.width)
  })
}

// A count of consecutive integers from a starting index, which is the
// shape a `Rect` gives us. `gleam/list` has no range in this toolchain, and
// `frame` keeps a private copy of the same walk for the same reason.
fn counting(start: Int, count: Int) -> List(Int) {
  counting_down(start, count - 1, [])
}

// Built from the last index backwards so the accumulator comes out in
// order without a reverse.
fn counting_down(start: Int, offset: Int, collected: List(Int)) -> List(Int) {
  case offset < 0 {
    True -> collected
    False -> counting_down(start, offset - 1, [start + offset, ..collected])
  }
}

fn typed(text: String) -> List(virtual_backend.Step) {
  text |> string.to_graphemes |> list.map(key)
}

fn key(name: String) -> virtual_backend.Step {
  virtual_backend.Input(backend.KeyPress(name))
}

fn deliver(payload: String) -> virtual_backend.Step {
  virtual_backend.Deliver(message: connection.Incoming(payload))
}

// The demo scaffolding removed, so the pane holds only what this module
// delivered and a leftover row can only have come from the expanded view.
fn quiet_model(inbox: Subject(connection.Message)) -> tui.Model {
  tui.Model(
    ..tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None)),
    transcript: [],
    strands: [],
    agent_summary: agents.summary([]),
    notice: "ready",
  )
}
