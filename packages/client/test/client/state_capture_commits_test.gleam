//// Capturing the commits a finished child made, against a real repository and
//// the real sandbox helper (protocol-change/107, "Return").
////
//// The child is a repository made from a captured state, the way a receiving
//// daemon makes one. The tests commit in it, leave edits uncommitted, and look at
//// what the capture carries (the commits and nothing else), at what it leaves
//// alone (the child's tree, index and refs), and at what it refuses (a history
//// that no longer holds the sent tip, and a directory that is not the primary
//// checkout it names).

import client/internal/ffi_os
import client/state_apply.{Clone}
import client/state_capture
import client/state_object.{type State, Full}
import client/state_service
import client/state_store
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig

type Scenario {
  Scenario(
    rig: Rig,
    capturer: state_capture.Capturer,
    store: state_store.Store,
    /// The state the parent sent, which the child's history starts from.
    sent: State,
    /// The child's repository.
    child: String,
  )
}

// A parent with uncommitted work whose state was sent and applied as a child's
// copy, so the child's `HEAD` is the sent snapshot commit.
fn scenario(name: String) -> Scenario {
  let rig = state_rig.rig(name)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let capturer =
    state_capture.new(rig.git, rig.state, [], state_service.endpoint(service))
  worktree_rig.write(rig.root <> "/README", "parent edit\n")
  let assert Ok(sent) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  let assert Ok(Some(held)) = state_store.get(store, sent.hash)
  let child = rig.scratch <> "/child"
  let assert Ok(_applied) =
    state_apply.apply(
      rig.git,
      held.path,
      held.state,
      Clone(destination: child, session: "seed-0123456789abcdef"),
    )
  Scenario(rig:, capturer:, store:, sent:, child:)
}

pub fn only_the_commits_a_child_made_are_captured_test() {
  let scenario = scenario("commits-only")
  let rig = scenario.rig
  let child = scenario.child
  let _ = state_rig.commit_file(child, "first.txt", "one\n", "child one")
  let tip = state_rig.commit_file(child, "second.txt", "two\n", "child two")

  // Work the child did not commit: an edit, a staged file and an untracked one.
  worktree_rig.write(child <> "/README", "never committed\n")
  worktree_rig.write(child <> "/staged.txt", "staged\n")
  let _ = worktree_rig.git(child, ["add", "staged.txt"])
  worktree_rig.write(child <> "/untracked.txt", "untracked\n")
  let refs = state_rig.refs(child)
  let status = worktree_rig.git(child, ["status", "--porcelain"])

  let assert Ok(Some(state)) =
    state_capture.capture_commits(scenario.capturer, child, scenario.sent.tip)
  assert state.tip == tip
  assert state.base == Some(scenario.sent.tip)
  assert state.dirty == state_object.Clean
  let assert Ok(Some(held)) = state_store.get(scenario.store, state.hash)
  assert held.state == state

  // The bundle is thin against the sent tip alone.
  let assert Ok(bytes) = simplifile.read_bits(held.path)
  let assert Ok(header) = state_object.parse_header(bytes)
  assert header.prerequisites == [scenario.sent.tip]
  assert state_object.verify_bundle(state, bytes) == Ok(Nil)

  // The child is exactly as it was, and its stage is gone.
  assert state_rig.refs(child) == refs
  assert worktree_rig.git(child, ["status", "--porcelain"]) == status
  assert simplifile.read(child <> "/README") == Ok("never committed\n")
  let assert Ok(stages) = simplifile.read_directory(rig.snapshots)
  assert stages == []

  // Applied in the parent, the commits are there and the edits are not.
  let assert Ok(returned) =
    state_apply.apply_returned(
      rig.git,
      rig.root,
      "sub:^main/finish-the-cache-0123456789abcdef",
      state_apply.Sent(
        bundle: {
          let assert Ok(Some(sent)) =
            state_store.get(scenario.store, scenario.sent.hash)
          sent.path
        },
        state: scenario.sent,
      ),
      held.path,
      state,
    )
  assert returned.tip == tip
  assert worktree_rig.git(rig.root, ["show", tip <> ":README"]) == "parent edit"
  assert worktree_rig.git(rig.root, ["show", tip <> ":second.txt"]) == "two"
  let assert Error(_) = simplifile.read_bits(rig.root <> "/staged.txt")
  assert worktree_rig.git(rig.root, ["ls-tree", "--name-only", tip])
    |> string.contains("staged.txt")
    == False
  state_rig.stop(rig)
}

pub fn a_child_that_committed_nothing_returns_nothing_test() {
  let scenario = scenario("commits-none")
  let rig = scenario.rig

  // An edit that stays uncommitted is not a commit.
  worktree_rig.write(scenario.child <> "/README", "never committed\n")
  assert state_capture.capture_commits(
      scenario.capturer,
      scenario.child,
      scenario.sent.tip,
    )
    == Ok(None)
  let assert Ok(stages) = simplifile.read_directory(rig.snapshots)
  assert stages == []
  state_rig.stop(rig)
}

pub fn a_history_that_no_longer_holds_the_sent_tip_is_refused_test() {
  let scenario = scenario("commits-rewritten")
  let rig = scenario.rig
  let child = scenario.child

  // The child discards the sent snapshot and commits on the parent's own head,
  // so its history is unrelated to the state it was handed.
  let _ = worktree_rig.git(child, ["reset", "--hard", "--quiet", "HEAD~1"])
  let _ = state_rig.commit_file(child, "other.txt", "other\n", "elsewhere")
  let assert Error(reason) =
    state_capture.capture_commits(scenario.capturer, child, scenario.sent.tip)
  assert string.contains(reason, "ancestor")
  state_rig.stop(rig)
}

pub fn a_directory_that_is_not_the_primary_checkout_it_names_is_refused_test() {
  let scenario = scenario("commits-directory")
  let rig = scenario.rig
  let _ = state_rig.commit_file(scenario.child, "a.txt", "a\n", "child one")

  // A link to the child, which a session could plant in its place.
  let link = rig.scratch <> "/link"
  let assert Ok(Nil) = simplifile.create_symlink(scenario.child, link)
  let assert Error(_) =
    state_capture.capture_commits(scenario.capturer, link, scenario.sent.tip)

  // A linked worktree of the child keeps its metadata elsewhere.
  let tree = rig.scratch <> "/tree"
  let _ =
    worktree_rig.git(scenario.child, [
      "worktree", "add", "--quiet", "--detach", tree, "HEAD",
    ])
  let assert Error(reason) =
    state_capture.capture_commits(scenario.capturer, tree, scenario.sent.tip)
  assert string.contains(reason, "primary checkout")

  // A directory that is not a repository at all.
  let assert Error(_) =
    state_capture.capture_commits(scenario.capturer, rig.scratch, "x")
  state_rig.stop(rig)
}

pub fn a_hostile_child_configuration_does_not_change_what_is_captured_test() {
  let scenario = scenario("commits-hostile")
  let rig = scenario.rig
  let child = scenario.child
  let tip = state_rig.commit_file(child, "first.txt", "one\n", "child one")

  // A file-system monitor, a hook path, a clean filter attached by an attribute
  // and a rewrite of every path to a transport: none may change the bundle or
  // fail the capture.
  let program = child <> "/.git/evil"
  worktree_rig.write(program, "#!/bin/sh\nexit 1\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(program, 0o755)
  let _ = worktree_rig.git(child, ["config", "core.fsmonitor", program])
  let _ =
    worktree_rig.git(child, ["config", "core.hooksPath", child <> "/.git"])
  let _ = worktree_rig.git(child, ["config", "filter.evil.clean", program])
  let _ = worktree_rig.git(child, ["config", "protocol.ext.allow", "always"])
  let _ =
    worktree_rig.git(child, [
      "config",
      "url.ext::" <> program <> " .insteadOf",
      "/",
    ])
  worktree_rig.write(child <> "/.git/info/attributes", "*.txt filter=evil\n")

  let assert Ok(Some(state)) =
    state_capture.capture_commits(scenario.capturer, child, scenario.sent.tip)
  assert state.tip == tip
  assert list.length(string.split(
      worktree_rig.git(child, ["rev-list", tip, "^" <> scenario.sent.tip]),
      "\n",
    ))
    == 1
  state_rig.stop(rig)
}
