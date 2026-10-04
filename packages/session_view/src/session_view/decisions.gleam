//// The approval decisions a session has recorded, as lines a timeline can
//// draw: `Owner denied bash`, `Owner allowed bash`.
////
//// An approval that was answered leaves nothing in the transcript. The tool
//// call fails or runs, and a reader who opens the session later cannot tell
//// an operator's denial from a jail's refusal. The record that can say so is
//// the escalation the harness kept in its register: it holds the decision's
//// status and the author who made it (`approval.Review.origin`), the tool,
//// and the strand and call it was raised for. It is in every metadata cut,
//// so reading it adds no wire data and no second channel; this module only
//// reads what the capture already carries.
////
//// A decision's sequence is the register write that committed it. Storage
//// numbers register writes and transcript entries from one counter within a
//// session (`docs/architecture/durability.md`), so the sequence orders the
//// decision among the transcript's own records, and a host can place the
//// line after the step it decided (`turns.with_decisions`).
////
//// Nothing here decides anything. A request still waiting has no decision
//// and is skipped. A record whose author was not stored is attributed to
//// `Someone`, because disappearance alone never identifies the person who
//// resolved a request (`approval`).

import core/json
import core/origin
import core/register
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/approval
import session_view/snapshot_view

/// What the decision was.
pub type Verdict {
  /// The authority was granted. A grant that the operation has already
  /// consumed was granted first, so it counts here.
  Allowed

  /// The request was refused.
  Denied
}

/// One recorded decision, as the timeline draws it.
pub type Decision {
  Decision(
    /// The register sequence that committed the decision, which places it
    /// among the transcript's records.
    seq: Int,
    /// The strand whose tool call raised the request.
    strand: String,
    /// Who decided, as `origin.display_label` words it, or `Someone`.
    who: String,
    /// What they decided.
    verdict: Verdict,
    /// The tool the request was for, bounded by the ledger's own summary.
    tool: String,
  )
}

/// The decisions the cells record for `strand`, oldest first.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.from_cells([], "main") == []
/// ```
pub fn from_cells(
  cells: List(snapshot_view.Cell),
  strand: String,
) -> List(Decision) {
  cells
  |> list.filter(fn(cell) {
    cell.namespace == register.FactCustom
    && string.starts_with(cell.key, "escalation/")
  })
  |> list.filter_map(fn(cell) { decision(cell, strand) })
  |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
}

// One cell as a decision for `strand`, or nothing: a record that does not
// decode, one still pending, and one raised on another strand are skipped.
fn decision(cell: snapshot_view.Cell, strand: String) -> Result(Decision, Nil) {
  use review <- result.try(approval.decode(cell) |> result.replace_error(Nil))
  use verdict <- result.try(case review.status {
    approval.Pending -> Error(Nil)
    approval.Approved | approval.Consumed -> Ok(Allowed)
    approval.Rejected -> Ok(Denied)
  })
  use owner <- result.try(raised_on(cell.value))
  use <- bool.guard(owner != strand, Error(Nil))
  let who = case review.origin {
    Some(author) -> origin.display_label(author)
    None -> "Someone"
  }
  Ok(Decision(
    seq: cell.seq,
    strand: owner,
    who:,
    verdict:,
    tool: string.slice(review.tool, 0, 128),
  ))
}

// The strand a stored escalation was raised on: the record's scope names it.
fn raised_on(value: json.JsonValue) -> Result(String, Nil) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(Nil)
  })
  use scope <- result.try(list.key_find(fields, "scope"))
  use scope <- result.try(case scope {
    json.Object(scope) -> Ok(scope)
    _ -> Error(Nil)
  })
  case list.key_find(scope, "strand") {
    Ok(json.String(strand)) -> Ok(strand)
    _ -> Error(Nil)
  }
}

/// The strand each escalation was raised on, by the escalation's identity,
/// for every record the cells hold, pending or decided. A card for a request
/// that waits names the strand that is waiting, which the ledger's own
/// summary does not keep.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.strands([]) == []
/// ```
pub fn strands(cells: List(snapshot_view.Cell)) -> List(#(String, String)) {
  list.filter_map(cells, fn(cell) {
    use <- bool.guard(
      cell.namespace != register.FactCustom
        || !string.starts_with(cell.key, "escalation/"),
      Error(Nil),
    )
    use strand <- result.try(raised_on(cell.value))
    Ok(#(string.drop_start(cell.key, 11), strand))
  })
}

/// The words of a decision's line, as the terminal and the page both say
/// them: `Owner denied bash`.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.words(decisions.Decision(7, "main", "Owner", decisions.Denied, "bash"))
///   == "Owner denied bash"
/// ```
pub fn words(decision: Decision) -> String {
  let verb = case decision.verdict {
    Allowed -> " allowed "
    Denied -> " denied "
  }
  let tool = case decision.tool {
    "" -> "a request"
    tool -> tool
  }
  decision.who <> verb <> tool
}
