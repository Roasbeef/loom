//// `loomd executor release` against real ledgers in private state directories.
////
//// The command opens a ledger the executor daemon owns while it runs, so these
//// tests hold the two properties that make that safe: it will not start while
//// another VM holds the state directory's endpoint reservation, and a refusal
//// of any kind leaves the ledger as it was. What a release changes is the
//// storage layer's business and is tested there.

import client/daemon/executor_cli
import client/worktrees
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/endpoint
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/worktree_rig

const session = "release-session"

// A private state directory holding a ledger that has one scope for `session`
// in the given state. The ledger is closed again, as it is while the executor
// daemon is stopped.
fn state_with(name: String, state: exec_ledger.ScopeState) -> String {
  let directory = fixtures.scratch("executor-cli-" <> name)
  let assert Ok(Nil) = simplifile.set_permissions_octal(directory, 0o700)
    as "the state directory is made private"
  let assert Ok(ledger) = exec_ledger.open(directory <> "/exec-ledger.db")
    as "the ledger opens"
  let assert Ok(_) =
    exec_ledger.attach(
      ledger,
      session,
      "/work",
      1,
      bit_array.from_string("attach-token"),
      exec_ledger.default_limits(),
    )
    as "the scope attaches"
  case state {
    exec_ledger.Open -> Nil
    exec_ledger.Closing -> {
      let assert Ok(Nil) = exec_ledger.begin_close(ledger, session, "/work", 1)
        as "the close begins"
      Nil
    }
    exec_ledger.Closed(outcome) -> {
      let assert Ok(Nil) = exec_ledger.begin_close(ledger, session, "/work", 1)
        as "the close begins"
      let assert Ok(Nil) =
        exec_ledger.finish_close(ledger, session, "/work", 1, outcome)
        as "the close finishes"
      Nil
    }
  }
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  directory
}

fn scope_state(directory: String) -> exec_ledger.ScopeState {
  let assert Ok(ledger) = exec_ledger.open(directory <> "/exec-ledger.db")
    as "the ledger reopens"
  let assert Ok(Some(found)) = exec_ledger.scope(ledger, session)
    as "the scope reads"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  found.state
}

fn releases(directory: String) -> List(exec_ledger.Release) {
  let assert Ok(ledger) = exec_ledger.open(directory <> "/exec-ledger.db")
    as "the ledger reopens"
  let assert Ok(found) = exec_ledger.releases(ledger, session)
    as "the releases read"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  found
}

pub fn a_closing_scope_is_released_and_the_release_is_recorded_test() {
  let directory = state_with("closing", exec_ledger.Closing)

  let assert Ok(told) =
    executor_cli.run(["release", session, "--state-dir", directory])

  assert string.contains(told, "it was closing")
  assert string.contains(told, "at incarnation 1")
  assert string.contains(told, "reopens it at incarnation 2")
  assert scope_state(directory) == exec_ledger.Closed(exec_ledger.AllRetired)
  let assert [recorded] = releases(directory)
  assert recorded.incarnation == 1
  assert recorded.was == exec_ledger.Closing
}

pub fn an_unknown_cleanup_is_released_and_named_in_the_answer_test() {
  let directory =
    state_with("unknown", exec_ledger.Closed(exec_ledger.UnknownCleanup(3)))

  let assert Ok(told) =
    executor_cli.run(["release", session, "--state-dir", directory])

  assert string.contains(told, "3 children it could not prove gone")
  assert scope_state(directory) == exec_ledger.Closed(exec_ledger.AllRetired)
}

pub fn an_open_scope_is_refused_and_nothing_changes_test() {
  let directory = state_with("open", exec_ledger.Open)

  let assert Error(reason) =
    executor_cli.run(["release", session, "--state-dir", directory])

  assert string.contains(reason, "is open")
  assert scope_state(directory) == exec_ledger.Open
  assert releases(directory) == []
}

pub fn a_cleanly_closed_scope_is_refused_test() {
  let directory =
    state_with("clean", exec_ledger.Closed(exec_ledger.AllRetired))

  let assert Error(reason) =
    executor_cli.run(["release", session, "--state-dir", directory])

  assert string.contains(reason, "nothing to release")
  assert releases(directory) == []
}

pub fn a_session_with_no_scope_is_refused_test() {
  let directory = state_with("absent", exec_ledger.Closing)

  let assert Error(reason) =
    executor_cli.run(["release", "someone-else", "--state-dir", directory])

  assert string.contains(reason, "no scope for session someone-else")
  assert scope_state(directory) == exec_ledger.Closing
}

pub fn a_running_executor_daemon_stops_the_command_before_the_ledger_opens_test() {
  let directory = state_with("running", exec_ledger.Closing)

  // A daemon that is serving has published a ready record for its VM, and
  // such a record is never adopted while the VM lives. This test VM stands for
  // that daemon.
  let assert Ok(paths) = endpoint.paths(directory)
  let assert Ok(daemon) = endpoint.observe(bootstrap.current_process_id())
    as "this VM is observable"
  let assert Ok(Nil) =
    endpoint.write(
      paths,
      endpoint.Ready(
        fence: daemon,
        host: "127.0.0.1",
        port: 7000,
        epoch: "epoch",
        identity: None,
      ),
    )
    as "the ready record is written"

  let assert Error(reason) =
    executor_cli.run(["release", session, "--state-dir", directory])

  assert string.contains(reason, "may be running")
  assert string.contains(reason, "stop the daemon first")
  assert scope_state(directory) == exec_ledger.Closing
  assert releases(directory) == []
}

pub fn a_state_directory_with_no_ledger_is_refused_and_not_created_test() {
  let missing =
    "build/executor-cli-missing-"
    <> int.to_string(bootstrap.system_time_ms())
    <> "/state"

  let assert Error(reason) =
    executor_cli.run(["release", session, "--state-dir", missing])

  assert string.contains(reason, "exec-ledger.db does not exist")
  assert simplifile.is_directory(missing) == Ok(False)
}

pub fn the_command_without_a_session_or_with_unknown_words_prints_usage_test() {
  assert executor_cli.run([]) == Error(executor_cli.usage)
  assert executor_cli.run(["release"]) == Error(executor_cli.usage)
  assert executor_cli.run(["release", "--state-dir", "x"])
    == Error(executor_cli.usage)
  assert executor_cli.run(["release", session, "--wipe"])
    == Error(executor_cli.usage)
  assert executor_cli.run(["reset", session]) == Error(executor_cli.usage)
  assert string.contains(executor_cli.usage, "loom executor release SESSION")
}

// --- the worktree sweep (protocol-change/095) -----------------------------------

const distribution =
  "[distribution]
node = \"executor@10.0.0.2\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"owner@10.0.0.1\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"
"

fn sweep_arguments(rig: worktree_rig.Rig, more: List(String)) -> List(String) {
  let config = rig.state <> "/executor.toml"
  stopped_daemon(rig.state)
  let assert Ok(Nil) =
    simplifile.write(
      config,
      distribution
        <> "\n[workspaces.repo]\nroot = \""
        <> rig.root
        <> "\"\nmode = \"worktree\"\nbase = \"main\"\n",
    )
  let assert Ok(here) = simplifile.current_directory()
  list.append(
    [
      "release",
      "--worktrees",
      "--config",
      config,
      "--state-dir",
      rig.state,
      "--helper",
      here <> "/../sandbox/loom-exec",
    ],
    more,
  )
}

// What an executor daemon that has stopped leaves behind: the endpoint record
// of a VM that no longer exists, which the next claim replaces. A state
// directory with a catalogue and no record at all is refused as damage.
fn stopped_daemon(state: String) -> Nil {
  let assert Ok(paths) = endpoint.paths(state)
  let assert Ok(Nil) =
    endpoint.write(
      paths,
      endpoint.Ready(
        fence: endpoint.Fence(
          pid: absent_process(99_990),
          birth: "a VM that is gone",
          started_at_ms: 1,
        ),
        host: "127.0.0.1",
        port: 7000,
        epoch: "epoch",
        identity: None,
      ),
    )
    as "the departed daemon's record is written"
  Nil
}

// A process id nothing on this machine holds, found by asking.
fn absent_process(candidate: Int) -> Int {
  case bootstrap.process_identity(candidate) {
    Ok(bootstrap.ProcessAbsent) -> candidate
    Ok(bootstrap.ProcessPresent(_)) | Error(_) -> absent_process(candidate - 1)
  }
}

pub fn the_worktree_sweep_needs_the_executors_configuration_test() {
  let directory = state_with("sweep-flags", exec_ledger.Open)
  let assert Error(reason) =
    executor_cli.run(["release", "--worktrees", "--state-dir", directory])
  assert string.contains(reason, "--worktrees needs --config")
}

pub fn the_worktree_sweep_removes_clean_trees_and_keeps_changed_ones_test() {
  let rig = worktree_rig.rig("cli-sweep")
  let clean = opened(rig, 1)
  let changed = opened(rig, 2)
  worktree_rig.write(changed.path <> "/wip.txt", "mine\n")

  let assert Ok(told) = executor_cli.run(sweep_arguments(rig, []))

  assert string.contains(told, "removed  " <> worktree_rig.session(1))
  assert string.contains(told, "kept     " <> worktree_rig.session(2))
  assert string.contains(told, "1 removed, 1 kept")
  assert !worktree_rig.exists(clean.path)
  assert worktree_rig.exists(changed.path <> "/wip.txt")

  // The branches are still there: the command never deletes one.
  assert string.contains(
    worktree_rig.git(rig.root, ["branch", "--list", "loom/*"]),
    clean.branch,
  )
}

pub fn a_named_session_is_removed_whatever_it_holds_test() {
  let rig = worktree_rig.rig("cli-force")
  let changed = opened(rig, 1)
  worktree_rig.write(changed.path <> "/wip.txt", "mine\n")

  let assert Ok(kept) = executor_cli.run(sweep_arguments(rig, []))
  assert string.contains(kept, "kept     " <> worktree_rig.session(1))

  let assert Ok(forced) =
    executor_cli.run(
      sweep_arguments(rig, ["--force-session", worktree_rig.session(1)]),
    )
  assert string.contains(forced, "removed  " <> worktree_rig.session(1))
  assert !worktree_rig.exists(changed.path)
}

fn opened(rig: worktree_rig.Rig, n: Int) -> worktrees.Tree {
  let assert Ok(tree) =
    worktrees.open(rig.trees, rig.workspace, worktree_rig.session(n))
    as "the tree opens"
  tree
}
