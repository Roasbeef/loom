//// How the sandboxed Git words a call the sandbox would not run
//// (`worktree_git.failure_words`), which `loomd executor release --worktrees`
//// prints when the sandbox is degraded.

import broker/exec
import client/worktree_git
import gleam/string

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
