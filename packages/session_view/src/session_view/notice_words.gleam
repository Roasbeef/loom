//// The words of a command's outcome: what the footer says after a command is
//// written to the wire and after the daemon answers it.
////
//// The shared step used to word both from the wire itself, the command's
//// name and a verb (`goal_set sent`, `deny committed`), which is the event's
//// name and not a sentence a reader would write. A footer is a state the
//// reader glances at, so it says `Goal pinned`. The table is here, in the
//// portable subset, so the terminal's status line and the web page say the
//// same thing about the same command.
////
//// The table is closed and fixed. A command it does not list is worded
//// `Sent` when it was written and `Done` when it was answered, so no wire
//// name ever reaches a reader, and no word comes from the session: the
//// name of a fork, for one, is session text and is not here.
////
//// ## Flow
////
//// `sent` words a command the moment it is written to the wire, and
//// `outcome` words the daemon's answer to it, one status at a time. Both
//// fall back on `done`, which is the one place the command table lives.

import gleam/list

/// The words for a command that has just been written to the wire and has
/// not been answered. Most say only that the command went; a goal
/// command, which the server answers within a round trip, says what is being
/// done.
///
/// ## Examples
///
/// ```gleam
/// assert notice_words.sent("goal_set") == "Pinning the goal"
/// assert notice_words.sent("notes") == "Sent"
/// ```
pub fn sent(command: String) -> String {
  case command {
    "prompt" | "prompt_content" | "steer" | "follow_up" -> "Sending"
    "goal_get" -> "Reading the goal"
    "goal_set" -> "Pinning the goal"
    "goal_clear" -> "Clearing the goal"
    "goal_pause" -> "Pausing the goal"
    "goal_resume" -> "Resuming the goal"
    "goal_check" -> "Checking the goal"
    "fork" -> "Forking"
    "deny" -> "Denying"
    "approve" -> "Allowing"
    "abort" -> "Stopping"
    _ -> "Sent"
  }
}

/// The words for the daemon's answer to a command: its name and the status
/// the answer carried (`admitted`, `committed` or `queued`).
///
/// A command the daemon only booked for later says so, whatever the command
/// was; every other status is the command done.
///
/// ## Examples
///
/// ```gleam
/// assert notice_words.outcome("prompt", "queued") == "Queued for the next turn"
/// assert notice_words.outcome("deny", "committed") == "Denied"
/// assert notice_words.outcome("something_new", "admitted") == "Done"
/// ```
pub fn outcome(command: String, status: String) -> String {
  case status, command {
    "queued", "prompt" | "queued", "prompt_content" ->
      "Queued for the next turn"
    "queued", "edit_queued_input" -> "Queued input updated"
    "queued", "steer" -> "Steering · runs next"
    "queued", _ -> "Queued"
    _, _ -> done(command)
  }
}

/// Whether a footer outcome only says the daemon is holding the operator's
/// input, which a host that draws the held input itself need not repeat.
///
/// The web page draws a held prompt or steer in the lane, with how it will
/// run, and settles it into the transcript when it runs. The footer's
/// "Queued" beside it said the same thing a second time and, once the row had
/// settled, outlived it, so the page leaves these words out.
///
/// ## Examples
///
/// ```gleam
/// assert notice_words.holds(notice_words.outcome("steer", "queued"))
/// assert !notice_words.holds(notice_words.outcome("deny", "committed"))
/// ```
pub fn holds(text: String) -> Bool {
  list.contains(
    [
      outcome("prompt", "queued"),
      outcome("steer", "queued"),
      outcome("follow_up", "queued"),
    ],
    text,
  )
}

/// The words for a command that has been carried out.
///
/// ## Examples
///
/// ```gleam
/// assert notice_words.done("goal_clear") == "Goal cleared"
/// assert notice_words.done("fork") == "Forked"
/// ```
pub fn done(command: String) -> String {
  case command {
    "prompt" | "prompt_content" -> "Sent"
    "steer" -> "Steer sent"
    "follow_up" -> "Queued as a follow-up"
    "goal_set" -> "Goal pinned"
    "goal_clear" -> "Goal cleared"
    "goal_pause" -> "Goal paused"
    "goal_resume" -> "Goal resumed"
    "goal_check" -> "Goal check started"
    "fork" -> "Forked"
    "deny" -> "Denied"
    "approve" -> "Allowed once"
    "abort" -> "Stopped"
    "compact" -> "Compaction started"
    "create_strand" -> "Strand created"
    "set_config" -> "Setting saved"
    "schedule_cancel" -> "Schedule cancelled"
    "edit_queued_input" -> "Queued input updated"
    _ -> "Done"
  }
}
