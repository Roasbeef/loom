//// The parts of a client step's message that belong to the session rather
//// than to any one host: the clock readings an input is applied at, the
//// commands an operator gives the session, and the whole-event message
//// `session_view/step.update` reduces for a host with no surfaces of its own.
////
//// A host's own message names what happened in its own terms, keys and a
//// pointer for the terminal (`tui/msg`) and DOM events for the web view,
//// and decides which session command, if any, each one means. What it
//// hands the shared step is in the terms here. `Stamp` is the instant an
//// event is applied at, which the shared record stores as `Shared.stamp`
//// so that no reducer reads a clock. `Command` is the closed set of things
//// an operator does to a session from any host, which
//// `session_view/commands.act` carries out over the shared record alone
//// (`docs/design-notes/step-extraction.md`, section 2, and question 7 on
//// why a parsed slash command reaches it as `command.Session` rather than
//// as text).
////
//// The module imports only `session_view`, so it sits below
//// `session_view/model` in the import graph.

import session_view/approval
import session_view/attempt
import session_view/command
import session_view/connection_event
import session_view/operator
import session_view/remembered

/// The clock readings one event is applied at.
///
/// Every reducer reads them from `Model.shared.stamp` instead of calling a
/// clock, so a step reads no clock and every reducer in one step sees the
/// same instant. There are two monotonic readings because they time
/// different things: a test may fix the presentation clock to pin frames
/// while a live socket in the same test still needs real deadlines. The
/// wall clock is not here: its one reader is the terminal's session
/// creation key, so the terminal carries it beside the stamp in its own
/// message (`tui/msg.Input.wall_ms`) and stores it in its view.
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

/// What an operator does to a session: one call into the shared step's
/// commands (`commands.act`), which read and write the session state alone.
///
/// A change of active strand is not one of them. It is three shared calls
/// with the host's own writes between them, because the lane's
/// cancellation of unsent frames yields updates the host applies one at a
/// time (the ruling on question 11 of the step-extraction note), so the
/// host drives it (`submit.switch_active_strand`).
@internal
pub type Command {
  /// A submitted draft that parsed as a session command. `draft` is the
  /// text as typed, which a prompt sends with its attachments expanded, and
  /// `delivery` is how the host means a prompt to reach a running strand.
  Submit(draft: String, command: command.Session, delivery: operator.Delivery)

  /// A session command chosen by a control, such as a button, instead of
  /// typed as a draft. It has no draft to consume, so it leaves the
  /// composer's text alone (`commands.control`). It carries no prompt.
  Control(command: command.Session)

  /// Interrupt the active strand's running operation.
  Interrupt

  /// Stop one strand's running operation.
  Stop(strand: String)

  /// Decide the approval `review` as the host showed it, not as the session
  /// state holds it under the same ID now.
  Decide(review: approval.Review, choice: operator.Choice)

  /// Forget remembered permissions, as the host listed them
  /// (protocol-change/073). It is refused to an attachment that may not
  /// approve, and the daemon refuses it again to an observer.
  Forget(forget: remembered.Forget)

  /// Switch the active strand to the catalogue model `name`.
  SelectModel(name: String)

  /// End the session's half of the attachment: close the adopted lane and
  /// mark the session as ending. The host cancels its own work after it.
  Quit
}

/// What a host with no surfaces of its own hands the shared step
/// (`step.update`): traffic it received, or one event to reduce.
///
/// The two are separate messages because they are separate moments. Traffic
/// is received when the transport delivers it, and reducing it waits for an
/// input, which carries the clock readings the reducers run at. A host that
/// wakes on arrival, as the web view does, sends `Arrived` and then an
/// `Input` for the same wake.
@internal
pub type Msg(source) {
  /// One event and the readings it is applied at. The step reduces it.
  Input(at: Stamp, event: Event)

  /// Traffic the host received, oldest first. The step files it and reduces
  /// nothing.
  Arrived(arrivals: List(Arrival(source)))
}

/// One unit of received traffic, in the terms of the buffer it is filed
/// into.
@internal
pub type Arrival(source) {
  /// A conversation socket's message, and the source it was read from. A
  /// message from a source the record no longer reads is dropped
  /// (`admission.file_frame`).
  Frame(source: source, message: connection_event.Message)

  /// One recorded attempt event, for a host that replays a recording.
  Replayed(event: attempt.Event)
}

/// What one `Input` does.
@internal
pub type Event {
  /// The host's wake-up: the clocks advance, the inbox is drained, the lane
  /// ticks and the waiting reads are sent.
  Ticked

  /// The operator acted, in the session's terms.
  Acted(command: Command)
}
