//// A terminal-owned inbox together with the messages already taken out of
//// its mailbox.
////
//// The terminal's step reads no mailbox. Before each step the host reads a
//// bounded number of waiting messages for every inbox the model holds
//// (`waiting`), and the step files them into the `Inbox` value
//// (`push`, from `tui/admission`); the reducers then take from that value
//// where they used to call `process.receive(subject, 0)`. `waiting` is the
//// only function here that reads a mailbox for the step, and `push` and
//// `take` are pure.
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
//// Every read names its room, and the room is the most the next step can
//// consume from that inbox less what it holds, so nothing buffers without
//// limit. Filing never drops a message; the bound is kept by reading no
//// more than there is room for.

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
    /// Every read is bounded, so the list is short.
    held: List(a),
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
  Inbox(subject:, held: [])
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

/// How many received messages the inbox holds.
///
/// ## Examples
///
/// ```gleam
/// assert buffered.held(buffered.new(process.new_subject())) == 0
/// ```
pub fn held(inbox: Inbox(a)) -> Int {
  list.length(inbox.held)
}

/// Moves waiting messages out of the mailbox until the inbox holds
/// `up_to`, without blocking.
///
/// This is `waiting` followed by `push` for each message. No source module
/// calls it since phase 3, when the host began reading with `waiting` and
/// admission filing with `push`. It is kept because it is phase 2's receive
/// for one inbox: `admission_test` uses it as the reference its generated
/// runs are compared against, and tests use it to fill an inbox directly.
/// An inbox that already holds `up_to` or more reads nothing.
///
/// ## Examples
///
/// ```gleam
/// let inbox = buffered.top_up(inbox, up_to: 64)
/// ```
pub fn top_up(inbox: Inbox(a), up_to limit: Int) -> Inbox(a) {
  list.fold(waiting(inbox.subject, limit - held(inbox)), inbox, push)
}

/// Reads up to `room` messages waiting in a subject's mailbox, oldest
/// first, without blocking.
///
/// The host calls this before a step with the room an inbox has left, the
/// most the step can take from it less what the inbox already holds, and
/// hands the messages to the step to file. What it does not read stays in
/// the mailbox, behind everything it did, so no buffer grows past its bound
/// and nothing is dropped.
///
/// ## Examples
///
/// ```gleam
/// let fresh = buffered.waiting(buffered.sender(inbox), 64 - buffered.held(inbox))
/// ```
pub fn waiting(subject: Subject(a), room: Int) -> List(a) {
  receive_waiting(subject, room, []) |> list.reverse
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

/// Appends a message behind everything held.
///
/// This is for a reader outside the step that selected the message from the
/// mailbox itself, as a test driver does. The runtime took every held
/// message out of that mailbox earlier, so the selected one is newer than
/// all of them and its place is at the tail. Appending it there lets the
/// caller advance with the same `take` the step uses, rather than a second
/// path that handles the selected message on its own.
///
/// ## Examples
///
/// ```gleam
/// let frames = buffered.push(frames, selected)
/// ```
pub fn push(inbox: Inbox(a), message: a) -> Inbox(a) {
  Inbox(..inbox, held: list.append(inbox.held, [message]))
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
    [message, ..rest] -> #(Inbox(..inbox, held: rest), Ok(message))
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

// A discard stops after this many messages, so an inbox a live producer
// is still filling cannot hold the caller in a loop.
const discard_limit = 4096

/// Drops up to 4096 messages waiting in a subject's mailbox.
///
/// The runtime calls this, as the `Discard` effect and when it cleans up an
/// attempt it will not adopt, for an inbox the model has stopped reading: a
/// replaced connection's, or an abandoned attempt's frames. Frames nobody
/// will read would otherwise stay in the terminal's mailbox, where every
/// later selective receive scans past them. A socket that is still closing
/// may add one final notice after this returns.
///
/// ## Examples
///
/// ```gleam
/// buffered.discard(buffered.sender(model.inbox))
/// ```
pub fn discard(subject: Subject(a)) -> Nil {
  discard_up_to(subject, discard_limit)
}

fn discard_up_to(subject: Subject(a), remaining: Int) -> Nil {
  case remaining <= 0, process.receive(subject, 0) {
    True, _ | _, Error(Nil) -> Nil
    False, Ok(_) -> discard_up_to(subject, remaining - 1)
  }
}
