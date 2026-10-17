//// The vocabulary of what a child on another orchestrator sends its parent
//// (protocol-change/084, phase 2), and the rows a parent keeps for a send that
//// nobody has answered.
////
//// The receipts and landings are stored on one orchestrator and read back on
//// the other, so what is written is what is read for every shape, and a value
//// that does not decode is named and never crashes the reader.

import client/remote_mail
import client/remote_send
import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{None, Some}
import tools/agent

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn an_entry() -> ids.EntryId {
  let #(entry, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 3))
  entry
}

pub fn only_a_closed_parent_session_is_worth_asking_again_test() {
  assert remote_mail.retryable(remote_mail.ParentSessionNotOpen)
  assert remote_mail.retryable(remote_mail.Busy(reason: "holder"))
  assert !remote_mail.retryable(remote_mail.UnknownChild)
  assert !remote_mail.retryable(remote_mail.OriginMismatch)
  assert !remote_mail.retryable(remote_mail.StoreFailure(reason: "busy"))
}

pub fn every_refusal_has_a_sentence_test() {
  assert remote_mail.describe_refusal(remote_mail.UnknownChild)
    == "the parent session has no record of this child"
  assert remote_mail.describe_refusal(remote_mail.ParentSessionNotOpen)
    == "the parent session is not open"
  assert remote_mail.describe_refusal(remote_mail.OriginMismatch)
    == "the message did not come from the orchestrator that runs this child"
  assert remote_mail.describe_refusal(remote_mail.StoreFailure(reason: "busy"))
    == "the parent's store failed: busy"
  assert remote_mail.describe_refusal(remote_mail.Busy(reason: "holder"))
    == "the parent's orchestrator was busy: holder"
}

pub fn a_receipt_round_trips_test() {
  list.each(
    [remote_mail.Delivered, remote_mail.Declined(reason: "no run open")],
    fn(receipt) {
      assert remote_mail.decode_receipt(remote_mail.encode_receipt(receipt))
        == Ok(receipt)
    },
  )
}

pub fn a_receipt_that_does_not_decode_is_named_test() {
  assert remote_mail.decode_receipt(json.Null)
    == Error("expected a mail receipt, got null")
  assert remote_mail.decode_receipt(json.Object([])) == Error("missing `kind`")
  assert remote_mail.decode_receipt(
      json.Object([#("kind", json.String("lost"))]),
    )
    == Error("unknown mail receipt `lost`")
  assert remote_mail.decode_receipt(
      json.Object([#("kind", json.String("declined"))]),
    )
    == Error("missing `reason`")
}

pub fn a_landing_round_trips_in_every_shape_test() {
  list.each(
    [
      remote_mail.Steered(entry: an_entry()),
      remote_mail.Started(operation: an_op(5), remaining_ms: Some(1500)),
      remote_mail.Started(operation: an_op(6), remaining_ms: None),
      remote_mail.Admitted,
    ],
    fn(landing) {
      assert remote_mail.decode_landing(remote_mail.encode_landing(landing))
        == Ok(landing)
    },
  )
}

pub fn a_landing_that_does_not_decode_is_named_test() {
  assert remote_mail.decode_landing(json.Null)
    == Error("expected a landing, got null")
  assert remote_mail.decode_landing(
      json.Object([#("delivery", json.String("teleported"))]),
    )
    == Error("unknown landing `teleported`")
  let assert Error(_) =
    remote_mail.decode_landing(
      json.Object([
        #("delivery", json.String("started")),
        #("operation", json.String("not an operation")),
      ]),
    )
  assert remote_mail.decode_landing(
      json.Object([
        #("delivery", json.String("started")),
        #("operation", json.String(ids.op_id_to_string(an_op(1)))),
        #("remainingMs", json.String("soon")),
      ]),
    )
    == Error("expected `remainingMs` to be an integer")
}

pub fn a_send_row_round_trips_and_is_keyed_by_its_message_id_test() {
  let row =
    remote_send.Row(
      id: "7b1c",
      orchestrator: "box",
      parent_strand: "main",
      child: agent.Handle(strand: "sub:^main/build-1", operation: an_op(9)),
      text: "also the tests",
    )
  assert remote_send.decode(remote_send.encode(row)) == Ok(row)
  assert remote_send.key("7b1c") == "remote-send/7b1c"
  assert remote_send.decode(json.Null) == Error("expected a send row, got null")
  assert remote_send.decode(json.Object([])) == Error("missing `id`")
}
