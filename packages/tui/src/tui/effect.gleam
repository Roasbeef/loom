//// The side effects a terminal step asks for, as values.
////
//// The terminal's reducer used to perform its own I/O: a websocket write,
//// a socket close, a cancelled worker, a clipboard sequence on stdout, a
//// report to the Herdr pane. Each of those now becomes an `Effect` that the
//// reducer appends to the model's outbox, and `tui/runtime` performs the
//// list after the step that produced it. The step is then a function from
//// an event and a model to a model and a list of effects, which is the
//// shape a Lustre application has, and what lets a test or a replay decide
//// what happens to the effects rather than each reducer asking whether it
//// is allowed to act.
////
//// Effects are data rather than closures. A test can assert that a
//// submitted prompt produced exactly one `Channel(Transmit(..))`, and a
//// second runtime, such as a web view served by the daemon, interprets the
//// same vocabulary against its own transport.
////
//// Every effect names the resource it acts on. The model's handles move
//// during a step: an adoption replaces the socket, a quit clears the
//// candidate. An effect decided against the old handle must reach the old
//// handle, so the runtime never looks a target up in the model.
////
//// Two kinds of I/O are deliberately not here yet. Recording appends stay
//// synchronous, because the recording orders an input before the channel
//// traces it caused, and that order holds only while every recording write
//// happens where it did. Mailbox drains, background job starts, clock reads
//// and file reads stay in the reducer, because their results feed the next
//// model; those become messages in phase 2 of issue #530.

import gleam/erlang/process.{type Subject}
import tui/attachment
import tui/connection
import tui/daemon
import tui/herdr
import tui/session_channel
import tui/sessions
import weft

/// One side effect a reducer step decided on.
pub type Effect {
  /// An output of the adopted session channel: a frame write or a close.
  Channel(session_channel.Out)

  /// An output of a provisional attachment attempt.
  Attachment(attachment.Out)

  /// Writes a frame to a conversation socket that has no channel, which is
  /// the preview peer's path before any session is adopted.
  Send(socket: connection.Connection, frame: String)

  /// Closes a conversation socket the model no longer routes through a
  /// channel, such as a preview peer or a replaced attachment's socket.
  CloseSocket(socket: connection.Connection)

  /// Closes a daemon control connection.
  CloseControl(control: daemon.Connection)

  /// Cancels a background worker through its weft signal.
  CancelTask(signal: weft.Cancel)

  /// Cancels a local session-switch worker. This blocks for up to its own
  /// one-second drain so a socket the worker opened is closed rather than
  /// leaked.
  CancelSessionSwitch(status: sessions.SwitchStatus)

  /// Empties an inbox the model has stopped reading, so its queued frames
  /// do not sit in the terminal's mailbox forever.
  Discard(inbox: Subject(connection.Message))

  /// Writes an OSC 52 clipboard sequence to the terminal.
  WriteClipboard(sequence: String)

  /// Announces the session identity to the Herdr pane.
  AnnounceHerdr(reporter: herdr.Reporter, session: String)

  /// Reports the pane state to Herdr.
  ReportHerdr(
    reporter: herdr.Reporter,
    state: herdr.PaneState,
    session: String,
    message: String,
  )
}
