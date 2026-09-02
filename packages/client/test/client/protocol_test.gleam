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
import core/message
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

pub fn prompt_content_round_trips_ordered_blocks_test() {
  let command =
    protocol.PromptContent(strand: "main", content: [
      message.UserText("look here", None),
      message.UserImage("iVBORw0KGgo=", "image/png"),
    ])
  let encoded =
    protocol.encode_command(protocol.CommandEnvelope(id: 18, command:))
  assert protocol.decode_command(encoded)
    == Ok(protocol.CommandEnvelope(id: 18, command:))
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

// --- the schedule commands and the listing they answer with ----------------

fn schedule_rows() -> List(protocol.ScheduleInfo) {
  [
    protocol.ScheduleInfo(
      name: "nightly",
      target: "main",
      owner: "operator",
      when: "every 3600s, at most 24 times",
      wake: protocol.WakesIdle,
      fired: 7,
      body: "summarize what changed today",
    ),
    protocol.ScheduleInfo(
      name: "heartbeat",
      target: "sub:main/reviewer-abc123",
      owner: "main",
      when: "every 300s, at most 20 times",
      wake: protocol.SteersOnly,
      fired: 2,
      body: "report where the review has got to",
    ),
  ]
}

pub fn schedules_command_round_trips_test() {
  let encoded =
    protocol.encode_command(protocol.CommandEnvelope(
      id: 19,
      command: protocol.ListSchedules,
    ))
  assert encoded == "{\"v\":1,\"id\":19,\"cmd\":\"schedules\",\"body\":{}}"
  assert protocol.decode_command(encoded)
    == Ok(protocol.CommandEnvelope(id: 19, command: protocol.ListSchedules))
}

pub fn schedule_cancel_round_trips_its_pair_test() {
  let command =
    protocol.CancelSchedule(
      target: "sub:main/reviewer-abc123",
      name: "heartbeat",
    )
  let encoded =
    protocol.encode_command(protocol.CommandEnvelope(id: 20, command:))
  assert protocol.decode_command(encoded)
    == Ok(protocol.CommandEnvelope(id: 20, command:))
}

/// Both halves of the pair are required, because `{target, name}` *is*
/// a schedule's durable identity: a cancel that guessed a missing
/// target would delete a different session's clock under the same name.
pub fn schedule_cancel_needs_both_halves_of_the_pair_test() {
  let assert Error(protocol.BadBody(id: 21, cmd: "schedule_cancel", reason:)) =
    protocol.decode_command(
      "{\"v\":1,\"id\":21,\"cmd\":\"schedule_cancel\","
      <> "\"body\":{\"target\":\"main\"}}",
    )
    as "a cancel with no name must not decode"
  assert reason == "name is required"

  let assert Error(protocol.BadBody(
    id: 22,
    cmd: "schedule_cancel",
    reason: "target is required",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":22,\"cmd\":\"schedule_cancel\","
      <> "\"body\":{\"name\":\"heartbeat\"}}",
    )
    as "a cancel with no target must not decode"
}

/// Forward compatibility within v1 on the commands too: a client that
/// learns a new optional field must not break this build.
pub fn the_schedule_commands_ignore_unknown_fields_test() {
  let assert Ok(protocol.CommandEnvelope(
    id: 23,
    command: protocol.ListSchedules,
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":23,\"cmd\":\"schedules\","
      <> "\"body\":{\"only_wakers\":true}}",
    )
  let assert Ok(protocol.CommandEnvelope(
    id: 24,
    command: protocol.CancelSchedule(target: "main", name: "poll"),
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":24,\"cmd\":\"schedule_cancel\",\"body\":{"
      <> "\"target\":\"main\",\"name\":\"poll\",\"because\":\"tidying\"}}",
    )
}

pub fn a_schedules_snapshot_round_trips_every_row_test() {
  let event =
    protocol.SnapshotEvent(
      protocol.SchedulesSnapshot(schedules: schedule_rows()),
    )
  let encoded =
    protocol.encode_event(protocol.EventEnvelope(
      reply_to: Some(19),
      seq: None,
      event:,
    ))
  assert protocol.decode_event(encoded)
    == Ok(protocol.EventEnvelope(reply_to: Some(19), seq: None, event:))
}

/// The wake question is a boolean on the wire and a two-variant type in
/// the harness, so the mapping is worth pinning in both directions: a
/// polarity flip here would tell an operator a waking heartbeat merely
/// steers.
pub fn the_wake_flag_is_the_wires_only_boolean_test() {
  let encoded =
    protocol.encode_event(protocol.EventEnvelope(
      reply_to: Some(19),
      seq: None,
      event: protocol.SnapshotEvent(
        protocol.SchedulesSnapshot(schedules: schedule_rows()),
      ),
    ))
  let assert Ok(json.Object(envelope)) = json.parse(encoded)
  let assert Ok(json.Object(body)) = list.key_find(envelope, "body")
  let assert Ok(json.Array([json.Object(first), json.Object(second)])) =
    list.key_find(body, "schedules")
  assert list.key_find(first, "wake") == Ok(json.Bool(True))
  assert list.key_find(second, "wake") == Ok(json.Bool(False))

  // And a `wake` of the wrong type is a refused body rather than a
  // silently defaulted one.
  let assert Error(protocol.BadEnvelope(reason:, id: None)) =
    protocol.decode_event(
      "{\"v\":1,\"event\":\"snapshot\",\"body\":{\"mode\":\"schedules\","
      <> "\"schedules\":[{\"name\":\"n\",\"target\":\"main\",\"owner\":\"main\","
      <> "\"when\":\"once\",\"wake\":\"yes\",\"fired\":0,\"body\":\"b\"}]}}",
    )
    as "a non-boolean wake must not decode"
  assert reason == "snapshot body: wake must be a boolean"
}
