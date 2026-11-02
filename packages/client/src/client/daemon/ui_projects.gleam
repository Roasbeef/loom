//// The project reads and the answer behind the owner's home page
//// (protocol-change/106, the addendum on the web view).
////
//// The home page draws a Projects section and a ticket page. Their facts are
//// the ones the `projects.*` control commands serve, from the same actors, so a
//// ticket reads the same on the web page and in the terminal. This module is
//// the daemon's side of three page reads: every project's first board page, one
//// ticket, and an answer to a ticket's question. It returns the daemon's JSON
//// untouched, because decoding, ordering and wording belong to
//// `session_view/project_board`, which both surfaces share.
////
//// Nothing here decides who may ask. The socket hands a page this feed only when
//// the page is the owner's and was minted to operate
//// (`ui_socket.home_projects_capability`), and each read repeats the owner check
//// before it asks an actor (`ui_socket.projects_for`). A daemon that started no
//// project table has no feed at all, and its pages draw no section.
////
//// The board body is built here once, and the `projects.board` control command
//// uses the same function, so the two cannot drift apart.
////
//// ## Flow
////
//// `feed` → `boards` → `ticket_of` → `answered`
////
//// 1. `feed` is the daemon's offer to a page, or nothing when there is no
////    project table.
//// 2. `boards` reads each running project's first page, building each body
////    with `board_body`.
//// 3. `ticket_of` reads one ticket and `answered` records an answer, both named
////    by ids the page took from a board it holds.

import client/daemon/project_book
import client/daemon/project_host
import client/daemon/project_start
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import web_view/projects

/// What the daemon reads and does for a page's projects.
pub type Feed {
  Feed(
    /// Every running project's first board page.
    boards: fn() -> projects.Read,
    /// One ticket of a project.
    ticket: fn(String, String) -> projects.TicketRead,
    /// An answer to a ticket's question, echoing the question's sequence number.
    answer: fn(String, String, Int, String) -> projects.Answer,
  )
}

/// The feed over a daemon's project table, or nothing when the daemon started
/// none.
///
/// ## Examples
///
/// ```gleam
/// assert ui_projects.feed(None) == None
/// ```
pub fn feed(control: Option(project_start.Control)) -> Option(Feed) {
  option.map(control, fn(held) {
    Feed(
      boards: fn() { boards(held) },
      ticket: fn(project, ticket) { ticket_of(held, project, ticket) },
      answer: fn(project, ticket, seq, text) {
        answered(held, project, ticket, seq, text)
      },
    )
  })
}

/// The `projects.board` reply body: the project, the ledger's newest sequence
/// number as `revision`, the page, the total, the tickets and the router's
/// queued replies. The control command and the page read the same body.
///
/// ## Examples
///
/// ```gleam
/// // ui_projects.board_body("p1", shown)
/// ```
pub fn board_body(project: String, shown: project_host.Board) -> JsonValue {
  json.Object([
    #("project", json.String(project)),
    #("revision", json.Int(shown.revision)),
    #("page", json.Int(shown.page)),
    #("total", json.Int(shown.total)),
    #("tickets", json.Array(shown.tickets)),
    #("replies", json.Array(shown.replies)),
    #("unrouted", json.Array(shown.unrouted)),
    #("would_have_done", json.Array(shown.would_have_done)),
    #("sources", json.Array(shown.sources)),
  ])
}

/// Every running project and its first page. A project whose actor does not
/// answer is left out of this read, and the page keeps what it last drew for it.
fn boards(control: project_start.Control) -> projects.Read {
  project_book.all(control.book)
  |> list.filter_map(fn(handle) {
    project_host.board(handle, 0)
    |> result.map(fn(shown) {
      projects.Listed(
        id: handle.project,
        workspace: handle.workspace,
        board: board_body(handle.project, shown),
      )
    })
  })
  |> projects.Heard
}

/// One ticket, or why there is none.
fn ticket_of(
  control: project_start.Control,
  project: String,
  ticket: String,
) -> projects.TicketRead {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.TicketGone
    Ok(handle) ->
      case project_host.ticket(handle, ticket) {
        Ok(detail) -> projects.TicketHeard(detail)
        Error(Nil) -> projects.TicketGone
      }
  }
}

/// The actor's word on an answer, as the page needs it: recorded, or refused
/// with the code the control command would answer, so a stale answer is
/// `conflict` on both surfaces.
fn answered(
  control: project_start.Control,
  project: String,
  ticket: String,
  seq: Int,
  text: String,
) -> projects.Answer {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.Refused("not_found")
    Ok(handle) ->
      case project_host.answer(handle, ticket, seq, text, "owner") {
        Ok(Nil) -> projects.Recorded
        Error(project_host.NoSuchTicket) -> projects.Refused("not_found")
        Error(project_host.StaleQuestion) -> projects.Refused("conflict")
        Error(project_host.NotAccepted(..)) -> projects.Refused("bad_request")
      }
  }
}
