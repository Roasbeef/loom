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

/// A project as the page holds it: its id, its workspace, and its board once
/// the reply decoded.
pub type Loaded {
  Loaded(
    /// The project's id.
    id: String,
    /// The workspace, which names the project on the page.
    workspace: String,
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
