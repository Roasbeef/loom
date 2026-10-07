//// The todo panel on both pages: the strand's board with the phase that
//// holds the active task expanded and the others folded, the terminal's
//// status glyphs, the `n/m done` count, and the reviewer band beside it.
////
//// The first group draws `view/todo_panel` from plain values, which is the
//// module's whole contract. The second drives a page through a capture whose
//// `main` carries a `todo` result and reads the HTML the browser would
//// receive, on the operator's page and the observer's, so the panel's
//// place in the dock and above the observer's bar is pinned too.

import core/todo_list.{
  type Board, Active, Blocked, Board, Done, Dropped, Pending, Phase, Task,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/view/todo_panel

fn board() -> Board {
  Board([
    Phase("Design", [Task("Read the spec", Done), Task("Sketch it", Dropped)]),
    Phase("Build", [
      Task("Write the view", Done),
      Task("Wire the dock", Active),
      Task("Add tests", Pending),
      Task("Ship <b>it</b>", Blocked(Some("needs <i>review</i>"))),
    ]),
    Phase("Verify", [Task("Run the gate", Pending), Task("Hand check", Pending)]),
  ])
}

fn drawn(board, lines) -> String {
  element.to_string(todo_panel.view(board, lines))
}

fn has(haystack: String, needles: List(String)) -> Bool {
  list.all(needles, string.contains(haystack, _))
}

pub fn no_board_and_no_reviewer_draws_nothing_test() {
  assert !string.contains(drawn(None, []), "todo-panel")
}

pub fn a_board_with_no_phase_draws_nothing_test() {
  assert !string.contains(drawn(Some(Board([])), []), "todo-panel")
}

pub fn the_focused_phase_is_expanded_with_the_terminals_glyphs_test() {
  let html = drawn(Some(board()), [])

  // The active task's phase is the one drawn, with every task in it, in the
  // order the agent wrote them, each with its glyph and its status.
  assert has(html, [
    "<span class=\"todo-phase\">Build</span>",
    "<li class=\"todo-task todo-done\">",
    "<li class=\"todo-task todo-active\">",
    "<li class=\"todo-task todo-pending\">",
    "<li class=\"todo-task todo-blocked\">",
    ">✓<",
    ">▸<",
    ">○<",
    ">⊘<",
    "Write the view",
    "Wire the dock",
    "Add tests",
  ])
  assert !string.contains(html, "Read the spec")
  assert !string.contains(html, "Run the gate")
  assert string.contains(html, "aria-hidden=\"true\"")
  assert string.contains(html, "active: ")
}

pub fn a_dropped_task_has_its_own_glyph_test() {
  let html =
    drawn(
      Some(
        Board([Phase("Only", [Task("Drop me", Dropped), Task("Keep", Active)])]),
      ),
      [],
    )
  assert has(html, ["todo-dropped", ">–<", "Drop me"])
}

pub fn the_counts_are_the_terminals_test() {
  let html = drawn(Some(board()), [])

  // Design's two tasks are closed (a dropped task counts as closed) and so
  // is Build's first, so three of eight are done; the focused phase has one
  // of its four.
  assert has(html, [
    "<span class=\"todo-quiet\">1/4</span>",
    "<span class=\"todo-total\">3/8 done</span>",
  ])
}

pub fn the_board_is_one_collapsed_line_over_a_fold_test() {
  let html = drawn(Some(board()), [])

  // The line is the fold's summary: the label, the closed count over every
  // phase, and the active task's text. The board is the fold's other child,
  // so a closed fold shows the line alone.
  assert in_order(html, [
    "<loom-fold class=\"todo-fold\">",
    "slot=\"summary\"",
    "Todo",
    " · 3 of 8 done",
    "<span class=\"todo-current\">Wire the dock</span>",
    "<div class=\"todo-detail\">",
    "todo-tasks",
    "</loom-fold>",
  ])
}

pub fn a_board_with_no_active_task_says_only_the_count_test() {
  let html =
    drawn(
      Some(Board([Phase("Later", [Task("a", Pending), Task("b", Done)])])),
      [],
    )
  assert string.contains(html, " · 1 of 2 done")
  assert !string.contains(html, "todo-current")
}

pub fn the_active_task_in_the_line_is_text_only_test() {
  let html =
    drawn(Some(Board([Phase("P", [Task("Fix <b>it</b>", Active)])])), [])
  assert string.contains(
    html,
    "<span class=\"todo-current\">Fix &lt;b&gt;it&lt;/b&gt;</span>",
  )
  assert !string.contains(html, "<b>")
}

pub fn a_finished_board_and_the_band_are_not_folded_test() {
  let finished =
    drawn(Some(Board([Phase("One", [Task("a", Done)])])), ["Reviewer x"])
  assert !string.contains(finished, "loom-fold")

  let banded = drawn(Some(board()), ["Reviewer x"])
  let assert Ok(#(_, band)) = string.split_once(banded, "</loom-fold>")
  assert string.contains(band, "todo-reviewers")
}

pub fn the_other_phases_fold_into_one_row_test() {
  let html = drawn(Some(board()), [])
  assert string.contains(
    html,
    "<p class=\"todo-others\">Design ✓ · Verify 0/2</p>",
  )
}

pub fn a_single_phase_has_no_folded_row_test() {
  let html = drawn(Some(Board([Phase("Only", [Task("Do it", Active)])])), [])
  assert !string.contains(html, "todo-others")
}

pub fn a_board_of_blocked_work_focuses_the_phase_that_needs_attention_test() {
  let html =
    drawn(
      Some(
        Board([
          Phase("Done", [Task("a", Done)]),
          Phase("Waiting", [Task("b", Blocked(None))]),
        ]),
      ),
      [],
    )
  assert has(html, ["<span class=\"todo-phase\">Waiting</span>", "todo-blocked"])
}

pub fn a_finished_board_leaves_the_dock_test() {
  let html =
    drawn(
      Some(
        Board([
          Phase("One", [Task("a", Done)]),
          Phase("Two", [Task("b", Done), Task("c", Dropped)]),
        ]),
      ),
      [],
    )
  assert !string.contains(html, "todo-line")
  assert !string.contains(html, "todo-panel")
  assert !string.contains(html, "done")
}

pub fn session_text_is_only_ever_a_text_node_test() {
  let html = drawn(Some(board()), [])
  assert has(html, [
    "Ship &lt;b&gt;it&lt;/b&gt;",
    " · needs &lt;i&gt;review&lt;/i&gt;",
  ])
  assert !string.contains(html, "<b>")
  assert !string.contains(html, "<i>")
}

pub fn a_reviewer_band_alone_is_still_drawn_test() {
  let html =
    drawn(None, [
      "Reviewer advisor · generating · no pending input",
      "  Task: check the plan",
    ])
  assert has(html, [
    "<section aria-label=\"Plan and reviewers\" class=\"todo-panel\">",
    "<div class=\"todo-reviewers\">",
    "<p>Reviewer advisor · generating · no pending input</p>",
    "<p>  Task: check the plan</p>",
  ])
  assert !string.contains(html, "todo-board")
}

pub fn the_band_sits_after_the_board_test() {
  let html =
    drawn(Some(board()), ["Reviewer advisor · running · no pending input"])
  let assert Ok(#(before, after)) =
    string.split_once(html, "<div class=\"todo-reviewers\">")
  assert string.contains(before, "todo-board")
  assert string.contains(after, "Reviewer advisor")
}

// --- on the pages ---------------------------------------------------------------

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

pub fn a_page_with_no_board_draws_no_panel_test() {
  let model = page([lane_fixture.captured(10, None)])

  // The fixture's reviewers are running, so its band shows; a page with no
  // board and none running shows nothing of the panel at all.
  let quiet = page([lane_fixture.planned([Board([])], [])])
  assert !string.contains(operator(quiet), "todo-panel")
  assert !string.contains(observer(quiet), "todo-panel")
  assert !string.contains(operator(model), "todo-board")
}

pub fn the_operators_dock_holds_the_board_above_the_composer_test() {
  let html = operator(page([lane_fixture.planned([board()], [])]))
  assert in_order(html, [
    "<footer class=\"dock\">",
    "todo-panel",
    "todo-phase",
    "Wire the dock",
    "<form",
  ])
  assert string.contains(html, "3/8 done")
}

pub fn the_observers_panel_is_above_its_bar_and_below_the_lane_test() {
  let html = observer(page([lane_fixture.planned([board()], [])]))
  assert in_order(html, [
    "<loom-follow",
    "todo-panel",
    "Wire the dock",
    "<p class=\"observer-bar\">",
  ])
  assert string.contains(html, "3/8 done")
}

pub fn a_running_reviewer_draws_the_band_on_both_pages_test() {
  let model =
    page([
      lane_fixture.planned([board()], [
        #(lane_fixture.child, lane_fixture.review_op()),
      ]),
    ])

  // The strand's name is session text and holds markup: it arrives escaped.
  assert has(operator(model), [
    "todo-reviewers",
    "Sub-agent &lt;b&gt;review",
  ])
  assert has(observer(model), ["todo-reviewers", "Task:"])
  assert !string.contains(operator(model), "<b>review")
}

pub fn the_newest_board_of_a_capture_is_the_one_drawn_test() {
  let newer =
    Board([
      Phase("Later", [Task("Finish it", Active), Task("Then rest", Pending)]),
    ])
  let html = operator(page([lane_fixture.planned([board(), newer], [])]))
  assert has(html, ["Later", "Finish it", "0/2 done"])
  assert !string.contains(html, "Wire the dock")
}

// A later capture whose window no longer reaches the `todo` call keeps the
// board, as the terminal's pinned panel does.
pub fn a_later_capture_without_a_todo_call_keeps_the_board_test() {
  let html =
    operator(
      page([
        lane_fixture.planned([board()], []),
        lane_fixture.answered(["one", "two", "three", "four"]),
      ]),
    )
  assert has(html, ["Wire the dock", "3/8 done"])
}

pub fn the_line_follows_the_strand_the_page_shows_test() {
  let model = page([lane_fixture.planned([board()], [])])
  assert string.contains(operator(model), "3 of 8 done")
  assert string.contains(observer(model), "3 of 8 done")

  // The board belongs to `main`. Focusing the strand that has none draws no
  // line, and focusing `main` again draws it.
  let away =
    page_fixture.run(model, component.update, [
      component.FocusRequested(lane_fixture.child),
    ])
  assert component.strand(away) == lane_fixture.child
  assert !string.contains(operator(away), "todo-line")
  let back =
    page_fixture.run(away, component.update, [
      component.FocusRequested(component.primary),
    ])
  assert string.contains(operator(back), "3 of 8 done")
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

// A board whose tasks are all closed draws nothing, but a reviewer running
// beside it is still the dock's to show.
pub fn a_finished_board_leaves_a_reviewer_band_alone_test() {
  let html =
    drawn(Some(Board([Phase("One", [Task("a", Done), Task("b", Done)])])), [
      "reviewer-1 · running",
    ])
  assert string.contains(html, "todo-reviewers")
  assert !string.contains(html, "todo-line")
  assert !string.contains(html, "2 of 2")
}
