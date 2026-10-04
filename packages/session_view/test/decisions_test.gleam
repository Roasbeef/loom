//// The decisions a session recorded are read from the escalation cells the
//// capture already carries: who answered, what they decided, and on which
//// strand the request was raised. A request still waiting is no decision.

import core/json
import core/message
import core/origin
import core/register
import gleam/option.{Some}
import session_view/decisions
import session_view/snapshot_view

// One escalation cell, as the harness stores it, with the fields the
// decision reads: its status, its tool, its author and the strand its scope
// names.
fn escalation(
  id: String,
  seq: Int,
  status: String,
  author: json.JsonValue,
  strand: String,
) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    "escalation/" <> id,
    seq,
    json.Object([
      #("id", json.String(id)),
      #("status", json.String(status)),
      #("tool", json.String("bash")),
      #("preview", json.String("printf hi")),
      #("origin", author),
      #("scope", json.Object([#("strand", json.String(strand))])),
    ]),
  )
}

fn owner() -> json.JsonValue {
  origin.encode(Some(message.Origin("principal-owner", "Owner")))
}

pub fn a_rejected_request_is_a_denial_by_its_author_test() {
  let cells = [escalation("e1", 12, "rejected", owner(), "main")]
  let assert [decision] = decisions.from_cells(cells, "main")
  assert decision.seq == 12
  assert decision.verdict == decisions.Denied
  assert decisions.words(decision) == "Owner denied bash"
}

pub fn an_approved_request_and_a_consumed_one_are_both_allowed_test() {
  let cells = [
    escalation("e1", 12, "approved", owner(), "main"),
    escalation("e2", 20, "consumed", owner(), "main"),
  ]
  let assert [first, second] = decisions.from_cells(cells, "main")
  assert decisions.words(first) == "Owner allowed bash"
  assert second.verdict == decisions.Allowed
}

pub fn a_request_still_waiting_is_no_decision_test() {
  let cells = [escalation("e1", 12, "pending", json.Null, "main")]
  assert decisions.from_cells(cells, "main") == []
}

pub fn a_decision_belongs_to_the_strand_that_raised_it_test() {
  let cells = [escalation("e1", 12, "rejected", owner(), "sub:main/review")]
  assert decisions.from_cells(cells, "main") == []
  assert decisions.from_cells(cells, "sub:main/review") != []
}

pub fn a_record_with_no_stored_author_names_no_one_test() {
  let cells = [escalation("e1", 12, "rejected", json.Null, "main")]
  let assert [decision] = decisions.from_cells(cells, "main")
  assert decisions.words(decision) == "Someone denied bash"
}

pub fn decisions_come_oldest_first_test() {
  let cells = [
    escalation("e2", 30, "rejected", owner(), "main"),
    escalation("e1", 12, "approved", owner(), "main"),
  ]
  let assert [first, second] = decisions.from_cells(cells, "main")
  assert first.seq == 12
  assert second.seq == 30
}
