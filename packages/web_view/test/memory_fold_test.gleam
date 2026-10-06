//// The memory context the daemon attaches to a run, as both pages draw it.
////
//// The daemon records distilled memory as a user message of its own ahead
//// of the owner's prompt. Drawn like a prompt it reads as the owner typing
//// twenty kilobytes at the start of every turn, so both pages make it the
//// first step of the turn's fold, `Memory · n lines`, and hold the whole
//// message behind that line (`<loom-expand>`). These tests check the line,
//// that the body still holds every digest line, and that the owner's own
//// prompt is drawn as before.

import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page

fn model() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.remembered()])
  |> lane_fixture.opened
}

fn assert_folded(drawn: String) {
  // The row's line is `Memory · 2 lines`, the fold's first step, not the
  // attribution the daemon wrote.
  assert string.contains(
    drawn,
    "<span class=\"verb\">Memory</span><span class=\"figure\">· 2 lines</span>",
  )
  assert !string.contains(drawn, "memory context (2 lines)")
  assert !string.contains(drawn, "[Ctrl+G to expand]")

  // The body holds the whole message, every digest line, escaped.
  assert string.contains(drawn, "slot=\"body\"")
  assert string.contains(drawn, "the gate is make check")
  assert string.contains(drawn, "keep &lt;b&gt;R6&lt;/b&gt; portable")
  assert !string.contains(drawn, "<b>R6</b>")
  assert string.contains(drawn, "Distilled memory from this repository")

  // The owner's prompt is still a prompt.
  assert string.contains(drawn, "please run the gate")
}

pub fn the_observer_page_folds_the_memory_context_test() {
  assert_folded(element.to_string(component.view(model())))
}

pub fn the_operator_page_folds_the_memory_context_test() {
  assert_folded(element.to_string(operator_page.view(model())))
}
