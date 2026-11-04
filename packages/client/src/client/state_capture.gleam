//// Capturing a workspace into this node's state store (protocol-change/107,
//// "Capture").
////
//// `client/repository_snapshot` makes a verified bundle of a quiescent workspace
//// in a private stage, and `client/state_store` keeps bundles under their hash.
//// Neither knows the other. This module is the step between them that a node
//// runs when it holds the repository a spawn wants to send: it builds the
//// capture call, runs the capture inside the sandbox, reads the bundle it made,
//// describes it, puts it in the store, and removes the stage. The node is the
//// orchestrator for a session whose workspace is local, and the executor that
//// serves the workspace for one whose workspace is remote (the executor's plane
//// reaches here through `host.Capturing`).
////
//// ## What the caller owes
////
//// `repository_snapshot` cannot check that the workspace is quiet, so the caller
//// must have drained it. The orchestrator takes the session's workspace gate
//// (`client/workspace_gate`) around the call, and an executor's capture is made
//// under the same gate on the orchestrator's side of the link, because the
//// request is sent while the gate is held. This module takes no lock of its own.
////
//// ## What stays private
////
//// Every Git process runs through the node's sandboxed Git (`client/worktree_git`)
//// with the network off and the state root masked, and the capture's one writable
//// root is its own stage under `repository-snapshots`, which no session can read.
//// The bundle reaches the store through the store's own endpoint, in the pieces a
//// peer's would arrive in, so a state is made the one way the store makes any
//// state, by comparing the bytes with the description. The stage is removed on
//// success. After a failure it stays, as `repository_snapshot` leaves it, until
//// the processes that may still use it are known to have drained.
////
//// ## Flow
////
//// `new` → `capture` → `scope_of`
////
//// 1. `new` binds the node's sandboxed Git, state root, node credentials and
////    store endpoint.
//// 2. `capture` makes the stage and the scratch directories, runs the snapshot
////    against a basis, reads the bundle it made and deposits it.
//// 3. `scope_of` is the sandbox policy of the capture: the workspace, with the
////    state root and the node's credentials masked.

import broker/policy
import client/git_identity.{type Identity}
import client/internal/ffi_os
import client/repository_snapshot
import client/state_object.{type Basis, type State}
import client/state_transfer.{type Endpoint}
import client/workspace_policy
import client/worktree_git.{type Git}
import gleam/bit_array
import gleam/int
import gleam/result
import host/bootstrap
import simplifile

/// How long one capture may take, in milliseconds. The snapshot's own Git calls
/// are bounded below this, and a caller that waits for a capture waits a little
/// longer than it.
pub const capture_within_ms = 180_000

/// A node's means of capturing a workspace.
pub opaque type Capturer {
  Capturer(
    git: Git,
    state_root: String,
    credentials: List(String),
    states: Endpoint,
  )
}

/// Binds what a capture needs: the node's sandboxed Git, its state root, the
/// node credential files every jailed call masks, and the endpoint of the one
/// process that owns its store.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.new(git, state_root, [key, cookie], state_service.endpoint(service))
/// ```
pub fn new(
  git: Git,
  state_root: String,
  credentials: List(String),
  states: Endpoint,
) -> Capturer {
  Capturer(git:, state_root:, credentials:, states:)
}

/// Captures the workspace at `directory` into the node's store.
///
/// `basis` is `Full`, or `Thin` against a commit the receiver holds, and
/// `identity` is the author of the snapshot commit when the workspace has
/// uncommitted work: a clean workspace needs none, and a dirty one without a
/// complete identity is refused rather than given an invented author. The answer
/// is the description of the state now in the store, which is what a `Request`
/// names. A refusal is Git's or the snapshot's own account of what is wrong with
/// the workspace (a submodule, a shallow clone, a size over the store's limit),
/// and capturing again does not change it.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.capture(capturer, "/work/loom", identity, state_object.Full)
/// ```
pub fn capture(
  capturer: Capturer,
  directory: String,
  identity: Identity,
  basis: Basis,
) -> Result(State, String) {
  let snapshots = capturer.state_root <> "/repository-snapshots"
  let scratch = capturer.state_root <> "/snapshot-scratch"
  use Nil <- result.try(bootstrap.ensure_private_directory(snapshots))
  use Nil <- result.try(bootstrap.ensure_private_directory(scratch))

  // The stage name is made here from a counter, so a model or a peer never
  // chooses a path under the store.
  let stage = "capture-" <> int.to_string(ffi_os.unique_positive_integer())
  use made <- result.try(repository_snapshot.capture_against(
    capturer.git,
    worktree_git.Capture(
      directory:,
      arguments: [],
      scope: scope_of(capturer, directory, snapshots),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: capture_limits(),
    ),
    snapshots,
    stage,
    identity,
    capture_within_ms,
    basis,
  ))
  deposited(capturer, made)
}

/// Reads the bundle a snapshot made, describes it from its bytes, and puts it in
/// the store. The stage goes with the bundle once the store holds the state.
fn deposited(
  capturer: Capturer,
  made: repository_snapshot.Snapshot,
) -> Result(State, String) {
  use bytes <- result.try(bootstrap.read_bounded(
    made.bundle,
    state_object.size_limit,
  ))
  let state =
    state_object.State(
      hash: state_object.hash_of(bytes),
      size: bit_array.byte_size(bytes),
      tip: made.commit,
      base: made.base,
      dirty: made.dirty,
    )
  use state <- result.try(state_object.validate(state))

  // Only a store that finished the state lets the stage go.
  case state_transfer.deposit(capturer.states, state, bytes) {
    state_transfer.Delivered -> {
      let _removed = simplifile.delete(made.stage)
      Ok(state)
    }
    state_transfer.Declined(refusal:) -> Error(state_transfer.describe(refusal))
    state_transfer.Faulted(reason:) -> Error(reason)
    state_transfer.Silent -> Error("the state store did not answer in time")
    state_transfer.Stalled ->
      Error("the state store kept answering without taking the bundle")
  }
}

/// The sandbox policy a capture's Git runs under: the host is readable as for a
/// session's tools, which a linked worktree needs because its Git metadata is in
/// the primary checkout beside it, the state root's secrets and the node's credentials
/// are masked, and the snapshot store is protected so `repository_snapshot` can
/// grant itself the one stage it writes.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.scope_of(capturer, "/work/loom", "/state/repository-snapshots").protected
/// ```
fn scope_of(
  capturer: Capturer,
  directory: String,
  snapshots: String,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(directory),
    readable_roots: ["/"],
    protected: [snapshots],
  )
  |> workspace_policy.protecting_state_root(capturer.state_root)
  |> workspace_policy.protecting_node_credentials(capturer.credentials)
}

/// The resources one capture's Git calls may use. The snapshot clamps them to
/// its own ceilings, so these are the widest it will take.
fn capture_limits() -> policy.Limits {
  policy.Limits(
    cpu_s: 300,
    wall_s: 600,
    mem_bytes: 2_147_483_648,
    pids: 64,
    fsize_bytes: 1_073_741_824,
    output_bytes: 1_048_576,
  )
}
