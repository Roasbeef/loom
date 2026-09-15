//// Startup refusal paths must not invoke native launch or change discovery.
//// Real control handshakes and paused-child lock handoff live in client tests,
//// which can boot the actual daemon entrypoint without a dependency cycle.

import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host
import host/endpoint
import simplifile
import tui/bootstrap
import tui/daemon/bootstrap as daemon_bootstrap
import weft

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

pub fn reconnect_waits_for_the_native_owner_before_one_launch_test() {
  let paths = paths("reconnect-retirement")
  let gate = paths.root <> "/retire"
  let assert Ok(#(child, pid)) =
    host.spawn_server(
      "/bin/sh",
      [
        "-c",
        "i=0; while [ \"$i\" -lt 100 ] && [ ! -f \"$1\" ]; do i=$((i+1)); sleep 0.05; done",
        "retirement-fixture",
        gate,
      ],
      paths.root,
      paths.log,
    )
    as "the bounded fixture owns a native process with no serving socket"
  let assert Ok(fence) = endpoint.observe(pid)
    as "the paused fixture has an observable native fence"
  let record = endpoint.Ready(fence, "127.0.0.1", 1, "departing", None)
  assert endpoint.write(paths, record) == Ok(Nil)
  assert host.atomic_write_private(paths.token, string.repeat("a", 64))
    == Ok(Nil)
  assert host.release_server_process(child) == Ok(Nil)
  let launches = process.new_subject()
  let owner = process.self()
  let run =
    weft.new([
      fn() {
        daemon_bootstrap.reconnect(
          paths,
          owner,
          fn() {
            process.send(launches, Nil)
            Error("vacancy observed")
          },
          3000,
        )
      },
    ])
    |> weft.deadline(4000)
    |> weft.start_detached

  // A failed control probe while the old VM is alive cannot spend the
  // attempt or invoke launch. Releasing the gate establishes actual exit.
  let assert weft.NotYet = weft.pull(run, within: 100)
    as "reconnect waits through the socket-close/native-retirement interval"
  assert endpoint.load(paths) == Ok(Some(record))
  assert process.receive(launches, 0) == Error(Nil)
  assert simplifile.write(gate, "retire") == Ok(Nil)
  let assert weft.PulledOutcome(weft.Failed(error: "vacancy observed", ..)) =
    weft.pull(run, within: 3500)
    as "positive native vacancy reaches the one launch callback"
  let assert weft.AllDelivered = weft.pull(run, within: 500)
    as "the bounded reconnect task has retired"
  assert process.receive(launches, 0) == Ok(Nil)
  assert process.receive(launches, 0) == Error(Nil)
  assert endpoint.is_present(fence) == Ok(False)
  host.close_server_process(child)
  assert simplifile.delete(paths.root) == Ok(Nil)
}

pub fn reconnect_never_replaces_an_unreachable_live_vm_test() {
  let paths = paths("reconnect-occupied")
  let assert Ok(fence) = endpoint.observe(host.current_process_id())
    as "the test VM remains alive throughout the reconnect budget"
  let record = endpoint.Ready(fence, "127.0.0.1", 1, "unreachable", None)
  assert endpoint.write(paths, record) == Ok(Nil)
  assert host.atomic_write_private(paths.token, string.repeat("a", 64))
    == Ok(Nil)
  let launches = process.new_subject()
  let assert Error(_) =
    daemon_bootstrap.reconnect(
      paths,
      process.self(),
      fn() {
        process.send(launches, Nil)
        Error("must not launch")
      },
      100,
    )
    as "socket failure cannot replace a live native owner"
  assert process.receive(launches, 0) == Error(Nil)
  assert endpoint.load(paths) == Ok(Some(record))
  assert simplifile.delete(paths.root) == Ok(Nil)
}
