//// The snapshot document's version, which is what keeps a build that does not
//// know the catalogue agent from loading a state that carries one.

import client/project_retention.{Original, WithAgents}
import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import project/gate
import project/model
import project/state

fn config() -> state.Config {
  state.Config(
    project: model.ProjectId("p1"),
    workspace: "/w",
    max_workers: 1,
    queue_limit: 1,
    attention_limit: 1,
    policy_version: "v1",
  )
}

/// A state holding one offered trigger, with or without a chosen agent.
fn holding(agent: option.Option(String)) -> state.State {
  let id = model.TriggerId("c1")
  let trigger =
    model.Trigger(
      id:,
      source: model.SourceId("github"),
      thread: model.ThreadId("t1"),
      actor: model.ActorId("a1"),
      inputs: model.Inputs(model.Owner, model.Addressed, None),
      generation: 0,
      at_ms: 1,
    )
  let record =
    state.TriggerRecord(
      trigger:,
      admission: gate.Admitted(
        model.Explicit,
        model.FromComposer,
        model.ApprovalsNotGranted,
      ),
      fate: state.Offered,
      judgement: None,
      agent:,
    )
  state.State(
    ..state.start(config()),
    triggers: dict.from_list([#(id, record)]),
  )
}

fn document(layout: project_retention.Layout) -> project_retention.Document {
  project_retention.Document(layout, "{}", [], [], [])
}

pub fn a_state_with_no_agent_keeps_the_original_layout_test() {
  assert project_retention.layout_of(holding(None)) == Original
  assert string.starts_with(
    project_retention.encode(document(Original)),
    "{\"v\":1,",
  )
}

pub fn a_state_that_carries_an_agent_is_written_as_version_two_test() {
  assert project_retention.layout_of(holding(Some("small fixes"))) == WithAgents
  let text = project_retention.encode(document(WithAgents))
  assert string.starts_with(text, "{\"v\":2,")
  assert project_retention.decode(text) == Ok(document(WithAgents))
}

pub fn a_version_this_build_does_not_know_is_refused_test() {
  let text = project_retention.encode(document(WithAgents))
  let future = string.replace(text, "{\"v\":2,", "{\"v\":3,")
  assert future != text
  let assert Error(_) = project_retention.decode(future)
  Nil
}
