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
//// reaches here through `host.Capturing`). The same module also applies a held
//// state in a scope's tree, for an executor that was asked to put a parent's
//// checkout there.
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
//// state, by comparing the bytes with the description. The stage is removed
//// whichever way the capture ends. `repository_snapshot` leaves a failed stage
//// in place, because it cannot know that the processes using it have gone; this
//// module is the caller that does, since every Git call it makes has settled or
//// been cancelled by the time the capture returns. A stage that outlives its
//// process, because the daemon was killed mid-capture, is removed by `sweep`
//// when the next daemon starts, and its name is drawn at random so that one
//// left behind can never be the name a later capture is refused for.
////
//// ## Flow
////
//// `new` → `capture` | `capture_committed` | `apply` → `prepared` → `scope_of`, and
//// `sweep` at daemon start
////
//// 1. `new` binds the node's sandboxed Git, state root, node credentials, store
////    endpoint and a read handle on the store.
//// 2. `capture` makes the stage and the scratch directories, runs the snapshot
////    against a basis, reads the bundle it made and deposits it.
////    `capture_committed` is the same for a finished child's work: only the
////    commits, none of the working tree, and `capture_commits` is its form for a
////    primary checkout thin against a sent tip.
//// 3. `prepared` builds the call the captures make, and `scope_of` is its sandbox
////    policy: the workspace, with the state root and the node's credentials
////    masked.
//// 4. `sweep` empties the stage directory when a daemon starts, before any
////    capture can be running.
//// 5. `apply` is the other direction: it finds a state the store holds and has
////    `client/state_apply` check it out in a scope's tree.

import broker/policy
import client/git_identity.{type Identity}
import client/internal/ffi_pki
import client/repository_snapshot
import client/state_apply
import client/state_object.{type Basis, type State}
import client/state_store.{type Store}
import client/state_transfer.{type Endpoint}
import client/workspace_policy
import client/worktree_git.{type Git}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// How long one capture may take, in milliseconds. The snapshot's own Git calls
/// are bounded below this, and a caller that waits for a capture waits a little
/// longer than it.
pub const capture_within_ms = 180_000

/// A node's means of capturing a workspace and of applying a state it holds.
pub opaque type Capturer {
  Capturer(
    git: Git,
    state_root: String,
    credentials: List(String),
    states: Endpoint,
    store: Store,
  )
}

/// Binds what a capture needs: the node's sandboxed Git, its state root, the
/// node credential files every jailed call masks, the endpoint of the one
/// process that owns its store, and a read handle on that store's directory,
/// which `apply` reads a held bundle out of.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.new(git, state_root, [key, cookie], state_service.endpoint(service), store)
/// ```
pub fn new(
  git: Git,
  state_root: String,
  credentials: List(String),
  states: Endpoint,
  store: Store,
) -> Capturer {
  Capturer(git:, state_root:, credentials:, states:, store:)
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
  use #(call, snapshots, stage) <- result.try(prepared(capturer, directory))
  repository_snapshot.capture_against(
    capturer.git,
    call,
    snapshots,
    stage,
    identity,
    capture_within_ms,
    basis,
  )
  |> result.try(deposited(capturer, _))
  |> removing_stage_on_failure(snapshots <> "/" <> stage)
}

/// Captures the commits a finished child made in the repository at `directory`
/// after `base`, and only those (protocol-change/107, "Return").
///
/// `base` is the tip of the state the child was handed, which the sender already
/// holds, so the bundle is thin and small. The working tree is not read: edits the
/// child left uncommitted do not travel, and no author is needed. The answer is
/// `None` when the child committed nothing, and otherwise the description of the
/// state now in the store, whose base is `base`. A refusal says what is wrong
/// with the repository, such as a `HEAD` that does not descend from `base` or a
/// directory that is not a primary checkout.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.capture_commits(capturer, "/work/seeds/seed-0123", sent_tip)
/// ```
pub fn capture_commits(
  capturer: Capturer,
  directory: String,
  base: String,
) -> Result(Option(State), String) {
  capture_committed(
    capturer,
    directory,
    repository_snapshot.Primary,
    state_object.Thin(base),
  )
}

/// Captures what the repository at `directory` committed, bundled against
/// `basis`, with the working tree unread.
///
/// This is `capture_commits` for a directory that may be the linked worktree of
/// an executor's scope (`checkout` says which kind it must be), and for a basis
/// that may be `Full`. The answer is `None` for a `Thin` basis whose base is
/// `HEAD`, and otherwise the description of the state now in the store.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.capture_committed(capturer, tree, repository_snapshot.LinkedTo(common), state_object.Thin(sent_tip))
/// ```
pub fn capture_committed(
  capturer: Capturer,
  directory: String,
  checkout: repository_snapshot.Checkout,
  basis: Basis,
) -> Result(Option(State), String) {
  use #(call, snapshots, stage) <- result.try(prepared(capturer, directory))
  let made =
    repository_snapshot.capture_committed(
      capturer.git,
      call,
      snapshots,
      stage,
      capture_within_ms,
      checkout,
      basis,
    )

  // A child that committed nothing leaves no stage and no state.
  result.try(made, fn(made) {
    case made {
      None -> Ok(None)
      Some(snapshot) -> deposited(capturer, snapshot) |> result.map(Some)
    }
  })
  |> removing_stage_on_failure(snapshots <> "/" <> stage)
}

/// Applies a state this node holds into a scope's linked worktree
/// (protocol-change/107, "Apply"), and answers the tip it checked out.
///
/// The state must be in the node's store under the description given: a state
/// that is absent, partial, or held as something else is refused, because the
/// description is a claim a peer made and the store is the node's own record.
/// `repository` is the canonical primary checkout the tree belongs to,
/// `worktree` the tree, and `session` names the branch `loom/<session>` that is
/// moved onto the tip. `client/state_apply` does the rest, in the sandbox, with
/// no network and no hook, and refuses a tree that is not what it should be.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.apply(capturer, state, "/srv/repo", "/state/worktrees/repo/s-1", "s-1")
/// ```
pub fn apply(
  capturer: Capturer,
  state: State,
  repository: String,
  worktree: String,
  session: String,
) -> Result(String, String) {
  use found <- result.try(stored(capturer, state))
  state_apply.apply(
    capturer.git,
    found.path,
    found.state,
    state_apply.Reset(repository:, worktree:, session:),
  )
  |> result.map(fn(applied) { applied.tip })
}

/// The state in the node's store under the description that names it. A hash the
/// store does not hold is "not here", which the sender answers by sending it;
/// one it holds as another state is a description that is not this node's.
fn stored(
  capturer: Capturer,
  state: State,
) -> Result(state_store.Held, String) {
  case state_store.get(capturer.store, state.hash) {
    Ok(Some(found)) if found.state == state -> Ok(found)
    Ok(Some(_)) ->
      Error("this node's store holds a different state under that hash")
    Ok(None) -> Error("this node's store does not hold that state")
    Error(reason) -> Error(reason)
  }
}

/// The discovery call over a directory, the store the stage goes in, and the
/// stage's name. The directories are made private first, and the name is made
/// here from random bytes, so a model or a peer never chooses a path under the
/// store and a stage left by an earlier process never shares a name with this
/// one. A counter would not do: it starts again at one in every process.
fn prepared(
  capturer: Capturer,
  directory: String,
) -> Result(#(worktree_git.Capture, String, String), String) {
  let snapshots = capturer.state_root <> "/repository-snapshots"
  let scratch = capturer.state_root <> "/snapshot-scratch"
  use Nil <- result.try(bootstrap.ensure_private_directory(snapshots))
  use Nil <- result.map(bootstrap.ensure_private_directory(scratch))
  let call =
    worktree_git.Capture(
      directory:,
      arguments: [],
      scope: scope_of(capturer, directory, snapshots),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: capture_limits(),
    )
  let token =
    ffi_pki.random_bytes(8) |> bit_array.base16_encode |> string.lowercase
  let stage = "capture-" <> token
  #(call, snapshots, stage)
}

/// Removes the stage when a capture failed, and passes the answer on unchanged.
/// A success has removed it already, in `deposited` or by never making one.
fn removing_stage_on_failure(
  answer: Result(a, String),
  stage: String,
) -> Result(a, String) {
  // A failure removes the stage whichever step it came from, and a success has
  // nothing left to remove.
  case answer {
    Ok(_) -> answer
    Error(_) -> {
      let _removed = simplifile.delete(stage)
      answer
    }
  }
}

/// Removes every stage a capture left in the store, for a daemon that is starting.
///
/// A stage belongs to the capture that made it, and a capture runs inside the
/// daemon that started it, so none of the stages found when a daemon starts is
/// live. They are what a daemon killed mid-capture left, each a copy of a
/// repository's history. The directory itself stays, because the daemon makes it
/// before any session is admitted and every ordinary jail masks it. A directory
/// that cannot be read has nothing to remove.
///
/// ## Examples
///
/// ```gleam
/// // state_capture.sweep("/state")
/// ```
pub fn sweep(state_root: String) -> Nil {
  let snapshots = state_root <> "/repository-snapshots"

  // A directory that is not there has no stages, and one that cannot be read has
  // none this daemon can remove.
  case simplifile.read_directory(snapshots) {
    Ok(names) ->
      list.each(names, fn(name) {
        let _removed = simplifile.delete(snapshots <> "/" <> name)
        Nil
      })
    Error(_) -> Nil
  }
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
