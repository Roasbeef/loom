//// Reading an unfinished answer keeps one immutable transient projection.
//// The live stream continues collecting behind it until the user returns.

import etui/backend
import etui/geometry
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/workspace
import tui_test/gateway

fn deliver(model: tui.Model, text: String) -> tui.Model {
  process.send(
    model.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", text)),
  )
  tui.update(backend.Tick, model)
}

fn streaming() -> tui.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
  |> fn(model) { tui.update(backend.Resize(90, 24), model) }
  |> deliver(string.join(list.repeat("An unfinished paragraph.\n\n", 40), ""))
}

pub fn scrolling_inside_a_live_answer_freezes_until_end_test() {
  let live = streaming()
  let reading = tui.update(backend.MouseScroll(5, 5, True), live)
  assert reading.scroll_offset > 0
  let assert Some(_) = reading.reading_lines
    as "scrolling captures the unfinished answer"
  let arrived = deliver(reading, "\n\nNew output below.\n\nMore output.")
  assert arrived.streams != reading.streams
    as "the actual live stream keeps collecting"
  assert arrived.rendered_rows == reading.rendered_rows
    as "incoming fragments cannot reflow the reader's text"
  assert arrived.scroll_offset == reading.scroll_offset

  let resumed = tui.update(backend.KeyPress("end"), arrived)
  assert resumed.scroll_offset == 0
  assert resumed.reading_lines == None
  assert resumed.rendered_rows != reading.rendered_rows
    as "returning to the bottom reveals the accumulated output"
}

pub fn frozen_text_reflows_on_resize_without_adopting_new_output_test() {
  let reading = tui.update(backend.MouseScroll(5, 5, True), streaming())
  let arrived = deliver(reading, "\n\nHidden until returning to the bottom.")
  let resized = tui.update(backend.Resize(70, 24), arrived)
  assert resized.reading_lines == reading.reading_lines
  assert resized.scroll_offset > 0
}

pub fn clicking_the_visible_jump_hint_preserves_a_draft_test() {
  let reading = tui.update(backend.MouseScroll(5, 5, True), streaming())
  let arrived = deliver(reading, "\n\nNew output below.")
  let drafting = tui.update(backend.KeyPress("x"), arrived)
  let shown =
    tui.view(
      tui.Model(..drafting, frame_cache: None),
      geometry.rect_new(0, 0, drafting.width, drafting.height),
    ).0
  let assert Ok(#(_, y)) =
    frame.buffer_to_lines(shown)
    |> list.index_map(fn(row, y) { #(row, y) })
    |> list.find(fn(pair) { string.contains(pair.0, "click for latest") })
    as "the user has a visible jump action while reading above the tail"
  let resumed =
    tui.update(backend.MousePress(5, y, backend.MouseLeft), drafting)
  assert resumed.scroll_offset == 0
  assert resumed.reading_lines == None
  assert resumed.input == drafting.input
    as "jumping to the bottom does not submit or discard the draft"
  assert resumed.selection == None
}
