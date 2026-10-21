//// What a relayed session says to the page that started it
//// (protocol-change/094): its overview, its pending requests, a message delivered
//// once, and a page of its transcript.
////
//// The runtime is a real one on a private SQLite file, as in
//// `remote_decision_test`, with a provider that never answers, so a message that
//// starts a run leaves it open and a second one meets a strand that is busy.
//// What is not here is the hub's stop and decision, which the registry-level
//// tests drive through a fake endpoint and `remote_decision_test` drives through
//// the real judgement.

import broker/escalation as broker_escalation
import broker/policy
import client/approval_ceiling
import client/grants
import client/internal/ffi_os
import client/peer_mail
import client/relayed_session
import client/remote_mail
import client/remote_top
import core/clock
import core/ids
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/api
import runtime/escalation as durable
import session_view/remote_transcript
import simplifile
import support/notes_session

fn workspace(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "locate the test workspace"
  let root =
    here
    <> "/build/relayed-session-"
    <> label
    <> "-"
    <> int.to_string(
      ffi_os.system_time_ms() * 1000 + ffi_os.unique_positive_integer(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "create the workspace"
  root
}

fn session(label: String) -> #(String, api.Runtime) {
  let root = workspace(label)
  #(root, notes_session.open(root <> "/session.db", clock.fixed(1000)).runtime)
}

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

// Raises a request the way `client/escalate` does and answers its seq.
fn raise(runtime: api.Runtime, id: String, wanted: List(policy.Grant)) -> Int {
  let denial =
    grants.encode_denial(
      reason: "tool requirements exceed the session policy",
      source: broker_escalation.PolicyDenial,
      wanted:,
    )
  let assert Ok(durable.Claimed(_)) =
    api.claim_escalation(
      runtime,
      id,
      denial,
      action: durable.Action(tool: "bash", digest: "digest", preview: "make"),
      scope: durable.CallScope(
        operation: an_op(3),
        strand: "main",
        step_id: "step",
        source_index: 0,
        call_id: "call-1",
      ),
      max_asks: 3,
    )
    as "the test's raise takes the claim"
  let assert Ok(cell) = api.escalation_cell(runtime, id)
    as "the record is readable"
  cell.seq
}

fn overview(
  runtime: api.Runtime,
  ceiling: option.Option(approval_ceiling.Ceiling),
) -> relayed_session.Overview {
  let assert Ok(found) = relayed_session.overview(runtime, ceiling)
    as "the overview reads"
  found
}

pub fn a_session_with_nothing_in_it_is_resting_with_nothing_asked_test() {
  let #(_root, runtime) = session("resting")
  let found = overview(runtime, None)
  assert found.doing == peer_mail.Resting
  assert found.pending == []
  assert found.children == []
  assert found.updated_at == None
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_pending_request_carries_its_seq_and_what_the_ceiling_admits_test() {
  let #(root, runtime) = session("pending")
  let inside = policy.GrantWritableRoot(root <> "/work/out")
  let outside = policy.GrantWritableRoot("/etc")
  let seq = raise(runtime, "policy-1", [inside, outside])
  let ceiling =
    Some(
      approval_ceiling.Ceiling(..approval_ceiling.nothing(), writable_roots: [
        root <> "/work",
      ]),
    )
  let found = overview(runtime, ceiling)
  assert found.doing == peer_mail.NeedsAnswer
  let assert [record] = found.pending
  assert record.escalation_id == "policy-1"
  assert record.status == "pending"
  assert record.seq == seq
  assert record.placement == None
  assert record.admitted == Some([inside])

  // With no ceiling the page may decide nothing, and no grant is admitted.
  let assert [bare] = overview(runtime, None).pending
  assert bare.admitted == Some([])
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_decided_request_is_no_longer_listed_test() {
  let #(root, runtime) = session("decided")
  let _seq = raise(runtime, "policy-1", [policy.GrantWritableRoot(root)])
  assert api.deny_escalation(runtime, "policy-1") == Ok(Nil)
  let found = overview(runtime, None)
  assert found.pending == []
  assert found.doing == peer_mail.Resting
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_message_starts_a_run_and_a_second_steers_it_test() {
  let #(_root, runtime) = session("send")
  let assert Ok(first) = relayed_session.send(runtime, "msg-1", "build it")
  let assert Ok(remote_mail.Started(..)) = remote_mail.decode_landing(first)
  let found = overview(runtime, None)
  assert found.doing == peer_mail.Running
  assert option.is_some(found.updated_at)

  // The strand has a run open, so the next message is a steer onto it.
  let assert Ok(second) = relayed_session.send(runtime, "msg-2", "and test it")
  let assert Ok(remote_mail.Steered(..)) = remote_mail.decode_landing(second)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_message_sent_again_is_answered_from_its_receipt_and_lands_once_test() {
  let #(_root, runtime) = session("receipt")
  let assert Ok(_) = relayed_session.send(runtime, "msg-1", "build it")
  let assert Ok(again) = relayed_session.send(runtime, "msg-1", "build it")
  assert remote_mail.decode_landing(again) == Ok(remote_mail.Admitted)

  // One message reached the strand: its history holds one user message.
  let assert Ok(page) = relayed_session.history_page(runtime, 0, 50)
  let assert Ok(decoded) = remote_transcript.decode(page)
  assert list.length(decoded.entries) == 1
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_id_reused_for_other_text_is_refused_and_delivers_nothing_test() {
  let #(_root, runtime) = session("reuse")
  let assert Ok(_) = relayed_session.send(runtime, "msg-1", "build it")
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.send(runtime, "msg-1", "something else")
  let assert Ok(page) = relayed_session.history_page(runtime, 0, 50)
  let assert Ok(decoded) = remote_transcript.decode(page)
  assert list.length(decoded.entries) == 1
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_message_outside_its_bounds_is_refused_before_anything_is_written_test() {
  let #(_root, runtime) = session("bounds")
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.send(runtime, "", "hello")
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.send(runtime, "msg-1", "")
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.send(runtime, string.repeat("i", 129), "hello")
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.send(runtime, "msg-1", string.repeat("t", 32_769))
  let assert Ok(page) = relayed_session.history_page(runtime, 0, 50)
  let assert Ok(decoded) = remote_transcript.decode(page)
  assert decoded.entries == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_transcript_page_is_the_main_strands_branch_and_is_bounded_test() {
  let #(_root, runtime) = session("history")
  let assert Ok(empty) = relayed_session.history_page(runtime, 0, 50)
  let assert Ok(none) = remote_transcript.decode(empty)
  assert none.child == "main"
  assert none.entries == []
  assert none.next == None
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.history_page(runtime, -1, 50)
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.history_page(runtime, 0, 0)
  let assert Error(remote_top.InvalidArgument(..)) =
    relayed_session.history_page(runtime, 0, remote_transcript.max_entries + 1)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_session_with_no_endpoint_answers_not_relayed_to_everything_test() {
  let endpoint = relayed_session.refusing()
  assert endpoint.overview(None) == Error(remote_top.NotRelayed)
  assert endpoint.send("id", "text") == Error(remote_top.NotRelayed)
  assert endpoint.history(0, 10) == Error(remote_top.NotRelayed)
  assert endpoint.stop() == Error(remote_top.NotRelayed)
}

pub fn an_endpoint_over_a_runtime_that_is_not_up_asks_to_try_again_test() {
  let endpoint =
    relayed_session.endpoint(
      fn() { Error(Nil) },
      fn() { Ok(Nil) },
      fn(_terms, _id, _decision, _seq, _decider) {
        Error(remote_top.NotRelayed)
      },
    )
  let assert Error(remote_top.NotYetOpen(..)) = endpoint.overview(None)
  let assert Error(remote_top.NotYetOpen(..)) = endpoint.send("id", "text")
  let assert Error(remote_top.NotYetOpen(..)) = endpoint.history(0, 10)

  // The two actions that belong to the hub are the closures it was given.
  assert endpoint.stop() == Ok(Nil)
}
