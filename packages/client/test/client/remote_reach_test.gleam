//// What a session with nowhere to start a child reaches, and the parent a
//// message names (protocol-change/084).
////
//// The production reach connects to a pinned peer and asks its port, so its
//// behaviour belongs to the shipped two-orchestrator test. What is pinned here is
//// the reach every other host gets, because `agent_spawn` offers `on` from its
//// names and the Agency refuses from its answers.

import client/peer_mail
import client/remote_reach
import client/remote_spawn
import core/clock
import core/ids
import gleam/option.{None}
import tools/agent

fn an_op() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  op
}

pub fn a_session_with_no_orchestrators_offers_none_test() {
  let reach = remote_reach.none("sess-1")
  assert reach.session == "sess-1"
  assert reach.orchestrators == []
  assert !reach.offered()
}

pub fn every_question_of_such_a_reach_is_a_definitive_refusal_test() {
  let reach = remote_reach.none("sess-1")
  let parent = remote_reach.parent(reach, "main")
  let refused = peer_mail.Refused("`box` is not a configured orchestrator")
  let site =
    remote_spawn.CallSite(
      operation: an_op(),
      step_id: "step-1",
      source_index: 0,
      minter: agent.ToolCall,
    )
  let request =
    remote_spawn.Request(
      purpose: "x",
      brief: "y",
      model: None,
      tools: None,
      within_ms: None,
      result_schema: None,
      detach: remote_spawn.Attached,
    )
  assert reach.spawn("box", parent, site, 0, [], request) == Error(refused)
  assert reach.join("box", parent, [], 25_000) == Error(refused)
  assert reach.run_ended("box", parent, an_op()) == Error(refused)
  assert remote_reach.not_configured("box") == refused
}

pub fn a_message_names_the_session_and_a_strand_of_it_test() {
  let reach = remote_reach.none("sess-1")
  assert remote_reach.parent(reach, "main")
    == remote_spawn.Parent(session: "sess-1", strand: "main")
}
