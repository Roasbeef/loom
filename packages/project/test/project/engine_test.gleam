//// The engine, scenario by scenario: each test names one rule of the design
//// note and drives the smallest event sequence that shows it.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/action
import project/engine
import project/event.{
  AcceptRefused, Deliver, OfferCandidates, PublishBranch, RequestCheck,
  StartSession, StopSession,
}
import project/gate
import project/host
import project/model.{
  Asking, CommitId, Head, NoQuestion, ProtectedPathsTouched,
  ProtectedPathsUntouched, TicketId, TriggerId, Waiting,
}
import project/queue
import project/readiness
import project/stage
import project/state
import support/world.{
  accept, arrival, attach, automated, fresh, owner, run, step, ticket, ticket_of,
}

fn explicit_mandate() -> model.Mandate {
  model.Mandate(
    strength: model.Explicit,
    basis: model.FromComposer,
    actor: model.ActorId("me"),
    source: world.source,
    scope: model.Scope("w", model.ApprovalsNotGranted),
    policy_version: "v1",
  )
}

// A state with ticket `c1` accepted and its first session running.
fn working() -> state.State {
  run(fresh(), [
    arrival(owner("c1")),
    accept("c1"),
    event.AssignmentLive(ticket_of("c1"), 1),
  ])
}

fn waiting_report(head: model.Head, question: model.Question) -> event.Event {
  event.Reported(ticket_of("c1"), 1, Waiting(question), head)
}

// A person asks for a worker on a ticket whose first one rested, and the
// second assignment starts. Its events carry sequence number 2.
fn second_worker() -> List(event.Event) {
  [
    event.RetryRequested(ticket_of("c1"), model.PrincipalId("owner")),
    event.AssignmentLive(ticket_of("c1"), 2),
  ]
}

fn head_at(commit: String, paths: model.PathScope) -> model.Head {
  Head(CommitId(commit), paths)
}

fn passed(commit: String) -> event.Event {
  event.CheckFinished(
    ticket_of("c1"),
    event.CheckOk(host.passed(
      CommitId(commit),
      model.CommandDigest("d"),
      model.EntryId("e"),
    )),
  )
}

// --- accepting and idempotence ---------------------------------------------------

pub fn an_owner_message_is_offered_to_the_router_test() {
  let #(next, effects) = step(fresh(), arrival(owner("c1")))
  assert effects == [OfferCandidates([TriggerId("c1")])]
  assert next.router == state.RouterBusy
}

pub fn accepting_a_trigger_opens_a_ticket_and_starts_a_session_test() {
  let offered = run(fresh(), [arrival(owner("c1"))])
  let #(next, effects) = step(offered, accept("c1"))
  assert effects
    == [
      StartSession(ticket_of("c1"), 1, "project:p1:t-c1:1", explicit_mandate()),
      Deliver(ticket_of("c1"), 1, TriggerId("c1")),
    ]
  assert state.stage_of(ticket(next, ticket_of("c1"))) == stage.Queued
}

pub fn accepting_a_trigger_twice_makes_one_ticket_test() {
  let accepted = run(fresh(), [arrival(owner("c1")), accept("c1")])
  let #(again, effects) = step(accepted, accept("c1"))
  assert effects == []
  assert again == accepted
  assert dict.size(again.tickets) == 1
}

pub fn a_routing_naming_an_unknown_ticket_changes_nothing_test() {
  let offered = run(fresh(), [arrival(owner("c1"))])
  let refused = engine.apply(offered, attach("c1", TicketId("t-nowhere")))
  assert refused == Error(event.UnknownTicket(TicketId("t-nowhere")))
}

pub fn the_router_cannot_route_what_it_was_not_offered_test() {
  let refused = engine.apply(fresh(), accept("c1"))
  assert refused == Error(event.UnknownTrigger(TriggerId("c1")))
  let queued = run(fresh(), [arrival(owner("c1")), arrival(owner("c2"))])
  assert engine.apply(queued, accept("c2"))
    == Error(event.NotOffered(TriggerId("c2")))
}

// --- authority -------------------------------------------------------------------

pub fn inferred_work_is_held_while_its_pair_is_off_test() {
  let #(next, effects) = step(fresh(), arrival(world.overheard("o1", "th")))
  assert effects == []
  let assert Ok(stored) = state.record(next, TriggerId("o1")) as "stored"
  assert stored.fate
    == state.Decided(state.Held(state.HeldByGate(gate.ModeIsOff)))
}

pub fn observe_records_what_would_have_been_accepted_test() {
  let observing =
    run(fresh(), [
      event.ModeSet(world.source, world.rule, model.Observe),
      arrival(world.overheard("o1", "th")),
    ])
  let #(next, effects) = step(observing, accept("o1"))
  assert effects == []
  assert dict.size(next.tickets) == 0
  let assert Ok(stored) = state.record(next, TriggerId("o1")) as "stored"
  assert stored.fate == state.Decided(state.WouldAccept)
}

pub fn auto_cannot_be_set_without_a_current_verdict_test() {
  let refused =
    engine.apply(fresh(), event.ModeSet(world.source, world.rule, model.Auto))
  assert refused == Error(event.VerdictRequired(world.source, world.rule))
}

pub fn accepting_inferred_work_needs_auto_a_rule_and_a_verdict_test() {
  let armed = run(automated(), [arrival(world.overheard("o1", "th"))])
  let #(next, _) = step(armed, accept("o1"))
  let opened = ticket(next, ticket_of("o1"))
  assert opened.mandate.strength == model.Inferred
  assert opened.demand == model.Satisfied
}

pub fn a_changed_policy_returns_auto_to_observe_test() {
  let changed = run(automated(), [event.PolicyVersionSet("v2")])
  assert state.mode_of(changed, world.source, world.rule) == model.Observe
  let failed =
    run(automated(), [
      world.verdict(world.source, world.rule, "v1", model.VerdictFailed),
    ])
  assert state.mode_of(failed, world.source, world.rule) == model.Observe
}

pub fn an_accept_after_the_verdict_goes_stale_records_and_acts_on_nothing_test() {
  let armed = run(automated(), [arrival(world.overheard("o1", "th"))])
  let stale = run(armed, [event.PolicyVersionSet("v2")])
  let #(next, effects) = step(stale, accept("o1"))
  assert effects == []
  assert dict.size(next.tickets) == 0
  let off = run(armed, [event.ModeSet(world.source, world.rule, model.Off)])
  assert engine.apply(off, accept("o1")) == Error(AcceptRefused(gate.ModeIsOff))
}

pub fn an_unlisted_sender_is_recorded_and_never_delivered_test() {
  let subscribed =
    run(fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      event.AssignmentLive(ticket_of("c1"), 1),
    ])
  let #(next, effects) =
    step(subscribed, world.arrival(world.stranger("s1", "th-c1")))
  assert effects == []
  let assert Ok(thread) = dict.get(next.threads, model.ThreadId("th-c1"))
    as "thread"
  assert list.contains(
    thread.entries,
    model.ThreadEntry(TriggerId("s1"), model.Recorded),
  )
  let assert Ok(stored) = state.record(next, TriggerId("s1")) as "stored"
  assert stored.fate == state.Decided(state.RecordedOnly)
}

pub fn a_follow_up_goes_straight_to_the_ticket_that_owns_the_thread_test() {
  let #(next, effects) =
    step(working(), arrival(world.addressed("f1", "th-c1", "me")))
  assert effects == [Deliver(ticket_of("c1"), 1, TriggerId("f1"))]
  assert next.router == state.RouterBusy
  assert next.queue == []
}

pub fn an_inferred_comment_on_a_followed_thread_reaches_the_worker_only_when_the_gate_allows_test() {
  let comment =
    world.trigger(
      "b1",
      "th-c1",
      "ci",
      model.ListedBot,
      model.Unaddressed,
      world.matched(),
      0,
    )
  let observing =
    run(working(), [event.ModeSet(world.source, world.rule, model.Observe)])
  let #(_, held) = step(observing, arrival(comment))
  assert list.all(held, fn(effect) {
    case effect {
      Deliver(_, _, _) -> False
      _ -> True
    }
  })

  let armed =
    run(working(), [
      world.verdict(world.source, world.rule, "v1", model.VerdictPassed),
      event.ModeSet(world.source, world.rule, model.Auto),
    ])
  let #(_, delivered) = step(armed, arrival(comment))
  assert delivered == [Deliver(ticket_of("c1"), 1, TriggerId("b1"))]
}

pub fn the_projects_own_messages_are_dropped_test() {
  let own =
    world.trigger(
      "b1",
      "th",
      "loom-bot",
      model.Person,
      model.Addressed,
      None,
      0,
    )
  let #(next, effects) = step(fresh(), arrival(own))
  assert effects == []
  assert dict.size(next.threads) == 0
  let assert Ok(stored) = state.record(next, TriggerId("b1")) as "stored"
  assert stored.fate == state.Decided(state.OwnMessage)
}

pub fn inference_stops_past_the_generation_limit_test() {
  let deep =
    world.trigger(
      "o9",
      "th",
      "pat",
      model.Person,
      model.Unaddressed,
      world.matched(),
      gate.max_generation + 1,
    )
  let #(_, effects) = step(automated(), arrival(deep))
  assert effects == []
  let explicit_deep =
    world.trigger("c9", "th9", "me", model.Owner, model.Addressed, None, 50)
  let #(_, offered) = step(automated(), arrival(explicit_deep))
  assert offered == [OfferCandidates([TriggerId("c9")])]
}

// --- stopping ----------------------------------------------------------------------

fn stoppable() -> state.State {
  run(fresh(), [
    arrival(owner("c1")),
    accept("c1"),
    event.AssignmentLive(ticket_of("c1"), 1),
    event.RouterTurnEnded,
  ])
}

pub fn a_bots_comment_cannot_stop_a_ticket_test() {
  let observing =
    run(stoppable(), [
      event.ModeSet(world.source, world.rule, model.Observe),
      arrival(world.trigger(
        "bot2",
        "th",
        "ci",
        model.ListedBot,
        model.Unaddressed,
        world.matched(),
        0,
      )),
    ])
  assert engine.apply(
      observing,
      event.RoutedStop(TriggerId("bot2"), ticket_of("c1")),
    )
    == Error(event.NotAPersonsMessage(TriggerId("bot2")))
}

pub fn a_persons_stop_withdraws_the_mandate_and_the_ticket_never_resumes_test() {
  let asked =
    run(stoppable(), [
      arrival(world.addressed("s1", "elsewhere", "pat")),
    ])
  let #(stopped, effects) =
    step(asked, event.RoutedStop(TriggerId("s1"), ticket_of("c1")))
  assert effects == [StopSession(ticket_of("c1"), 1)]
  let ended = ticket(stopped, ticket_of("c1"))
  assert ended.outcome == Some(model.StoppedByPerson)
  assert ended.demand == model.Satisfied

  // Nothing reopens it: not a resume, not a retry, not a command.
  let wants =
    run(stopped, [
      event.RouterTurnEnded,
      arrival(world.addressed("r1", "th-c1", "me")),
    ])
  assert engine.apply(wants, step_resume("r1"))
    == Error(event.TicketWithdrawn(ticket_of("c1")))
  assert engine.apply(
      stopped,
      event.RetryRequested(ticket_of("c1"), world_principal()),
    )
    == Error(event.TicketWithdrawn(ticket_of("c1")))
}

fn step_resume(id: String) -> event.Event {
  event.Routed(model.Routing(
    trigger: TriggerId(id),
    kind: model.Resume(ticket_of("c1")),
    holds: [],
    related: [],
    prior_hand_back: None,
  ))
}

fn world_principal() -> model.PrincipalId {
  model.PrincipalId("owner")
}

pub fn a_stop_command_is_idempotent_and_ends_assignments_wanting_test() {
  let #(stopped, effects) =
    step(working(), event.PersonStopped(ticket_of("c1"), world_principal()))
  assert effects == [StopSession(ticket_of("c1"), 1)]
  let #(again, more) =
    step(stopped, event.PersonStopped(ticket_of("c1"), world_principal()))
  assert more == []
  assert again == stopped
}

// A stop is the only event that ends the session of a ticket a person
// withdrew, so it has to free the slot itself. The drive of project mode on a
// real model left every stopped ticket's assignment running, which kept the
// waiting tickets queued for good.
pub fn a_stop_frees_the_slot_for_a_waiting_ticket_test() {
  // Two general slots and the reserved one are taken by c1, c2 and c3, which a
  // person's request may use, so c4 waits.
  let full =
    run(fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      arrival(owner("c2")),
      arrival(owner("c3")),
      arrival(owner("c4")),
      event.RouterTurnEnded,
      accept("c2"),
      accept("c3"),
      accept("c4"),
    ])
  assert state.slots_used(full, state.General) == 2
  assert state.slots_used(full, state.Reserved) == 1
  assert state.active_assignment(ticket(full, ticket_of("c4"))) == None
  let #(stopped, effects) =
    step(full, event.PersonStopped(ticket_of("c1"), world_principal()))
  assert state.slots_used(stopped, state.General) == 2
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 1, _, _) -> ticket == ticket_of("c4")
      _ -> False
    }
  })
}

pub fn a_stopped_ticket_is_never_assigned_again_test() {
  let queued =
    run(fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      arrival(owner("c2")),
      arrival(owner("c3")),
      event.RouterTurnEnded,
      accept("c2"),
      accept("c3"),
      arrival(owner("c4")),
      event.RouterTurnEnded,
      accept("c4"),
    ])
  let stopped =
    run(queued, [event.PersonStopped(ticket_of("c4"), world_principal())])
  let freed =
    step(
      stopped,
      event.AssignmentEnded(ticket_of("c1"), 1, model.SessionExited),
    )
  assert list.all(freed.1, fn(effect) {
    case effect {
      StartSession(ticket, _, _, _) -> ticket != ticket_of("c4")
      _ -> True
    }
  })
}

// --- overload ------------------------------------------------------------------------

fn busy_router() -> state.State {
  run(automated(), [arrival(owner("c0"))])
}

fn fate_of(current: state.State, id: String) -> state.Fate {
  let assert Ok(stored) = state.record(current, TriggerId(id)) as "stored"
  stored.fate
}

pub fn a_full_queue_sheds_inferred_triggers_and_records_it_test() {
  let queued =
    run(busy_router(), [
      arrival(world.overheard("o1", "t1")),
      arrival(world.overheard("o2", "t2")),
      arrival(world.overheard("o3", "t3")),
      arrival(world.overheard("o4", "t4")),
    ])
  assert fate_of(queued, "o4") == state.Decided(state.Shed)
  assert fate_of(queued, "o1") == state.Awaiting
}

pub fn an_explicit_trigger_displaces_inferred_work_and_is_never_shed_test() {
  let full =
    run(busy_router(), [
      arrival(world.overheard("o1", "t1")),
      arrival(world.overheard("o2", "t2")),
      arrival(world.overheard("o3", "t3")),
      arrival(owner("c1")),
    ])
  assert fate_of(full, "o1") == state.Decided(state.Shed)
  assert fate_of(full, "c1") == state.Awaiting

  // With nothing inferred left to shed, explicit triggers queue past the bound.
  let explicit =
    run(busy_router(), [
      arrival(owner("e1")),
      arrival(owner("e2")),
      arrival(owner("e3")),
      arrival(owner("e4")),
      arrival(owner("e5")),
    ])
  assert list.length(explicit.queue) == 5
}

pub fn the_router_is_offered_twenty_candidates_explicit_first_test() {
  let queued = run(busy_router(), [arrival(world.overheard("o1", "t1"))])
  let many =
    counted(25)
    |> list.map(fn(n) { arrival(owner("e" <> int_text(n))) })
  let filled = run(queued, many)
  let #(_, effects) = step(filled, event.RouterTurnEnded)
  let expected =
    counted(20) |> list.map(fn(n) { TriggerId("e" <> int_text(n)) })
  assert effects == [OfferCandidates(expected)]
}

fn counted(size: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, size), fn(_, position) { position + 1 })
}

fn int_text(n: Int) -> String {
  string.pad_start(int.to_string(n), 2, "0")
}

pub fn a_source_stops_inferring_while_people_are_busy_with_its_tickets_test() {
  let asking = fn(n: String) {
    [
      arrival(owner(n)),
      accept(n),
      event.AssignmentLive(ticket_of(n), 1),
      event.Reported(ticket_of(n), 1, Waiting(Asking(1)), model.NoHead),
      event.RouterTurnEnded,
    ]
  }
  let busy =
    run(automated(), list.flatten([asking("c1"), asking("c2"), asking("c3")]))
  assert state.waiting_on_person(busy, world.source) == 3
  let #(next, effects) = step(busy, arrival(world.overheard("o1", "t1")))
  assert effects == []
  assert fate_of(next, "o1") == state.Decided(state.Held(state.HeldByAttention))
}

pub fn the_token_ceiling_stops_inferred_assignments_but_not_explicit_ones_test() {
  let capped = run(automated(), [event.CeilingChanged(model.CeilingReached)])
  let with_inferred =
    run(capped, [arrival(world.overheard("o1", "t1")), event.RouterTurnEnded])
  assert fate_of(with_inferred, "o1")
    == state.Decided(state.Held(state.HeldByCeiling))
  let #(_, effects) = step(capped, arrival(owner("c1")))
  assert effects == [OfferCandidates([TriggerId("c1")])]
  let started = run(capped, [arrival(owner("c1"))])
  let #(_, begun) = step(started, accept("c1"))
  assert list.any(begun, fn(effect) {
    case effect {
      StartSession(_, _, _, _) -> True
      _ -> False
    }
  })
}

pub fn lifting_the_ceiling_starts_the_work_that_was_waiting_test() {
  let capped =
    run(automated(), [
      arrival(world.overheard("o1", "t1")),
      event.CeilingChanged(model.CeilingReached),
    ])
  let #(waiting, effects) = step(capped, accept("o1"))
  assert effects == []
  assert ticket(waiting, ticket_of("o1")).assignments == []
  let #(_, started) = step(waiting, event.CeilingChanged(model.CeilingClear))
  assert list.any(started, fn(effect) {
    case effect {
      StartSession(ticket, 1, _, _) -> ticket == ticket_of("o1")
      _ -> False
    }
  })
}

// --- slots -----------------------------------------------------------------------------

pub fn the_reserved_slot_serves_a_persons_message_and_nothing_else_test() {
  let two_running =
    run(automated(), [
      arrival(owner("c1")),
      arrival(owner("c2")),
      arrival(world.overheard("o1", "t1")),
      accept("c1"),
      event.RouterTurnEnded,
      accept("c2"),
      accept("o1"),
    ])
  assert state.slots_used(two_running, state.General) == 2
  assert state.slots_used(two_running, state.Reserved) == 0
  let inferred = ticket(two_running, ticket_of("o1"))
  assert inferred.assignments == []
  assert state.stage_of(inferred) == stage.Queued

  let with_person =
    run(two_running, [arrival(owner("c3")), event.RouterTurnEnded, accept("c3")])
  assert state.slots_used(with_person, state.Reserved) == 1
  let with_fourth =
    run(with_person, [arrival(owner("c4")), event.RouterTurnEnded, accept("c4")])
  assert ticket(with_fourth, ticket_of("c4")).assignments == []
}

// Three tickets whose first workers fill both general slots and the reserved
// one, with a fourth in line.
fn full_with_a_fourth_waiting() -> state.State {
  run(fresh(), [
    arrival(owner("c1")),
    accept("c1"),
    arrival(owner("c2")),
    arrival(owner("c3")),
    arrival(owner("c4")),
    event.RouterTurnEnded,
    accept("c2"),
    accept("c3"),
    accept("c4"),
  ])
}

// A worker idle on a head that waits for a person.
fn rests_in_review(ticket_name: String) -> event.Event {
  event.Reported(
    ticket_of(ticket_name),
    1,
    Waiting(NoQuestion),
    head_at("a", ProtectedPathsTouched),
  )
}

// A worker whose work is in review is idle, so its slot belongs to the next
// ticket in line. The assignment ends with the engine's own word for it, and
// the person still sees the ticket under review.
pub fn a_worker_at_rest_in_review_frees_its_slot_test() {
  let full = full_with_a_fourth_waiting()
  assert state.active_assignment(ticket(full, ticket_of("c4"))) == None

  let #(rested, effects) = step(full, rests_in_review("c1"))
  let first = ticket(rested, ticket_of("c1"))
  assert state.active_assignment(first) == None
  assert list.map(first.assignments, fn(each) { each.status })
    == [state.AssignmentDone(model.SessionRested)]
  assert state.stage_of(first) == stage.PersonReview
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 1, _, _) -> ticket == ticket_of("c4")
      _ -> False
    }
  })

  // No stop is owed: the session and its clone stay for the next assignment.
  assert !list.any(effects, fn(effect) {
    case effect {
      StopSession(..) -> True
      _ -> False
    }
  })
}

// Finished work never fills the project. With every slot held by a ticket in
// review or ready, new tickets still get workers.
pub fn finished_tickets_never_hold_every_slot_test() {
  let resting =
    run(full_with_a_fourth_waiting(), [
      rests_in_review("c1"),
      rests_in_review("c2"),
      rests_in_review("c3"),
    ])
  assert state.slots_used(resting, state.General)
    + state.slots_used(resting, state.Reserved)
    == 1
  assert state.active_assignment(ticket(resting, ticket_of("c4"))) != None

  let more =
    run(resting, [arrival(owner("c5")), event.RouterTurnEnded, accept("c5")])
  assert state.active_assignment(ticket(more, ticket_of("c5"))) != None
}

// A ticket whose check passed rests as well, and a worker that is still
// answering a question or has been spoken to does not.
pub fn only_an_idle_worker_with_work_for_a_person_rests_test() {
  let ready =
    run(working(), [
      waiting_report(model.NoHead, NoQuestion),
      observed_head("a", ProtectedPathsUntouched),
    ])

  // The check is out, so the worker is kept for a failure it would be told.
  assert state.active_assignment(ticket(ready, ticket_of("c1"))) != None
  let passed_check = run(ready, [passed("a")])
  assert state.active_assignment(ticket(passed_check, ticket_of("c1"))) == None
  assert ticket(passed_check, ticket_of("c1")).readiness != readiness.InProgress

  // A question keeps the worker, however the head stands.
  let asking =
    run(working(), [
      event.Reported(
        ticket_of("c1"),
        1,
        Waiting(Asking(2)),
        head_at("a", ProtectedPathsTouched),
      ),
    ])
  assert state.active_assignment(ticket(asking, ticket_of("c1"))) != None
}

// A report with no head leaves the decision to the head the host reads, so a
// worker that committed again is still assigned to hear a failed check.
pub fn a_resumed_worker_rests_only_once_its_head_is_read_test() {
  let rested = run(working(), [rests_in_review("c1")])
  let resumed =
    run(rested, [
      event.RetryRequested(ticket_of("c1"), world_principal()),
      event.AssignmentLive(ticket_of("c1"), 2),
    ])

  // The new worker has said nothing, so it is not taken for the idle one.
  assert ticket(resumed, ticket_of("c1")).latest == None
  assert state.active_assignment(ticket(resumed, ticket_of("c1"))) != None

  let idle =
    run(resumed, [
      event.Reported(ticket_of("c1"), 2, Waiting(NoQuestion), model.NoHead),
    ])
  assert state.active_assignment(ticket(idle, ticket_of("c1"))) != None

  // The same head again changes nothing, and the worker rests once more.
  let again =
    run(idle, [
      event.HeadObserved(
        ticket_of("c1"),
        2,
        head_at("a", ProtectedPathsTouched),
      ),
    ])
  assert state.active_assignment(ticket(again, ticket_of("c1"))) == None

  // A new head is a new check, and the worker stays for its verdict.
  let moved =
    run(idle, [
      event.HeadObserved(
        ticket_of("c1"),
        2,
        head_at("b", ProtectedPathsUntouched),
      ),
    ])
  assert state.active_assignment(ticket(moved, ticket_of("c1"))) != None
}

// A person's message to a ticket in review starts a new assignment, and the
// slot is taken again for as long as the worker works.
pub fn a_message_to_a_ticket_in_review_starts_a_new_assignment_test() {
  let rested = run(working(), [rests_in_review("c1")])
  let #(woken, effects) =
    step(rested, arrival(world.addressed("f1", "th-c1", "me")))
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 2, _, _) -> ticket == ticket_of("c1")
      _ -> False
    }
  })
  assert list.length(ticket(woken, ticket_of("c1")).assignments) == 2
}

// --- a worker that failed to start -----------------------------------------------------

fn failed_start(why: String) -> event.Event {
  event.WorkerFailed(ticket_of("c1"), 1, why)
}

// A worker whose session never started is not idle. The ticket reads as failed
// with the host's words, its slot is free, and a retry starts another worker
// and clears the failure.
pub fn a_worker_that_failed_to_start_leaves_the_ticket_failed_with_a_reason_test() {
  let fresh_ticket = run(fresh(), [arrival(owner("c1")), accept("c1")])
  let failed = run(fresh_ticket, [failed_start("the clone was not made")])
  let held = ticket(failed, ticket_of("c1"))
  assert state.stage_of(held) == stage.PersonFailed
  assert held.failure == Some("the clone was not made")
  assert state.active_assignment(held) == None
  assert state.slots_used(failed, state.General) == 0
  assert list.map(held.assignments, fn(each) { each.status })
    == [state.AssignmentDone(model.SessionCrashed)]

  // The failure is not a report anyone made, and a retry clears it.
  let #(retried, effects) =
    step(failed, event.RetryRequested(ticket_of("c1"), world_principal()))
  assert ticket(retried, ticket_of("c1")).failure == None
  assert state.stage_of(ticket(retried, ticket_of("c1"))) == stage.Queued
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 2, _, _) -> ticket == ticket_of("c1")
      _ -> False
    }
  })
}

pub fn a_start_failure_names_the_assignment_and_is_capped_test() {
  let started = run(fresh(), [arrival(owner("c1")), accept("c1")])
  assert engine.apply(started, event.WorkerFailed(ticket_of("c1"), 7, "x"))
    == Error(event.UnknownAssignment(ticket_of("c1"), 7))
  let failed = run(started, [failed_start(string.repeat("w", 500))])
  let assert Some(why) = ticket(failed, ticket_of("c1")).failure
  assert string.length(why) == model.max_reason_chars

  // A second report for an assignment that already ended is out of date.
  assert engine.apply(failed, failed_start("again"))
    == Error(event.Stale(ticket_of("c1")))
}

// A ticket that is already in line for a worker has nothing to retry.
pub fn a_ticket_already_in_line_cannot_be_retried_test() {
  let full = full_with_a_fourth_waiting()
  assert engine.apply(
      full,
      event.RetryRequested(ticket_of("c4"), world_principal()),
    )
    == Error(event.AlreadyWanted(ticket_of("c4")))
}

// --- the actions a ticket lists ---------------------------------------------------------

fn actions_of(current: state.State, name: String) -> List(action.Action) {
  action.available(ticket(current, ticket_of(name)))
}

pub fn the_engine_lists_what_a_person_can_do_with_a_ticket_test() {
  // A running worker with no question offers close and stop.
  let live = working()
  assert actions_of(live, "c1") == [action.Close, action.Stop]

  // A failed start offers a retry, and a question offers an answer.
  let failed = run(live, [event.WorkerFailed(ticket_of("c1"), 1, "no clone")])
  assert actions_of(failed, "c1") == [action.Close, action.Retry, action.Stop]
  let asking =
    run(live, [
      event.Reported(ticket_of("c1"), 1, Waiting(Asking(4)), model.NoHead),
    ])
  assert actions_of(asking, "c1") == [action.Answer, action.Close, action.Stop]

  // A ticket in review with a head offers a retry and a publish.
  let review = run(live, [rests_in_review("c1")])
  assert actions_of(review, "c1")
    == [action.Close, action.Retry, action.Publish, action.Stop]

  // An ended ticket offers only a stop, and a stopped one nothing.
  let closed = run(review, [close("c1")])
  assert actions_of(closed, "c1") == [action.Stop]
  let stopped =
    run(review, [event.PersonStopped(ticket_of("c1"), world_principal())])
  assert actions_of(stopped, "c1") == []
}

// --- closing a ticket -------------------------------------------------------------------

fn close(name: String) -> event.Event {
  event.PersonClosed(ticket_of(name), world_principal())
}

// A person who accepts the work closes the ticket. It ends as closed, its
// rested session is stopped, and, unlike a stop, the mandate stands.
pub fn a_persons_close_ends_the_ticket_and_keeps_the_mandate_test() {
  let rested = run(working(), [rests_in_review("c1")])
  let #(closed, effects) = step(rested, close("c1"))
  let ended = ticket(closed, ticket_of("c1"))
  assert ended.outcome == Some(model.Closed)
  assert ended.authority == state.Granted
  assert state.stage_of(ended) == stage.StageEnded(model.Closed)
  assert effects == [StopSession(ticket_of("c1"), 1)]

  // Nothing of the ticket holds a slot, and a rested assignment now reads as
  // an exit, so the next one will not be seated in a stopped session.
  assert list.map(ended.assignments, fn(each) { each.status })
    == [state.AssignmentDone(model.SessionExited)]
}

// A ticket whose worker is still running is stopped and freed by a close, and
// the slot goes to the next ticket in line.
pub fn closing_a_running_ticket_frees_its_slot_test() {
  let full = full_with_a_fourth_waiting()
  let #(closed, effects) = step(full, close("c1"))
  assert ticket(closed, ticket_of("c1")).outcome == Some(model.Closed)
  assert state.active_assignment(ticket(closed, ticket_of("c1"))) == None
  assert list.contains(effects, StopSession(ticket_of("c1"), 1))
  assert state.active_assignment(ticket(closed, ticket_of("c4"))) != None
}

// A later message the router resumes the ticket with reopens it, which a stop
// never allows.
pub fn a_closed_ticket_can_be_resumed_and_a_stopped_one_cannot_test() {
  let rested = run(working(), [rests_in_review("c1")])
  let closed =
    run(rested, [close("c1"), event.RouterTurnEnded, arrival(owner("c2"))])
  let resume =
    event.Routed(model.Routing(
      TriggerId("c2"),
      model.Resume(ticket_of("c1")),
      [],
      [],
      None,
    ))
  let #(reopened, effects) = step(closed, resume)
  assert ticket(reopened, ticket_of("c1")).outcome == None
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 2, _, _) -> ticket == ticket_of("c1")
      _ -> False
    }
  })

  let stopped =
    run(rested, [
      event.PersonStopped(ticket_of("c1"), world_principal()),
      event.RouterTurnEnded,
      arrival(owner("c2")),
    ])
  assert engine.apply(stopped, resume)
    == Error(event.TicketWithdrawn(ticket_of("c1")))
}

pub fn only_an_open_ticket_can_be_closed_test() {
  let rested = run(working(), [rests_in_review("c1")])
  let closed = run(rested, [close("c1")])
  assert engine.apply(closed, close("c1"))
    == Error(event.TicketEnded(ticket_of("c1")))
  let stopped =
    run(rested, [event.PersonStopped(ticket_of("c1"), world_principal())])
  assert engine.apply(stopped, close("c1"))
    == Error(event.TicketWithdrawn(ticket_of("c1")))
  assert engine.apply(rested, close("nobody"))
    == Error(event.UnknownTicket(ticket_of("nobody")))
}

// A worker that lets a ticket go has ended it, and its session and slot go
// with it like any other end.
pub fn a_dropped_ticket_frees_its_slot_test() {
  let full = full_with_a_fourth_waiting()
  let #(dropped, effects) =
    step(full, event.Reported(ticket_of("c1"), 1, model.Dropped, model.NoHead))
  assert ticket(dropped, ticket_of("c1")).outcome == Some(model.Abandoned)
  assert list.contains(effects, StopSession(ticket_of("c1"), 1))
  assert state.active_assignment(ticket(dropped, ticket_of("c4"))) != None
}

pub fn a_freed_slot_goes_to_the_waiting_ticket_oldest_person_first_test() {
  let full =
    run(automated(), [
      arrival(owner("c1")),
      arrival(owner("c2")),
      arrival(world.overheard("o1", "t1")),
      arrival(owner("c3")),
      accept("c1"),
      event.RouterTurnEnded,
      accept("c2"),
      accept("o1"),
      accept("c3"),
    ])
  let #(_, effects) =
    step(full, event.AssignmentEnded(ticket_of("c1"), 1, model.SessionExited))
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(ticket, 1, _, _) -> ticket == ticket_of("o1")
      _ -> False
    }
  })
}

// --- done means verified ---------------------------------------------------------------

pub fn an_idle_worker_with_a_new_head_requests_one_check_test() {
  let report = waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion)
  let #(checked, effects) = step(working(), report)
  assert effects == [RequestCheck(ticket_of("c1"), CommitId("a"))]
  let #(_, again) = step(checked, report)
  assert again == []
}

pub fn an_open_question_or_a_busy_worker_requests_no_check_test() {
  let asking = waiting_report(head_at("a", ProtectedPathsUntouched), Asking(1))
  assert step(working(), asking).1 == []
  let busy =
    event.Reported(
      ticket_of("c1"),
      1,
      model.Progress,
      head_at("a", ProtectedPathsUntouched),
    )
  assert step(working(), busy).1 == []
}

pub fn an_idle_report_with_no_head_asks_the_host_to_read_the_branch_test() {
  let #(_, effects) = step(working(), waiting_report(model.NoHead, NoQuestion))
  assert effects == [event.ObserveHead(ticket_of("c1"), 1)]
}

// The head the host read is what a check is requested for, and a repeated
// reading of the same head asks for nothing.
pub fn an_observed_head_requests_one_check_test() {
  let idle = run(working(), [waiting_report(model.NoHead, NoQuestion)])
  let observed = observed_head("a", ProtectedPathsUntouched)
  let #(checked, effects) = step(idle, observed)
  assert effects == [RequestCheck(ticket_of("c1"), CommitId("a"))]
  assert ticket(checked, ticket_of("c1")).head == Some(CommitId("a"))
  let #(_, again) = step(checked, observed)
  assert again == []
}

// The protected paths are decided before the check is: a head that touches one
// goes to a person and no check is requested for it.
pub fn an_observed_head_on_protected_paths_runs_no_check_test() {
  let idle = run(working(), [waiting_report(model.NoHead, NoQuestion)])
  let #(next, effects) = step(idle, observed_head("a", ProtectedPathsTouched))
  assert effects == []
  let held = ticket(next, ticket_of("c1"))
  assert held.readiness == readiness.AwaitingReview
  assert state.stage_of(held) == stage.PersonReview

  // A passing check for that head is refused: none was requested.
  assert engine.apply(next, passed("a")) == Error(event.Stale(ticket_of("c1")))
}

// A head read after the worker has gone back to work, or asked something, is
// a reading of work in flight, and the engine refuses it.
pub fn an_observed_head_is_stale_once_the_worker_moved_on_test() {
  let busy =
    run(working(), [
      waiting_report(model.NoHead, NoQuestion),
      event.Reported(ticket_of("c1"), 1, model.Progress, model.NoHead),
    ])
  assert engine.apply(busy, observed_head("a", ProtectedPathsUntouched))
    == Error(event.Stale(ticket_of("c1")))
  let asking = run(working(), [waiting_report(model.NoHead, Asking(2))])
  assert engine.apply(asking, observed_head("a", ProtectedPathsUntouched))
    == Error(event.Stale(ticket_of("c1")))
}

// A commit made after a pass is seen at the next idle report, and the pass it
// invalidates cannot reach a pull request.
pub fn a_later_observed_commit_invalidates_ready_and_asks_for_a_new_check_test() {
  let ready =
    run(
      working(),
      list.flatten([
        [
          waiting_report(model.NoHead, NoQuestion),
          observed_head("a", ProtectedPathsUntouched),
          passed("a"),
        ],
        second_worker(),
        [
          event.Reported(ticket_of("c1"), 2, Waiting(NoQuestion), model.NoHead),
        ],
      ]),
    )
  assert readiness.vouches_for(ticket(ready, ticket_of("c1")).readiness)
    == Some(CommitId("a"))
  let #(moved, effects) =
    step(
      ready,
      event.HeadObserved(
        ticket_of("c1"),
        2,
        head_at("b", ProtectedPathsUntouched),
      ),
    )
  assert effects == [RequestCheck(ticket_of("c1"), CommitId("b"))]
  assert ticket(moved, ticket_of("c1")).readiness == readiness.InProgress
  assert engine.apply(moved, passed("a")) == Error(event.Stale(ticket_of("c1")))
}

fn observed_head(commit: String, paths: model.PathScope) -> event.Event {
  event.HeadObserved(ticket_of("c1"), 1, head_at(commit, paths))
}

// The host's reason for asking a person is about one commit.
pub fn a_review_request_holds_until_the_head_moves_test() {
  let ready =
    run(working(), [
      waiting_report(model.NoHead, NoQuestion),
      observed_head("a", ProtectedPathsUntouched),
      passed("a"),
    ])
  let off =
    event.ReviewRequested(ticket_of("c1"), CommitId("a"), model.PublishingOff)
  let #(asked, effects) = step(ready, off)
  assert effects == []
  let held = ticket(asked, ticket_of("c1"))
  assert held.review == Some(model.PublishingOff)
  assert state.stage_of(held) == stage.PersonReview

  // It keeps what the pass earned.
  assert readiness.vouches_for(held.readiness) == Some(CommitId("a"))

  // A reason about a commit that is not the head is stale.
  assert engine.apply(
      ready,
      event.ReviewRequested(ticket_of("c1"), CommitId("z"), model.PublishingOff),
    )
    == Error(event.Stale(ticket_of("c1")))

  // A new commit clears the reason along with the pass.
  let moved =
    run(
      asked,
      list.flatten([
        second_worker(),
        [
          event.Reported(ticket_of("c1"), 2, Waiting(NoQuestion), model.NoHead),
          event.HeadObserved(
            ticket_of("c1"),
            2,
            head_at("b", ProtectedPathsUntouched),
          ),
        ],
      ]),
    )
  assert ticket(moved, ticket_of("c1")).review == None
}

// Without a check there is nothing to vouch for the work, so a ticket still in
// progress waits for a person.
pub fn a_review_request_without_a_check_sends_the_ticket_to_review_test() {
  let idle =
    run(working(), [
      waiting_report(model.NoHead, NoQuestion),
      observed_head("a", ProtectedPathsUntouched),
    ])
  let #(asked, _) =
    step(
      idle,
      event.ReviewRequested(
        ticket_of("c1"),
        CommitId("a"),
        model.NoCheckConfigured,
      ),
    )
  let held = ticket(asked, ticket_of("c1"))
  assert held.readiness == readiness.AwaitingReview
  assert state.stage_of(held) == stage.PersonReview
}

pub fn protected_paths_go_to_review_and_run_no_check_test() {
  let report = waiting_report(head_at("a", ProtectedPathsTouched), NoQuestion)
  let #(next, effects) = step(working(), report)
  assert effects == []
  let held = ticket(next, ticket_of("c1"))
  assert held.readiness == readiness.AwaitingReview
  assert state.stage_of(held) == stage.PersonReview
}

pub fn a_passing_check_makes_the_ticket_ready_and_opens_a_pull_request_test() {
  let checked =
    run(working(), [
      waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion),
    ])
  let #(ready, effects) = step(checked, passed("a"))
  assert effects
    == [PublishBranch(ticket_of("c1"), "project/t-c1", CommitId("a"))]
  let held = ticket(ready, ticket_of("c1"))
  assert readiness.vouches_for(held.readiness) == Some(CommitId("a"))
  let opened =
    run(ready, [
      event.PullRequestOpened(ticket_of("c1"), model.PullRequestRef("url")),
    ])
  assert state.stage_of(ticket(opened, ticket_of("c1"))) == stage.PersonReview
}

pub fn a_check_that_nobody_requested_cannot_make_a_ticket_ready_test() {
  assert engine.apply(working(), passed("a"))
    == Error(event.Stale(ticket_of("c1")))
  let moved =
    run(working(), [
      waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion),
      event.Reported(
        ticket_of("c1"),
        1,
        model.Progress,
        head_at("b", ProtectedPathsUntouched),
      ),
    ])
  assert engine.apply(moved, passed("a")) == Error(event.Stale(ticket_of("c1")))
}

pub fn a_later_commit_invalidates_a_passed_check_test() {
  let ready =
    run(working(), [
      waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion),
      passed("a"),
    ])
  let moved =
    run(
      ready,
      list.append(second_worker(), [
        event.Reported(
          ticket_of("c1"),
          2,
          model.Progress,
          head_at("b", ProtectedPathsUntouched),
        ),
      ]),
    )
  assert ticket(moved, ticket_of("c1")).readiness == readiness.InProgress
  assert engine.apply(
      moved,
      event.PullRequestOpened(ticket_of("c1"), model.PullRequestRef("url")),
    )
    == Error(event.NotPublishable(ticket_of("c1")))
}

pub fn a_person_may_publish_past_a_failing_check_test() {
  let failed =
    run(working(), [
      waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion),
      event.CheckFinished(
        ticket_of("c1"),
        event.CheckRejected(CommitId("a"), model.CommandDigest("d")),
      ),
    ])
  let by = world_principal()
  let #(published, effects) =
    step(failed, event.PersonPublished(ticket_of("c1"), by, CommitId("a")))
  assert effects
    == [PublishBranch(ticket_of("c1"), "project/t-c1", CommitId("a"))]
  assert ticket(published, ticket_of("c1")).readiness
    == readiness.Published(by, CommitId("a"))
  assert engine.apply(
      failed,
      event.PersonPublished(ticket_of("c1"), by, CommitId("zzz")),
    )
    == Error(event.Stale(ticket_of("c1")))
}

// --- lifecycle ---------------------------------------------------------------------------

pub fn a_retry_makes_a_second_assignment_with_its_own_key_test() {
  let ended =
    run(working(), [
      event.AssignmentEnded(ticket_of("c1"), 1, model.SessionCrashed),
    ])
  assert state.stage_of(ticket(ended, ticket_of("c1"))) == stage.Idle
  let #(retried, effects) =
    step(ended, event.RetryRequested(ticket_of("c1"), world_principal()))
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(_, 2, key, _) -> key == "project:p1:t-c1:2"
      _ -> False
    }
  })

  // The new worker is told what the ticket was opened for, because the first
  // session took the opening message with it.
  assert list.contains(effects, Deliver(ticket_of("c1"), 2, TriggerId("c1")))
  assert engine.apply(
      retried,
      event.RetryRequested(ticket_of("c1"), world_principal()),
    )
    == Error(event.AssignmentActive(ticket_of("c1")))
}

pub fn a_session_binds_once_test() {
  let bound =
    run(working(), [
      event.SessionBound(ticket_of("c1"), 1, model.SessionId("s-1")),
    ])
  assert engine.apply(
      bound,
      event.SessionBound(ticket_of("c1"), 1, model.SessionId("s-2")),
    )
    == Error(event.Stale(ticket_of("c1")))
  assert engine.apply(
      bound,
      event.SessionBound(ticket_of("c1"), 1, model.SessionId("s-1")),
    )
    == Ok(#(bound, []))
}

pub fn a_merged_ticket_resumes_when_someone_comments_test() {
  let merged =
    run(working(), [
      event.AssignmentEnded(ticket_of("c1"), 1, model.SessionExited),
      event.Concluded(ticket_of("c1"), model.Merged),
      event.RouterTurnEnded,
    ])
  assert state.stage_of(ticket(merged, ticket_of("c1")))
    == stage.StageEnded(model.Merged)
  let asked = run(merged, [arrival(world.addressed("r1", "th-c1", "me"))])
  let #(resumed, effects) = step(asked, step_resume("r1"))
  assert list.any(effects, fn(effect) {
    case effect {
      StartSession(_, 2, _, _) -> True
      _ -> False
    }
  })
  assert ticket(resumed, ticket_of("c1")).outcome == None
}

pub fn a_conclusion_cannot_be_a_stop_test() {
  assert engine.apply(
      working(),
      event.Concluded(ticket_of("c1"), model.StoppedByPerson),
    )
    == Error(event.NotAConclusion(ticket_of("c1")))
}

pub fn a_failed_input_asks_a_person_until_it_arrives_test() {
  let failed =
    run(working(), [event.InputFailed(ticket_of("c1"), TriggerId("c1"))])
  assert state.stage_of(ticket(failed, ticket_of("c1"))) == stage.PersonDelivery
  let fixed =
    run(failed, [event.InputDelivered(ticket_of("c1"), TriggerId("c1"))])
  assert state.stage_of(ticket(fixed, ticket_of("c1"))) == stage.Working
}

pub fn an_answer_must_echo_the_open_question_test() {
  let asking =
    run(working(), [
      event.Reported(ticket_of("c1"), 1, Waiting(Asking(4)), model.NoHead),
    ])
  assert state.stage_of(ticket(asking, ticket_of("c1"))) == stage.PersonAnswer
  assert engine.apply(
      asking,
      event.Answered(ticket_of("c1"), 3, world_principal()),
    )
    == Error(event.StaleAnswer(ticket_of("c1")))
  let #(answered, effects) =
    step(asking, event.Answered(ticket_of("c1"), 4, world_principal()))
  assert effects
    == [event.Deliver(ticket_of("c1"), 1, model.answer_id(ticket_of("c1"), 4))]
  assert state.stage_of(ticket(answered, ticket_of("c1"))) == stage.Idle
}

// --- an answer reaches the worker --------------------------------------------------------

pub fn an_answer_with_no_live_worker_waits_for_the_next_assignment_test() {
  let asked =
    run(working(), [
      event.Reported(ticket_of("c1"), 1, Waiting(Asking(4)), model.NoHead),
      event.AssignmentEnded(ticket_of("c1"), 1, model.SessionCrashed),
    ])
  let #(answered, effects) =
    step(asked, event.Answered(ticket_of("c1"), 4, world_principal()))

  // Nothing is delivered, because nobody is there to receive it, and nothing
  // is lost: the answer waits in the ticket's inbox.
  assert effects == []
  let answer = model.answer_id(ticket_of("c1"), 4)
  assert list.contains(ticket(answered, ticket_of("c1")).inbox, answer)

  // The next assignment is started with the answer delivered to it.
  let #(_, retried) =
    step(answered, event.RetryRequested(ticket_of("c1"), world_principal()))
  assert list.contains(retried, Deliver(ticket_of("c1"), 2, answer))
}

// --- the router's second chances are bounded ----------------------------------------------

fn turns_ended(current: state.State, turns: Int) -> state.State {
  case turns {
    0 -> current
    _ -> turns_ended(run(current, [event.RouterTurnEnded]), turns - 1)
  }
}

fn resume_c1(trigger: String) -> event.Event {
  event.Routed(model.Routing(
    TriggerId(trigger),
    model.Resume(ticket_of("c1")),
    [],
    [],
    None,
  ))
}

// A router that resumes a stopped ticket is refused, and the refused candidate
// is still the router's: it stays offered, the project queues everything else
// behind it, and a person's requeue is refused too, because the trigger is
// not waiting. Nothing about that is a loss. The router's turn ending is what
// frees it, and each end offers it again until its offers are spent, when it is
// a visible record that a person can queue again.
pub fn a_refused_resume_leaves_the_candidate_with_the_router_until_its_turn_ends_test() {
  let stopped =
    run(working(), [
      event.PersonStopped(ticket_of("c1"), world_principal()),
      event.RouterTurnEnded,
      arrival(owner("c2")),
    ])
  assert engine.apply(stopped, resume_c1("c2"))
    == Error(event.TicketWithdrawn(ticket_of("c1")))
  assert stopped.offered == [TriggerId("c2")]
  assert stopped.router == state.RouterBusy

  // A later post queues behind the held batch, and a requeue of the held
  // candidate is refused rather than ignored.
  let behind = run(stopped, [arrival(owner("c3"))])
  assert behind.queue == [TriggerId("c3")]
  assert engine.apply(
      behind,
      event.Requeued(TriggerId("c2"), world_principal()),
    )
    == Error(event.NotRequeueable(TriggerId("c2")))

  // The turn ends: the refused candidate goes to the back of the queue and the
  // waiting one is offered first.
  let #(first, effects) = step(behind, event.RouterTurnEnded)
  assert effects == [OfferCandidates([TriggerId("c3"), TriggerId("c2")])]
  assert state.offer_count(first, TriggerId("c2")) == 2

  // Refused twice more, it is a record for a person and not a stranded batch.
  let spent = turns_ended(first, 3)
  assert spent.router == state.RouterIdle
  assert list.map(state.unrouted(spent), fn(each) { each.trigger.id })
    == [TriggerId("c2"), TriggerId("c3")]
  let #(_, again) =
    step(spent, event.Requeued(TriggerId("c2"), world_principal()))
  assert again == [OfferCandidates([TriggerId("c2")])]
}

pub fn a_candidate_offered_three_times_without_a_decision_waits_for_a_person_test() {
  let offered = run(fresh(), [arrival(owner("c1"))])
  assert state.offer_count(offered, TriggerId("c1")) == 1

  // The first two turns that end with no decision offer the candidate again.
  let twice = turns_ended(offered, 2)
  assert state.offer_count(twice, TriggerId("c1")) == queue.max_offers
  assert twice.offered == [TriggerId("c1")]

  // The third turn is the last: the candidate is recorded as unrouted and the
  // router is offered nothing.
  let #(settled, effects) = step(twice, event.RouterTurnEnded)
  assert effects == []
  assert settled.offered == []
  assert settled.queue == []
  assert settled.router == state.RouterIdle
  let assert Ok(stored) = state.record(settled, TriggerId("c1")) as "stored"
  assert stored.fate
    == state.Decided(state.Unrouted(state.NoDecision(queue.max_offers)))
  assert list.map(state.unrouted(settled), fn(each) { each.trigger.id })
    == [TriggerId("c1")]

  // The router can no longer route it, and a person can queue it again.
  assert engine.apply(settled, accept("c1"))
    == Error(event.NotOffered(TriggerId("c1")))
  let #(again, offers) =
    step(settled, event.Requeued(TriggerId("c1"), world_principal()))
  assert offers == [OfferCandidates([TriggerId("c1")])]
  assert state.offer_count(again, TriggerId("c1")) == 1
  assert state.unrouted(again) == []

  // And the requeued candidate can be accepted like any other.
  let accepted = run(again, [accept("c1")])
  assert dict.size(accepted.tickets) == 1
}

// A candidate the router decides is never counted against it, however many
// turns end afterwards.
pub fn a_decided_candidate_is_never_unrouted_test() {
  let decided =
    run(fresh(), [arrival(owner("c1")), accept("c1"), event.RouterTurnEnded])
  let assert Ok(stored) = state.record(decided, TriggerId("c1")) as "stored"
  assert stored.fate == state.Decided(state.Accepted(ticket_of("c1")))
  assert state.unrouted(turns_ended(decided, 5)) == []
}

pub fn replaying_the_log_rebuilds_the_state_test() {
  let events = [
    arrival(owner("c1")),
    accept("c1"),
    event.AssignmentLive(ticket_of("c1"), 1),
    waiting_report(head_at("a", ProtectedPathsUntouched), NoQuestion),
  ]
  assert engine.replay(world.config(), events) == Ok(run(fresh(), events))
  let broken =
    list.append(events, [accept("c1"), attach("zz", ticket_of("c1"))])
  assert engine.replay(world.config(), broken)
    == Error(engine.ReplayFailure(5, event.UnknownTrigger(TriggerId("zz"))))
}

// --- an actor's rate and a pull request's thread -------------------------------------

// A project whose queue is long enough that only the actor's rate cap can shed.
fn roomy() -> state.State {
  run(state.start(state.Config(..world.config(), queue_limit: 100)), [
    event.ModeSet(world.source, world.rule, model.Observe),
    arrival(owner("c0")),
  ])
}

fn comments_from(actor: String, count: Int) -> List(event.Event) {
  counted(count)
  |> list.map(fn(n) {
    let id = actor <> int_text(n)
    arrival(world.trigger(
      id,
      "th-" <> id,
      actor,
      model.Person,
      model.Unaddressed,
      world.matched(),
      0,
    ))
  })
}

pub fn an_actor_past_the_rate_cap_is_shed_and_others_are_not_test() {
  let busy = run(roomy(), comments_from("pat", queue.actor_cap))
  assert fate_of(busy, "pat01") == state.Awaiting

  // The next comment from the same actor is shed and recorded as shed, and a
  // different actor's comment is queued as usual.
  let next = run(busy, [last_of("pat", queue.actor_cap + 1)])
  assert fate_of(next, "pat" <> int_text(queue.actor_cap + 1))
    == state.Decided(state.Shed)
  let other = run(next, comments_from("quinn", 1))
  assert fate_of(other, "quinn01") == state.Awaiting
}

fn last_of(actor: String, position: Int) -> event.Event {
  let id = actor <> int_text(position)
  arrival(world.trigger(
    id,
    "th-" <> id,
    actor,
    model.Person,
    model.Unaddressed,
    world.matched(),
    0,
  ))
}

pub fn a_pull_request_opens_a_thread_the_ticket_follows_test() {
  let ready =
    run(working(), [
      waiting_report(head_at("abc", ProtectedPathsUntouched), NoQuestion),
      passed("abc"),
    ])
  let #(opened, _) =
    step(
      ready,
      event.PullRequestOpened(
        ticket_of("c1"),
        model.PullRequestRef("https://github.com/o/r/pull/7"),
      ),
    )
  assert list.contains(
    opened.subscriptions,
    model.Subscription(ticket_of("c1"), model.ThreadId("gh-7")),
  )
}
