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
import core/glance
import core/ids
import core/json
import gleam/int
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
    glance: None,
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
      agent.Released,
      agent.TokenBudgetSpent,
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

pub fn a_stub_is_kept_under_the_reserved_prefix_and_its_call_site_digest_test() {
  assert remote_child.stub_key("7b1c0a4e2d95f318")
    == "remote-child/7b1c0a4e2d95f318"
}

pub fn only_a_stub_whose_child_may_be_running_is_live_test() {
  let before = a_placed().deadline_ms - 1
  assert remote_child.is_live(a_stub(remote_child.Requested), before)
  assert remote_child.is_live(a_stub(remote_child.Spawned(a_placed())), before)
  assert !remote_child.is_live(
    a_stub(remote_child.Settled(a_placed(), agent.Completed, a_usage())),
    before,
  )
  assert !remote_child.is_live(a_stub(remote_child.Refused("no room")), before)
}

// The deadline is the bound on how long a child runs, so a stub frees its slot
// by the clock alone: at the deadline and after it, whatever was or was not
// heard from the other orchestrator. A stub whose spawn is still unanswered has
// no deadline and keeps counting.
pub fn a_spawned_stub_stops_being_live_at_its_childs_deadline_test() {
  let stub = a_stub(remote_child.Spawned(a_placed()))
  let deadline = a_placed().deadline_ms
  assert remote_child.is_live(stub, deadline - 1)
  assert !remote_child.is_live(stub, deadline)
  assert !remote_child.is_live(stub, deadline + 600_000)
  assert remote_child.is_live(
    a_stub(remote_child.Requested),
    deadline + 600_000,
  )
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

fn a_stub_on(
  orchestrator: String,
  state: remote_child.State,
) -> remote_child.Stub {
  Stub(..a_stub(state), orchestrator:)
}

fn kept(stubs: List(remote_child.Stub)) -> List(remote_child.Kept) {
  list.index_map(stubs, fn(stub, index) {
    remote_child.Kept(key: "remote-child/" <> int.to_string(index), stub:)
  })
}

pub fn the_orchestrators_owed_a_release_are_those_of_stubs_that_made_a_child_test() {
  let stubs =
    kept([
      a_stub_on("desk", remote_child.Refused("the cap is 4")),
      a_stub_on("box", remote_child.Requested),
      a_stub_on("box", remote_child.Spawned(a_placed())),
      a_stub_on(
        "zed",
        remote_child.Settled(a_placed(), agent.Completed, a_usage()),
      ),
    ])

  // A refused stub made no child, so `desk` holds nothing. A requested stub may
  // have made one whose reply was lost, and a settled stub's orchestrator still
  // holds the session the child ran in. Each name is listed once, in order.
  assert remote_child.holders(stubs) == ["box", "zed"]
  assert remote_child.holders([]) == []
}

pub fn a_stub_holds_a_move_only_while_its_child_may_be_running_test() {
  let deadline = a_placed().deadline_ms

  // A requested stub counts always, and a spawned one until its deadline.
  assert remote_child.live_on(
      kept([a_stub_on("box", remote_child.Requested)]),
      deadline + 1,
    )
    == Some("box")
  let spawned = kept([a_stub_on("box", remote_child.Spawned(a_placed()))])
  assert remote_child.live_on(spawned, deadline - 1) == Some("box")
  assert remote_child.live_on(spawned, deadline) == None

  // Neither a refused nor a settled stub does, and with several the first name
  // in order is reported.
  assert remote_child.live_on(
      kept([
        a_stub_on("box", remote_child.Refused("no")),
        a_stub_on(
          "box",
          remote_child.Settled(a_placed(), agent.Completed, a_usage()),
        ),
      ]),
      0,
    )
    == None
  assert remote_child.live_on(
      kept([
        a_stub_on("zed", remote_child.Requested),
        a_stub_on("box", remote_child.Requested),
      ]),
      0,
    )
    == Some("box")
}

pub fn a_cell_that_does_not_decode_is_left_out_of_the_stubs_test() {
  let good = remote_child.encode(a_stub(remote_child.Requested))
  assert remote_child.kept_of([
      #("remote-child/a", good),
      #("remote-child/b", json.String("garbage")),
    ])
    == [remote_child.Kept("remote-child/a", a_stub(remote_child.Requested))]
}

pub fn settled_usage_is_summed_per_orchestrator_in_name_order_test() {
  let settled = fn(orchestrator, input) {
    a_stub_on(
      orchestrator,
      remote_child.Settled(
        placed: a_placed(),
        outcome: agent.Completed,
        usage: remote_spawn.ChildUsage(
          input:,
          output: 10,
          cache_read: 1,
          cache_write: 2,
          cost: 0.25,
        ),
      ),
    )
  }
  let stubs =
    kept([
      settled("desk", 100),
      settled("box", 200),
      settled("box", 300),
      a_stub_on("box", remote_child.Spawned(placed: a_placed())),
      a_stub_on("box", remote_child.Requested),
      a_stub_on("box", remote_child.Refused(reason: "no")),
    ])

  // Only a settled child has reported usage. A running, a pending and a refused
  // one add nothing.
  assert remote_child.usage_by_orchestrator(stubs)
    == [
      #(
        "box",
        remote_spawn.ChildUsage(
          input: 500,
          output: 20,
          cache_read: 2,
          cache_write: 4,
          cost: 0.5,
        ),
      ),
      #(
        "desk",
        remote_spawn.ChildUsage(
          input: 100,
          output: 10,
          cache_read: 1,
          cache_write: 2,
          cost: 0.25,
        ),
      ),
    ]
  assert remote_child.settled_tokens(stubs) == 630
  assert remote_child.settled_tokens([]) == 0
}

pub fn a_glance_survives_the_stub_test() {
  let seen =
    glance.Glance(
      operation: ids.op_id_to_string(an_op(4)),
      title: "running the suite",
      summary: "waiting on e2e",
      at: 1_756_000_000_000,
      tokens: 4200,
    )
  round_trips(Stub(..a_stub(remote_child.Requested), glance: Some(seen)))
  round_trips(
    Stub(..a_stub(remote_child.Spawned(a_placed())), glance: Some(seen)),
  )
}

// A stub written before glances existed has no `glance` member and reads as one
// that has none.
pub fn a_stub_without_a_glance_member_decodes_as_having_none_test() {
  let assert json.Object(fields) =
    remote_child.encode(a_stub(remote_child.Requested))
  let older = json.Object(list.filter(fields, fn(pair) { pair.0 != "glance" }))
  let assert Ok(stub) = remote_child.decode(older)
  assert stub.glance == None
}

pub fn a_child_is_found_by_its_name_and_its_parent_strand_in_any_state_test() {
  let requested =
    remote_child.Kept("remote-child/a", a_stub(remote_child.Requested))
  let other =
    remote_child.Kept(
      "remote-child/b",
      Stub(..a_stub(remote_child.Requested), strand: "other"),
    )
  let name = requested.stub.name

  // The stub is found whatever state it is in, and by nothing but its name and
  // the parent strand: it has no handle yet.
  assert remote_child.find_named([other, requested], "main", name)
    == Ok(requested)
  assert remote_child.find_named([other, requested], "other", name) == Ok(other)
  assert remote_child.find_named([requested], "main", "sub:^main/nobody-1")
    == Error(Nil)
  assert remote_child.find_named([], "main", name) == Error(Nil)
}
