//// The engine, scenario by scenario: each test names one rule of the design
//// note and drives the smallest event sequence that shows it.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/engine
import project/event.{
  AcceptRefused, Deliver, OfferCandidates, OpenPullRequest, RequestCheck,
  StartSession, StopSession,
}
import project/gate
import project/host
import project/model.{
  Asking, CommitId, Head, NoQuestion, ProtectedPathsTouched,
  ProtectedPathsUntouched, TicketId, TriggerId, Waiting,
}
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
      event.VerdictRecorded(world.source, world.rule, "v1", model.VerdictFailed),
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
  assert step(working(), waiting_report(model.NoHead, NoQuestion)).1 == []
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
    == [OpenPullRequest(ticket_of("c1"), "project/t-c1", CommitId("a"))]
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
    run(ready, [
      event.Reported(
        ticket_of("c1"),
        1,
        model.Progress,
        head_at("b", ProtectedPathsUntouched),
      ),
    ])
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
    == [OpenPullRequest(ticket_of("c1"), "project/t-c1", CommitId("a"))]
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
  assert effects == [event.RelayAnswer(ticket_of("c1"), 1, 4)]
  assert state.stage_of(ticket(answered, ticket_of("c1"))) == stage.Idle
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
