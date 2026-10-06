//// The decisions a session recorded are read from the approval ledger the
//// host keeps once a request is decided: who answered, what they decided,
//// and, from what the captures saw while the request waited, the strand it
//// was raised on. A request still waiting is no decision.

import core/json
import core/message
import core/register
import gleam/option.{type Option, None, Some}
import session_view/approval
import session_view/decisions
import session_view/snapshot_view

fn review(
  id: String,
  seq: Int,
  status: approval.Status,
  who: Option(message.Origin),
) -> approval.Review {
  approval.Review(
    id,
    seq,
    status,
    "bash",
    "printf hi",
    who,
    approval.Unavailable("this decision is already resolved"),
    strand: None,
  )
}

fn owner() -> Option(message.Origin) {
  Some(message.Origin("principal-owner", "Owner"))
}

fn raised() -> List(#(String, String)) {
  [#("e1", "main"), #("e2", "main"), #("e3", "sub:main/review")]
}

pub fn a_rejected_request_is_a_denial_by_its_author_test() {
  let ledger = [review("e1", 12, approval.Rejected, owner())]
  let assert [decision] = decisions.from_ledger(ledger, raised(), "main")
  assert decision.seq == 12
  assert decision.verdict == decisions.Denied
  assert decisions.words(decision) == "Owner denied bash"
}

pub fn an_approved_request_and_a_consumed_one_are_both_allowed_test() {
  let ledger = [
    review("e1", 12, approval.Approved, owner()),
    review("e2", 20, approval.Consumed, owner()),
  ]
  let assert [first, second] = decisions.from_ledger(ledger, raised(), "main")
  assert decisions.words(first) == "Owner allowed bash"
  assert second.verdict == decisions.Allowed
}

pub fn a_request_still_waiting_is_no_decision_test() {
  let ledger = [review("e1", 12, approval.Pending, None)]
  assert decisions.from_ledger(ledger, raised(), "main") == []
}

pub fn a_decision_belongs_to_the_strand_that_raised_it_test() {
  let ledger = [review("e3", 12, approval.Rejected, owner())]
  assert decisions.from_ledger(ledger, raised(), "main") == []
  assert decisions.from_ledger(ledger, raised(), "sub:main/review") != []
}

pub fn a_request_whose_strand_was_never_seen_is_left_out_test() {
  let ledger = [review("e9", 12, approval.Rejected, owner())]
  assert decisions.from_ledger(ledger, raised(), "main") == []
}

pub fn a_record_with_no_stored_author_names_no_one_test() {
  let ledger = [review("e1", 12, approval.Rejected, None)]
  let assert [decision] = decisions.from_ledger(ledger, raised(), "main")
  assert decisions.words(decision) == "Someone denied bash"
}

pub fn decisions_come_oldest_first_test() {
  let ledger = [
    review("e2", 30, approval.Rejected, owner()),
    review("e1", 12, approval.Approved, owner()),
  ]
  let assert [first, second] = decisions.from_ledger(ledger, raised(), "main")
  assert first.seq == 12
  assert second.seq == 30
}

// The strand a request was raised on is the scope the stored record names,
// found for pending and decided cells alike.
pub fn the_strand_comes_from_the_records_scope_test() {
  let cell = fn(id, strand) {
    snapshot_view.Cell(
      register.FactCustom,
      "escalation/" <> id,
      7,
      json.Object([
        #("id", json.String(id)),
        #("scope", json.Object([#("strand", json.String(strand))])),
      ]),
    )
  }
  let other =
    snapshot_view.Cell(register.FactCustom, "note/x", 8, json.Object([]))
  assert decisions.strands([cell("e1", "main"), other, cell("e2", "sub:x")])
    == [#("e1", "main"), #("e2", "sub:x")]
}

// A page that opened after the decision has no capture that saw the request
// pending, so the record's own scope names the strand, and it agrees with
// what a capture would have said.
pub fn a_records_own_scope_names_the_strand_when_no_capture_saw_it_test() {
  let record =
    approval.Review(
      ..review("e7", 12, approval.Rejected, owner()),
      strand: Some("sub:main/review"),
    )
  assert decisions.from_ledger([record], [], "main") == []
  let assert [decision] = decisions.from_ledger([record], [], "sub:main/review")
  assert decisions.words(decision) == "Owner denied bash"
  assert decisions.from_ledger([record], [#("e7", "main")], "main") != []
    as "a capture's account of the request wins over the record's"
}
