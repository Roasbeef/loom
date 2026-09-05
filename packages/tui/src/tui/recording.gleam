//// A session recording: one JSON line per event the client saw.
////
//// `loom --record <path>` writes this file while a real session runs, and
//// `loom replay <path>` plays it back through the virtual backend. Between
//// them sits the reason the format exists at all: a client bug that only
//// appears against a live server is otherwise reproducible only by having
//// that server, and a frame nobody can print is a bug nobody can describe.
//// A recording turns both into a file.
////
//// ## What is recorded, and what is not
////
//// Only the events that move the model. `Tick` is excluded because it
//// carries no information — the replay backend supplies its own ticks, and
//// recording thousands of idle ones would bury the events that matter.
//// `MouseMove` is excluded because `update` returns the model unchanged for
//// it, so a recording that carried it would replay identically and cost
//// bytes to say so; a press, drag or release is kept, because that is how a
//// mouse selection is made and a replay has to be able to make one.
//// `Recorded` is the set that is left, and it is a type rather than a
//// filter, so nothing downstream has to ask whether a moment is recordable.
////
//// ## The wire form
////
//// One compact JSON object per line: `at`, the monotonic milliseconds since
//// the recording began, and `t`, which discriminates. A `Connected`,
//// `Closed` or `NetworkFault` is a connection lifecycle fact rather than a
//// gateway frame, so each gets its own tag; an `Incoming` carries the
//// gateway's own bytes verbatim, because the protocol already has exactly
//// one wire form and a second encoding of it could only ever disagree.
////
//// Decoding is total. A line that is not a well-formed moment is a worded
//// error naming the line, never a crash and never a silently dropped event:
//// a replay that quietly skipped a frame would answer a question about the
//// client with an answer about the recording.
////
//// ## What a replay may do
////
//// A replay reproduces inbound traffic and rendering, and nothing else. It
//// performs no outbound effect — no websocket write, no daemon start, no
//// local catalogue read — and it fabricates nothing the live client would
//// have been *sent*. `tui.Peer` is what enforces that: submitting under
//// `Replaying` does only the local half of the live path, and the turn the
//// server echoed arrives from the recording as an entry, so the operator's
//// line is drawn once rather than twice.
////
//// The same rule covers measurements. The footer's tokens-per-second is
//// this client's own clock from a request going out to its settlement,
//// and a replay spends that window reading a file rather than waiting on
//// a provider. A replay leaves it unset instead of reporting its own
//// speed.

import core/json
import etui/backend
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tui/connection
import tui/internal/ffi_bootstrap
import tui/virtual_backend

/// Which way a wheel event moved, so no reader has to carry the polarity
/// of a boolean called `up`.
pub type ScrollDirection {
  /// Towards older transcript.
  ScrollUp

  /// Towards the tail.
  ScrollDown
}

/// One event worth replaying.
///
/// The set is closed on purpose: everything etui can deliver that this
/// client acts on, and nothing else. Adding a variant here is the same
/// decision as deciding a new event changes what the client shows.
pub type Recorded {
  /// A key press, as the exact string etui's backend produced.
  Key(text: String)

  /// One bracketed paste, delivered whole.
  Pasted(text: String)

  /// A terminal resize.
  Resized(width: Int, height: Int)

  /// A mouse wheel notch at a cell position.
  Scrolled(x: Int, y: Int, direction: ScrollDirection)

  /// A mouse button going down on a cell.
  Pressed(x: Int, y: Int, button: backend.MouseButton)

  /// The pointer moving with a button held.
  Dragged(x: Int, y: Int, button: backend.MouseButton)

  /// A mouse button coming up on a cell.
  Released(x: Int, y: Int, button: backend.MouseButton)

  /// One message from the websocket actor's inbox.
  Arrived(message: connection.Message)
}

/// One recorded event and when it happened.
pub type Moment {
  Moment(
    /// Monotonic milliseconds since the recording started. Offsets rather
    /// than timestamps, so a recording says nothing about when or where it
    /// was taken and replays the same on any machine.
    at_ms: Int,
    /// What happened.
    event: Recorded,
  )
}

/// An open recording. Opaque: the path and the epoch are the whole of it,
/// and neither is anyone else's business.
pub opaque type Recorder {
  Recorder(path: String, started_ms: Int)
}

/// Opens a recording, truncating anything already at the path.
///
/// Truncating rather than appending is deliberate: offsets are relative to
/// one run, so two runs concatenated would describe a timeline that never
/// happened.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(recorder) = recording.start("/tmp/session.jsonl")
/// ```
pub fn start(path: String) -> Result(Recorder, String) {
  case simplifile.write(path, "") {
    Ok(Nil) ->
      Ok(Recorder(path:, started_ms: ffi_bootstrap.monotonic_time_ms()))
    Error(reason) ->
      Error("cannot open recording " <> path <> ": " <> string.inspect(reason))
  }
}

/// Appends one input event, if it is one that replays.
///
/// Takes the optional recorder rather than making every call site test it,
/// because the overwhelmingly common case is a session with no recording
/// and the check belongs in one place.
///
/// ## Examples
///
/// ```gleam
/// recording.note_input(model.recorder, backend.KeyPress("a"))
/// ```
pub fn note_input(
  recorder: Option(Recorder),
  event: backend.InputEvent,
) -> Nil {
  case recorder, of_input(event) {
    Some(recorder), Some(recorded) -> append(recorder, recorded)
    None, _ | _, None -> Nil
  }
}

/// Appends one inbox message.
///
/// ## Examples
///
/// ```gleam
/// recording.note_message(model.recorder, connection.Connected)
/// ```
pub fn note_message(
  recorder: Option(Recorder),
  message: connection.Message,
) -> Nil {
  case recorder {
    Some(recorder) -> append(recorder, Arrived(message:))
    None -> Nil
  }
}

/// The recordable part of an input event, if any.
///
/// ## Examples
///
/// ```gleam
/// assert recording.of_input(backend.Tick) == option.None
/// ```
pub fn of_input(event: backend.InputEvent) -> Option(Recorded) {
  case event {
    backend.KeyPress(key) -> Some(Key(text: key))
    backend.Paste(text) -> Some(Pasted(text:))
    backend.Resize(width, height) -> Some(Resized(width:, height:))
    backend.MouseScroll(x, y, True) ->
      Some(Scrolled(x:, y:, direction: ScrollUp))
    backend.MouseScroll(x, y, False) ->
      Some(Scrolled(x:, y:, direction: ScrollDown))
    backend.MousePress(x, y, button) -> Some(Pressed(x:, y:, button:))
    backend.MouseDrag(x, y, button) -> Some(Dragged(x:, y:, button:))
    backend.MouseRelease(x, y, button) -> Some(Released(x:, y:, button:))

    // A tick carries nothing, and a move with no button held leaves the
    // model exactly as it found it.
    backend.Tick | backend.MouseMove(..) -> None
  }
}

/// The script step one recorded event replays as.
///
/// ## Examples
///
/// ```gleam
/// assert recording.to_step(recording.Key("a"))
///   == virtual_backend.Input(backend.KeyPress("a"))
/// ```
pub fn to_step(event: Recorded) -> virtual_backend.Step {
  case event {
    Key(text:) -> virtual_backend.Input(backend.KeyPress(text))
    Pasted(text:) -> virtual_backend.Input(backend.Paste(text))
    Resized(width:, height:) ->
      virtual_backend.Input(backend.Resize(width, height))
    Scrolled(x:, y:, direction: ScrollUp) ->
      virtual_backend.Input(backend.MouseScroll(x, y, True))
    Scrolled(x:, y:, direction: ScrollDown) ->
      virtual_backend.Input(backend.MouseScroll(x, y, False))
    Pressed(x:, y:, button:) ->
      virtual_backend.Input(backend.MousePress(x, y, button))
    Dragged(x:, y:, button:) ->
      virtual_backend.Input(backend.MouseDrag(x, y, button))
    Released(x:, y:, button:) ->
      virtual_backend.Input(backend.MouseRelease(x, y, button))
    Arrived(message:) -> virtual_backend.Deliver(message:)
  }
}

/// The whole script a recording replays as, in order.
///
/// ## Examples
///
/// ```gleam
/// let steps = recording.to_steps(moments)
/// ```
pub fn to_steps(moments: List(Moment)) -> List(virtual_backend.Step) {
  list.map(moments, fn(moment) { to_step(moment.event) })
}

/// One recording line, with no trailing newline.
///
/// ## Examples
///
/// ```gleam
/// assert recording.encode_line(recording.Moment(12, recording.Key("a")))
///   == "{\"at\":12,\"t\":\"key\",\"key\":\"a\"}"
/// ```
pub fn encode_line(moment: Moment) -> String {
  let Moment(at_ms:, event:) = moment
  json.to_string(json.Object([#("at", json.Int(at_ms)), ..encode_event(event)]))
}

/// Decodes one recording line.
///
/// ## Examples
///
/// ```gleam
/// assert recording.decode_line("{\"at\":12,\"t\":\"key\",\"key\":\"a\"}")
///   == Ok(recording.Moment(12, recording.Key("a")))
/// ```
pub fn decode_line(line: String) -> Result(Moment, String) {
  use value <- result.try(
    json.parse(line)
    |> result.map_error(fn(report) {
      "the line is not JSON: " <> report.expected
    }),
  )
  use fields <- result.try(object_fields(value))
  use at_ms <- result.try(required_int(fields, "at"))
  use tag <- result.try(required_string(fields, "t"))
  use event <- result.try(decode_event(tag, fields))
  Ok(Moment(at_ms:, event:))
}

/// Reads and decodes a whole recording.
///
/// Blank lines are skipped so a file that ends in a newline, which every
/// appended file does, is not a decoding failure. Everything else must
/// decode: a partial replay would answer the wrong question.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(moments) = recording.decode_file("/tmp/session.jsonl")
/// ```
pub fn decode_file(path: String) -> Result(List(Moment), String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(reason) {
      "cannot read recording " <> path <> ": " <> string.inspect(reason)
    }),
  )
  text
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.filter(fn(numbered) { string.trim(numbered.1) != "" })
  |> list.try_map(fn(numbered) {
    let #(number, line) = numbered
    decode_line(line)
    |> result.map_error(fn(reason) {
      path <> " line " <> int.to_string(number) <> ": " <> reason
    })
  })
}

// One append per event. A recording is written by a person's hand or by a
// websocket, so the syscall rate is bounded by those and buffering would
// only risk losing the tail of the run that is being diagnosed.
fn append(recorder: Recorder, event: Recorded) -> Nil {
  let at_ms = ffi_bootstrap.monotonic_time_ms() - recorder.started_ms
  let line = encode_line(Moment(at_ms:, event:)) <> "\n"

  // A failed append is deliberately silent. The terminal owns the screen,
  // so there is nowhere to print, and a recording that stops recording is
  // not a reason to take a live session down.
  let _ = simplifile.append(recorder.path, line)
  Nil
}

fn encode_event(event: Recorded) -> List(#(String, json.JsonValue)) {
  case event {
    Key(text:) -> [#("t", json.String("key")), #("key", json.String(text))]
    Pasted(text:) -> [
      #("t", json.String("paste")),
      #("text", json.String(text)),
    ]
    Resized(width:, height:) -> [
      #("t", json.String("resize")),
      #("width", json.Int(width)),
      #("height", json.Int(height)),
    ]
    Scrolled(x:, y:, direction:) -> [
      #("t", json.String("scroll")),
      #("x", json.Int(x)),
      #("y", json.Int(y)),
      #("up", json.Bool(direction == ScrollUp)),
    ]
    Pressed(x:, y:, button:) -> encode_button("press", x, y, button)
    Dragged(x:, y:, button:) -> encode_button("drag", x, y, button)
    Released(x:, y:, button:) -> encode_button("release", x, y, button)
    Arrived(message:) -> encode_message(message)
  }
}

fn encode_button(
  tag: String,
  x: Int,
  y: Int,
  button: backend.MouseButton,
) -> List(#(String, json.JsonValue)) {
  [
    #("t", json.String(tag)),
    #("x", json.Int(x)),
    #("y", json.Int(y)),
    #("button", json.String(button_name(button))),
  ]
}

// The button by name rather than by etui's bit value, so a recording reads
// as what happened and does not change meaning if etui renumbers.
fn button_name(button: backend.MouseButton) -> String {
  case button {
    backend.MouseLeft -> "left"
    backend.MouseMiddle -> "middle"
    backend.MouseRight -> "right"
  }
}

// The gateway's own bytes go through verbatim: the protocol has one wire
// form already, and a second encoding of it could only disagree with the
// first. The three lifecycle messages are not wire frames at all, so each
// is given a tag of its own rather than being flattened into a fake one.
fn encode_message(
  message: connection.Message,
) -> List(#(String, json.JsonValue)) {
  case message {
    connection.Connected -> [#("t", json.String("connected"))]
    connection.Incoming(text:) -> [
      #("t", json.String("incoming")),
      #("text", json.String(text)),
    ]
    connection.Closed(reason:) -> [
      #("t", json.String("closed")),
      #("reason", json.String(reason)),
    ]
    connection.NetworkFault(reason:) -> [
      #("t", json.String("fault")),
      #("reason", json.String(reason)),
    ]
  }
}

fn decode_event(
  tag: String,
  fields: List(#(String, json.JsonValue)),
) -> Result(Recorded, String) {
  case tag {
    "key" -> result.map(required_string(fields, "key"), Key)
    "paste" -> result.map(required_string(fields, "text"), Pasted)
    "resize" -> decode_resize(fields)
    "scroll" -> decode_scroll(fields)
    "press" -> decode_button(fields, Pressed)
    "drag" -> decode_button(fields, Dragged)
    "release" -> decode_button(fields, Released)
    "connected" -> Ok(Arrived(message: connection.Connected))
    "incoming" ->
      result.map(required_string(fields, "text"), fn(text) {
        Arrived(message: connection.Incoming(text:))
      })
    "closed" ->
      result.map(required_string(fields, "reason"), fn(reason) {
        Arrived(message: connection.Closed(reason:))
      })
    "fault" ->
      result.map(required_string(fields, "reason"), fn(reason) {
        Arrived(message: connection.NetworkFault(reason:))
      })
    other -> Error("unknown recording event \"" <> other <> "\"")
  }
}

fn decode_resize(
  fields: List(#(String, json.JsonValue)),
) -> Result(Recorded, String) {
  use width <- result.try(required_int(fields, "width"))
  use height <- result.try(required_int(fields, "height"))
  Ok(Resized(width:, height:))
}

fn decode_scroll(
  fields: List(#(String, json.JsonValue)),
) -> Result(Recorded, String) {
  use x <- result.try(required_int(fields, "x"))
  use y <- result.try(required_int(fields, "y"))
  use direction <- result.try(case list.key_find(fields, "up") {
    Ok(json.Bool(True)) -> Ok(ScrollUp)
    Ok(json.Bool(False)) -> Ok(ScrollDown)
    Ok(_) | Error(Nil) -> Error("scroll needs a boolean \"up\"")
  })
  Ok(Scrolled(x:, y:, direction:))
}

// The three button events share one shape and differ only in the
// constructor, which the tag has already chosen.
fn decode_button(
  fields: List(#(String, json.JsonValue)),
  build: fn(Int, Int, backend.MouseButton) -> Recorded,
) -> Result(Recorded, String) {
  use x <- result.try(required_int(fields, "x"))
  use y <- result.try(required_int(fields, "y"))
  use name <- result.try(required_string(fields, "button"))
  use button <- result.try(case name {
    "left" -> Ok(backend.MouseLeft)
    "middle" -> Ok(backend.MouseMiddle)
    "right" -> Ok(backend.MouseRight)
    other -> Error("unknown mouse button \"" <> other <> "\"")
  })
  Ok(build(x, y, button))
}

fn object_fields(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("a recording line must be a JSON object")
  }
}

fn required_string(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(name <> " must be a string")
  }
}

fn required_int(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(name <> " must be an integer")
  }
}
