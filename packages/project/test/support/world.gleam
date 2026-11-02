//// Fixtures shared by the project engine's tests: a small configuration,
//// trigger builders for each row of the authority table, and helpers that
//// apply events and insist they are accepted.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/engine
import project/event.{type Effect, type Event}
import project/model.{
  type RuleMatch, type Trigger, ActorId, Addressed, ApprovalsNotGranted, Inputs,
  ProjectId, RuleId, RuleMatch, SourceId, ThreadId, Trigger, TriggerId,
  Unaddressed,
}
import project/state.{type State}

/// The source's own bot identity.
pub const bot = ActorId("loom-bot")

/// The rule used by the inferred fixtures.
pub const rule = RuleId("rule-a")

/// The source used by the fixtures.
pub const source = SourceId("github")

/// A small project: two general slots, a queue of three per source and an
/// attention limit of two.
pub fn config() -> state.Config {
  state.Config(
    project: ProjectId("p1"),
    workspace: "w",
    max_workers: 2,
    queue_limit: 3,
    attention_limit: 2,
    policy_version: "v1",
  )
}

/// A trigger with every input spelled out.
pub fn trigger(
  id: String,
  thread: String,
  actor: String,
  sender: model.Sender,
  addressing: model.Addressing,
  matched: option.Option(RuleMatch),
  generation: Int,
) -> Trigger {
  Trigger(
    id: TriggerId(id),
    source:,
    thread: ThreadId(thread),
    actor: ActorId(actor),
    inputs: Inputs(sender:, addressing:, rule: matched),
    generation:,
    at_ms: 1000,
  )
}

/// A rule match that grants no approvals.
pub fn matched() -> option.Option(RuleMatch) {
  Some(RuleMatch(rule, ApprovalsNotGranted))
}

/// The owner typing in the composer: explicit.
pub fn owner(id: String) -> Trigger {
  trigger(id, "th-" <> id, "me", model.Owner, Addressed, None, 0)
}

/// A listed person addressing the agent on a thread: explicit.
pub fn addressed(id: String, thread: String, actor: String) -> Trigger {
  trigger(id, thread, actor, model.Person, Addressed, None, 0)
}

/// A listed person speaking without addressing the agent: inferred, with a
/// matching rule.
pub fn overheard(id: String, thread: String) -> Trigger {
  trigger(id, thread, "pat", model.Person, Unaddressed, matched(), 0)
}

/// Someone nobody listed, with no rule: never admitted.
pub fn stranger(id: String, thread: String) -> Trigger {
  trigger(id, thread, "eve", model.Unlisted, Unaddressed, None, 0)
}

/// The arrival event for a trigger.
pub fn arrival(trigger: Trigger) -> Event {
  event.TriggerArrived(trigger, bot)
}

/// Accept a trigger as a ticket titled `t`.
pub fn accept(id: String) -> Event {
  event.Routed(model.Routing(
    trigger: TriggerId(id),
    kind: model.Accept(model.title("t")),
    holds: [],
    related: [],
    prior_hand_back: None,
  ))
}

/// Attach a trigger to a ticket.
pub fn attach(id: String, ticket: model.TicketId) -> Event {
  event.Routed(model.Routing(
    trigger: TriggerId(id),
    kind: model.Attach(ticket),
    holds: [],
    related: [],
    prior_hand_back: None,
  ))
}

/// Apply an event and insist the engine accepts it.
pub fn step(current: State, incoming: Event) -> #(State, List(Effect)) {
  case engine.apply(current, incoming) {
    Ok(result) -> result
    Error(refusal) -> panic as { "refused: " <> string.inspect(refusal) }
  }
}

/// Apply a list of events in order, keeping only the final state.
pub fn run(current: State, events: List(Event)) -> State {
  list.fold(events, current, fn(acc, incoming) { step(acc, incoming).0 })
}

/// A fresh state.
pub fn fresh() -> State {
  state.start(config())
}

/// What a replay verdict over thirty triggers covers, for fixtures that care
/// only that a verdict has some coverage.
pub const covers =
  model.Covers(
    lane: model.Replay,
    triggers: 30,
    trials: 1,
    changed: 0,
    bound_points: 20,
  )

/// The pin of a state that has had no router announced: the policy version
/// alone, with the prompt revision and model unset.
pub fn pin(version: String) -> model.Pin {
  model.Pin(policy_version: version, prompt_revision: "", model: "")
}

/// A verdict event measured under the policy version `version`.
pub fn verdict(
  pair_source: model.SourceId,
  pair_rule: model.RuleId,
  version: String,
  outcome: model.VerdictOutcome,
) -> Event {
  event.VerdictRecorded(pair_source, pair_rule, pin(version), outcome, covers)
}

/// A state in which the rule's pair is in `Auto` with a current verdict.
pub fn automated() -> State {
  run(fresh(), [
    verdict(source, rule, "v1", model.VerdictPassed),
    event.ModeSet(source, rule, model.Auto),
  ])
}

/// The ticket a trigger opens.
pub fn ticket_of(id: String) -> model.TicketId {
  model.ticket_for(TriggerId(id))
}

/// A ticket in the state, or a panic naming the missing id.
pub fn ticket(current: State, id: model.TicketId) -> state.Ticket {
  case state.ticket(current, id) {
    Ok(found) -> found
    Error(_) -> panic as "the test expected this ticket to exist"
  }
}
