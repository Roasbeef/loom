//// The pure half of taking a subagent message to the Agency
//// (protocol-change/084): judging a request against the spawner's terms,
//// clamping the parent's tools to its ceiling, and rendering the Agency's
//// refusals as the ones the sender reads.

import client/remote_spawn.{
  Attached, CapReached, Detached, InvalidArgument, Request, Terms,
}
import gleam/option.{None, Some}
import tools/agent

fn terms() -> remote_spawn.Terms {
  Terms(
    ceiling: ["agent_note", "agent_send", "bash", "fs_read"],
    max_depth: 1,
    max_within_ms: 60_000,
    default_within_ms: 10_000,
  )
}

fn request() -> remote_spawn.Request {
  Request(
    purpose: "run the suite",
    brief: "Run make e2e.",
    model: None,
    tools: None,
    within_ms: None,
    result_schema: None,
    detach: Attached,
  )
}

pub fn a_request_that_names_no_deadline_gets_the_default_test() {
  let assert Ok(asked) = remote_spawn.agent_request(request(), terms())
  assert asked.within_ms == Some(10_000)
  assert asked.purpose == "run the suite"
  assert asked.brief == "Run make e2e."
  assert asked.detach == False
  assert asked.context == agent.Fresh
}

pub fn a_deadline_is_kept_up_to_the_cap_and_refused_beyond_it_test() {
  let at = fn(within_ms) {
    remote_spawn.agent_request(
      Request(..request(), within_ms: Some(within_ms)),
      terms(),
    )
  }
  let assert Ok(exact) = at(60_000)
  assert exact.within_ms == Some(60_000)
  let assert Ok(least) = at(1)
  assert least.within_ms == Some(1)

  // Refused and not clamped: a sender that believed a child could run longer
  // than it can would wait on nothing.
  let assert Error(InvalidArgument(reason: over)) = at(60_001)
  assert over == "within_ms is above this spawner's max_within_s"
  assert at(0) == Error(InvalidArgument(reason: "within_ms must be positive"))
  assert at(-1) == Error(InvalidArgument(reason: "within_ms must be positive"))
}

pub fn a_tool_outside_the_ceiling_is_named_in_the_refusal_test() {
  let asked =
    remote_spawn.agent_request(
      Request(..request(), tools: Some(["bash", "peer_send", "schedule_at"])),
      terms(),
    )
  assert asked == Error(remote_spawn.ToolOutsideCeiling(tool: "peer_send"))

  // Names inside the ceiling pass through untouched, in the order given.
  let assert Ok(inside) =
    remote_spawn.agent_request(
      Request(..request(), tools: Some(["fs_read", "bash"])),
      terms(),
    )
  assert inside.tools == Some(["fs_read", "bash"])
}

pub fn detach_and_the_model_and_the_schema_cross_unchanged_test() {
  let assert Ok(asked) =
    remote_spawn.agent_request(
      Request(..request(), model: Some("fast"), detach: Detached),
      terms(),
    )
  assert asked.detach == True
  assert asked.model == Some("fast")
  assert asked.result_schema == None
}

pub fn the_parents_tools_are_clamped_to_the_ceiling_in_the_parents_order_test() {
  assert remote_spawn.clamp_tools(
      ["peer_send", "bash", "agent_spawn", "agent_note", "fs_read"],
      terms(),
    )
    == ["bash", "agent_note", "fs_read"]
  assert remote_spawn.clamp_tools([], terms()) == []
  assert remote_spawn.clamp_tools(["peer_send"], terms()) == []
}

pub fn an_agency_refusal_becomes_the_refusal_the_sender_reads_test() {
  let render = fn(refusal) { remote_spawn.refusal_of(refusal, 8, 16) }
  assert render(agent.DepthCapReached(depth: 1))
    == CapReached(cap: remote_spawn.MaxDepth, limit: 1)
  assert render(agent.ParentRunEnded(strand: "^main"))
    == remote_spawn.ParentRunEnded
  assert render(agent.NameAlreadyMinted(strand: "sub:^main/x"))
    == remote_spawn.NameAlreadyMinted
  assert render(agent.InvalidArgument(reason: "no"))
    == InvalidArgument(reason: "no")
  assert render(agent.PlaneFailed(reason: "disk"))
    == remote_spawn.StoreFailure(reason: "disk")
  assert render(agent.AgencyUnavailable)
    == remote_spawn.StoreFailure(
      reason: "the delegate session's Agency is not running",
    )
  assert render(agent.UnknownTool(name: "bash"))
    == InvalidArgument(reason: "the parent does not hold the tool bash")
  assert render(agent.NotADescendant(strand: "sub:main/x"))
    == InvalidArgument(reason: "sub:main/x is not a child of this parent")
}

pub fn the_one_cap_refusal_is_named_by_the_limit_it_hit_test() {
  let render = fn(cap) {
    remote_spawn.refusal_of(
      agent.FanOutCapReached(live: cap, cap:),
      fan_out: 8,
      session_strands: 16,
    )
  }
  assert render(8) == CapReached(cap: remote_spawn.FanOut, limit: 8)
  assert render(16) == CapReached(cap: remote_spawn.SessionStrands, limit: 16)

  // When the two limits are equal the refusal is the parent's own, since that
  // check runs first.
  assert remote_spawn.refusal_of(
      agent.FanOutCapReached(live: 4, cap: 4),
      fan_out: 4,
      session_strands: 4,
    )
    == CapReached(cap: remote_spawn.FanOut, limit: 4)
}

pub fn a_join_is_capped_below_the_agent_wait_ceiling_test() {
  assert remote_spawn.join_cap_ms == 25_000
}

// The sentence names the rule that stopped the spawn, and for a cap the key that
// sets it, so the parent's model can change the request or do the work itself.
pub fn every_refusal_reads_as_a_sentence_naming_its_rule_test() {
  let sentence = remote_spawn.describe_refusal
  assert sentence(CapReached(cap: remote_spawn.MaxSessions, limit: 4))
    == "the cap `max_sessions` is 4 and was reached"
  assert sentence(CapReached(cap: remote_spawn.MaxDepth, limit: 1))
    == "the cap `max_depth` is 1 and was reached"
  assert sentence(CapReached(cap: remote_spawn.SessionStrands, limit: 16))
    == "the cap `session_strands` is 16 and was reached"
  assert sentence(remote_spawn.UnknownSpawner(node: "laptop@100.64.0.5"))
    == "it has no spawner configured for this machine (`laptop@100.64.0.5`)"
  assert sentence(remote_spawn.ParentRunEnded)
    == "the run that asked for this child has already ended"
  assert sentence(remote_spawn.ToolOutsideCeiling(tool: "peer_send"))
    == "the tool `peer_send` is outside what it lets a child hold"
  assert sentence(InvalidArgument(reason: "within_ms must be positive"))
    == "within_ms must be positive"
  assert sentence(remote_spawn.NameAlreadyMinted)
    == "a different call already started a child under that name"
  assert sentence(remote_spawn.StoreFailure(reason: "disk full"))
    == "its store failed: disk full"
}
