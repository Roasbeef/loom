//// The terminal client's own message type: what the step is given.
////
//// `tui.step` used to take etui's `backend.InputEvent`, and phase 2 of issue
//// #530 wrote what the step also needed onto the model before calling it:
//// the clock readings and what reading a pasted path found. A second
//// runtime, a Lustre server component in the daemon, cannot do that. Lustre calls `update(model, msg)` and has no
//// hook that runs before it, so anything the step needs from the host has
//// to arrive inside the message. This module is that message.
////
//// A `Msg` is one event and the instant it is applied at. The event names
//// what happened in the client's own terms: the key etui parsed and the
//// text it came from, a paste together with what reading its path found,
//// a resize, the pointer, or a tick. `tui/keymap` builds one from etui's
//// input event, and it only parses: which command a key means is still the
//// reducer's decision, because that depends on the model (a pending
//// submission, an open overlay), and a translator that looked at the model
//// would be a second reducer.
////
//// The event is also what a recording holds. `recorded` gives the line an
//// event is written as, which is the line etui's event was written as
//// before, so the recording format and its bytes are unchanged.
////
//// The module sits below `tui/model` in the import graph: the model stores
//// a `Stamp`, and `tui/pacing`, which the model imports, reads events. So it
//// imports nothing of the model.

import etui/backend
import etui/keys
import gleam/option.{type Option, None, Some}
import tui/image_drop
import tui/recording

/// One event and the instant it is applied at.
@internal
pub type Msg {
  Msg(
    /// The clock readings the step is applied at. The step stores them as
    /// `Model.stamp`, and every reducer reads the time there.
    at: Stamp,
    /// What happened.
    event: Event,
  )
}

/// The clock readings one event is applied at.
///
/// Every reducer reads them from `Model.stamp` instead of calling a clock,
/// so a step reads no clock and every reducer in one step sees the same
/// instant. There are two monotonic readings because they time different
/// things: a test may fix the presentation clock to pin frames while a live
/// socket in the same test still needs real deadlines.
@internal
pub type Stamp {
  Stamp(
    /// The presentation clock, `Model.monotonic_time_ms`: frame pacing,
    /// activity elapsed time, generation throughput, the cache outlook and
    /// the jobs and activity-poll ages.
    now_ms: Int,
    /// The host's monotonic clock, which times the session lanes' request
    /// deadlines and idle refresh.
    transport_ms: Int,
    /// The host's wall clock, which only a session creation key reads.
    wall_ms: Int,
  )
}

/// What happened, in the client's own terms.
@internal
pub type Event {
  /// A key press: the exact text the terminal sent, which a recording
  /// keeps, and the key it parses as, which the reducer reads.
  KeyPressed(text: String, key: keys.Key)

  /// One bracketed paste, delivered whole, with what reading the path it
  /// names found. The host reads the file before the step; `Ok(None)` is
  /// the answer for text that names no image, which is inserted as text.
  Pasted(text: String, image: Result(Option(image_drop.Image), String))

  /// The terminal's new size.
  Resized(width: Int, height: Int)

  /// A mouse wheel notch at a cell position.
  Scrolled(x: Int, y: Int, direction: recording.ScrollDirection)

  /// A mouse button going down on a cell.
  Pressed(x: Int, y: Int, button: backend.MouseButton)

  /// The pointer moving with a button held.
  Dragged(x: Int, y: Int, button: backend.MouseButton)

  /// A mouse button coming up on a cell.
  Released(x: Int, y: Int, button: backend.MouseButton)

  /// The pointer moving with no button held.
  Moved(x: Int, y: Int)

  /// The loop's idle-time wakeup: the point where traffic is drained, the
  /// lanes' timers run and the activity indicator advances.
  Ticked
}

/// The recording line an event is written as, if it is one that replays.
///
/// A tick carries nothing, and a move with no button held leaves the model
/// as it found it, so neither is recorded. Every other event is written as
/// the line etui's event was written as, so a recording made from messages
/// is byte-for-byte the recording made from etui's events.
///
/// ## Examples
///
/// ```gleam
/// assert msg.recorded(msg.Ticked) == option.None
/// ```
@internal
pub fn recorded(event: Event) -> Option(recording.Recorded) {
  case event {
    KeyPressed(text:, ..) -> Some(recording.Key(text:))
    Pasted(text:, ..) -> Some(recording.Pasted(text:))
    Resized(width:, height:) -> Some(recording.Resized(width:, height:))
    Scrolled(x:, y:, direction:) -> Some(recording.Scrolled(x:, y:, direction:))
    Pressed(x:, y:, button:) -> Some(recording.Pressed(x:, y:, button:))
    Dragged(x:, y:, button:) -> Some(recording.Dragged(x:, y:, button:))
    Released(x:, y:, button:) -> Some(recording.Released(x:, y:, button:))
    Moved(..) | Ticked -> None
  }
}
