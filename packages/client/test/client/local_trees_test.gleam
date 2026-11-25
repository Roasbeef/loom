//// The life of a local session's own Git worktree (protocol-change/133), against
//// a real repository, the production `client/local_trees` and
//// `client/worktrees`, and the shipped sandbox helper.
////
//// A local folder is not a registered workspace, so what these tests add to
//// `worktrees_test` is the folder's service: the first session of a folder
//// starts it, and every later session of the folder shares its gate. Git is run
//// directly as the operator to plant and to observe, as in `worktrees_test`, so
//// that a wrong answer from the daemon's own Git cannot also be the observer's.

import broker/exec
import client/local_trees
import client/workspaces
import client/worktrees
import gleam/string
import simplifile
import support/worktree_rig.{type Rig, exists, git, session, write}
import telemetry/log

// --- helpers --------------------------------------------------------------------

// A registry whose services are built the way the daemon builds them: a
// `Worktrees` over the folder's one workspace, with the rig's state root and
// ledger.
fn registry(rig: Rig) -> local_trees.LocalTrees {
  let assert Ok(current) = simplifile.current_directory()
    as "the test runner has a working directory"
  let assert Ok(trees) =
    local_trees.start(fn(workspace) {
      worktrees.start(
        worktrees.Config(
          state_root: rig.state,
          ledger_path: rig.ledger_path,
          helper_path: current <> "/../sandbox/loom-exec",
          demand: exec.BestEffort,
          credentials: [],
          path: "",
          logger: log.discard(),
        ),
        [workspace],
      )
    })
    as "the registry starts"
  trees
}

fn opened(trees: local_trees.LocalTrees, rig: Rig, n: Int) -> worktrees.Tree {
  let assert Ok(tree) = local_trees.open(trees, rig.root, "HEAD", session(n))
    as "the tree opens"
  tree
}

// --- the tree -------------------------------------------------------------------

pub fn a_session_works_in_a_tree_of_its_folder_and_leaves_the_folder_alone_test() {
  let rig = worktree_rig.rig("local-tree")
  let trees = registry(rig)
  let tree = opened(trees, rig, 1)

  // The tree is under the state root, named for the folder and the session, on
  // the session's own branch, and holds the folder's committed files.
  let workspace = local_trees.workspace_of(rig.root, "HEAD")
  assert tree.path == worktrees.tree_path(rig.state, workspace.name, session(1))
  assert tree.branch == "loom/" <> session(1)
  assert git(tree.path, ["rev-parse", "--abbrev-ref", "HEAD"]) == tree.branch
  assert git(tree.path, ["show", "HEAD:README"]) == "one"

  // An edit in the tree is on the tree's branch and not in the folder.
  write(tree.path <> "/README", "changed\n")
  write(tree.path <> "/new.txt", "added\n")
  assert git(rig.root, ["status", "--porcelain"]) == ""
  assert git(rig.root, ["rev-parse", "--abbrev-ref", "HEAD"]) == "main"
  assert !exists(rig.root <> "/new.txt")
  let assert Ok("one\n") = simplifile.read(rig.root <> "/README")
}

pub fn a_clean_close_removes_the_tree_and_keeps_the_branch_test() {
  let rig = worktree_rig.rig("local-clean")
  let trees = registry(rig)
  let tree = opened(trees, rig, 1)
  assert exists(tree.path)

  assert local_trees.close(trees, rig.root, "HEAD", session(1))
    == worktrees.Removed
  assert !exists(tree.path)

  // The branch is how a reopen gets the session's commits back, so it stays.
  assert git(rig.root, ["branch", "--list", tree.branch]) != ""
  assert !string.contains(git(rig.root, ["worktree", "list"]), tree.path)
}

pub fn a_tree_with_changes_is_kept_and_a_reopen_adopts_it_test() {
  let rig = worktree_rig.rig("local-dirty")
  let trees = registry(rig)
  let tree = opened(trees, rig, 1)
  write(tree.path <> "/notes.txt", "unsaved work\n")

  let assert worktrees.Kept(_) =
    local_trees.close(trees, rig.root, "HEAD", session(1))
  assert exists(tree.path <> "/notes.txt")

  // The reopen finds the same tree with the same file: nothing is recreated.
  let again = opened(trees, rig, 1)
  assert again == tree
  let assert Ok("unsaved work\n") = simplifile.read(tree.path <> "/notes.txt")
}

pub fn a_removed_tree_is_recreated_from_its_branch_with_its_commits_test() {
  let rig = worktree_rig.rig("local-recreate")
  let trees = registry(rig)
  let tree = opened(trees, rig, 1)

  // A commit on the session's branch survives the close that removes the clean
  // tree, because the branch is what holds it.
  write(tree.path <> "/work.txt", "committed\n")
  git(tree.path, ["add", "work.txt"])
  git(tree.path, ["commit", "--quiet", "-m", "session work"])
  assert local_trees.close(trees, rig.root, "HEAD", session(1))
    == worktrees.Removed
  assert !exists(tree.path)

  // The reopen checks the branch out again, commit included.
  let again = opened(trees, rig, 1)
  let assert Ok("committed\n") = simplifile.read(again.path <> "/work.txt")
}

pub fn a_branch_starts_from_the_base_the_session_asked_for_test() {
  let rig = worktree_rig.rig("local-base")
  let trees = registry(rig)

  // A second commit on `main`, so that `main~1` and `HEAD` differ.
  write(rig.root <> "/second.txt", "two\n")
  git(rig.root, ["add", "second.txt"])
  git(rig.root, ["commit", "--quiet", "-m", "second"])

  let assert Ok(older) = local_trees.open(trees, rig.root, "main~1", session(1))
    as "the older base opens"
  let assert Ok(newer) = local_trees.open(trees, rig.root, "HEAD", session(2))
    as "the newer base opens"
  assert !exists(older.path <> "/second.txt")
  assert exists(newer.path <> "/second.txt")
}

pub fn two_sessions_of_one_folder_have_trees_of_their_own_test() {
  let rig = worktree_rig.rig("local-two")
  let trees = registry(rig)
  let first = opened(trees, rig, 1)
  let second = opened(trees, rig, 2)

  assert first.path != second.path
  assert first.branch != second.branch
  write(first.path <> "/only-first.txt", "x\n")
  assert !exists(second.path <> "/only-first.txt")
}

// --- refusals -------------------------------------------------------------------

pub fn a_folder_that_is_not_a_repository_is_refused_test() {
  let rig = worktree_rig.rig("local-plain")
  let trees = registry(rig)
  let plain = rig.state <> "/plain-folder"
  let assert Ok(Nil) = simplifile.create_directory_all(plain)

  let assert Error(reason) = local_trees.open(trees, plain, "HEAD", session(1))
  assert string.contains(reason, "Git checkout")
}

pub fn a_linked_worktree_is_not_a_folder_a_session_may_branch_test() {
  let rig = worktree_rig.rig("local-linked")
  let trees = registry(rig)
  let linked = rig.state <> "/linked-folder"
  git(rig.root, ["worktree", "add", "--quiet", linked, "-b", "other"])

  // Its `.git` is a file, so the common directory is not `<folder>/.git`.
  let assert Error(reason) = local_trees.open(trees, linked, "HEAD", session(1))
  assert string.contains(reason, "primary checkout")
}

pub fn a_base_git_cannot_resolve_fails_without_leaving_a_tree_test() {
  let rig = worktree_rig.rig("local-badbase")
  let trees = registry(rig)

  let assert Error(_) =
    local_trees.open(trees, rig.root, "no-such-branch", session(1))
  let workspace = local_trees.workspace_of(rig.root, "no-such-branch")
  assert !exists(worktrees.tree_path(rig.state, workspace.name, session(1)))
}

pub fn a_folder_names_the_same_workspace_every_time_test() {
  let first = local_trees.workspace_of("/src/loom", "HEAD")
  let again = local_trees.workspace_of("/src/loom", "origin/main")
  let other = local_trees.workspace_of("/src/other", "HEAD")

  assert first.name == again.name
  assert first.name != other.name
  assert worktrees.safe_component(first.name)
  assert first.mode == workspaces.Worktree("HEAD")
  assert again.mode == workspaces.Worktree("origin/main")
}
