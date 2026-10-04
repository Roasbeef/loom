import broker/census
import broker/dispatch
import broker/exec
import broker/framing
import broker/policy
import executor
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// The helper `make sandbox` built, or the reason to skip: an unjailable
// platform, or no binary. Nothing here builds a helper of its own.
fn helper_path() -> Result(String, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> {
      let path = "../sandbox/loom-exec"
      case simplifile.is_file(path) {
        Ok(True) -> Ok(path)
        _absent_or_unreadable ->
          Error("no loom-exec at " <> path <> "; run `make sandbox`")
      }
    }
  }
}

fn config(helper: String, name: String) -> executor.Config {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  executor.Config(
    helper:,
    scratch: here <> "/build/test-scratch/" <> name,
    pool_size: 1,
  )
}

pub fn a_relative_scratch_is_refused_before_anything_spawns_test() {
  let refused =
    executor.boot(executor.Config(helper: "none", scratch: "rel", pool_size: 1))
  let assert Error(_) = refused
}

pub fn the_helper_is_chosen_from_argv_then_environment_then_default_test() {
  assert executor.choose_helper(["/a"], Ok("/b")) == "/a"
  assert executor.choose_helper([], Ok("/b")) == "/b"
  assert executor.choose_helper([], Ok("")) == executor.default_helper
  assert executor.choose_helper([], Error(Nil)) == "bin/loom-exec"
}

pub fn the_base_policy_is_a_writable_scratch_with_the_network_off_test() {
  let base = executor.base_policy("/scratch")
  assert base.writable_roots == ["/scratch"]
  assert base.network == policy.NetworkOff
  assert policy.validate(base) == Ok(Nil)
}

pub fn the_census_line_is_one_line_of_json_test() {
  let line = executor.census_line(census.Census(1, 3, 2, ["a", "b"]))
  assert line
    == "{\"service\":1,\"exec_proto\":3,\"policy_v\":2,\"features\":[\"a\",\"b\"]}"
}

/// A restart is a fresh incarnation. Pools spawn helpers lazily, so two
/// boots and drains need no helper, and the identities they would mint for
/// the same sequence number differ.
pub fn two_boots_in_one_vm_have_distinct_incarnations_test() {
  let assert Ok(first) = executor.boot(config("none", "restart-a"))
  let assert Ok(Nil) = executor.drain(first)
  let assert Ok(second) = executor.boot(config("none", "restart-b"))
  let assert Ok(Nil) = executor.drain(second)

  let a = executor.incarnation(first)
  let b = executor.incarnation(second)
  assert a != b
  assert dispatch.execution_id(incarnation: a, seq: 1)
    != dispatch.execution_id(incarnation: b, seq: 1)
}

/// The service is drained once: a second drain finds it gone and says so
/// rather than claiming a second clean close.
pub fn a_drained_executor_is_gone_test() {
  let assert Ok(up) = executor.boot(config("none", "gone"))
  assert executor.drain(up) == Ok(Nil)
  assert executor.drain(up) == Error(exec.RetirementOwnerGone)
}

/// Against the real helper: a jailed `true` runs through the service, the
/// census names this build's versions and the helper's own hello features,
/// and the drain returns the pool's clean verdict. A host whose helper says
/// `degraded` (no bwrap on Linux, no seatbelt on macOS) must refuse the
/// smoke instead, naming the degraded enforcement: that refusal is the
/// behaviour, so it is asserted rather than skipped.
pub fn a_standalone_boot_reports_its_census_and_runs_true_test() {
  case helper_path() {
    Error(reason) ->
      io.println_error("SKIP executor standalone boot: " <> reason)
    Ok(helper) -> {
      let assert Ok(here) = simplifile.current_directory()
      let config = config(here <> "/" <> helper, "boot")
      let assert Ok(up) = executor.boot(config)

      // Nothing has spawned a helper, so no hello has been heard.
      let assert Ok(unknown) = executor.census(up)
      assert unknown.features == []

      let ran = executor.smoke(up, scratch: config.scratch)
      let assert Ok(measured) = executor.census(up)
      assert measured.service == census.service_version
      assert measured.exec_proto == framing.exec_protocol_version
      assert measured.policy_v == policy.version
      assert measured.features != []
      assert census.skew(measured, census.local([])) == Ok(Nil)

      case list.contains(measured.features, "degraded") {
        True -> {
          let assert Error(reason) = ran
          assert string.contains(reason, "degraded")
          assert string.contains(reason, "skipped layers")
        }
        False -> {
          assert ran == Ok(Nil)
        }
      }
      assert executor.drain(up) == Ok(Nil)
      let assert Ok(Nil) = simplifile.delete(config.scratch)
        as "the test removes what it booted"

      case list.contains(measured.features, "degraded") {
        True -> {
          let assert Error(reason) = executor.run(config)
          assert string.contains(reason, "degraded")
        }
        False -> {
          assert executor.run(config) == Ok(Nil)
        }
      }
      assert simplifile.is_directory(config.scratch) == Ok(False)
    }
  }
}

/// The scratch directory a boot creates is gone once the run has drained
/// cleanly, even when the run failed (the helper here does not exist).
pub fn a_run_removes_its_scratch_even_when_it_fails_test() {
  let config = config("/nonexistent/loom-exec", "removed")
  let assert Error(_) = executor.run(config)
  assert simplifile.is_directory(config.scratch) == Ok(False)
}

/// A boot that fails after creating the scratch removes it: nothing was
/// spawned, and `run` only cleans up after a boot that succeeded.
pub fn a_boot_that_fails_after_the_scratch_removes_it_test() {
  let config = config("none", "boot-failed")
  let failed = executor.boot_with(config, start: fn(_) { Error("injected") })
  assert failed |> result.is_error
  assert simplifile.is_directory(config.scratch) == Ok(False)
}

/// A drain that cannot confirm custody means a jail may still be using the
/// scratch, so the run leaves it in place (and says so on stderr).
pub fn an_unconfirmed_drain_leaves_the_scratch_test() {
  let config = config("/nonexistent/loom-exec", "kept")
  let unconfirmed = fn(up) {
    let _ = executor.drain(up)
    Error(exec.RetirementOwnerGone)
  }
  let assert Error(_) = executor.run_with(config, drain: unconfirmed)
  assert simplifile.is_directory(config.scratch) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(config.scratch)
    as "the test removes what it kept"
}
