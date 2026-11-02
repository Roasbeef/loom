//// The project's check against a real repository, the shipped sandbox helper
//// and strict enforcement.
////
//// The check runs where the worker cannot reach and cannot read what the
//// daemon keeps. These tests start the production worktrees over a real
//// repository, run `project_start.run_check` on a commit, and have the check
//// itself try to read a session's store and a credential, and to write beside
//// the repository. A check that is told by the jail it may not is the claim.
////
//// Strict enforcement is asked for, so a host that cannot apply every layer
//// refuses to run the command at all. That is not a failure of the claim, and
//// a test that meets it prints a SKIP line to standard error and passes, which
//// is how the suite counts skips.

import broker/exec
import client/daemon/project_host
import client/daemon/project_start
import client/goalstate
import client/internal/ffi_os
import client/worktrees.{type Worktrees}
import gleam/io
import gleam/list
import gleam/string
import simplifile
import support/worktree_rig
import telemetry/log

fn trees(rig: worktree_rig.Rig) -> Worktrees {
  worktrees.stop(rig.trees)
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let assert Ok(strict) =
    worktrees.start(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: here <> "/../sandbox/loom-exec",
        demand: exec.PlatformEnforcement,
        logger: log.discard(),
      ),
      [rig.workspace],
    )
    as "the worktrees start"
  strict
}

fn request(
  rig: worktree_rig.Rig,
  command: String,
) -> project_host.CheckRequest {
  project_host.CheckRequest(
    ticket: "t-a",
    commit: worktree_rig.git(rig.root, ["rev-parse", "HEAD"]),
    command:,
    wall_ms: 60_000,
  )
}

// Runs a command as the project's check, or says why it could not: `Error`
// carries the reason a host without full enforcement gives.
fn run(
  rig: worktree_rig.Rig,
  command: String,
) -> Result(goalstate.CheckResult, String) {
  let result =
    project_start.run_check(
      ffi_os.system_time_ms,
      rig.workspace,
      Ok(trees(rig)),
      request(rig, command),
    )
  case result.ending {
    goalstate.DidNotFinish(reason:) -> Error(reason)
    goalstate.Exited(_) -> Ok(result)
  }
}

fn skip(why: String) -> Nil {
  io.println_error("SKIP project_check: " <> why)
}

pub fn a_check_runs_in_a_fresh_tree_at_the_commit_and_the_tree_goes_away_test() {
  let rig = worktree_rig.rig_at("check-fresh", "main")
  let tree =
    worktrees.tree_path(
      rig.state,
      rig.workspace.name,
      project_start.check_tree_name("t-a", request(rig, "").commit),
    )
  case run(rig, "test -f README && touch build-output && pwd") {
    Error(why) -> skip(why)
    Ok(result) -> {
      assert result.ending == goalstate.Exited(status: 0)
      assert string.contains(result.output, tree)

      // The tree is removed although the check left untracked output in it.
      assert !worktree_rig.exists(tree)
    }
  }
}

pub fn a_check_cannot_read_the_session_store_or_a_credential_or_write_beside_the_repo_test() {
  let rig = worktree_rig.rig_at("check-jail", "main")
  let token = rig.state <> "/owner.token"
  let store = rig.state <> "/sessions/s1.db"
  let control = rig.state <> "/worktrees/control"
  worktree_rig.write(token, "SECRET")
  worktree_rig.write(store, "TRANSCRIPT")
  worktree_rig.write(control, "CONTROL")

  // Exit 9 says the control file was not readable, which would make the other
  // lines pass for a reason that has nothing to do with the mask. Exit 7 and 8
  // say a secret was read, and 6 that the repository was written.
  let command =
    string.join(
      [
        "grep -q CONTROL " <> control <> " || exit 9",
        "grep -q SECRET " <> token <> " && exit 7",
        "grep -q TRANSCRIPT " <> store <> " && exit 8",
        "touch " <> rig.root <> "/planted && exit 6",
        "exit 0",
      ],
      "\n",
    )
  case run(rig, command) {
    Error(why) -> skip(why)
    Ok(result) -> {
      assert result.ending == goalstate.Exited(status: 0)
      assert !worktree_rig.exists(rig.root <> "/planted")
    }
  }
}

pub fn a_failing_check_reports_its_status_and_its_output_test() {
  let rig = worktree_rig.rig_at("check-fails", "main")
  case run(rig, "echo broken >&2; exit 3") {
    Error(why) -> skip(why)
    Ok(result) -> {
      assert result.ending == goalstate.Exited(status: 3)
      assert string.contains(result.output, "broken")
    }
  }
}

pub fn the_head_and_the_paths_it_changed_are_read_from_the_workers_tree_test() {
  let rig = worktree_rig.rig_at("observe", "main")
  let name = project_start.tree_name("t-a", 1)
  let assert Ok(tree) = worktrees.open(rig.trees, rig.workspace, name)

  // The worker commits a source file, the Makefile and a file whose name has a
  // space and a line break in it.
  worktree_rig.write(tree.path <> "/src/a.go", "package a\n")
  worktree_rig.write(tree.path <> "/Makefile", "check:\n")
  worktree_rig.write(tree.path <> "/odd name\nMakefile", "x\n")
  worktree_rig.git(tree.path, ["add", "-A"])
  worktree_rig.git(tree.path, ["commit", "--quiet", "-m", "work"])
  let head = worktree_rig.git(tree.path, ["rev-parse", "HEAD"])

  // The checkout moves on, which must not count its own new files as the
  // worker's.
  worktree_rig.write(rig.root <> "/elsewhere", "x\n")
  worktree_rig.git(rig.root, ["add", "elsewhere"])
  worktree_rig.git(rig.root, ["commit", "--quiet", "-m", "other work"])

  let assert Ok(observed) =
    project_start.observe(
      rig.state,
      rig.root,
      rig.workspace,
      rig.trees,
      project_host.ObserveRequest("t-a", 1),
    )
  assert observed.commit == head
  assert list.sort(observed.changed, string.compare)
    == ["Makefile", "odd name\nMakefile", "src/a.go"]
}

pub fn a_commit_that_is_not_a_commit_name_never_reaches_a_command_line_test() {
  let rig = worktree_rig.rig_at("check-name", "main")
  let hostile =
    project_host.CheckRequest(
      ticket: "t-a",
      commit: "--upload-pack=touch /tmp/x",
      command: "true",
      wall_ms: 1000,
    )
  let result =
    project_start.run_check(
      ffi_os.system_time_ms,
      rig.workspace,
      Ok(rig.trees),
      hostile,
    )
  assert result.ending == goalstate.DidNotFinish(reason: "not a commit name")
  assert project_start.commit_name("0123abc") == Ok(Nil)
  assert project_start.commit_name("ABCDEF1") == Error("not a commit name")
  assert project_start.commit_name("abc") == Error("not a commit name")
}
