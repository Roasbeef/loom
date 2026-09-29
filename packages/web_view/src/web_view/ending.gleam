//// Why a page has no session, in words a person can act on.
////
//// A page can be without its session for several reasons the person can do
//// something about: a newer link ended it, the session stopped, the daemon
//// was still starting, the link had expired. Each is one variant of
//// `Ending`, a closed type, and everything the page says about it is a fixed
//// string chosen by the variant. Nothing here is built from text a peer, a
//// session or an error message supplied: the relay and the daemon's routes
//// name a variant, and a reason that names none of them is drawn as
//// `ConnectionFailed`, so an unforeseen diagnostic never reaches a browser
//// (protocol-change/051, the addendum on an ended page).
////
//// The variants travel between processes as the reason string a
//// `connection_event.Closed` carries, which is the session engine's type and
//// holds a plain `String`. `reason` and `from_reason` are the two halves of
//// that hop, and they are exact inverses over `all`, which a test holds them
//// to. The daemon's page socket also asks `close` how to end its WebSocket:
//// Lustre's client runtime reconnects after any close code but 1000 and
//// treats 1000 as final, so an ending the person must resolve closes with
//// 1000 and one that may clear by itself closes with a code the client
//// retries.
////
//// This module is pure text and decisions. `web_view/view/ended` draws an
//// ending into the live page, and `web_view/page` draws one into the
//// document a browser gets when it asks for a page that has ended.

import gleam/list
import gleam/result

/// Why a page has no session.
pub type Ending {
  /// The page's own UI session is gone. Opening a new link for a session
  /// ends the principal's earlier page for it, and a page lasts eight hours;
  /// the daemon keeps no record of which of the two it was, and a daemon
  /// that restarted forgets every page, so this is all it can say.
  PageEnded

  /// The credential behind the page, or the membership it stood on, was
  /// revoked or changed while the page was open.
  AccessRevoked

  /// The session stopped, or the daemon shut it down, under the page.
  SessionStopped

  /// The session is not open on the daemon: it is opening, or saved, or its
  /// gateway is not running. The daemon may open it again.
  NotOpen

  /// The daemon was starting, stopping or too slow to answer.
  DaemonNotReady

  /// The link was already used, or its 60 seconds passed.
  LinkExpired

  /// The connection failed for a reason the page does not name.
  ConnectionFailed
}

/// How the page's WebSocket should end, for the client runtime that reads
/// the close code.
pub type Close {
  /// Close with 1000. The runtime does not reconnect, so the notice the page
  /// drew stays, and the person resolves it.
  Final

  /// Close with a code other than 1000. The runtime reconnects after a
  /// backoff of at most ten seconds, which is what the ending may need.
  Retry
}

/// Every ending, in the order the documentation lists them.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(ending.all(), ending.PageEnded)
/// ```
pub fn all() -> List(Ending) {
  [
    PageEnded,
    AccessRevoked,
    SessionStopped,
    NotOpen,
    DaemonNotReady,
    LinkExpired,
    ConnectionFailed,
  ]
}

/// The reason string that carries an ending between processes.
///
/// The strings are the ones the relay has always sent for the endings it
/// knew, so a lane's recorded reason reads the same.
///
/// ## Examples
///
/// ```gleam
/// assert ending.reason(ending.SessionStopped) == "the session ended"
/// ```
pub fn reason(ending: Ending) -> String {
  case ending {
    PageEnded -> "the page session ended"
    AccessRevoked -> "access was revoked"
    SessionStopped -> "the session ended"
    NotOpen -> "the session is not open"
    DaemonNotReady -> "the daemon was not ready"
    LinkExpired -> "the link expired"
    ConnectionFailed -> "the connection failed"
  }
}

/// The ending a reason string names, or `otherwise` when it names none.
///
/// A reason the daemon composed for its own log, or one a lane failed with,
/// is not one of the fixed strings and is never drawn; the caller says what
/// an unrecognised reason stands for at its own boundary.
///
/// ## Examples
///
/// ```gleam
/// assert ending.from_reason("access was revoked", ending.ConnectionFailed)
///   == ending.AccessRevoked
/// assert ending.from_reason("gateway unavailable", ending.NotOpen)
///   == ending.NotOpen
/// ```
pub fn from_reason(given: String, otherwise otherwise: Ending) -> Ending {
  list.find(all(), fn(ending) { reason(ending) == given })
  |> result.unwrap(otherwise)
}

/// How the page's socket ends for this ending.
///
/// An ending the person has to resolve is `Final`: a reconnect would be
/// refused the same way, every ten seconds, behind a notice that never
/// changes. One the daemon may clear on its own is `Retry`: it was still
/// starting, or the session was still opening.
///
/// ## Examples
///
/// ```gleam
/// assert ending.close(ending.PageEnded) == ending.Final
/// assert ending.close(ending.NotOpen) == ending.Retry
/// ```
pub fn close(ending: Ending) -> Close {
  case ending {
    NotOpen | DaemonNotReady -> Retry
    PageEnded
    | AccessRevoked
    | SessionStopped
    | LinkExpired
    | ConnectionFailed -> Final
  }
}

/// The one line that says what happened.
///
/// ## Examples
///
/// ```gleam
/// assert ending.headline(ending.PageEnded) == "This page has ended."
/// ```
pub fn headline(ending: Ending) -> String {
  case ending {
    PageEnded -> "This page has ended."
    AccessRevoked -> "Your access to this session was revoked or changed."
    SessionStopped -> "The session stopped."
    NotOpen -> "The session is not open."
    DaemonNotReady -> "The daemon was not ready."
    LinkExpired -> "This link has expired or was already used."
    ConnectionFailed -> "The connection to the session failed."
  }
}

/// The text after the headline: why it happens, where that is known, and what
/// to do. `session_id` is the session's canonical identity, which the
/// daemon's router parsed before any page existed, and it names the command
/// that mints a fresh link.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   ending.advice(ending.PageEnded, "0192ab"),
///   "loom ui --session 0192ab",
/// )
/// ```
pub fn advice(ending: Ending, session_id: String) -> String {
  case ending {
    PageEnded ->
      "Opening a new link for a session ends the page you had open before it, "
      <> "and a page lasts eight hours. "
      <> fresh_link(session_id)
    AccessRevoked ->
      "Ask the session's owner to restore your access. Then "
      <> fresh_link(session_id)
    SessionStopped -> "Open the session again. Then " <> fresh_link(session_id)
    NotOpen ->
      "The daemon may still be opening it. Reload this page in a moment. "
      <> "If it stays closed, "
      <> fresh_link(session_id)
    DaemonNotReady ->
      "It may still be starting. Reload this page in a moment. If it keeps "
      <> "failing, "
      <> fresh_link(session_id)
    LinkExpired ->
      "A link works once, within 60 seconds. " <> fresh_link(session_id)
    ConnectionFailed ->
      "Reload this page. If it fails again, " <> fresh_link(session_id)
  }
}

// The sentence every ending that needs a new link ends with. It names a
// command the person runs in a terminal; the page never runs it.
fn fresh_link(session_id: String) -> String {
  "Run `loom ui --session " <> session_id <> "` for a fresh link."
}
