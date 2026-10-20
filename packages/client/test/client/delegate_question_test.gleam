//// What a delegate session owes its spawner's operator when a child is refused by
//// its sandbox (protocol-change/089): the row a raised request leaves, and the
//// pass that sends the record, then its decided state, and then lets it go.
////
//// The runtime is a real one on a private SQLite file and the records are raised
//// through the door `client/escalate` uses. The laptop is played by a function
//// that reports what it is asked, and is connected or not as the case needs.

import broker/escalation as broker_escalation
import broker/policy.{type Grant}
import client/approval_ceiling
import client/delegate_drain
import client/delegate_outbox
import client/grants
import client/internal/ffi_os
import client/peer_outbox_drain
import client/protocol
import client/remote_mail
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import runtime/api
import runtime/escalation as durable
import runtime/lineage
import simplifile
import support/notes_session
import telemetry/log
import tools/agent.{type Handle}

const strand = "sub:^main/build-0123456789abcdef"

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn session(label: String) -> api.Runtime {
  let assert Ok(here) = simplifile.current_directory()
    as "locate the test workspace"
  let root =
    here
    <> "/build/delegate-question-"
    <> label
    <> "-"
    <> int.to_string(
      ffi_os.system_time_ms() * 1000 + ffi_os.unique_positive_integer(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "create the session directory"
  notes_session.open(root <> "/session.db", clock.fixed(1000)).runtime
}

fn ceiling() -> approval_ceiling.Ceiling {
  approval_ceiling.Ceiling(..approval_ceiling.nothing(), writable_roots: [
    "/srv/w",
  ])
}

fn link() -> delegate_outbox.SpawnerLink {
  delegate_outbox.SpawnerLink(
    parent_session: "0198c0de-0000-7000-8000-000000000001",
    spawner: "laptop",
    node: "laptop@100.64.0.5",
    ceiling: Some(ceiling()),
  )
}

// The child's lineage cell, which is what makes a record its.
fn child(runtime: api.Runtime) -> Handle {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key(strand),
      lineage.encode(lineage.Lineage(
        strand:,
        parent: "^main",
        depth: 1,
        minted_by: lineage.CallSite(
          operation: an_op(1),
          step_id: "step",
          source_index: 0,
        ),
        brief: an_op(2),
        tools: [],
        default_within_ms: None,
        deadline: None,
        detached: True,
        reaped: False,
        orchestrator: None,
      )),
    )
  agent.Handle(strand:, operation: an_op(3))
}

fn wanted() -> List(Grant) {
  [policy.GrantWritableRoot("/srv/w/a"), policy.GrantEnv("AWS_SECRET")]
}

fn raise(runtime: api.Runtime, id: String) -> Int {
  let denial =
    grants.encode_denial(
      reason: "tool requirements exceed the session policy",
      source: broker_escalation.PolicyDenial,
      wanted: wanted(),
    )
  let assert Ok(durable.Claimed(_)) =
    api.claim_escalation(
      runtime,
      id,
      denial,
      action: durable.Action(tool: "bash", digest: "d1", preview: "make"),
      scope: durable.CallScope(
        operation: an_op(3),
        strand:,
        step_id: "step",
        source_index: 0,
        call_id: "call-1",
      ),
      max_asks: 3,
    )
    as "the raise takes the claim"
  seq_of(runtime, id)
}

fn seq_of(runtime: api.Runtime, id: String) -> Int {
  let assert Ok(cell) = api.escalation_cell(runtime, id)
    as "the record is readable"
  cell.seq
}

// --- the laptop ----------------------------------------------------------------

type Heard {
  Asked(record: protocol.EscalationRecord)
}

fn laptop(
  connected connected: Bool,
  answer answer: Result(Result(Nil, remote_mail.ChildRefusal), Nil),
  heard heard: Subject(Heard),
) -> delegate_outbox.Laptop {
  delegate_outbox.Laptop(
    ..delegate_outbox.absent(),
    connected: fn() { connected },
    escalation: fn(_parent, _child, record) {
      process.send(heard, Asked(record))
      answer
    },
  )
}

fn pass(
  runtime: api.Runtime,
  laptop laptop: delegate_outbox.Laptop,
  now now: Int,
) -> peer_outbox_drain.Backlog {
  delegate_drain.pass(
    fn() { Ok(runtime) },
    fn() { False },
    fn() { now },
    link(),
    laptop,
    log.discard(),
  )()
}

fn owed() -> peer_outbox_drain.Backlog {
  peer_outbox_drain.Owed(peer_outbox_drain.Quick)
}

fn rows(runtime: api.Runtime) -> List(delegate_outbox.Question) {
  let assert Ok(found) = delegate_outbox.question_rows(runtime)
  list.map(found, fn(row) { row.1 })
}

// --- the row -------------------------------------------------------------------

pub fn a_raised_request_leaves_a_row_at_its_seq_for_its_parent_test() {
  let runtime = session("announce")
  let handle = child(runtime)
  let seq = raise(runtime, "policy-1")
  assert delegate_outbox.announce(runtime, "policy-1", until: 5000) == Ok(Nil)
  assert rows(runtime)
    == [
      delegate_outbox.Question(
        id: "policy-1",
        seq:,
        parent_strand: "main",
        child: agent.Handle(..handle, operation: an_op(3)),
        until: 5000 + delegate_outbox.answer_window_ms,
        sending: delegate_outbox.NotAcknowledged,
      ),
    ]

  // Announcing again at the same seq finds the row it wrote.
  assert delegate_outbox.announce(runtime, "policy-1", until: 9000) == Ok(Nil)
  assert list.length(rows(runtime)) == 1
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_request_that_is_not_a_childs_leaves_no_row_test() {
  let runtime = session("not-a-child")

  // No lineage cell is written for the strand, so it is not a child.
  let _ = raise(runtime, "policy-1")
  let assert Error(_) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_row_round_trips_and_a_damaged_one_is_named_test() {
  let row =
    delegate_outbox.Question(
      id: "policy-1",
      seq: 4,
      parent_strand: "main",
      child: agent.Handle(strand:, operation: an_op(3)),
      until: 100,
      sending: delegate_outbox.Acknowledged,
    )
  assert delegate_outbox.decode_question(delegate_outbox.encode_question(row))
    == Ok(row)
  assert delegate_outbox.question_key("policy-1", 4)
    == "delegate/outbox/escalation/policy-1/4"
}

// --- the pass ------------------------------------------------------------------

pub fn a_disconnected_laptop_is_not_asked_and_a_live_request_stays_owed_test() {
  let runtime = session("away")
  let _ = child(runtime)
  let _ = raise(runtime, "policy-1")
  let assert Ok(Nil) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)
  let heard = process.new_subject()
  assert pass(
      runtime,
      laptop: laptop(connected: False, answer: Ok(Ok(Nil)), heard:),
      now: 100,
    )
    == owed()
  assert process.receive(heard, 0) == Error(Nil)

  // The call stopped parking at 5000, but the record is still decidable, so the
  // pass keeps waiting for the laptop through the answer window.
  assert pass(
      runtime,
      laptop: laptop(connected: False, answer: Ok(Ok(Nil)), heard:),
      now: 6000,
    )
    == owed()

  // Once the answer window has closed the record is the box owner's, and the
  // pass does not wait on it.
  assert pass(
      runtime,
      laptop: laptop(connected: False, answer: Ok(Ok(Nil)), heard:),
      now: 5000 + delegate_outbox.answer_window_ms,
    )
    == peer_outbox_drain.Clear
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_connected_laptop_is_sent_the_record_with_what_the_ceiling_admits_test() {
  let runtime = session("sends")
  let _ = child(runtime)
  let seq = raise(runtime, "policy-1")
  let assert Ok(Nil) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)
  let heard = process.new_subject()
  let up = laptop(connected: True, answer: Ok(Ok(Nil)), heard:)
  assert pass(runtime, laptop: up, now: 100) == owed()
  let assert Ok(Asked(record)) = process.receive(heard, 0)
  assert record.escalation_id == "policy-1"
  assert record.seq == seq
  assert record.status == "pending"
  assert record.strand == strand

  // The laptop is told which of the wanted grants it may approve.
  assert record.admitted == Some([policy.GrantWritableRoot("/srv/w/a")])
  let assert [row] = rows(runtime)
  assert row.sending == delegate_outbox.Acknowledged

  // An acknowledged seq is not sent again, and the pass stays owed for the
  // decision.
  assert pass(runtime, laptop: up, now: 200) == owed()
  assert process.receive(heard, 0) == Error(Nil)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_decided_request_is_sent_once_more_and_then_the_row_goes_test() {
  let runtime = session("decided")
  let _ = child(runtime)
  let seq = raise(runtime, "policy-1")
  let assert Ok(Nil) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)
  let heard = process.new_subject()
  let up = laptop(connected: True, answer: Ok(Ok(Nil)), heard:)
  let _ = pass(runtime, laptop: up, now: 100)
  let assert Ok(Asked(_)) = process.receive(heard, 0)

  let assert Ok(cell) = api.escalation_cell(runtime, "policy-1")
  let assert Ok(_) = api.deny_escalation_at(runtime, cell, None)
  assert pass(runtime, laptop: up, now: 200) == peer_outbox_drain.Clear
  let assert Ok(Asked(decided)) = process.receive(heard, 0)
  assert decided.status == "rejected"
  assert decided.seq > seq
  assert decided.denial == None
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_row_a_newer_raise_replaced_is_dropped_without_a_send_test() {
  let runtime = session("superseded")
  let _ = child(runtime)
  let first = raise(runtime, "policy-1")
  let assert Ok(Nil) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)

  // A claim by another call refreshes the pending record and moves its seq.
  let second = raise(runtime, "policy-1")
  assert second > first
  let heard = process.new_subject()
  let up = laptop(connected: True, answer: Ok(Ok(Nil)), heard:)
  assert pass(runtime, laptop: up, now: 100) == peer_outbox_drain.Clear
  assert process.receive(heard, 0) == Error(Nil)
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

// The e2e drive of 2026-10-19 found this: since a refused call parks for only a
// five-second grace, a row that ended with the park was dropped before a laptop
// a network away was told, and the request was never shown. The call has
// stopped waiting here, but the record is still decidable and the child's next
// run spends an approval, so the laptop is still asked.
pub fn a_request_whose_call_stopped_parking_is_still_sent_test() {
  let runtime = session("after-park")
  let _ = child(runtime)
  let seq = raise(runtime, "policy-1")
  let assert Ok(Nil) = delegate_outbox.announce(runtime, "policy-1", until: 50)
  let heard = process.new_subject()
  let up = laptop(connected: True, answer: Ok(Ok(Nil)), heard:)
  assert pass(runtime, laptop: up, now: 100) == owed()
  let assert Ok(Asked(record)) = process.receive(heard, 0)
  assert record.seq == seq
  assert record.status == "pending"

  // A decision taken after the park still reaches the laptop as the decided
  // state, which is what clears its card.
  let assert Ok(cell) = api.escalation_cell(runtime, "policy-1")
  let assert Ok(_) = api.deny_escalation_at(runtime, cell, None)
  assert pass(runtime, laptop: up, now: 200) == peer_outbox_drain.Clear
  let assert Ok(Asked(decided)) = process.receive(heard, 0)
  assert decided.status == "rejected"
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_answer_window_that_closed_drops_the_row_and_sends_nothing_test() {
  let runtime = session("closed")
  let _ = child(runtime)
  let _ = raise(runtime, "policy-1")
  let assert Ok(Nil) = delegate_outbox.announce(runtime, "policy-1", until: 50)
  let heard = process.new_subject()
  let up = laptop(connected: True, answer: Ok(Ok(Nil)), heard:)
  assert pass(runtime, laptop: up, now: 50 + delegate_outbox.answer_window_ms)
    == peer_outbox_drain.Clear
  assert process.receive(heard, 0) == Error(Nil)
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn silence_and_a_retryable_refusal_keep_the_row_and_a_final_one_drops_it_test() {
  let runtime = session("answers")
  let _ = child(runtime)
  let _ = raise(runtime, "policy-1")
  let assert Ok(Nil) =
    delegate_outbox.announce(runtime, "policy-1", until: 5000)
  let heard = process.new_subject()

  assert pass(
      runtime,
      laptop: laptop(connected: True, answer: Error(Nil), heard:),
      now: 100,
    )
    == owed()
  assert pass(
      runtime,
      laptop: laptop(
        connected: True,
        answer: Ok(Error(remote_mail.ParentSessionNotOpen)),
        heard:,
      ),
      now: 100,
    )
    == owed()
  let assert [row] = rows(runtime)
  assert row.sending == delegate_outbox.NotAcknowledged

  assert pass(
      runtime,
      laptop: laptop(
        connected: True,
        answer: Ok(Error(remote_mail.UnknownChild)),
        heard:,
      ),
      now: 100,
    )
    == peer_outbox_drain.Clear
  assert rows(runtime) == []
  let assert Ok(Nil) = api.close(runtime)
}

// --- who can answer ------------------------------------------------------------

pub fn a_delegate_session_is_answerable_only_with_a_ceiling_and_a_connected_node_test() {
  let up =
    laptop(connected: True, answer: Ok(Ok(Nil)), heard: process.new_subject())
  let down =
    laptop(connected: False, answer: Ok(Ok(Nil)), heard: process.new_subject())
  assert delegate_outbox.answers(Some(link()), Some(up))
  assert !delegate_outbox.answers(Some(link()), Some(down))

  // A spawner with no ceiling takes no decision, however connected it is.
  assert !delegate_outbox.answers(
    Some(delegate_outbox.SpawnerLink(..link(), ceiling: None)),
    Some(up),
  )

  // A session with no spawner, or no way to reach one, is not answerable.
  assert !delegate_outbox.answers(None, Some(up))
  assert !delegate_outbox.answers(Some(link()), None)
}
