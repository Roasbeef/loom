//// The translator from etui's input event to the client's own event, and
//// the recording line each event is written as (phase 3 of issue #530).
////
//// `keymap.translate` stands between etui and the reducer, so every etui
//// event has one expected client event, and the table below names it. It
//// only parses: a key's text becomes the key it names and nothing more, so
//// Escape reaches the reducer as `keys.Escape` and the reducer decides what
//// it means.
////
//// A recording is written from the client event (`msg.recorded`) and
//// replayed as etui events (`recording.to_step`). The round trip below runs
//// every recordable line through replay's etui event, the translator and
//// `msg.recorded`, and asks for the same line back, so a recording made
//// from messages holds exactly the bytes one made from etui's events did.

import etui/backend
import etui/keys
import gleam/list
import gleam/option.{None, Some}
import tui/image_drop
import tui/keymap
import tui/msg
import tui/recording
import tui/virtual_backend

// Every etui event, and the client event it translates to. A paste carries
// the read it was given, and every other event ignores it.
pub fn every_etui_event_translates_to_its_client_event_test() {
  let image = image_drop.Image("/tmp/a.png", "a.png", "image/png", 3, "YQ==")
  let read = Ok(Some(image))

  assert keymap.translate(backend.KeyPress("esc"), read)
    == msg.KeyPressed("esc", keys.Escape)
  assert keymap.translate(backend.KeyPress("enter"), read)
    == msg.KeyPressed("enter", keys.Enter)
  assert keymap.translate(backend.KeyPress("q"), read)
    == msg.KeyPressed("q", keys.match("q"))
  assert keymap.translate(backend.Paste("/tmp/a.png"), read)
    == msg.Pasted("/tmp/a.png", read)
  assert keymap.translate(backend.Paste("words"), Ok(None))
    == msg.Pasted("words", Ok(None))
  assert keymap.translate(backend.Resize(100, 30), read) == msg.Resized(100, 30)
  assert keymap.translate(backend.MouseScroll(3, 4, True), read)
    == msg.Scrolled(3, 4, recording.ScrollUp)
  assert keymap.translate(backend.MouseScroll(3, 4, False), read)
    == msg.Scrolled(3, 4, recording.ScrollDown)
  assert keymap.translate(backend.MousePress(1, 2, backend.MouseLeft), read)
    == msg.Pressed(1, 2, backend.MouseLeft)
  assert keymap.translate(backend.MouseDrag(1, 2, backend.MouseRight), read)
    == msg.Dragged(1, 2, backend.MouseRight)
  assert keymap.translate(backend.MouseRelease(1, 2, backend.MouseMiddle), read)
    == msg.Released(1, 2, backend.MouseMiddle)
  assert keymap.translate(backend.MouseMove(5, 6), read) == msg.Moved(5, 6)
  assert keymap.translate(backend.Tick, read) == msg.Ticked
}

// A tick and a bare move are not recorded; they leave nothing to replay.
pub fn a_tick_and_a_bare_move_are_not_recorded_test() {
  assert msg.recorded(msg.Ticked) == None
  assert msg.recorded(msg.Moved(1, 2)) == None
}

// Every recordable line survives replay's etui event, the translator and
// the recording of the message unchanged.
pub fn every_recorded_input_round_trips_through_the_translator_test() {
  let lines = [
    recording.Key("q"),
    recording.Key("esc"),
    recording.Key("ctrl+c"),
    recording.Key("é"),
    recording.Pasted("two\nlines"),
    recording.Pasted("/tmp/shot.png"),
    recording.Resized(120, 40),
    recording.Scrolled(3, 4, recording.ScrollUp),
    recording.Scrolled(3, 4, recording.ScrollDown),
    recording.Pressed(1, 2, backend.MouseLeft),
    recording.Pressed(1, 2, backend.MouseMiddle),
    recording.Dragged(3, 2, backend.MouseRight),
    recording.Released(3, 2, backend.MouseMiddle),
  ]
  list.each(lines, fn(line) {
    let assert virtual_backend.Input(event) = recording.to_step(line)
      as "premise: every input line replays as an etui event"
    assert msg.recorded(keymap.translate(event, Ok(None))) == Some(line)
  })
}
