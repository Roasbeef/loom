//// Making a private session shareable, as one task the owner's page asks for
//// (protocol-change/065, the addendum on making a session shareable).
////
//// A session created `workspace_private` shares its notes and history with its
//// workspace, so the registry refuses to give another person a seat in it
//// (`IsolationRequired`). The terminal's way out is three commands: stop the
//// session, `loomd access isolate`, and resume it. The page cannot ask the owner
//// to run them, so this module runs the same three registry operations in the
//// same order, and `manager.isolate` is the daemon's own isolation, not a copy
//// of it. Nothing here writes the catalogue itself.
////
//// ## Flow
////
//// `make` is the whole task. It checks the owner (`owner`), reads the session's
//// scope, stops the session if it runs (`stopped`), isolates it
//// (`manager.isolate`), and resumes it when it ran (`resumed`). A session that
//// is already session-only has nothing to do and answers at once, which makes a
//// repeat of the task a no-op.
////
//// ## What a failure leaves
////
//// The three steps do not share a transaction, so each refusal says which state
//// the session is left in, and every state is one the owner can leave by
//// pressing again or by resuming from the home page. None is a half-isolated
//// session, because isolation itself is one catalogue transaction
//// (`storage/domain.isolate`): the session is private or it is session-only.
////
//// | refusal | where it stopped | the session is left |
//// | --- | --- | --- |
//// | `NotOwner`, `NotFound`, `Unavailable` | before anything changed | exactly as it was |
//// | `NotStopped` | the stop did not finish in `stop_wait_ms` | the stop was issued and still completes; private, and once saved a second press moves it and leaves it saved |
//// | `NotMoved` | isolation was refused, for example a session another page resumed in the meantime | private, and running again when it ran before |
//// | `Stranded` | isolation was refused and the session could not be resumed either | stopped and private; resume it from the home page |
//// | `NotResumed` | isolation succeeded and the resume did not | stopped and shareable; resume it from the home page |
////
//// A session that was saved when the task began is isolated and stays saved:
//// the task restores the state it found, so a saved session is never started
//// on the owner's behalf by a button that said nothing about running it.
////
//// The task never decides who may ask. The page layer checks that the page is
//// open and minted to operate, and this module authenticates the credential as
//// the daemon's owner before it stops anything, because `manager.stop_session`
//// takes no caller and a stop is the first change. `manager.isolate`
//// authenticates the credential and the epoch a second time in the registry's
//// own turn, so it is the last word on who may.

import client/daemon/manager
import client/daemon/restart
import gleam/result
import storage/access
import storage/catalogue
import storage/domain
import weft/poll

/// How long the task waits for a running session to finish stopping, in
/// milliseconds. A session in the middle of a turn cancels it, which takes
/// longer than an idle stop; a drain that outlasts this wait is `NotStopped`,
/// and the stop it began still completes.
pub const stop_wait_ms = 15_000

/// How long the task waits for the resumed session to become resident, in
/// milliseconds. It is the page's own resume wait (`ui_socket.resume_wait_ms`).
pub const resume_wait_ms = 30_000

/// Why the task made nothing shareable, or left the session short of resumed.
/// Each variant says in what state the session is left (the module's table), and
/// none carries text from the daemon, so a page words it from a fixed table.
pub type Refusal {
  /// The credential is not the daemon's owner. Nothing changed.
  NotOwner

  /// The catalogue holds no such session. Nothing changed.
  NotFound

  /// The registry did not answer, or the session is opening, reserved or
  /// blocked, which a stop cannot end. Nothing changed.
  Unavailable

  /// The session did not finish stopping in time.
  NotStopped

  /// Isolation was refused and the session is private again, running when it
  /// ran before.
  NotMoved

  /// Isolation was refused and the session could not be resumed. It is stopped
  /// and private.
  Stranded

  /// Isolation succeeded and the session did not resume. It is stopped and
  /// shareable.
  NotResumed
}

// What the session was doing when the task found it, which is what the task
// puts back.
type Found {
  Running
  Parked
}

/// Stops, isolates and resumes `id` for the owner whose credential is `digest`,
/// or says why it did not and, by the module's table, where the session stands.
///
/// `state_root` is the daemon's own, which the isolated domain's fresh stores
/// are minted under (`manager.isolate`). A caller never supplies it from a page.
/// The call blocks for the stop and the resume, each bounded, so a page runs it
/// in a task of its own (`ui_socket.shareable_task`).
///
/// ## Examples
///
/// ```gleam
/// // shareable.make(registry, owner_digest, epoch, state_root, session_id)
/// ```
pub fn make(
  registry: manager.Manager(instance),
  digest: access.Digest,
  epoch: String,
  state_root: String,
  id: String,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(owner(registry, digest))
  use held <- result.try(
    manager.session_domain(registry, id) |> result.map_error(unreadable),
  )

  // Branch on existing domain scope to determine whether isolation is needed.
  case held.scope {
    domain.SessionOnly -> Ok(Nil)
    domain.WorkspacePrivate -> {
      use found <- result.try(stopped(registry, id))

      // Attempt domain isolation in the registry or check if concurrently completed.
      case manager.isolate(registry, digest, epoch, id, state_root) {
        Ok(_) -> resumed(registry, id, found)
        Error(_) ->
          // This branch resolves isolated registry id before the operation continues.
          case isolated(registry, id) {
            Ok(Nil) -> resumed(registry, id, found)
            Error(Nil) -> Error(restored(registry, id, found))
          }
      }
    }
  }
}

/// Checks whether the target session has already reached SessionOnly scope.
fn isolated(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Nil) {
  // This branch resolves manager session_domain registry id before the operation continues.
  case manager.session_domain(registry, id) {
    Ok(held) ->
      // This branch resolves held scope before the operation continues.
      case held.scope {
        domain.SessionOnly -> Ok(Nil)
        domain.WorkspacePrivate -> Error(Nil)
      }

    Error(_) -> Error(Nil)
  }
}

/// Asserts that the authenticated principal possesses daemon owner credentials.
fn owner(
  registry: manager.Manager(instance),
  digest: access.Digest,
) -> Result(Nil, Refusal) {
  use principal <- result.try(
    manager.authenticate(registry, digest) |> result.replace_error(NotOwner),
  )

  // Verify that authenticated principal kind is OwnerPrincipal.
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(NotOwner)
  }
}

/// Maps registry access errors to structured shareable operation refusals.
fn unreadable(error: manager.Error) -> Refusal {
  // This branch resolves error before the operation continues.
  case error {
    manager.Catalogue(catalogue.Missing) -> NotFound
    manager.Catalogue(_)
    | manager.NotInitialized
    | manager.SessionArchived
    | manager.Capacity
    | manager.Unavailable
    | manager.StaleOperation
    | manager.StartFailed(_)
    | manager.Preparation(_)
    | manager.SessionMoving(..)
    | manager.SessionMoved(..)
    | manager.SessionDeleting -> Unavailable
  }
}

/// Stops a running session or waits for a stopping session to reach rest state.
fn stopped(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Found, Refusal) {
  use view <- result.try(
    manager.get(registry, id) |> result.map_error(unreadable),
  )

  // Dispatch on session lifecycle status to ensure safe stoppage before migration.
  case view.status {
    manager.Saved -> Ok(Parked)
    manager.Stopping(_) -> at_rest(registry, id, Parked)
    manager.Resident(_) ->
      // A task that raced this one may have isolated and resumed the session
      // since the scope was read. It is already shareable and running, so there
      // is nothing to stop, and stopping it would only undo the other task.
      case isolated(registry, id) {
        Ok(Nil) -> Ok(Running)
        Error(Nil) -> {
          use _ <- result.try(
            manager.stop_session(registry, id)
            |> result.replace_error(NotStopped),
          )
          at_rest(registry, id, Running)
        }
      }

    manager.Reserved
    | manager.FailedStart(..)
    | manager.Opening(_)
    | manager.RecoveryBlocked(_) -> Error(Unavailable)
  }
}

/// Polls until the session reaches Saved status or concurrent isolation is confirmed.
fn at_rest(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Result(Found, Refusal) {
  let outcome =
    poll.until(within: stop_wait_ms, every: 100, attempt: fn() {
      // This branch resolves manager get registry id isolated registry id before the operation continues.
      case manager.get(registry, id), isolated(registry, id) {
        Error(_), _ -> poll.Fail(NotStopped)
        Ok(_), Ok(Nil) -> poll.Done(found)
        Ok(view), Error(Nil) ->
          // This branch resolves view status before the operation continues.
          case view.status {
            manager.Saved -> poll.Done(found)
            manager.Stopping(_) | manager.Resident(_) | manager.Opening(_) ->
              poll.Retry
            manager.Reserved
            | manager.FailedStart(..)
            | manager.RecoveryBlocked(_) -> poll.Fail(NotStopped)
          }
      }
    })

  // Branch on poll outcome to report successful rest state or failure refusal.
  case outcome {
    poll.Answered(found) -> Ok(found)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(NotStopped)
  }
}

/// Restores previous session execution state when isolation fails after stopping.
fn restored(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Refusal {
  // This branch resolves found before the operation continues.
  case found {
    Parked -> NotMoved
    Running ->
      // This branch resolves reopened registry id before the operation continues.
      case reopened(registry, id) {
        Ok(Nil) -> NotMoved
        Error(Nil) -> Stranded
      }
  }
}

/// Resumes running session state after successful isolation or leaves parked sessions saved.
fn resumed(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Result(Nil, Refusal) {
  // This branch resolves found before the operation continues.
  case found {
    Parked -> Ok(Nil)
    Running -> reopened(registry, id) |> result.replace_error(NotResumed)
  }
}

// The registry's open and the wait until the session is resident, which
// `restart` shares: a profile switch reopens a session the same way.
fn reopened(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Nil) {
  restart.reopened(registry, id, within: resume_wait_ms)
}
