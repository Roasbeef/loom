//// The memory context the daemon attaches to a run, as both pages draw it.
////
//// The daemon records distilled memory as a user message of its own ahead
//// of the owner's prompt. Drawn like a prompt it reads as the owner typing
//// twenty kilobytes at the start of every turn, so both pages fold it to
//// one line, `memory context (n lines)`, and hold the whole message as the
//// row's expansion (`<loom-expand>`). These tests check the folded line,
//// that the expansion still holds every digest line, and that the owner's
//// own prompt is drawn as before.

import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page

fn model() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.remembered()])
}

fn assert_folded(drawn: String) {
  // The compact slot holds the one-line summary, not the attribution.
  assert string.contains(drawn, "memory context (2 lines)")
  assert !string.contains(drawn, "[Ctrl+G to expand]")

  // The full slot holds the whole message, every digest line, escaped.
  assert string.contains(drawn, "slot=\"full\"")
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
