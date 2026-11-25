//// The `--worktree` launch flag and how it reaches a session creation
//// (protocol-change/133). The flag keeps the launch's directory exactly as it
//// is and only says that new sessions work in a Git worktree of it, on a branch
//// of their own, so it is read apart from the options that carry a value and is
//// carried as a placement of its own.

import core/agency_limits
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/daemon/protocol
import tui/placement
import tui/run

// A launch that does not name the flag is the launch it always was.
pub fn a_launch_without_the_flag_makes_no_worktree_test() {
  let assert Ok(options) = tui.launch_options(["--workspace", "/work"])
  assert options.placement == placement.OnThisHost
}

pub fn the_flag_alone_starts_the_branch_at_head_test() {
  let assert Ok(options) =
    tui.launch_options(["--worktree", "--workspace", "/work"])
  assert options.placement == placement.InWorktree("HEAD")

  // The directory is still the launch's own, for the picker and the footer.
  assert options.workspace == "/work"
}

pub fn the_base_may_come_before_or_after_the_flag_test() {
  let assert Ok(after) =
    tui.launch_options(["--worktree", "--base", "origin/main"])
  assert after.placement == placement.InWorktree("origin/main")
  let assert Ok(before) =
    tui.launch_options(["--base", "v1.2", "--worktree", "--config", "/c.toml"])
  assert before.placement == placement.InWorktree("v1.2")
  assert before.config == "/c.toml"
}

pub fn a_base_without_the_flag_is_refused_test() {
  let assert Error(reason) = tui.launch_options(["--base", "main"])
  assert string.contains(reason, "--worktree")
}

pub fn a_base_git_would_read_as_an_option_is_refused_test() {
  let assert Error(_) = tui.launch_options(["--worktree", "--base", "--detach"])
  let assert Error(_) = tui.launch_options(["--worktree", "--base", "a b"])
  let assert Error(_) = tui.launch_options(["--worktree", "--base", ""])
  let assert Error(reason) = tui.launch_options(["--worktree", "--base"])
  assert string.contains(reason, "--base")
}

pub fn a_flag_given_twice_is_refused_test() {
  let assert Error(_) = tui.launch_options(["--worktree", "--worktree"])
  let assert Error(_) =
    tui.launch_options(["--worktree", "--base", "a", "--base", "b"])
}

pub fn a_workspace_on_an_executor_or_in_a_pool_has_no_tree_to_make_test() {
  let assert Error(reason) =
    tui.launch_options(["--worktree", "--executor", "box", "--workspace", "app"])
  assert string.contains(reason, "executor")
  let assert Error(_) =
    tui.launch_options(["--worktree", "--pool", "p", "--workspace", "app"])
}

pub fn an_existing_session_is_not_given_a_worktree_test() {
  let assert Error(reason) =
    tui.launch_options(["--worktree", "--session", "01a11401"])
  assert string.contains(reason, "--session")
}

pub fn a_guest_session_cannot_be_given_a_worktree_test() {
  let assert Error(_) = tui.launch_vm(["--vm", "--worktree"])
  let assert Error(_) = tui.launch_vm(["--vm", "--base", "main"])
}

// `loom run -p` takes the same two words and turns them into the same
// placement.
pub fn a_headless_run_takes_the_flag_too_test() {
  let assert Ok(request) =
    run.parse(["-p", "hello", "--worktree", "--base", "origin/main"])
  assert request.options.placement == placement.InWorktree("origin/main")
  let assert Ok(plain) = run.parse(["-p", "hello"])
  assert plain.options.placement == placement.OnThisHost
  let assert Error(_) = run.parse(["-p", "hello", "--base", "main"])
  let assert Error(_) = run.parse(["-p", "hello", "--vm", "--worktree"])
}

// The creation carries the base as a `worktree` object, and a creation in the
// directory itself carries no such key, so an older daemon is sent exactly the
// request it always was.
pub fn the_creation_sends_the_base_only_for_a_worktree_test() {
  let encoded = fn(worktree) {
    let assert Ok(body) =
      protocol.encode(
        7,
        protocol.CreateSession(
          "key",
          "/work",
          "app",
          "/config",
          "",
          "",
          "",
          agency_limits.empty,
          worktree,
        ),
        protocol.Epoch("current"),
      )
    body
  }
  assert string.contains(
    encoded(Some("origin/main")),
    "\"worktree\":{\"base\":\"origin/main\"}",
  )
  assert !string.contains(encoded(None), "worktree")
}
