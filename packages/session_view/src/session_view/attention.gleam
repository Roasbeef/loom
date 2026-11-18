//// What the live rail lifts out of a session's lane: the rows that need the
//// owner, and the ones worth knowing.
////
//// Live mode (`docs/design-notes/attention-inbox/README.md`, section 2.3)
//// draws a rail beside the live transcript. The transcript keeps its order
//// and its folds; the rail reads the same pieces and pulls out the few that
//// a reader who looked away would want first. This module is that reading,
//// as a pure function from the lane's `turns.Piece` values and the register's
//// `approval.Review` values to a list of `Lifted` rows. It draws nothing and
//// holds no state, so the same pieces always lift the same rows, and a host
//// that is not the web view could draw them.
////
//// Two holds divide the rows. An approval that is still pending is
//// `PinnedUntilAnswered`: it stays on the rail until a decision commits,
//// because the strand cannot proceed without it. Everything else is
//// `FoldsOnceOpened`: it is shown until the reader opens it, then folded
//// away. Phase 1 adds stuck strands and open asks to the pinned group; they
//// are not variants here because nothing in the lane can say them yet.
////
//// ## Keys and heads
////
//// A row's `key` is the identity the page jumps to in the transcript. It is
//// always a daemon identity: a piece's own key, or an approval's id with the
//// `approval:` prefix (approvals are register rows, not lane rows). A turn
//// whose work had failed steps lifts once, under the turn's own key, from the
//// failed count its divider carries, so the row exists while the fold is
//// closed and its steps are not loaded, and it does not change identity as
//// steps arrive. A row's `head` is one line of at most `head_limit`
//// graphemes. Heads quote session text (a child's outcome, a refusal), so a
//// view must draw them as text nodes and never as markup. A head carries no
//// identity: a child's result says only its outcome, and the head for a peer
//// message says only that a message arrived. The daemon knows it stored the
//// message, not that it is relevant or that anyone has answered it, and the
//// rail must not claim either. The view names the source from the row's
//// `kind`.
////
//// ## Order
////
//// `lift` returns the pinned rows first, in the order the approvals were
//// raised, and then the insights newest first. The lane is oldest first, so
//// the insights are the lane's rows reversed. Each piece lifts at most once,
//// and a turn's work lifts once for its failed steps.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/approval
import session_view/transcript_line
import session_view/turns

/// The longest head, in graphemes. A longer one is cut and ends in `…`.
pub const head_limit = 120

/// How long a row stays on the rail.
pub type Hold {
  /// The row waits on the owner and stays until the decision commits.
  PinnedUntilAnswered

  /// The row is worth knowing and folds away once the reader opens it.
  FoldsOnceOpened
}

/// Why a row was lifted: a closed set, each from one kind of lane piece or
/// register row.
pub type Kind {
  /// A request that has no decision yet, with the tool that asked.
  ApprovalPending(tool: String)

  /// A tool call that returned an error, or a code-mode program that failed.
  FailedStep

  /// A response that failed, or a sub-agent spawn that was refused.
  FailedTurn

  /// A child's result, as an `agent_wait` returned it.
  SubagentResult(child: String)

  /// A message another session's strand stored for this session.
  PeerMessage(session: String, strand: String)
}

/// One row of the rail.
pub type Lifted {
  Lifted(
    /// The transcript identity the page jumps to. A daemon identity, never
    /// model text.
    key: String,
    /// Why the row was lifted.
    kind: Kind,
    /// Whether the row stays until answered.
    hold: Hold,
    /// One line of at most `head_limit` graphemes. Untrusted text.
    head: String,
  )
}

/// The rows the rail shows: pending approvals first, in the order they were
/// raised, then the lane's notable pieces newest first.
///
/// ## Examples
///
/// ```gleam
/// assert attention.lift([], []) == []
/// ```
pub fn lift(
  pieces: List(turns.Piece),
  approvals: List(approval.Review),
) -> List(Lifted) {
  let pending = list.filter_map(approvals, approval_row)

  let insights =
    pieces
    |> list.flat_map(piece_rows)
    |> list.reverse

  list.append(pending, insights)
}

/// The rows that wait on the owner.
///
/// ## Examples
///
/// ```gleam
/// assert attention.pinned([]) == []
/// ```
pub fn pinned(lifted: List(Lifted)) -> List(Lifted) {
  list.filter(lifted, fn(row) { row.hold == PinnedUntilAnswered })
}

/// The rows worth knowing, in the order `lift` gave them.
///
/// ## Examples
///
/// ```gleam
/// assert attention.insights([]) == []
/// ```
pub fn insights(lifted: List(Lifted)) -> List(Lifted) {
  list.filter(lifted, fn(row) { row.hold == FoldsOnceOpened })
}

/// A pending review as a pinned row. A review with any other status was
/// decided, and is not the rail's to show.
fn approval_row(review: approval.Review) -> Result(Lifted, Nil) {
  // Only an undecided request waits on the owner.
  case review.status {
    approval.Pending -> {
      // The presentation refuses a record whose authority cannot be encoded.
      // The row still stands, since the owner can deny it, and it falls back
      // to the captured preview.
      let action = case approval.presentation(review) {
        Ok(shown) -> shown.action
        Error(_) -> review.preview
      }

      // A request with no preview is still named by what it asks to do.
      let head = case action {
        "" -> approval.wants(review.tool)
        action -> approval.wants(review.tool) <> " · " <> action
      }

      Ok(Lifted(
        key: "approval:" <> review.id,
        kind: ApprovalPending(review.tool),
        hold: PinnedUntilAnswered,
        head: one_line(head),
      ))
    }

    approval.Approved | approval.Rejected | approval.Consumed -> Error(Nil)
  }
}

/// The insight rows of one lane piece, oldest first within it.
fn piece_rows(piece: turns.Piece) -> List(Lifted) {
  // Each kind of piece lifts as its own kind of row, or not at all.
  case piece {
    turns.Plain(block:, ..) -> failed_response(block.key, block.rows)

    turns.Work(key:, worked:, items:, ..) ->
      list.append(
        failed_steps(key, worked.failed),
        list.flat_map(items, narrated_failure),
      )

    turns.Spawned(key:, child:, purpose:, standing: turns.Failed, refusal:, ..) -> {
      let named = option.unwrap(child, "a child")

      // The harness's refusal sentence says more than the purpose does.
      let why = case refusal {
        Some(reason) -> reason
        None -> purpose
      }

      [
        insight(key, FailedTurn, "Spawn of " <> named <> " failed · " <> why),
      ]
    }

    turns.Returned(key:, child:, outcome:, ..) -> [
      insight(key, SubagentResult(child), outcome),
    ]

    turns.Peer(key:, session:, strand:, ..) -> [
      insight(key, PeerMessage(session, strand), "messaged this session"),
    ]

    // The remaining pieces are the owner's own words, the harness's
    // bookkeeping, or messages whose attribution the rail does not vouch for.
    turns.Spawned(standing: turns.Pending, ..)
    | turns.Spawned(standing: turns.Done, ..)
    | turns.Prompt(..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Sibling(..)
    | turns.Trigger(..)
    | turns.Missed(..)
    | turns.Decided(..) -> []
  }
}

/// One insight for a turn whose work had failed steps, or none when it had
/// none. It is read from the turn's divider (`Worked.failed`), which the
/// window keeps for a turn whose fold is closed and whose steps are not
/// loaded, and it is keyed by the turn's own piece key, so the row stays the
/// same row as steps are added and the fold is opened or closed.
fn failed_steps(work_key: String, failed: Int) -> List(Lifted) {
  // The count is the head: the steps themselves are in the turn's fold.
  case failed {
    0 -> []
    1 -> [insight(work_key, FailedStep, "1 step failed")]
    n -> [insight(work_key, FailedStep, int.to_string(n) <> " steps failed")]
  }
}

/// The failed response, if any, of one item folded under a turn's divider.
fn narrated_failure(item: turns.Item) -> List(Lifted) {
  // Only a narrated block can hold a failed response; steps are counted by
  // the divider and memory rows are not failures.
  case item {
    turns.Narrated(block:, ..) -> failed_response(block.key, block.rows)
    turns.Step(..) | turns.Memory(..) -> []
  }
}

/// A failed response, once, from the first `Failure` row of its block.
fn failed_response(
  key: String,
  rows: List(#(String, transcript_line.Line)),
) -> List(Lifted) {
  let failures =
    list.filter(rows, fn(row) { { row.1 }.speaker == transcript_line.Failure })

  // A block with several failure rows is still one failed response.
  case failures {
    [#(_, line), ..] -> [insight(key, FailedTurn, line.text)]
    [] -> []
  }
}

/// An insight row, with its head put on one line and cut.
fn insight(key: String, kind: Kind, head: String) -> Lifted {
  Lifted(key:, kind:, hold: FoldsOnceOpened, head: one_line(head))
}

/// Text as one line of at most `head_limit` graphemes: line breaks and tabs
/// become spaces, runs of spaces collapse, and a longer text is cut on a
/// grapheme boundary and ends in `…`, so the whole stays within the limit.
fn one_line(text: String) -> String {
  let flat =
    text
    |> string.replace("\r", " ")
    |> string.replace("\n", " ")
    |> string.replace("\t", " ")
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
    |> string.join(" ")

  let graphemes = string.to_graphemes(flat)

  // Cut only when the text is over the limit; the drop stops at the bound.
  case list.drop(graphemes, head_limit) {
    [_, ..] -> string.concat(list.take(graphemes, head_limit - 1)) <> "…"
    [] -> flat
  }
}
