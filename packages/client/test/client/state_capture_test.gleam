//// Capturing a workspace into a node's store, against a real repository and the
//// real sandbox helper (protocol-change/107, "Capture").
////
//// A source with committed history, an edit to a tracked file and a new file
//// is captured through the node's own store service. The tests then look at
//// what is in the store, at the source, which must be byte for byte as it was,
//// and at the one thing that reads the store afterwards: the sandboxed apply,
//// which has to be able to open a bundle that every session's jail cannot.

import client/git_identity
import client/internal/ffi_os
import client/state_apply.{Clone}
import client/state_capture
import client/state_object.{Dirty, Full}
import client/state_service
import client/state_store
import client/worktree_git
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig

fn capturer(rig: Rig) -> #(state_capture.Capturer, state_store.Store) {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  #(
    state_capture.new(rig.git, rig.state, [], state_service.endpoint(service)),
    store,
  )
}

// A tracked file edited and a file that is new, which is the work a spawn from a
// parent in the middle of a task carries.
fn dirty(rig: Rig) -> Nil {
  worktree_rig.write(rig.root <> "/README", "edited by the parent\n")
  worktree_rig.write(rig.root <> "/notes.txt", "not committed anywhere\n")
}

pub fn a_dirty_workspace_becomes_a_stored_state_the_source_never_notices_test() {
  let rig = state_rig.rig("capture-dirty")
  let #(capturer, store) = capturer(rig)
  dirty(rig)
  let refs = state_rig.refs(rig.root)
  let assert Ok(readme) = simplifile.read(rig.root <> "/README")

  let assert Ok(state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)

  // The store holds the state whole, under the hash of its own bytes, and the
  // stage is gone with the bundle it made.
  assert state.dirty == Dirty
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  assert held.state == state
  assert string.ends_with(held.path, state.hash <> ".bundle")
  let assert Ok(stages) = simplifile.read_directory(rig.snapshots)
  assert stages == []

  // The parent's checkout is exactly as it was: no ref, no file, no index.
  assert state_rig.refs(rig.root) == refs
  assert simplifile.read(rig.root <> "/README") == Ok(readme)
  assert worktree_rig.exists(rig.root <> "/notes.txt")
  state_rig.stop(rig)
}

pub fn the_stored_state_applies_into_a_checkout_that_equals_the_snapshot_test() {
  let rig = state_rig.rig("capture-apply")
  let #(capturer, store) = capturer(rig)
  dirty(rig)
  let assert Ok(state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  let assert Ok(Some(held)) = state_store.get(store, state.hash)

  // The store is masked from every jail, the runner's included, and the apply
  // reads it through the one call the runner lifts the mask for.
  let destination = rig.scratch <> "/applied"
  let assert Ok(applied) =
    state_apply.apply(
      rig.git,
      held.path,
      held.state,
      Clone(destination:, session: worktree_rig.session(1)),
    )
  assert applied.tip == state.tip
  assert simplifile.read(destination <> "/README")
    == Ok("edited by the parent\n")
  assert simplifile.read(destination <> "/notes.txt")
    == Ok("not committed anywhere\n")
  state_rig.stop(rig)
}

pub fn a_clean_workspace_needs_no_author_and_a_dirty_one_is_refused_without_one_test() {
  let rig = state_rig.rig("capture-author")
  let #(capturer, _store) = capturer(rig)
  let nobody = git_identity.Identity(None, None)

  // Nothing to snapshot: the tip is `HEAD`, and no commit is made to sign.
  let assert Ok(clean) = state_capture.capture(capturer, rig.root, nobody, Full)
  assert clean.dirty == state_object.Clean

  // Uncommitted work needs a snapshot commit, and an author is never invented.
  dirty(rig)
  let assert Error(reason) =
    state_capture.capture(capturer, rig.root, nobody, Full)

  // The reason says where the identity has to be set, because a setting in the
  // repository is not read and an operator would look there first.
  assert string.contains(reason, "global Git configuration")
  assert string.contains(reason, "git config --global user.name")
  assert string.contains(
    reason,
    "a setting in the repository itself is not used",
  )
  state_rig.stop(rig)
}

pub fn a_directory_that_is_not_a_repository_is_refused_with_a_reason_test() {
  let rig = state_rig.rig("capture-none")
  let #(capturer, _store) = capturer(rig)
  let empty = rig.scratch <> "/empty"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(empty)
  let assert Error(reason) =
    state_capture.capture(capturer, empty, state_rig.identity(), Full)
  assert string.length(reason) > 0
  state_rig.stop(rig)
}

// The grant is for the unpack and for nothing else: the same runner, asked to
// read the same bundle through its ordinary call, finds the store masked, as a
// session's tool does.
pub fn the_runners_ordinary_calls_cannot_read_the_store_test() {
  let rig = state_rig.rig("capture-sealed")
  let #(capturer, store) = capturer(rig)
  dirty(rig)
  let assert Ok(state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let call =
    worktree_git.Run(directory: rig.root, writable: [], arguments: [
      "bundle", "verify", held.path,
    ])
  let assert Ok(sealed) = worktree_git.run(rig.git, call, 60_000)
  assert sealed.code != 0
  let assert Ok(lifted) = worktree_git.run_reading_store(rig.git, call, 60_000)
  assert lifted.code == 0
  state_rig.stop(rig)
}

// A capture that fails after its stage exists, here for want of an author, takes
// the stage with it: the stage is a copy of the repository's history, and
// nothing will come back for it.
pub fn a_failed_capture_leaves_no_stage_behind_test() {
  let rig = state_rig.rig("capture-failed")
  let #(capturer, _store) = capturer(rig)
  dirty(rig)
  let nobody = git_identity.Identity(None, None)

  let assert Error(_) = state_capture.capture(capturer, rig.root, nobody, Full)
  assert simplifile.read_directory(rig.snapshots) == Ok([])
  state_rig.stop(rig)
}

// A stage that an earlier process left behind, which a kill mid-capture does,
// is not in the way of a new capture, and the start of the next daemon removes it
// while keeping the directory every jail masks.
pub fn a_stage_from_an_earlier_process_blocks_nothing_and_is_swept_test() {
  let rig = state_rig.rig("capture-leftover")
  let #(capturer, _store) = capturer(rig)

  // The name an earlier process drew from its own counter.
  let leftover = rig.snapshots <> "/capture-1"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(leftover)
  let assert Ok(Nil) =
    simplifile.write(leftover <> "/snapshot.bundle", "half a bundle")

  let assert Ok(_state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  assert simplifile.read_directory(rig.snapshots) == Ok(["capture-1"])

  state_capture.sweep(rig.state)
  assert simplifile.is_directory(rig.snapshots) == Ok(True)
  assert simplifile.read_directory(rig.snapshots) == Ok([])
  state_rig.stop(rig)
}
