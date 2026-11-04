//// The parent's end of a return: putting a finished child's commits into the
//// repository it was started from (protocol-change/107, "Return").
////
//// The commits are already in this machine's state store when a join says so
//// (`client/spawn_return` sent them). This module is the step between that and
//// `client/state_apply.apply_returned`: it finds the two bundles in the store,
//// checks that the session is still working in the workspace the child was
//// started from, and applies behind the workspace's gate.
////
//// ## The workspace it applies into
////
//// A spawn records the canonical directory it captured. The commits are applied
//// only when the session's workspace resolves to that same directory now, so a
//// session that was moved, or whose workspace was changed, does not take a child's
//// commits into a repository the child never saw. The apply itself refuses
//// anything but a primary checkout whose `.git` is a directory.
////
//// ## Why the gate's exclusive side
////
//// The apply writes objects and a ref under `.git`, and the sent tip of a dirty
//// workspace is a commit that only the bundle ever held, so the objects it
//// unpacks are unreferenced from the moment they land until the ref is made. A
//// tool call running `git gc --prune=now` or `git repack -ad` in that window would
//// remove them, and the ref would then name a commit the repository cannot read.
//// The shared side keeps a capture out and nothing else: every other workspace
//// tool call also holds it, so it would not keep a `git gc` out. The apply
//// therefore takes the exclusive side, as a capture does, and for the same
//// reason: while it runs no tool call of the session runs in the workspace. It
//// waits at most `workspace_gate.drain_ms` for calls in flight, and a drain that
//// does not finish is a reason to try again and not a refusal.
////
//// ## Flow
////
//// `from_store` → `held` → `behind_gate` → `applied`
////
//// 1. `from_store` is the apply over this node's store and sandboxed Git: it reads
////    the two bundles with `held` and runs `state_apply.apply_returned`.
//// 2. `behind_gate` is what a session runs: the workspace check, then `applied`,
////    which runs the apply inside the gate and words the gate's three refusals
////    as reasons to retry.

import client/remote_child.{type Returned}
import client/state_apply
import client/state_object.{type State}
import client/state_store.{type Store}
import client/workspace_gate.{type Gate}
import client/worktree_git.{type Git}
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import host/bootstrap

/// The apply over a node's store and Git. The arguments are the directory of the
/// repository, the state the spawn sent, the state the child returned and the
/// child's strand. The answer is the ref the commits are under and how many there
/// are, or the reason there is none.
///
/// ## Examples
///
/// ```gleam
/// // return_apply.from_store(store, git)("/work/loom", sent, returned, "sub:^main/fix-1a2b")
/// // == Ok(#("refs/loom/children/fix-1a2b/01234567", 2))
/// ```
pub fn from_store(
  store: Store,
  git: Git,
) -> fn(String, State, State, String) -> Result(#(String, Int), String) {
  fn(workspace, sent, returned, child) {
    use held_sent <- result.try(held(store, sent))
    use held_returned <- result.try(held(store, returned))
    use applied <- result.map(state_apply.apply_returned(
      git,
      workspace,
      child,
      state_apply.Sent(bundle: held_sent.path, state: held_sent.state),
      held_returned.path,
      held_returned.state,
    ))
    #(applied.ref, applied.commits)
  }
}

/// Finds a complete state in the store under the description that names it.
fn held(store: Store, state: State) -> Result(state_store.Held, String) {
  // A state the store does not hold, or holds as something else, is no state.
  case state_store.get(store, state.hash) {
    Ok(Some(found)) if found.state == state -> Ok(found)
    Ok(Some(_)) ->
      Error("this machine's store holds a different state under that hash")
    Ok(None) -> Error("this machine's store no longer holds the state")
    Error(reason) -> Error(reason)
  }
}

/// Applies a child's returned commits into the session's workspace, behind its
/// gate.
///
/// `Ok` is a decision that will not change: the commits are in the repository
/// (`Applied`), or they cannot be put there (`NotApplied`), such as a workspace
/// that is not the one the child started from or a bundle that does not agree
/// with its description. `Error` is a reason to try again, from the gate: the
/// workspace did not go quiet in `drain_ms`, or the apply outlived its hold and
/// its answer was discarded, in which case a repeat finds the ref it made and
/// changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // return_apply.behind_gate(gate, 30_000, 330_000, workspace, seeded_from, apply, sent, returned, child)
/// ```
pub fn behind_gate(
  gate: Gate,
  drain_ms: Int,
  hold_ms: Int,
  workspace: String,
  seeded_from: String,
  apply: fn(String, State, State, String) -> Result(#(String, Int), String),
  sent: State,
  returned: State,
  child: String,
) -> Result(Returned, String) {
  // The commits go only where the child's workspace was captured from.
  case bootstrap.canonical_directory(workspace) {
    Ok(directory) if directory == seeded_from ->
      applied(gate, drain_ms, hold_ms, directory, apply, sent, returned, child)
    Ok(_) ->
      Ok(remote_child.NotApplied(
        "this session's workspace is not the one the child was started from",
      ))
    Error(_) ->
      Ok(remote_child.NotApplied("this session's workspace cannot be read"))
  }
}

/// Runs the apply inside the gate and words the gate's refusals.
fn applied(
  gate: Gate,
  drain_ms: Int,
  hold_ms: Int,
  directory: String,
  apply: fn(String, State, State, String) -> Result(#(String, Int), String),
  sent: State,
  returned: State,
  child: String,
) -> Result(Returned, String) {
  let work = fn() { apply(directory, sent, returned, child) }

  // The apply's own answer is final; the gate's refusals are reasons to retry.
  case workspace_gate.exclusive(gate, drain_ms, hold_ms, work) {
    Ok(Ok(#(ref, commits))) -> Ok(remote_child.Applied(ref:, commits:))
    Ok(Error(reason)) -> Ok(remote_child.NotApplied(reason))
    Error(workspace_gate.NotQuiet) ->
      Error(
        "the workspace did not go quiet: a tool call was still running after "
        <> int.to_string(drain_ms / 1000)
        <> " seconds",
      )
    Error(workspace_gate.Lapsed) ->
      Error("applying them took too long and was discarded")
    Error(workspace_gate.Unavailable) ->
      Error("the workspace's gate did not answer")
  }
}

/// The apply of a node that has no store or no sandboxed Git: every attempt is a
/// refusal that says so.
///
/// ## Examples
///
/// ```gleam
/// assert return_apply.unavailable()("/w", sent, returned, "c") == Error("...")
/// ```
pub fn unavailable() -> fn(String, State, State, String) ->
  Result(#(String, Int), String) {
  fn(_workspace, _sent, _returned, _child) {
    Error(
      "this machine keeps no state store or has no sandboxed Git to apply them with",
    )
  }
}
