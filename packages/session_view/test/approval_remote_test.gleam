//// A child's request on another orchestrator, as the cells of a metadata cut
//// carry it (protocol-change/089).
////
//// The parent session files the box's record under `remote-escalation/` in the
//// protocol's own vocabulary. These cases pin what the terminal and the page read
//// from it: the identity and `seq` an answer must name are the box's, an approval
//// carries only the grants the spawner's ceiling admits, the rest are listed with
//// their reason, and the session choice follows from what is admitted.

import core/json
import core/register
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/approval
import session_view/snapshot_view

const child = "sub:^main/build-0123456789abcdef"

fn writable(path: String) -> json.JsonValue {
  json.Object([
    #("type", json.String("writable_root")),
    #("path", json.String(path)),
  ])
}

fn wall(seconds: Int) -> json.JsonValue {
  json.Object([
    #("type", json.String("limit")),
    #("field", json.String("wall_seconds")),
    #("value", json.Int(seconds)),
  ])
}

// The protocol's own record, as `protocol.encode_escalation` writes it for a
// placed request.
fn cell(
  wanted wanted: List(json.JsonValue),
  admitted admitted: List(json.JsonValue),
  action action: String,
) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    "remote-escalation/box/policy-ab",
    41,
    json.Object([
      #("seq", json.Int(9)),
      #("escalation_id", json.String("box/policy-ab")),
      #("op", json.String("op-1")),
      #("strand", json.String(child)),
      #("status", json.String("pending")),
      #("tool", json.String("bash")),
      #("action", json.String(action)),
      #("preview", json.String("{\"command\":\"make test\"}")),
      #(
        "denial",
        json.Object([
          #(
            "reason",
            json.String("tool requirements exceed the session policy"),
          ),
          #("source", json.String("policy")),
          #("wanted", json.Array(wanted)),
        ]),
      ),
      #("placement", json.String("box")),
      #("admitted", json.Array(admitted)),
    ]),
  )
}

fn review(cell: snapshot_view.Cell) -> approval.Review {
  let assert Ok([found]) = approval.records([cell])
    as "the remote cell decodes to one review"
  found
}

pub fn a_remote_cell_reads_with_the_other_orchestrators_identity_and_seq_test() {
  let found =
    review(cell(
      wanted: [writable("/srv/w")],
      admitted: [writable("/srv/w")],
      action: "d1",
    ))
  assert found.id == "box/policy-ab"

  // The cell's own sequence is this session's. The answer names the box's.
  assert found.seq == 9
  assert found.status == approval.Pending
  assert found.strand == None
  assert approval.asker(found) == Some("build @ box")
  assert approval.outside_lines(found) == []
}

pub fn an_approval_carries_only_what_the_ceiling_admits_test() {
  let found =
    review(cell(
      wanted: [writable("/srv/w"), wall(600)],
      admitted: [writable("/srv/w")],
      action: "d1",
    ))
  let assert Ok(command) = approval.approve(4, found)
  assert string.contains(command, "\"escalation_id\":\"box/policy-ab\"")
  assert string.contains(command, "\"expected_seq\":9")
  assert string.contains(command, "/srv/w")
  assert !string.contains(command, "wall_seconds")

  // What the ceiling does not admit is listed, with the reason.
  assert approval.outside_lines(found)
    == [
      "- Resource limit: {\"type\":\"limit\",\"field\":\"wall_seconds\",\"value\":600} (outside the spawner's approval ceiling)",
    ]
}

pub fn the_session_choice_follows_what_is_admitted_test() {
  let rememberable =
    review(cell(
      wanted: [writable("/srv/w")],
      admitted: [writable("/srv/w")],
      action: "d1",
    ))
  assert list.all([approval.rememberable(rememberable)], fn(found) {
    found == Ok(Nil)
  })
  let assert Ok(command) = approval.approve_for_session(4, rememberable)
  assert string.contains(command, "\"scope\":\"session\"")

  // A limit cannot be remembered however it is admitted.
  let limit =
    review(cell(wanted: [wall(60)], admitted: [wall(60)], action: "d1"))
  let assert Error(_) = approval.rememberable(limit)
}

pub fn a_ceiling_that_admits_nothing_offers_denial_only_test() {
  let found =
    review(cell(wanted: [writable("/etc")], admitted: [], action: "d1"))
  let assert Error(reason) = approval.approve(4, found)
  assert string.contains(reason, "ceiling admits none")
  let assert Ok(denial) = approval.deny(4, found)
  assert string.contains(denial, "\"expected_seq\":9")
  assert string.contains(denial, "\"escalation_id\":\"box/policy-ab\"")
}

pub fn a_remote_record_without_an_action_cannot_be_approved_test() {
  let found =
    review(cell(
      wanted: [writable("/srv/w")],
      admitted: [writable("/srv/w")],
      action: "",
    ))
  let assert Error(_) = approval.approve(4, found)
}

pub fn a_cell_under_the_wrong_key_is_refused_test() {
  let wrong =
    snapshot_view.Cell(
      ..cell(wanted: [], admitted: [], action: "d1"),
      key: "remote-escalation/box/other",
    )
  let assert Error(_) = approval.records([wrong])
}
