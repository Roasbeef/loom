//// Choosing an executor for a session's workspace, over real hosts and ledgers
//// in one VM (protocol-change/078, executor pools).
////
//// Each executor is the real host with a fake plane and a scope limit of one,
//// started under its own name, so a full executor is made by attaching one
//// other session to it. The tests prove the rules of placement: candidates are
//// tried in the declared order, only a first open moves on, a record that
//// names an executor is never re-picked, a declaration that the census
//// contradicts closes the scope, and the executor chosen is reported.

import client/executors
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session/session
import support/remote_fixtures as fixtures
import support/remote_orchestrator as rig

fn store() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the store opens"
  opened
}

// One executor that admits `scopes` scopes, with the probe that counts its
// plane builds and closes.
fn executor_of(scopes: Int) -> #(fixtures.Probe, rig.Executor) {
  let probe = fixtures.probe(fixtures.Open)
  #(
    probe,
    rig.start_limited(
      rig.factory(
        probe,
        rig.census(1000, rig.standard_tools()),
        protocol.AllRetired,
      ),
      scopes:,
    ),
  )
}

// The names the catalogue was told, newest first, through a subject so the
// placement's callback stays a plain function.
fn heard() -> #(fn(String) -> Nil, fn() -> List(String)) {
  let told = process.new_subject()
  #(fn(name) { process.send(told, name) }, fn() { drain(told, []) })
}

fn drain(told: process.Subject(String), found: List(String)) -> List(String) {
  case process.receive(told, 50) {
    Ok(name) -> drain(told, [name, ..found])
    Error(Nil) -> found
  }
}

fn open(
  placement: workspace.Placement,
  opened: session.Session,
  session session_name: String,
) -> Result(workspace.Hands, String) {
  workspace.attach(
    workspace.Registered(
      ..rig.registered_in(placement, opened, clock.fixed(at: 1000)),
      session: session_name,
    ),
  )
}

fn only(name: String, executor: rig.Executor) -> workspace.Placement {
  rig.placement_of([rig.candidate(name, executor)], fn(_name) { Nil })
}

// Fills the executor's only slot with a session that is not the one under test.
fn occupy(name: String, executor: rig.Executor, session: String) {
  let assert Ok(hands) = open(only(name, executor), store(), session:)
    as "the filler attaches"
  hands
}

pub fn the_first_candidate_takes_the_session_when_it_has_room_test() {
  let #(probe_a, a) = executor_of(1)
  let #(probe_b, b) = executor_of(1)
  let #(chosen, told) = heard()
  let opened = store()
  let placement =
    rig.placement_of([rig.candidate("a", a), rig.candidate("b", b)], chosen)

  let assert Ok(hands) = open(placement, opened, session: "s")

  assert hands.incarnation == 1
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("a"))))
  assert told() == ["a"]
  assert list.length(fixtures.builds(probe_a)) == 1
  assert fixtures.builds(probe_b) == []
  rig.stop(a)
  rig.stop(b)
}

pub fn a_pool_moves_past_a_full_executor_in_declared_order_test() {
  let #(probe_a, a) = executor_of(1)
  let #(probe_b, b) = executor_of(1)
  let _taken = occupy("a", a, "someone-else")
  let #(chosen, told) = heard()
  let opened = store()
  let placement =
    rig.placement_of([rig.candidate("a", a), rig.candidate("b", b)], chosen)

  let assert Ok(hands) = open(placement, opened, session: "s")

  // The refusal came before any plane was built, so a built only the
  // filler's, and the record names the executor that took the session.
  assert hands.incarnation == 1
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("b"))))
  assert told() == ["b"]
  assert list.length(fixtures.builds(probe_a)) == 1
  assert list.length(fixtures.builds(probe_b)) == 1
  rig.stop(a)
  rig.stop(b)
}

pub fn an_executor_that_cannot_be_connected_is_skipped_test() {
  let #(_probe_a, a) = executor_of(1)
  let #(_probe_b, b) = executor_of(1)
  let down =
    rig.candidate_over(
      "a",
      workspace.Reach(..rig.reach(a), connect: fn() { Error("no route to a") }),
    )
  let opened = store()
  let placement =
    rig.placement_of([down, rig.candidate("b", b)], fn(_name) { Nil })

  let assert Ok(_hands) = open(placement, opened, session: "s")

  // The attach was never sent to a, and a record that named it would have sent
  // every later open back to a machine that was down.
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("b"))))
  rig.stop(a)
  rig.stop(b)
}

pub fn a_session_with_no_room_anywhere_fails_and_keeps_no_record_test() {
  let #(_probe_a, a) = executor_of(1)
  let #(_probe_b, b) = executor_of(1)
  let filler_a = occupy("a", a, "taken-a")
  let _filler_b = occupy("b", b, "taken-b")
  let opened = store()
  let placement =
    rig.placement_of([rig.candidate("a", a), rig.candidate("b", b)], fn(_name) {
      Nil
    })

  let assert Error(reason) = open(placement, opened, session: "s")

  assert string.starts_with(
    reason,
    "executor_unavailable: no executor accepted the session: a: ",
  )
  assert string.contains(reason, "; b: ")
  assert string.contains(reason, "already holds 1 scopes")

  // Neither executor created a scope, so the record that named the last one is
  // withdrawn and the next open chooses again from the whole pool.
  assert scope.read(opened) == Ok(None)
  filler_a.plane.close()
  let assert Ok(hands) = open(placement, opened, session: "s")
  assert hands.incarnation == 1
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("a"))))
  rig.stop(a)
  rig.stop(b)
}

pub fn a_single_candidate_keeps_the_plain_refusal_test() {
  let #(_probe_a, a) = executor_of(1)
  let _taken = occupy("a", a, "taken")
  let opened = store()

  let assert Error(reason) = open(only("a", a), opened, session: "s")

  assert reason
    == "executor_unavailable: the executor already holds 1 scopes that are not cleanly closed"
  assert scope.read(opened) == Ok(None)
  rig.stop(a)
}

pub fn a_reopen_into_a_full_executor_never_moves_to_another_test() {
  let #(_probe_a, a) = executor_of(1)
  let #(probe_b, b) = executor_of(1)
  let filler_a = occupy("a", a, "taken-a")
  let opened = store()
  let placement =
    rig.placement_of([rig.candidate("a", a), rig.candidate("b", b)], fn(_name) {
      Nil
    })

  // The session lands on b because a is full. It is then closed cleanly, which
  // frees b's slot, and another session takes the slot, while a has room again.
  let assert Ok(first) = open(placement, opened, session: "s")
  first.plane.close()
  assert scope.read(opened)
    == Ok(Some(scope.Scope(1, Some(protocol.AllRetired), Some("b"))))
  let _taken = occupy("b", b, "taken-b")
  filler_a.plane.close()

  let assert Error(reason) = open(placement, opened, session: "s")

  // The checkout is on b, so a full b is a failure and not a reason to look
  // elsewhere, however much room a has.
  assert string.starts_with(reason, "executor_unavailable: ")
  assert string.contains(reason, "already holds 1 scopes")
  assert string.contains(reason, "no executor accepted") == False
  assert scope.executor_of(scope.read(opened) |> option_of) == Some("b")
  assert list.length(fixtures.builds(probe_b)) == 2
  rig.stop(a)
  rig.stop(b)
}

fn option_of(read: Result(option.Option(scope.Scope), String)) {
  let assert Ok(found) = read
  found
}

pub fn a_bound_executor_that_is_down_is_not_replaced_test() {
  let #(_probe_a, a) = executor_of(1)
  let #(probe_b, b) = executor_of(1)
  let opened = store()
  let assert Ok(Nil) = scope.write(opened, scope.Scope(1, None, Some("a")))
  let down =
    rig.candidate_over(
      "a",
      workspace.Reach(..rig.reach(a), connect: fn() { Error("a is down") }),
    )
  let placement =
    rig.placement_of([down, rig.candidate("b", b)], fn(_name) { Nil })

  let assert Error(reason) = open(placement, opened, session: "s")

  assert reason == "executor_unavailable: a is down"
  assert fixtures.builds(probe_b) == []
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("a"))))
  rig.stop(a)
  rig.stop(b)
}

pub fn an_attach_whose_reply_is_lost_reopens_the_same_executor_and_rebinds_test() {
  let #(probe_a, a) = executor_of(1)
  let #(probe_b, b) = executor_of(1)
  let proxy = rig.lossy_link(a)
  let broken =
    rig.candidate_over(
      "a",
      workspace.Reach(
        ..rig.reach(proxy),
        connect: rig.one_connection(),
        attach_within_ms: 300,
      ),
    )
  let #(chosen, told) = heard()
  let opened = store()

  // The executor attached the scope and the link broke before it said so. The
  // open fails and does not go to b, because a may hold the scope.
  let assert Error(reason) =
    open(
      rig.placement_of([broken, rig.candidate("b", b)], chosen),
      opened,
      session: "s",
    )
  assert string.starts_with(reason, "executor_unavailable: ")
  assert string.contains(reason, "no answer to the attach")
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("a"))))
  assert told() == []
  assert fixtures.eventually(fn() { list.length(fixtures.builds(probe_a)) == 1 })

  // The retry names a again, now over a link that works, and the ledger rebinds
  // the open scope at the same incarnation instead of a second one appearing on
  // b. b is listed first here, so an open that chose again would take it.
  let assert Ok(hands) =
    open(
      rig.placement_of([rig.candidate("b", b), rig.candidate("a", a)], chosen),
      opened,
      session: "s",
    )
  assert hands.incarnation == 1
  assert scope.read(opened) == Ok(Some(scope.Scope(1, None, Some("a"))))
  assert told() == ["a"]
  assert fixtures.builds(probe_b) == []
  rig.stop(a)
  rig.stop(b)
}

pub fn a_declaration_the_census_contradicts_closes_the_scope_and_fails_the_open_test() {
  let #(probe_a, a) = executor_of(1)
  let wrong =
    rig.candidate("a", a)
    |> rig.declaring(fn(row) {
      executors.Executor(..row, platform: Some("macos/arm64"))
    })
  let #(chosen, told) = heard()
  let opened = store()
  let placement = rig.placement_of([wrong], chosen)

  let assert Error(reason) = open(placement, opened, session: "s")

  // The reason names both values, and the scope was closed cleanly, which is
  // also what returns its slot.
  assert reason
    == "executor_unavailable: executor a declares platform macos/arm64 but its census reports linux/x86_64"
  assert fixtures.eventually(fn() { fixtures.closes(probe_a) == 1 })
  assert scope.read(opened)
    == Ok(Some(scope.Scope(1, Some(protocol.AllRetired), Some("a"))))
  assert told() == []
  let assert Ok(_other) = open(only("a", a), store(), session: "next")
  rig.stop(a)
}

pub fn a_declaration_the_census_confirms_opens_normally_test() {
  let #(_probe_a, a) = executor_of(1)
  let right =
    rig.candidate("a", a)
    |> rig.declaring(fn(row) {
      executors.Executor(
        ..row,
        platform: Some("linux/x86_64"),
        enforcement: Some(executors.Enforced),
      )
    })

  let assert Ok(_hands) =
    open(rig.placement_of([right], fn(_name) { Nil }), store(), session: "s")

  rig.stop(a)
}

pub fn a_toolchain_the_executor_lacks_is_named_in_the_refusal_test() {
  let #(_probe_a, a) = executor_of(1)
  let claims =
    rig.candidate("a", a)
    |> rig.declaring(fn(row) {
      executors.Executor(..row, toolchains: ["codemode"])
    })

  let assert Error(reason) =
    open(rig.placement_of([claims], fn(_name) { Nil }), store(), session: "s")

  assert reason
    == "executor_unavailable: executor a declares toolchain codemode but its census reports []"
  rig.stop(a)
}

pub fn a_record_that_names_an_unconfigured_executor_fails_the_open_test() {
  let #(_probe_a, a) = executor_of(1)
  let opened = store()
  let assert Ok(Nil) = scope.write(opened, scope.Scope(1, None, Some("gone")))

  let assert Error(reason) = open(only("a", a), opened, session: "s")

  assert reason == "executor_unavailable: no executor named gone"
  rig.stop(a)
}
