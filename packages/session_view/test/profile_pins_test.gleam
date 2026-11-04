//// The `pins` of a `profile` snapshot, as a client reads them
//// (protocol-change/108): the optional object's total decoder, and the line
//// the shared record writes so the terminal can show what a session was
//// created with.

import core/json
import gleam/list
import gleam/option.{None, Some}
import session_view/event_fold
import session_view/inbox
import session_view/model.{type Shared}
import session_view/msg
import session_view/protocol
import session_view/step
import session_view/transcript_line.{Line, System}

fn fresh() -> Shared(String, Nil, String, String) {
  step.new(
    "main",
    "session",
    msg.Stamp(1000, 1000),
    inbox.new("frames"),
    inbox.new("replay"),
  )
}

fn frame(extra: List(#(String, json.JsonValue))) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("reply_to", json.Int(4)),
      #("event", json.String("snapshot")),
      #(
        "body",
        json.Object(list.append(
          [
            #("mode", json.String("profile")),
            #("available", json.Array([json.String("fast")])),
          ],
          extra,
        )),
      ),
    ]),
  )
}

fn pins(pairs: List(#(String, json.JsonValue))) -> #(String, json.JsonValue) {
  #("pins", json.Object(pairs))
}

// A snapshot with no `pins` field is a session with no pins, and one with the
// field reports each role and key in the order the daemon sent them.
pub fn the_pins_field_is_optional_and_ordered_test() {
  let assert Ok(protocol.ProfileSnapshot(pins: [], ..)) =
    protocol.decode_v2_presentation(frame([]))

  let assert Ok(protocol.ProfileSnapshot(pins: held, ..)) =
    protocol.decode_v2_presentation(
      frame([
        pins([
          #("main", json.String("opus")),
          #("vision", json.String("eyes")),
        ]),
      ]),
    )
  assert held == [#("main", "opus"), #("vision", "eyes")]
}

// A `pins` value that is not an object of text fails the frame; it is never read
// as no pins, which would hide a daemon that sent something else.
pub fn a_malformed_pins_field_is_refused_test() {
  let assert Error(_) =
    protocol.decode_v2_presentation(frame([#("pins", json.String("main"))]))

  let assert Error(_) =
    protocol.decode_v2_presentation(frame([pins([#("main", json.Int(3))])]))
}

// A read writes the pins as one line after the profile's own, and a session
// without pins gets no such line.
pub fn the_shared_record_shows_the_pins_when_there_are_some_test() {
  let snapshot = fn(held) {
    protocol.ProfileSnapshot(
      current: None,
      available: ["fast"],
      switched: None,
      pins: held,
    )
  }
  let shown = fn(held) {
    event_fold.apply_event(fresh(), snapshot(held)).transcript
  }

  assert list.contains(
    shown([#("main", "opus"), #("vision", "eyes")]),
    Line(System, "pinned: main=opus, vision=eyes"),
  )
  assert !list.any(shown([]), fn(line) {
    case line {
      Line(System, "pinned: " <> _) -> True
      _ -> False
    }
  })
}

// A switch keeps the pins, so its reply shows them beside the restart notice.
pub fn a_switch_reply_shows_the_pins_too_test() {
  let applied =
    event_fold.apply_event(
      fresh(),
      protocol.ProfileSnapshot(
        current: Some("fast"),
        available: ["fast"],
        switched: Some(1),
        pins: [#("vision", "eyes")],
      ),
    )
  assert list.contains(applied.transcript, Line(System, "pinned: vision=eyes"))
}
