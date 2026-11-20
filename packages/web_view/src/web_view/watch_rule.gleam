//// The second line of a row under "Watch live" in the rail: what the session is
//// doing and how much of it the live rail has lifted out, in the words the final
//// design draws (`docs/design-notes/attention-inbox/final/mockup.html`):
//// `running · 2 lifted`, `approval · 1 lifted`, `aegis · asked`,
//// `finished · to review`.
////
//// The line is composed from three things the page already holds for a running
//// session: the activity word the daemon's activity read gave, the number of
//// records pinned in the live rail (open asks, stuck strands and a pending
//// approval, which the rail keeps until they are answered), and the project the
//// catalogue found for the workspace. A page that reads no attention feed passes
//// no pinned count, and the line then says the state and nothing about the rail.
////
//// The module is pure. It draws nothing and holds no Lustre, so the rules for
//// which word a state gets are stated by tests without drawing a page. The words
//// are fixed by this module and the project is the host's own text; nothing a
//// session wrote reaches the line. A session is never said to have "ended": a
//// session that is idle after finishing is `finished`, and one with nothing to
//// say is `quiet`.

import gleam/int
import gleam/option.{type Option, None, Some}
import web_view/sessions.{type Activity, Failed, Idle, NeedsYou, Working}

/// Whether a finished session's worktree holds changes the owner has not read,
/// which the inbox lists under "To review".
pub type Review {
  /// The session's tree holds changes to read.
  ToRead

  /// The session has nothing to read, or the page cannot tell.
  NothingToRead
}

/// What the page knows of one running session.
pub type Facts {
  Facts(
    /// What the activity read last said the session is doing, or nothing before
    /// the first answer.
    activity: Option(Activity),
    /// How many records the live rail pins for the session: its open asks, its
    /// stuck strands and a pending approval.
    pinned: Int,
    /// How many open asks the session has routed to the owner.
    asks: Int,
    /// Whether a finished session's tree is waiting to be read.
    review: Review,
    /// The name of the session's project, or nothing when the catalogue found
    /// none. It is the host's text and is drawn as a text node.
    project: Option(String),
  )
}

/// The second line for a session.
///
/// A pending approval is `approval` and a session with open asks says `asked`,
/// with its project first when it has one. A working session is `running`. A
/// failed one is `failed`. An idle one is `finished · to review` when its tree
/// holds changes, and otherwise `quiet`, with the project first. The rail's count
/// follows `approval` and `running` as `· N lifted` while it is above none.
///
/// ## Examples
///
/// ```gleam
/// assert watch_rule.words(watch_rule.Facts(Some(sessions.Working), 2, 1, watch_rule.NothingToRead, None))
///   == "running · 2 lifted"
/// ```
pub fn words(facts: Facts) -> String {
  case facts.activity, facts.asks, facts.review {
    Some(NeedsYou), _, _ -> "approval" <> lifted(facts.pinned)
    _, asks, _ if asks > 0 -> prefixed(facts.project, "asked")
    Some(Working), _, _ -> "running" <> lifted(facts.pinned)
    Some(Failed), _, _ -> "failed"
    Some(Idle), _, ToRead -> "finished · to review"
    Some(Idle), _, NothingToRead | None, _, _ ->
      prefixed(facts.project, "quiet")
  }
}

/// The rail's count as the line's tail: ` · 2 lifted`, or nothing for none.
fn lifted(pinned: Int) -> String {
  case pinned > 0 {
    True -> " · " <> int.to_string(pinned) <> " lifted"
    False -> ""
  }
}

/// A word with its project in front, `aegis · asked`, or the word alone.
fn prefixed(project: Option(String), word: String) -> String {
  case project {
    Some("") | None -> word
    Some(name) -> name <> " · " <> word
  }
}
