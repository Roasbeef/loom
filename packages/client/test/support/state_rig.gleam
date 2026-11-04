//// A real source repository, the sandboxed Git and a capture call for the
//// tests of repository states (protocol-change/107).
////
//// Every test gets a repository of its own with one commit on `main`, a state
//// root laid out as a daemon leaves it, and the production
//// `client/worktree_git` over the shipped sandbox helper. Git itself is run
//// here, outside any jail, for setup and for assertions, because the tests are
//// the operator: what is under test is that the executor never does.

import broker/exec
import broker/policy
import client/git_identity
import client/internal/ffi_os
import client/repository_snapshot
import client/state_object
import client/worktree_git
import gleam/bit_array
import gleam/int
import gleam/option.{Some}
import host/bootstrap
import simplifile
import support/worktree_rig

/// What one test needs.
pub type Rig {
  Rig(
    /// The sandboxed Git, which capture and apply both run through.
    git: worktree_git.Git,
    /// A discovery call over the source repository, ready for capture.
    call: worktree_git.Capture,
    /// The source repository's top directory.
    root: String,
    /// The scratch directory that holds the rig's other directories.
    scratch: String,
    /// The state root the sandboxed Git masks, with its daemon entries.
    state: String,
    /// The directory capture makes its private stages in.
    snapshots: String,
  )
}

/// A rig over a new repository.
pub fn rig(name: String) -> Rig {
  let directory =
    "build/state-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the scratch directory is created"
  let assert Ok(scratch) = bootstrap.canonical_directory(directory)
    as "the scratch directory resolves"
  let state = scratch <> "/state"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state root is created"
  worktree_rig.establish(state)
  let discovery = state <> "/discovery"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(discovery)
    as "the discovery directory is created"
  let root = worktree_rig.repository(scratch <> "/repo")
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let assert Ok(git) =
    worktree_git.start(
      worktree_git.Config(
        helper_path: here <> "/../sandbox/loom-exec",
        scratch: state <> "/git-runner",
        state_root: state,
        demand: exec.BestEffort,
        credentials: [],
      ),
    )
    as "the sandboxed Git starts"
  let snapshots = state <> "/repository-snapshots"
  let call =
    worktree_git.Capture(
      directory: root,
      arguments: [],
      scope: policy.SandboxPolicy(..policy.workspace_default(root), protected: [
        snapshots,
      ]),
      staging: discovery,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 30,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_073_741_824,
        output_bytes: 65_536,
      ),
    )
  Rig(git:, call:, root:, scratch:, state:, snapshots:)
}

/// Stops the sandboxed Git.
pub fn stop(rig: Rig) -> Nil {
  let assert Ok(Nil) = worktree_git.stop(rig.git) as "the sandboxed Git drains"
  Nil
}

/// The identity a capture's snapshot commit is authored with.
pub fn identity() -> git_identity.Identity {
  git_identity.Identity(Some("Owner"), Some("owner@example.invalid"))
}

/// Captures the source with a full or thin bundle, answering Git's refusal
/// when there is one.
pub fn try_capture(
  rig: Rig,
  stage: String,
  basis: state_object.Basis,
) -> Result(repository_snapshot.Snapshot, String) {
  repository_snapshot.capture_against(
    rig.git,
    rig.call,
    rig.snapshots,
    stage,
    identity(),
    120_000,
    basis,
  )
}

/// Captures the source and requires it to succeed.
pub fn capture(
  rig: Rig,
  stage: String,
  basis: state_object.Basis,
) -> repository_snapshot.Snapshot {
  let assert Ok(snapshot) = try_capture(rig, stage, basis)
    as "the capture succeeds"
  snapshot
}

/// The state a snapshot's bundle describes, computed from its bytes the way the
/// store computes it.
pub fn state_of(snapshot: repository_snapshot.Snapshot) -> state_object.State {
  let assert Ok(bytes) = simplifile.read_bits(snapshot.bundle)
    as "the bundle is readable"
  state_object.State(
    hash: state_object.hash_of(bytes),
    size: bit_array.byte_size(bytes),
    tip: snapshot.commit,
    base: snapshot.base,
    dirty: snapshot.dirty,
  )
}

/// Commits a file with one operator Git call per step and answers the new
/// commit.
pub fn commit_file(
  root: String,
  name: String,
  text: String,
  message: String,
) -> String {
  worktree_rig.write(root <> "/" <> name, text)
  let _added = worktree_rig.git(root, ["add", name])
  let _committed = worktree_rig.git(root, ["commit", "--quiet", "-m", message])
  worktree_rig.git(root, ["rev-parse", "HEAD"])
}

/// A clone of the source at its current state: a primary checkout that holds
/// everything the source has committed so far.
pub fn clone(rig: Rig, name: String) -> String {
  let destination = rig.scratch <> "/" <> name
  let _cloned =
    worktree_rig.git(rig.scratch, [
      "clone",
      "--quiet",
      rig.root,
      destination,
    ])
  let assert Ok(canonical) = bootstrap.canonical_directory(destination)
    as "the clone resolves"
  canonical
}

/// Every ref of a repository with the object it names, sorted, for comparing
/// before and after.
pub fn refs(root: String) -> String {
  worktree_rig.git(root, [
    "for-each-ref",
    "--format=%(refname) %(objectname)",
  ])
}
