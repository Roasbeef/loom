//// The directory store over a one-member Khepri cluster in the test VM
//// (protocol-change/080). The store is a VM-wide singleton, so every case
//// starts it on a fresh directory and stops it before returning, and the
//// module is declared serial.

import client/directory/record.{Moving, Record, Serving}
import client/directory/store.{Mismatch}
import client/internal/ffi_khepri
import gleam/list
import gleam/option.{None, Some}
import simplifile
import support/remote_fixtures

const session = "0198c0de-0000-7000-8000-000000000001"

const alpha = "alpha@10.0.0.1"

const bravo = "bravo@10.0.0.4"

const op = "0192f3c1-0000-7000-8000-000000000001"

fn with_store(body: fn(String) -> Nil) -> Nil {
  let directory = remote_fixtures.scratch("directory-store") <> "/directory"
  let assert Ok(Nil) = store.start_system(directory) as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"
  body(directory)
  store.stop()
}

pub fn a_missing_record_reads_as_none_test() {
  use _directory <- with_store
  assert store.read(session) == Ok(None)
  assert store.read_consistent(session) == Ok(None)
}

pub fn create_writes_and_refuses_a_second_time_test() {
  use _directory <- with_store
  let owned = Record(owner: alpha, state: Serving)
  assert store.create(session, owned) == Ok(Nil)
  assert store.read(session) == Ok(Some(owned))
  assert store.create(session, Record(owner: bravo, state: Serving))
    == Error(Mismatch(Some(owned)))
}

pub fn swap_commits_only_against_the_exact_value_test() {
  use _directory <- with_store
  let serving = Record(owner: alpha, state: Serving)
  let moving = Record(owner: alpha, state: Moving(op:, to: bravo))
  let arrived = Record(owner: bravo, state: Serving)
  let assert Ok(Nil) = store.create(session, serving) as "created"
  assert store.swap(session, serving, moving, store.write_ms) == Ok(Nil)

  // The abandon and the activation both expect the moving record, and only the
  // first to commit wins.
  assert store.swap(session, moving, arrived, store.write_ms) == Ok(Nil)
  assert store.swap(session, moving, serving, store.write_ms)
    == Error(Mismatch(Some(arrived)))
  assert store.read_consistent(session) == Ok(Some(arrived))
}

pub fn swap_on_a_missing_record_is_a_mismatch_with_nothing_test() {
  use _directory <- with_store
  let serving = Record(owner: alpha, state: Serving)
  assert store.swap(session, serving, serving, store.write_ms)
    == Error(Mismatch(None))
}

pub fn delete_if_removes_only_the_expected_record_test() {
  use _directory <- with_store
  let serving = Record(owner: alpha, state: Serving)
  let moving = Record(owner: alpha, state: Moving(op:, to: bravo))
  let assert Ok(Nil) = store.create(session, moving) as "created"
  assert store.delete_if(session, serving) == Error(Mismatch(Some(moving)))
  assert store.read(session) == Ok(Some(moving))
  let assert Ok(Nil) = store.swap(session, moving, serving, store.write_ms)
    as "abandoned"
  assert store.delete_if(session, serving) == Ok(Nil)
  assert store.read(session) == Ok(None)

  // A second delete finds nothing, and says so rather than claiming success.
  assert store.delete_if(session, serving) == Error(Mismatch(None))
}

pub fn the_migration_marker_is_absent_until_written_test() {
  use _directory <- with_store
  assert store.migrated(alpha) == Ok(False)
  assert store.mark_migrated(alpha) == Ok(Nil)
  assert store.migrated(alpha) == Ok(True)
  assert store.migrated(bravo) == Ok(False)
}

pub fn the_one_member_is_a_voter_and_the_leader_test() {
  use _directory <- with_store
  let assert Ok(store.Membership(members:, leader:)) = store.membership()
    as "membership answers"
  assert list.length(members) == 1
  assert list.all(members, fn(member) { member.1 == ffi_khepri.Voter })
  assert leader != None
  let assert Ok(Nil) =
    store.create(session, Record(owner: alpha, state: Serving))
    as "a write moves the applied index"
  assert store.applied_index() > 0
}

pub fn the_joined_marker_and_the_data_check_test() {
  use directory <- with_store
  assert store.holds_data(directory)
  assert !store.is_joined(directory)
  let assert Ok(Nil) = store.mark_joined(directory) as "marked"
  assert store.is_joined(directory)
}

pub fn a_ra_system_with_no_store_is_not_data_test() {
  let directory =
    remote_fixtures.scratch("directory-system-only") <> "/directory"
  let assert Ok(Nil) = store.start_system(directory) as "the Ra system starts"

  // The system's own files are there, and they are not a store.
  let assert Ok([_, ..]) = simplifile.read_directory(directory)
    as "the Ra system wrote its files"
  assert !store.holds_data(directory)
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"

  // A started server is.
  assert store.holds_data(directory)
  store.stop()
}

pub fn a_stopped_store_answers_no_quorum_rather_than_absent_test() {
  let directory = remote_fixtures.scratch("directory-stopped") <> "/directory"
  let assert Ok(Nil) = store.start_system(directory) as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "started"
  store.stop()
  let assert Error(store.Unavailable(_)) = store.read(session)
    as "a read of a stopped store is unavailable"
  let assert Error(store.NoQuorum(_)) =
    store.create(session, Record(owner: alpha, state: Serving))
    as "a write to a stopped store is refused"
  let assert Ok(False) = simplifile.is_file(store.joined_marker(directory))
    as "nothing marked it joined"
  Nil
}
