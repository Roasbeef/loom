//// The daemon's executor boot: a configuration that serves workspaces starts
//// the host under its fixed name, and one that serves none starts nothing.
////
//// Only the decision and the start are proved here. Distribution itself needs
//// a VM booted for it, so the two-node tests live in `remote_nodes_test`.

import client/daemon/main
import client/peer_defaults
import client/remote/address
import client/workspaces.{Workspace}
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/remote_fixtures as fixtures
import telemetry/log

fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/" <> path
}

fn config(
  state: String,
  served: List(workspaces.Workspace),
  arguments: List(String),
) -> main.Config {
  main.Config(
    ..main.Config(
      "",
      "127.0.0.1",
      0,
      8,
      "Owner",
      [],
      main.ViewOff,
      peer_defaults.off,
      [],
      [],
      [],
    ),
    state_root: state,
    session_defaults: arguments,
    workspaces: served,
  )
}

pub fn a_daemon_that_serves_no_workspace_starts_no_host_test() {
  let state = absolute(fixtures.scratch("daemon-executor-none"))
  assert main.start_executor(config(state, [], []), log.discard()) == Ok(None)
  assert process.named(address.default()) == Error(Nil)
}

pub fn a_daemon_that_serves_a_workspace_registers_the_host_test() {
  let scratch = absolute(fixtures.scratch("daemon-executor"))
  let checkout = scratch <> "/checkout"
  let assert Ok(Nil) = simplifile.create_directory_all(checkout)
    as "the checkout is created"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch <> "/state")
    as "the state root is created"
  let served = [Workspace("proj", checkout)]
  let arguments = [
    "--helper",
    absolute("../sandbox/loom-exec"),
    "--best-effort",
  ]

  let assert Ok(Some(monitor)) =
    main.start_executor(
      config(scratch <> "/state", served, arguments),
      log.discard(),
    )
  let assert Ok(host) = process.named(address.default())
    as "the host registers under the fixed name"

  // The host is not linked to this process, so it ends only when told to.
  process.demonitor_process(monitor)
  assert process.is_alive(host)
  process.kill(host)

  // The name is free again before the next test looks for it.
  assert fixtures.eventually(fn() {
    process.named(address.default()) == Error(Nil)
  })
}

pub fn a_missing_helper_refuses_the_start_with_a_reason_test() {
  let scratch = absolute(fixtures.scratch("daemon-executor-nohelper"))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
    as "the state root is created"
  let assert Error(reason) =
    main.start_executor(
      config(scratch, [Workspace("proj", scratch)], [
        "--helper",
        scratch <> "/no-such-helper",
      ]),
      log.discard(),
    )
  assert string.contains(reason, "the helper binary does not exist")
  assert process.named(address.default()) == Error(Nil)
}
