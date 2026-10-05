//// The approval decisions a session has recorded, as lines a timeline can
//// draw: `Owner denied bash`, `Owner allowed bash`.
////
//// An approval that was answered leaves nothing in the transcript. The tool
//// call fails or runs, and a reader cannot tell an operator's denial from a
//// jail's refusal. The record that can say so is the escalation the harness
//// keeps in its register: its status, the author who decided
//// (`approval.Review.origin`), the tool, and the strand it was raised on.
//// A metadata cut carries only the escalations still pending. Once one is
//// decided, the host looks it up and keeps the answer in the approval ledger
//// (`approval.decisions`), sixteen at most, and this module reads that
//// ledger, which is data the page already receives: no wire field is added.
//// The strand comes from the pending cell, which the capture held while the
//// request waited (`strands`); the host remembers it until the decision.
////
//// A page that opens after a request was decided never saw it pending, so
//// it has no identity to look up. It reads the daemon's decided approvals
//// instead (`escalations_decided`, protocol-change/015 addendum), which
//// arrive as the same records a lookup returns and join the same ledger.
//// Those records carry their strand in the escalation's own scope
//// (`approval.Review.strand`), which is what the line falls back to when no
//// capture saw the request pending. A decision the page watched and then
//// read again is one ledger entry, because the ledger is keyed by the
//// escalation's identity.
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

/// The decisions the approval ledger holds for `strand`, oldest first.
///
/// `raised` says which strand each request was raised on, by the request's
/// identity (`strands`), and the record's own scope answers for a request
/// no capture saw pending. A request that is still pending is no decision,
/// and one whose strand is not known either way is left out rather than
/// guessed at.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.from_ledger([], [], "main") == []
/// ```
pub fn from_ledger(
  ledger: List(approval.Review),
  raised: List(#(String, String)),
  strand: String,
) -> List(Decision) {
  ledger
  |> list.filter_map(fn(review) { decision(review, raised, strand) })
  |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
}

// One ledger entry as a decision for `strand`, or nothing.
fn decision(
  review: approval.Review,
  raised: List(#(String, String)),
  strand: String,
) -> Result(Decision, Nil) {
  use verdict <- result.try(case review.status {
    approval.Pending -> Error(Nil)
    approval.Approved | approval.Consumed -> Ok(Allowed)
    approval.Rejected -> Ok(Denied)
  })
  use owner <- result.try(
    list.key_find(raised, review.id)
    |> result.lazy_or(fn() { option.to_result(review.strand, Nil) }),
  )
  use <- bool.guard(owner != strand, Error(Nil))
  let who = case review.origin {
    Some(author) -> origin.display_label(author)
    None -> "Someone"
  }
  Ok(Decision(
    seq: review.seq,
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
/// for every record the cells hold. A card for a request that waits names the
/// strand that is waiting, and the host keeps the pair for the decision's
/// line, since the ledger's summary of a decided request keeps no scope.
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
  decision.who <> verb(decision.verdict) <> tool_words(decision.tool)
}

/// The verb of a decision's line, with its spaces: ` allowed `, ` denied `.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.verb(decisions.Denied) == " denied "
/// ```
pub fn verb(verdict: Verdict) -> String {
  case verdict {
    Allowed -> " allowed "
    Denied -> " denied "
  }
}

/// The tool a decision's line names, or `a request` when the record names
/// none.
///
/// ## Examples
///
/// ```gleam
/// assert decisions.tool_words("") == "a request"
/// ```
pub fn tool_words(tool: String) -> String {
  case tool {
    "" -> "a request"
    tool -> tool
  }
}
