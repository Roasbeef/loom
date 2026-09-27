//// One strand's transcript lines from one completed capture, for a host
//// that keeps no presentation state of its own.
////
//// The terminal builds its transcript incrementally. It keeps a paged
//// history window across cuts, caches the rows of every record and call,
//// and adds the live streams, tool tails and its own queued submissions
//// beside the durable records. A read-only host has none of that to keep:
//// it holds the last capture and redraws from it. `project` is that host's
//// whole projection. It runs the same steps the terminal runs when a cut
//// arrives (the strand's ancestry through `history_view`, the advisor's
//// traffic through `advisor_history`, the rows through
//// `transcript_lines.record_lines`), starting each time from an empty
//// history and empty caches, so its lines are what a terminal that had just
//// attached would draw for the same records.

import core/ids
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/advisor_history
import session_view/block_summary
import session_view/history_view
import session_view/notes_view
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript_line.{type CacheNotice, type Line}
import session_view/transcript_lines
import session_view/worktree_view

/// One transcript line and the key that names it across captures.
pub type Row {
  Row(
    /// The durable sequence the line was drawn from, which of the blocks at
    /// that sequence it belongs to, and its index within the block
    /// (`transcript_lines.keyed_record_lines`). It holds digits, `.`, `:`
    /// and `~` only, so it is safe as a view's list key.
    key: String,
    /// The line itself.
    line: Line,
  )
}

/// The transcript lines of `strand` in a completed capture, oldest first,
/// with details collapsed.
///
/// The lines cover the durable records the capture's window holds on the
/// strand's ancestry. Nothing live is included: no stream fragments, tool
/// tails or queued submissions, since a capture carries none of them.
///
/// ## Examples
///
/// ```gleam
/// // transcript.project(cut, view, "main")
/// //   is main's rows, oldest first, e.g. [Line(User, "hello"), ..]
/// ```
pub fn project(
  cut: snapshot.Captured,
  view: snapshot_view.View,
  strand: String,
) -> List(Line) {
  let #(records, presentation, advisor) = projected(cut, view, strand)
  let #(lines, _, _) =
    transcript_lines.record_lines(records, presentation, [], advisor)
  lines
}

/// The same lines as `project`, in the same order, each with a key that
/// names it across captures.
///
/// A host that draws the transcript as a keyed list uses these, so that a
/// history window which drops lines at its head removes them rather than
/// rewriting every line after them.
///
/// ## Examples
///
/// ```gleam
/// // transcript.project_rows(cut, view, "main")
/// //   is [Row("7.0:0", Line(User, "hello")), ..]
/// ```
pub fn project_rows(
  cut: snapshot.Captured,
  view: snapshot_view.View,
  strand: String,
) -> List(Row) {
  let #(records, presentation, advisor) = projected(cut, view, strand)
  transcript_lines.keyed_record_lines(records, presentation, [], advisor)
  |> list.map(fn(row) { Row(key: row.0, line: row.1) })
}

/// The same rows as `project_rows`, grouped by the block that drew them and
/// tagged with what drew it (`transcript_lines.keyed_record_blocks`), with
/// `notices` spliced after the entries they were anchored to, as the
/// terminal splices its own.
///
/// A host that draws some blocks as something other than rows (a folded
/// turn, a card for another session's message) reads these; `turns` is
/// the rule for which.
///
/// ## Examples
///
/// ```gleam
/// // transcript.blocks(cut, view, "main", [])
/// ```
pub fn blocks(
  cut: snapshot.Captured,
  view: snapshot_view.View,
  strand: String,
  notices: List(CacheNotice),
) -> List(transcript_lines.Block) {
  let #(records, presentation, advisor) = projected(cut, view, strand)
  let notices = list.filter(notices, fn(notice) { notice.strand == strand })
  transcript_lines.keyed_record_blocks(records, presentation, notices, advisor)
}

/// The newest entry `strand` holds on its own ancestry in a capture: where a
/// transient notice raised for it now is anchored, as the terminal anchors
/// one (`transcript_lines.newest_entry`).
///
/// ## Examples
///
/// ```gleam
/// // transcript.newest_entry(cut, view, "main")
/// ```
pub fn newest_entry(
  cut: snapshot.Captured,
  view: snapshot_view.View,
  strand: String,
) -> Option(ids.EntryId) {
  let #(records, _, _) = projected(cut, view, strand)
  transcript_lines.newest_entry(records, strand)
}

// What both projections read of one capture: the strand's records, the
// presentation a freshly attached terminal starts from, and the advisor's
// board for that strand.
fn projected(
  cut: snapshot.Captured,
  view: snapshot_view.View,
  strand: String,
) -> #(
  List(protocol.EntryRecord),
  transcript_lines.Presentation,
  advisor_history.Board,
) {
  let branch =
    history_view.empty()
    |> history_view.capture(cut.window, view, strand)
    |> history_view.branch(view)

  // An attached terminal starts from these same defaults: no labels, empty
  // row caches and no worktree board, so the rows depend on the records
  // alone.
  let presentation =
    transcript_lines.Presentation(
      active_strand: strand,
      extent: notes_view.Excerpt,
      captured: Some(#(cut, view)),
      records: branch.records,
      streams: [],
      tool_tails: [],
      queued: [],
      awaiting_outcome: None,
      cache_notices: [],
      summaries: block_summary.new(),
      compact_entry_cache: dict.new(),
      compact_call_cache: dict.new(),
      worktree: worktree_view.new(),
    )
  #(
    branch.records,
    presentation,
    advisor_history.project(view, cut.window)
      |> advisor_history.visible(strand),
  )
}
