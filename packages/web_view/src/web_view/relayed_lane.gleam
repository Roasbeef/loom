//// The transcript of a relayed session as the pieces the page's own lane draws
//// (protocol-change/094, and the first fix of issue #1135).
////
//// A session that runs on another orchestrator gives the page its transcript a
//// bounded page at a time (`remote_transcript.Page`, the `ChildHistory` shape of
//// protocol-change/090). The page used to draw each entry as one line of words,
//// so an answer's Markdown, a table and a tool call showed as the characters
//// they were written with. This module turns the same page into the pieces a
//// local session's page projects from its capture (`session_view/turns`), so
//// `view/lane.reading` draws it with the same rendered Markdown and the same
//// folded tool steps, and nothing about how a record reads is decided twice.
////
//// ## What stays out
////
//// The page is model text recorded on another machine, and it is data. Nothing
//// here parses it as anything but a record: the projection is `session_view`'s,
//// and `view/lane` puts every string in a text node or in the closed tree of
//// `session_view/markdown`, where a tag a model wrote is the characters it is,
//// a link is checked by the browser before it can be followed, and an image is
//// text. The provider's reasoning blocks are taken out again here
//// (`remote_transcript.without_reasoning`), since the box takes them out before
//// it sends a page and a page that still carries one was not made by it.
////
//// ## What the page can and cannot open
////
//// A tool step is a line with its detail behind a chevron, which the browser
//// opens (`<loom-expand>`), so it needs no message and no handler. A settled
//// turn's work is drawn open under its divider instead of behind a button,
//// because this page holds at most one bounded page of entries and has no
//// message with which to ask for a fold's steps. The fold is the only difference
//// from the local lane.
////
//// ## Flow
////
//// `pieces` → `records` → `opened`
////
//// 1. `pieces` projects the page's entries into the lane's pieces.
//// 2. `records` attributes the entries to the strand the page shows, newest
////    first, as a capture's branch holds them.
//// 3. `opened` draws a folded turn's work open.

import gleam/dict
import gleam/list
import gleam/option.{None}
import session_view/advisor_history
import session_view/block_summary
import session_view/notes_view
import session_view/protocol
import session_view/remote_transcript
import session_view/transcript_lines
import session_view/turns
import session_view/worktree_view
import web_view/view/expansion

/// The strand every relayed page shows. A page of the session's own transcript
/// is its primary strand's, and the name of a child on the box is not needed to
/// draw its words.
const strand = "main"

/// The lane's pieces for one page of a relayed transcript, oldest first.
///
/// `latest` says whether the session is running an operation or waits on an
/// approval, in which case the last turn is drawn without a divider, as a local
/// lane draws the turn that is running.
///
/// ## Examples
///
/// ```gleam
/// let page = remote_transcript.Page(child: "main", entries: [], omitted: 0, next: option.None)
/// assert relayed_lane.pieces(page, turns.Settled) == []
/// ```
pub fn pieces(
  page: remote_transcript.Page,
  latest: turns.Latest,
) -> List(turns.Piece) {
  let held = records(page)
  let presentation = presentation(held)
  let board = advisor_history.Board(items: [], unloaded: None)

  transcript_lines.keyed_record_blocks(held, presentation, [], board)
  |> turns.pieces([], latest, turns.Expand(expansion.capped))
  |> list.map(opened)
}

/// The page's entries as a capture's branch holds them: newest first, each on
/// the strand the page shows, with the provider's reasoning taken out.
fn records(page: remote_transcript.Page) -> List(protocol.EntryRecord) {
  page.entries
  |> list.reverse
  |> list.map(fn(held) {
    protocol.EntryRecord(
      strand:,
      entry: remote_transcript.without_reasoning(held),
    )
  })
}

/// What a freshly attached reader starts from: no capture, no labels, no row
/// caches and no worktree board, so the rows depend on the records alone.
fn presentation(
  held: List(protocol.EntryRecord),
) -> transcript_lines.Presentation {
  transcript_lines.Presentation(
    active_strand: strand,
    extent: notes_view.Excerpt,
    captured: None,
    records: held,
    streams: [],
    tool_tails: [],
    queued: [],
    awaiting_outcome: None,
    cache_notices: [],
    summaries: block_summary.new(),
    compact_entry_cache: dict.new(),
    compact_call_cache: dict.new(),
    worktree: worktree_view.new(),
    clock: None,
  )
}

/// A settled turn's work, drawn open. The projection leaves every item in a
/// folded piece, and the page has no press that would ask for them, so they are
/// drawn rather than withheld. The page is one bounded page of entries, so the
/// steps it opens are bounded with it.
fn opened(piece: turns.Piece) -> turns.Piece {
  case piece {
    turns.Work(folding: turns.Folded, ..) ->
      turns.Work(..piece, folding: turns.Unfolded(hidden: 0))
    turns.Work(..)
    | turns.Plain(..)
    | turns.Prompt(..)
    | turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Peer(..)
    | turns.Sibling(..)
    | turns.Trigger(..)
    | turns.Missed(..)
    | turns.Decided(..) -> piece
  }
}
