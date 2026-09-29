//// The effects the session reducers decide, generic over the host's
//// handles.
////
//// Of everything the terminal's step queues, two kinds of effect are decided
//// by the reducers that will move into `session_view` with the shared
//// record (`docs/design-notes/step-extraction.md`): an output of the adopted
//// session lane, and the recording line for a message that arrived with no
//// lane to note it under. Neither needs to know what the socket or the
//// recorder is. A lane output already carries its own handle
//// (`session_channel.Out(socket, recorder)`), and the channelless line needs
//// only the recorder and the message. So the type is generic over both
//// handles, as the lane is, and a host binds them to its own socket and
//// recorder.
////
//// A function over the shared record queues these values on
//// `Shared.outbox`. The terminal stores each such result through
//// `tui_model.hold_shared`, which wraps the values in `effect.Step` and
//// moves them into the step's single queue at the point of the call, and
//// performs them in `runtime.perform_io` after the step, as it performs
//// every other effect. That is what keeps one order across both kinds, so
//// a lane write, a terminal `Discard` and another lane write still come out
//// in the order the step decided them. A web host would perform the same values against
//// its own relay and a `Nil` recorder.
////
//// The type is in a module of its own, rather than in `session_view/step`
//// beside the step's entry points, because the shared record holds a queue
//// of these values (`Shared.outbox`) and the step imports the record, so a
//// type in the step would make the two modules import each other.

import session_view/connection_event
import session_view/session_channel

/// One effect a session reducer decided: an output of the adopted lane, or
/// the recording line for a message no lane noted.
///
/// `socket` is the host's connection type and `recorder` its recording
/// handle. Both are only named here, never used: performing the effect is
/// the host's work.
pub type Effect(socket, recorder) {
  /// An output of the adopted session lane: a frame to write on its socket,
  /// a close of that socket, or an attempt note for its recording.
  Lane(output: session_channel.Out(socket, recorder))

  /// A message that arrived while the model held no lane, for the host to
  /// append to its recording as an untagged arrival. The preview peer's
  /// traffic is recorded this way.
  Recorded(recorder: recorder, message: connection_event.Message)
}
