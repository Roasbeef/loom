//// The session summary's rows that come from a read or from the presence
//// roster: the live jobs and who is attached.
////
//// A host draws these as a short key and value list. This module decides
//// what each row says and how much of it a host is given, so the terminal
//// and the web page can draw the same words. It decides nothing about
//// whether a host shows a row: the web page draws viewers for an operator
//// and not for an observer, and that is the page's choice
//// (protocol-change/051), made by handing in the roster or not.
////
//// Jobs are an explicit current read (`live_jobs`), not something inferred
//// from history. A board read for another strand than the one asked about is
//// not an answer about it, and a strand nobody has read yet has no board, so
//// both are `Unread` and never a count of zero. What a board says was true
//// when the daemon observed it, and the rows carry that ("at last refresh").
////
//// Viewers come from the presence rows of the coherent cut the host holds.
//// Each presence row is one attachment, and the terminal's participant count
//// counts attachments. A person is not an attachment: the same principal
//// attached from three pages is one viewer with three pages, so the list
//// names who is watching and the count says how many attachments there are.
////
//// Both lists are bounded, because a host draws them into every viewer's
//// document: `max_job_rows` job lines and `max_viewer_rows` viewers, each with
//// a count of what was left out. Job and viewer names are session and
//// principal text and are meant to be drawn as text nodes. The module is
//// portable: it holds no `@external` and performs no I/O.

import core/origin
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/live_jobs
import session_view/snapshot
import session_view/snapshot_view
import session_view/text_hygiene

/// The most job lines a summary carries.
pub const max_job_rows = 8

/// The most viewers a summary carries.
pub const max_viewer_rows = 16

/// What is known of the strand's live jobs.
pub type Jobs {
  /// No board for this strand has been read, or the read was refused.
  Unread

  /// The daemon's board for this strand at its last refresh.
  Live(
    /// Every live job the daemon counted, whether or not it sent the row.
    total: Int,
    /// At most `max_job_rows` lines, in the order the daemon sent them.
    rows: List(String),
    /// How many jobs are counted in `total` and have no row here.
    omitted: Int,
  )
}

/// Whose attachment a row is.
pub type Whose {
  /// The attachment this host holds.
  You

  /// Another attachment of the session.
  Another
}

/// One principal's attachments to the session.
pub type Viewer {
  Viewer(
    /// The principal's display name, or `peer session/strand` for a peer.
    /// Principal text.
    name: String,
    /// The roles the principal's attachments hold, as words, each once, in
    /// the order the cut listed them.
    roles: List(String),
    /// How many attachments the principal has.
    pages: Int,
    /// Whether one of them is this host's own attachment.
    whose: Whose,
  )
}

/// The attached viewers, as many as a summary carries.
pub type Viewers {
  Viewers(
    /// At most `max_viewer_rows` principals, in the order the cut first
    /// listed them.
    rows: List(Viewer),
    /// How many attachments the cut listed in all, whether or not their
    /// principal has a row.
    total: Int,
  )
}

/// The jobs row for `strand`, from the board the host holds.
///
/// A board that names another strand is an old answer to a different
/// question, so it reads as `Unread`.
///
/// ## Examples
///
/// ```gleam
/// assert session_summary.jobs(option.None, "main") == session_summary.Unread
/// ```
pub fn jobs(board: Option(live_jobs.Board), strand: String) -> Jobs {
  case board {
    Some(board) if board.strand == strand -> {
      let lines = list.drop(live_jobs.lines(board), 1)
      let shown = list.take(lines, max_job_rows)

      Live(
        total: board.total,
        rows: shown,
        omitted: board.total - list.length(shown),
      )
    }
    Some(_) | None -> Unread
  }
}

/// The viewers of the coherent cut the host holds, one per principal, or
/// none before one.
///
/// ## Examples
///
/// ```gleam
/// assert session_summary.viewers(option.None).total == 0
/// ```
pub fn viewers(
  captured: Option(#(snapshot.Captured, snapshot_view.View)),
) -> Viewers {
  case captured {
    None -> Viewers([], 0)
    Some(#(cut, view)) -> {
      let #(order, grouped) =
        list.fold(view.peers, #([], dict.new()), fn(seen, peer) {
          let #(order, grouped) = seen
          let mine = case peer.connection_id == cut.attachment.connection_id {
            True -> You
            False -> Another
          }
          case dict.get(grouped, peer.origin) {
            Ok(viewer) -> #(
              order,
              dict.insert(grouped, peer.origin, join(viewer, peer, mine)),
            )
            Error(Nil) -> #(
              [peer.origin, ..order],
              dict.insert(grouped, peer.origin, first(peer, mine)),
            )
          }
        })

      Viewers(
        rows: list.reverse(order)
          |> list.take(max_viewer_rows)
          |> list.filter_map(dict.get(grouped, _)),
        total: list.length(view.peers),
      )
    }
  }
}

// A principal's first attachment as a viewer.
fn first(peer: snapshot_view.Peer, mine: Whose) -> Viewer {
  Viewer(
    name: text_hygiene.single_line(origin.display_label(peer.origin)),
    roles: [role_word(peer.role)],
    pages: 1,
    whose: mine,
  )
}

// A further attachment of a principal already listed.
fn join(viewer: Viewer, peer: snapshot_view.Peer, mine: Whose) -> Viewer {
  Viewer(
    ..viewer,
    roles: case list.contains(viewer.roles, role_word(peer.role)) {
      True -> viewer.roles
      False -> list.append(viewer.roles, [role_word(peer.role)])
    },
    pages: viewer.pages + 1,
    whose: case viewer.whose, mine {
      You, _ | _, You -> You
      Another, Another -> Another
    },
  )
}

fn role_word(role: snapshot.Role) -> String {
  case role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer"
  }
}
