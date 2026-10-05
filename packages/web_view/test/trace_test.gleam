//// The Trace tab: the session's `code_mode` programs, drawn on both pages
//// from the records the page holds.
////
//// The first group draws `view/trace` from a trace, which is the module's
//// whole contract: the heading, the newest program first with its state,
//// excerpt and collapsed Budget, the earlier ones under it, the line saying
//// capability calls are not recorded, and every string arriving as escaped
//// text with no handler. The second drives the pages through a capture and
//// pins the pane's place in the strand panel: the fourth pane, after Session
//// and before the nudges, so the Strands and Session panes' paths do not move.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/trace_view
import web_view/component
import web_view/operator_page
import web_view/view/trace

fn drawn(trace: trace_view.Trace) -> String {
  element.to_string(trace.view(trace))
}

fn program(state: trace_view.State, label: String) -> trace_view.Program {
  trace_view.Program(
    state:,
    label:,
    excerpt: Some("done"),
    within_ms: Some(30_000),
    vetting: trace_view.Passed,
    sandbox: Some(
      "sandbox · build enforced 4 layers; skipped 0 · satellite enforced 4 layers; skipped 0",
    ),
    detail: None,
    calls: [],
  )
}

pub fn no_program_draws_the_heading_and_a_line_saying_so_test() {
  let html = drawn(trace_view.empty())

  assert string.contains(html, "pane pane-trace")
  assert string.contains(html, "Trace</h2>")
  assert string.contains(html, "No program yet.")
  assert !string.contains(html, "trace-latest")
}

pub fn the_newest_program_leads_and_the_earlier_ones_follow_test() {
  let html =
    drawn(trace_view.Trace(
      programs: [
        program(trace_view.Failed, "first.gleam"),
        program(trace_view.Completed, "second.gleam"),
        program(trace_view.Running, "third.gleam"),
      ],
      omitted: 2,
    ))

  assert in_order(html, [
    "trace-latest",
    "third.gleam",
    "trace-running",
    "running",
    "Budget · 30 s",
    "Earlier",
    "second.gleam",
    "trace-completed",
    "first.gleam",
    "trace-failed",
    "2 older programs not shown",
    "No calls recorded.",
  ])
  assert !string.contains(html, "satellite")
    as "the sandbox line is the Session tab's"
  assert !string.contains(html, "vetted")
}

// A program that did not compile shows the compiler's diagnostics and never
// the sentence the result carries for the model.
pub fn a_failed_program_shows_its_diagnostics_not_the_models_instructions_test() {
  let failed =
    trace_view.Program(
      ..program(trace_view.CompileFailed, "broken.gleam"),
      excerpt: Some(
        "the program did not compile and did not run. Fix the diagnostics below; warnings also fail the build: error: unknown module",
      ),
      detail: Some(
        "error: unknown module\n  cap/nope\nhint: check imports\nmore",
      ),
      within_ms: None,
    )
  let html = drawn(trace_view.Trace(programs: [failed], omitted: 0))

  assert string.contains(html, "compile failed")
  assert string.contains(html, "error: unknown module")
  assert string.contains(html, "<details class=\"trace-diagnostic\">")
  assert !string.contains(html, "Fix the diagnostics")
  assert !string.contains(html, "warnings also fail")
  assert string.contains(html, "Budget · default")
  assert !string.contains(html, "default wall budget")

  let refused =
    trace_view.Program(
      ..program(trace_view.Rejected, "vetoed.gleam"),
      excerpt: Some("refused; fix the program and submit it again."),
      detail: Some("import os is not allowed"),
    )
  let html = drawn(trace_view.Trace(programs: [refused], omitted: 0))
  assert string.contains(html, "import os is not allowed")
  assert !string.contains(html, "submit it again")

  let bare =
    trace_view.Program(..failed, detail: None)
    |> fn(program) { drawn(trace_view.Trace(programs: [program], omitted: 0)) }
  assert !string.contains(bare, "Fix the diagnostics")
}

pub fn a_label_and_an_excerpt_are_only_ever_text_nodes_test() {
  let hostile = "<img src=x onerror=alert(1)> \" onmouseover=\"x\""
  let html =
    drawn(trace_view.Trace(
      programs: [
        trace_view.Program(
          state: trace_view.Completed,
          label: hostile,
          excerpt: Some(hostile),
          within_ms: None,
          vetting: trace_view.Passed,
          sandbox: None,
          detail: None,
          calls: ["CALLS · 1 call · 1 failed", "× " <> hostile],
        ),
      ],
      omitted: 0,
    ))

  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "onmouseover=\"x\"")
  assert string.contains(html, "trace-call") as "the call row is drawn, as text"
  assert string.contains(html, "Budget · default")
}

pub fn the_view_carries_no_handler_test() {
  let html =
    drawn(trace_view.Trace(
      programs: [program(trace_view.Completed, "a.gleam")],
      omitted: 0,
    ))
  assert !string.contains(html, "data-lustre-on")
}

// --- on the pages ---------------------------------------------------------------

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

pub fn a_page_with_no_program_draws_the_empty_pane_test() {
  let model = page([lane_fixture.captured(10, None)])
  list.each([operator(model), observer(model)], fn(html) {
    assert string.contains(html, "No program yet.")
  })
}

// The pane is the panel's fourth child: after Session and before the
// advisor's nudges, so nothing in the Strands or Session panes moves.
pub fn both_pages_draw_the_pane_after_session_test() {
  let model =
    page([lane_fixture.traced("// count functions\npub fn main() { 3 }", "3")])

  assert in_order(operator(model), [
    "<aside aria-label=\"Strand panel\"",
    "pane pane-strands",
    "pane pane-changes",
    "pane pane-session",
    "pane pane-trace",
    "Program 2",
    "running",
    "Earlier",
    "count functions",
    "completed",
  ])
  assert in_order(observer(model), [
    "<aside aria-label=\"Strand panel\"",
    "pane pane-session",
    "pane pane-trace",
    "Program 2",
  ])
}

pub fn the_centre_column_holds_no_trace_test() {
  let model = page([lane_fixture.traced("pub fn main() { 3 }", "3")])
  list.each([operator(model), observer(model)], fn(html) {
    let assert Ok(#(centre, _)) =
      string.split_once(html, "<aside aria-label=\"Strand panel\"")
    assert !string.contains(centre, "pane-trace")
  })
}

fn in_order(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> True
    [needle, ..rest] ->
      case string.split_once(haystack, needle) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}
