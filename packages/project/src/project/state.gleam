//// The engine's state value and the questions every transition asks of it.
////
//// `State` is plain data. It is the fold of the event log, so two states built
//// from the same events are equal, and a host that persists events can drop
//// the state at any time and rebuild it. Nothing here transitions; the
//// modules `project/intake`, `project/route`, `project/work`,
//// `project/queue` and `project/schedule` do, each returning a new state and
//// the effects the actor performs.
////
//// The types come first, then `start`, then the pure queries: a ticket's
//// stage, the count of live assignments by slot, and a source and rule pair's
//// gate view. They live here because more than one transition module asks
//// them, and a question answered in two places is answered two ways.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import project/event.{type Effect, type Refusal}
import project/gate
import project/model.{
  type Ceiling, type CommandDigest, type CommitId, type Demand, type Heard,
  type Mandate, type Mode, type Outcome, type ProjectId, type PullRequestRef,
  type Question, type Report, type Routing, type RuleId, type SessionEnd,
  type SessionId, type SourceId, type Subscription, type Thread, type ThreadId,
  type TicketId, type TicketTitle, type Trigger, type TriggerId,
  type VerdictOutcome, CeilingClear,
}
import project/readiness.{type Readiness}
import project/stage

/// The project's fixed numbers. They never change within a replay, so they
/// are not events.
pub type Config {
  Config(
    /// The project's id, part of every session request key.
    project: ProjectId,
    /// The workspace tickets' worktrees are cut from.
    workspace: String,
    /// General worker slots. One more slot is reserved for a person.
    max_workers: Int,
    /// The most candidates a source may hold queued before inferred ones shed.
    queue_limit: Int,
    /// A source stops inferring while its tickets needing a person exceed this.
    attention_limit: Int,
    /// The policy version in force at the start.
    policy_version: String,
  )
}

/// What became of a trigger.
pub type Decision {
  /// It came from the project itself and was dropped.
  OwnMessage

  /// The gate did not admit it; it is on its thread and nowhere else.
  RecordedOnly

  /// A subscription carried it to a ticket.
  Delivered(
    /// The first subscribed ticket.
    ticket: TicketId,
  )

  /// The router accepted it, opening a ticket.
  Accepted(
    /// The new ticket.
    ticket: TicketId,
  )

  /// The router attached it to an open ticket.
  Attached(
    /// The ticket.
    ticket: TicketId,
  )

  /// The router resumed an ended ticket with it.
  Resumed(
    /// The ticket.
    ticket: TicketId,
  )

  /// The router stopped a ticket on it.
  StoppedTicket(
    /// The ticket.
    ticket: TicketId,
  )

  /// The router ignored it.
  Ignored

  /// Overload shed it. Only inferred triggers are ever shed.
  Shed

  /// `Observe` mode recorded that it would have been accepted.
  WouldAccept

  /// A hold kept it from the router.
  Held(
    /// Why.
    hold: Hold,
  )

  /// The router was offered it too many times and decided nothing. It waits
  /// on the board for a person, who can queue it again.
  Unrouted(
    /// Why it stopped being offered.
    reason: UnroutedReason,
  )
}

/// Why a candidate stopped being offered to the router.
pub type UnroutedReason {
  /// It went out in this many batches and came back each time with no
  /// decision. An explicit trigger can end here as well as an inferred one,
  /// and nothing drops it: it is a record a person sees.
  NoDecision(
    /// How many times it was offered.
    offers: Int,
  )
}

/// Why an admitted inferred trigger never reached the router.
pub type Hold {
  /// The gate would refuse to accept it.
  HeldByGate(
    /// The gate's reason.
    reason: gate.AcceptRefusal,
  )

  /// Its source has too many tickets waiting on a person.
  HeldByAttention

  /// The project's token ceiling is reached.
  HeldByCeiling
}

/// Where a stored trigger is in its life.
pub type Fate {
  /// Queued for the router.
  Awaiting

  /// Handed to the router in a batch and not yet routed.
  Offered

  /// Settled.
  Decided(
    /// How.
    decision: Decision,
  )
}

/// A trigger with the gate's verdict and its fate.
pub type TriggerRecord {
  TriggerRecord(
    /// The trigger.
    trigger: Trigger,
    /// The gate's verdict, fixed at arrival.
    admission: gate.Admission,
    /// Where it is now.
    fate: Fate,
  )
}

/// Which slot an assignment holds.
pub type SlotKind {
  /// One of `max_workers`.
  General

  /// The one slot kept for a person's message.
  Reserved
}

/// Where an assignment is in its life.
pub type AssignmentStatus {
  /// Requested; the session is not yet running.
  AssignmentPending

  /// The session is running.
  AssignmentRunning

  /// The session ended.
  AssignmentDone(
    /// How.
    end: SessionEnd,
  )
}

/// One binding of a ticket to a worker session. A ticket has several over
/// time.
pub type Assignment {
  Assignment(
    /// One-based sequence number within the ticket.
    seq: Int,
    /// The catalogue's session id, once the host has bound it.
    session: Option(SessionId),
    /// The slot it holds.
    slot: SlotKind,
    /// What wanted it.
    wanted: model.Wanted,
    /// Its status.
    status: AssignmentStatus,
  )
}

/// Whether a person has withdrawn a ticket's mandate.
pub type Authority {
  /// The mandate stands.
  Granted

  /// A person stopped the ticket. It never resumes.
  Withdrawn(
    /// Who stopped it: a principal's command or a person's message.
    by: Withdrawal,
  )
}

/// How a mandate was withdrawn.
pub type Withdrawal {
  /// A person's command through the host.
  ByCommand(
    /// The principal.
    by: model.PrincipalId,
  )

  /// A person's explicit message that the router acted on.
  ByMessage(
    /// The message.
    trigger: TriggerId,
  )
}

/// A unit of authorized work. Its state is its own and does not follow a
/// session.
pub type Ticket {
  Ticket(
    /// The ticket's id.
    id: TicketId,
    /// The capped title, shown on the board and never to a worker.
    title: TicketTitle,
    /// The trigger that opened it.
    origin: TriggerId,
    /// What it was authorized to do.
    mandate: Mandate,
    /// Whether the mandate stands.
    authority: Authority,
    /// Assignments, newest first.
    assignments: List(Assignment),
    /// Whether a session is wanted.
    demand: Demand,
    /// Triggers waiting for a session to receive them, oldest first.
    inbox: List(TriggerId),
    /// Inputs that failed to reach the worker.
    failed_inputs: List(TriggerId),
    /// The open question, if any.
    question: Question,
    /// The worker's latest report. A new assignment clears it, because the
    /// worker it described is gone and the new one has said nothing yet.
    latest: Option(Report),
    /// Why the host ended the latest assignment as failed, in the host's
    /// words, or `None`. It accompanies a `Failed` latest report that no
    /// worker made, and it clears with the report.
    failure: Option(String),
    /// Whether a person spoke since that report.
    heard: Heard,
    /// The commit the host last read from the worker's branch.
    head: Option(CommitId),
    /// The latest commit a check was requested or skipped for.
    last_checked: Option(CommitId),
    /// The latest failed check, if any.
    rejected: Option(#(CommitId, CommandDigest)),
    /// Where its work stands for a person.
    readiness: Readiness,
    /// Why the host would not go on by itself at the current head, if it
    /// said so. A new head clears it.
    review: Option(model.ReviewReason),
    /// The pull request, once the host opened it.
    pull_request: Option(PullRequestRef),
    /// How it ended, if it did.
    outcome: Option(Outcome),
    /// Routing decisions that touched it, newest first.
    routings: List(Routing),
  )
}

/// Whether the router has candidates in front of it.
pub type RouterPhase {
  /// No batch is out.
  RouterIdle

  /// A batch was offered and its turn has not ended.
  RouterBusy
}

/// A verdict as the state remembers it.
pub type Verdict {
  Verdict(
    /// The policy version it was measured under.
    version: String,
    /// What it found.
    outcome: VerdictOutcome,
  )
}

/// Everything the engine knows.
pub type State {
  State(
    /// The fixed numbers.
    config: Config,
    /// The policy version in force.
    policy_version: String,
    /// Every trigger seen, by id.
    triggers: Dict(TriggerId, TriggerRecord),
    /// Every thread seen, by id.
    threads: Dict(ThreadId, Thread),
    /// The many-to-many links between tickets and threads.
    subscriptions: List(Subscription),
    /// Every ticket, by id.
    tickets: Dict(TicketId, Ticket),
    /// Ticket ids, newest first.
    order: List(TicketId),
    /// Candidates awaiting the router, oldest first.
    queue: List(TriggerId),
    /// Candidates the router holds now.
    offered: List(TriggerId),
    /// How many batches each candidate has been in. The count is what bounds
    /// the router's second chances, see `queue.max_offers`.
    offers: Dict(TriggerId, Int),
    /// Whether a batch is out.
    router: RouterPhase,
    /// The mode of each source and rule pair; absent means `Off`.
    modes: Dict(#(SourceId, RuleId), Mode),
    /// The latest verdict of each pair.
    verdicts: Dict(#(SourceId, RuleId), Verdict),
    /// Whether the token ceiling is reached.
    ceiling: Ceiling,
  )
}

/// What a transition returns: the next state and the effects to perform, or a
/// refusal that leaves the state as it was.
pub type Step =
  Result(#(State, List(Effect)), Refusal)

/// The state before any event.
///
/// ## Examples
///
/// ```gleam
/// let config = state.Config(
///   project: model.ProjectId("p"),
///   workspace: "w",
///   max_workers: 2,
///   queue_limit: 4,
///   attention_limit: 3,
///   policy_version: "v1",
/// )
/// assert state.start(config).ceiling == model.CeilingClear
/// ```
pub fn start(config: Config) -> State {
  State(
    config:,
    policy_version: config.policy_version,
    triggers: dict.new(),
    threads: dict.new(),
    subscriptions: [],
    tickets: dict.new(),
    order: [],
    queue: [],
    offered: [],
    offers: dict.new(),
    router: RouterIdle,
    modes: dict.new(),
    verdicts: dict.new(),
    ceiling: CeilingClear,
  )
}

/// Look a ticket up or refuse with `UnknownTicket`.
///
/// ## Examples
///
/// ```gleam
/// assert state.ticket(state.start(config), model.TicketId("x")) |> result.is_error
/// ```
pub fn ticket(state: State, id: TicketId) -> Result(Ticket, Refusal) {
  case dict.get(state.tickets, id) {
    Ok(found) -> Ok(found)
    Error(Nil) -> Error(event.UnknownTicket(id))
  }
}

/// Look a stored trigger up or refuse with `UnknownTrigger`.
///
/// ## Examples
///
/// ```gleam
/// assert state.record(state.start(config), model.TriggerId("x")) |> result.is_error
/// ```
pub fn record(state: State, id: TriggerId) -> Result(TriggerRecord, Refusal) {
  case dict.get(state.triggers, id) {
    Ok(found) -> Ok(found)
    Error(Nil) -> Error(event.UnknownTrigger(id))
  }
}

/// Store a ticket, keeping the creation order.
///
/// ## Examples
///
/// ```gleam
/// // -> a state whose `tickets` holds the ticket
/// ```
pub fn put_ticket(state: State, ticket: Ticket) -> State {
  // A ticket already in the order keeps its place.
  let order = case dict.has_key(state.tickets, ticket.id) {
    True -> state.order
    False -> [ticket.id, ..state.order]
  }

  State(..state, tickets: dict.insert(state.tickets, ticket.id, ticket), order:)
}

/// Set a stored trigger's fate.
///
/// ## Examples
///
/// ```gleam
/// // -> the same state with the trigger's fate replaced
/// ```
pub fn set_fate(state: State, id: TriggerId, fate: Fate) -> State {
  case dict.get(state.triggers, id) {
    Ok(found) ->
      State(
        ..state,
        triggers: dict.insert(state.triggers, id, TriggerRecord(..found, fate:)),
      )
    Error(Nil) -> state
  }
}

/// The tickets in creation order, oldest first.
///
/// ## Examples
///
/// ```gleam
/// assert state.tickets_oldest_first(state.start(config)) == []
/// ```
pub fn tickets_oldest_first(state: State) -> List(Ticket) {
  state.order
  |> list.reverse
  |> list.filter_map(fn(id) { dict.get(state.tickets, id) })
}

/// The assignment currently holding a slot: pending or running.
///
/// ## Examples
///
/// ```gleam
/// // -> option.None for a ticket with no assignment
/// ```
pub fn active_assignment(ticket: Ticket) -> Option(Assignment) {
  case list.find(ticket.assignments, holds_slot) {
    Ok(found) -> Some(found)
    Error(Nil) -> None
  }
}

/// Whether an assignment holds a slot.
///
/// ## Examples
///
/// ```gleam
/// let a = state.Assignment(1, option.None, state.General, model.ByRouting, state.AssignmentPending)
/// assert state.holds_slot(a)
/// ```
pub fn holds_slot(assignment: Assignment) -> Bool {
  case assignment.status {
    AssignmentPending -> True
    AssignmentRunning -> True
    AssignmentDone(_) -> False
  }
}

/// How many assignments hold a slot of this kind across the project.
///
/// ## Examples
///
/// ```gleam
/// assert state.slots_used(state.start(config), state.General) == 0
/// ```
pub fn slots_used(state: State, kind: SlotKind) -> Int {
  state.tickets
  |> dict.values
  |> list.flat_map(fn(ticket) { ticket.assignments })
  |> list.count(fn(assignment) {
    holds_slot(assignment) && assignment.slot == kind
  })
}

/// The facts a stage is computed from.
///
/// ## Examples
///
/// ```gleam
/// // -> stage.Facts for the ticket
/// ```
pub fn facts(ticket: Ticket) -> stage.Facts {
  stage.Facts(
    outcome: ticket.outcome,
    delivery: delivery_fact(ticket),
    question: ticket.question,
    review: review_fact(ticket),
    latest: ticket.latest,
    heard: ticket.heard,
    assignment: assignment_fact(ticket),
    demand: ticket.demand,
  )
}

/// A ticket's stage.
///
/// ## Examples
///
/// ```gleam
/// // -> stage.Queued for a ticket never assigned
/// ```
pub fn stage_of(ticket: Ticket) -> stage.Stage {
  stage.of(facts(ticket))
}

fn delivery_fact(ticket: Ticket) -> stage.Delivery {
  case ticket.failed_inputs {
    [] -> stage.DeliveryClear
    [_, ..] -> stage.DeliveryFailed
  }
}

/// A pull request counts only when the ticket is ready or published, because
/// readiness is what lets the host open one. A ready or published ticket whose
/// pull request the host declined to open waits for a person all the same,
/// which is what `review` says.
fn review_fact(ticket: Ticket) -> stage.ReviewFact {
  case ticket.readiness, ticket.pull_request, ticket.review {
    readiness.AwaitingReview, _, _ -> stage.InReview
    readiness.Ready(_), Some(_), _ -> stage.PullRequestOpen
    readiness.Published(_, _), Some(_), _ -> stage.PullRequestOpen
    readiness.Ready(_), None, Some(_) -> stage.InReview
    readiness.Published(_, _), None, Some(_) -> stage.InReview
    readiness.Ready(_), None, None -> stage.NotInReview
    readiness.Published(_, _), None, None -> stage.NotInReview
    readiness.InProgress, _, _ -> stage.NotInReview
  }
}

/// The triggers that were offered without a decision and now wait for a
/// person, oldest first and then by id.
///
/// ## Examples
///
/// ```gleam
/// assert state.unrouted(state.start(config)) == []
/// ```
pub fn unrouted(state: State) -> List(TriggerRecord) {
  state.triggers
  |> dict.values
  |> list.filter(fn(stored) {
    case stored.fate {
      Decided(Unrouted(_)) -> True
      Decided(_) | Awaiting | Offered -> False
    }
  })
  |> list.sort(fn(a, b) {
    case int.compare(a.trigger.at_ms, b.trigger.at_ms) {
      order.Eq -> string.compare(a.trigger.id.value, b.trigger.id.value)
      other -> other
    }
  })
}

/// How many batches a trigger has been offered in.
///
/// ## Examples
///
/// ```gleam
/// assert state.offer_count(state.start(config), model.TriggerId("x")) == 0
/// ```
pub fn offer_count(state: State, id: TriggerId) -> Int {
  case dict.get(state.offers, id) {
    Ok(count) -> count
    Error(Nil) -> 0
  }
}

/// Say what the latest assignment is doing.
fn assignment_fact(ticket: Ticket) -> stage.AssignmentFact {
  case ticket.assignments {
    [] -> stage.NeverAssigned
    [latest, ..] ->
      case latest.status {
        AssignmentPending -> stage.LatestPending
        AssignmentRunning -> stage.LatestLive
        AssignmentDone(_) -> stage.LatestEnded
      }
  }
}

/// The gate's view of a source and rule pair.
///
/// A verdict is current when it passed under the policy version in force.
///
/// ## Examples
///
/// ```gleam
/// let pair = state.pair(state.start(config), model.SourceId("s"), option.None)
/// assert pair.mode == model.Off
/// ```
pub fn pair(state: State, source: SourceId, rule: Option(RuleId)) -> gate.Pair {
  case rule {
    None -> gate.Pair(None, model.Off, gate.VerdictMissing)
    Some(rule_id) ->
      gate.Pair(
        rule,
        mode_of(state, source, rule_id),
        verdict_of(state, source, rule_id),
      )
  }
}

/// The mode of a pair; `Off` when none was set.
///
/// ## Examples
///
/// ```gleam
/// assert state.mode_of(state.start(config), model.SourceId("s"), model.RuleId("r")) == model.Off
/// ```
pub fn mode_of(state: State, source: SourceId, rule: RuleId) -> Mode {
  case dict.get(state.modes, #(source, rule)) {
    Ok(mode) -> mode
    Error(Nil) -> model.Off
  }
}

/// Whether a pair's verdict is current.
///
/// ## Examples
///
/// ```gleam
/// assert state.verdict_of(state.start(config), model.SourceId("s"), model.RuleId("r")) == gate.VerdictMissing
/// ```
pub fn verdict_of(
  state: State,
  source: SourceId,
  rule: RuleId,
) -> gate.VerdictState {
  case dict.get(state.verdicts, #(source, rule)) {
    Ok(Verdict(version, model.VerdictPassed))
      if version == state.policy_version
    -> gate.VerdictCurrent
    Ok(_) -> gate.VerdictMissing
    Error(Nil) -> gate.VerdictMissing
  }
}

/// How many open tickets of a source wait on a person.
///
/// ## Examples
///
/// ```gleam
/// assert state.waiting_on_person(state.start(config), model.SourceId("s")) == 0
/// ```
pub fn waiting_on_person(state: State, source: SourceId) -> Int {
  state.tickets
  |> dict.values
  |> list.count(fn(ticket) {
    ticket.mandate.source == source && stage.needs_person(stage_of(ticket))
  })
}

/// The commit a ticket's current readiness vouches for.
///
/// ## Examples
///
/// ```gleam
/// // -> option.None for a ticket still in progress
/// ```
pub fn vouched_commit(ticket: Ticket) -> Option(CommitId) {
  readiness.vouches_for(ticket.readiness)
}
