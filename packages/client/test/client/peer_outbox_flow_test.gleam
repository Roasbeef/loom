//// The sender's peer outbox against two real runtimes.
////
//// The sender and the recipient each answer through `peer_mail.handle`, the
//// call the Agency actor makes, so rows are written to a real session store
//// and the recipient's receipts are real. What a test scripts is the network
//// between them: a `Script` stands in for the recipient's endpoint and says,
//// per delivery, whether nobody answers, whether the recipient commits and
//// the reply is lost, or whether the call reaches it. The drainer's own
//// timing is in `peer_outbox_drain_test`.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/gateway_test
import client/peer_mail
import client/peer_outbox
import client/peers
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/peer_rig.{Down, Gone, Lose, Pass, Resident, Saved}

pub fn a_reachable_recipient_is_answered_as_before_and_the_row_is_admitted_test() {
  let rig = peer_rig.rig(1000, [], Pass)
  let assert Ok(receipt) = peer_rig.send(rig, "m1") as "the send is admitted"
  assert peer_rig.field(receipt, "admitted") == json.Bool(True)
  assert peer_rig.receipts(rig.recipient) == 1
  assert peer_rig.counts(rig) == #(1, 1)

  // The sender's own row now holds the receipt the recipient stored.
  assert peer_rig.stored_receipt(rig, "m1") == receipt
  assert peer_rig.due(rig) == []
}

pub fn a_retry_of_an_admitted_message_is_answered_from_the_row_test() {
  let rig = peer_rig.rig(1010, [], Pass)
  let assert Ok(receipt) = peer_rig.send(rig, "m1")
  let assert Ok(again) = peer_rig.send(rig, "m1") as "the retry is answered"
  assert again == receipt

  // The retry never reached the network: the row already holds the answer.
  assert peer_rig.counts(rig) == #(1, 1)
  assert peer_rig.receipts(rig.recipient) == 1
  let assert Error(reason) =
    peers.send(rig.wiring, "main", rig.recipient_name, "main", "m1", "changed")
    as "the id names different content"
  assert reason == "message id was already used for different content or target"
}

pub fn the_pending_request_is_the_request_the_recipient_stores_test() {
  let rig = peer_rig.rig(1020, [Down], Pass)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  let assert [row] = peer_rig.due(rig)
  let assert Ok(receipt) = peer_rig.send(rig, "m1")
    as "the second attempt delivers"
  let assert Some(request) = peer_outbox.request(rig.sender_name, row)
  assert peer_rig.field(receipt, "request") == request
}

pub fn an_unreachable_recipient_queues_the_message_test() {
  let rig = peer_rig.rig(1030, [Down], Down)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
    as "an unreachable owner is not an error"
  assert peers.is_queued(queued)
  assert peer_rig.field(queued, "message_id") == json.String("m1")
  assert peer_rig.field(queued, "note") == json.String(peers.queued_note)
  assert peer_rig.receipts(rig.recipient) == 0
  assert peer_rig.counts(rig) == #(1, 1)
  let assert [row] = peer_rig.due(rig)
  assert row.message_id == "m1"
  assert row.state == peer_outbox.Pending("hello", peer_outbox.OnOwner)
}

pub fn a_resend_delivers_exactly_one_message_after_the_owner_returns_test() {
  let rig = peer_rig.rig(1040, [Down, Down], Pass)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  let assert [row] = peer_rig.due(rig)
  assert peers.resend(rig.wiring, row) == peer_outbox.Unanswered
  assert peer_rig.receipts(rig.recipient) == 0
  assert peer_rig.due(rig) == [row]

  let assert peer_outbox.Receipt(receipt) = peers.resend(rig.wiring, row)
    as "the third attempt reaches the recipient"
  assert peer_rig.receipts(rig.recipient) == 1
  assert peer_rig.due(rig) == []
  assert peer_rig.stored_receipt(rig, "m1") == receipt
  assert peer_rig.counts(rig) == #(3, 3)
}

pub fn a_lost_reply_is_retried_to_the_same_receipt_without_a_second_message_test() {
  let rig = peer_rig.rig(1050, [Lose], Pass)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // The recipient committed before its reply was lost.
  assert peer_rig.receipts(rig.recipient) == 1
  let assert [row] = peer_rig.due(rig)
  let assert peer_outbox.Receipt(receipt) = peers.resend(rig.wiring, row)
  assert peer_rig.receipts(rig.recipient) == 1
  assert peer_rig.counts(rig) == #(2, 2)
  assert peer_rig.stored_receipt(rig, "m1") == receipt
}

pub fn a_definitive_refusal_is_returned_and_recorded_and_not_retried_test() {
  let rig = peer_rig.rig(1060, [], Pass)
  peer_rig.set_resident(rig, Gone)
  assert peer_rig.send(rig, "m1") == Error(peers.not_running)
  assert peer_rig.counts(rig) == #(0, 1)

  // The row is finished, so nothing is due and nothing will be attempted.
  assert peer_rig.due(rig) == []
  assert peer_rig.stored_receipt(rig, "m1") == json.Null
  assert peer_rig.counts(rig) == #(0, 1)
}

pub fn a_refused_message_may_be_sent_again_once_the_cause_passes_test() {
  let rig = peer_rig.rig(1070, [], Pass)
  peer_rig.set_resident(rig, Gone)
  assert peer_rig.send(rig, "m1") == Error(peers.not_running)
  peer_rig.set_resident(rig, Resident)
  let assert Ok(receipt) = peer_rig.send(rig, "m1")
    as "the same id is attempted again"
  assert peer_rig.field(receipt, "admitted") == json.Bool(True)
  assert peer_rig.receipts(rig.recipient) == 1
}

pub fn a_directory_that_cannot_reach_the_owner_queues_the_message_test() {
  let sender = gateway_test.reserved_fixture(peer_rig.session_id(1080)).runtime
  let recipient = ids.session_id_to_string(peer_rig.session_id(1081))
  let source =
    peer_mail.Endpoint("sender", fn(command) {
      peer_mail.handle(sender, clock.fixed(0), command)
      |> peer_mail.refused
    })
  let wiring =
    peers.Wiring(
      source,
      json.Null,
      Some(
        peers.Directory(
          resolve: fn(id) {
            case id == "sender" {
              True -> Ok(source)
              False -> Error(peer_mail.Unreachable)
            }
          },
          describe: fn(_) { Ok(json.Null) },
        ),
      ),
    )
  let assert Ok(_) = source.call(peer_mail.Link("main", recipient, "main"))
    as "the sender records the link"
  let assert Ok(queued) =
    peers.send(wiring, "main", recipient, "main", "m1", "hello")
    as "an unreachable directory queues"
  assert peers.is_queued(queued)
}

pub fn a_strand_at_the_bound_refuses_when_every_row_is_pending_test() {
  let rig = peer_rig.rig(1090, [], Down)
  upto(peer_outbox.row_limit)
  |> list.each(fn(n) {
    let assert Ok(queued) = peer_rig.send(rig, "m" <> int.to_string(n))
      as "a queued message is accepted below the bound"
    assert peers.is_queued(queued)
  })
  assert peer_rig.send(rig, "one-too-many") == Error("outbox_full")
  assert list.length(peer_rig.due(rig)) == peer_outbox.row_limit

  // A retry of a row that already exists is not a new row.
  let assert Ok(again) = peer_rig.send(rig, "m1")
    as "an existing row is resumed"
  assert peers.is_queued(again)
}

pub fn a_strand_at_the_bound_evicts_the_oldest_finished_row_test() {
  let rig = peer_rig.rig(1100, [Pass, Pass, Pass], Down)
  let assert Ok(_) = peer_rig.send(rig, "first")
  let assert Ok(_) = peer_rig.send(rig, "second")
  let assert Ok(_) = peer_rig.send(rig, "third")
  upto(peer_outbox.row_limit - 3)
  |> list.each(fn(n) {
    let assert Ok(queued) = peer_rig.send(rig, "q" <> int.to_string(n))
    assert peers.is_queued(queued)
  })
  assert peer_rig.stored_receipt(rig, "first") != json.Null

  // The outbox is at the bound; a new message takes the oldest finished row.
  let assert Ok(queued) = peer_rig.send(rig, "newest")
    as "a finished row makes room"
  assert peers.is_queued(queued)
  assert peer_rig.stored_receipt(rig, "first") == json.Null
  assert peer_rig.stored_receipt(rig, "second") != json.Null
  assert list.length(peer_rig.due(rig)) == peer_outbox.row_limit - 2
}

pub fn a_pending_row_older_than_an_hour_is_refused_test() {
  let rig = peer_rig.rig_on(1110, [], Down, clock.fixed(0))
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // The same store, read an hour and a millisecond later.
  let later =
    peer_mail.Endpoint(rig.sender_name, fn(command) {
      peer_mail.handle(
        rig.sender,
        clock.fixed(peer_outbox.pending_ttl_ms + 1),
        command,
      )
      |> peer_mail.refused
    })
  let assert Ok(json.Array(items)) = later.call(peer_mail.OutboxDue)
  assert items == []

  // The row is refused with the unreachable reason and is not final: the
  // same id is attempted again once the recipient answers.
  let assert Ok(found) =
    later.call(peer_mail.OutboxReceipt("main", rig.recipient_name, "m1"))
  assert found == json.Null
  process.send(rig.script, peer_rig.SetThen(Pass))
  let assert Ok(receipt) = peer_rig.send(rig, "m1")
    as "an expired message is sent again"
  assert peer_rig.field(receipt, "admitted") == json.Bool(True)
}

pub fn a_row_not_yet_an_hour_old_is_still_due_test() {
  let rig = peer_rig.rig_on(1120, [], Down, clock.fixed(0))
  let assert Ok(_) = peer_rig.send(rig, "m1")
  let still =
    peer_mail.Endpoint(rig.sender_name, fn(command) {
      peer_mail.handle(
        rig.sender,
        clock.fixed(peer_outbox.pending_ttl_ms),
        command,
      )
      |> peer_mail.refused
    })
  let assert Ok(json.Array([_])) = still.call(peer_mail.OutboxDue)
    as "the row is exactly an hour old and still owed"
}

pub fn unlinking_deletes_the_pending_rows_to_that_target_only_test() {
  let rig = peer_rig.rig(1130, [Pass], Down)
  let assert Ok(_) = peer_rig.send(rig, "delivered")
  let assert Ok(queued) = peer_rig.send(rig, "waiting")
  assert peers.is_queued(queued)
  assert list.length(peer_rig.due(rig)) == 1

  let assert Ok(_) = peers.unlink(rig.source, rig.target, "main", "main")
    as "the owner removes the link"
  assert peer_rig.due(rig) == []

  // The delivered message keeps its row: it is the sender's record.
  assert peer_rig.stored_receipt(rig, "delivered") != json.Null
  assert peer_rig.counts(rig) == #(2, 2)
}

// A program's `peer.send` and `peer.sent_receipt`, through the production
// router, which supplies the sending strand itself.
fn routed(
  rig: peer_rig.Rig,
  cap: String,
  args: List(#(String, String)),
) -> framing.CapOutcome {
  let route =
    peers.router(rig.wiring, "main", fn(_) {
      Error(satellite.CapDenial("unknown", "unexpected fallback"))
    })
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(0), 701))
  let request =
    satellite.CapRequest(
      cap:,
      args: msgpack.MapValue(
        list.map(args, fn(pair) {
          #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
        }),
      ),
      identity: identity.run_phase(identity.for_execution(
        op_id: op,
        step_id: "outbox",
        budget: budget.Budget(max_outstanding: 4, deadline_ms: 9_000_000),
      )),
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [],
      cwd: "/work",
      ordinal: 0,
    )
  let assert Ok(satellite.ServedHere(serve)) = route(request)
    as "the peer router serves the capability"
  serve()
}

pub fn a_program_is_told_a_queued_send_by_denial_code_test() {
  let rig = peer_rig.rig(1140, [Down], Down)
  let answer =
    routed(rig, "peer.send", [
      #("session", rig.recipient_name),
      #("strand", "main"),
      #("message_id", "m1"),
      #("text", "hello"),
    ])
  assert answer == framing.CapErr("peer_queued", peers.queued_note)
}

pub fn sent_receipt_reads_the_local_row_before_asking_the_recipient_test() {
  let rig = peer_rig.rig(1150, [Pass], Down)
  let assert Ok(receipt) = peer_rig.send(rig, "m1")

  // With the recipient no longer reachable through the directory, only the
  // sender's own row can answer.
  peer_rig.set_resident(rig, Saved)
  let answer =
    routed(rig, "peer.sent_receipt", [
      #("session", rig.recipient_name),
      #("message_id", "m1"),
    ])
  assert answer == framing.CapOk(msgpack.StringValue(json.to_string(receipt)))

  // A message with no admitted row falls through to the recipient, which the
  // directory can no longer resolve.
  let unknown =
    routed(rig, "peer.sent_receipt", [
      #("session", rig.recipient_name),
      #("message_id", "never-sent"),
    ])
  assert unknown == framing.CapErr("peer_refused", peer_mail.not_open_reason)
}

pub fn the_unreachable_note_does_not_promise_a_fixed_pace_test() {
  // The drainer slows while other messages wait for a session to be opened,
  // and a message queued then is first retried at the next tick.
  assert string.contains(peers.queued_note, "at first about every 5 seconds")
}

pub fn a_saved_recipient_is_queued_and_delivered_once_it_is_open_test() {
  let rig = peer_rig.rig(1160, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
    as "a send to a saved session is queued, not refused"
  assert peers.is_queued(queued)
  assert peer_rig.field(queued, "note")
    == json.String(peers.queued_unopened_note)
  assert peer_rig.receipts(rig.recipient) == 0

  // The recipient was looked up and never asked.
  assert peer_rig.counts(rig) == #(0, 1)
  let assert [row] = peer_rig.due(rig)
  assert row.state == peer_outbox.Pending("hello", peer_outbox.OnOpen)

  // Another attempt while it is still saved waits again.
  assert peers.resend(rig.wiring, row) == peer_outbox.NotOpen
  assert peer_rig.receipts(rig.recipient) == 0

  // The owner opens it, and the next attempt is admitted.
  peer_rig.set_resident(rig, Resident)
  let assert [row] = peer_rig.due(rig)
  let assert peer_outbox.Receipt(receipt) = peers.resend(rig.wiring, row)
    as "the open recipient admits the message"
  assert peer_rig.receipts(rig.recipient) == 1
  assert peer_rig.stored_receipt(rig, "m1") == receipt
  assert peer_rig.due(rig) == []

  // Sending it again is the stored receipt and not a second message.
  assert peer_rig.send(rig, "m1") == Ok(receipt)
  assert peer_rig.receipts(rig.recipient) == 1
}

pub fn a_message_that_waits_an_hour_for_an_open_is_refused_in_those_words_test() {
  let rig = peer_rig.rig_on(1170, [], Pass, clock.fixed(0))
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  let later =
    peer_mail.Endpoint(rig.sender_name, fn(command) {
      peer_mail.handle(
        rig.sender,
        clock.fixed(peer_outbox.pending_ttl_ms + 1),
        command,
      )
      |> peer_mail.refused
    })
  let assert Ok(json.Array(items)) = later.call(peer_mail.OutboxDue)
  assert items == []
  let assert Some(peer_outbox.Row(state: peer_outbox.Refused(reason), ..)) =
    peer_rig.row(rig, "m1")
    as "the row is refused"
  assert reason == peer_mail.not_opened_in_time_reason
}

pub fn a_row_that_stopped_waiting_for_an_open_is_refused_as_an_owner_that_was_silent_test() {
  let rig = peer_rig.rig_on(1180, [], Down, clock.fixed(0))
  peer_rig.set_resident(rig, Saved)
  let assert Ok(_) = peer_rig.send(rig, "m1")
  let assert Some(peer_outbox.Row(
    state: peer_outbox.Pending(wait: peer_outbox.OnOpen, ..),
    ..,
  )) = peer_rig.row(rig, "m1")
    as "the row waits for an open"

  // The owner is found again but does not answer, so the row now waits on it.
  peer_rig.set_resident(rig, Resident)
  let assert [row] = peer_rig.due(rig)
  assert peers.resend(rig.wiring, row) == peer_outbox.Unanswered
  let assert Some(peer_outbox.Row(
    state: peer_outbox.Pending(wait: peer_outbox.OnOwner, ..),
    ..,
  )) = peer_rig.row(rig, "m1")
    as "the row waits for the owner"
  let later =
    peer_mail.Endpoint(rig.sender_name, fn(command) {
      peer_mail.handle(
        rig.sender,
        clock.fixed(peer_outbox.pending_ttl_ms + 1),
        command,
      )
      |> peer_mail.refused
    })
  let assert Ok(json.Array([])) = later.call(peer_mail.OutboxDue)
  let assert Some(peer_outbox.Row(state: peer_outbox.Refused(reason), ..)) =
    peer_rig.row(rig, "m1")
  assert reason == peer_mail.unreachable_reason
}

pub fn a_recipient_deleted_while_a_message_waits_ends_the_message_refused_test() {
  let rig = peer_rig.rig(1190, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)

  // No catalogue holds the session any more: nothing will ever open it.
  peer_rig.set_resident(rig, Gone)
  let assert [row] = peer_rig.due(rig)
  assert peers.resend(rig.wiring, row)
    == peer_outbox.Rejected(peers.not_running)
  assert peer_rig.due(rig) == []
  let assert Some(peer_outbox.Row(state: peer_outbox.Refused(reason), ..)) =
    peer_rig.row(rig, "m1")
  assert reason == peers.not_running
  assert peer_rig.receipts(rig.recipient) == 0
}

pub fn unlinking_deletes_a_message_waiting_for_an_open_test() {
  let rig = peer_rig.rig(1200, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let assert Ok(queued) = peer_rig.send(rig, "m1")
  assert peers.is_queued(queued)
  let assert Ok(_) = peers.unlink(rig.source, rig.target, "main", "main")
    as "the owner removes the link"
  assert peer_rig.due(rig) == []
  assert peer_rig.row(rig, "m1") == option.None

  // Opened later, nothing is delivered for the link that was removed.
  peer_rig.set_resident(rig, Resident)
  assert peer_rig.receipts(rig.recipient) == 0
}

pub fn a_program_is_told_a_saved_recipient_by_the_same_denial_code_test() {
  let rig = peer_rig.rig(1210, [], Pass)
  peer_rig.set_resident(rig, Saved)
  let answer =
    routed(rig, "peer.send", [
      #("session", rig.recipient_name),
      #("strand", "main"),
      #("message_id", "m1"),
      #("text", "hello"),
    ])
  assert answer == framing.CapErr("peer_queued", peers.queued_unopened_note)
}

fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}
