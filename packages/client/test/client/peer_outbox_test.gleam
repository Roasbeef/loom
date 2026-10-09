//// The pure rules of the sender's peer outbox: what a claim means, how a row
//// moves, when a strand is full, and when a pending row expires.
////
//// Nothing here touches a store or a process. The same rules are exercised
//// against real runtimes in `peer_outbox_flow_test`.

import client/peer_outbox.{
  Admitted, Conflict, Evict, Free, Full, Insert, NotOpen, OnOpen, Pending,
  Receipt, Refused, Rejected, Resume, Row, Settled, Unanswered,
}
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn row(id: String, text: String, at: Int) -> peer_outbox.Row {
  peer_outbox.pending("main", "peer", "main", id, text, at)
}

fn receipt_for(source: String, row: peer_outbox.Row) -> json.JsonValue {
  let assert Some(request) = peer_outbox.request(source, row)
    as "a pending row has a request"
  json.Object([
    #("request", request),
    #("source", json.Null),
    #("admitted", json.Bool(True)),
  ])
}

fn finished(id: String, at: Int) -> peer_outbox.Row {
  Row(..row(id, "t", at), state: Refused("no"))
}

pub fn a_new_message_is_inserted_test() {
  assert peer_outbox.claim(None, row("m1", "hello", 0), "src") == Insert
}

pub fn the_same_pending_message_resumes_without_a_write_test() {
  let stored = row("m1", "hello", 0)
  assert peer_outbox.claim(Some(stored), row("m1", "hello", 99), "src")
    == Resume
}

pub fn a_pending_message_id_reused_for_other_text_conflicts_test() {
  assert peer_outbox.claim(
      Some(row("m1", "hello", 0)),
      row("m1", "changed", 0),
      "src",
    )
    == Conflict
}

pub fn a_refused_message_may_be_sent_again_test() {
  let stored = Row(..row("m1", "hello", 0), state: Refused("not running"))
  assert peer_outbox.claim(Some(stored), row("m1", "changed", 5), "src")
    == Insert
}

pub fn an_admitted_message_answers_with_its_receipt_test() {
  let sent = row("m1", "hello", 0)
  let receipt = receipt_for("src", sent)
  let stored = Row(..sent, state: Admitted(receipt))
  assert peer_outbox.claim(Some(stored), row("m1", "hello", 9), "src")
    == Settled(receipt)
}

pub fn an_admitted_message_id_reused_for_other_text_conflicts_test() {
  let sent = row("m1", "hello", 0)
  let stored = Row(..sent, state: Admitted(receipt_for("src", sent)))
  assert peer_outbox.claim(Some(stored), row("m1", "changed", 9), "src")
    == Conflict
}

pub fn the_request_names_the_sending_session_so_a_receipt_compares_equal_test() {
  let sent = row("m1", "hello", 0)
  assert peer_outbox.request("a", sent) != peer_outbox.request("b", sent)
  let assert Some(json.Object(fields)) = peer_outbox.request("a", sent)
  assert list.map(fields, fn(pair) { pair.0 })
    == [
      "source_session", "source_strand", "target_strand", "message_id", "body",
    ]
}

pub fn a_strand_under_the_bound_has_room_test() {
  let rows = [#("k1", row("m1", "t", 0))]
  assert peer_outbox.room(rows, "main") == Free
}

fn rows_of(count: Int, make: fn(Int) -> peer_outbox.Row) {
  upto(count)
  |> list.map(fn(n) { #("key" <> int.to_string(n), make(n)) })
}

pub fn a_full_strand_evicts_the_oldest_finished_row_test() {
  let rows =
    rows_of(peer_outbox.row_limit, fn(n) {
      case n {
        5 -> finished("old", 10)
        9 -> finished("newer", 20)
        _ -> row("p" <> int.to_string(n), "t", 100)
      }
    })
  assert peer_outbox.room(rows, "main") == Evict("key5")
}

pub fn finished_rows_of_equal_age_evict_by_key_order_test() {
  let rows =
    rows_of(peer_outbox.row_limit, fn(n) {
      case n {
        3 | 7 -> finished("f" <> int.to_string(n), 10)
        _ -> row("p" <> int.to_string(n), "t", 100)
      }
    })
  assert peer_outbox.room(rows, "main") == Evict("key3")
  assert peer_outbox.room(list.reverse(rows), "main") == Evict("key3")
}

pub fn a_strand_of_only_pending_rows_is_full_test() {
  let rows =
    rows_of(peer_outbox.row_limit, fn(n) { row(int.to_string(n), "t", n) })
  assert peer_outbox.room(rows, "main") == Full
}

pub fn another_strands_rows_do_not_count_toward_the_bound_test() {
  let rows =
    rows_of(peer_outbox.row_limit, fn(n) {
      Row(..row(int.to_string(n), "t", n), strand: "other")
    })
  assert peer_outbox.room(rows, "main") == Free
  assert peer_outbox.room(rows, "other") == Full
}

pub fn an_attempt_settles_only_a_pending_row_test() {
  let sent = row("m1", "hello", 0)
  let receipt = receipt_for("src", sent)
  assert peer_outbox.settle(sent, Receipt(receipt))
    == Some(Row(..sent, state: Admitted(receipt)))
  assert peer_outbox.settle(sent, Rejected("no grant"))
    == Some(Row(..sent, state: Refused("no grant")))
  assert peer_outbox.settle(sent, Unanswered) == None
}

pub fn the_first_outcome_of_a_row_is_final_test() {
  let sent = row("m1", "hello", 0)
  let admitted = Row(..sent, state: Admitted(receipt_for("src", sent)))
  let refused = Row(..sent, state: Refused("no grant"))
  assert peer_outbox.settle(admitted, Rejected("late")) == None
  assert peer_outbox.settle(refused, Receipt(json.Null)) == None
  assert peer_outbox.expire(admitted, 10_000_000, "gone") == None
  assert peer_outbox.expire(refused, 10_000_000, "gone") == None
}

pub fn a_pending_row_expires_only_after_the_hour_test() {
  let sent = row("m1", "hello", 1000)
  let edge = 1000 + peer_outbox.pending_ttl_ms
  assert peer_outbox.expire(sent, edge, "owner unreachable") == None
  assert peer_outbox.expire(sent, edge + 1, "owner unreachable")
    == Some(Row(..sent, state: Refused("owner unreachable")))
}

pub fn every_state_survives_a_round_trip_test() {
  let sent = row("m1", "hello \"quoted\"", 42)
  let admitted = Row(..sent, state: Admitted(receipt_for("src", sent)))
  let refused = Row(..sent, state: Refused("not running"))
  list.each([sent, admitted, refused], fn(original) {
    assert peer_outbox.decode(peer_outbox.encode(original)) == Ok(original)
  })
}

pub fn a_malformed_row_is_an_error_not_a_crash_test() {
  assert peer_outbox.decode(json.Null) == Error("expected outbox object")
  assert peer_outbox.decode(json.Object([])) == Error("missing outbox field")
  let unknown =
    json.Object([
      #("strand", json.String("main")),
      #("session", json.String("peer")),
      #("target_strand", json.String("main")),
      #("message_id", json.String("m1")),
      #("queued_at", json.Int(0)),
      #("state", json.String("lost")),
    ])
  assert peer_outbox.decode(unknown) == Error("unknown outbox state")
}

pub fn a_row_key_names_strand_session_and_id_test() {
  let base = peer_outbox.key("main", "peer", "m1")
  assert base == peer_outbox.key("main", "peer", "m1")
  assert base != peer_outbox.key("other", "peer", "m1")
  assert base != peer_outbox.key("main", "elsewhere", "m1")
  assert base != peer_outbox.key("main", "peer", "m2")
  assert base != peer_outbox.key("main", "peerm", "1")
  assert string.starts_with(base, peer_outbox.key_prefix)
}

pub fn a_saved_recipient_changes_what_a_pending_row_waits_for_test() {
  let sent = row("m1", "hello", 0)
  let assert Some(for_open) = peer_outbox.settle(sent, NotOpen)
    as "the first answer that the recipient is saved is written"
  assert for_open.state == Pending("hello", OnOpen)
  assert peer_outbox.waiting_for(for_open) == Some(OnOpen)

  // The same answer again changes nothing, so a recipient that stays saved
  // costs no write per attempt.
  assert peer_outbox.settle(for_open, NotOpen) == None

  // The next attempt may find the owner gone, and the row then waits on the
  // owner again.
  assert peer_outbox.settle(for_open, Unanswered) == Some(sent)

  // A receipt or a refusal still ends a row that was waiting for an open.
  let receipt = receipt_for("src", sent)
  assert peer_outbox.settle(for_open, Receipt(receipt))
    == Some(Row(..for_open, state: Admitted(receipt)))
  assert peer_outbox.settle(for_open, Rejected("no grant"))
    == Some(Row(..for_open, state: Refused("no grant")))
}

pub fn a_finished_row_does_not_wait_for_anything_test() {
  let sent = row("m1", "hello", 0)
  let admitted = Row(..sent, state: Admitted(receipt_for("src", sent)))
  assert peer_outbox.waiting_for(admitted) == None
  assert peer_outbox.waiting_for(finished("m2", 0)) == None
  assert peer_outbox.settle(admitted, NotOpen) == None
  assert peer_outbox.settle(finished("m2", 0), NotOpen) == None
}

pub fn an_expired_row_is_refused_in_words_that_name_what_it_waited_for_test() {
  let sent = row("m1", "hello", 0)
  let assert Some(for_open) = peer_outbox.settle(sent, NotOpen)
  assert peer_outbox.expiry_reason(sent, "silent", "closed") == "silent"
  assert peer_outbox.expiry_reason(for_open, "silent", "closed") == "closed"
  assert peer_outbox.expire(
      for_open,
      peer_outbox.pending_ttl_ms + 1,
      peer_outbox.expiry_reason(for_open, "silent", "closed"),
    )
    == Some(Row(..for_open, state: Refused("closed")))
}

pub fn the_wait_survives_a_round_trip_and_an_older_row_waits_for_its_owner_test() {
  let sent = row("m1", "hello", 42)
  let assert Some(for_open) = peer_outbox.settle(sent, NotOpen)
  assert peer_outbox.decode(peer_outbox.encode(for_open)) == Ok(for_open)

  // A row written before a recipient could be waited for has no `wait` field.
  let assert json.Object(fields) = peer_outbox.encode(sent)
    as "a row encodes as an object"
  let older = json.Object(list.filter(fields, fn(pair) { pair.0 != "wait" }))
  assert peer_outbox.decode(older) == Ok(sent)

  // A field of any other shape is an error, not a guess.
  let odd =
    json.Object(
      list.map(fields, fn(pair) {
        case pair.0 {
          "wait" -> #("wait", json.String("sideways"))
          _ -> pair
        }
      }),
    )
  assert peer_outbox.decode(odd) == Error("unknown outbox wait")
}

fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}
