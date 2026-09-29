//// The parts of a client step's message that belong to the session rather
//// than to any one host: the clock readings an input is applied at, and
//// the commands an operator gives the session.
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
import session_view/command
import session_view/operator

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

  /// Interrupt the active strand's running operation.
  Interrupt

  /// Stop one strand's running operation.
  Stop(strand: String)

  /// Decide the approval `review` as the host showed it, not as the session
  /// state holds it under the same ID now.
  Decide(review: approval.Review, choice: operator.Choice)

  /// Switch the active strand to the catalogue model `name`.
  SelectModel(name: String)

  /// End the session's half of the attachment: close the adopted lane and
  /// mark the session as ending. The host cancels its own work after it.
  Quit
}
