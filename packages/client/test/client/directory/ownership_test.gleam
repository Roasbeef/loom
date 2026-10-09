//// Two orchestrators' ownership values over one directory store
//// (protocol-change/080). Each write names the exact value it expects, so when
//// two daemons race for a session the second finds the record changed and its
//// write fails. The store is a VM-wide singleton, so the module is serial.

import client/directory/ownership
import client/directory/record.{Local, Moving, Record, Serving}
import client/directory/store.{Mismatch}
import gleam/option.{None, Some}
import support/remote_fixtures

const session = "0198c0de-0000-7000-8000-000000000002"

const alpha = "alpha@10.0.0.1"

const bravo = "bravo@10.0.0.4"

const op = "0192f3c1-0000-7000-8000-000000000003"

fn with_store(body: fn() -> Nil) -> Nil {
  let directory = remote_fixtures.scratch("ownership") <> "/directory"
  let assert Ok(Nil) = store.start_system(directory) as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"
  body()
  store.stop()
}

pub fn a_repeated_create_and_intent_count_as_written_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  assert a.create(session) == Ok(Nil)
  assert a.create(session) == Ok(Nil)
  assert a.begin_move(session, op, bravo) == Ok(Nil)
  assert a.begin_move(session, op, bravo) == Ok(Nil)
  assert a.read(session)
    == Ok(Some(Record(owner: alpha, state: Moving(op:, to: bravo))))
}

pub fn a_second_creator_finds_the_first_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let b = ownership.over_store(bravo)
  assert a.create(session) == Ok(Nil)
  assert b.create(session)
    == Error(Mismatch(Some(Record(owner: alpha, state: Serving))))
}

pub fn the_activation_wins_over_a_later_abandon_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let b = ownership.over_store(bravo)
  let assert Ok(Nil) = a.create(session) as "created"
  let assert Ok(Nil) = a.begin_move(session, op, bravo) as "intent"
  assert b.activate(session, op, alpha) == Ok(Nil)
  assert a.abandon(session, op, bravo)
    == Error(Mismatch(Some(Record(owner: bravo, state: Serving))))
  assert a.read_consistent(session)
    == Ok(Some(Record(owner: bravo, state: Serving)))
}

pub fn the_abandon_wins_over_a_later_activation_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let b = ownership.over_store(bravo)
  let assert Ok(Nil) = a.create(session) as "created"
  let assert Ok(Nil) = a.begin_move(session, op, bravo) as "intent"
  assert a.abandon(session, op, bravo) == Ok(Nil)
  assert b.activate(session, op, alpha)
    == Error(Mismatch(Some(Record(owner: alpha, state: Serving))))
}

pub fn an_intent_needs_this_daemon_serving_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let b = ownership.over_store(bravo)
  assert a.begin_move(session, op, bravo) == Error(Mismatch(None))
  let assert Ok(Nil) = a.create(session) as "created"
  assert b.begin_move(session, op, alpha)
    == Error(Mismatch(Some(Record(owner: alpha, state: Serving))))
}

pub fn only_the_serving_owner_releases_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let b = ownership.over_store(bravo)
  let assert Ok(Nil) = a.create(session) as "created"
  assert b.release(session)
    == Error(Mismatch(Some(Record(owner: alpha, state: Serving))))
  assert a.release(session) == Ok(Nil)
  assert a.read(session) == Ok(None)
}

pub fn the_migration_marker_is_per_node_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  assert a.migrated(alpha) == Ok(False)
  assert a.mark_migrated() == Ok(Nil)
  assert a.migrated(alpha) == Ok(True)
  assert a.migrated(bravo) == Ok(False)
}

pub fn a_local_record_is_no_base_for_a_move_test() {
  use <- with_store
  let a = ownership.over_store(alpha)
  let local = Record(owner: alpha, state: Local)
  assert a.record_local(session) == Ok(Nil)
  assert a.record_local(session) == Ok(Nil)
  assert a.read(session) == Ok(Some(local))

  // Every write of a move expects `serving` or `moving`, so none of them can
  // take a local session's record as its base, and neither can a remote delete.
  assert a.begin_move(session, op, bravo) == Error(Mismatch(Some(local)))
  assert a.release(session) == Error(Mismatch(Some(local)))

  // Only the local release removes it.
  assert a.release_local(session) == Ok(Nil)
  assert a.read(session) == Ok(None)
}
