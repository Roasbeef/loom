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
import tui/model as tui_model
import tui/protocol
import tui/workspace
import tui_test/gateway

fn deliver(model: tui_model.Model, text: String) -> tui_model.Model {
  process.send(
    model.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", text)),
  )
  tui.update(backend.Tick, model)
}

fn streaming() -> tui_model.Model {
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

// Etui reports a tick only when a poll times out with no input, and a wheel
// flick delivers notches faster than any poll timeout. A socket drained by
// ticks alone is therefore starved for as long as the hand keeps moving: the
// history page a scroll asked for, and every capture queued behind it, land
// in one batch when the gesture pauses.
pub fn a_wheel_notch_drains_the_socket_without_waiting_for_a_tick_test() {
  let reading = tui.update(backend.MouseScroll(5, 5, True), streaming())
  process.send(
    reading.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", "\n\nQueued.")),
  )

  let scrolled = tui.update(backend.MouseScroll(5, 5, True), reading)
  assert scrolled.streams != reading.streams
    as "a notch applies the traffic already queued behind it"
  assert scrolled.reading_lines == reading.reading_lines
    as "and the drained fragment cannot reflow the text being read"
}

pub fn a_held_drag_drains_the_socket_too_test() {
  let pressed =
    tui.update(backend.MousePress(5, 5, backend.MouseLeft), streaming())
  process.send(
    pressed.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", "\n\nQueued.")),
  )

  let dragged = tui.update(backend.MouseDrag(9, 6, backend.MouseLeft), pressed)
  assert dragged.streams != pressed.streams
    as "a drag applies the traffic queued while the button is held"
  assert dragged.selection != None
    as "and the selection it extends survives the drain"
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
      tui_model.Model(..drafting, frame_cache: None),
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

// The frame cache is keyed on the screen rectangle alone, so a model edited
// by record update has to be driven through an event before its own frame is
// the one drawn.
fn border_text(model: tui_model.Model) -> String {
  let drawn = tui.update(backend.Resize(90, 24), model)
  let #(buffer, _) = tui.view(drawn, geometry.rect_new(0, 0, 90, 24))
  frame.buffer_to_text(buffer)
}

// The prompt border is where an offline terminal learns that its typing is
// still safe, so that instruction outranks every other title the border could
// carry. A socket that closes mid-interrupt does not clear the interrupt, so
// the two titles do compete for real.
pub fn a_disconnected_terminal_names_its_retained_draft_first_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let offline = tui_model.Model(..base, peer: tui_model.Disconnected)
  assert string.contains(
    border_text(offline),
    "Disconnected · /sessions to reconnect · draft retained",
  )

  let interrupting =
    tui_model.Model(
      ..offline,
      interrupt: Some(tui_model.Interrupt(base.active_strand, None, None)),
    )
  assert string.contains(
    border_text(interrupting),
    "Disconnected · /sessions to reconnect · draft retained",
  )
    as "a pending interrupt does not outrank the reconnect instruction"
  assert !string.contains(
    border_text(interrupting),
    "stopped · enter sends held input",
  )

  // The same pending interrupt on a live terminal still names itself, so the
  // guard rather than the fixture produced the two assertions above.
  let live = tui_model.Model(..interrupting, peer: tui_model.Preview)
  assert string.contains(border_text(live), "stopped · enter sends held input")
}

pub fn switching_agents_restores_the_frozen_reader_without_crossing_streams_test() {
  let reading = tui.update(backend.MouseScroll(5, 5, True), streaming())
  let reading =
    tui_model.Model(..reading, strands: [
      protocol.Strand("main", Some("main"), Some("assistant")),
      protocol.Strand("worker", Some("worker"), Some("assistant")),
    ])
  let worker =
    reading
    |> tui.update(backend.KeyPress("f2"), _)
    |> tui.update(backend.KeyPress("down"), _)
    |> tui.update(backend.KeyPress("enter"), _)
  assert worker.reading_lines == None
  assert worker.scroll_offset == 0
  let returned =
    worker
    |> tui.update(backend.KeyPress("f2"), _)
    |> tui.update(backend.KeyPress("up"), _)
    |> tui.update(backend.KeyPress("enter"), _)
  assert returned.active_strand == "main"
  assert returned.reading_lines == reading.reading_lines
  assert returned.scroll_offset == reading.scroll_offset
  assert returned.rendered_rows == reading.rendered_rows
}
