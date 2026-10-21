//// The operator command that releases an executor's stuck scope, and the one
//// that settles the Git worktrees it made.
////
//// `loomd executor release SESSION` (and `loom executor release`, which
//// forwards here the way `loom ext` does) is the explicit, recorded override
//// the design note promises for a scope with unknown cleanup. The executor
//// refuses to attach a session to a scope whose children it could not prove
//// gone, and it never decides on its own that they are. After an executor VM
//// restarts, every session that closes finds no workspace plane in the new VM
//// and records exactly that. A host that ends between the two halves of a close
//// leaves a scope `closing`, refused for good in the same way. Each such scope
//// holds one of the executor's sixteen unclean slots until a person who knows
//// the machine says its processes are gone.
////
//// ## Why the daemon must be stopped
////
//// The command opens the executor's ledger itself, at `<state-dir>/exec-ledger.db`.
//// Opening the ledger turns every call the opener's predecessor had in flight
//// into an unknown outcome, which is only correct when no earlier opener is
//// still running. `exec_ledger.open` takes no lock to enforce that. The daemon
//// holds the state directory's endpoint reservation for the life of its VM, so
//// the command takes the same reservation first (`daemon.claim_endpoint`) and
//// refuses to go on when a live daemon holds it. The reservation is left
//// behind when the command exits, and it names a VM that no longer exists, so
//// the next daemon replaces it as it replaces any record of a departed VM.
////
//// ## What it changes
////
//// `exec_ledger.release` moves a `closing` scope, or a `closed` one with unknown
//// cleanup, to `closed` with every child retired, and writes a `scope_release`
//// row in the same transaction. The session's next open attaches at the
//// incarnation after the one that closed and the executor reopens the scope. The
//// command refuses an `open` scope, whose session may be running, and a scope
//// that is already cleanly closed, and it says which.
////
//// ## Settling the worktrees
////
//// Deleting a session on the orchestrator never reaches the executor, so a
//// worktree workspace's tree for a deleted session stays until someone removes
//// it (protocol-change/095). `release --worktrees` is that someone. It settles
//// every tree the executor's ledger says it made under the rule of a close:
//// a clean tree is removed with its branch kept, and a tree with changes is
//// kept unless the operator names its session with `--force-session`. It needs
//// the daemon's own configuration (`--config`), because removing a tree runs
//// Git in the workspace's repository, and it runs that Git in the sandbox as the
//// daemon does. The daemon must be stopped, for the reason above.

import client/daemon/main as daemon
import client/executor_plane
import client/internal/ffi_os
import client/workspaces
import client/worktrees
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/exec_ledger
import telemetry/log

/// Complete help for the executor operator command.
pub const usage =
  "usage: loom executor release SESSION [--state-dir PATH]   (also: loomd executor release)
       loom executor release --worktrees --config PATH [--state-dir PATH]
                             [--helper PATH] [--force-session SESSION]...

Release a scope on this machine's executor that the executor will not reopen by
itself. Run it on the executor, with the executor daemon stopped.

An executor refuses to attach a session to a scope that closed with unknown
cleanup, or that was left closing when the daemon ended mid-close, because it
cannot prove the scope's processes are gone. After the executor restarts, every
session that closes ends this way. `release` is the operator saying the
processes are gone: it closes the scope as retired and records that it did, in
the executor's ledger. The session's next open then reopens the scope at the
next incarnation.

SESSION is the orchestrator's session id, as the refused open names it.
--state-dir is the executor daemon's state directory (default ~/.loom), where
exec-ledger.db lives.

Check that nothing from the session still runs on this machine first. The
command refuses a scope that is open, and a scope that is already closed
cleanly.

While it runs it holds the state directory's daemon reservation, and it leaves
that record behind when it exits. A daemon started during the release is
refused and must be started again, and `loom` may report that the daemon is
still starting until the next daemon starts.

Example:
  loom executor release 7f3a9c1e --state-dir /var/lib/loom

With --worktrees, settle the Git worktrees this executor made for worktree
workspaces instead. Deleting a session never reaches the executor, so its tree
stays until it is removed here. A tree with no changes is removed and its branch
loom/<session> is kept; a tree with changes or on a detached HEAD is kept, and
--force-session SESSION removes the one named whatever it holds. Git runs in the
sandbox. --config is the executor's loom.toml, which names the workspaces, and
--helper names the sandbox helper when it is not the one beside loomd.
Branches are never deleted: prune the loom/ ones with Git.

Example:
  loom executor release --worktrees --config /etc/loom/loom.toml"

/// Runs the command and exits nonzero with a one-line reason when it fails.
///
/// ## Examples
///
/// ```gleam
/// // loomd executor release 7f3a9c1e --state-dir /var/lib/loom
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case run(arguments) {
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Runs one command and returns what it prints. A refused command has changed
/// nothing in the ledger.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(executor_cli.run(["release"]))
/// ```
pub fn run(arguments: List(String)) -> Result(String, String) {
  case arguments {
    ["release", "--worktrees", ..flags] -> settle_worktrees(flags)
    ["release", session, ..flags] if session != "" ->
      case string.starts_with(session, "-") {
        True -> Error(usage)
        False -> release(session, flags)
      }
    _ -> Error(usage)
  }
}

// What the worktree form of the command was asked.
type Sweep {
  Sweep(
    state_dir: Option(String),
    config: Option(String),
    helper: Option(String),
    forced: List(String),
  )
}

fn settle_worktrees(flags: List(String)) -> Result(String, String) {
  use asked <- result.try(sweep_flags(flags, Sweep(None, None, None, [])))
  use path <- result.try(option.to_result(
    asked.config,
    "--worktrees needs --config, the executor's loom.toml\n" <> usage,
  ))
  use config <- result.try(case asked.state_dir {
    None -> daemon.parse([])
    Some(directory) -> daemon.parse(["--state-dir", directory])
  })
  let ledger_path = config.state_root <> "/exec-ledger.db"
  use Nil <- result.try(case bootstrap.path_exists(ledger_path) {
    True -> Ok(Nil)
    False ->
      Error(
        ledger_path
        <> " does not exist; --state-dir must be the executor daemon's state directory",
      )
  })
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      path <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use served <- result.try(workspaces.parse(text))
  use claimed <- result.try(
    daemon.claim_endpoint(config)
    |> result.map_error(fn(reason) {
      "the executor daemon may be running, so its trees are not touched: "
      <> reason
      <> "; stop the daemon first"
    }),
  )
  let #(config, _paths, _fence) = claimed
  use Nil <- result.try(migrated(ledger_path))
  let helper = case asked.helper {
    Some(found) -> ["--helper", found]
    None -> []
  }
  use machine <- result.try(executor_plane.machine(
    list.append(["--config", path], helper),
    path,
    config.state_root,
    log.discard(),
  ))
  use trees <- result.try(executor_plane.worktrees_of(machine, served))
  let swept = worktrees.sweep(trees, served, forced: asked.forced)
  worktrees.stop(trees)
  result.map(swept, sweep_report(_, ledger_path))
}

// The sole opener of the ledger migrates it to the current version, which a
// file the daemon has not run on since an upgrade needs before the worktree
// records can be read.
fn migrated(ledger_path: String) -> Result(Nil, String) {
  use ledger <- result.try(
    exec_ledger.open(ledger_path)
    |> result.map_error(fn(error) {
      ledger_path <> " did not open: " <> string.inspect(error)
    }),
  )
  let _closed = exec_ledger.close(ledger)
  Ok(Nil)
}

fn sweep_flags(flags: List(String), asked: Sweep) -> Result(Sweep, String) {
  case flags {
    [] -> Ok(asked)
    ["--state-dir", directory, ..rest] ->
      sweep_flags(rest, Sweep(..asked, state_dir: Some(directory)))
    ["--config", path, ..rest] ->
      sweep_flags(rest, Sweep(..asked, config: Some(path)))
    ["--helper", path, ..rest] ->
      sweep_flags(rest, Sweep(..asked, helper: Some(path)))
    ["--force-session", session, ..rest] ->
      sweep_flags(rest, Sweep(..asked, forced: [session, ..asked.forced]))
    [_other, ..] -> Error(usage)
  }
}

// One line for each tree, then what the operator may do next.
fn sweep_report(swept: List(worktrees.Swept), ledger_path: String) -> String {
  let lines =
    list.map(swept, fn(each) {
      case each.closed {
        worktrees.Removed ->
          "removed  "
          <> each.session
          <> " ("
          <> each.workspace
          <> ") "
          <> each.path
        worktrees.Kept(reason:) ->
          "kept     "
          <> each.session
          <> " ("
          <> each.workspace
          <> ") "
          <> each.path
          <> ": "
          <> reason
      }
    })
  let removed = list.count(swept, fn(each) { each.closed == worktrees.Removed })
  string.join(
    list.append(lines, [
      int.to_string(removed)
      <> " removed, "
      <> int.to_string(list.length(swept) - removed)
      <> " kept (ledger "
      <> ledger_path
      <> "). Branches loom/<session> remain in each repository; prune them with Git.",
    ]),
    "\n",
  )
}

fn release(session: String, flags: List(String)) -> Result(String, String) {
  use config <- result.try(case flags {
    [] -> daemon.parse([])
    ["--state-dir", directory] -> daemon.parse(["--state-dir", directory])
    _ -> Error(usage)
  })
  let ledger_path = config.state_root <> "/exec-ledger.db"

  // The check comes before the reservation, because taking it creates the state
  // directory, and a mistyped path should not leave one behind.
  use Nil <- result.try(case bootstrap.path_exists(ledger_path) {
    True -> Ok(Nil)
    False ->
      Error(
        ledger_path
        <> " does not exist; --state-dir must be the executor daemon's state directory",
      )
  })
  use claimed <- result.try(
    daemon.claim_endpoint(config)
    |> result.map_error(fn(reason) {
      "the executor daemon may be running, so its ledger is not opened: "
      <> reason
      <> "; stop the daemon first"
    }),
  )
  let #(config, _paths, _fence) = claimed
  use ledger <- result.try(
    exec_ledger.open(config.state_root <> "/exec-ledger.db")
    |> result.map_error(fn(error) {
      ledger_path <> " did not open: " <> string.inspect(error)
    }),
  )
  let released =
    exec_ledger.release(ledger, session, ffi_os.system_time_ms())
    |> result.map_error(fn(error) { refusal(session, error) })
  let _closed = exec_ledger.close(ledger)
  result.map(released, fn(done) { described(session, ledger_path, done) })
}

// The sentence for a release the ledger refused, naming the rule.
fn refusal(session: String, error: exec_ledger.Error) -> String {
  case error {
    exec_ledger.NoSuchScope -> "the ledger has no scope for session " <> session
    exec_ledger.NotReleasable(state: exec_ledger.Open) ->
      "the scope of session "
      <> session
      <> " is open, so the session may be running; stop the session and let it"
      <> " close, then release the scope if the open is then refused"
    exec_ledger.NotReleasable(state: _) ->
      "the scope of session "
      <> session
      <> " is already closed with every child retired; nothing to release"
    other -> "the release failed: " <> string.inspect(other)
  }
}

// What the release changed, for the operator and for the shell history.
fn described(
  session: String,
  ledger_path: String,
  released: exec_ledger.Released,
) -> String {
  let was = case released.was {
    exec_ledger.Closing -> "closing, with its close never finished"
    exec_ledger.Closed(exec_ledger.UnknownCleanup(count:)) ->
      "closed with "
      <> int.to_string(count)
      <> " children it could not prove gone"
    exec_ledger.Closed(exec_ledger.AllRetired) | exec_ledger.Open -> "closed"
  }
  "released the scope of session "
  <> session
  <> " (workspace "
  <> released.workspace
  <> "): it was "
  <> was
  <> " at incarnation "
  <> int.to_string(released.incarnation)
  <> " and is now closed with every child retired. The session's next open"
  <> " reopens it at incarnation "
  <> int.to_string(released.incarnation + 1)
  <> ". Recorded in "
  <> ledger_path
  <> "."
}
