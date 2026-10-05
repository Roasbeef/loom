//// The endpoint's real two-node proof uses public bootstrap and vector subprocess
//// spawning. Weft joins both fixed role runners; a missing prerequisite fails.

import distribution_fixture as fixture
import envoy
import executor/remote/distribution
import gleam/int
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import weft

pub fn real_tls_scoped_fence_drain_and_lifetime_loss_test() {
  let assert Ok(here) = simplifile.current_directory() as "package directory"
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let suffix = int.to_string(seconds) <> int.to_string(nanos)
  let root = here <> "/build/beam-scoped-lifetime-" <> suffix
  let assert Ok(provisioned) = fixture.provision(root, "scopelifetime")
    as "real pinned certificates"
  assert fixture.write_provisioned(provisioned, root <> "/fixture.term")
    == Ok(Nil)
  let executable = fixture.current_executable()
  let previous = envoy.get("LOOM_BEAM_ENDPOINT_FIXTURE")
  envoy.set("LOOM_BEAM_ENDPOINT_FIXTURE", root)
  let roles = [
    #(
      provisioned.executor_config,
      provisioned.executor_options,
      "beam_endpoint_fixture:scoped_executor_main(),halt(0).",
    ),
    #(
      provisioned.owner_config,
      provisioned.owner_options,
      "beam_endpoint_fixture:scoped_owner_main(),halt(0).",
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
    |> weft.deadline(30_000)
    |> weft.start
  case previous {
    Ok(value) -> envoy.set("LOOM_BEAM_ENDPOINT_FIXTURE", value)
    Error(_) -> envoy.unset("LOOM_BEAM_ENDPOINT_FIXTURE")
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
  assert simplifile.read(root <> "/scoped-executor-success") == Ok("ready")
  assert simplifile.read(root <> "/scoped-owner-success") == Ok("ready")
  assert simplifile.delete(root) == Ok(Nil)
}
