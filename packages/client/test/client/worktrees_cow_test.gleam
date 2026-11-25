//// How a tree is made when a `git-cow` is on the daemon's `PATH`
//// (protocol-change/095, the addendum on copy-on-write). A fake `git-cow`
//// stands in for the real one: a script that records its arguments beside the
//// tree and then makes the tree with plain Git, or exits with the code a test
//// names, so each branch of the choice is exercised without a copy-on-write
//// file system.

import broker/exec
import client/worktrees
import gleam/int
import gleam/result
import gleam/string
import simplifile
import support/worktree_rig.{type Rig, exists, session}
import telemetry/log

// A fake that records `$@` in `cow-args` beside the tree, then runs `body`.
fn fake_cow(rig: Rig, name: String, body: String) -> String {
  let path = rig.state <> "/" <> name
  let script =
    "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$2\")/cow-args\"\n"
    <> body
  let assert Ok(Nil) = simplifile.write(path, script)
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
  path
}

// The production `Worktrees` over the rig's repository with this lookup.
fn trees_with(
  rig: Rig,
  cow: fn() -> Result(String, Nil),
) -> worktrees.Worktrees {
  let assert Ok(current) = simplifile.current_directory()
  let assert Ok(trees) =
    worktrees.start_with(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: current <> "/../sandbox/loom-exec",
        demand: exec.BestEffort,
        credentials: [],
        path: "",
        logger: log.discard(),
      ),
      [rig.workspace],
      cow,
    )
  trees
}

fn tree_of(rig: Rig, n: Int) -> String {
  worktrees.tree_path(rig.state, "repo", session(n))
}

const makes_the_tree = "shift; exec git worktree add \"$@\"\n"

pub fn a_found_git_cow_makes_the_tree_with_the_same_arguments_test() {
  let rig = worktree_rig.rig("cow-used")
  let program = fake_cow(rig, "git-cow", makes_the_tree)
  let trees = trees_with(rig, fn() { Ok(program) })

  let assert Ok(tree) = worktrees.open(trees, rig.workspace, session(1))
  assert exists(tree.path <> "/README")
  let assert Ok(said) = simplifile.read(rig.state <> "/worktrees/repo/cow-args")
  assert said
    == string.join(
      ["add", tree_of(rig, 1), "-b", "loom/" <> session(1), "main"],
      "\n",
    )
    <> "\n"
}

pub fn no_git_cow_makes_the_tree_with_plain_git_test() {
  let rig = worktree_rig.rig("cow-absent")
  let trees = trees_with(rig, fn() { Error(Nil) })

  let assert Ok(tree) = worktrees.open(trees, rig.workspace, session(1))
  assert exists(tree.path <> "/README")
  assert !exists(rig.state <> "/worktrees/repo/cow-args")
}

pub fn exit_two_and_three_fall_back_to_plain_git_test() {
  list_each([2, 3], fn(code) {
    let rig = worktree_rig.rig("cow-declined-" <> int.to_string(code))
    let program =
      fake_cow(
        rig,
        "git-cow",
        "echo 'the source is dirty' >&2\nexit " <> int.to_string(code) <> "\n",
      )
    let trees = trees_with(rig, fn() { Ok(program) })

    let assert Ok(tree) = worktrees.open(trees, rig.workspace, session(1))
    assert exists(tree.path <> "/README")
  })
}

pub fn any_other_exit_is_the_creations_failure_with_no_fallback_test() {
  let rig = worktree_rig.rig("cow-failed")
  let program = fake_cow(rig, "git-cow", "echo 'disk on fire' >&2\nexit 5\n")
  let trees = trees_with(rig, fn() { Ok(program) })

  let assert Error(reason) = worktrees.open(trees, rig.workspace, session(1))
  assert string.contains(reason, "git cow add exited 5")
  assert string.contains(reason, "disk on fire")
  assert !exists(tree_of(rig, 1))
}

pub fn a_priv_link_that_points_outside_the_tree_is_removed_after_a_copy_test() {
  let rig = worktree_rig.rig("cow-links")

  // The fake makes the tree, then plants the links a copy of a built checkout
  // would carry: one into the source checkout and one inside the tree.
  let program =
    fake_cow(
      rig,
      "git-cow",
      "shift; git worktree add \"$@\" || exit 1\n"
        <> "mkdir -p \"$1/build/dev/erlang/out\" \"$1/build/dev/erlang/in\" \"$1/priv-here\"\n"
        <> "ln -s \"$PWD\" \"$1/build/dev/erlang/out/priv\"\n"
        <> "ln -s \"$1/priv-here\" \"$1/build/dev/erlang/in/priv\"\n",
    )
  let trees = trees_with(rig, fn() { Ok(program) })

  let assert Ok(tree) = worktrees.open(trees, rig.workspace, session(1))
  assert result.unwrap(
      simplifile.is_symlink(tree.path <> "/build/dev/erlang/out/priv"),
      True,
    )
    == False
  assert simplifile.is_symlink(tree.path <> "/build/dev/erlang/in/priv")
    == Ok(True)
}

fn list_each(items: List(a), run: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      run(first)
      list_each(rest, run)
    }
  }
}
