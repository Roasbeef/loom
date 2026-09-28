//// The terminal client's own message type: what the step is given.
////
//// `tui.step` used to take etui's `backend.InputEvent`, and phase 2 of issue
//// #530 wrote what the step also needed onto the model before calling it:
//// the clock readings and what reading a pasted path found. A second
//// runtime, a Lustre server component in the daemon, cannot do that. Lustre calls `update(model, msg)` and has no
//// hook that runs before it, so anything the step needs from the host has
//// to arrive inside the message. This module is that message.
////
//// A `Msg` is one of two things. `Input` is one event and the instant it is
//// applied at, and the step reduces it. `Arrived` is traffic the host
//// received, which the step only admits: it files each message into the
//// buffer or slot that waits for it and reduces nothing, so the drains keep
//// running where they always ran, at a tick or a key, in their fixed
//// order. A host that wakes when traffic arrives therefore delivers
//// `Arrived` and then an `Input` with `Ticked`, and never expects an arrival
//// alone to be reduced.
////
//// An input's event names
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
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import session_view/attempt
import session_view/connection_event
import session_view/pasted_image
import tui/job
import tui/recording

/// What the step is given.
@internal
pub type Msg {
  /// One event and the instant it is applied at, which the step reduces.
  Input(
    /// The clock readings the step is applied at. The step stores them as
    /// `Model.shared.stamp`, and every reducer reads the time there.
    at: Stamp,
    /// The host's wall clock, read with `at`. The step stores it as
    /// `Model.view.wall_ms`, where a session creation key reads it. It is
    /// beside the stamp rather than in it because it is the terminal's
    /// reading: no session reducer uses it.
    wall_ms: Int,
    /// What happened.
    event: Event,
  )

  /// Traffic the host received, oldest first, which the step admits and
  /// does not reduce (`tui/admission`). It reads no clock, so it carries no
  /// stamp, and it returns no effects.
  Arrived(arrivals: List(Arrival))
}

/// One message the host received for the model, before any reducer takes
/// it.
@internal
pub type Arrival {
  /// A message from a conversation socket, tagged with the inbox subject it
  /// was received from. The subject is the source key: an inbox is replaced
  /// whole at an adoption, so a message whose subject is neither the
  /// adopted inbox's nor the waiting attempt's belongs to a socket the model
  /// no longer reads, and admission drops it rather than let it reach the
  /// adopted lane.
  Frame(
    source: Subject(connection_event.Message),
    message: connection_event.Message,
  )

  /// One recorded attempt event, during a replay.
  Replayed(event: attempt.Event)

  /// One message from a background job, tagged with the job's key.
  JobReplied(arrival: job.Arrival(job.Daemon))
}

/// The clock readings one event is applied at.
///
/// Every reducer reads them from `Model.shared.stamp` instead of calling a
/// clock, so a step reads no clock and every reducer in one step sees the
/// same instant. There are two monotonic readings because they time
/// different things: a test may fix the presentation clock to pin frames
/// while a live socket in the same test still needs real deadlines. The
/// wall clock is not here: its one reader is the terminal's session
/// creation key, so it is carried in `Input.wall_ms` and is stored in the
/// terminal's view.
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
  Pasted(text: String, image: Result(Option(pasted_image.Image), String))

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
