//// Stopping, archiving and deleting a session from the owner's home: what the
//// page asks, what the daemon answers, and the fixed words for each refusal
//// (protocol-change/065, the round-4 addendum on session actions).
////
//// The daemon already has all three operations as control commands
//// (`sessions.stop`, `sessions.archive`, `sessions.delete`), and the terminal
//// runs them as one: stop the session, wait for it to leave, then archive or
//// delete it. The page offers them where they are valid for the row. A running
//// session can be stopped; a saved one can be archived, which hides it and
//// keeps its history, or deleted, which removes the registration and the
//// database and cannot be undone. The registry refuses to archive or delete a
//// session a process still holds (`AdminBusy`), so the page never offers
//// either on a running row.
////
//// The page sends the action and the session the server drew into the row, and
//// nothing else. Who is asking, whether they may, and whether the session is in
//// a state the action fits are the daemon's: it reads them from the attachment
//// the router authenticated, again at the moment of the click
//// (`ui_socket.manage_for`). Delete is the one action with no way back, so the
//// page takes a second press in the row before it asks (`Stage`). Stop takes
//// the same step on a row that is working or waiting for the person, since it
//// cancels a turn in flight or drops an approval nobody has seen; on an idle
//// row it acts at once. The daemon takes no such step: the confirmation is
//// the page's, and the daemon's checks are the same whether the press was
//// confirmed or forged.
////
//// The sidebar offers two of them, Archive on a saved or blocked row and
//// `StopArchive` on a running one (`view/archiving`), each after one
//// confirmation that names what it will do. Both are the home's own Archive
//// and Stop, asked of the same daemon function under the same checks.
////
//// The words a page shows for a refusal are fixed here, so no text the daemon
//// or the catalogue produced reaches a browser.

/// What the owner can ask of a session's row.
pub type Action {
  /// End the process that runs the session. The session stays on disk and
  /// shows as saved.
  Stop

  /// Hide a saved session from the lists and keep everything it holds. The
  /// terminal's `sessions.restore` brings it back.
  Archive

  /// Remove a saved session's registration and its database. It cannot be
  /// undone.
  Delete

  /// The sidebar's one action on a running row: stop the session, wait for the
  /// registry to report it saved, then archive it, as one request. It is the
  /// terminal's sequence made a single task, so the page never holds a stop's
  /// answer to chain a second request from, and the daemon makes the same
  /// checks at the start that it makes for each of the two alone.
  StopArchive
}

/// What the daemon answers to a request to act on a session.
pub type Answer {
  /// The daemon did it.
  Done(action: Action)

  /// The daemon did nothing, and the reason says why in fixed words.
  Declined(reason: Reason)
}

/// Why the daemon did nothing. Every page shows the fixed words for the reason
/// (`reason_words`).
pub type Reason {
  /// The page's principal is not the daemon's owner on a page minted to
  /// operate, the page has ended, or the session is not one the catalogue
  /// holds. One answer for each, so a page learns nothing else about its
  /// standing.
  NotOwner

  /// A process still holds the session, so its files are in use. It is stopped
  /// first.
  Running

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// registry refused the change.
  Unavailable
}

/// Where the page is in acting on a row. It is the page's own state and
/// nothing the session records.
pub type Stage {
  /// No row is waiting on the owner or on the daemon.
  Calm

  /// The owner pressed Delete on this row, or Stop on a row that is working or
  /// waiting for them, and the row asks once more. `action` is the one the
  /// confirmation is for, so a press that confirms a Stop can never act as a
  /// Delete.
  Confirming(session: String, action: Action)

  /// A request for this row is with the daemon. A press meanwhile asks
  /// nothing, so one press acts at most once.
  Working(session: String, action: Action)
}

/// The words a page shows for a refusal. They are fixed here, one for each
/// reason, so nothing the daemon wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert actions.reason_words(actions.Running)
///   == "That session is still running. Stop it first."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can do that from a page."
    Running -> "That session is still running. Stop it first."
    Unavailable -> "The daemon could not do that. Try again."
  }
}

/// The words a page shows once the daemon did what was asked.
///
/// ## Examples
///
/// ```gleam
/// assert actions.done_words(actions.Archive) == "Archived."
/// ```
pub fn done_words(action: Action) -> String {
  case action {
    Stop -> "Stopped."
    Archive -> "Archived."
    Delete -> "Deleted."
    StopArchive -> "Stopped and archived."
  }
}
