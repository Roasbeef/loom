//// The composed decider of a verdict over Jev, trial by trial, with a fake
//// fetch and a scripted router. Nothing reaches the network.

import client/codex/network
import client/jev as transport
import client/project_jev_judge.{Setting, Setup}
import client/project_judge.{type Judge, Decision, Failure, Judge, Limits, Spend}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/gate
import project/jev_verdict
import project/judge
import project/model
import project/state
import project/tape

// An inferred trigger with no ticket listed is asked three things.
fn body(asks: String) -> String {
  "{\"model\":\"jev-1.14.0\",\"answers\":{\"asks_for_work\":{\"type\":\"noul\",\"noul\":"
  <> asks
  <> "},\"clear_alone\":{\"type\":\"noul\",\"noul\":0.95},\"decline_reason\":{\"type\":\"choice\",\"choice\":\"nothing_to_do\",\"confidence\":0.8,\"probabilities\":{\"nothing_to_do\":0.9,\"off_topic\":0.1}}},\"usage\":{\"input_tokens\":100,\"output_tokens\":5}}"
}

fn frame() -> tape.Frame {
  tape.Frame(
    trigger: model.Trigger(
      id: model.TriggerId("t1"),
      source: model.SourceId("github"),
      thread: model.ThreadId("th"),
      actor: model.ActorId("alice"),
      inputs: model.Inputs(
        sender: model.Unlisted,
        addressing: model.Unaddressed,
        rule: None,
      ),
      generation: 0,
      at_ms: 1,
    ),
    text: "please bump the dependency",
    relation: gate.UnrelatedThread,
    thread: [],
    recorded: tape.Declined,
  )
}

fn engine() -> state.State {
  state.start(state.Config(
    project: model.ProjectId("p1"),
    workspace: "/w",
    max_workers: 1,
    queue_limit: 1,
    attention_limit: 1,
    policy_version: "v1",
  ))
}

// A router that answers `choice` at a cost of 7 tokens, or fails at that cost.
fn router(answer: Result(judge.Choice, String)) -> Judge {
  Judge(
    decide: fn(_, _, _) {
      case answer {
        Ok(choice) ->
          Ok(Decision(
            choice:,
            routing: project_judge.Routed,
            spend: Spend(calls: 1, tokens: 7),
            trial: None,
          ))
        Error(words) -> Error(Failure(words, Spend(calls: 1, tokens: 7)))
      }
    },
    limits: Limits(concurrency: 1, wall_ms: 1000),
  )
}

fn composed(
  fetch: transport.Fetch,
  answer: Result(judge.Choice, String),
) -> Judge {
  project_jev_judge.judge(
    Setup(
      setting: Setting(
        client: transport.client_with(Some("k"), 3000, fetch),
        model: "jev-latest",
        percent: 80,
        agents: [],
      ),
      router: router(answer),
      recording: project_jev_judge.Records,
    ),
    engine(),
  )
}

fn custody(_, _) {
  Ok(Nil)
}

pub fn a_trial_jev_settles_is_jevs_choice_and_costs_one_call_test() {
  // Jev says the message asks for work, so it is taken even though the router
  // would have passed.
  let fetch = fn(_, _, _) { Ok(network.Response(200, body("0.9"))) }
  let assert Ok(decision) =
    composed(fetch, Ok(judge.Pass)).decide(frame(), 0, custody)
  assert decision.choice == judge.Take
  assert decision.spend == Spend(calls: 1, tokens: 105)
  let assert Some(trial) = decision.trial
  assert trial.model == Some("jev-1.14.0")
  assert case trial.outcome {
    jev_verdict.Decided(_) -> True
    _ -> False
  }
}

pub fn a_trial_jev_declines_is_a_pass_test() {
  let fetch = fn(_, _, _) { Ok(network.Response(200, body("0.1"))) }
  let assert Ok(decision) =
    composed(fetch, Ok(judge.Take)).decide(frame(), 0, custody)
  assert decision.choice == judge.Pass
}

pub fn a_trial_jev_abstains_on_goes_to_the_router_with_both_spends_test() {
  let fetch = fn(_, _, _) { Ok(network.Response(200, body("0.5"))) }
  let assert Ok(decision) =
    composed(fetch, Ok(judge.Take)).decide(frame(), 0, custody)
  assert decision.choice == judge.Take
  assert decision.spend == Spend(calls: 2, tokens: 112)
  let assert Some(trial) = decision.trial
  assert case trial.outcome {
    jev_verdict.Abstained(_) -> True
    _ -> False
  }
}

pub fn a_failed_service_goes_to_the_router_and_is_not_the_runs_failure_test() {
  let fetch = fn(_, _, _) { Error("request_transport_failed") }
  let assert Ok(decision) =
    composed(fetch, Ok(judge.Pass)).decide(frame(), 1, custody)
  assert decision.choice == judge.Pass
  assert decision.spend == Spend(calls: 1, tokens: 7)
  let assert Some(trial) = decision.trial
  assert case trial.outcome {
    jev_verdict.Failed(_) -> True
    _ -> False
  }
  assert trial.answers == None
}

pub fn a_router_failure_after_a_jev_answer_keeps_jevs_spend_test() {
  let fetch = fn(_, _, _) { Ok(network.Response(200, body("0.5"))) }
  let assert Error(failure) =
    composed(fetch, Error("the router failed")).decide(frame(), 0, custody)
  assert string.contains(failure.words, "the router failed")
  assert failure.spend == Spend(calls: 2, tokens: 112)
  assert list.length([failure]) == 1
}
