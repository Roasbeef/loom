//// The footer shows its figures whole or not at all. The detailed row used
//// to end in `cac…` whenever the cache outlook was present, cutting the
//// cache read/write pair the expanded footer exists to show; these tests
//// pin the fitting rule and paint both footers with realistic numbers.

import core/message
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/render
import tui/transcript_lines
import tui/workspace

fn usage() -> message.Usage {
  message.Usage(
    input: 812_000,
    output: 86_000,
    cache_read: 1_200_000,
    cache_write: 40_000,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 2_138_000,
    cost: message.UsageCost(1.1, 2.2, 0.3, 0.4, 4.0),
  )
}

fn model() {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
  |> fn(base) {
    tui_model.Model(
      ..base,
      usage: usage(),
      cache_outlook: "cache idle 3m",
      output_rate_tps: Some(45),
      notice: "",
    )
  }
}

fn footer_rows(model, width) -> List(String) {
  let model = tui.update(backend.Resize(width, 30), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, width, 30))
  frame.buffer_to_text(buffer)
  |> string.split("\n")
  |> list.reverse
  |> list.take(4)
}

pub fn pieces_fit_whole_or_not_at_all_test() {
  assert render.fit_pieces(["ctx ~5%", "est $0.00", "in 812k"], 20)
    == "ctx ~5% · est $0.00"
  assert render.fit_pieces(["ctx ~5%", "est $0.00"], 100)
    == "ctx ~5% · est $0.00"
  assert render.fit_pieces([], 10) == ""

  // A first piece wider than the whole section is cut rather than dropped,
  // since an empty section says less than a truncated one.
  assert render.fit_pieces(["a long first piece"], 8) == "a long …"

  // The order is the priority: a later short piece never jumps a dropped one.
  assert render.fit_pieces(["abc", "a much longer piece", "x"], 10) == "abc"
}

pub fn the_outlook_rides_the_cache_piece_test() {
  assert transcript_lines.usage_pieces(usage(), "cache idle 3m")
    == #("cache 1.2m/40k, idle 3m", ["est $4.00", "in 812k", "out 86k"])
  assert { transcript_lines.usage_pieces(usage(), "cache TTL elapsed") }.0
    == "cache 1.2m/40k, TTL elapsed"
  assert { transcript_lines.usage_pieces(usage(), "") }.0 == "cache 1.2m/40k"
}

// At every layout the detailed footer either shows the cache pair whole or
// leaves it out; no row ends in a cut figure.
pub fn the_detailed_footer_never_cuts_a_figure_test() {
  let expanded = tui_model.Model(..model(), details_expanded: True)
  list.each([240, 180, 120, 90, 60], fn(width) {
    let text = footer_rows(expanded, width) |> string.join("\n")
    assert !string.contains(text, "cac…")
    assert !string.contains(text, "Total est")
  })

  // On the ordinary two-row layout everything but the rate fits, and the
  // cache outlook leads so a narrow row keeps the warning.
  let text = footer_rows(expanded, 180) |> string.join("\n")
  assert string.contains(
    text,
    "cache 1.2m/40k, idle 3m · ctx — · est $4.00 · in 812k · out 86k",
  )
}

// With room to spare the rate joins the row as its own whole piece.
pub fn the_rate_shows_when_the_outlook_leaves_room_test() {
  let quiet =
    tui_model.Model(..model(), details_expanded: True, cache_outlook: "")
  let text = footer_rows(quiet, 180) |> string.join("\n")
  assert string.contains(
    text,
    "cache 1.2m/40k · ctx — · est $4.00 · in 812k · out 86k · 45 tok/s",
  )
}

// The compact footer keeps its order (outlook, notice, model, context, cost)
// and drops trailing pieces whole when a long notice crowds them out.
pub fn the_compact_footer_drops_whole_pieces_test() {
  let text = footer_rows(model(), 120) |> string.join("\n")
  assert string.contains(
    text,
    "cache idle 3m · baseten-kimi-k3 · ctx — · est $4.00",
  )

  let crowded =
    tui_model.Model(
      ..model(),
      notice: "steer captured; waiting for the running operation to stop",
    )
  let text = footer_rows(crowded, 120) |> string.join("\n")
  assert !string.contains(text, "est $4…")
  assert string.contains(text, "steer captured")
}

// The Left hint appears only where Left would open the picker: an empty
// composer, no pending paste, and a daemon to ask.
pub fn sessions_hint_tracks_the_left_binding_test() {
  assert render.sessions_hint("", [], Some(Nil)) == "← sessions"
  assert render.sessions_hint("draft", [], Some(Nil)) == ""
  assert render.sessions_hint("", [Nil], Some(Nil)) == ""
  assert render.sessions_hint("", [], None) == ""
}
