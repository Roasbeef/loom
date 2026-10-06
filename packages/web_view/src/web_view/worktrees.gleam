//// The Changes tab's read of the session's Git working tree: what the page
//// asks, what the daemon answers, and when the page asks again
//// (protocol-change/051, the addendum on the worktree read).
////
//// The tab used to list only what the agent's edit and write tools reported,
//// because a page was never shown worktree bytes. A change made by a shell
//// command or an editor was therefore invisible. The owner reversed that for
//// two kinds of page: the owner's own and an operator's the owner invited.
//// An observer's page is never shown them. The page makes the read through
//// the daemon's own bounded observation of the session's workspace
//// (`client/worktree_diff`, the one the terminal's worktree view reads), but
//// not through the session gateway: the gateway admits that read to an
//// `Owner` binding and no page carries `Owner` (`ui_relay.capped`). The
//// daemon runs the read in a task of its own and the page's runtime never
//// waits for it.
////
//// The page sends nothing but the request. Which session, which workspace,
//// the base commit and every bound on the answer are the daemon's, and the
//// daemon checks the page's standing again each time it is asked, so a page
//// whose grant was revoked after it opened is refused at its next read.
////
//// ## When the page asks
////
//// Once when it opens, and again after the transcript shows a tool call
//// finished that it has not read since, at most once in `refresh_ms`. A tool
//// call is the only moment the agent changes the tree, and a shell command is
//// one of them, so waiting for a result is the cheapest signal the page has.
//// Nothing is read while nothing happens, so a hidden tab costs nothing; the
//// server component cannot tell which tab is showing without a new event, and
//// 051 admits none.
////
//// ## What the page holds
////
//// A `Read`. The last board stays on screen while the next read is out, and a
//// read that fails or is refused replaces it, so the tab never shows a
//// board the daemon has stopped vouching for. Every string in a board is the
//// repository's own text, drawn only as a text node.

import session_view/protocol
import session_view/turn_ledger
import session_view/worktree_view

/// The shortest time between two reads, in milliseconds. A burst of tool calls
/// asks once.
pub const refresh_ms = 4000

/// How long a read may be out before the page treats it as lost and asks
/// again, in milliseconds. The daemon's run has a deadline of its own and
/// answers within it; a run that was cancelled or crashed answers nothing, and
/// without this the page would wait for it for ever.
pub const lost_ms = 30_000

/// What the page knows of the workspace.
pub type Read {
  /// The page may not read the workspace: an observer's page, or one the
  /// daemon gave no capability. The tab lists the tool edits alone.
  Withheld

  /// The page may read, and no answer has come yet.
  Unread

  /// The daemon's last observation: uncommitted files against HEAD and the
  /// commits since the session started, within the daemon's bounds. It may be
  /// a workspace that is not a checkout (`Board.repository`).
  Seen(board: worktree_view.Board)

  /// The daemon refused: the page's standing no longer allows the read.
  Declined

  /// The daemon could not make the observation, or its answer was not one the
  /// page accepts.
  Unreadable

  /// The daemon's allowance for this credential's reads was spent, which is no
  /// statement about the workspace or the page's standing. The page keeps what
  /// it last drew and asks again after the usual interval, so a credential
  /// with several tabs open does not see a tab flip between the diff and a
  /// fallback.
  Throttled
}

/// Whether a read is with the daemon. At most one is, so a slow observation
/// is never doubled.
pub type Asking {
  /// No read is out.
  Idle

  /// A read is out, and its answer arrives as a message.
  Out
}

/// The sequence number of the newest tool result in `records`, newest first as
/// a branch holds them, or 0 when there is none. It changes exactly when a tool
/// call finishes, which is the moment the tree may have changed.
///
/// ## Examples
///
/// ```gleam
/// assert worktrees.latest_result([]) == 0
/// ```
pub fn latest_result(records: List(protocol.EntryRecord)) -> Int {
  turn_ledger.latest_result(records)
}
