//// The production broker and helper pool over a private workspace, for the tests
//// that observe a real Git working tree through the jail
//// (`worktree_diff_test`, `relayed_changes_test`).
////
//// `with_fixture` runs a test with the wiring a session captures with, and
//// does nothing when the platform cannot enforce the jail, as the prerequisite
//// probe says (`support/enforcement`).

import broker/broker
import broker/exec
import broker/executor
import broker/policy
import client/catalog
import client/host_git
import client/serve
import client/workspace_policy
import client/worktree_diff
import core/clock
import gleam/int
import host/bootstrap
import simplifile
import support/enforcement

/// Runs `run` over a fresh workspace named for `label` with the production
/// broker, or does nothing where enforcement is absent.
///
/// ## Examples
///
/// ```gleam
/// // use wiring <- worktree_wiring.with_fixture("states")
/// ```
pub fn with_fixture(
  label: String,
  run: fn(worktree_diff.Wiring) -> Nil,
) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a package working directory"
  let assert Ok(repository) = bootstrap.canonical_directory(here <> "/../..")
    as "the source repository locates the built helper"
  case enforcement.probe(repository <> "/bin/loom", "worktree observation") {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      // A non-repository fixture must have no ancestor Git metadata. Denying
      // reads of the source checkout's metadata instead produces a genuine
      // permission failure on macOS. The jail replaces /tmp with scratch, so
      // /var/tmp retains the fixture's path inside both enforcement backends.
      let directory =
        "/var/tmp/loom-worktree-observation-"
        <> int.to_string(bootstrap.current_process_id())
        <> "-"
        <> label
        <> "-"
        <> int.to_string(bootstrap.system_time_ms())
      let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
        as "the fixture owns a workspace"
      let assert Ok(workspace) = bootstrap.canonical_directory(directory)
        as "the fixture policy uses absolute paths"
      serve_workspace(repository, workspace, run)
    }
  }
}

/// Starts the production broker and pool over `workspace` and runs the test
/// with the wiring a session would capture with. A linked worktree's metadata
/// directories are admitted as `serve.boot` admits them
/// (`workspace_policy.widening_linked_worktree`), so a workspace whose `.git` is a file
/// is observed as it is in production.
///
/// ## Examples
///
/// ```gleam
/// // worktree_wiring.serve_workspace(repository, workspace, run)
/// ```
pub fn serve_workspace(
  repository: String,
  workspace: String,
  run: fn(worktree_diff.Wiring) -> Nil,
) -> Nil {
  // Keep ancestor repositories outside this fixture's readable scope.
  // Host reads would let the empty workspace discover the CI checkout.
  let base = workspace_policy.base_policy_for(workspace, catalog.WorkspaceReads)

  // Apple ships the real Git executable with Xcode; /usr/bin/git is a
  // launcher whose discovery needs unrelated host preferences. Admit only
  // the installed developer usr tree and put its real binary first.
  let developer_usr = "/Applications/Xcode.app/Contents/Developer/usr"
  let #(base, path) = case simplifile.is_directory(developer_usr) {
    Ok(True) -> #(
      policy.SandboxPolicy(..base, readable_roots: [
        developer_usr,
      ]),
      developer_usr <> "/bin:/usr/bin:/bin:/usr/local/bin",
    )
    Ok(False) | Error(_) -> #(base, "/usr/local/bin:/usr/bin:/bin")
  }
  let base = workspace_policy.widening_linked_worktree(base, workspace)
  let clock = clock.from_function(bootstrap.system_time_ms)
  let assert Ok(#(_pool, broker, service)) =
    serve.start_effect_plane(
      helper: repository <> "/bin/loom-exec",
      base_policy: base,
      tmp_dir: workspace <> "/.helper",
      size: 1,
      clock:,
    )
    as "the fixture starts the production broker and pool"
  run(worktree_diff.Wiring(
    workspace:,
    broker:,
    base_policy: base,
    clock:,
    demand: exec.PlatformEnforcement,
    env: [
      #("PATH", path),
      #("HOME", "/nonexistent"),
    ],
    entropy: fn() { bootstrap.system_time_ms() },
    git: host_git.program(),
  ))

  // The pool's original helper witnesses, not a stop request, prove drain.
  broker.stop(broker)
  assert executor.close(
      service,
      draining: executor.drain_ms,
      helpers: executor.helpers_ms,
    )
    == Ok(Nil)
}
