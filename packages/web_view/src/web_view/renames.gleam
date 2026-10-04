//// Renaming a session from its page: what the page asks, what the daemon
//// answers, and the fixed words for each refusal (protocol-change/067).
////
//// A display name is catalogue metadata the owner already changes with the
//// control command `sessions.rename` (protocol-change/019). The page makes the
//// same change through the same registry call, as the owner's own credential,
//// and the page holds no authority of its own to do it with
//// (`ui_relay.capped`). The page therefore sends one value, the name the owner
//// typed. Which session, who is asking and whether they may are all the
//// daemon's: it reads them from the attachment the router authenticated,
//// again at the moment of the click, and nothing on the page can name a
//// different session or a different principal.
////
//// The words a page shows for a refusal are fixed here, so no text the daemon
//// or the catalogue produced reaches a browser. A name that was accepted is
//// echoed back to the page as the daemon stored it, which is a text node
//// wherever it is drawn.

/// What the daemon answers to a request to rename.
pub type Answer {
  /// The daemon stored the name. The name is the one the catalogue now holds,
  /// which the page draws in the heading and the sidebar.
  Renamed(name: String)

  /// The daemon stored nothing.
  Declined(reason: Reason)
}

/// Why the daemon renamed nothing. Every page shows the fixed words for the
/// reason (`reason_words`).
pub type Reason {
  /// The page's principal is not the daemon's owner, the page has ended, or
  /// the session is not one the owner's catalogue holds. One answer for each,
  /// so a page learns nothing else about its standing.
  NotOwner

  /// The name breaks the rule for a display name: it is blank, longer than 256
  /// bytes, or holds a control, zero-width or direction-changing character.
  InvalidName

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// catalogue refused the write.
  Unavailable
}

/// What the page's rename control is doing. It is a page's own state and
/// nothing the session records.
pub type Control {
  /// The page's principal cannot rename, and the page draws no control. An
  /// observer's page is always here, and so is a member operator's.
  Withheld

  /// The control is drawn and waits for the owner to submit a name.
  Ready

  /// A request is with the daemon. A submit meanwhile is ignored, so one submit
  /// renames at most once.
  Asking

  /// The daemon stored the name, and the control says so.
  Done

  /// The daemon stored nothing, and the control says why in the reason's fixed
  /// words.
  Refused(reason: Reason)
}

/// The words a page shows for a declined rename. They are fixed here, one per
/// reason, so nothing the daemon wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert renames.reason_words(renames.NotOwner)
///   == "Only the owner can rename a session from a page."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can rename a session from a page."
    InvalidName ->
      "A name needs 1 to 256 bytes, with no control or invisible characters."
    Unavailable -> "The daemon could not rename the session. Try again."
  }
}
