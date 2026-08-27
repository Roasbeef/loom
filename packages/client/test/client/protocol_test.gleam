//// The escalation half of the v1 wire form: what an `approve` must say,
//// and what an `escalation` body carries about the action it is asking
//// about.
////
//// The golden corpus in `protocol_conformance_test` pins the canonical
//// bytes. This file pins the two rules that corpus cannot state — that
//// the echo fields on `approve` are required rather than defaulted, and
//// that the action fields on an `escalation` are additive and tolerated
//// by absence.

import broker/policy
import client/protocol
import core/json
import gleam/list
import gleam/option.{None, Some}

fn network_grant() -> policy.Grant {
  policy.GrantNetwork(network: policy.NetworkProxy(
    allow: ["registry.npmjs.org"],
    proxy: "127.0.0.1:3128",
  ))
}

fn record(
  tool: String,
  action: String,
  preview: String,
  asked: Int,
) -> protocol.EscalationRecord {
  protocol.EscalationRecord(
    escalation_id: "esc-1",
    op: "op-1",
    strand: "main",
    status: "pending",
    tool:,
    action:,
    preview:,
    asked:,
    denial: None,
  )
}

fn escalation_fields(
  record: protocol.EscalationRecord,
) -> List(#(String, json.JsonValue)) {
  let encoded =
    protocol.encode_event(protocol.EventEnvelope(
      reply_to: None,
      seq: Some(11),
      event: protocol.EscalationEvent(record:),
    ))
  let assert Ok(protocol.EventEnvelope(
    event: protocol.EscalationEvent(record: decoded),
    ..,
  )) = protocol.decode_event(encoded)
    as "an escalation event must round-trip"
  assert decoded == record
  let assert Ok(json.Object(envelope)) = json.parse(encoded)
  let assert Ok(json.Object(body)) = list.key_find(envelope, "body")
  body
}

// --- approve: the echo is required -----------------------------------------

/// `grants` used to be optional, and absent meant "everything this
/// record wants, resolved when the commit runs". That is the widening a
/// human never saw (#72), so its absence is now a refused frame rather
/// than a default — and a refused frame is what makes the change fail
/// an old client loudly instead of quietly approving something else.
pub fn approve_without_grants_is_refused_test() {
  let assert Error(protocol.BadBody(id: 6, cmd: "approve", reason:)) =
    protocol.decode_command(
      "{\"v\":1,\"id\":6,\"cmd\":\"approve\","
      <> "\"body\":{\"escalation_id\":\"esc-1\",\"action\":\"d-1\"}}",
    )
    as "an approve with no grants must not decode"
  assert reason == "grants is required"
}

/// The action echo is required for the same reason: a client that
/// cannot say which action it rendered has not carried consent for one.
pub fn approve_without_an_action_is_refused_test() {
  let assert Error(protocol.BadBody(id: 6, cmd: "approve", reason:)) =
    protocol.decode_command(
      "{\"v\":1,\"id\":6,\"cmd\":\"approve\","
      <> "\"body\":{\"escalation_id\":\"esc-1\",\"grants\":[]}}",
    )
    as "an approve with no action must not decode"
  assert reason == "action is required"
}

/// An empty action is a statement, not an absence: it is what a client
/// echoes for a record that names no action.
pub fn approve_may_echo_an_empty_action_test() {
  let assert Ok(protocol.CommandEnvelope(
    id: 6,
    command: protocol.Approve(escalation_id: "esc-1", grants: [], action: ""),
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":6,\"cmd\":\"approve\","
      <> "\"body\":{\"escalation_id\":\"esc-1\",\"grants\":[],\"action\":\"\"}}",
    )
}

pub fn approve_round_trips_its_echo_test() {
  let command =
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [network_grant()],
      action: "9f2c1a7b4e0d63859ac41d2f7b6e8035",
    )
  let encoded =
    protocol.encode_command(protocol.CommandEnvelope(id: 6, command:))
  assert protocol.decode_command(encoded)
    == Ok(protocol.CommandEnvelope(id: 6, command:))
}

// --- the escalation body: additive, and tolerated by absence ---------------

pub fn an_escalation_carries_the_action_fields_test() {
  let body =
    escalation_fields(record(
      "bash",
      "9f2c1a7b4e0d63859ac41d2f7b6e8035",
      "{\"command\":\"npm install left-pad\"}",
      2,
    ))
  assert list.key_find(body, "tool") == Ok(json.String("bash"))
  assert list.key_find(body, "action")
    == Ok(json.String("9f2c1a7b4e0d63859ac41d2f7b6e8035"))
  assert list.key_find(body, "preview")
    == Ok(json.String("{\"command\":\"npm install left-pad\"}"))
  assert list.key_find(body, "asked") == Ok(json.Int(2))
}

/// A record that names no action encodes as one written before the
/// fields existed — nothing said is nothing emitted — which is what
/// keeps the addition invisible to a reader that does not know it.
pub fn a_record_with_no_action_emits_no_action_fields_test() {
  let body = escalation_fields(record("", "", "", 0))
  assert list.key_find(body, "tool") == Error(Nil)
  assert list.key_find(body, "action") == Error(Nil)
  assert list.key_find(body, "preview") == Error(Nil)
  assert list.key_find(body, "asked") == Error(Nil)
}

/// And a body written before the fields existed decodes as one that
/// names no action, rather than as a malformed body.
pub fn a_body_without_the_action_fields_decodes_test() {
  let assert Ok(protocol.EventEnvelope(
    event: protocol.EscalationEvent(record: decoded),
    ..,
  )) =
    protocol.decode_event(
      "{\"v\":1,\"event\":\"escalation\",\"seq\":11,\"body\":{"
      <> "\"escalation_id\":\"esc-1\",\"op\":\"op-1\",\"strand\":\"main\","
      <> "\"status\":\"pending\"}}",
    )
    as "a legacy escalation body must still decode"
  assert decoded == record("", "", "", 0)
}

/// Tolerance of absence is not tolerance of nonsense: a field that is
/// present and the wrong type is still a malformed body, the
/// distinction every optional field in this module draws.
pub fn a_non_string_preview_is_malformed_test() {
  let assert Error(_fault) =
    protocol.decode_event(
      "{\"v\":1,\"event\":\"escalation\",\"seq\":11,\"body\":{"
      <> "\"escalation_id\":\"esc-1\",\"op\":\"op-1\",\"strand\":\"main\","
      <> "\"status\":\"pending\",\"preview\":42}}",
    )
    as "a numeric preview must not decode as absent"
}

// --- the refusal that hands the record back --------------------------------

/// The `stale_approval` details carry the record under an `escalation`
/// key, in the same shape the event body has, so a client re-renders
/// its prompt from the answer to its own command.
pub fn stale_approval_details_carry_the_record_test() {
  let fresh = record("bash", "d-600", "{\"timeout_ms\":600000}", 2)
  let assert json.Object(fields) = protocol.stale_approval_details(fresh)
  let assert Ok(json.Object(body)) = list.key_find(fields, "escalation")
  assert list.key_find(body, "escalation_id") == Ok(json.String("esc-1"))
  assert list.key_find(body, "action") == Ok(json.String("d-600"))
  assert list.key_find(body, "strand") == Ok(json.String("main"))
}
