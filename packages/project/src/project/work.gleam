//// A ticket's working life: opening, delivery, assignments, reports,
//// checks, publication, withdrawal and conclusion.
////
//// Everything in a ticket that a worker or the host can change goes through
//// this module, and every function returns a `Step`: a new state with the
//// effects to perform, or a refusal that leaves the state alone.
////
//// Three rules are enforced here and nowhere else. A person's stop withdraws
//// the mandate, ends the ticket as `StoppedByPerson` and cancels its
//// waiting demand, and every other transition refuses a withdrawn or ended
//// ticket, so such a ticket never resumes. A check is requested only when a
//// worker reports `Waiting` with no open question and a head that differs
//// from the last checked commit, and a diff touching protected paths goes to
//// review with no check. And `Ready` is reachable only through
//// `readiness.check_passed`, which takes the host's `CheckPassed`.
////
//// ## Flow
////
//// `open` → `deliver_to` → `assignment_live` → `reported` → `head_observed` →
//// `check_finished` → `rest` → `retry` → `withdraw`
////
//// 1. `open` builds a ticket from an admitted trigger, and `deliver_to` hands
////    it that trigger and later ones.
//// 2. `assignment_live` and `reported` follow the worker. An idle report with
////    a head runs the check rule at once; one without a head waits for
////    `head_observed`.
//// 3. `check_finished` takes the host's verdict. Whenever a transition leaves
////    the ticket's work waiting for a person and its worker idle, `rest` ends
////    the assignment so the slot is free while the session stays.
//// 4. `retry` gives a ticket with no worker a new one, and `withdraw` ends the
////    ticket for good.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import project/event.{
  type CheckResult, type Effect, type Refusal, CheckOk, CheckRejected,
  ObserveHead, PublishBranch, RequestCheck, StopSession,
}
import project/gate.{Admitted, NotAdmitted}
import project/host
import project/model.{
  type CommitId, type Head, type PrincipalId, type PullRequestRef, type Report,
  type SessionEnd, type SessionId, type TicketId, type TicketTitle,
  type TriggerId, Abandoned, Asking, Blocked, ByPerson, ByRouting, Dropped,
  Explicit, Failed, Head, Mandate, NoHead, NoQuestion, PersonHeard, Progress,
  Satisfied, Scope, Silent, StoppedByPerson, Subscription, Waiting, Wanting,
}
import project/readiness
import project/schedule
import project/state.{
  type Assignment, type State, type Step, type Ticket, Assignment,
  AssignmentDone, AssignmentPending, AssignmentRunning, ByCommand, ByMessage,
  Granted, Withdrawn,
}

// --- opening and delivery ----------------------------------------------------

/// Open a ticket for an admitted trigger and subscribe it to the trigger's
/// thread. The mandate is built here from the stored admission, which is why a
/// routing event cannot choose a strength.
///
/// ## Examples
///
/// ```gleam
/// // -> a state holding the ticket `model.ticket_for(trigger.id)`
/// ```
pub fn open(
  current: State,
  stored: state.TriggerRecord,
  title: TicketTitle,
  routing: model.Routing,
) -> State {
  // A trigger the gate did not admit never opens a ticket.
  case stored.admission {
    NotAdmitted(_) -> current
    Admitted(strength, basis, approvals) -> {
      let trigger = stored.trigger
      let id = model.ticket_for(trigger.id)
      let mandate =
        Mandate(
          strength:,
          basis:,
          actor: trigger.actor,
          source: trigger.source,
          scope: Scope(current.config.workspace, approvals),
          policy_version: current.policy_version,
        )

      // An explicit request is a person's demand; an inferred one is the
      // router's.
      let by = case strength {
        Explicit -> ByPerson
        model.Inferred -> ByRouting
      }

      let ticket =
        state.Ticket(
          id:,
          title:,
          origin: trigger.id,
          mandate:,
          authority: Granted,
          assignments: [],
          demand: Wanting(by),
          inbox: [trigger.id],
          failed_inputs: [],
          question: NoQuestion,
          latest: None,
          failure: None,
          heard: Silent,
          head: None,
          last_checked: None,
          rejected: None,
          failed_heads: 0,
          readiness: readiness.InProgress,
          review: None,
          pull_request: None,
          outcome: None,
          routings: [routing],
        )
      subscribe(state.put_ticket(current, ticket), id, trigger.thread)
    }
  }
}

/// Link a ticket to a thread, once.
///
/// ## Examples
///
/// ```gleam
/// // -> the same state when the link already exists
/// ```
pub fn subscribe(
  current: State,
  ticket: TicketId,
  thread: model.ThreadId,
) -> State {
  let link = Subscription(ticket, thread)

  // A link is stored once.
  case list.contains(current.subscriptions, link) {
    True -> current
    False ->
      state.State(..current, subscriptions: [link, ..current.subscriptions])
  }
}

/// Hand an admitted trigger to a ticket. With a session pending or running the
/// worker receives it at once; otherwise it waits in the ticket's inbox and
/// the ticket wants a session, on a person's demand when the trigger is a
/// person's explicit message. The caller schedules afterwards.
///
/// ## Examples
///
/// ```gleam
/// // -> #(state, [Deliver(ticket, seq, trigger)]) for a ticket with a session
/// ```
pub fn deliver_to(
  current: State,
  id: TicketId,
  trigger: TriggerId,
) -> #(State, List(Effect)) {
  // A trigger the state cannot find counts as inferred, which never records a
  // person's voice.
  let strength = case state.record(current, trigger) {
    Ok(stored) -> admitted_strength(stored)
    Error(_) -> model.Inferred
  }

  // An unknown ticket receives nothing.
  case state.ticket(current, id) {
    Error(_) -> #(current, [])
    Ok(ticket) -> {
      // Only a person's explicit message counts as hearing from a person.
      let heard = case strength {
        Explicit -> PersonHeard
        model.Inferred -> ticket.heard
      }

      // With a pending or running session the worker receives the input at
      // once; otherwise it waits in the inbox.
      case state.active_assignment(ticket) {
        Some(assignment) -> #(
          state.put_ticket(current, state.Ticket(..ticket, heard:)),
          [event.Deliver(id, assignment.seq, trigger)],
        )
        None -> #(
          state.put_ticket(
            current,
            state.Ticket(
              ..ticket,
              heard:,
              inbox: list.append(ticket.inbox, [trigger]),
              demand: raise_demand(ticket.demand, strength),
            ),
          ),
          [],
        )
      }
    }
  }
}

fn admitted_strength(stored: state.TriggerRecord) -> model.Strength {
  case stored.admission {
    Admitted(strength, _, _) -> strength
    NotAdmitted(_) -> model.Inferred
  }
}

/// A person's demand is never lowered by a routing demand that arrives later.
fn raise_demand(
  demand: model.Demand,
  strength: model.Strength,
) -> model.Demand {
  case demand, strength {
    Wanting(ByPerson), _ -> Wanting(ByPerson)
    _, Explicit -> Wanting(ByPerson)
    Satisfied, model.Inferred -> Wanting(ByRouting)
    Wanting(ByRouting), model.Inferred -> Wanting(ByRouting)
  }
}

// --- withdrawal and conclusion -----------------------------------------------

/// Withdraw a ticket's mandate on a person's say. The ticket ends as
/// `StoppedByPerson`, loses its waiting demand and inbox, and its live
/// sessions are stopped. A second stop changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // -> Ok(#(state, [])) when the ticket was already withdrawn
/// ```
pub fn withdraw(current: State, id: TicketId, by: state.Withdrawal) -> Step {
  use ticket <- result.try(state.ticket(current, id))

  // A second stop changes nothing.
  case ticket.authority {
    Withdrawn(_) -> Ok(#(current, []))
    Granted -> {
      let stopped =
        state.Ticket(
          ..ticket,
          assignments: list.map(ticket.assignments, released),
          authority: Withdrawn(by),
          outcome: Some(StoppedByPerson),
          demand: Satisfied,
          inbox: [],
        )

      // The stopped sessions' slots are free from this event on, so a ticket
      // waiting for one is assigned now and not at some later event.
      Ok(schedule_after(
        state.put_ticket(current, stopped),
        stop_sessions(ticket),
      ))
    }
  }
}

/// An assignment as the end of its ticket leaves it. The end is the only thing
/// that stops the session of a ticket the person withdrew or that concluded,
/// and nothing else reports that session's exit, so without this the
/// assignment stayed pending or running for good and kept holding its slot. A rested
/// assignment holds no slot but names a session that is stopped now and a clone
/// that is released, so it is marked exited as well: only a rested assignment
/// of an open ticket may be taken over by the next one.
fn released(assignment: Assignment) -> Assignment {
  case assignment.status {
    AssignmentPending
    | AssignmentRunning
    | AssignmentDone(model.SessionRested) ->
      Assignment(..assignment, status: AssignmentDone(model.SessionExited))
    AssignmentDone(model.SessionExited)
    | AssignmentDone(model.SessionCrashed) -> assignment
  }
}

/// The stops an ended ticket owes. Only the newest assignment can have a live
/// session, a pending start or a rested one with a clone still in place, so
/// that is the only one to stop. An assignment that exited or crashed has
/// already been stopped.
fn stop_sessions(ticket: Ticket) -> List(Effect) {
  case ticket.assignments {
    [] -> []
    [newest, ..] ->
      case newest.status {
        AssignmentPending
        | AssignmentRunning
        | AssignmentDone(model.SessionRested) -> [
          StopSession(ticket.id, newest.seq),
        ]
        AssignmentDone(model.SessionExited)
        | AssignmentDone(model.SessionCrashed) -> []
      }
  }
}

/// A person accepted the ticket's work and closed it. The ticket ends as
/// `Closed`, its sessions are stopped and its slots are freed, and the mandate
/// stands, so a later message on its thread that the router resumes it with
/// reopens it. That is the whole difference from a stop, which withdraws the
/// mandate for good.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(TicketEnded(id)) for a ticket that already ended
/// ```
pub fn person_closed(current: State, id: TicketId, _by: PrincipalId) -> Step {
  use ticket <- result.map(open_ticket(current, id))
  end_ticket(current, ticket, model.Closed)
}

/// A person's stop command.
///
/// ## Examples
///
/// ```gleam
/// // -> the ticket ends as stopped and never resumes
/// ```
pub fn person_stopped(current: State, id: TicketId, by: PrincipalId) -> Step {
  withdraw(current, id, ByCommand(by))
}

/// A person's stop by message, as the router relayed it.
///
/// ## Examples
///
/// ```gleam
/// // -> the ticket ends as stopped and never resumes
/// ```
pub fn message_stopped(
  current: State,
  id: TicketId,
  trigger: TriggerId,
) -> Step {
  withdraw(current, id, ByMessage(trigger))
}

/// The ticket ended: its pull request merged or closed, or the worker let it
/// go.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotAConclusion(id)) for StoppedByPerson
/// ```
pub fn concluded(current: State, id: TicketId, outcome: model.Outcome) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // A person's stop has its own command; only a merge, a close or abandonment
  // concludes a ticket.
  case outcome {
    StoppedByPerson -> Error(event.NotAConclusion(id))
    model.Merged -> Ok(end_ticket(current, ticket, outcome))
    model.Closed -> Ok(end_ticket(current, ticket, outcome))
    Abandoned -> Ok(end_ticket(current, ticket, outcome))
  }
}

/// Record how a ticket ended, stop its sessions and let the freed slots be
/// used.
fn end_ticket(
  current: State,
  ticket: Ticket,
  outcome: model.Outcome,
) -> #(State, List(Effect)) {
  let ended =
    state.Ticket(
      ..ticket,
      assignments: list.map(ticket.assignments, released),
      outcome: Some(outcome),
      demand: Satisfied,
      inbox: [],
    )
  schedule_after(state.put_ticket(current, ended), stop_sessions(ticket))
}

/// A ticket that is neither withdrawn nor ended, or the refusal saying which.
fn open_ticket(current: State, id: TicketId) -> Result(Ticket, Refusal) {
  use ticket <- result.try(state.ticket(current, id))

  // A withdrawn ticket and an ended one refuse work with different refusals.
  case ticket.authority, ticket.outcome {
    Withdrawn(_), _ -> Error(event.TicketWithdrawn(id))
    Granted, Some(_) -> Error(event.TicketEnded(id))
    Granted, None -> Ok(ticket)
  }
}

/// Let a transition's result end the assignment of a worker that came to
/// rest, see `rest`.
fn then_rest(step: Step, id: TicketId) -> Step {
  use #(next, effects) <- result.map(step)
  rest(next, id, effects)
}

/// A slot is held only while the assignment's session is doing work. When a
/// ticket's work reaches a person (it awaits review, is ready, or a person
/// published it) and its worker is idle, the assignment ends as
/// `SessionRested`: the slot is free for the next ticket, and the session and
/// its clone stay where they are. A person's message, a retry or a resume then
/// starts a new assignment, which the host seats in the same session.
///
/// Idle means the worker's latest report is `Waiting` with no question, no
/// person has spoken to it since, and the ticket is open. Each of those facts
/// can change only by an event that calls this function afterwards, or by a
/// report, which clears `heard` and so cannot leave a working worker looking
/// idle. A new assignment clears the report, so a worker that has just
/// started on a resting ticket is never taken for the idle one before it.
fn rest(
  current: State,
  id: TicketId,
  effects: List(Effect),
) -> #(State, List(Effect)) {
  case state.ticket(current, id) {
    Error(_) -> #(current, effects)
    Ok(ticket) ->
      case at_rest(ticket) {
        False -> #(current, effects)
        True -> {
          let rested =
            state.Ticket(
              ..ticket,
              assignments: list.map(ticket.assignments, rested_assignment),
            )
          schedule_after(state.put_ticket(current, rested), effects)
        }
      }
  }
}

/// Whether the ticket's work waits for a person while its worker is idle and
/// still assigned.
fn at_rest(ticket: Ticket) -> Bool {
  let waiting_for_person = waits_for_person(ticket.readiness)
  let idle =
    ticket.latest == Some(Waiting(NoQuestion))
    && ticket.question == NoQuestion
    && ticket.heard == Silent
  let open = ticket.outcome == None && ticket.authority == Granted

  waiting_for_person && idle && open && state.active_assignment(ticket) != None
}

/// Whether a readiness hands the ticket to a person: only work still in
/// progress does not.
fn waits_for_person(current: readiness.Readiness) -> Bool {
  case current {
    readiness.InProgress -> False
    readiness.AwaitingReview | readiness.Ready(_) | readiness.Published(_, _) ->
      True
  }
}

/// An assignment as a rest leaves it. A rest ends the assignment that holds
/// the slot, which is the only one the ticket can have.
fn rested_assignment(assignment: Assignment) -> Assignment {
  case state.holds_slot(assignment) {
    True ->
      Assignment(..assignment, status: AssignmentDone(model.SessionRested))
    False -> assignment
  }
}

/// Effects first, then whatever the freed slot lets the scheduler start.
fn schedule_after(
  current: State,
  effects: List(Effect),
) -> #(State, List(Effect)) {
  let #(scheduled, more) = schedule.run(current)
  #(scheduled, list.append(effects, more))
}

// --- assignments -------------------------------------------------------------

/// Record the session the host created or recovered for an assignment.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) when the assignment is bound to another session
/// ```
pub fn session_bound(
  current: State,
  id: TicketId,
  seq: Int,
  session: SessionId,
) -> Step {
  use ticket <- result.try(state.ticket(current, id))
  use updated <- result.try(
    update_assignment(ticket, seq, fn(assignment) {
      case assignment.session {
        None -> Ok(Assignment(..assignment, session: Some(session)))
        Some(bound) if bound == session -> Ok(assignment)
        Some(_) -> Error(event.Stale(id))
      }
    }),
  )
  Ok(#(state.put_ticket(current, updated), []))
}

/// The assignment's session is running.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) for an assignment that already ended
/// ```
pub fn assignment_live(current: State, id: TicketId, seq: Int) -> Step {
  use ticket <- result.try(state.ticket(current, id))
  use updated <- result.try(
    update_assignment(ticket, seq, fn(assignment) {
      case assignment.status {
        AssignmentPending | AssignmentRunning ->
          Ok(Assignment(..assignment, status: AssignmentRunning))
        AssignmentDone(_) -> Error(event.Stale(id))
      }
    }),
  )
  Ok(#(state.put_ticket(current, updated), []))
}

/// The assignment's session ended, which frees its slot.
///
/// ## Examples
///
/// ```gleam
/// // -> the slot is free for the next waiting ticket
/// ```
pub fn assignment_ended(
  current: State,
  id: TicketId,
  seq: Int,
  end: SessionEnd,
) -> Step {
  use ticket <- result.try(state.ticket(current, id))
  use updated <- result.try(
    update_assignment(ticket, seq, fn(assignment) {
      case assignment.status {
        AssignmentDone(_) -> Ok(assignment)
        AssignmentPending | AssignmentRunning ->
          Ok(Assignment(..assignment, status: AssignmentDone(end)))
      }
    }),
  )
  Ok(schedule_after(state.put_ticket(current, updated), []))
}

/// The host gave up on an assignment's worker before it reported: its session
/// would not start, or it was lost. The assignment ends as crashed and frees
/// its slot, and the ticket reads as failed with the host's reason, so a
/// ticket whose worker never spoke is not left looking idle. A person's later
/// message clears the failure from the stage like any other, and a retry
/// starts a fresh worker.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) for an assignment that already ended
/// ```
pub fn worker_failed(
  current: State,
  id: TicketId,
  seq: Int,
  why: String,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))
  use ended <- result.try(
    update_assignment(ticket, seq, fn(assignment) {
      case assignment.status {
        AssignmentDone(_) -> Error(event.Stale(id))
        AssignmentPending | AssignmentRunning ->
          Ok(
            Assignment(
              ..assignment,
              status: AssignmentDone(model.SessionCrashed),
            ),
          )
      }
    }),
  )
  let failed =
    state.Ticket(
      ..ended,
      latest: Some(Failed),
      failure: Some(model.failure_text(why)),
      heard: Silent,
    )
  Ok(schedule_after(state.put_ticket(current, failed), []))
}

/// Rewrite one assignment of a ticket, or refuse when it does not exist.
fn update_assignment(
  ticket: Ticket,
  seq: Int,
  change: fn(Assignment) -> Result(Assignment, Refusal),
) -> Result(Ticket, Refusal) {
  // An unknown sequence number refuses.
  case list.find(ticket.assignments, fn(found) { found.seq == seq }) {
    Error(Nil) -> Error(event.UnknownAssignment(ticket.id, seq))
    Ok(found) -> {
      use changed <- result.try(change(found))
      let assignments =
        list.map(ticket.assignments, fn(other) {
          case other.seq == seq {
            True -> changed
            False -> other
          }
        })
      Ok(state.Ticket(..ticket, assignments:))
    }
  }
}

/// A person asked for a new assignment on a stalled ticket. The new worker
/// starts with no memory of the old one, so the messages the gate admitted on
/// the ticket's opening thread are queued for it again, oldest first, ahead of
/// whatever was already waiting. A ticket with an explicit mandate is queued
/// none of the thread's inferred messages.
///
/// A ticket already waiting for a session has nothing to retry either: asking
/// again would only list its messages twice.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(AssignmentActive(id)) while a session is pending or running
/// ```
pub fn retry(current: State, id: TicketId) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // A ticket with a pending or running session has nothing to retry, and
  // neither has one that is already in line for a session.
  case state.active_assignment(ticket), ticket.demand {
    Some(_), _ -> Error(event.AssignmentActive(id))
    None, Wanting(_) -> Error(event.AlreadyWanted(id))
    None, Satisfied -> {
      let wanting =
        state.Ticket(
          ..ticket,
          demand: raise_demand(ticket.demand, model.Inferred),
          inbox: requeued_inbox(current, ticket),
        )
      Ok(schedule_after(state.put_ticket(current, wanting), []))
    }
  }
}

/// A person asked for the check to run again on the commit it already judged.
/// The commit is the head: a different one is not what the check failed on. The
/// ticket goes back to waiting for a verdict, the failed head count starts
/// again, and the host is asked for a check. The record of the failure is
/// cleared while the check runs, so the ticket does not ask for a person
/// that the check is about to answer, and so the action is not offered a
/// second time before the verdict arrives.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NothingToRecheck(id)) unless a check failed at the head, or
/// // gave no result
/// ```
pub fn recheck(current: State, id: TicketId) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // Only a check that failed at the head, or never gave a verdict, is run
  // again. A passing one has nothing to repeat.
  case state.recheckable(ticket) {
    None -> Error(event.NothingToRecheck(id))
    Some(commit) -> {
      let waiting =
        state.Ticket(
          ..ticket,
          readiness: readiness.new_commit(ticket.readiness),
          review: None,
          rejected: None,
          failed_heads: 0,
          last_checked: Some(commit),
        )
      Ok(
        #(state.put_ticket(current, waiting), [
          RequestCheck(ticket.id, commit),
        ]),
      )
    }
  }
}

/// Whether a message on the thread may reach this ticket's worker. An inferred
/// message never reaches a worker whose mandate is explicit, the same rule
/// `intake` applies when the message first arrives, so a retry cannot deliver
/// what a live session was never given.
fn may_steer(current: State, ticket: Ticket, trigger: TriggerId) -> Bool {
  case ticket.mandate.strength, state.record(current, trigger) {
    model.Inferred, _ -> True
    Explicit, Ok(stored) -> admitted_strength(stored) == Explicit
    Explicit, Error(_) -> False
  }
}

/// The inbox a retry starts its worker with: the admitted messages of the
/// ticket's opening thread, oldest first, then anything already waiting. The
/// first worker's session received the opening message and the follow-ups, and
/// a session that ended took them with it. Without this a retry starts a worker
/// that is never told what to do, which is what happened to a ticket whose
/// first session failed to start.
fn requeued_inbox(current: State, ticket: Ticket) -> List(TriggerId) {
  // A thread the state no longer holds leaves the opening message alone, which
  // is the one delivery a worker cannot do without.
  let admitted = case state.record(current, ticket.origin) {
    Error(_) -> [ticket.origin]
    Ok(stored) ->
      case dict.get(current.threads, stored.trigger.thread) {
        Error(Nil) -> [ticket.origin]
        Ok(thread) ->
          thread.entries
          |> list.reverse
          |> list.filter(fn(entry) { entry.reception == model.Received })
          |> list.filter(fn(entry) { may_steer(current, ticket, entry.trigger) })
          |> list.map(fn(entry) { entry.trigger })
      }
  }

  list.append(
    admitted,
    list.filter(ticket.inbox, fn(waiting) { !list.contains(admitted, waiting) }),
  )
}

// --- reports and checks ------------------------------------------------------

/// A worker reported. The report updates the ticket's facts; a `Waiting`
/// report with a fresh head may request a check or send the ticket to review.
///
/// ## Examples
///
/// ```gleam
/// // -> #(state, [RequestCheck(id, commit)]) for a first idle report
/// ```
pub fn reported(
  current: State,
  id: TicketId,
  seq: Int,
  report: Report,
  head: Head,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))
  use live <- result.try(
    update_assignment(ticket, seq, fn(assignment) {
      case assignment.status {
        AssignmentDone(_) -> Error(event.Stale(id))
        AssignmentPending | AssignmentRunning ->
          Ok(Assignment(..assignment, status: AssignmentRunning))
      }
    }),
  )

  // The worker's first word after a failed check ends the rejection's
  // "sent back" status, since the report now says what the worker is doing.
  let heard_from =
    state.Ticket(
      ..live,
      latest: Some(report),
      failure: None,
      heard: Silent,
      rejected: option.map(live.rejected, report_ends_handling),
    )
  let moved = apply_head(heard_from, head)
  let #(settled, effects) = apply_report(moved, seq, report, head)

  // A report that ends the ticket ends its session and frees its slot like
  // any other end; any other report leaves slots as they were.
  let step = case settled.outcome {
    None -> Ok(#(state.put_ticket(current, settled), effects))
    Some(outcome) -> {
      let #(ended, stops) =
        end_ticket(state.put_ticket(current, settled), settled, outcome)
      Ok(#(ended, list.append(effects, stops)))
    }
  }

  // A report that carries no head leaves resting to the head the host reads
  // next: a worker told to look again may have committed, and the commit
  // would need the worker still assigned to hear a failed check.
  case head {
    NoHead -> step
    Head(..) -> then_rest(step, id)
  }
}

/// A rejection after the worker has spoken: whatever the worker was sent back
/// to, its own report is the better account of what it does now.
fn report_ends_handling(rejected: model.Rejection) -> model.Rejection {
  model.Rejection(..rejected, handling: model.PersonNeeded)
}

/// A new commit invalidates whatever the old one earned: a passed check, a
/// publish, a pending review, the host's reason for asking a person to look
/// and the record of a failed check, all of which were about the old commit.
fn apply_head(ticket: Ticket, head: Head) -> Ticket {
  case head {
    NoHead -> ticket
    Head(commit, _) ->
      case ticket.head == Some(commit) {
        True -> ticket
        False ->
          state.Ticket(
            ..ticket,
            head: Some(commit),
            readiness: readiness.new_commit(ticket.readiness),
            review: None,
            rejected: None,
          )
      }
  }
}

/// Apply what a report says to the ticket, and run the check rule for an idle
/// one.
fn apply_report(
  ticket: Ticket,
  seq: Int,
  report: Report,
  head: Head,
) -> #(Ticket, List(Effect)) {
  case report {
    Progress -> #(ticket, [])
    Blocked -> #(ticket, [])
    Failed -> #(ticket, [])
    Dropped -> #(
      state.Ticket(..ticket, outcome: Some(Abandoned), demand: Satisfied),
      [],
    )
    Waiting(question) ->
      check_rule(state.Ticket(..ticket, question:), seq, question, head)
  }
}

/// The check rule: a request only for an idle worker with no open question
/// and a head not yet checked. Protected paths go to a person instead, and the
/// head is marked checked so a repeated idle report does not ask again.
///
/// An idle report that arrives with no head is the ordinary case, because a
/// worker's own call cannot name its branch. The engine then asks the host to
/// read it (`ObserveHead`), and the answer comes back as `HeadObserved` and
/// runs this rule again with the head in hand.
fn check_rule(
  ticket: Ticket,
  seq: Int,
  question: model.Question,
  head: Head,
) -> #(Ticket, List(Effect)) {
  case question, head {
    Asking(_), _ -> #(ticket, [])
    NoQuestion, NoHead -> #(ticket, [ObserveHead(ticket.id, seq)])
    NoQuestion, Head(commit, paths) ->
      case ticket.last_checked == Some(commit) {
        True -> #(ticket, [])
        False -> check_head(ticket, commit, paths)
      }
  }
}

/// The host read the head of an idle worker's branch. The head counts only
/// while the ticket's latest word from the worker is still an idle report with
/// no question: a worker that went back to work, or asked something, has moved
/// past the moment the host was asked about, and a check of its head would be
/// a check of work in flight.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) when the worker reported progress meanwhile
/// ```
pub fn head_observed(
  current: State,
  id: TicketId,
  seq: Int,
  head: Head,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))
  use _ <- result.try(update_assignment(ticket, seq, fn(found) { Ok(found) }))

  // Only an idle report with no question has a head worth reading.
  case ticket.latest, ticket.question {
    Some(Waiting(NoQuestion)), NoQuestion -> {
      let moved = apply_head(ticket, head)
      let #(settled, effects) = check_rule(moved, seq, NoQuestion, head)
      then_rest(Ok(#(state.put_ticket(current, settled), effects)), id)
    }
    _, _ -> Error(event.Stale(id))
  }
}

/// The host says it will not run the check or open a pull request by itself
/// and why. The reason is kept on the ticket until the head moves, and a ticket
/// that no check could vouch for waits for review.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) for a commit other than the head
/// ```
pub fn review_requested(
  current: State,
  id: TicketId,
  commit: CommitId,
  reason: model.ReviewReason,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // The reason is about one commit, and a ticket that has moved on needs none.
  case ticket.head == Some(commit) {
    False -> Error(event.Stale(id))
    True ->
      Ok(
        #(
          state.put_ticket(
            current,
            state.Ticket(
              ..ticket,
              review: Some(reason),
              readiness: readiness.review_needed(ticket.readiness),
            ),
          ),
          [],
        ),
      )
      |> then_rest(id)
  }
}

/// Mark the head checked, then request a check, or send protected paths to a
/// person instead.
fn check_head(
  ticket: Ticket,
  commit: CommitId,
  paths: model.PathScope,
) -> #(Ticket, List(Effect)) {
  let marked = state.Ticket(..ticket, last_checked: Some(commit))

  // A diff touching protected paths goes to review and runs no check.
  case paths {
    model.ProtectedPathsTouched -> #(
      state.Ticket(
        ..marked,
        readiness: readiness.protected_touched(marked.readiness),
      ),
      [],
    )
    model.ProtectedPathsUntouched -> #(marked, [
      RequestCheck(ticket.id, commit),
    ])
  }
}

/// The host's check finished for the ticket's current head. A pass makes the
/// ticket `Ready` and asks the host to open its pull request; a result for a
/// commit that is no longer the head is stale.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) when the head moved on while the check ran
/// ```
pub fn check_finished(
  current: State,
  id: TicketId,
  finished: CheckResult,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // A rejection is recorded only for the current head.
  case finished {
    CheckOk(proof) -> check_passed(current, ticket, proof) |> then_rest(id)
    CheckRejected(commit, digest, cause) ->
      case ticket.head == Some(commit) {
        False -> Error(event.Stale(id))
        True -> Ok(rejected(current, ticket, commit, digest, cause))
      }
  }
}

/// The most different heads in a row that the engine sends a worker back to.
/// A fourth failing head goes to a person instead, because a worker that has
/// failed three times against a check is more likely misreading the check than
/// one commit short of passing it. The count is of heads and not of runs: a
/// person's re-run of the same commit does not use one up. A pass, a person's
/// answer or a person's re-run starts the count again.
pub const max_failing_heads = 3

/// Record a failed check at the head, and decide whether the worker is sent
/// back to it. The worker is sent back only when a session is live, the
/// failure could be the work's (an `EnvironmentFailure` could not be), and the
/// ticket has not already used up its failing heads. The host acts on the
/// answer by handing the worker its note, so the decision is in the ledger
/// with the failure and the stage can say who has the ticket.
fn rejected(
  current: State,
  ticket: Ticket,
  commit: CommitId,
  digest: model.CommandDigest,
  cause: model.FailureCause,
) -> #(State, List(Effect)) {
  // A re-run of the commit that already failed is not another head.
  let heads = case ticket.rejected {
    Some(before) if before.commit == commit -> ticket.failed_heads
    Some(_) | None -> ticket.failed_heads + 1
  }

  // Only a failure of the work, with a worker to hear it and heads to spare,
  // sends the worker back. Every other row is a person's.
  let handling = case
    cause,
    heads <= max_failing_heads,
    state.active_assignment(ticket)
  {
    model.TestFailure, True, Some(_) -> model.WorkerTold
    model.TestFailure, False, _
    | model.TestFailure, True, None
    | model.EnvironmentFailure, _, _
    -> model.PersonNeeded
  }

  let failed =
    state.Ticket(
      ..ticket,
      rejected: Some(model.Rejection(commit, digest, cause, handling)),
      failed_heads: heads,
    )
  #(state.put_ticket(current, failed), [])
}

/// Make the ticket ready when the passing check was requested for the current
/// head and the readiness accepts it.
fn check_passed(
  current: State,
  ticket: Ticket,
  proof: host.CheckPassed,
) -> Step {
  let commit = host.commit(proof)
  let requested =
    ticket.head == Some(commit) && ticket.last_checked == Some(commit)

  // The check must have been requested for the current head, and the readiness
  // must still accept a pass.
  case requested, readiness.check_passed(ticket.readiness, proof) {
    True, Ok(ready) ->
      Ok(vouched(
        current,
        state.Ticket(
          ..ticket,
          readiness: ready,
          rejected: None,
          failed_heads: 0,
        ),
        commit,
      ))
    True, Error(Nil) -> Error(event.Stale(ticket.id))
    False, _ -> Error(event.Stale(ticket.id))
  }
}

/// A passing check on a ticket asks the host to publish its commit only when
/// the mandate is explicit. The check jail confines what the commit's code can
/// do while it runs, but the commit itself came from a worker that an inferred
/// trigger steered, and a worker's sandbox can read the whole checkout and the
/// files around it. Publishing uses the owner's credentials, so an inferred
/// ticket stops at `Ready` with a reason and waits for a person, whose
/// `PersonPublished` is the only way its commit leaves the machine.
fn vouched(
  current: State,
  ticket: Ticket,
  commit: CommitId,
) -> #(State, List(Effect)) {
  // The mandate's strength was fixed when the ticket opened, so a later
  // explicit message to the thread does not change which way this goes.
  case ticket.mandate.strength {
    Explicit -> publish(current, ticket, commit)
    model.Inferred -> #(
      state.put_ticket(
        current,
        state.Ticket(..ticket, review: Some(model.InferredWork)),
      ),
      [],
    )
  }
}

/// A person published past the check. The commit must be the ticket's head.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(Stale(id)) for a commit other than the head
/// ```
pub fn person_published(
  current: State,
  id: TicketId,
  by: PrincipalId,
  commit: CommitId,
) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // A person publishes the ticket's current head and nothing else.
  case ticket.head == Some(commit) {
    False -> Error(event.Stale(id))
    True ->
      Ok(publish(
        current,
        state.Ticket(
          ..ticket,
          readiness: readiness.person_publishes(ticket.readiness, by, commit),
        ),
        commit,
      ))
      |> then_rest(id)
  }
}

/// Store the ticket and ask the host to publish the commit. A ticket whose pull
/// request is open is asked too, because a later commit has to reach the same
/// branch for the pull request to show it; the host finds the pull request
/// that is open and opens no second one.
fn publish(
  current: State,
  ticket: Ticket,
  commit: CommitId,
) -> #(State, List(Effect)) {
  #(state.put_ticket(current, ticket), [
    PublishBranch(ticket.id, model.branch_name(ticket.id), commit),
  ])
}

/// The host opened the ticket's pull request. Only a ready or published
/// ticket has one.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(NotPublishable(id)) for a ticket still in progress
/// ```
pub fn pull_request_opened(
  current: State,
  id: TicketId,
  pull_request: PullRequestRef,
) -> Step {
  use ticket <- result.try(state.ticket(current, id))

  // Only a ticket that vouches for a commit has a pull request.
  case readiness.vouches_for(ticket.readiness) {
    None -> Error(event.NotPublishable(id))
    Some(_) -> Ok(#(follow_pull_request(current, ticket, pull_request), []))
  }
}

/// Record the pull request and subscribe the ticket to its thread, so a
/// person's comment on the pull request reaches the worker that wrote it. A
/// source reads the same subscription to count a failure on that thread as one
/// more hop from the project's own output.
fn follow_pull_request(
  current: State,
  ticket: Ticket,
  pull_request: PullRequestRef,
) -> State {
  let recorded =
    state.put_ticket(
      current,
      state.Ticket(..ticket, pull_request: Some(pull_request)),
    )

  // A URL that names no thread leaves the subscriptions as they were.
  case model.pull_request_thread(pull_request) {
    Some(thread) -> subscribe(recorded, ticket.id, thread)
    None -> recorded
  }
}

// --- questions and inputs ----------------------------------------------------

/// A person answered the open question, echoing its sequence number.
///
/// ## Examples
///
/// ```gleam
/// // -> Error(StaleAnswer(id)) for a number the ticket did not ask
/// ```
pub fn answered(current: State, id: TicketId, question: Int) -> Step {
  use ticket <- result.try(open_ticket(current, id))

  // The answer must echo the open question.
  case ticket.question == Asking(question) {
    False -> Error(event.StaleAnswer(id))
    True -> {
      let answered_ticket =
        state.Ticket(
          ..ticket,
          question: NoQuestion,
          heard: PersonHeard,
          failed_heads: 0,
        )
      Ok(relay(current, answered_ticket, question))
    }
  }
}

/// Send the answer to the worker that is live now. With no live session the
/// answer waits in the ticket's inbox and goes out on the next assignment,
/// which is how any input for a ticket without a session travels. The answer
/// has no session of its own to wake, so it asks for none: a ticket with no
/// worker takes the answer along when a person or the router next wants one.
fn relay(
  current: State,
  ticket: Ticket,
  question: Int,
) -> #(State, List(Effect)) {
  let answer = model.answer_id(ticket.id, question)

  // A pending or running session receives it at once; otherwise it queues.
  case state.active_assignment(ticket) {
    Some(assignment) -> #(state.put_ticket(current, ticket), [
      event.Deliver(ticket.id, assignment.seq, answer),
    ])
    None -> #(
      state.put_ticket(
        current,
        state.Ticket(..ticket, inbox: list.append(ticket.inbox, [answer])),
      ),
      [],
    )
  }
}

/// An input did not reach the worker.
///
/// ## Examples
///
/// ```gleam
/// // -> the ticket's stage becomes `person/delivery`
/// ```
pub fn input_failed(current: State, id: TicketId, trigger: TriggerId) -> Step {
  use ticket <- result.try(state.ticket(current, id))

  // A failure is recorded once.
  let failed = case list.contains(ticket.failed_inputs, trigger) {
    True -> ticket.failed_inputs
    False -> list.append(ticket.failed_inputs, [trigger])
  }

  Ok(
    #(
      state.put_ticket(current, state.Ticket(..ticket, failed_inputs: failed)),
      [],
    ),
  )
}

/// An input reached the worker.
///
/// ## Examples
///
/// ```gleam
/// // -> the ticket's failed inputs lose the trigger
/// ```
pub fn input_delivered(
  current: State,
  id: TicketId,
  trigger: TriggerId,
) -> Step {
  use ticket <- result.try(state.ticket(current, id))
  let failed = list.filter(ticket.failed_inputs, fn(other) { other != trigger })
  Ok(
    #(
      state.put_ticket(current, state.Ticket(..ticket, failed_inputs: failed)),
      [],
    ),
  )
}
