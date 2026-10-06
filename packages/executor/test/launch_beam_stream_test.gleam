//// The endpoint's real two-node proof uses public bootstrap and vector subprocess
//// spawning. Weft joins both fixed role runners; a missing prerequisite fails.

import distribution_fixture as fixture
import envoy
import executor/remote/distribution
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import tools/fs
import weft

pub fn real_two_node_unix_duplex_credit_final_and_join_test() {
  run_fixture()
}

pub fn real_two_node_original_lifetime_credit_test() {
  envoy.set("LOOM_LAUNCH_STREAM_BUDGET", "lifetime")
  run_fixture()
  envoy.unset("LOOM_LAUNCH_STREAM_BUDGET")
}

fn run_fixture() {
  let assert Ok(here) = simplifile.current_directory() as "package directory"
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let suffix = int.to_string(seconds) <> int.to_string(nanos)
  let root = here <> "/build/launch-stream-" <> suffix
  let assert Ok(provisioned) = fixture.provision(root, "launchstream")
    as "real pinned certificates"
  assert fixture.write_provisioned(provisioned, root <> "/fixture.term")
    == Ok(Nil)
  let previous_scratch = envoy.get("LOOM_TEST_SCRATCH")
  let scratch = channel_parent(here, previous_scratch)
  envoy.set("LOOM_TEST_SCRATCH", scratch)
  let executable = fixture.current_executable()
  let previous = envoy.get("LOOM_LAUNCH_STREAM_FIXTURE")
  envoy.set("LOOM_LAUNCH_STREAM_FIXTURE", root)
  let roles = [
    #(
      provisioned.executor_config,
      provisioned.executor_options,
      "launch_beam_stream_fixture:executor_main(),halt(0).",
    ),
    #(
      provisioned.owner_config,
      provisioned.owner_options,
      "launch_beam_stream_fixture:owner_main(),halt(0).",
    ),
  ]
  let outcomes =
    weft.new_prepared(
      list.map(roles, fn(role) {
        let #(config, options, entrypoint) = role
        weft.managed(fn(_) {
          fixture.run_node(
            executable,
            list.append(fixture.node_arguments(options), [
              "-noshell",
              "-eval",
              entrypoint,
            ]),
            here,
            distribution.bootstrap_home(config),
          )
        })
      }),
    )
    |> weft.deadline(60_000)
    |> weft.start
  case previous {
    Ok(value) -> envoy.set("LOOM_LAUNCH_STREAM_FIXTURE", value)
    Error(_) -> envoy.unset("LOOM_LAUNCH_STREAM_FIXTURE")
  }
  case previous_scratch {
    Ok(value) -> envoy.set("LOOM_TEST_SCRATCH", value)
    Error(_) -> envoy.unset("LOOM_TEST_SCRATCH")
  }
  let values = weft.values(outcomes)
  assert list.length(values) == 2
  list.index_map(values, fn(value, index) {
    let #(exit_code, output) = value
    let report = int.to_string(exit_code) <> "\n" <> output
    assert simplifile.write(
        root <> "/role-" <> int.to_string(index) <> ".log",
        report,
      )
      == Ok(Nil)
  })
  list.each(values, fn(value) {
    let #(exit_code, output) = value
    assert exit_code == 0 as output
    assert !string.contains(output, "=CRASH REPORT=")
    assert !string.contains(output, "=ERROR REPORT=")
    assert !string.contains(output, "exception error")
    assert !string.contains(output, "gleam_error")
  })
  assert simplifile.read(root <> "/executor-success")
    == Ok("real_original_unix_custody")
  assert simplifile.read(root <> "/owner-success")
    == Ok("real_duplex_final_credit_and_join")
  assert simplifile.delete(root) == Ok(Nil)
}

/// Runs this bounded real transport control without unrelated suites.
///
/// ## Examples
/// `gleam run -m launch_beam_stream_test` runs both fixed role processes.
pub fn main() {
  real_two_node_unix_duplex_credit_final_and_join_test()
  real_two_node_original_lifetime_credit_test()
}

// The optional override is independent of checkout ancestry. An absent override
// uses the ordinary package directory and canonical repository build parent.
fn channel_parent(here: String, override: Result(String, Nil)) -> String {
  let scratch = result.unwrap(override, here <> "/../../build")
  assert simplifile.create_directory_all(scratch) == Ok(Nil)
  let assert Ok(scratch) = fs.resolve_real(fs.real_filesystem(), "/", scratch)
    as "Canonical configured or ordinary checkout socket root."
  scratch
}

pub fn optional_socket_parent_uses_checkout_fallback_and_independent_override_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "Original fixture package directory."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/scratch-parent-"
    <> int.to_string(seconds)
    <> int.to_string(nanos)
  let ordinary = root <> "/checkout/packages/executor"
  assert simplifile.create_directory_all(ordinary) == Ok(Nil)
  let expected = root <> "/checkout/build"
  assert simplifile.create_directory_all(expected) == Ok(Nil)
  let assert Ok(expected) = fs.resolve_real(fs.real_filesystem(), "/", expected)
    as "Independent ordinary checkout expectation."
  assert channel_parent(ordinary, Error(Nil)) == expected

  // A nested configured parent must not be interpreted as a checkout root.
  let explicit = root <> "/elsewhere/build/nested"
  assert simplifile.create_directory_all(explicit) == Ok(Nil)
  let assert Ok(explicit) = fs.resolve_real(fs.real_filesystem(), "/", explicit)
    as "Independent configured parent expectation."
  assert channel_parent(ordinary, Ok(explicit)) == explicit
  assert simplifile.write(root <> "/success", "both_canonical_resolution_modes")
    == Ok(Nil)
}
