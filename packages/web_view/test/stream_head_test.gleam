//// The strip above the stream says how long the running turn has run, counted
//// by the browser from the instant the turn's operation started.

import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/view/stream_head

fn drawn(turn) -> String {
  drawn_with(turn, None)
}

fn drawn_with(turn, model) -> String {
  stream_head.view(
    stream_head.Head(
      name: "coord/web-inbox",
      place: "main · loom",
      tone: stream_head.Running,
      state: "running",
      turn:,
      model:,
      goal: None,
    ),
    element.none(),
    element.none(),
  )
  |> element.to_string
}

pub fn a_running_turn_says_how_long_it_has_run_test() {
  assert string.contains(
    drawn(Some(1_790_030_460_000)),
    "running, turn <loom-elapsed form=\"minutes\" since=\"1790030460000\"></loom-elapsed>",
  )
}

pub fn a_strip_with_no_turn_draws_the_state_alone_test() {
  let html = drawn(None)
  assert string.contains(html, ">running</span>")
  assert !string.contains(html, "loom-elapsed")
}

pub fn the_model_is_named_after_the_place_test() {
  let html = drawn_with(None, Some("kimi-k3"))
  assert string.contains(html, "main · loom<span class=\"stream-model\"")
  assert string.contains(html, " · kimi-k3</span>")
}

pub fn a_strip_with_no_model_names_none_test() {
  assert !string.contains(drawn(None), "stream-model")
}
