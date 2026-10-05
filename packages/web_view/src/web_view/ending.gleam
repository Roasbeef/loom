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

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The most pages one principal holds for one session at once.
///
/// The daemon enforces it (`client/daemon/ui_sessions.max_pages`, which
/// says why the number is four and why the oldest page ends rather than the
/// new link being refused). It is a constant here because the words
/// `PageEnded` shows name it, and a sentence that states the number beside
/// a bound that has another would be a lie the tests cannot see.
pub const max_pages = 4

/// Why a page has no session.
pub type Ending {
  /// The page's own UI session is gone: its eight hours ran out, the daemon
  /// restarted and forgot every page, or it was the oldest of `max_pages`
  /// and a newer link took its place. The daemon keeps no record of which,
  /// so this is all it can say. A newer link ends a page only at that
  /// bound; a principal may hold several pages for one session.
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

/// What a person can do about an ending: a lead that says why it happened and
/// what to try first, and the command that mints a fresh link when one would
/// help. The command is separate from the lead so the document a refused
/// request gets can draw it as a chip with a copy button, and the live notice
/// can say it in a sentence; `advice` is that sentence.
pub type Advice {
  Advice(
    /// The sentences before the command: why the page has no session and what
    /// to try first.
    lead: String,
    /// The command a person runs in a terminal for a fresh link, or `None` for
    /// an ending a fresh link would not help.
    command: Option(String),
  )
}

/// The advice for a session's page: `lead` and, where a fresh link helps, the
/// command that mints one. `session_id` is the session's canonical identity,
/// which the daemon's router parsed before any page existed, and it names the
/// command.
///
/// ## Examples
///
/// ```gleam
/// assert ending.advised(ending.LinkExpired, "0192ab").command
///   == Some("loom ui --session 0192ab")
/// ```
pub fn advised(ending: Ending, session_id: String) -> Advice {
  let command = Some("loom ui --session " <> session_id)
  case ending {
    PageEnded ->
      Advice(
        "A page lasts eight hours, and the daemon forgets every page when it "
          <> "restarts. You can also have "
          <> int.to_string(max_pages)
          <> " pages open for a session at once; opening another ends the "
          <> "oldest.",
        command,
      )
    AccessRevoked ->
      Advice("Ask the session's owner to restore your access.", command)
    SessionStopped ->
      Advice(
        "Open the session again, then reload this page. The page's own link "
          <> "still works, so a fresh one is not needed.",
        None,
      )
    NotOpen ->
      Advice(
        "The daemon may still be opening it. Reload this page in a moment. "
          <> "If it stays closed, it needs a new link.",
        command,
      )
    DaemonNotReady ->
      Advice(
        "It may still be starting. Reload this page in a moment. If it keeps "
          <> "failing, it needs a new link.",
        command,
      )
    LinkExpired -> Advice("A link works once, within 60 seconds.", command)
    ConnectionFailed ->
      Advice(
        "Reload this page. If it fails again, it needs a new link.",
        command,
      )
  }
}

/// The text after the headline: why it happens, where that is known, and what
/// to do, as one run of sentences. It is `advised` said aloud, with the command
/// in backticks.
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
  sentence(advised(ending, session_id))
}

// The advice as the live notice says it.
fn sentence(advice: Advice) -> String {
  case advice.command {
    Some(command) -> advice.lead <> " Run " <> command <> " for a fresh link."
    None -> advice.lead
  }
}

/// `headline` for a home page (protocol-change/065), which has no session to
/// be revoked from or to stop. An ending only a session page can reach reads
/// as a failed connection.
///
/// ## Examples
///
/// ```gleam
/// assert ending.home_headline(ending.AccessRevoked)
///   == "Your access was revoked or changed."
/// ```
pub fn home_headline(ending: Ending) -> String {
  case ending {
    PageEnded -> "This page has ended."
    AccessRevoked -> "Your access was revoked or changed."
    DaemonNotReady -> "The daemon was not ready."
    LinkExpired -> "This link has expired or was already used."
    SessionStopped | NotOpen | ConnectionFailed ->
      "The connection to the daemon failed."
  }
}

/// `advised` for a home page: the same reasons, and a fresh link that is
/// `loom ui` with no session.
///
/// ## Examples
///
/// ```gleam
/// assert ending.home_advised(ending.LinkExpired).command == Some("loom ui")
/// ```
pub fn home_advised(ending: Ending) -> Advice {
  let command = Some("loom ui")
  case ending {
    PageEnded ->
      Advice(
        "A page lasts eight hours, and the daemon forgets every page when it "
          <> "restarts. You can also have "
          <> int.to_string(max_pages)
          <> " home pages open at once; opening another ends the oldest.",
        command,
      )
    AccessRevoked -> Advice("Ask the owner to restore your access.", command)
    DaemonNotReady ->
      Advice(
        "It may still be starting. Reload this page in a moment. If it keeps "
          <> "failing, it needs a new link.",
        command,
      )
    LinkExpired -> Advice("A link works once, within 60 seconds.", command)
    SessionStopped | NotOpen | ConnectionFailed ->
      Advice(
        "Reload this page. If it fails again, it needs a new link.",
        command,
      )
  }
}

/// `headline` for the admin page (protocol-change/065, the fifth pull
/// request). It is the home's, with the words for an ending only the admin page
/// has: the page's fifteen minutes.
///
/// ## Examples
///
/// ```gleam
/// assert ending.admin_headline(ending.PageEnded) == "This admin page has ended."
/// ```
pub fn admin_headline(ending: Ending) -> String {
  case ending {
    PageEnded -> "This admin page has ended."
    AccessRevoked -> "Your access was revoked or changed."
    DaemonNotReady -> "The daemon was not ready."
    LinkExpired -> "This link has expired or was already used."
    SessionStopped | NotOpen | ConnectionFailed ->
      "The connection to the daemon failed."
  }
}

/// `advised` for the admin page: an admin page lasts fifteen minutes, and a
/// fresh one is `loom ui` and the home's "Admin" button, which is why the
/// command is the home's.
///
/// ## Examples
///
/// ```gleam
/// assert ending.admin_advised(ending.LinkExpired).command == Some("loom ui")
/// ```
pub fn admin_advised(ending: Ending) -> Advice {
  let command = Some("loom ui")
  let fresh = " Then press Admin on the home page for a fresh admin page."
  case ending {
    PageEnded ->
      Advice(
        "An admin page lasts fifteen minutes, and the daemon forgets every "
          <> "page when it restarts."
          <> fresh,
        command,
      )
    AccessRevoked ->
      Advice("Ask the owner to restore your access." <> fresh, command)
    DaemonNotReady ->
      Advice(
        "It may still be starting. Reload this page in a moment. If it keeps "
          <> "failing, it needs a new link."
          <> fresh,
        command,
      )
    LinkExpired ->
      Advice("A link works once, within 60 seconds." <> fresh, command)
    SessionStopped | NotOpen | ConnectionFailed ->
      Advice(
        "Reload this page. If it fails again, it needs a new link." <> fresh,
        command,
      )
  }
}

/// `advice` for the admin page: `admin_advised` said as a sentence.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(ending.admin_advice(ending.PageEnded), "fifteen minutes")
/// ```
pub fn admin_advice(ending: Ending) -> String {
  sentence(admin_advised(ending))
}

/// `advice` for a home page: `home_advised` said as a sentence.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(ending.home_advice(ending.LinkExpired), "loom ui")
/// ```
pub fn home_advice(ending: Ending) -> String {
  sentence(home_advised(ending))
}
