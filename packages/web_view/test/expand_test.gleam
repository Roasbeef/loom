//// Expanding a row on the page, as `Ctrl+g` does in the terminal.
////
//// A call and a reasoning block that have more to show than the lane's
//// compact rows are drawn as a `<loom-expand>` holding both, and a row with
//// nothing more is drawn as before. The expanded text is session text, so it
//// arrives only as a text node, and it is cut to a budget
//// (`web_view/view/expansion`). These tests read the HTML the browser would
//// receive, on both pages; the toggling itself is the browser's.

import gleam/int
import gleam/list
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/transcript_line.{Line, Reasoning, System, ToolDetail}
import web_view/component
import web_view/operator_page
import web_view/view/expansion

fn program() -> String {
  list.repeat(Nil, 12)
  |> list.index_map(fn(_, n) {
    "let a" <> int.to_string(n + 1) <> " = <x" <> int.to_string(n + 1) <> ">"
  })
  |> string.join("\n")
}

fn model(update) {
  component.new(page_fixture.start())
  |> component.apply([update])
  |> lane_fixture.opened
}

fn observer(update) -> String {
  model(update)
  |> component.view
  |> element.to_string
  |> string.replace("<!-- lustre:memo -->", "")
}

fn operator(update) -> String {
  model(update)
  |> operator_page.view
  |> element.to_string
  |> string.replace("<!-- lustre:memo -->", "")
}

pub fn a_code_mode_call_expands_to_its_whole_program_test() {
  let drawn = observer(lane_fixture.programmed(program(), "the output"))

  // The step is one line, `code_mode`, with the program behind it: the line
  // is the head slot and the whole program, as escaped text, is the body.
  assert string.contains(drawn, "class=\"expand step done\">")
  assert string.contains(drawn, "slot=\"head\"")
  assert string.contains(drawn, "slot=\"body\"")
  assert string.contains(drawn, "a12 = &lt;x12&gt;")
  assert !string.contains(drawn, "<x12>")
  assert string.contains(drawn, "the output")
}

pub fn reasoning_expands_to_the_whole_block_test() {
  let drawn = observer(lane_fixture.programmed("1", "1"))
  assert string.contains(drawn, "first &lt;idea&gt;")
  assert string.contains(drawn, "third")
}

pub fn the_operators_page_draws_the_same_expanders_test() {
  let drawn = operator(lane_fixture.programmed(program(), "the output"))
  assert string.contains(drawn, "class=\"expand step done\">")
  assert string.contains(drawn, "a12 = &lt;x12&gt;")
}

pub fn a_row_with_nothing_more_to_show_has_no_expander_test() {
  let drawn = observer(lane_fixture.answered(["short answer"]))
  assert !string.contains(drawn, "loom-expand")
}

pub fn the_expanded_text_is_cut_to_the_budget_and_says_so_test() {
  let many =
    list.index_map(list.repeat(Nil, expansion.max_lines + 50), fn(_, n) {
      Line(ToolDetail, "row " <> int.to_string(n))
    })
  let kept = expansion.capped(many)
  assert list.length(kept) == expansion.max_lines + 1
  assert list.last(kept) == Ok(Line(System, expansion.notice()))
}

pub fn one_long_line_is_cut_by_characters_test() {
  let long = string.repeat("é", expansion.max_characters + 500)
  let assert [Line(Reasoning, cut), Line(System, _)] =
    expansion.capped([Line(Reasoning, long)])
    as "one cut line and the notice"
  assert string.length(cut) == expansion.max_characters
}

pub fn text_within_the_budget_is_left_alone_test() {
  let lines = [Line(ToolDetail, "a\nb"), Line(Reasoning, "c")]
  assert expansion.capped(lines) == lines
}
