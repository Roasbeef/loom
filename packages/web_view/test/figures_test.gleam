//// The session's figures, which the stream's strip draws: the context estimate,
//// the cost and the output speed.
////
//// These tests pin that a figure is a word and an emphasised number, that a
//// figure with no value is not drawn, that the speed's slot is kept before a
//// generation is timed, and that the context disclosure can be dismissed
//// without moving the panel's buttons.

import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/view/figures

fn drawn(context: String, cost: String, rate: option.Option(Int)) -> String {
  figures.view(context, element.none(), cost, rate) |> element.to_string
}

// The figures are a word and an emphasised number, and the cost no longer
// says `session`, which read as `session est $0.00`.
pub fn the_figures_emphasise_the_number_test() {
  let bar = drawn("ctx ~2%", "est $0.04", None)
  assert string.contains(bar, "ctx <span class=\"num\">~2%</span>")
  assert string.contains(bar, "est <span class=\"num\">$0.04</span>")
  assert !string.contains(bar, "session est")

  assert string.contains(
    bar,
    "title=\"Estimated context use of the strand shown. Open for the breakdown.\"",
  )
}

// A cost with qualifiers before the marker keeps them in the label, so the
// emphasised element holds only the amount.
pub fn a_qualified_cost_emphasises_only_the_amount_test() {
  let partial = drawn("ctx ~2%", "API ref partial est $1.00", None)
  assert string.contains(
    partial,
    "API ref partial est <span class=\"num\">$1.00</span>",
  )
  assert !string.contains(partial, "<span class=\"num\">ref")

  let mixed = drawn("ctx ~2%", "mixed rates est $2.10", None)
  assert string.contains(
    mixed,
    "mixed rates est <span class=\"num\">$2.10</span>",
  )
}

// The context disclosure carries the fixed mark `<loom-dismiss>` reads, and the
// element follows it as a sibling, so the panel's buttons keep their tree paths
// (`component.context_refresh_path`).
pub fn the_context_disclosure_can_be_dismissed_test() {
  let bar = drawn("ctx ~2%", "est $0.04", None)
  assert string.contains(bar, "data-dismiss=\"keep\"")
  assert string.contains(bar, "</details><loom-dismiss></loom-dismiss>")
}

// A model with no price has no estimate, and the strip does not draw a dash
// for it; the context figure is still drawn beside where it would have been.
pub fn an_unpriced_session_draws_no_estimate_test() {
  let unpriced = drawn("ctx ~2%", "est —", None)
  assert !string.contains(unpriced, "est ")
  assert !string.contains(unpriced, "No priced usage yet")
  assert string.contains(unpriced, "ctx <span class=\"num\">~2%</span>")
}

// A figure with no value is not drawn, so a first turn that has not
// committed shows no `ctx` and no `est` and not two dashes. Only the speed
// keeps its slot, which is why the figures area holds just that one.
pub fn a_figure_with_no_value_is_not_drawn_test() {
  let bar = drawn("", "est —", None)

  assert !string.contains(bar, "ctx")
  assert !string.contains(bar, "est")
  assert string.contains(bar, "class=\"figure rate idle\"")
}

// The output speed is drawn as the number and the unit once a generation has
// been timed. Before that the slot is kept with a dimmed dash, so the strip
// does not lose the item when a page opens, reconnects or focuses a strand
// with no sample (the cause of the owner's "tok/s disappears" report).
pub fn the_output_rate_slot_is_kept_before_a_generation_is_timed_test() {
  assert string.contains(
    drawn("", "", Some(87)),
    "<span class=\"num\">87</span> tok/s",
  )
  assert !string.contains(drawn("", "", Some(87)), "idle")

  let idle = drawn("", "", None)
  assert string.contains(idle, "<span class=\"num\">—</span> tok/s")
  assert string.contains(idle, "class=\"figure rate idle\"")
}
