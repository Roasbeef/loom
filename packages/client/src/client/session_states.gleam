//// What a session can do with repository states when its workspace is on an
//// executor (protocol-change/107, slice 4b).
////
//// A seeded child on an executor or a pool starts from a copy of its parent's
//// workspace, and the copy has to be put into the child's own workspace before
//// the child runs. The orchestrator that holds the child's session is the only
//// machine that can do it: it holds the scope's attach token and incarnation,
//// which fence every message that changes the workspace, and it holds the state
//// in its store. This module is the record of what that orchestrator can do,
//// so that the code deciding when to do it (`client/spawn_seed`,
//// `client/spawn_return`) does not import the executor link or the surface.
////
//// ## Why the functions are closures
////
//// The attach token is minted when a session opens and is replaced when it
//// opens again. A closure over the surface cannot outlive the open it was made
//// in, and a fence that has moved on refuses its request, which is the property
//// wanted. A caller holds the record of the session that is resident now and
//// never keeps one across a close.
////
//// ## What a failure means
////
//// Every operation answers `Failure`: `Later` when asking again can succeed (the
//// executor did not answer in time), and `Final` when it cannot (the workspace
//// refused the state, the fence is stale). A caller turns the first into a
//// request to ask again and the second into a refusal.

import client/state_object.{type Basis, type Content, type State}
import client/state_transfer.{type Link}
import gleam/option.{type Option}

/// Why an operation on the executor did not succeed.
pub type Failure {
  /// The executor did not answer within the time allowed. Nothing is known to
  /// have happened, and the operation is safe to repeat.
  Later(reason: String)

  /// The executor answered no, for a reason that repeating does not change.
  Final(reason: String)
}

/// Whether a session has started a child, as far as its orchestrator can tell.
pub type Freshness {
  /// No child was ever started in the session, so a state may be put into its
  /// workspace.
  Fresh

  /// A child was started. The workspace holds work a state would replace.
  Begun

  /// The orchestrator could not read the session's record, because its holder is
  /// not up or the read failed. It does not know, and a state is neither put in
  /// nor skipped on a guess: the caller asks again.
  Unreadable
}

/// The reason an apply is refused once the session has begun.
pub const already_begun =
  "the session has already begun, and a state is put into a workspace only before its first turn"

/// The reason an apply waits when the session's record cannot be read.
pub const unreadable =
  "the session's record could not be read to tell whether it has begun; ask again"

/// The same states, with `apply` refused once the session has begun, and put off
/// when it cannot be told whether it has.
///
/// The executor cannot tell a tree the session has worked in from a fresh one
/// beyond a few checks, so the orchestrator, which knows whether it has started
/// a child, is the one that holds the line. `fresh` is asked each time, at the
/// moment of the request and not once at construction, so a session that began
/// between two calls is refused the second.
///
/// ## Examples
///
/// ```gleam
/// // session_states.before_first_turn(states, fn() { session_states.Begun }).apply(state)
/// // == Error(session_states.Final(session_states.already_begun))
/// ```
pub fn before_first_turn(
  states: SessionStates,
  fresh: fn() -> Freshness,
) -> SessionStates {
  SessionStates(..states, apply: fn(state) {
    case fresh() {
      Fresh -> states.apply(state)
      Begun -> Error(Final(already_begun))
      Unreadable -> Error(Later(unreadable))
    }
  })
}

/// A session's way to move states in and out of its workspace on an executor.
pub type SessionStates {
  SessionStates(
    /// The `[executors.<name>]` that holds the session, for a log line.
    executor: String,
    /// The Git branch the session's worktree has on that executor,
    /// `loom/<session id>`, which is where an operator finds commits the return
    /// gave up on.
    branch: String,
    /// The link to the executor's state store. A state sent over it lands in the
    /// store, and an apply names it there.
    link: Link,
    /// Whether the executor's workspace for this session takes a state: `Ok` when
    /// Git and an enforcing helper are present and the workspace is in worktree
    /// mode, and the reason in words when it does not. It is read from the
    /// census the attach returned, so it costs no request.
    fit: Result(Nil, String),
    /// Puts a state that is already in the executor's store into the session's
    /// tree and answers the commit the tree has checked out. The session must not
    /// have taken its first turn; the executor cannot tell, so the function that
    /// builds this record refuses once the session has begun.
    apply: fn(State) -> Result(String, Failure),
    /// Captures the session's workspace into a state in the executor's store, thin
    /// against `basis` when it is `Thin`, and answers its description. `None`
    /// means a committed-only capture found nothing beyond the basis.
    capture: fn(Basis, Content) -> Result(Option(State), Failure),
  )
}
