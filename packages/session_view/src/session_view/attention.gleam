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
//// away. Phase 1 adds the session's own open records to the same two groups:
//// an open ask and a stuck strand are pinned until answered, and an open find
//// folds once opened. The lane cannot say them, so a host that has read the
//// session's feed row hands them in as `Record`s (`lift_all`), and this module
//// words them without knowing where they were read from.
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
//// graphemes. Heads quote session text (a child's report, a refusal), so a
//// view must draw them as text nodes and never as markup. A head carries no
//// identity: a child's result says its outcome and the first line of what the
//// child reported, and the head for a peer message says only that a message
//// arrived. The daemon knows it stored the message, not that it is relevant
//// or that anyone has answered it, and the rail must not claim either. The
//// view names the source from the row's `kind`.
////
//// ## Quiet rows
////
//// A row earns its place by saying something the reader cannot get from the
//// row above it. Three rules keep the rail from repeating itself. A child's
//// result carries the first line of its report after the outcome word, since
//// the outcome alone (`completed`) is the same for every child that finished.
//// A failed call whose result said nothing on its own lines reads what its
//// program card says went wrong (`turns.Worked.last_failure`). And failed
//// responses that read the same lift as one row under the first response's
//// key, with the count in the head (`provider stream error ... · 6 times`).
//// That is what retries of one provider error look like. Sameness is the head
//// the reader sees, cut as it is cut, so a retry that differs only past the
//// cut, such as a request size, reads the same. A run ends at any row of
//// another kind, at an answer that did not fail, at a step that worked and at
//// the owner's own prompt, so a failure the owner has already moved past
//// starts a new row when it comes back. Pieces that lift no row and are not an
//// answer, such as a heartbeat and the notes injected with it, do not end a
//// run.
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
import session_view/step_words
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

  /// An ask routed to the owner that has no answer yet.
  AskPending

  /// A strand that stopped on a failed run and has not run since.
  StuckStrand(strand: String)

  /// An open find, of the kind the agent called it (`risk`, `idea`, `bug` or
  /// `question`).
  FindOpen(kind: String)
}

/// An open record of the session's own, as its feed row names it. The identity
/// is a daemon identity and the head is the model's own words, cut by the
/// daemon, so a view draws it as a text node.
pub type Record {
  /// An open ask, by its identifier.
  AskRecord(id: String, head: String)

  /// A stuck strand, by its name. A strand whose failure the owner dismissed is
  /// never handed in: the daemon's feed leaves it out until it fails again
  /// (protocol-change/131), so this classifier has no rule of its own for it.
  StuckRecord(strand: String)

  /// An open find, by its identifier, with the kind word and a head.
  FindRecord(id: String, kind: String, head: String)
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
  lift_all(pieces, approvals, [])
}

/// The rows the rail shows when the host has also read the session's own open
/// records: the pending approvals first, then the open asks and stuck strands,
/// all pinned, then the open finds and the lane's notable pieces, which fold
/// once opened. The records keep the order they were handed in, since the
/// host's feed ranks them.
///
/// ## Examples
///
/// ```gleam
/// assert attention.lift_all([], [], [attention.StuckRecord("sub:a")])
///   == [attention.Lifted("stuck:sub:a", attention.StuckStrand("sub:a"), attention.PinnedUntilAnswered, "Stopped on a failed run")]
/// ```
pub fn lift_all(
  pieces: List(turns.Piece),
  approvals: List(approval.Review),
  records: List(Record),
) -> List(Lifted) {
  let pending = list.filter_map(approvals, approval_row)
  let waiting = list.filter_map(records, waiting_row)
  let finds = list.filter_map(records, find_row)

  let insights =
    pieces
    |> list.flat_map(piece_rows)
    |> collapse_repeats
    |> list.reverse

  list.flatten([pending, waiting, finds, insights])
}

/// The key an ask is lifted under, which the host maps back to the ask.
///
/// ## Examples
///
/// ```gleam
/// assert attention.ask_key("ask-0123456789") == "ask:ask-0123456789"
/// ```
pub fn ask_key(id: String) -> String {
  "ask:" <> id
}

/// The key a find is lifted under, which the host maps back to the find.
///
/// ## Examples
///
/// ```gleam
/// assert attention.find_key("find-0123456789") == "find:find-0123456789"
/// ```
pub fn find_key(id: String) -> String {
  "find:" <> id
}

/// The key a stuck strand is lifted under, which the host maps back to the
/// strand.
///
/// ## Examples
///
/// ```gleam
/// assert attention.stuck_key("sub:a") == "stuck:sub:a"
/// ```
pub fn stuck_key(strand: String) -> String {
  "stuck:" <> strand
}

/// The pinned row of an open ask or a stuck strand, or nothing for a find.
fn waiting_row(record: Record) -> Result(Lifted, Nil) {
  // Only what waits on the owner is pinned.
  case record {
    AskRecord(id:, head:) ->
      Ok(Lifted(
        key: ask_key(id),
        kind: AskPending,
        hold: PinnedUntilAnswered,
        head: one_line(head),
      ))
    StuckRecord(strand:) ->
      Ok(Lifted(
        key: stuck_key(strand),
        kind: StuckStrand(strand),
        hold: PinnedUntilAnswered,
        head: "Stopped on a failed run",
      ))
    FindRecord(..) -> Error(Nil)
  }
}

/// The insight row of an open find, or nothing for the records that wait.
fn find_row(record: Record) -> Result(Lifted, Nil) {
  case record {
    FindRecord(id:, kind:, head:) ->
      Ok(insight(find_key(id), FindOpen(kind), head))
    AskRecord(..) | StuckRecord(..) -> Error(Nil)
  }
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

/// What one lane piece contributes to the rows, before repeats are merged.
type Candidate {
  /// A row that is never merged with another.
  Row(Lifted)

  /// A failed response, which merges with the failed responses next to it
  /// that read the same.
  Repeatable(Lifted)

  /// A piece that lifts no row but ends a run of failures: an answer that did
  /// not fail, a step that worked, or the owner's own prompt.
  Boundary
}

/// A run of rows that read the same, or a single row, as the fold builds it.
/// The row is the first of the run.
type Run {
  Run(row: Lifted, count: Int)
}

/// The runs built so far, newest first, and the head the newest run may still
/// grow under: a failed response's head, or nothing once a boundary or another
/// kind of row has ended it.
type Folded {
  Folded(runs: List(Run), open: option.Option(String))
}

/// The insight rows of one lane piece, oldest first within it.
fn piece_rows(piece: turns.Piece) -> List(Candidate) {
  // Each kind of piece lifts as its own kind of row, or not at all.
  case piece {
    turns.Plain(block:, ..) -> response_candidates(block.key, block.rows)

    turns.Work(key:, worked:, items:, ..) ->
      list.append(
        list.map(failed_steps(key, worked.failed, worked.last_failure), Row),
        list.flat_map(items, item_candidates),
      )

    turns.Spawned(key:, child:, purpose:, standing: turns.Failed, refusal:, ..) -> {
      let named = option.unwrap(child, "a child")

      // The harness's refusal sentence says more than the purpose does.
      let why = case refusal {
        Some(reason) -> reason
        None -> purpose
      }

      [
        Row(insight(
          key,
          FailedTurn,
          "Spawn of " <> named <> " failed · " <> why,
        )),
      ]
    }

    turns.Returned(key:, child:, outcome:, report:, ..) -> [
      Row(insight(key, SubagentResult(child), returned_head(outcome, report))),
    ]

    turns.Peer(key:, session:, strand:, ..) -> [
      Row(insight(key, PeerMessage(session, strand), "messaged this session")),
    ]

    // The owner speaking is the end of whatever failed before it.
    turns.Prompt(..) -> [Boundary]

    // The remaining pieces are the owner's own words, the harness's
    // bookkeeping, or messages whose attribution the rail does not vouch for.
    turns.Spawned(standing: turns.Pending, ..)
    | turns.Spawned(standing: turns.Done, ..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Sibling(..)
    | turns.Trigger(..)
    | turns.Missed(..)
    | turns.Decided(..) -> []
  }
}

/// A child's result as one line: the outcome word, then the first line of what
/// the child reported. A child whose report says nothing keeps the outcome
/// alone, because that is all it said and an `aborted` child is worth seeing.
fn returned_head(outcome: String, report: String) -> String {
  // A report whose breaks arrived as the characters `\n` is read with real
  // ones first, as the lane reads it.
  let first =
    step_words.spoken_breaks(report)
    |> string.split("\n")
    |> list.map(opening_words)
    |> list.find(fn(line) { line != "" })

  // A report with a line of text adds it; one with none leaves the word.
  case first {
    Ok(line) -> outcome <> " · " <> line
    Error(Nil) -> outcome
  }
}

/// A report line as the words it opens on: a Markdown heading loses its
/// marks, and a line of nothing but marks, such as a rule, is nothing.
fn opening_words(line: String) -> String {
  let words =
    line
    |> string.to_graphemes
    |> list.drop_while(fn(mark) { mark == "#" || mark == " " })
    |> string.concat
    |> string.trim

  let marks = ["-", "*", "_", "=", "`", ">", "|", "~", " "]

  // A line that is only marks says nothing, so the next line is tried.
  case list.all(string.to_graphemes(words), fn(g) { list.contains(marks, g) }) {
    True -> ""
    False -> words
  }
}

/// Merges failed responses that are adjacent among the rows and read the same
/// into the first of them, with the count in its head. The rows arrive oldest
/// first, so the first is the oldest in the pieces held, and the key it carries
/// does not change as retries add to the run. A window that later gains older
/// pieces may move the key of a run it had held only the end of, once.
fn collapse_repeats(candidates: List(Candidate)) -> List(Lifted) {
  let Folded(runs:, ..) =
    list.fold(candidates, Folded([], None), fn(folded, candidate) {
      case candidate, folded {
        Boundary, _ -> Folded(..folded, open: None)

        Row(row), Folded(runs:, ..) -> Folded([Run(row, 1), ..runs], None)

        Repeatable(row), Folded(runs: [run, ..earlier], open: Some(head))
          if head == row.head
        -> Folded([Run(..run, count: run.count + 1), ..earlier], Some(head))

        Repeatable(row), Folded(runs:, ..) ->
          Folded([Run(row, 1), ..runs], Some(row.head))
      }
    })

  runs
  |> list.reverse
  |> list.map(run_row)
}

/// The row of one run: the first response's row for a run of one, and that row
/// with the count after the shared head for a longer run.
fn run_row(run: Run) -> Lifted {
  // Only a run of two or more has a count to say.
  case run.count {
    1 -> run.row
    n -> {
      let count = " · " <> int.to_string(n) <> " times"

      // The head is cut to leave room for the count, as `failed_steps` does.
      Lifted(
        ..run.row,
        head: one_line_within(run.row.head, head_limit - string.length(count))
          <> count,
      )
    }
  }
}

/// One insight for a turn whose work had failed steps, or none when it had
/// none. It is read from the turn's divider (`Worked.failed` and
/// `Worked.last_failure`), which the window keeps for a turn whose fold is
/// closed and whose steps are not loaded, and it is keyed by the turn's own
/// piece key, so the row stays the same row as steps are added and the fold is
/// opened or closed.
///
/// The head names the last failed call and what its result said, as the final
/// design's insight does (`bash make check · exit 2`), and adds the count when
/// more than one call failed. A turn whose divider holds no such line, because
/// the only failure was a program's inner call, keeps the count alone.
fn failed_steps(
  work_key: String,
  failed: Int,
  last_failure: option.Option(String),
) -> List(Lifted) {
  // The count is the fallback head: the steps themselves are in the turn's fold.
  case failed, last_failure {
    0, _ -> []
    1, Some(what) -> [insight(work_key, FailedStep, what)]
    1, None -> [insight(work_key, FailedStep, "1 step failed")]
    n, Some(what) -> {
      let count = " · " <> int.to_string(n) <> " steps failed"

      // The line is cut to leave room for the count, since the head's own cut
      // would otherwise take the count, which the line cannot tell.
      [
        insight(
          work_key,
          FailedStep,
          one_line_within(what, head_limit - string.length(count)) <> count,
        ),
      ]
    }
    n, None -> [
      insight(work_key, FailedStep, int.to_string(n) <> " steps failed"),
    ]
  }
}

/// What one item folded under a turn's divider contributes.
fn item_candidates(item: turns.Item) -> List(Candidate) {
  // A narrated block is a response, failed or not; a step that worked is
  // progress; the divider counts failed steps and memory rows are not
  // failures.
  case item {
    turns.Narrated(block:, ..) -> response_candidates(block.key, block.rows)
    turns.Step(standing: turns.Done, ..) -> [Boundary]
    turns.Step(..) | turns.Memory(..) -> []
  }
}

/// A response block's contribution: a failed response from the first `Failure`
/// row of its block, an answer that did not fail as a boundary, or nothing for
/// a block that is neither. A failure with no text is a row of its own, since
/// two of them would read as nothing and a count over nothing says nothing.
fn response_candidates(
  key: String,
  rows: List(#(String, transcript_line.Line)),
) -> List(Candidate) {
  let failures =
    list.filter(rows, fn(row) { { row.1 }.speaker == transcript_line.Failure })

  let spoke =
    list.any(rows, fn(row) { { row.1 }.speaker == transcript_line.Assistant })

  // A block with several failure rows is still one failed response, and a
  // block that spoke without failing is an answer, which ends a run.
  case failures, spoke {
    [#(_, line), ..], _ -> {
      let row = insight(key, FailedTurn, line.text)

      // A failure with no text cannot be counted.
      case row.head {
        "" -> [Row(row)]
        _ -> [Repeatable(row)]
      }
    }
    [], True -> [Boundary]
    [], False -> []
  }
}

/// An insight row, with its head put on one line and cut.
fn insight(key: String, kind: Kind, head: String) -> Lifted {
  Lifted(key:, kind:, hold: FoldsOnceOpened, head: one_line(head))
}

/// Text as one line of at most `room` graphemes, cut as `one_line` cuts it.
fn one_line_within(text: String, room: Int) -> String {
  let flat = one_line(text)
  let graphemes = string.to_graphemes(flat)

  // Cut only when the line is over the room; the cut ends in `…`.
  case list.drop(graphemes, room) {
    [_, ..] -> string.concat(list.take(graphemes, room - 1)) <> "…"
    [] -> flat
  }
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
