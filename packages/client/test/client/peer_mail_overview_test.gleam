//// The `Overview` endpoint command against a real runtime.
////
//// `sessions.activity` (`protocol-change/050`) is only as right as the row
//// each resident computes for itself, so these tests drive a real session
//// through the states the owner's picker distinguishes — idle, finished,
//// waiting on an approval, and running — and read the row back through
//// `peer_mail.handle`, the same call the Agency actor makes.

import client/gateway_test
import client/peer_mail
import core/clock
import core/glance
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/list
import gleam/option.{None}
import gleam/string
import runtime/api
import weft/poll

fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), seed))
  id
}

fn overview(runtime: api.Runtime) -> JsonValue {
  let assert Ok(row) =
    peer_mail.handle(runtime, clock.fixed(0), peer_mail.Overview)
    as "the resident answers its own overview"
  assert string.byte_size(json.to_string(row)) <= peer_mail.overview_row_bytes
  row
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the row is an object"
  let assert Ok(found) = list.key_find(fields, key) as "the row has the field"
  found
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

pub fn a_fresh_session_is_idle_with_no_last_run_test() {
  let runtime = gateway_test.reserved_fixture(session_id(501)).runtime
  let row = overview(runtime)
  assert field(row, "state") == json.String("idle")
  assert field(row, "working") == json.Int(0)
  assert field(row, "approvals") == json.Int(0)
  assert field(row, "last_outcome") == json.Null
  assert field(row, "last_message") == json.Null
  assert field(row, "model") == json.String("loom-1")
  assert field(row, "glances") == json.Array([])
}

pub fn a_finished_run_reports_its_outcome_and_final_text_test() {
  let runtime = gateway_test.reserved_fixture(session_id(502)).runtime
  let assert Ok(operation) = api.prompt(runtime, [user("summarize")])
    as "the prompt is accepted"
  let assert Ok(_) = api.await_result(runtime, operation, within_ms: 5000)
    as "the settling provider finishes the run"
  let row = overview(runtime)
  assert field(row, "state") == json.String("idle")
  assert field(row, "strands") == json.Int(1)
  assert field(row, "last_outcome") == json.String("completed")
  assert field(row, "last_message") == json.String("ok")
}

pub fn a_pending_approval_needs_the_operator_test() {
  let runtime = gateway_test.reserved_fixture(session_id(503)).runtime
  let assert Ok(Nil) = api.raise_escalation(runtime, "esc-1", json.Object([]))
    as "an escalation is raised"
  let row = overview(runtime)
  assert field(row, "state") == json.String("needs_you")
  assert field(row, "approvals") == json.Int(1)
}

pub fn a_running_strand_is_working_and_shows_only_its_current_glance_test() {
  let runtime = gateway_test.parked_reserved_fixture(session_id(504)).runtime
  let assert Ok(operation) = api.prompt(runtime, [user("audit")])
    as "the prompt is accepted"

  // The provider is parked, so the operation stays open on main. A glance
  // naming it is current; one naming another operation is left over from
  // finished work and must not be reported.
  let current =
    glance.Glance(ids.op_id_to_string(operation), "Audit", "Reading x", 5, 0)
  let stale = glance.Glance("op-gone", "Old", "Finished", 9, 0)
  let assert Ok(Nil) =
    api.put_reserved_fact(runtime, glance.key("main"), glance.encode(current))
    as "the current glance is written"
  let assert Ok(Nil) =
    api.put_reserved_fact(runtime, glance.key("sub:gone"), glance.encode(stale))
    as "the stale glance is written"
  let assert poll.Answered(row) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      let row = overview(runtime)
      case field(row, "state") {
        json.String("working") -> poll.Done(row)
        _ -> poll.Retry
      }
    })
    as "the open operation is observed"
  assert field(row, "working") == json.Int(1)
  assert field(row, "glances")
    == json.Array([
      json.Object([
        #("strand", json.String("main")),
        #("title", json.String("Audit")),
        #("summary", json.String("Reading x")),
      ]),
    ])
  api.abort(runtime)
}
