//// The public shared API preserves private files and exposes lock-port death.
//// The TUI's bootstrap suite exercises process birth, paused launch ordering
//// and non-ASCII paths against this same module.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/string
import host/bootstrap
import simplifile

fn root() -> String {
  // Three tests below call this, and each of them deletes the whole root when
  // it finishes. A millisecond reading alone is not enough to keep them apart:
  // two calls that land in the same millisecond name the same directory, and
  // then one test's cleanup removes the other's fixture mid-assertion. The
  // random component makes the name unique per call, so the tests stay
  // independent whatever order or concurrency the runner chooses.
  let assert Ok(path) =
    bootstrap.absolute_path(
      "build/host-test-é-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
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

pub fn a_log_tail_cut_inside_a_codepoint_still_reports_test() {
  let root = root()
  assert bootstrap.ensure_private_directory(root) == Ok(Nil)
  let path = root <> "/daemon.log"
  let started = bootstrap.system_time_ms()
  assert bootstrap.atomic_write_private(path, string.repeat("é", 40)) == Ok(Nil)

  // Eighty bytes of two-byte codepoints, so a nine-byte tail begins on a
  // continuation byte. The offset is chosen in bytes and cannot know that,
  // which is why the bytes cross the boundary undecoded: trimming them as a
  // string on the Erlang side raised `badarg` and killed the caller on the
  // one path whose job is to say why the daemon would not start.
  assert bootstrap.current_log_tail(path, started, 9) == Ok("éééé")

  // A tail that happens to land on a codepoint boundary is unaffected.
  assert bootstrap.current_log_tail(path, started, 8) == Ok("éééé")

  // A log older than the launch attempt is still no diagnostic at all.
  assert bootstrap.current_log_tail(path, started + 60_000, 9) == Error(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}
