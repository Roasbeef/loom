//// Renaming oneself from the home page: what the page asks, what the daemon
//// answers, and the fixed words for each refusal (protocol-change/065, the
//// tenth pull request).
////
//// A display name is catalogue metadata the person chose when they were invited
//// or claimed, and the control command `principals.rename` changes it. The home
//// makes the same change through the same registry call, as the page's own
//// credential, from the "Your name" control in the account panel the person's
//// name in the bar opens. The page therefore sends one value, the name the
//// person typed. Whose name it is, whether the page may change it and whether
//// the name is one a display name may be are all the daemon's: it reads the
//// principal from the attachment the router authenticated, again at the moment
//// of the submit, and nothing on the page can name a different principal.
////
//// The owner renames anyone else from the admin page, which has its own
//// vocabulary for it (`web_view/grants`). This module is only the home's,
//// because the home may rename its own principal and no other.
////
//// The words a page shows for a refusal are fixed here, so no text the daemon or
//// the catalogue produced reaches a browser. A name that was accepted is echoed
//// back to the page as the catalogue stored it, trimmed, and is drawn as a text
//// node wherever it appears.

/// What the daemon answers to a request to rename the page's principal.
pub type Answer {
  /// The daemon stored the name. The name is the one the catalogue now holds,
  /// which the page draws in the bar and in the control's lead.
  Renamed(name: String)

  /// The daemon stored nothing.
  Declined(reason: Reason)
}

/// Why the daemon renamed nothing. Every page shows the fixed words for the
/// reason (`reason_words`).
pub type Reason {
  /// The page has ended, its ceiling is read-only, or its credential no longer
  /// authenticates as the principal it was admitted for. One answer for each, so
  /// a page learns nothing else about its standing.
  NotAllowed

  /// The name breaks the rule for a display name: it is blank, longer than 256
  /// bytes, or holds a control, zero-width or direction-changing character. It
  /// is the rule a claim's chosen name is held to.
  InvalidName

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// catalogue refused the write.
  Unavailable
}

/// Where the "Your name" control stands. It is the page's own state and nothing
/// the daemon records.
pub type Control {
  /// The form is drawn and waits for a name.
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
/// assert names.reason_words(names.NotAllowed)
///   == "This page can no longer change your name."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotAllowed -> "This page can no longer change your name."
    InvalidName ->
      "A name needs 1 to 256 bytes, with no control or invisible characters."
    Unavailable -> "The daemon could not change your name. Try again."
  }
}
