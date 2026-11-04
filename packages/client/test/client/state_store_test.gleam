//// The store is a directory on the real filesystem. The tests drive it with
//// stand-in bundle bytes, since it never reads a bundle's contents beyond their
//// size and hash, and check the cap, the sweep and the verified read against
//// files they damage on purpose.

import client/internal/ffi_os
import client/state_object.{Clean, Dirty}
import client/state_store.{Limits}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile

const tip = "0123456789abcdef0123456789abcdef01234567"

const base = "89abcdef0123456789abcdef0123456789abcdef"

fn scratch(name: String) -> String {
  let directory =
    "build/state-store-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(canonical) = bootstrap.canonical_directory(directory)
  canonical
}

fn bundle(directory: String, name: String, size: Int) -> String {
  let path = directory <> "/" <> name
  let assert Ok(Nil) =
    simplifile.write_bits(
      path,
      bit_array.from_string(name <> string.repeat("x", size)),
    )
  path
}

fn open(
  name: String,
  limits: state_store.Limits,
) -> #(state_store.Store, String) {
  let root = scratch(name)
  let assert Ok(store) = state_store.open(state_store.directory(root), limits)
  #(store, root)
}

fn now() -> Int {
  bootstrap.system_time_ms() / 1000
}

fn small() -> state_store.Limits {
  Limits(size_limit: 1000, total_cap: 2500, retain_s: 3600)
}

pub fn the_default_limits_are_the_protocols_and_a_week_test() {
  assert state_store.default_limits.size_limit == state_object.size_limit
  assert state_store.default_limits.retain_s == 604_800
  assert state_store.default_limits.total_cap
    == 4 * state_store.default_limits.size_limit
  assert state_store.directory("/s") == "/s/states"
}

pub fn limits_that_cannot_hold_a_bundle_are_refused_test() {
  let root = scratch("limits")
  let directory = state_store.directory(root)
  let refused = Error("the state store limits cannot hold a bundle")
  assert result_of(state_store.open(
      directory,
      Limits(size_limit: 0, total_cap: 10, retain_s: 1),
    ))
    == refused
  assert result_of(state_store.open(
      directory,
      Limits(size_limit: 10, total_cap: 9, retain_s: 1),
    ))
    == refused
  assert result_of(state_store.open(
      directory,
      Limits(size_limit: 10, total_cap: 10, retain_s: 0),
    ))
    == refused
}

fn result_of(opened: Result(state_store.Store, String)) -> Result(Nil, String) {
  case opened {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

pub fn a_bundle_is_stored_under_its_hash_and_read_back_verified_test() {
  let #(store, root) = open("roundtrip", small())
  let file = bundle(root, "one.bundle", 100)
  let assert Ok(bytes) = simplifile.read_bits(file)
  let assert Ok(state) =
    state_store.put(
      store,
      file,
      tip:,
      base: Some(base),
      dirty: Dirty,
      now_s: now(),
    )
  assert state.hash == state_object.hash_of(bytes)
  assert state.size == bit_array.byte_size(bytes)
  assert state.tip == tip
  assert state.base == Some(base)
  assert state.dirty == Dirty

  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  assert held.state == state
  assert held.path
    == state_store.directory(root) <> "/" <> state.hash <> ".bundle"
  assert simplifile.read_bits(held.path) == Ok(bytes)
  assert simplifile.is_file(
      state_store.directory(root) <> "/" <> state.hash <> ".json",
    )
    == Ok(True)
}

pub fn a_store_directory_is_private_and_holds_no_temporary_files_test() {
  let #(store, root) = open("private", small())
  let file = bundle(root, "p.bundle", 50)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let directory = state_store.directory(root)
  let assert Ok(info) = simplifile.file_info(directory)
  assert simplifile.file_info_permissions_octal(info) == 0o700
  let assert Ok(names) = simplifile.read_directory(directory)
  assert list.sort(names, string.compare)
    == [state.hash <> ".bundle", state.hash <> ".json"]
}

pub fn putting_the_same_bytes_again_answers_the_existing_entry_test() {
  let #(store, root) = open("idempotent", small())
  let file = bundle(root, "same.bundle", 80)
  let assert Ok(first) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(before) = state_store.usage(store)
  let assert Ok(second) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  assert second == first
  assert state_store.usage(store) == Ok(before)
}

pub fn a_hash_that_is_not_a_hash_never_reaches_a_path_test() {
  let #(store, _root) = open("badhash", small())
  assert state_store.get(store, "../../etc/passwd") == Error("not a state hash")
  assert state_store.get(store, "") == Error("not a state hash")
  assert state_store.get(store, string.repeat("A", 64))
    == Error("not a state hash")
}

pub fn an_unknown_hash_is_not_held_test() {
  let #(store, _root) = open("unknown", small())
  assert state_store.get(store, string.repeat("a", 64)) == Ok(None)
}

pub fn a_bundle_over_the_size_limit_is_refused_with_its_size_test() {
  let #(store, root) = open("toobig", small())
  let file = bundle(root, "big.bundle", 2000)
  let assert Ok(info) = simplifile.file_info(file)
  assert state_store.put(
      store,
      file,
      tip:,
      base: None,
      dirty: Clean,
      now_s: now(),
    )
    == Error(
      "the bundle is "
      <> int.to_string(info.size)
      <> " bytes, over the state size limit of 1000",
    )
  assert state_store.usage(store) == Ok(0)
}

pub fn an_empty_or_missing_bundle_is_refused_test() {
  let #(store, root) = open("empty", small())
  let empty = root <> "/empty.bundle"
  let assert Ok(Nil) = simplifile.write_bits(empty, <<>>)
  assert state_store.put(
      store,
      empty,
      tip:,
      base: None,
      dirty: Clean,
      now_s: now(),
    )
    == Error("the state's size is not positive")
  let assert Error(_) =
    state_store.put(
      store,
      root <> "/missing.bundle",
      tip:,
      base: None,
      dirty: Clean,
      now_s: now(),
    )
  assert state_store.usage(store) == Ok(0)
}

pub fn a_tip_that_is_not_an_object_id_is_refused_before_anything_is_written_test() {
  let #(store, root) = open("badtip", small())
  let file = bundle(root, "t.bundle", 10)
  assert state_store.put(
      store,
      file,
      tip: "HEAD",
      base: None,
      dirty: Clean,
      now_s: now(),
    )
    == Error("the state's tip is not a full object id")
  assert state_store.usage(store) == Ok(0)
}

pub fn the_total_cap_refuses_what_does_not_fit_and_evicts_nothing_test() {
  let #(store, root) = open("cap", small())
  let first = bundle(root, "a.bundle", 900)
  let second = bundle(root, "b.bundle", 900)
  let third = bundle(root, "c.bundle", 900)
  let assert Ok(one) =
    state_store.put(store, first, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(two) =
    state_store.put(store, second, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(held) = state_store.usage(store)

  // Two bundles and their records are about 1900 bytes, so a third does not
  // fit under 2500, and the refusal says by how much the store is full.
  let assert Error(reason) =
    state_store.put(store, third, tip:, base: None, dirty: Clean, now_s: now())
  assert string.contains(
    reason,
    "the state store holds " <> int.to_string(held),
  )
  assert string.contains(reason, "of its 2500 byte cap")
  assert state_store.usage(store) == Ok(held)
  let assert Ok(Some(_)) = state_store.get(store, one.hash)
  let assert Ok(Some(_)) = state_store.get(store, two.hash)
}

pub fn the_cap_counts_strays_so_they_cannot_widen_it_test() {
  let #(store, root) = open("strays", small())
  let directory = state_store.directory(root)
  let assert Ok(Nil) =
    simplifile.write(directory <> "/stray.tmp", string.repeat("s", 2000))
  let file = bundle(root, "s.bundle", 900)
  let assert Error(_) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
}

pub fn expiry_is_strictly_older_than_the_retention_test() {
  assert !state_store.expired(100, 100, 60)
  assert !state_store.expired(100, 160, 60)
  assert state_store.expired(100, 161, 60)
  assert !state_store.expired(100, 50, 60)
}

pub fn a_sweep_keeps_the_young_and_removes_a_state_whole_when_old_test() {
  let #(store, root) = open("sweep", small())
  let file = bundle(root, "w.bundle", 100)

  // The clock is read before the write, so the entry's time is never earlier.
  let start = now()
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: start)
  let directory = state_store.directory(root)

  // At the retention boundary and inside it, nothing goes.
  assert state_store.sweep(store, start + 3600) == Ok(0)
  let assert Ok(Some(_)) = state_store.get(store, state.hash)

  // Past it the record and its bundle go together, as one entry.
  assert state_store.sweep(store, start + 3600 + 120) == Ok(1)
  assert state_store.get(store, state.hash) == Ok(None)
  assert simplifile.read_directory(directory) == Ok([])
}

pub fn a_sweep_removes_orphans_and_temporary_files_by_their_own_age_test() {
  let #(store, root) = open("orphans", small())
  let directory = state_store.directory(root)
  let hash = string.repeat("b", 64)
  let assert Ok(Nil) =
    simplifile.write(directory <> "/" <> hash <> ".bundle", "orphan")
  let assert Ok(Nil) =
    simplifile.write(directory <> "/" <> hash <> ".bundle.tmp123", "half")
  let assert Ok(Nil) = simplifile.write(directory <> "/notes", "stray")
  assert state_store.sweep(store, now()) == Ok(0)
  assert state_store.sweep(store, now() + 3600 + 5) == Ok(3)
  assert simplifile.read_directory(directory) == Ok([])
}

pub fn an_admission_sweeps_first_so_expired_entries_make_room_test() {
  let #(store, root) = open("room", small())
  let first = bundle(root, "r1.bundle", 900)
  let second = bundle(root, "r2.bundle", 900)
  let third = bundle(root, "r3.bundle", 900)
  let assert Ok(one) =
    state_store.put(store, first, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(_two) =
    state_store.put(store, second, tip:, base: None, dirty: Clean, now_s: now())

  // An hour and a bit later both are expired, and the third fits.
  let later = now() + 3600 + 10
  let assert Ok(three) =
    state_store.put(store, third, tip:, base: None, dirty: Clean, now_s: later)
  assert state_store.get(store, one.hash) == Ok(None)
  let assert Ok(Some(_)) = state_store.get(store, three.hash)
}

pub fn a_truncated_stored_bundle_is_refused_on_read_test() {
  let #(store, root) = open("truncated", small())
  let file = bundle(root, "tr.bundle", 200)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let assert Ok(bytes) = simplifile.read_bits(held.path)
  let assert Ok(cut) = bit_array.slice(bytes, 0, 50)
  let assert Ok(Nil) = simplifile.write_bits(held.path, cut)
  assert state_store.get(store, state.hash)
    == Error("the stored bundle does not match its hash or its size")
}

pub fn a_changed_byte_in_a_stored_bundle_is_refused_on_read_test() {
  let #(store, root) = open("flipped", small())
  let file = bundle(root, "fl.bundle", 200)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let assert Ok(Nil) =
    simplifile.write(held.path, string.repeat("z", state.size))
  assert state_store.get(store, state.hash)
    == Error("the stored bundle does not match its hash or its size")
}

pub fn a_record_whose_bundle_is_gone_is_an_error_not_an_absence_test() {
  let #(store, root) = open("gone", small())
  let file = bundle(root, "g.bundle", 60)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let assert Ok(Nil) = simplifile.delete(held.path)
  let assert Error(_) = state_store.get(store, state.hash)
}

pub fn a_damaged_entry_is_replaced_by_putting_the_same_bytes_test() {
  let #(store, root) = open("repair", small())
  let file = bundle(root, "rp.bundle", 120)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let assert Ok(Nil) = simplifile.write(held.path, "short")
  let assert Error(_) = state_store.get(store, state.hash)
  let assert Ok(again) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  assert again == state
  let assert Ok(Some(_)) = state_store.get(store, state.hash)
}

pub fn a_record_naming_another_hash_is_refused_test() {
  let #(store, root) = open("renamed", small())
  let file = bundle(root, "rn.bundle", 90)
  let assert Ok(state) =
    state_store.put(store, file, tip:, base: None, dirty: Clean, now_s: now())
  let other = string.repeat("c", 64)
  let directory = state_store.directory(root)
  let assert Ok(text) =
    simplifile.read(directory <> "/" <> state.hash <> ".json")
  let assert Ok(Nil) =
    simplifile.write(directory <> "/" <> other <> ".json", text)
  assert state_store.get(store, other)
    == Error("the state record names another hash")
}
