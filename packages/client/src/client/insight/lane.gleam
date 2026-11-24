//// A finished session's lane, and the Insights rows the classifier lifts from
//// it, rebuilt from the stored entries alone.
////
//// The offline ordering test (`docs/design-notes/insight-triage.md`, section
//// 8.3) needs the rows the attention rail would have shown for a session that
//// has already ended. The rail reads the lane through `session_view`, and the
//// lane is built from a captured cut that the daemon sends over the wire. This
//// module builds the same cut from the entries of the primary strand's branch,
//// with no wire in between, so the pieces that come out are the ones the web
//// view would have drawn for that branch.
////
//// ## Why the window is not the history window
////
//// The web view keeps at most 600 records of a strand and pages older ones in
//// on demand (`history_view`). A test that asks which rows deserved the
//// owner's attention cannot start from a window that forgot the early part of
//// a long session, so the branch is handed to `transcript.branch_blocks`
//// whole. The cut and the view that go with it carry only what the projection
//// reads, which is the strand set, the leaf and the entries.
////
//// ## Which rows
////
//// `candidates` keeps the lane's Insights rows (the ones that fold once
//// opened) and drops the peer messages, since the design keeps a peer message
//// out of every triage request. Open finds are records of the session's own
//// and are not in the lane, so a session's candidates here can be fewer than
//// the "Insights" count its page shows. Pending approvals, asks and stuck
//// strands never reach this module: no register is read, and they are pinned
//// rather than insights in any case.

import core/entry.{type Entry}
import core/json
import core/message
import core/usage_evidence
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import session_view/attention.{type Lifted}
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/turns

/// The strand whose branch is the session's transcript.
pub const primary = "main"

/// One insight row and where the lane holds it.
pub type Candidate {
  Candidate(
    /// The row as the classifier lifted it.
    row: Lifted,
    /// The index, in the lane's oldest-first order, of the piece that holds
    /// the row. A turn whose work failed lifts one row under the turn's own
    /// key, and that row's piece is the turn's work piece.
    at: Int,
  )
}

/// The lane of a finished session, oldest first.
///
/// `entries` are the primary strand's branch, newest first, as
/// `storage.scan_branch` returns them. `strands` names every strand the
/// session had, which the lane reads to tell a child's hue and result from
/// the primary's.
///
/// ## Examples
///
/// ```gleam
/// assert lane.pieces([], []) == []
/// ```
pub fn pieces(
  entries: List(Entry),
  strands strands: List(String),
) -> List(turns.Piece) {
  let view = view_of(entries, strands)
  let cut = cut_of(entries)
  let branch =
    snapshot_view.Branch(
      records: list.map(entries, fn(held) {
        protocol.EntryRecord(primary, held)
      }),
      unloaded: None,
    )

  transcript.branch_blocks(branch, cut, view, primary, [])
  |> turns.pieces(view.strands, turns.Settled, turns.Skip)
}

/// The Insights rows of a lane that a triage request may carry, newest first.
///
/// ## Examples
///
/// ```gleam
/// assert lane.candidates([]) == []
/// ```
pub fn candidates(lane: List(turns.Piece)) -> List(Candidate) {
  // The classifier's own list is the authority on which rows exist and in
  // what order, so the rows are lifted over the whole lane first.
  let held =
    attention.lift(lane, [])
    |> attention.insights
    |> list.filter(fn(row) { !is_peer(row) })

  // A row is placed by lifting each piece alone, which `lift_all` does too: a
  // piece lifts the same rows whatever surrounds it.
  let placed =
    list.index_map(lane, fn(piece, index) {
      #(index, attention.lift([piece], []))
    })

  list.filter_map(held, fn(row) {
    list.find(placed, fn(entry) {
      list.any(entry.1, fn(lifted) { lifted.key == row.key })
    })
    |> result.map(fn(found) { Candidate(row:, at: found.0) })
  })
}

/// Whether a row is another session's message, which no request carries.
fn is_peer(row: Lifted) -> Bool {
  case row.kind {
    attention.PeerMessage(..) -> True
    attention.ApprovalPending(..)
    | attention.FailedStep
    | attention.FailedTurn
    | attention.SubagentResult(..)
    | attention.AskPending
    | attention.StuckStrand(..)
    | attention.FindOpen(..) -> False
  }
}

/// The view the projection reads: the strands, and the primary's leaf.
fn view_of(entries: List(Entry), strands: List(String)) -> snapshot_view.View {
  // The newest entry is the leaf of the primary strand's branch.
  let leaf = case entries {
    [newest, ..] -> Some(newest.id)
    [] -> None
  }

  snapshot_view.View(
    strands: list.map(strands, fn(id) { protocol.Strand(id, None, None) }),
    leaves: dict.from_list([#(primary, leaf)]),
    configurations: dict.new(),
    operations: dict.new(),
    usage: no_usage(),
    settings: snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    peers: [],
    cells: [],
    preview: None,
    pending_inputs: None,
    tools: None,
  )
}

/// The cut the projection reads its records from, holding every entry.
fn cut_of(entries: List(Entry)) -> snapshot.Captured {
  let items = list.map(entries, fn(held) { snapshot.Loaded(held, 0) })

  snapshot.Captured(
    attachment: snapshot.Attachment(
      expected: snapshot.Expected("offline", "offline", "offline"),
      connection_id: "offline",
      origin: message.Origin("offline", "offline"),
      role: snapshot.Observer,
    ),
    next_seq: 0,
    // The projection never decodes the metadata; the view stands for it.
    metadata: json.Null,
    window: snapshot.Window(items:, bytes: 0, evicted_through: None),
    oldest_seq: None,
  )
}

/// A session total of nothing, for a view that does not show usage.
fn no_usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    usage_evidence.none(),
  )
}
