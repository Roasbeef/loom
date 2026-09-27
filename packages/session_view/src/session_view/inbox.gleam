//// The messages a host has received from one source and not yet reduced,
//// oldest first, as a value.
////
//// A host reads its mailbox before a step and files what it read here; the
//// step's reducers then take from this value in a fixed order. The buffer is
//// the pure half of that arrangement. The other half, reading a mailbox, is
//// the host's and stays with the host: the terminal's is `tui/buffered`,
//// over an Erlang subject, and the web view's is a Lustre selector.
////
//// The source is whatever the host uses to tell one socket's traffic from
//// another's, and the buffer only carries it. The terminal's source is the
//// subject a socket delivers to, and admission files a frame only into the
//// inbox whose source names it. An adoption replaces the whole inbox value,
//// so the held messages of a replaced socket leave with it and cannot reach
//// a reducer after the swap, which is the rule the terminal-attachment P
//// model checks as S2.
////
//// Filing never drops a message. The bound on what an inbox holds is the
//// host's to keep, by reading no more than the next step can take.

import gleam/list

/// One source's received messages, oldest first.
pub opaque type Inbox(source, a) {
  Inbox(
    /// The host's name for where these messages came from.
    source: source,
    /// Messages received and not yet taken, oldest first. Every read that
    /// fills it is bounded, so the list is short.
    held: List(a),
  )
}

/// An inbox for `source` holding nothing.
///
/// ## Examples
///
/// ```gleam
/// assert inbox.held(inbox.new("socket")) == 0
/// ```
pub fn new(source: source) -> Inbox(source, a) {
  Inbox(source:, held: [])
}

/// The host's name for where these messages came from.
///
/// ## Examples
///
/// ```gleam
/// assert inbox.source(inbox.new("socket")) == "socket"
/// ```
pub fn source(inbox: Inbox(source, a)) -> source {
  inbox.source
}

/// How many received messages the inbox holds.
///
/// ## Examples
///
/// ```gleam
/// assert inbox.held(inbox.push(inbox.new(Nil), 1)) == 1
/// ```
pub fn held(inbox: Inbox(source, a)) -> Int {
  list.length(inbox.held)
}

/// Appends a message behind everything held.
///
/// A message is received from its mailbox exactly once, so it is newer than
/// everything the inbox already holds, and its place is at the tail.
///
/// ## Examples
///
/// ```gleam
/// let inbox = inbox.push(inbox, message)
/// ```
pub fn push(inbox: Inbox(source, a), message: a) -> Inbox(source, a) {
  Inbox(..inbox, held: list.append(inbox.held, [message]))
}

/// Takes the oldest held message.
///
/// This is how a reducer reads an inbox: it sees what the host received
/// before the step and nothing that arrived during it.
///
/// ## Examples
///
/// ```gleam
/// let #(inbox, next) = inbox.take(inbox)
/// ```
pub fn take(inbox: Inbox(source, a)) -> #(Inbox(source, a), Result(a, Nil)) {
  case inbox.held {
    [] -> #(inbox, Error(Nil))
    [message, ..rest] -> #(Inbox(..inbox, held: rest), Ok(message))
  }
}
