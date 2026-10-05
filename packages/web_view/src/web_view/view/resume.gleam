//// What a page offers for a saved session's row: nothing, a button that asks
//// the daemon to open it, or the row whose open is out.
////
//// The sidebar and the home's table draw the same rows, and both must agree on
//// which saved rows may be pressed, so the rule is written here once
//// (protocol-change/065, the third pull request). A saved row is a button only
//// on a page that was minted to operate and only while no other open is out.
//// A session that is `Blocked` (its creation was never reconciled, or recovery
//// stopped it) and a session that a process runs are never this module's: the
//// first is text at every ceiling, and the second opens by a ticket.
////
//// While an open is out the page draws that row as "opening" and every other
//// saved row as text. That is the page's half of "a second press asks
//// nothing": a row with no handler cannot be pressed, even by a frame that
//// names the path it used to have. The component's update ignores a second
//// press as well, and the daemon's own refusal is the third layer, so each is
//// enough alone.
////
//// The message a press sends is the caller's, applied to the catalogue's
//// identity drawn into the tree by the server. The browser's event names only
//// the path it fired at, never a session.

import gleam/option.{type Option, None, Some}
import web_view/sessions.{type Entry, Blocked, Live, Saved}

/// What a page offers for saved sessions.
pub type Resume(message) {
  /// The page was not minted to operate, so a saved row is text. The daemon
  /// refuses a forged press from such a page all the same.
  Never

  /// The page may ask the daemon to open a saved session. `press` is the
  /// message a press sends, given the session's identity, and `pending` is the
  /// session whose open is out, if one is.
  Offered(press: fn(String) -> message, pending: Option(String))
}

/// What a row draws in its place.
pub type Kind(message) {
  /// The row is words only.
  Text

  /// The row is a button whose press sends this message.
  Button(press: message)

  /// The row is words that say its open is out.
  Opening
}

/// What `entry`'s row draws on a page that offers `resume`.
///
/// ## Examples
///
/// ```gleam
/// assert resume.kind(resume.Never, saved_entry) == resume.Text
/// ```
pub fn kind(resume: Resume(message), entry: Entry) -> Kind(message) {
  case entry.residency, resume {
    Live, _ | Blocked, _ | Saved, Never -> Text
    Saved, Offered(press:, pending: None) -> Button(press(entry.id))
    Saved, Offered(pending: Some(session), ..) ->
      case session == entry.id {
        True -> Opening
        False -> Text
      }
  }
}

/// The session whose open is out, which a memoized view includes in its key so
/// that a row changes when it starts and when it ends.
///
/// ## Examples
///
/// ```gleam
/// assert resume.pending(resume.Never) == None
/// ```
pub fn pending(resume: Resume(message)) -> Option(String) {
  case resume {
    Never -> None
    Offered(pending:, ..) -> pending
  }
}
