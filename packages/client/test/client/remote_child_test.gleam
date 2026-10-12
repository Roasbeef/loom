//// The parent's durable record of a child on another orchestrator, as data: the
//// keys it is kept under, the payload that survives a restart, and what a
//// payload that does not decode is called (protocol-change/084).
////
//// The records are read back out of the session store after a restart, by a
//// drainer that has only them to go on, so the property worth pinning is that
//// what is written is what is read, for every state and every optional part of
//// the request. The rules that move a record between states act on a live
//// session store, and `agency_test` covers them there.

import client/remote_child.{Placed, Stub}
import client/remote_spawn
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

fn a_request() -> remote_spawn.Request {
  remote_spawn.Request(
    purpose: "run the suite",
    brief: "Run make e2e.",
    model: None,
    tools: None,
    within_ms: None,
    result_schema: None,
    detach: remote_spawn.Attached,
  )
}

fn a_stub(state: remote_child.State) -> remote_child.Stub {
  Stub(
    orchestrator: "box",
    strand: "main",
    site: remote_spawn.CallSite(
      operation: an_op(3),
      step_id: "step-1",
      source_index: 2,
      minter: agent.ToolCall,
    ),
    depth: 0,
    parent_tools: ["agent_note", "agent_send", "bash"],
    request: a_request(),
    name: "sub:^main/run-the-suite-0123456789abcdef",
    state:,
  )
}

fn a_placed() -> remote_child.Placed {
  Placed(
    handle: agent.Handle(
      strand: "sub:^main/run-the-suite-0123456789abcdef",
      operation: an_op(4),
    ),
    tools: ["agent_note", "agent_send"],
    model: "cheap",
    model_id: "cheap-1",
    deadline_ms: 1_756_000_900_000,
  )
}

fn a_usage() -> remote_spawn.ChildUsage {
  remote_spawn.ChildUsage(
    input: 100,
    output: 20,
    cache_read: 5,
    cache_write: 7,
    cost: 0.5,
  )
}

fn round_trips(stub: remote_child.Stub) -> Nil {
  assert remote_child.decode(remote_child.encode(stub)) == Ok(stub)
}

pub fn a_stub_round_trips_in_every_state_test() {
  round_trips(a_stub(remote_child.Requested))
  round_trips(a_stub(remote_child.Spawned(a_placed())))
  round_trips(a_stub(remote_child.Refused("the cap `max_sessions` is 4")))
  list.each(
    [
      agent.Completed,
      agent.Failed(reason: "provider_error: overloaded"),
      agent.Aborted,
      agent.BudgetExpired,
      agent.ParentFinished,
    ],
    fn(outcome) {
      round_trips(a_stub(remote_child.Settled(a_placed(), outcome, a_usage())))
    },
  )
}

pub fn every_optional_part_of_the_request_survives_test() {
  let assert Ok(schema) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #("failed", json.Object([#("type", json.String("array"))])),
          ]),
        ),
        #("required", json.Array([json.String("failed")])),
      ]),
    )
  let full =
    remote_spawn.Request(
      purpose: "run the suite",
      brief: "Run make e2e.\nReport failures.",
      model: Some("cheap"),
      tools: Some(["bash", "fs_read"]),
      within_ms: Some(1_800_000),
      result_schema: Some(schema),
      detach: remote_spawn.Detached,
    )
  round_trips(Stub(..a_stub(remote_child.Requested), request: full))
}

// A code-mode program's spawn is minted under its ordinal, and the ordinal has to
// come back with the stub or the resend would derive another child's name.
pub fn a_programs_ordinal_survives_test() {
  let site =
    remote_spawn.CallSite(
      operation: an_op(9),
      step_id: "step-9",
      source_index: 0,
      minter: agent.Program(ordinal: 7),
    )
  round_trips(Stub(..a_stub(remote_child.Requested), site:))
}

pub fn keys_are_the_reserved_prefixes_and_what_names_the_record_test() {
  assert remote_child.stub_key("7b1c0a4e2d95f318")
    == "remote-child/7b1c0a4e2d95f318"
  let operation = an_op(5)
  assert remote_child.ended_key(operation, "box")
    == "remote-ended/" <> ids.op_id_to_string(operation) <> "/box"
}

pub fn only_a_stub_whose_child_may_be_running_is_live_test() {
  assert remote_child.is_live(a_stub(remote_child.Requested))
  assert remote_child.is_live(a_stub(remote_child.Spawned(a_placed())))
  assert !remote_child.is_live(
    a_stub(remote_child.Settled(a_placed(), agent.Completed, a_usage())),
  )
  assert !remote_child.is_live(a_stub(remote_child.Refused("no room")))
}

pub fn a_message_about_a_stub_names_this_session_and_the_parent_strand_test() {
  assert remote_child.parent_of(a_stub(remote_child.Requested), "sess-1")
    == remote_spawn.Parent(session: "sess-1", strand: "main")
}

pub fn a_payload_that_does_not_decode_is_an_error_not_a_crash_test() {
  let assert Error(_) = remote_child.decode(json.String("not a stub"))
  let assert Error(_) = remote_child.decode(json.Object([]))

  // A broken part is named: an unknown state is said to be one, and a number
  // that is text is refused.
  let encoded = remote_child.encode(a_stub(remote_child.Requested))
  let assert json.Object(fields) = encoded
  let assert Error(unknown) =
    remote_child.decode(
      json.Object([#("state", json.String("lost")), ..without(fields, "state")]),
    )
  assert unknown == "unknown remote child state `lost`"
  let assert Error(_) =
    remote_child.decode(
      json.Object([#("depth", json.String("0")), ..without(fields, "depth")]),
    )
}

fn without(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> List(#(String, json.JsonValue)) {
  list.filter(fields, fn(field) { field.0 != name })
}
