//// The public shared API preserves private files and exposes lock-port death.
//// The TUI's bootstrap suite exercises process birth and paused launch ordering
//// through its compatibility wrappers over this same implementation.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import host/bootstrap
import simplifile

fn root() -> String {
  let assert Ok(path) =
    bootstrap.absolute_path(
      "build/host-test-é-" <> int.to_string(bootstrap.system_time_ms()),
    )
    as "the host fixture has an absolute path"
  path
}

pub fn shared_private_file_round_trip_keeps_utf8_paths_and_read_bounds_test() {
  let root = root()
  assert bootstrap.ensure_private_directory(root) == Ok(Nil)
  let path = root <> "/token-é"
  assert bootstrap.atomic_write_private(path, "private-value") == Ok(Nil)
  assert bootstrap.read_private_bounded(path, 13)
    == Ok(bit_array.from_string("private-value"))
  let assert Error(_reason) = bootstrap.read_private_bounded(path, 12)
    as "the public shared reader retains its byte bound"
  let assert Ok(resolved) = bootstrap.canonical_path(path)
    as "canonicalization preserves the UTF-8 filename"
  assert bootstrap.read_private_bounded(resolved, 13)
    == Ok(bit_array.from_string("private-value"))
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn shared_lock_monitor_observes_original_port_death_test() {
  let root = root()
  assert bootstrap.ensure_private_directory(root) == Ok(Nil)
  let path = root <> "/daemon.lock"
  let assert Ok(lock) = bootstrap.try_launch_lock(path)
    as "the root acquires the shared OS lock"
  let watch = bootstrap.lock_monitor(lock)
  assert bootstrap.try_launch_lock(path) == Error("busy")
  bootstrap.release_launch_lock(lock)
  let assert Ok(process.PortDown(monitor:, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "the root can fence readiness on original lock-port death"
  assert monitor == watch
  assert bootstrap.path_exists(path)
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn shared_digest_keeps_workspace_identity_stable_test() {
  assert bootstrap.sha256(bit_array.from_string("abc"))
    |> bit_array.base16_encode
    == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
}
