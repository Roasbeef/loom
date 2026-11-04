//// The project engine: `apply` an event to a state and get the next state
//// with the effects to perform, or a refusal; `replay` a log of events into a
//// state.
////
//// The engine is a pure value-to-value function. An actor elsewhere holds the
//// state, persists each accepted event to the ledger before acting, performs
//// the returned effects, and feeds their outcomes back as events. Nothing
//// here reads a clock, spawns a process or talks to a model, so the whole
//// state space can be explored by a property test without any of them.
////
//// The log is the state. A refusal leaves the state untouched, so a host
//// persists only events that were accepted, and replaying that list rebuilds
//// the state exactly. An event the engine would refuse on replay means the
//// ledger was written by something else, and `replay` says which one.
////
//// The transition logic lives in sibling modules, each owning one part of the
//// ticket's life: `project/intake` takes triggers in, `project/queue` holds
//// candidates for the router, `project/route` applies its decisions,
//// `project/schedule` hands out worker slots, and `project/work` runs a
//// ticket from assignment to conclusion. This module dispatches to them and
//// owns the project-level controls: modes, verdicts, the policy version and
//// the token ceiling.

import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import project/event.{type Event, type Refusal}
import project/gate
import project/intake
import project/model.{type Mode, Auto, CeilingClear, Observe}
import project/queue
import project/route
import project/schedule
import project/state.{type State, type Step, Verdict}
import project/work

/// Where a replay stopped.
pub type ReplayFailure {
  ReplayFailure(
    /// The zero-based position of the refused event.
    index: Int,
    /// Why the engine refused it.
    refusal: Refusal,
  )
}

/// Apply one event. On `Ok` the caller persists the event and performs the
/// effects; on `Error` it persists nothing and the state is as it was.
///
/// ## Examples
///
/// ```gleam
/// let current = state.start(config)
/// assert engine.apply(current, event.RouterTurnEnded) == Ok(#(current, []))
/// ```
pub fn apply(current: State, incoming: Event) -> Step {
  case incoming {
    event.TriggerArrived(trigger, bot) -> intake.arrive(current, trigger, bot)
    event.Routed(routing) -> route.route(current, routing)
    event.RoutedStop(trigger, ticket) -> route.stop(current, trigger, ticket)
    event.RoutedIgnore(trigger) -> route.ignore(current, trigger)
    event.RouterTurnEnded -> Ok(queue.turn_ended(current))
    event.Requeued(trigger, _) -> queue.requeue(current, trigger)
    event.ModeSet(source, rule, mode) -> set_mode(current, source, rule, mode)
    event.VerdictRecorded(source, rule, pin, outcome, covers) ->
      Ok(record_verdict(current, source, rule, Verdict(pin, outcome, covers)))
    event.PolicyVersionSet(version) -> Ok(set_policy_version(current, version))
    event.RouterPinSet(prompt_revision, router_model) ->
      Ok(set_router_pin(current, prompt_revision, router_model))
    event.Labelled(trigger, label, _) -> label_trigger(current, trigger, label)
    event.CeilingChanged(ceiling) -> Ok(set_ceiling(current, ceiling))

    // The events about a ticket's working life.
    event.SessionBound(ticket, seq, session) ->
      work.session_bound(current, ticket, seq, session)
    event.AssignmentLive(ticket, seq) ->
      work.assignment_live(current, ticket, seq)
    event.AssignmentEnded(ticket, seq, end) ->
      work.assignment_ended(current, ticket, seq, end)
    event.WorkerFailed(ticket, seq, why) ->
      work.worker_failed(current, ticket, seq, why)
    event.Reported(ticket, seq, report, head) ->
      work.reported(current, ticket, seq, report, head)
    event.HeadObserved(ticket, seq, head) ->
      work.head_observed(current, ticket, seq, head)
    event.ReviewRequested(ticket, commit, reason) ->
      work.review_requested(current, ticket, commit, reason)
    event.Answered(ticket, question, _) ->
      work.answered(current, ticket, question)
    event.InputFailed(ticket, trigger) ->
      work.input_failed(current, ticket, trigger)
    event.InputDelivered(ticket, trigger) ->
      work.input_delivered(current, ticket, trigger)
    event.CheckFinished(ticket, finished) ->
      work.check_finished(current, ticket, finished)
    event.PersonPublished(ticket, by, commit) ->
      work.person_published(current, ticket, by, commit)
    event.PersonStopped(ticket, by) -> work.person_stopped(current, ticket, by)
    event.PersonClosed(ticket, by) -> work.person_closed(current, ticket, by)
    event.RetryRequested(ticket, _) -> work.retry(current, ticket)
    event.PullRequestOpened(ticket, pull_request) ->
      work.pull_request_opened(current, ticket, pull_request)
    event.Concluded(ticket, outcome) -> work.concluded(current, ticket, outcome)
  }
}

/// Fold a list of events into a state. The effects are dropped: a replay
/// rebuilds what the engine knows, and the ledger already records what was
/// done about it.
///
/// ## Examples
///
/// ```gleam
/// assert engine.replay(config, []) == Ok(state.start(config))
/// ```
pub fn replay(
  config: state.Config,
  events: List(Event),
) -> Result(State, ReplayFailure) {
  events
  |> list.index_fold(Ok(state.start(config)), fn(acc, incoming, index) {
    use current <- result.try(acc)

    // The first refusal stops the fold and names its position, because a later
    // event cannot be judged against a state that never formed.
    case apply(current, incoming) {
      Ok(#(next, _)) -> Ok(next)
      Error(refusal) -> Error(ReplayFailure(index, refusal))
    }
  })
}

/// Set a mode. `Auto` needs a current passing verdict for the pair.
fn set_mode(
  current: State,
  source: model.SourceId,
  rule: model.RuleId,
  mode: Mode,
) -> Step {
  let verdict = state.verdict_of(current, source, rule)

  // Only `Auto` needs a current passing verdict, and the gate decides that.
  case gate.mode_allowed(mode, verdict) {
    Error(Nil) -> Error(event.VerdictRequired(source, rule))
    Ok(Nil) ->
      Ok(
        #(
          state.State(
            ..current,
            modes: dict.insert(current.modes, #(source, rule), mode),
          ),
          [],
        ),
      )
  }
}

/// Remember a pair's latest verdict and demote any pair it leaves without
/// one.
fn record_verdict(
  current: State,
  source: model.SourceId,
  rule: model.RuleId,
  verdict: state.Verdict,
) -> #(State, List(event.Effect)) {
  let recorded =
    state.State(
      ..current,
      verdicts: dict.insert(current.verdicts, #(source, rule), verdict),
    )
  #(demote_stale(recorded), [])
}

fn set_policy_version(
  current: State,
  version: String,
) -> #(State, List(event.Effect)) {
  #(demote_stale(state.State(..current, policy_version: version)), [])
}

/// Remember the router's prompt revision and model. Setting the values already
/// held changes nothing, so a host may announce them at every start. Setting
/// different ones makes every verdict measured under the old ones stale, and
/// the pairs that relied on them return to `Observe` in the same step, which
/// is what keeps the demotion in the ledger and not in a host's memory.
fn set_router_pin(
  current: State,
  prompt_revision: String,
  router_model: String,
) -> #(State, List(event.Effect)) {
  #(demote_stale(state.State(..current, prompt_revision:, router_model:)), [])
}

/// Record a person's label for a stored trigger. Only a trigger a rule matched
/// can be labelled, because the label counts toward that rule's verdict.
fn label_trigger(
  current: State,
  trigger: model.TriggerId,
  label: model.Label,
) -> Step {
  use stored <- result.try(
    state.record(current, trigger)
    |> result.replace_error(event.NotLabellable(trigger)),
  )

  // A trigger no rule matched belongs to no source and rule pair.
  case stored.trigger.inputs.rule {
    option.None -> Error(event.NotLabellable(trigger))
    option.Some(_) ->
      Ok(
        #(
          state.State(
            ..current,
            labels: dict.insert(current.labels, trigger, label),
          ),
          [],
        ),
      )
  }
}

/// A pair in `Auto` without a current passing verdict returns to `Observe`,
/// so a changed policy or a failing verdict takes automation away at once.
fn demote_stale(current: State) -> State {
  let modes =
    dict.map_values(current.modes, fn(pair, mode) {
      case mode, state.verdict_of(current, pair.0, pair.1) {
        Auto, gate.VerdictMissing -> Observe
        Auto, gate.VerdictCurrent -> Auto
        Observe, _ -> Observe
        model.Off, _ -> model.Off
      }
    })
  state.State(..current, modes:)
}

/// Reaching the ceiling stops inferred work; lifting it lets waiting work
/// start and queued candidates reach the router.
fn set_ceiling(
  current: State,
  ceiling: model.Ceiling,
) -> #(State, List(event.Effect)) {
  let changed = state.State(..current, ceiling:)

  // Reaching the ceiling changes nothing yet; lifting it lets waiting work
  // start and queued candidates reach the router.
  case ceiling {
    model.CeilingReached -> #(changed, [])
    CeilingClear -> {
      let #(scheduled, started) = schedule.run(changed)
      let #(offered, offers) = queue.offer(scheduled)
      #(offered, list.append(started, offers))
    }
  }
}
