//// The transcript's vertical spacing and its left edge.
////
//// Two rules about where rows sit, both of them invisible from inside the
//// functions that place them and both easy to lose to an unrelated change,
//// so they are pinned from the pane the reader actually looks at.
////
//// The first is that consecutive tool rows are separated. A tool call owns
//// the rows under it — its patch, its output, a note excerpt — so
//// `render_line` closes none of the tool family with a blank of its own,
//// and without a deliberate spacer a run of successful commands arrived as
//// an undifferentiated block. The separation has to arrive without welding
//// a failed call away from the output that explains it, which is why both
//// halves are asserted in one run.
////
//// The second is that a message has one left edge. The speaker mark is a
//// heading of up to thirteen cells, and reapplying its whole width to every
//// later row indented a second paragraph, a list or a fence far in from the
//// margin while the first paragraph's own wrapped rows fell back to column
//// zero. Every row after the first now sits at the glyph's two-cell gutter,
//// whatever kind of block it belongs to.

import etui/backend
import etui/buffer.{type Buffer}
import etui/geometry.{type Rect, Position}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import tui
import tui/agents
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import tui_test/gateway

// The cells a row after a message's first is expected to be indented by.
const gutter = 2

// What the defect produced: the Assistant mark's own width, reapplied to
// every row of the body after the first.
const mark_width = 9

/// Two settled calls in one group are one blank row apart, and no more.
///
/// The group is deliberately mixed: the first call succeeded and is one
/// summary row, the second failed and is a summary row with its output
/// beneath it. That is what lets the same run assert both halves of the
/// rule — a blank between the groups, and no blank inside the failing one,
/// because a spacer placed by the wrong fold would separate a call from the
/// output that explains it.
pub fn consecutive_tool_calls_are_one_blank_row_apart_test() {
  let rows = transcript_rows(two_calls())
  let first = row_index(rows, "first-command")
  let failed = row_index(rows, "second-command")
  let output = row_index(rows, "exit status 1")

  assert failed == first + 2
    as "two settled calls must be separated by exactly one blank row"
  assert at(rows, first + 1) == ""
    as "the row between two calls must be blank, not another call's text"
  assert output == failed + 1
    as "a call's summary must stay adjacent to the output beneath it"
}

/// The heading still opens the group one blank row above the first call.
///
/// The heading closes itself with a blank of its own, so the spacer must be
/// placed above every call but the first. A fold that interspersed blindly
/// would show here as two blank rows under the heading.
pub fn the_activity_heading_keeps_its_one_row_gap_test() {
  let rows = transcript_rows(two_calls())
  let heading = row_index(rows, "Ctrl+g expands details")
  let first = row_index(rows, "first-command")

  assert first == heading + 2 as "the heading opens the group one row above it"
  assert at(rows, heading + 1) == "" as "that row is the heading's own blank"
}

/// Every row of a multi-block message shares one column under the glyph.
///
/// Prose, a top-level list item and a fenced line are three different block
/// kinds reaching the wrapper by three different paths, so the check names
/// all three rather than trusting one to stand for the rest. The nested
/// item is the control: it is expected to be two cells further in, which is
/// the list's own nesting measured from the gutter and not a second left
/// edge.
pub fn a_multi_block_message_keeps_one_left_edge_test() {
  let rows = transcript_rows(said(document()))

  assert indent_of(rows, "opening paragraph") == 0
    as "row zero carries the whole speaker mark"
  assert indent_of(rows, "top level item") == gutter
    as "a top-level list item sits at the glyph's gutter"
  assert indent_of(rows, "nested item") == gutter + 2
    as "a nested item is the list's own two cells further in"
  assert indent_of(rows, "let answer = 1") == gutter
    as "a fenced row sits at the gutter like every other block"

  // And the general rule behind the four: nothing in the body hangs at the
  // mark's own width, whichever block it came from.
  list.each(body_rows(rows), fn(row) {
    assert indent(row) < mark_width
      as { "a body row hangs at the label's width: " <> row }
  })
}

/// A wrapped paragraph's continuation rows sit at the gutter too.
///
/// This is the half the old order could not reach: the first logical line
/// carried the mark and therefore no leading whitespace, so the wrapper that
/// ran after the prefix had nothing to re-apply and dropped the overflow to
/// column zero. One paragraph is enough to see it, and the pane is narrow
/// enough that the sentence cannot fit on one row.
pub fn a_wrapped_paragraph_continues_at_the_gutter_test() {
  let rows = transcript_rows(said(long_sentence()))
  let wrapped = body_rows(rows)

  assert wrapped != []
    as "premise: the sentence is wider than the pane, so it has continuations"
  list.each(wrapped, fn(row) {
    assert indent(row) == gutter
      as { "a continuation row left the gutter: " <> row }
  })
}

/// A paragraph and the call beneath it in one response are one row apart.
///
/// This is the half of the rule the separation can get wrong in the other
/// direction. A paragraph closes itself with a blank already, so a spacer
/// placed above every group without looking up would draw the gap twice and
/// push the call a row further from the prose that introduced it than a
/// reader of `main` ever saw.
pub fn prose_and_the_call_below_it_are_one_blank_row_apart_test() {
  let rows = transcript_rows(narrated_call())
  let prose = row_index(rows, "so here is the command")
  let call = row_index(rows, "third-command")

  assert call == prose + 2
    as "a paragraph's own trailing blank is the only gap above the call"
  assert at(rows, prose + 1) == "" as "that one row is blank"
}

/// Two note-bodied calls in a group are one blank row apart.
///
/// A call whose value the transcript renders as Markdown — `agent_note` here,
/// `remember` and `agent_send` by the same path — ends in a detail row, and a
/// detail row closes itself with a blank. So this is the group boundary where
/// a one-sided rule doubles the gap, and the bare summary rows of
/// `consecutive_tool_calls_are_one_blank_row_apart_test` cannot see it.
pub fn consecutive_note_bodies_are_one_blank_row_apart_test() {
  let rows = transcript_rows(two_notes())

  // The call summary folds the arguments away, so the note value reaches
  // the pane only as the rendered body beneath it.
  let body = row_index(rows, "alphanote")

  assert at(rows, body + 1) == "" as "the note body closes with its own blank"
  assert row_index(rows, "betanote") == body + 3
    as "the second call and its body follow that one blank, with no second"
}

/// Expanded history separates one call from the next, and only there.
///
/// In this view a response carrying a call and the entry carrying its result
/// are separate entries, and both close bare, so the gap between one call and
/// the next is nobody's trailing blank. The failing call is the control: its
/// output arrives as a `ToolFailure` row opening its own entry, and a rule
/// that read that row as the start of a new group would separate a call from
/// its own outcome.
pub fn expanded_history_separates_calls_but_not_outcomes_test() {
  let rows = transcript_rows(expanded_calls())
  let first = row_index(rows, "first-command")
  let output = row_index(rows, "result-output")
  let second = row_index(rows, "second-command")
  let failure = row_index(rows, "failure-output")

  assert output == first + 2
    as "a call's result must stay adjacent to the call it answers"
  assert second == output + 2
    as "a settled call and the next call are exactly one blank row apart"
  assert at(rows, second - 1) == "" as "that row between them is blank"
  assert failure == second + 2
    as "a failed result must stay adjacent to the call it answers"
}

// --- fixtures --------------------------------------------------------------

// One assistant turn per call, each answered by its own result, which is the
// shape `tool_activity` folds into a single group of two rows. The call IDs
// differ because a repeated ID ends a group rather than extending it.
fn two_calls() -> Pane {
  let model = quiet_model(connection.new_inbox(), Compact)
  let steps = [
    deliver(gateway.full_snapshot("demo")),
    deliver(gateway.identified_tool_call_entry(
      "main",
      "call-a",
      "bash",
      "first-command",
      1,
    )),
    deliver(gateway.identified_tool_result_ok_entry("main", "call-a", "ok", 2)),
    deliver(gateway.identified_tool_call_entry(
      "main",
      "call-b",
      "bash",
      "second-command",
      3,
    )),
    deliver(gateway.identified_tool_failure_entry(
      "main",
      "call-b",
      "exit status 1",
      4,
    )),
  ]
  run(model, steps)
}

// One response whose prose and call arrive together. A response carrying
// prose is a narrative rather than a member of an activity group, so its
// blocks are separated where the message itself is rendered.
fn narrated_call() -> Pane {
  let model = quiet_model(connection.new_inbox(), Compact)
  let steps = [
    deliver(gateway.full_snapshot("demo")),
    deliver(gateway.narrated_tool_call_entry(
      "main",
      "call-c",
      "so here is the command",
      "third-command",
      1,
    )),
  ]
  run(model, steps)
}

// Two `agent_note` calls, each settled, which group together and each end in
// a rendered note body rather than a bare summary row.
fn two_notes() -> Pane {
  let model = quiet_model(connection.new_inbox(), Compact)
  let steps = [
    deliver(gateway.full_snapshot("demo")),
    deliver(gateway.note_call_entry("main", "note-a", "alphanote", 1)),
    deliver(gateway.identified_tool_result_ok_entry("main", "note-a", "ok", 2)),
    deliver(gateway.note_call_entry("main", "note-b", "betanote", 3)),
    deliver(gateway.identified_tool_result_ok_entry("main", "note-b", "ok", 4)),
  ]
  run(model, steps)
}

// The same call-and-answer traffic drawn with details expanded, where every
// call and every result is its own durable entry and nothing folds them into
// a group. The second call fails, so the run carries both outcomes.
fn expanded_calls() -> Pane {
  let model = quiet_model(connection.new_inbox(), Expanded)
  let steps = [
    deliver(gateway.full_snapshot("demo")),
    deliver(gateway.identified_tool_call_entry(
      "main",
      "call-a",
      "bash",
      "first-command",
      1,
    )),
    deliver(gateway.identified_tool_result_ok_entry(
      "main",
      "call-a",
      "result-output",
      2,
    )),
    deliver(gateway.identified_tool_call_entry(
      "main",
      "call-b",
      "bash",
      "second-command",
      3,
    )),
    deliver(gateway.identified_tool_failure_entry(
      "main",
      "call-b",
      "failure-output",
      4,
    )),
  ]
  run(model, steps)
}

// A message whose body is rendered straight from the model, which is the
// shortest path to the prefixing this file is about: no provider, no
// grouping, one durable line.
fn said(text: String) -> Pane {
  let model =
    tui.Model(..quiet_model(connection.new_inbox(), Compact), transcript: [
      tui.Line(tui.Assistant, text),
    ])
  run(model, [])
}

// Three block kinds in one message, with a nested item under the first.
fn document() -> String {
  "opening paragraph\n\n- top level item\n  - nested item\n\n```gleam\nlet answer = 1\n```"
}

// Long enough to wrap several times in this pane, and written so no single
// word can be mistaken for the row that carries the mark.
fn long_sentence() -> String {
  "the harness renders one paragraph of continuous prose which is wider than "
  <> "the pane it is drawn into and therefore has to be broken across several "
  <> "rows before the reader can see the end of it"
}

// --- reading the pane ------------------------------------------------------

// The transcript pane's interior rows, oldest first, with the blank rows
// below the content dropped: the tail of an unfilled pane says nothing about
// spacing and would let a rule about blank rows pass by accident. The rows
// are taken from the pane's own rectangle rather than the whole screen, so
// the border and the footer cannot answer a search for a row.
fn transcript_rows(pane: Pane) -> List(String) {
  pane.rows
  |> list.reverse
  |> list.drop_while(fn(row) { row == "" })
  |> list.reverse
}

// Every row of a message's body: what is left once the row carrying the
// speaker mark, and the blank rows around the block, are gone.
fn body_rows(rows: List(String)) -> List(String) {
  rows
  |> list.drop_while(fn(row) { !string.contains(row, "Agent") })
  |> list.drop(1)
  |> list.filter(fn(row) { row != "" })
}

fn row_index(rows: List(String), needle: String) -> Int {
  let assert [index, ..] = matching_rows(rows, needle)
    as { "the pane never drew a row containing " <> needle }
  index
}

fn matching_rows(rows: List(String), needle: String) -> List(Int) {
  rows
  |> list.index_map(fn(row, index) { #(row, index) })
  |> list.filter(fn(pair) { string.contains(pair.0, needle) })
  |> list.map(fn(pair) { pair.1 })
}

// A row past the end of the pane reads as blank, which is what an unfilled
// pane would have drawn there anyway.
fn at(rows: List(String), index: Int) -> String {
  rows |> list.drop(index) |> list.first |> result.unwrap("")
}

fn indent_of(rows: List(String), needle: String) -> Int {
  indent(at(rows, row_index(rows, needle)))
}

fn indent(row: String) -> Int {
  string.length(row) - string.length(string.trim_start(row))
}

// --- harness ---------------------------------------------------------------

// The transcript pane of one finished run.
type Pane {
  Pane(rows: List(String))
}

// One scripted run on a pane narrow enough to wrap prose and wide enough to
// hold a tool summary. A point two cells in from the top left of the body
// lands in the transcript interior at this size, and `hit_area` answers with
// the same rectangle the transcript was drawn into.
fn run(model: tui.Model, steps: List(virtual_backend.Step)) -> Pane {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 60, height: 30),
      steps,
      model.inbox,
    )
  let assert Ok(finished) = tui.run_script(model, script)
    as "the scripted backend cannot refuse to start"
  let assert Ok(last) = list.last(finished.frames)
    as "every run draws at least its initial frame"

  Pane(rows: area_rows(last, tui.hit_area(finished.final, Position(2, 2))))
}

fn area_rows(drawn: Buffer, area: Rect) -> List(String) {
  counting(area.position.y, area.size.height)
  |> list.map(fn(y) {
    frame.row_text(drawn, area.position.x, y, area.size.width)
  })
}

// `gleam/list` has no range in this toolchain, and the pane is described by
// a `Rect`, so the walk is written out here as it is in its neighbours.
fn counting(start: Int, count: Int) -> List(Int) {
  counting_down(start, count - 1, [])
}

fn counting_down(start: Int, offset: Int, collected: List(Int)) -> List(Int) {
  case offset < 0 {
    True -> collected
    False -> counting_down(start, offset - 1, [start + offset, ..collected])
  }
}

fn deliver(payload: String) -> virtual_backend.Step {
  virtual_backend.Deliver(message: connection.Incoming(payload))
}

// The demo scaffolding removed, so every row in the pane was put there by
// this module.
fn quiet_model(
  inbox: Subject(connection.Message),
  view: TranscriptView,
) -> tui.Model {
  tui.Model(
    ..tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None)),
    transcript: [],
    strands: [],
    agent_summary: agents.summary([]),
    notice: "ready",
    details_expanded: case view {
      Compact -> False
      Expanded -> True
    },
  )
}

// Which of the two transcript views a scripted run is drawn in. They place
// the same blank at different boundaries — compact between the calls of one
// activity group, expanded between one durable entry and the next — so a
// spacing rule has to be pinned in whichever view owns the boundary.
type TranscriptView {
  Compact

  Expanded
}
