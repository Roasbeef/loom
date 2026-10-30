//// How the sandboxed Git words a call the sandbox would not run
//// (`worktree_git.failure_words`), which `loomd executor release --worktrees`
//// prints when the sandbox is degraded.

import broker/exec
import broker/policy
import client/worktree_git
import client/worktrees
import gleam/bit_array
import gleam/string
import simplifile
import support/worktree_rig

fn degraded(enforcement: List(String)) -> exec.ExecFailure {
  exec.DegradedExecution(result: exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement:,
    degraded: True,
    wall_ms: 1,
    timed_out: False,
    cancelled: False,
  ))
}

// The raw term is what the command used to print. The sentence names the layer
// the report skipped and the fix, and carries no constructor name.
pub fn a_degraded_run_names_the_missing_layer_and_the_fix_test() {
  let words = worktree_git.failure_words(degraded(["landlock", "skip:cgroup"]))
  assert string.contains(words, "without full enforcement")
  assert string.contains(words, "(skipped: cgroup)")
  assert string.contains(words, "delegated cgroup")
  assert !string.contains(words, "DegradedExecution")
  assert !string.contains(words, "ExecResult")
}

// A report that skips nothing it can name still says the sandbox was degraded
// and what to do, without an empty parenthesis.
pub fn a_degraded_run_with_no_named_layer_has_no_parenthesis_test() {
  let words = worktree_git.failure_words(degraded(["landlock"]))
  assert string.contains(words, "without full enforcement")
  assert !string.contains(words, "(skipped")
}

// A helper that announced itself degraded is told the same way, with what it
// reported.
pub fn a_degraded_helper_is_worded_with_what_it_reported_test() {
  let words = worktree_git.failure_words(exec.DegradedHelper(["no-cgroup"]))
  assert string.contains(words, "no-cgroup")
  assert string.contains(words, "delegated cgroup")
  assert !string.contains(words, "DegradedHelper")
}

// Every other failure is the tool layer's own account, never a raw term.
pub fn another_failure_is_the_tool_layers_words_test() {
  assert worktree_git.failure_words(exec.NotReady)
    == "the sandbox helper is not ready"
}

// Capture uses the real broker and helper, including their binary wire path.
fn capture_fixture(name: String) {
  let rig = worktree_rig.rig(name)
  let staging = rig.state <> "/capture"
  let assert Ok(Nil) = simplifile.create_directory_all(staging)
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: rig.state <> "/git-runner",
      state_root: rig.state,
      demand: exec.BestEffort,
    ))
  let base = policy.workspace_default(rig.root)
  let scope =
    policy.SandboxPolicy(..base, readable_roots: ["/"], protected: [
      rig.root <> "/canary",
    ])
  let call =
    worktree_git.Capture(
      directory: rig.root,
      arguments: [],
      scope:,
      staging:,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 0,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_048_576,
        output_bytes: 1024,
      ),
    )
  #(rig, git, call)
}

pub fn binary_input_and_output_survive_the_real_helper_test() {
  let #(rig, git, call) = capture_fixture("capture-binary")
  let input = <<0, 255, 128, 10, 0, 65>>
  let assert Ok(written) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(
        ..call,
        arguments: ["hash-object", "--stdin", "-w"],
        stdin: input,
        context: worktree_git.PrivateContext(
          git_dir: rig.root <> "/.git",
          index_file: rig.root <> "/.git/index",
          object_directory: rig.root <> "/.git/objects",
          alternate_object_directories: [],
        ),
        staging: rig.root <> "/.git/objects",
      ),
      30_000,
    )
  assert written.code == 0
  let assert Ok(hash) = bit_array.to_string(written.stdout)
  let hash = string.trim(hash)
  let assert Ok(read) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: ["cat-file", "blob", hash]),
      30_000,
    )
  assert read.code == 0
  assert read.stdout == input
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn capture_refuses_truncated_output_and_file_limit_test() {
  let #(rig, git, call) = capture_fixture("capture-limits")
  let limits = policy.Limits(..call.limits, output_bytes: 2)
  let truncated =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: ["--version"], limits:),
      30_000,
    )
  assert truncated == Error("Git did not complete with whole output")
  let limits = policy.Limits(..call.limits, fsize_bytes: 1)
  let assert Ok(failed) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(
        ..call,
        arguments: ["hash-object", "--stdin", "-w"],
        stdin: <<1, 2, 3>>,
        staging: rig.root <> "/.git/objects",
        limits:,
      ),
      30_000,
    )
  assert failed.code != 0
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn capture_refuses_a_successful_exit_after_its_deadline_test() {
  let #(rig, git, call) = capture_fixture("capture-deadline")
  let assert Ok(warm) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: ["--version"]),
      30_000,
    )
  assert warm.code == 0

  // The helper rounds its wall limit to seconds; caller time stays finer.
  let late =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: [
        "-c", "alias.wait=!sleep 0.2; printf complete", "wait",
      ]),
      100,
    )
  assert late == Error("Git did not complete before the capture deadline")
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn capture_preserves_protected_masks_test() {
  let #(rig, git, call) = capture_fixture("capture-mask")
  worktree_rig.write(rig.root <> "/canary", "secret")
  let assert Ok(allowed) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: ["hash-object", "README"]),
      30_000,
    )
  assert allowed.code == 0
  let assert Ok(denied) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: ["hash-object", "canary"]),
      30_000,
    )
  assert denied.code != 0
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn alternates_preserve_spaces_and_refuse_separators_test() {
  let #(rig, git, call) = capture_fixture("capture space")
  let objects = call.staging <> "/objects"
  let assert Ok(Nil) = simplifile.create_directory_all(objects)
  let context =
    worktree_git.PrivateContext(
      git_dir: rig.root <> "/.git",
      index_file: call.staging <> "/index",
      object_directory: objects,
      alternate_object_directories: [rig.root <> "/.git/objects"],
    )
  let assert Ok(found) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, context:, arguments: [
        "cat-file",
        "-t",
        "HEAD",
      ]),
      30_000,
    )
  assert found.code == 0
  assert found.stdout == <<"commit\n":utf8>>
  let invalid =
    worktree_git.PrivateContext(..context, alternate_object_directories: [
      "/tmp/one:/tmp/two",
    ])
  let rejected =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, context: invalid),
      30_000,
    )
  assert rejected == Error("invalid Git alternate path")
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}
