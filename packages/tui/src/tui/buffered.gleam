//// A terminal-owned inbox together with the messages already taken out of
//// its mailbox.
////
//// The terminal's step reads no mailbox. Before each step the runtime tops
//// up every inbox the model holds, moving a bounded number of waiting
//// messages out of the BEAM mailbox and into the `Inbox` value, and the
//// reducers then take from that value where they used to call
//// `process.receive(subject, 0)`. `top_up` is the only function here that
//// reads a mailbox for the step, and `take` is pure.
////
//// The received messages live inside the inbox value rather than in a table
//// beside the model, and that is what makes an adoption safe by
//// construction. When an adoption replaces `Model.inbox`, the old inbox
//// leaves the model with its buffer, so nothing it had already received can
//// be reduced afterwards; there is no second place where a stale buffer
//// could outlive the swap. That is the rule the terminal-attachment P model
//// checks as S2: no message from a replaced inbox reaches the reducer after
//// the swap.
////
//// A message is moved out of the mailbox exactly once, so whatever is held
//// is older than everything still in the mailbox. A reader outside the step
//// that waits on the inbox must therefore use `receive`, which returns the
//// held head first and only then waits on the mailbox. Reading the subject
//// directly, through `sender`, would let a newer message overtake the held
//// ones.
////
//// Every top-up names its bound, and the bound is the most the next step can
//// consume from that inbox, so nothing buffers without limit.

import gleam/erlang/process.{type Subject}
import gleam/list

/// A terminal-created subject and the messages already received from it,
/// oldest first.
pub opaque type Inbox(a) {
  Inbox(
    /// The subject the producers send to. Only the terminal process, which
    /// created it, can receive from it.
    subject: Subject(a),
    /// Messages moved out of the mailbox and not yet taken, oldest first.
    held: List(a),
    /// The length of `held`, kept so a top-up does not measure the list.
    count: Int,
  )
}

/// Wraps a subject the calling process owns, with nothing held.
///
/// ## Examples
///
/// ```gleam
/// let inbox = buffered.new(connection.new_inbox())
/// ```
pub fn new(subject: Subject(a)) -> Inbox(a) {
  Inbox(subject:, held: [], count: 0)
}

/// The subject producers send to.
///
/// Receiving from it bypasses the buffer: a message read that way can be
/// newer than one this inbox already holds. It is for handing to a producer,
/// such as a socket or a worker, for discarding what is left in the mailbox
/// once the inbox is dropped, and for tests that inject a message. Readers
/// use `take` inside the step and `receive` outside it.
///
/// ## Examples
///
/// ```gleam
/// process.send(buffered.sender(model.inbox), connection.Connected)
/// ```
pub fn sender(inbox: Inbox(a)) -> Subject(a) {
  inbox.subject
}

/// Reports whether a subject is the one this inbox receives from.
///
/// A selected event carries the subject it came from, and this is how an
/// event from an inbox the model no longer holds is recognised as stale.
///
/// ## Examples
///
/// ```gleam
/// assert buffered.is_sender(inbox, buffered.sender(inbox))
/// ```
pub fn is_sender(inbox: Inbox(a), subject: Subject(a)) -> Bool {
  inbox.subject == subject
}

/// How many received messages the inbox holds.
///
/// ## Examples
///
/// ```gleam
/// assert buffered.held(buffered.new(process.new_subject())) == 0
/// ```
pub fn held(inbox: Inbox(a)) -> Int {
  inbox.count
}

/// Moves waiting messages out of the mailbox until the inbox holds
/// `up_to`, without blocking.
///
/// The runtime calls this before a step, with the most that step can take
/// from the inbox. An inbox that already holds `up_to` or more reads
/// nothing, so an inbox the step did not drain does not grow.
///
/// ## Examples
///
/// ```gleam
/// let inbox = buffered.top_up(inbox, up_to: 64)
/// ```
pub fn top_up(inbox: Inbox(a), up_to limit: Int) -> Inbox(a) {
  let fresh = receive_waiting(inbox.subject, limit - inbox.count, [])
  case fresh {
    [] -> inbox
    _ ->
      Inbox(
        ..inbox,
        held: list.append(inbox.held, list.reverse(fresh)),
        count: inbox.count + list.length(fresh),
      )
  }
}

// The budget is checked before each receive, because a message received
// past it could not be put back behind the ones still in the mailbox.
fn receive_waiting(subject: Subject(a), remaining: Int, newest_first: List(a)) {
  case remaining <= 0 {
    True -> newest_first
    False ->
      case process.receive(subject, 0) {
        Error(Nil) -> newest_first
        Ok(message) ->
          receive_waiting(subject, remaining - 1, [message, ..newest_first])
      }
  }
}

/// Takes the oldest held message, reading no mailbox.
///
/// This is how a reducer reads an inbox: it sees what the runtime received
/// before the step and nothing that arrived during it.
///
/// ## Examples
///
/// ```gleam
/// let #(inbox, next) = buffered.take(model.inbox)
/// ```
pub fn take(inbox: Inbox(a)) -> #(Inbox(a), Result(a, Nil)) {
  case inbox.held {
    [] -> #(inbox, Error(Nil))
    [message, ..rest] -> #(
      Inbox(..inbox, held: rest, count: inbox.count - 1),
      Ok(message),
    )
  }
}

/// Returns the oldest held message, or waits up to `within_ms` on the
/// mailbox when nothing is held.
///
/// This is the read for code outside the step, such as a test driver or an
/// effect that cleans up an abandoned attempt. Because a held message is
/// always older than anything left in the mailbox, taking the held head
/// first is what keeps such a reader from reducing a newer message ahead
/// of an older one.
///
/// ## Examples
///
/// ```gleam
/// let #(inbox, next) = buffered.receive(model.inbox, 1000)
/// ```
pub fn receive(inbox: Inbox(a), within_ms: Int) -> #(Inbox(a), Result(a, Nil)) {
  case take(inbox) {
    #(inbox, Ok(message)) -> #(inbox, Ok(message))
    #(inbox, Error(Nil)) -> #(inbox, process.receive(inbox.subject, within_ms))
  }
}
