//// The daemon's executor boot: a configuration that serves workspaces starts
//// the host under its fixed name, and one that serves none starts nothing.
////
//// Only the decision and the start are proved here. Distribution itself needs
//// a VM booted for it, so the two-node tests live in `remote_nodes_test`.

import client/daemon/main
import client/executor_plane
import client/internal/ffi_os
import client/node_report.{ExecutorFacts, ScopeCounts}
import client/peer_defaults
import client/remote/address
import client/remote/protocol
import client/system_prompt
import client/workspaces
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/remote_fixtures as fixtures
import support/worktree_rig
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
      main.BindDefault,
      8,
      "Owner",
      [],
      None,
      main.ViewOff,
      peer_defaults.off,
      [],
      [],
      [],
      [],
      None,
      None,
      [],
      None,
      None,
      dict.new(),
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
  let served = [workspaces.shared("proj", checkout)]
  let arguments = [
    "--helper",
    absolute("../sandbox/loom-exec"),
    "--best-effort",
  ]

  let assert Ok(Some(hosted)) =
    main.start_executor(
      config(scratch <> "/state", served, arguments),
      log.discard(),
    )
  let assert Ok(host) = process.named(address.default())
    as "the host registers under the fixed name"

  // The host reports itself from its own ledger: nothing attached yet, so no
  // scope, no census, and the workspace named without its root.
  let limits = executor_plane.scope_limits()
  assert hosted.facts()
    == Some(ExecutorFacts(
      protocol: protocol.version,
      scopes: ScopeCounts(
        open: 0,
        closing: 0,
        closed_clean: 0,
        closed_unknown: 0,
      ),
      scope_limit: limits.max_unclean_scopes,
      unclean: [],
      ledger_bytes: 0,
      ledger_limit: limits.max_ledger_bytes,
      unacknowledged: 0,
      platform: system_prompt.platform(ffi_os.platform()),
      observed: None,
      workspaces: ["proj"],
      worktrees: option.None,
    ))

  // The host is not linked to this process, so it ends only when told to.
  process.demonitor_process(hosted.monitor)
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
      config(scratch, [workspaces.shared("proj", scratch)], [
        "--helper",
        scratch <> "/no-such-helper",
      ]),
      log.discard(),
    )
  assert string.contains(reason, "the helper binary does not exist")
  assert process.named(address.default()) == Error(Nil)
}

// --- worktree workspaces (protocol-change/095) ----------------------------------

fn tree_scratch(name: String) -> #(String, String) {
  let scratch = absolute(fixtures.scratch(name))
  let state = scratch <> "/state"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state root is created"
  let assert Ok(state) = bootstrap.canonical_directory(state)
    as "the state root resolves"
  worktree_rig.establish(state)
  #(scratch, state)
}

pub fn a_daemon_that_serves_a_worktree_workspace_reports_it_in_its_census_test() {
  let #(scratch, state) = tree_scratch("daemon-executor-trees")
  let repository = worktree_rig.repository(scratch <> "/repo")
  let served = [
    workspaces.Workspace("proj", repository, workspaces.Worktree("main")),
  ]
  let arguments = [
    "--helper",
    absolute("../sandbox/loom-exec"),
    "--best-effort",
  ]

  let assert Ok(Some(hosted)) =
    main.start_executor(config(state, served, arguments), log.discard())
  let assert Ok(host) = process.named(address.default())
    as "the host registers under the fixed name"

  // Nothing attached yet, so no tree, and the stray directory is counted.
  worktree_rig.write(state <> "/worktrees/proj/stranger/note.txt", "x\n")
  let assert Some(facts) = hosted.facts()
  assert facts.workspaces == ["proj"]
  assert facts.worktrees
    == Some(node_report.WorktreeFacts(
      workspaces: ["proj"],
      present: 0,
      kept: 0,
      branches_left: 0,
      unrecorded: 1,
    ))

  process.demonitor_process(hosted.monitor)
  process.kill(host)
  assert fixtures.eventually(fn() {
    process.named(address.default()) == Error(Nil)
  })
}

pub fn a_worktree_root_that_is_not_a_primary_checkout_refuses_the_start_test() {
  let #(scratch, state) = tree_scratch("daemon-executor-notrepo")
  let plain = scratch <> "/plain"
  let assert Ok(Nil) = simplifile.create_directory_all(plain)
    as "a plain directory is created"
  let served = [
    workspaces.Workspace("proj", plain, workspaces.Worktree("main")),
  ]
  let arguments = [
    "--helper",
    absolute("../sandbox/loom-exec"),
    "--best-effort",
  ]

  let assert Error(reason) =
    main.start_executor(config(state, served, arguments), log.discard())

  assert string.contains(reason, "primary checkout")
  assert process.named(address.default()) == Error(Nil)
}
