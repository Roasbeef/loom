//// Startup refusal paths must not invoke native launch or change discovery.
//// Real control handshakes and paused-child lock handoff live in client tests,
//// which can boot the actual daemon entrypoint without a dependency cycle.

import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import host/bootstrap as host
import host/endpoint
import simplifile
import tui/bootstrap
import tui/daemon/bootstrap as daemon_bootstrap

fn paths(name) {
  let assert Ok(paths) =
    endpoint.paths(
      "build/daemon-bootstrap-"
      <> name
      <> "-"
      <> int.to_string(host.system_time_ms()),
    )
    as "private startup fixture is fresh"
  paths
}

pub fn daemon_bootstrap_launch_arguments_are_global_and_port_zero_test() {
  assert bootstrap.daemon_launch_arguments("/state", "/bin/sleep", "")
    == ["--state-dir", "/state", "--bind", "127.0.0.1:0"]
  assert bootstrap.daemon_launch_arguments(
      "/state",
      "/bin/sleep",
      "/trusted/config",
    )
    == [
      "--state-dir",
      "/state",
      "--bind",
      "127.0.0.1:0",
      "--config",
      "/trusted/config",
    ]
}

pub fn daemon_bootstrap_live_starting_timeout_preserves_fence_test() {
  let paths = paths("starting")
  let assert Ok(fence) = endpoint.observe(host.current_process_id())
    as "the test VM supplies a real native fence"
  let record = endpoint.Starting(fence)
  assert endpoint.write(paths, record) == Ok(Nil)
  let launches = process.new_subject()
  let assert Error(_) =
    daemon_bootstrap.resolve(
      paths,
      process.self(),
      fn() {
        process.send(launches, Nil)
        Error("must not launch")
      },
      30,
    )
    as "an alive Starting record reaches a bounded failure"
  assert process.receive(launches, 0) == Error(Nil)
  assert endpoint.load(paths) == Ok(Some(record))
  assert simplifile.delete(paths.root) == Ok(Nil)
}

pub fn daemon_bootstrap_missing_catalogue_or_malformed_never_launches_test() {
  let paths = paths("missing")
  assert host.atomic_write_private(paths.catalogue, "existing") == Ok(Nil)
  let launches = process.new_subject()
  let launch = fn() {
    process.send(launches, Nil)
    Error("must not launch")
  }
  let assert Error(_) =
    daemon_bootstrap.resolve(paths, process.self(), launch, 100)
    as "a missing fence beside existing state requires operator recovery"
  assert host.atomic_write_private(paths.record, "{}") == Ok(Nil)
  let assert Error(_) =
    daemon_bootstrap.resolve(paths, process.self(), launch, 100)
    as "malformed discovery is not silently discarded"
  assert process.receive(launches, 0) == Error(Nil)
  assert simplifile.delete(paths.root) == Ok(Nil)
}

pub fn daemon_bootstrap_expired_discovery_cannot_release_native_child_test() {
  let paths = paths("expired-discovery")
  let assert Error(_) =
    daemon_bootstrap.resolve(
      paths,
      process.self(),
      fn() {
        process.sleep(600)
        Ok(daemon_bootstrap.Launch("/bin/sleep", ["60"]))
      },
      500,
    )
    as "native acquisition is refused after slow discovery exhausts the budget"
  assert endpoint.load(paths) == Ok(None)
  assert simplifile.delete(paths.root) == Ok(Nil)
}
