//// What the daemon tells the owner's home about its projects
//// (protocol-change/106, the addendum on the web view).
////
//// The home page's Projects section and its ticket page are fed by three reads
//// the daemon runs for the owner: the boards of every project, one ticket, and
//// the answer to a ticket's question. This module is the vocabulary of those
//// reads and nothing else. It holds the daemon's JSON as the daemon sent it,
//// because decoding it, ordering it and wording it belong to
//// `session_view/project_board`, which the terminal uses too, so the two
//// surfaces cannot disagree about what a ticket says or which comes first.
////
//// Every string inside the JSON is external text. It is decoded once, through
//// `session_view/project_board`, which makes it safe to draw, and a view draws
//// it as a text node only.
////
//// ## Examples
////
//// ```gleam
//// let none = projects.Heard([])
//// ```

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import session_view/project_board
import web_view/creations

/// The result of reading every project's board.
pub type Read {
  /// The daemon answered, with one entry for each project it holds. A daemon
  /// with no project answers an empty list, which is not the same as a daemon
  /// that did not answer.
  Heard(
    /// The projects, in the daemon's order.
    projects: List(Listed),
  )

  /// The daemon did not answer in time, or the page may not ask. The page keeps
  /// what it last drew.
  Unread
}

/// One project and its first board page, as the daemon sent them.
pub type Listed {
  Listed(
    /// The project's id, which a command names.
    id: String,
    /// The workspace the project is bound to, which the section words as the
    /// project's name.
    workspace: String,
    /// The router's session, which the project page opens.
    router_session: String,
    /// The `projects.board` reply, to be decoded by
    /// `session_view/project_board.decode_board`.
    board: JsonValue,
  )
}

/// The result of reading one ticket.
pub type TicketRead {
  /// The daemon sent the ticket, to be decoded by
  /// `session_view/project_board.decode_detail`.
  TicketHeard(
    /// The `projects.ticket` reply.
    detail: JsonValue,
  )

  /// The project holds no such ticket.
  TicketGone

  /// The daemon did not answer in time.
  TicketUnread
}

/// What the daemon said to an answer.
pub type Answer {
  /// The answer was recorded.
  Recorded

  /// The daemon refused it. The code is the daemon's, such as `conflict` for an
  /// answer to a question that has since changed; the page words it with
  /// `session_view/project_board.answer_refusal_words`.
  Refused(
    /// The daemon's error code.
    code: String,
  )
}

/// What the daemon said to a close.
pub type Closing {
  /// The ticket was closed, and its mandate stands.
  Closed

  /// The daemon refused it. The code is the daemon's, such as `bad_request` for
  /// a ticket that already ended or that a person stopped.
  NotClosed(
    /// The daemon's error code.
    code: String,
  )
}

/// What the daemon said to a stop or a retry of a ticket, the two acts a ticket
/// thread offers that have no other outcome than done or refused.
pub type Acted {
  /// The daemon recorded the act.
  Acted

  /// The daemon refused it. The code is the daemon's, such as `bad_request` for
  /// a ticket that has already ended; the page words it with
  /// `web_view/ticket_rule.refusal_words`.
  Declined(
    /// The daemon's error code.
    code: String,
  )
}

/// What the daemon said to a request to propose settings for a folder. The
/// proposal reads at most a dozen named files in the folder and runs nothing.
pub type Proposal {
  /// The daemon read the folder. The body is the `projects.propose` reply, to be
  /// decoded by `session_view/project_settings_view.decode_proposed`.
  Proposed(
    /// The reply, as the daemon sent it.
    body: JsonValue,
  )

  /// The daemon would not read the folder. The reason is the one a new session's
  /// folder gets, so the page words it the same way.
  ProposalRefused(
    /// Why, in the fixed vocabulary of `creations`.
    reason: creations.Reason,
  )
}

/// What the daemon said to a request to create a project.
pub type Creation {
  /// The project exists. A workspace that already had one keeps it, so this is
  /// also the answer for a repeat.
  Made(
    /// The project's id.
    project: String,
    /// What became of the settings the owner confirmed.
    settled: Settled,
  )

  /// The folder already has a project. Nothing was made and nothing was
  /// written to it, so the settings the owner confirmed were not stored.
  Existing(
    /// The project's id.
    project: String,
  )

  /// The folder was refused before anything was made.
  NotMade(
    /// Why, in the fixed vocabulary of `creations`.
    reason: creations.Reason,
  )

  /// The daemon refused to make the project and said why in its own words.
  MakeFailed(
    /// The daemon's sentence. It is drawn as a text node.
    words: String,
  )
}

/// What became of the check and setup the owner confirmed when a project was
/// made. They are two writes, so the second can fail after the first succeeded.
pub type Settled {
  /// The settings were stored, or the owner confirmed none.
  SettingsHeld

  /// The project exists and its settings were not stored. Nothing is rolled
  /// back, because a project with no check is a valid project.
  SettingsRefused(
    /// The daemon's sentence about the refusal.
    words: String,
  )
}

/// What the daemon said to a read of a project's settings.
pub type SettingsRead {
  /// The `projects.settings` reply, to be decoded by
  /// `session_view/project_settings_view.decode_settings`.
  SettingsHeard(
    /// The reply, as the daemon sent it.
    body: JsonValue,
  )

  /// The daemon did not answer, or the page may not ask. The page keeps what it
  /// drew.
  SettingsUnread
}

/// What the daemon said to a write of a project's settings.
pub type SettingsWrite {
  /// The settings were stored. The body is the reply, the settings now in
  /// force, as `SettingsHeard` carries them.
  SettingsStored(
    /// The reply, as the daemon sent it.
    body: JsonValue,
  )

  /// The daemon refused the write, in its own sentence. A stale revision is the
  /// code `conflict`, and the page reads the settings again.
  SettingsDeclined(
    /// The daemon's error code.
    code: String,
    /// The daemon's sentence, drawn as a text node.
    words: String,
  )
}

/// What the daemon said to a request posted from the composer.
pub type Posted {
  /// The request was recorded as an explicit trigger.
  Posted(
    /// The trigger's id.
    trigger: String,
  )

  /// This request id was posted before, so nothing changed.
  Reposted(
    /// The trigger's id.
    trigger: String,
  )

  /// The daemon refused the post. The code is the daemon's, such as
  /// `not_found` for a project that is gone.
  NotPosted(
    /// The daemon's error code.
    code: String,
  )
}

/// A project as the page holds it: its id, its workspace, and its board once
/// the reply decoded.
pub type Loaded {
  Loaded(
    /// The project's id.
    id: String,
    /// The workspace, which names the project on the page.
    workspace: String,
    /// The router's session id, which the project page opens.
    router_session: String,
    /// The decoded board, or none when the reply could not be decoded. A project
    /// with no board is drawn as one line that says so, and not as a healthy one.
    board: Option(project_board.Board),
  )
}

/// Decodes the daemon's answer for the page. A board that does not decode is
/// kept as a project with no board, so it is shown as unreadable and not left
/// out as though it were healthy.
///
/// ## Examples
///
/// ```gleam
/// assert projects.decode([]) == []
/// ```
pub fn decode(listed: List(Listed)) -> List(Loaded) {
  list.map(listed, fn(each) {
    Loaded(
      id: each.id,
      workspace: each.workspace,
      router_session: each.router_session,
      board: project_board.decode_board(each.board) |> option.from_result,
    )
  })
}

/// The ticket of a loaded project, when the page holds one by that id.
///
/// ## Examples
///
/// ```gleam
/// assert projects.find([], "p1", "t-a") == Error(Nil)
/// ```
pub fn find(
  held: List(Loaded),
  project: String,
  ticket: String,
) -> Result(project_board.Ticket, Nil) {
  use loaded <- result.try(list.find(held, fn(each) { each.id == project }))

  // A project whose board did not decode holds no ticket the page could name.
  case loaded.board {
    Some(board) -> list.find(board.tickets, fn(each) { each.id == ticket })
    None -> Error(Nil)
  }
}
