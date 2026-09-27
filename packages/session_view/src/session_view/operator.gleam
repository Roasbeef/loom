//// What an operator's client sends to a session, and how a host feeds the
//// lane what it received.
////
//// Two hosts drive the same lane: the terminal and the web view. Each has
//// its own way to take input (a key in an etui editor, a submitted form in
//// a browser) and its own model around the lane, but what an operator's
//// input becomes on the wire is one decision, and it lives here so that
//// both hosts make it the same way. A prompt or a steer becomes one
//// command frame on the addressed strand. An answer to an escalation
//// becomes an `approve` or `deny` that echoes exactly the record the
//// operator was shown, with its sequence, its action digest and its grants
//// (`session_view/approval`), so a record that moved after it was drawn is
//// refused by the gateway rather than decided.
////
//// Every function here takes the lane and returns it with the
//// `session_channel.Disposition` its submission earned, and reads nothing
//// else of a host. The lane decides whether the frame is sent now, waits
//// behind a capture, or is refused; what a host does with that answer
//// (clear its draft, show a notice) is presentation and stays with the
//// host.
////
//// `drain` is the other half of a host's reduction: the loop that hands
//// the lane what the host received, oldest first and bounded, at the fixed
//// points the reducers choose (a tick, or a key after Escape has had its
//// chance to cancel). The terminal and the web view both run it, over
//// their own model and their own inbox.

import gleam/list
import session_view/approval
import session_view/protocol
import session_view/session_channel.{type Channel, type Disposition}

/// How an operator's text reaches the strand it addresses.
pub type Delivery {
  /// A `prompt`: a turn of its own. On a busy strand the daemon holds it
  /// and runs it when the current operation settles.
  Prompt

  /// A `steer`: folded into the operation that is already running.
  Steer
}

/// An operator's answer to one pending escalation.
pub type Choice {
  /// Grant the displayed authority for this one request.
  AllowOnce

  /// Grant it and remember it for the session, where every grant is
  /// eligible (`approval.rememberable`).
  AllowForSession

  /// Refuse the request.
  Deny
}

/// Submits an operator's text to `strand` through the lane.
///
/// `id` is the host's command counter; the lane allocates the wire's own
/// request identity when it sends. `now` is the host's transport clock,
/// which the lane measures the request's deadline against.
///
/// ## Examples
///
/// ```gleam
/// let #(lane, disposition) =
///   operator.submit(lane, 1, "main", "inspect the tree", operator.Prompt, now)
/// ```
pub fn submit(
  lane: Channel(socket, recorder),
  id: Int,
  strand: String,
  text: String,
  delivery: Delivery,
  now: Int,
) -> #(Channel(socket, recorder), Disposition) {
  session_channel.submit(lane, frame(id, strand, text, delivery), now:)
}

/// The command frame an operator's text becomes.
///
/// ## Examples
///
/// ```gleam
/// operator.frame(1, "main", "inspect the tree", operator.Prompt)
/// ```
pub fn frame(
  id: Int,
  strand: String,
  text: String,
  delivery: Delivery,
) -> String {
  case delivery {
    Prompt -> protocol.prompt(id, strand, text)
    Steer -> protocol.steer(id, strand, text)
  }
}

/// Encodes an operator's answer to the escalation `record`, echoing the
/// record exactly as it was drawn.
///
/// An answer the record cannot carry is refused with the reason: approval
/// of a record whose authority was not captured whole, or remembering a
/// grant set that is not eligible. Denial is always available.
///
/// ## Examples
///
/// ```gleam
/// operator.decision(1, record, operator.Deny)
/// ```
pub fn decision(
  id: Int,
  record: approval.Review,
  choice: Choice,
) -> Result(String, String) {
  case choice {
    AllowOnce -> approval.approve(id, record)
    AllowForSession -> approval.approve_for_session(id, record)
    Deny -> approval.deny(id, record)
  }
}

/// Submits an operator's answer to the escalation `record` through the
/// lane, or refuses it with the reason `decision` gives.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(lane, disposition)) =
///   operator.decide(lane, 1, record, operator.Deny, now)
/// ```
pub fn decide(
  lane: Channel(socket, recorder),
  id: Int,
  record: approval.Review,
  choice: Choice,
  now: Int,
) -> Result(#(Channel(socket, recorder), Disposition), String) {
  case decision(id, record, choice) {
    Error(reason) -> Error(reason)
    Ok(encoded) -> Ok(session_channel.submit(lane, encoded, now:))
  }
}

/// The pending escalation a host drew as `id` at `seq`, if it is still the
/// one the host holds.
///
/// A host names a decision by the record it drew. By the time the answer
/// arrives the record may have been decided by someone else or reopened at
/// a new sequence, and answering the new one with a click meant for the old
/// one would decide something the operator never saw. So a record is found
/// only when both its identity and its sequence match and it is still
/// pending.
///
/// ## Examples
///
/// ```gleam
/// operator.drawn(approvals, "esc-1", 12)
/// ```
pub fn drawn(
  approvals: List(approval.Review),
  id: String,
  seq: Int,
) -> Result(approval.Review, Nil) {
  list.find(approvals, fn(record) {
    record.id == id && record.seq == seq && record.status == approval.Pending
  })
}

/// Hands at most `budget` of what a host holds to `handle`, oldest first.
///
/// `take` removes the oldest held message from the host's state, and
/// `handle` reduces one message, typically by passing it to
/// `session_channel.receive` and applying the updates that returns. The
/// budget is checked before each take, so a message beyond it stays held
/// for the next drain rather than being taken and lost. Each message is
/// taken from the state `handle` left, so a drain that follows an adoption
/// reads the adopted inbox.
///
/// ## Examples
///
/// ```gleam
/// operator.drain(model, 64, take_connection, handle_connection_message)
/// ```
pub fn drain(
  state: state,
  budget: Int,
  take: fn(state) -> #(state, Result(message, Nil)),
  handle: fn(state, message) -> state,
) -> state {
  case budget <= 0 {
    True -> state
    False ->
      case take(state) {
        #(state, Error(Nil)) -> state
        #(state, Ok(message)) ->
          drain(handle(state, message), budget - 1, take, handle)
      }
  }
}
