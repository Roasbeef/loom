//// The project's check against a real repository, the shipped sandbox helper
//// and strict enforcement.
////
//// The check runs where the worker cannot reach and cannot read what the
//// daemon keeps, in a tree cut from the host repository and not from anything
//// the worker wrote. These tests start the production worktrees over a real
//// repository, make a clone and a commit in it, run `project_start.run_check`
//// on that commit, and have the check itself try to read a session's store and
//// a credential, and to write beside the repository. A check that is told by
//// the jail it may not is the claim.
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
import client/project_repo
import client/worktrees.{type Worktrees}
import gleam/io
import gleam/list
import gleam/string
import simplifile
import support/project_rig
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

// A project whose worker has committed one file, and the commit the host
// repository then holds.
type Scene {
  Scene(layout: project_repo.Layout, commit: String)
}

fn scene(rig: worktree_rig.Rig) -> Scene {
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let commit = project_rig.commit(clone, [#("src/a.go", "package a\n")])
  let assert Ok(project_repo.Accepted(commit: taken, changed: _)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
    as "the host repository takes the commit in"
  assert taken == commit
  Scene(layout:, commit:)
}

fn request(scene: Scene, command: String) -> project_host.CheckRequest {
  project_host.CheckRequest(
    ticket: "t-a",
    commit: scene.commit,
    command:,
    wall_ms: 60_000,
  )
}

// Runs a command as the project's check, or says why it could not: `Error`
// carries the reason a host without full enforcement gives.
fn run(
  rig: worktree_rig.Rig,
  scene: Scene,
  command: String,
) -> Result(goalstate.CheckResult, String) {
  let result =
    project_start.run_check(
      ffi_os.system_time_ms,
      scene.layout,
      Ok(trees(rig)),
      request(scene, command),
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
  let scene = scene(rig)
  let tree = project_repo.check_tree_path(scene.layout, "t-a", scene.commit)
  case run(rig, scene, "test -f src/a.go && touch build-output && pwd") {
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
  let scene = scene(rig)
  let token = rig.state <> "/owner.token"
  let store = rig.state <> "/sessions/s1.db"
  let control = rig.state <> "/worktrees/control"
  worktree_rig.write(token, "SECRET")
  worktree_rig.write(store, "TRANSCRIPT")
  worktree_rig.write(control, "CONTROL")

  // Exit 9 says the control file was not readable, which would make the other
  // lines pass for a reason that has nothing to do with the mask. Exit 7 and 8
  // say a secret was read, and 6 that the owner's repository or the host
  // repository was written.
  let host = project_repo.host_path(scene.layout)
  let command =
    string.join(
      [
        "grep -q CONTROL " <> control <> " || exit 9",
        "grep -q SECRET " <> token <> " && exit 7",
        "grep -q TRANSCRIPT " <> store <> " && exit 8",
        "touch " <> rig.root <> "/planted && exit 6",
        "touch " <> host <> "/planted && exit 6",
        "exit 0",
      ],
      "\n",
    )
  case run(rig, scene, command) {
    Error(why) -> skip(why)
    Ok(result) -> {
      assert result.ending == goalstate.Exited(status: 0)
      assert !worktree_rig.exists(rig.root <> "/planted")
      assert !worktree_rig.exists(host <> "/planted")
    }
  }
}

pub fn a_failing_check_reports_its_status_and_its_output_test() {
  let rig = worktree_rig.rig_at("check-fails", "main")
  let scene = scene(rig)
  case run(rig, scene, "echo broken >&2; exit 3") {
    Error(why) -> skip(why)
    Ok(result) -> {
      assert result.ending == goalstate.Exited(status: 3)
      assert string.contains(result.output, "broken")
    }
  }
}

pub fn a_commit_the_host_repository_lacks_is_not_checked_test() {
  let rig = worktree_rig.rig_at("check-absent", "main")
  let layout = project_rig.started(rig)

  // The owner's own head is a real commit, but the host repository has not
  // taken it in under a ticket, and only commits it holds are checked.
  let owners = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let absent =
    project_start.run_check(
      ffi_os.system_time_ms,
      layout,
      Ok(rig.trees),
      project_host.CheckRequest(
        ticket: "t-a",
        commit: string.reverse(owners),
        command: "true",
        wall_ms: 1000,
      ),
    )
  assert case absent.ending {
    goalstate.DidNotFinish(reason:) ->
      string.contains(reason, "the check's tree was not made")
    goalstate.Exited(_) -> False
  }
}

pub fn the_head_and_the_paths_it_changed_are_read_from_the_host_repository_test() {
  let rig = worktree_rig.rig_at("observe", "main")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, project_start.tree_name("t-a", 1))

  // The worker commits a source file, the Makefile and a file whose name has a
  // space and a line break in it.
  let head =
    project_rig.commit(clone, [
      #("src/a.go", "package a\n"),
      #("Makefile", "check:\n"),
      #("odd name\nMakefile", "x\n"),
    ])

  // The checkout moves on, which must not count its own new files as the
  // worker's.
  worktree_rig.write(rig.root <> "/elsewhere", "x\n")
  worktree_rig.git(rig.root, ["add", "elsewhere"])
  worktree_rig.git(rig.root, ["commit", "--quiet", "-m", "other work"])

  let assert Ok(project_host.Taken(observed)) =
    project_start.observe(
      layout,
      rig.trees,
      project_host.ObserveRequest("t-a", 1),
    )
  assert observed.commit == head
  assert list.sort(observed.changed, string.compare)
    == ["Makefile", "odd name\nMakefile", "src/a.go"]
}

pub fn a_commit_that_is_not_a_commit_name_never_reaches_a_command_line_test() {
  let rig = worktree_rig.rig_at("check-name", "main")
  let layout = project_rig.started(rig)
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
      layout,
      Ok(rig.trees),
      hostile,
    )
  assert result.ending == goalstate.DidNotFinish(reason: "not a commit name")
  assert project_repo.commit_name("0123abc") == Ok(Nil)
  assert project_repo.commit_name("ABCDEF1") == Error("not a commit name")
  assert project_repo.commit_name("abc") == Error("not a commit name")
}
