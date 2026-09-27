//// The terminal's session lane: `tui/session_channel` with the terminal's
//// own socket and recorder filled in, and the one function that acts on
//// what the lane decides.
////
//// The channel is generic over the two handles it carries, because the
//// lane's transitions never use them: they only name the socket a frame is
//// written to and the recorder a note goes to. What those handles are is the
//// host's business, so the terminal names its choice here, once, and every
//// module that stores or performs a lane uses these names. `perform` is the
//// only place a lane's decisions touch the websocket or the recording file,
//// and it runs after the step, as the runtime performs everything else.

import session_view/session_channel
import tui/connection
import tui/recording

/// A session lane whose socket is a terminal connection and whose recorder
/// is the terminal's recording.
pub type Lane =
  session_channel.Channel(connection.Connection, recording.Recorder)

/// One output of a terminal lane: a frame to write, a close, or a note.
pub type Output =
  session_channel.Out(connection.Connection, recording.Recorder)

/// Performs one output against its socket or its recorder.
///
/// ## Examples
///
/// ```gleam
/// let #(lane, outputs) = session_channel.take_outputs(lane)
/// list.each(outputs, terminal_lane.perform)
/// ```
pub fn perform(output: Output) -> Nil {
  case output {
    session_channel.Transmit(socket, frame) -> connection.send(socket, frame)
    session_channel.Shut(socket) -> connection.close(socket)
    session_channel.Note(recorder, event) ->
      recording.append(recorder, recording.Attempt(event))
  }
}
