//// The state snapshot and the retention rule, scenario by scenario.
////
//// The properties that matter most are checked on every state the engine's
//// model-based test reaches (`machine_test`, `snapshot`); these tests pin the
//// shapes that test is unlikely to build by chance, and what retention keeps.

import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import project/engine
import project/event
import project/host
import project/model.{CommitId, Head, NoQuestion, ProtectedPathsUntouched}
import project/snapshot
import project/state
import support/world.{accept, arrival, fresh, owner, run, ticket_of}

// A state with every kind of record in it: a ticket with a passed check and a
// pull request, a withdrawn one, a stranger's recorded comment, a queued
// candidate, a mode and a verdict.
fn rich() -> state.State {
  run(world.automated(), [
    arrival(owner("c1")),
    accept("c1"),
    event.AssignmentLive(ticket_of("c1"), 1),
    event.Reported(
      ticket_of("c1"),
      1,
      model.Waiting(NoQuestion),
      Head(CommitId("abc"), ProtectedPathsUntouched),
    ),
    event.CheckFinished(
      ticket_of("c1"),
      event.CheckOk(host.passed(
        CommitId("abc"),
        model.CommandDigest("d"),
        model.EntryId("e"),
      )),
    ),
    event.PullRequestOpened(
      ticket_of("c1"),
      model.PullRequestRef("https://github.com/o/r/pull/7"),
    ),
    arrival(world.stranger("s1", "th-s")),
    arrival(world.overheard("o1", "th-o")),
    arrival(owner("c2")),
    event.RouterTurnEnded,
    event.PersonStopped(ticket_of("c1"), model.PrincipalId("owner")),
  ])
}

pub fn a_state_reads_back_exactly_what_was_written_test() {
  let current = rich()
  assert snapshot.decode(world.config(), snapshot.encode(current))
    == Ok(current)
  let empty = fresh()
  assert snapshot.decode(world.config(), snapshot.encode(empty)) == Ok(empty)
}

pub fn the_same_state_always_writes_the_same_text_test() {
  assert snapshot.encode(rich()) == snapshot.encode(rich())
}

pub fn a_document_that_is_not_a_snapshot_is_malformed_test() {
  assert snapshot.decode(world.config(), "nonsense")
    == Error(snapshot.Malformed)
  assert snapshot.decode(world.config(), "{}") == Error(snapshot.Malformed)
  let text = snapshot.encode(rich())
  assert snapshot.decode(world.config(), text <> " trailing")
    == Error(snapshot.Malformed)
}

pub fn a_proof_in_a_document_is_rebuilt_through_the_hosts_door_test() {
  let ready =
    run(world.fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      event.AssignmentLive(ticket_of("c1"), 1),
      event.Reported(
        ticket_of("c1"),
        1,
        model.Waiting(NoQuestion),
        Head(CommitId("abc"), ProtectedPathsUntouched),
      ),
      event.CheckFinished(
        ticket_of("c1"),
        event.CheckOk(host.passed(
          CommitId("abc"),
          model.CommandDigest("d"),
          model.EntryId("e"),
        )),
      ),
    ])
  let assert Ok(back) = snapshot.decode(world.config(), snapshot.encode(ready))
  assert world.ticket(back, ticket_of("c1")).readiness
    == world.ticket(ready, ticket_of("c1")).readiness
}

// --- retention --------------------------------------------------------------------

// An ended ticket, a stranger's recorded comment, and a candidate still waiting
// for the router, all with triggers at time 1000.
fn old_and_new() -> state.State {
  run(fresh(), [
    arrival(owner("c1")),
    accept("c1"),
    event.AssignmentLive(ticket_of("c1"), 1),
    event.Concluded(ticket_of("c1"), model.Merged),
    arrival(world.stranger("s1", "th-s")),
    arrival(owner("c2")),
  ])
}

pub fn retention_drops_what_no_later_event_can_name_and_keeps_the_decision_test() {
  let current = old_and_new()
  let #(kept, retired) = snapshot.retire(current, 2000)

  // The ended ticket, its subscription and its thread are gone, and so is the
  // stranger's settled comment. The candidate still waiting stays.
  assert dict.size(kept.tickets) == 0
  assert kept.subscriptions == []
  assert dict.keys(kept.triggers) == [model.TriggerId("c2")]
  assert dict.keys(kept.threads) == [model.ThreadId("th-c2")]

  // Each dropped trigger keeps what became of it.
  let decisions =
    list.map(retired, fn(each) { #(each.trigger.value, each.decision) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  assert decisions == [#("c1", "accepted"), #("s1", "recorded_only")]
  let assert Ok(accepted) =
    list.find(retired, fn(each) { each.trigger.value == "c1" })
  assert accepted.ticket == Some(ticket_of("c1"))
  assert accepted.at_ms == 1000

  // The smaller state is a state the engine goes on from, and it round-trips.
  let assert Ok(#(next, _)) = engine.apply(kept, event.RouterTurnEnded)
  assert state.record(next, model.TriggerId("c2")) |> result.is_ok
  assert snapshot.decode(world.config(), snapshot.encode(kept)) == Ok(kept)
}

pub fn a_trigger_that_is_not_old_or_that_a_kept_ticket_names_stays_test() {
  let current = old_and_new()

  // Nothing is older than a horizon before the triggers.
  let #(same, none) = snapshot.retire(current, 500)
  assert same == current
  assert none == []

  // An open ticket keeps its origin, its inbox and its thread.
  let open =
    run(fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      event.AssignmentLive(ticket_of("c1"), 1),
    ])
  let #(kept, retired) = snapshot.retire(open, 2000)
  assert kept == open
  assert retired == []
}

pub fn a_candidate_waiting_for_a_person_is_never_retired_test() {
  let waiting =
    run(fresh(), [
      arrival(owner("c1")),
      event.RouterTurnEnded,
      event.RouterTurnEnded,
      event.RouterTurnEnded,
    ])
  let assert Ok(stored) = state.record(waiting, model.TriggerId("c1"))
  let assert state.Decided(state.Unrouted(_)) = stored.fate
  let #(kept, retired) = snapshot.retire(waiting, 2000)
  assert retired == []
  assert dict.has_key(kept.triggers, model.TriggerId("c1"))
}

pub fn a_stopped_ticket_is_retired_with_the_rest_and_never_resumes_test() {
  let stopped =
    run(fresh(), [
      arrival(owner("c1")),
      accept("c1"),
      event.PersonStopped(ticket_of("c1"), model.PrincipalId("owner")),
    ])
  let #(kept, retired) = snapshot.retire(stopped, 2000)
  assert dict.size(kept.tickets) == 0
  assert list.length(retired) == 1
}
