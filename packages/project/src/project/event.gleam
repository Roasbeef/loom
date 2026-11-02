//// What goes into the engine, what comes out, and why it can refuse.
////
//// An `Event` is a fact the host observed or a command a person issued. The
//// ledger stores events and nothing else, and replaying them rebuilds the
//// engine's state exactly, so every field an event needs is in the event:
//// the source's bot identity rides on `TriggerArrived`, the diff's
//// protected-path verdict rides on `Reported`, and times are values the
//// caller passes in. An `Effect` is a request the actor performs; the engine
//// never performs one. A `Refusal` leaves the state untouched.

import project/gate
import project/host.{type CheckPassed}
import project/model.{
  type ActorId, type Ceiling, type CommandDigest, type CommitId, type Head,
  type Mandate, type Mode, type Outcome, type PrincipalId, type PullRequestRef,
  type Report, type ReviewReason, type Routing, type RuleId, type SessionEnd,
  type SessionId, type SourceId, type TicketId, type Trigger, type TriggerId,
  type VerdictOutcome,
}

/// The result of the host's check command.
pub type CheckResult {
  /// The check passed. The proof can only be built by the host's event path.
  CheckOk(
    /// The proof.
    proof: CheckPassed,
  )

  /// The check ran and failed.
  CheckRejected(
    /// The commit it ran against.
    commit: CommitId,
    /// The digest of the command.
    digest: CommandDigest,
  )
}

/// A fact or a command.
pub type Event {
  /// A source delivered a trigger. `bot` is the source's own identity, so
  /// the engine can drop the project's own messages.
  TriggerArrived(
    /// The trigger.
    trigger: Trigger,
    /// The source's bot identity.
    bot: ActorId,
  )

  /// The router routed a candidate with `accept`, `attach` or `resume`.
  Routed(
    /// The decision.
    routing: Routing,
  )

  /// The router stopped a ticket on a person's explicit message.
  RoutedStop(
    /// The person's message.
    trigger: TriggerId,
    /// The ticket to stop.
    ticket: TicketId,
  )

  /// The router ignored a candidate.
  RoutedIgnore(
    /// The ignored candidate.
    trigger: TriggerId,
  )

  /// The router's turn ended. Candidates it left unrouted go back to the queue.
  RouterTurnEnded

  /// A person queued a stored trigger for a fresh evaluation.
  Requeued(
    /// The stored trigger.
    trigger: TriggerId,
    /// Who asked.
    by: PrincipalId,
  )

  /// A person set the mode of one source and rule.
  ModeSet(
    /// The source.
    source: SourceId,
    /// The rule.
    rule: RuleId,
    /// The new mode.
    mode: Mode,
  )

  /// The evaluation instrument produced a verdict for one source and rule.
  VerdictRecorded(
    /// The source.
    source: SourceId,
    /// The rule.
    rule: RuleId,
    /// The policy version the verdict was measured under.
    version: String,
    /// What it found.
    outcome: VerdictOutcome,
  )

  /// The policy version changed. Pairs whose verdict is no longer current
  /// return to `Observe`.
  PolicyVersionSet(
    /// The new version.
    version: String,
  )

  /// The project's token ceiling was reached or lifted.
  CeilingChanged(
    /// The new state.
    ceiling: Ceiling,
  )

  /// The host created or recovered the session for an assignment.
  SessionBound(
    /// The ticket.
    ticket: TicketId,
    /// The assignment's sequence number.
    seq: Int,
    /// The catalogue's session id.
    session: SessionId,
  )

  /// The assignment's session is running.
  AssignmentLive(
    /// The ticket.
    ticket: TicketId,
    /// The assignment's sequence number.
    seq: Int,
  )

  /// The assignment's session ended.
  AssignmentEnded(
    /// The ticket.
    ticket: TicketId,
    /// The assignment's sequence number.
    seq: Int,
    /// How it ended.
    end: SessionEnd,
  )

  /// The host gave up on an assignment's worker before it reported anything:
  /// the session would not start after the host's attempts, or it was lost.
  /// The reason is the host's own sentence about the failure.
  WorkerFailed(
    /// The ticket.
    ticket: TicketId,
    /// The assignment's sequence number.
    seq: Int,
    /// What failed, in the host's words.
    why: String,
  )

  /// A worker reported. `head` is the commit the host read from its branch when the
  /// host had one to hand; a report committed from the worker's own call
  /// carries `NoHead`, and the host reads the branch afterwards when the
  /// engine asks (`ObserveHead`).
  Reported(
    /// The ticket.
    ticket: TicketId,
    /// The reporting assignment.
    seq: Int,
    /// The worker's closed-set status.
    report: Report,
    /// The commit the host read from the branch.
    head: Head,
  )

  /// The host read the head of an idle worker's branch, because the engine
  /// asked for it. The head carries the host's verdict on the protected
  /// paths, so a worker cannot say that its diff is clean.
  HeadObserved(
    /// The ticket.
    ticket: TicketId,
    /// The assignment whose worktree was read.
    seq: Int,
    /// The commit the host read from the branch.
    head: Head,
  )

  /// The host will not run the check or open a pull request on its own, and
  /// says why, so a person decides. It names the commit it was about, and it
  /// is stale once the head has moved.
  ReviewRequested(
    /// The ticket.
    ticket: TicketId,
    /// The head the host was working on.
    commit: CommitId,
    /// Why a person must look.
    reason: ReviewReason,
  )

  /// A person answered a question, echoing its sequence number.
  Answered(
    /// The ticket.
    ticket: TicketId,
    /// The question's sequence number.
    question: Int,
    /// Who answered.
    by: PrincipalId,
  )

  /// An input did not reach the worker.
  InputFailed(
    /// The ticket.
    ticket: TicketId,
    /// The input.
    trigger: TriggerId,
  )

  /// An input reached the worker after an earlier failure.
  InputDelivered(
    /// The ticket.
    ticket: TicketId,
    /// The input.
    trigger: TriggerId,
  )

  /// The host's check finished.
  CheckFinished(
    /// The ticket.
    ticket: TicketId,
    /// The result.
    result: CheckResult,
  )

  /// A person published past a failing check.
  PersonPublished(
    /// The ticket.
    ticket: TicketId,
    /// Who published.
    by: PrincipalId,
    /// The commit they published.
    commit: CommitId,
  )

  /// A person stopped a ticket. The ticket never resumes.
  PersonStopped(
    /// The ticket.
    ticket: TicketId,
    /// Who stopped it.
    by: PrincipalId,
  )

  /// A person accepted a ticket's work and closed it. Unlike a stop, the
  /// mandate stands, so the ticket can be resumed.
  PersonClosed(
    /// The ticket.
    ticket: TicketId,
    /// Who closed it.
    by: PrincipalId,
  )

  /// A person asked for a new assignment on a stalled ticket.
  RetryRequested(
    /// The ticket.
    ticket: TicketId,
    /// Who asked.
    by: PrincipalId,
  )

  /// The host opened the ticket's pull request.
  PullRequestOpened(
    /// The ticket.
    ticket: TicketId,
    /// The pull request.
    pull_request: PullRequestRef,
  )

  /// The ticket ended.
  Concluded(
    /// The ticket.
    ticket: TicketId,
    /// How it ended.
    outcome: Outcome,
  )
}

/// A request the actor performs. The engine only returns these.
pub type Effect {
  /// Create or recover the session under `key` and start it on the ticket.
  StartSession(
    /// The ticket.
    ticket: TicketId,
    /// The assignment's sequence number.
    seq: Int,
    /// The idempotency key, see `model.request_key`.
    key: String,
    /// The mandate the worker's policy derives from.
    mandate: Mandate,
  )

  /// Hand a stored trigger, or a person's answer (`model.answer_id`), to the
  /// worker of assignment `seq`. The worker
  /// reads the original text through its reference.
  Deliver(
    /// The ticket.
    ticket: TicketId,
    /// The assignment that receives it.
    seq: Int,
    /// The trigger.
    trigger: TriggerId,
  )

  /// Show the router up to twenty candidates, explicit ones first.
  OfferCandidates(
    /// The candidates in order.
    triggers: List(TriggerId),
  )

  /// Run the project's check at a commit.
  RequestCheck(
    /// The ticket.
    ticket: TicketId,
    /// The commit to check.
    commit: CommitId,
  )

  /// Read the head of the idle worker's branch and report it as
  /// `HeadObserved`. The engine asks because only the host can read a
  /// worktree and decide which paths are protected.
  ObserveHead(
    /// The ticket.
    ticket: TicketId,
    /// The assignment whose worktree to read.
    seq: Int,
  )

  /// Push the ticket's branch to the remote and open its pull request, when
  /// the project's `publish` setting allows it.
  PublishBranch(
    /// The ticket.
    ticket: TicketId,
    /// The remote branch, see `model.branch_name`.
    branch: String,
    /// The commit to publish.
    commit: CommitId,
  )

  /// End the live sessions of a stopped or concluded ticket.
  StopSession(
    /// The ticket.
    ticket: TicketId,
    /// The assignment whose session to stop.
    seq: Int,
  )
}

/// Why the engine did not apply an event. The state is unchanged.
pub type Refusal {
  /// The event names a ticket the state does not hold.
  UnknownTicket(ticket: TicketId)

  /// The event names a trigger the state does not hold.
  UnknownTrigger(trigger: TriggerId)

  /// The assignment does not exist or is not in the state the event needs.
  UnknownAssignment(ticket: TicketId, seq: Int)

  /// The router answered a trigger it was not offered.
  NotOffered(trigger: TriggerId)

  /// The trigger was not admitted by the gate.
  TriggerNotAdmitted(trigger: TriggerId)

  /// The gate refuses to accept the inferred trigger.
  AcceptRefused(reason: gate.AcceptRefusal)

  /// The trigger is not a person's explicit message, so it cannot stop work.
  NotAPersonsMessage(trigger: TriggerId)

  /// A person withdrew the mandate, and the ticket never resumes.
  TicketWithdrawn(ticket: TicketId)

  /// The ticket has ended and cannot take this event.
  TicketEnded(ticket: TicketId)

  /// The ticket is still open, so there is nothing to resume.
  TicketNotEnded(ticket: TicketId)

  /// The assignment or check is out of date.
  Stale(ticket: TicketId)

  /// The ticket has an active assignment already.
  AssignmentActive(ticket: TicketId)

  /// The ticket is already in line for a session.
  AlreadyWanted(ticket: TicketId)

  /// The event's state change is not allowed from the ticket's readiness.
  NotPublishable(ticket: TicketId)

  /// `Auto` was set for a pair with no current passing verdict.
  VerdictRequired(source: SourceId, rule: RuleId)

  /// The stored trigger cannot be requeued in its present state.
  NotRequeueable(trigger: TriggerId)

  /// The answer does not echo the open question.
  StaleAnswer(ticket: TicketId)

  /// A conclusion must be `Merged`, `Closed` or `Abandoned`; a person's stop
  /// is its own command.
  NotAConclusion(ticket: TicketId)
}
