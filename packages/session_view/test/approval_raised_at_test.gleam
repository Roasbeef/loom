//// The raise time of a local escalation, as the page's decoder reads it
//// (protocol-change/124).
////
//// A row written before the field existed has no `raised_at` key and must
//// decode with no time, not as corruption, because the page then draws no age
//// for it. A wrong type or a negative number is no time either, and the review
//// survives it.

import core/json
import core/register
import gleam/list
import gleam/option.{None, Some}
import session_view/approval
import session_view/snapshot_view

fn row(extra: List(#(String, json.JsonValue))) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    "escalation/esc-1",
    7,
    json.Object(list.append(
      [
        #("id", json.String("esc-1")),
        #("status", json.String("pending")),
        #("tool", json.String("bash")),
        #("preview", json.String("{\"command\":\"make\"}")),
        #("action", json.String("digest")),
        #("denial", json.Object([#("wanted", json.Array([]))])),
      ],
      extra,
    )),
  )
}

pub fn a_present_raise_time_is_read_test() {
  let assert Ok(review) =
    approval.decode(row([#("raised_at", json.Int(1_763_400_000_000))]))
  assert review.raised_at == Some(1_763_400_000_000)
}

pub fn a_record_before_the_field_has_no_time_test() {
  let assert Ok(review) = approval.decode(row([]))
  assert review.raised_at == None

  let assert Ok(review) = approval.decode(row([#("raised_at", json.Null)]))
  assert review.raised_at == None
}

// A time that cannot be read is no time. It must not cost the whole review,
// because a pending approval whose card cannot be drawn cannot be decided.
pub fn a_malformed_raise_time_is_no_time_and_keeps_the_review_test() {
  let assert Ok(review) =
    approval.decode(row([#("raised_at", json.String("noon"))]))
  assert review.raised_at == None
  assert review.id == "esc-1"

  let assert Ok(review) = approval.decode(row([#("raised_at", json.Int(-1))]))
  assert review.raised_at == None
  assert review.tool == "bash"
}
