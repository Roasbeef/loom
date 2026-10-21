//// The life of a session's Git worktree on an executor (protocol-change/095),
//// against a real repository, the production `client/worktrees` and the shipped
//// sandbox helper.
////
//// Git is run twice over in these tests, on purpose. The executor runs it
//// through the broker in the jail, which is what is under test. The tests run
//// it directly as the operator to plant a state, make a commit or look at a
//// result, so a wrong answer from the executor's Git cannot also be the
//// observer's.
////
//// The reconciliation test is exhaustive rather than random. The records
//// have five states and the disk three, so the whole product is small enough to
//// walk, and a case a generator might miss is a case a crash could land in.

import broker/exec
import client/workspaces
import client/worktree_git
import client/worktrees
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import simplifile
import storage/exec_ledger
import support/worktree_rig.{type Rig, exists, git, session, write}
import telemetry/log

// --- helpers --------------------------------------------------------------------

fn tree_of(rig: Rig, n: Int) -> String {
  worktrees.tree_path(rig.state, "repo", session(n))
}

fn open(rig: Rig, n: Int) -> Result(worktrees.Tree, String) {
  worktrees.open(rig.trees, rig.workspace, session(n))
}

fn opened(rig: Rig, n: Int) -> worktrees.Tree {
  let assert Ok(tree) = open(rig, n) as "the tree opens"
  tree
}

fn close(rig: Rig, n: Int) -> worktrees.Closed {
  worktrees.close(rig.trees, rig.workspace, session(n))
}

fn row(rig: Rig, n: Int) -> Result(exec_ledger.TreeState, Nil) {
  let assert Ok(ledger) = exec_ledger.connect(rig.ledger_path)
    as "the ledger connects"
  let found = exec_ledger.tree(ledger, session(n))
  let _closed = exec_ledger.close(ledger)
  case found {
    Ok(Some(each)) -> Ok(each.state)
    Ok(None) | Error(_) -> Error(Nil)
  }
}

fn plant(rig: Rig, n: Int, state: exec_ledger.TreeState) -> Nil {
  let assert Ok(ledger) = exec_ledger.connect(rig.ledger_path)
    as "the ledger connects"
  let assert Ok(Nil) =
    exec_ledger.record_tree(
      ledger,
      exec_ledger.Tree(
        session: session(n),
        workspace: "repo",
        path: tree_of(rig, n),
        branch: worktrees.branch_of(session(n)),
        state:,
      ),
    )
    as "a record is planted"
  let _closed = exec_ledger.close(ledger)
  Nil
}

// A tree made by the operator's own Git at the layout's path, the way the
// executor would have made it before a crash.
fn made_by_hand(rig: Rig, n: Int) -> String {
  let path = tree_of(rig, n)
  let assert Ok(Nil) = worktree_rig_directory(rig)
  git(rig.root, [
    "worktree",
    "add",
    "--quiet",
    path,
    "-b",
    worktrees.branch_of(session(n)),
    "main",
  ])
  path
}

fn worktree_rig_directory(rig: Rig) -> Result(Nil, simplifile.FileError) {
  simplifile.create_directory_all(rig.state <> "/worktrees/repo")
}

fn branches(rig: Rig) -> List(String) {
  git(rig.root, ["branch", "--list", "loom/*", "--format=%(refname:short)"])
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
}

// --- creating a tree ------------------------------------------------------------

pub fn a_first_open_makes_a_tree_on_a_branch_of_the_sessions_own_test() {
  let rig = worktree_rig.rig("first")
  let tree = opened(rig, 1)

  assert tree.path == tree_of(rig, 1)
  assert tree.branch == "loom/" <> session(1)
  assert exists(tree.path <> "/README")
  assert git(tree.path, ["rev-parse", "--abbrev-ref", "HEAD"]) == tree.branch
  assert string.contains(git(rig.root, ["worktree", "list"]), tree.path)
  assert row(rig, 1) == Ok(exec_ledger.Present)

  // The branch starts where `base` points, and the repository's own checkout
  // is untouched.
  assert git(tree.path, ["rev-parse", "HEAD"])
    == git(rig.root, ["rev-parse", "main"])
  assert git(rig.root, ["status", "--porcelain"]) == ""
}

pub fn two_sessions_on_one_workspace_get_separate_trees_and_branches_test() {
  let rig = worktree_rig.rig("two")
  let first = opened(rig, 1)
  let second = opened(rig, 2)

  assert first.path != second.path
  assert first.branch != second.branch

  // A change in one tree is invisible in the other and in the checkout.
  write(first.path <> "/README", "changed in one\n")
  assert git(second.path, ["status", "--porcelain"]) == ""
  assert git(rig.root, ["status", "--porcelain"]) == ""
  assert list.sort(branches(rig), string.compare)
    == [first.branch, second.branch]
}

pub fn an_open_names_no_path_the_session_chose_test() {
  let rig = worktree_rig.rig("names")
  list.each(["../escape", "a/b", "", ".hidden", "x y"], fn(name) {
    let assert Error(reason) = worktrees.open(rig.trees, rig.workspace, name)
    assert string.contains(reason, "not usable as a directory name")
  })
  assert simplifile.read_directory(rig.state <> "/worktrees/repo")
    == Error(simplifile.Enoent)
}

pub fn a_workspace_in_shared_mode_has_no_tree_to_open_test() {
  let rig = worktree_rig.rig("shared")
  let shared = workspaces.shared("repo", rig.root)
  let assert Error(reason) = worktrees.open(rig.trees, shared, session(1))
  assert string.contains(reason, "not in worktree mode")
}

// --- closing a tree -------------------------------------------------------------

pub fn a_tree_whose_only_untracked_content_is_codemode_is_removed_at_close_test() {
  let rig = worktree_rig.rig("codemode")
  let tree = opened(rig, 1)
  write(tree.path <> "/.codemode/home/gitconfig", "[user]\n")
  write(tree.path <> "/.codemode/work/exec", "x\n")

  // The status Loom reads ignores `.codemode`, so the tree is clean to it.
  assert close(rig, 1) == worktrees.Removed
  assert !exists(tree.path)
  assert row(rig, 1) == Ok(exec_ledger.Removed)

  // The branch outlives the tree, and the checkout no longer lists it.
  assert branches(rig) == [tree.branch]
  assert !string.contains(git(rig.root, ["worktree", "list"]), tree.path)
}

pub fn a_tree_with_changes_is_kept_and_reopened_with_them_test() {
  let rig = worktree_rig.rig("dirty")
  let tree = opened(rig, 1)
  write(tree.path <> "/README", "edited\n")
  write(tree.path <> "/notes.txt", "untracked\n")

  let assert worktrees.Kept(reason) = close(rig, 1)
  assert string.contains(reason, "changes")
  assert row(rig, 1) == Ok(exec_ledger.Kept)
  assert exists(tree.path <> "/notes.txt")

  // The next attach adopts the same tree, changes and all.
  let again = opened(rig, 1)
  assert again == tree
  assert simplifile.read(tree.path <> "/README") == Ok("edited\n")
  assert simplifile.read(tree.path <> "/notes.txt") == Ok("untracked\n")
  assert row(rig, 1) == Ok(exec_ledger.Present)
}

pub fn a_tree_on_a_detached_head_is_kept_because_no_branch_holds_its_commits_test() {
  let rig = worktree_rig.rig("detached")
  let tree = opened(rig, 1)
  git(tree.path, ["checkout", "--quiet", "--detach"])
  write(tree.path <> "/work.txt", "committed\n")
  git(tree.path, ["add", "work.txt"])
  git(tree.path, ["commit", "--quiet", "-m", "on no branch"])

  let assert worktrees.Kept(reason) = close(rig, 1)
  assert string.contains(reason, "detached")
  assert exists(tree.path <> "/work.txt")
}

pub fn a_close_with_no_record_has_nothing_to_settle_test() {
  let rig = worktree_rig.rig("norecord")
  assert close(rig, 7) == worktrees.Removed
  assert row(rig, 7) == Error(Nil)
}

pub fn commits_survive_a_clean_close_and_return_at_the_next_open_test() {
  let rig = worktree_rig.rig("commits")
  let tree = opened(rig, 1)
  write(tree.path <> "/feature.txt", "done\n")
  git(tree.path, ["add", "feature.txt"])
  git(tree.path, ["commit", "--quiet", "-m", "feature"])

  assert close(rig, 1) == worktrees.Removed
  assert !exists(tree.path)

  // Reopening checks the session's own branch out, so its commit is back.
  let again = opened(rig, 1)
  assert again == tree
  assert simplifile.read(tree.path <> "/feature.txt") == Ok("done\n")
  assert row(rig, 1) == Ok(exec_ledger.Present)
}

pub fn a_directory_removed_out_of_band_is_recreated_from_the_branch_test() {
  let rig = worktree_rig.rig("oob")
  let tree = opened(rig, 1)
  write(tree.path <> "/kept.txt", "committed\n")
  git(tree.path, ["add", "kept.txt"])
  git(tree.path, ["commit", "--quiet", "-m", "kept"])

  // Someone deletes the tree behind the executor's back.
  let assert Ok(Nil) = simplifile.delete(tree.path)
  assert !exists(tree.path)

  let again = opened(rig, 1)
  assert again == tree
  assert simplifile.read(tree.path <> "/kept.txt") == Ok("committed\n")
  assert row(rig, 1) == Ok(exec_ledger.Present)
}

pub fn a_branch_deleted_since_the_close_is_recreated_from_the_base_test() {
  let rig = worktree_rig.rig("branchless")
  let tree = opened(rig, 1)
  assert close(rig, 1) == worktrees.Removed
  git(rig.root, ["branch", "--quiet", "-D", tree.branch])

  let again = opened(rig, 1)
  assert again == tree
  assert git(tree.path, ["rev-parse", "HEAD"])
    == git(rig.root, ["rev-parse", "main"])
}

// --- a failed make --------------------------------------------------------------

pub fn a_failed_add_leaves_no_directory_and_a_removed_record_test() {
  let rig = worktree_rig.rig_at("badbase", "no-such-ref")

  let assert Error(reason) = open(rig, 1)

  assert string.contains(reason, "worktree add")
  assert string.byte_size(reason) <= 512
  assert !exists(tree_of(rig, 1))
  assert row(rig, 1) == Ok(exec_ledger.Removed)
  assert branches(rig) == []

  // The repository has no registration of it either.
  assert !string.contains(
    git(rig.root, ["worktree", "list", "--porcelain"]),
    session(1),
  )
}

pub fn a_directory_no_record_names_is_never_deleted_by_a_failed_attach_test() {
  let rig = worktree_rig.rig("unrecorded")

  // The ledger was reset while a tree remained: a first attach finds a
  // directory at its path that no record names, and refuses rather than
  // letting a failed add delete it.
  write(tree_of(rig, 1) <> "/precious.txt", "uncommitted work\n")
  let assert Error(reason) = open(rig, 1)
  assert string.contains(reason, "no worktree record names")
  assert exists(tree_of(rig, 1) <> "/precious.txt")
  assert row(rig, 1) == Error(Nil)
}

pub fn a_forced_sweep_clears_a_half_removed_tree_git_no_longer_knows_test() {
  let rig = worktree_rig.rig("halfremoved")
  let tree = opened(rig, 1)

  // A removal that crashed half way: the directory is left without the file
  // that links it to the repository.
  let assert Ok(Nil) = simplifile.delete(tree.path <> "/.git")
  write(tree.path <> "/leftover.txt", "x\n")

  let assert Ok(swept) =
    worktrees.sweep(rig.trees, [rig.workspace], forced: [session(1)])
  let by_session = list.map(swept, fn(each) { #(each.session, each.closed) })
  assert list.key_find(by_session, session(1)) == Ok(worktrees.Removed)
  assert !exists(tree.path)
  assert row(rig, 1) == Ok(exec_ledger.Removed)
}

// --- reconciliation -------------------------------------------------------------

pub fn every_record_state_against_every_disk_state_reconciles_test() {
  let rig = worktree_rig.rig("matrix")

  // 1. creating, the tree is there and Git lists it: the add finished.
  let _t1 = made_by_hand(rig, 1)
  plant(rig, 1, exec_ledger.Creating)

  // 2. creating, a directory is there that Git does not list: a half-made leftover.
  write(tree_of(rig, 2) <> "/half.txt", "x\n")
  plant(rig, 2, exec_ledger.Creating)

  // 3. creating, nothing is there.
  plant(rig, 3, exec_ledger.Creating)

  // 4. removing, the tree is clean: finish the removal.
  let _t4 = made_by_hand(rig, 4)
  plant(rig, 4, exec_ledger.Removing)

  // 5. removing, the tree holds changes: the removal stops.
  let t5 = made_by_hand(rig, 5)
  write(t5 <> "/precious.txt", "mine\n")
  plant(rig, 5, exec_ledger.Removing)

  // 6. removing, the tree is already gone.
  plant(rig, 6, exec_ledger.Removing)

  // 7. removed, yet a directory is there: a leftover of a removal.
  write(tree_of(rig, 7) <> "/leftover.txt", "x\n")
  plant(rig, 7, exec_ledger.Removed)

  // 8. present, the tree was deleted by hand: Git still lists it.
  let t8 = made_by_hand(rig, 8)
  let assert Ok(Nil) = simplifile.delete(t8)
  plant(rig, 8, exec_ledger.Present)

  // 9 and 10. present and kept, the tree is there: nothing to do.
  let _t9 = made_by_hand(rig, 9)
  plant(rig, 9, exec_ledger.Present)
  let t10 = made_by_hand(rig, 10)
  write(t10 <> "/wip.txt", "x\n")
  plant(rig, 10, exec_ledger.Kept)

  // A directory no record names belongs to someone else.
  write(rig.state <> "/worktrees/repo/stranger/note.txt", "not ours\n")

  // The first job of the gate runs the reconciliation ahead of itself.
  let _trigger = opened(rig, 11)

  assert row(rig, 1) == Ok(exec_ledger.Present)
  assert exists(tree_of(rig, 1) <> "/README")

  assert row(rig, 2) == Ok(exec_ledger.Removed)
  assert !exists(tree_of(rig, 2))

  assert row(rig, 3) == Ok(exec_ledger.Removed)

  assert row(rig, 4) == Ok(exec_ledger.Removed)
  assert !exists(tree_of(rig, 4))

  assert row(rig, 5) == Ok(exec_ledger.Kept)
  assert exists(t5 <> "/precious.txt")

  assert row(rig, 6) == Ok(exec_ledger.Removed)

  assert row(rig, 7) == Ok(exec_ledger.Removed)
  assert !exists(tree_of(rig, 7))

  assert row(rig, 8) == Ok(exec_ledger.Removed)
  assert !string.contains(
    git(rig.root, ["worktree", "list", "--porcelain"]),
    session(8),
  )

  assert row(rig, 9) == Ok(exec_ledger.Present)
  assert row(rig, 10) == Ok(exec_ledger.Kept)
  assert exists(t10 <> "/wip.txt")

  // Nothing was deleted that the ledger did not name, and no branch was.
  assert exists(rig.state <> "/worktrees/repo/stranger/note.txt")
  assert worktrees.unrecorded(rig.trees, [rig.workspace]) == 1
  assert list.contains(branches(rig), worktrees.branch_of(session(5)))
  assert list.contains(branches(rig), worktrees.branch_of(session(4)))
}

pub fn a_record_left_mid_change_while_the_executor_ran_is_settled_at_the_next_open_test() {
  let rig = worktree_rig.rig("midchange")

  // The gate has reconciled by now, so nothing but the open can settle a row
  // that an undo failed to close.
  let _first = opened(rig, 9)
  write(tree_of(rig, 1) <> "/half.txt", "left by a failed undo\n")
  plant(rig, 1, exec_ledger.Creating)

  let tree = opened(rig, 1)

  assert exists(tree.path <> "/README")
  assert !exists(tree.path <> "/half.txt")
  assert row(rig, 1) == Ok(exec_ledger.Present)
}

pub fn a_directory_that_is_not_ours_is_counted_and_a_file_is_not_test() {
  let rig = worktree_rig.rig("count")
  let _first = opened(rig, 1)
  write(rig.state <> "/worktrees/repo/stranger/note.txt", "x\n")
  write(rig.state <> "/worktrees/repo/.DS_Store", "x\n")
  assert worktrees.unrecorded(rig.trees, [rig.workspace]) == 1
}

pub fn a_record_whose_path_is_not_the_layouts_is_never_acted_on_test() {
  let rig = worktree_rig.rig("tampered")
  let victim = rig.state <> "/victim"
  write(victim <> "/important.txt", "keep\n")

  // A damaged row naming a directory outside the layout, in a state that
  // asks for a deletion.
  let assert Ok(ledger) = exec_ledger.connect(rig.ledger_path)
  let assert Ok(Nil) =
    exec_ledger.record_tree(
      ledger,
      exec_ledger.Tree(
        session: session(1),
        workspace: "repo",
        path: victim,
        branch: worktrees.branch_of(session(1)),
        state: exec_ledger.Removed,
      ),
    )
  let _closed = exec_ledger.close(ledger)

  let _trigger = opened(rig, 2)

  assert exists(victim <> "/important.txt")
}

// --- configuration at start -----------------------------------------------------

pub fn a_root_that_is_a_linked_worktree_is_refused_at_start_test() {
  let rig = worktree_rig.rig("linked")
  let linked = rig.state <> "/linked-checkout"
  git(rig.root, ["worktree", "add", "--quiet", linked, "-b", "elsewhere"])

  let workspace =
    workspaces.Workspace("repo", linked, workspaces.Worktree("main"))
  let assert Error(reason) =
    worktrees.start(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: "unused",
        demand: exec.BestEffort,
        logger: log.discard(),
      ),
      [workspace],
    )
  assert string.contains(reason, "primary checkout")
}

pub fn a_shared_configuration_starts_nothing_test() {
  let rig = worktree_rig.rig("sharedstart")
  let assert Ok(trees) =
    worktrees.start(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: "does-not-exist",
        demand: exec.BestEffort,
        logger: log.discard(),
      ),
      [workspaces.shared("repo", rig.root)],
    )
  assert worktrees.unrecorded(trees, [workspaces.shared("repo", rig.root)]) == 0
}

// --- the operator's sweep -------------------------------------------------------

pub fn the_sweep_removes_clean_trees_and_keeps_dirty_ones_unless_named_test() {
  let rig = worktree_rig.rig("sweep")
  let clean = opened(rig, 1)
  let dirty = opened(rig, 2)
  let named = opened(rig, 3)
  write(dirty.path <> "/wip.txt", "x\n")
  write(named.path <> "/wip.txt", "x\n")

  let assert Ok(swept) =
    worktrees.sweep(rig.trees, [rig.workspace], forced: [session(3)])
  let by_session = list.map(swept, fn(each) { #(each.session, each.closed) })

  assert list.key_find(by_session, session(1)) == Ok(worktrees.Removed)
  let assert Ok(worktrees.Kept(_)) = list.key_find(by_session, session(2))
  assert list.key_find(by_session, session(3)) == Ok(worktrees.Removed)
  assert !exists(clean.path)
  assert exists(dirty.path <> "/wip.txt")
  assert !exists(named.path)

  // Nothing the sweep did deleted a branch.
  assert list.length(branches(rig)) == 3
}

// --- properties -----------------------------------------------------------------

pub fn a_refusal_reason_is_printable_and_within_the_wire_limit_test() {
  qcheck.run(properties(95), qcheck.string(), fn(text) {
    let reason = worktree_git.printable(text, 512)
    assert string.byte_size(reason) <= 512
    assert list.all(string.to_utf_codepoints(reason), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code >= 32 && code != 127
    })
  })
}

pub fn a_session_component_never_climbs_out_of_the_layout_test() {
  qcheck.run(properties(96), qcheck.string(), fn(name) {
    case worktrees.safe_component(name) {
      True -> {
        assert !string.contains(name, "/")
        assert !string.starts_with(name, ".")
      }
      False -> Nil
    }
  })
}

// Fixed seeds keep the gate deterministic: a failure reproduces.
fn properties(seed: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(seed))
}
