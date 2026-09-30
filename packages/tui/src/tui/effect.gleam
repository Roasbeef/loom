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
//// submitted prompt produced exactly one `Step(Lane(Transmit(..)))`, and a
//// second runtime, such as a web view served by the daemon, interprets the
//// same vocabulary against its own transport.
////
//// The effects the session reducers decide, a lane's outputs and the
//// recording line for a message no lane noted, are `session_view/step_effect` values
//// generic over the socket and recorder, and reach this type through
//// `Step`. Everything else here is the terminal's own: the provisional
//// attachment, the control connection, jobs, inboxes the terminal created,
//// the input recording lines, the clipboard and Herdr.
////
//// Every effect names the resource it acts on. The model's handles move
//// during a step: an adoption replaces the socket, a quit clears the
//// candidate. An effect decided against the old handle must reach the old
//// handle, so the runtime never looks a target up in the model.
////
//// Recording appends are effects too. A step queues the input's own line
//// first, before the reducer runs, and each channel queues its attempt
//// notes in the same queue as its writes, so the effects come out in the
//// order the step decided them and the recording keeps the order ADR-009
//// requires: an input before everything it caused.
////
//// Background jobs are effects too. A reducer names a job with a key it
//// allocated and queues `StartJob(key, spec)`; the runtime starts it, keeps
//// its reply subject and cancel signal under the key, and hands its replies
//// back tagged with the key (`tui/job`). `CancelJob` names the job by the
//// same key. A key is never reused, so it identifies one job as exactly as
//// a handle would, and the runtime resolves it in its own table rather than
//// in anything a reducer changes. The provisional attachment is such a
//// job; file reads stay in the reducer until a later slice of phase 2 of
//// issue #530.

import gleam/erlang/process.{type Subject}
import session_view/connection_event
import session_view/step_effect
import tui/attachment
import tui/connection
import tui/herdr
import tui/job
import tui/recording

/// One side effect a reducer step decided on.
pub type Effect {
  /// An effect a session reducer decided: an output of the adopted session
  /// lane (a frame write, a close or an attempt note), or the recording line
  /// for a message that arrived with no lane. The terminal binds the step
  /// effect's handles to its own connection and recording.
  Step(step_effect.Effect(connection.Connection, recording.Recorder))

  /// An output of a provisional attachment attempt.
  Attachment(attachment.Out)

  /// Closes a conversation socket that no channel owns: the socket a
  /// dropped attachment `Prepared` carries.
  CloseSocket(socket: connection.Connection)

  /// Closes the daemon control connection the runtime holds under this
  /// key, and forgets it.
  CloseControl(control: job.ControlKey)

  /// Starts the background job `spec` describes under `key`, which the
  /// reducer allocated and holds in the slot that waits for its replies.
  StartJob(key: job.Key, spec: job.Spec)

  /// Cancels the background job started under `key`. Nothing it sends
  /// afterwards reaches a reducer, because the reducer that cancels it
  /// clears the slot that named the key in the same step.
  CancelJob(key: job.Key)

  /// Empties an inbox the model has stopped reading, so its queued frames
  /// do not sit in the terminal's mailbox forever.
  Discard(inbox: Subject(connection_event.Message))

  /// Appends one line to a recording: an input the terminal was given. A
  /// message that arrived with no channel to note it is a
  /// `Step(step_effect.Recorded(..))` instead, because a session reducer
  /// decides it.
  Record(recorder: recording.Recorder, event: recording.Recorded)

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

  /// Clears the Herdr pane's agent label, state and resume command. The
  /// exchange is synchronous inside the effect, unlike the fire-and-forget
  /// report: it runs on the quit path, where a report the socket never saw
  /// is a report that never happened, and the reply proves the reporter
  /// handled the release before the process that queued it is gone.
  ReleaseHerdr(reporter: herdr.Reporter)
}
