//// `loomd executor release` against real ledgers in private state directories.
////
//// The command opens a ledger the executor daemon owns while it runs, so these
//// tests hold the two properties that make that safe: it will not start while
//// another VM holds the state directory's endpoint reservation, and a refusal
//// of any kind leaves the ledger as it was. What a release changes is the
//// storage layer's business and is tested there.

import client/daemon/executor_cli
import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/endpoint
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures

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
