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
  case held.scope {
    domain.SessionOnly -> Ok(Nil)
    domain.WorkspacePrivate -> {
      use found <- result.try(stopped(registry, id))
      case manager.isolate(registry, digest, epoch, id, state_root) {
        Ok(_) -> resumed(registry, id, found)
        Error(_) ->
          case isolated(registry, id) {
            Ok(Nil) -> resumed(registry, id, found)
            Error(Nil) -> Error(restored(registry, id, found))
          }
      }
    }
  }
}

// Whether the session is session-only now. Two presses at once both stop the
// session, and the second isolation is refused because the first one made it:
// that is the change this task was asked for, not a failure to move.
fn isolated(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Nil) {
  case manager.session_domain(registry, id) {
    Ok(held) ->
      case held.scope {
        domain.SessionOnly -> Ok(Nil)
        domain.WorkspacePrivate -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

// The credential must authenticate as the daemon's owner. This is the check that
// guards the stop, which the registry does not authenticate.
fn owner(
  registry: manager.Manager(instance),
  digest: access.Digest,
) -> Result(Nil, Refusal) {
  use principal <- result.try(
    manager.authenticate(registry, digest) |> result.replace_error(NotOwner),
  )
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(NotOwner)
  }
}

// A session the catalogue does not hold is `NotFound`, and any other failure to
// read it is the registry's to sort out.
fn unreadable(error: manager.Error) -> Refusal {
  case error {
    manager.Catalogue(catalogue.Missing) -> NotFound
    manager.Catalogue(_)
    | manager.NotInitialized
    | manager.SessionArchived
    | manager.Capacity
    | manager.Unavailable
    | manager.StaleOperation
    | manager.StartFailed(_)
    | manager.Preparation(_) -> Unavailable
  }
}

// Brings the session to rest and reports what it was doing. A running session
// is stopped and waited for; a saved or already stopping one is only waited
// for, since this task did not start it running. A session still opening or
// blocked cannot be stopped to a rest by a request, so it is refused before
// anything is done to it.
fn stopped(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Found, Refusal) {
  use view <- result.try(
    manager.get(registry, id) |> result.map_error(unreadable),
  )
  case view.status {
    manager.Saved -> Ok(Parked)
    manager.Stopping(_) -> at_rest(registry, id, Parked)
    manager.Resident(_) -> {
      use _ <- result.try(
        manager.stop_session(registry, id) |> result.replace_error(NotStopped),
      )
      at_rest(registry, id, Running)
    }
    manager.Reserved | manager.Opening(_) | manager.RecoveryBlocked(_) ->
      Error(Unavailable)
  }
}

// Reads the registry until it holds nothing for the session. A drain that
// outlasts the wait is not an error of the stop, which still completes, but the
// session cannot be isolated while a process holds it, so the task ends here
// and a second press finds it saved.
//
// The stop is in place before this runs (the registry marks the slot closing in
// the turn that answers `stop_session`), so a session seen opening or resident
// is a new incarnation that another task resumed after its own isolation. The
// rest this task waited for has already come and gone, and waiting on for
// `Saved` would only expire. The task goes on to `manager.isolate`, which the
// registry refuses for a session something holds, and `isolated` then reads
// that refusal as the change another press made.
fn at_rest(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Result(Found, Refusal) {
  let outcome =
    poll.until(within: stop_wait_ms, every: 100, attempt: fn() {
      case manager.get(registry, id) {
        Error(_) -> poll.Fail(NotStopped)
        Ok(view) ->
          case view.status {
            manager.Saved -> poll.Done(found)
            manager.Resident(_) | manager.Opening(_) -> poll.Done(found)
            manager.Stopping(_) -> poll.Retry
            manager.Reserved | manager.RecoveryBlocked(_) ->
              poll.Fail(NotStopped)
          }
      }
    })
  case outcome {
    poll.Answered(found) -> Ok(found)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(NotStopped)
  }
}

// Isolation was refused after the stop. A session that ran is started again so
// the owner is left with what they had; if that fails too, it is stranded
// stopped, which the refusal says.
fn restored(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Refusal {
  case found {
    Parked -> NotMoved
    Running ->
      case reopened(registry, id) {
        Ok(Nil) -> NotMoved
        Error(Nil) -> Stranded
      }
  }
}

// Isolation succeeded. A session that ran is resumed; one that was saved stays
// saved.
fn resumed(
  registry: manager.Manager(instance),
  id: String,
  found: Found,
) -> Result(Nil, Refusal) {
  case found {
    Parked -> Ok(Nil)
    Running -> reopened(registry, id) |> result.replace_error(NotResumed)
  }
}

// The registry's open, the turn `sessions.open` runs, then a wait until the
// session is resident. A status that cannot become resident without another
// request ends the wait at once.
fn reopened(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Nil) {
  use _ <- result.try(manager.open(registry, id) |> result.replace_error(Nil))
  let outcome =
    poll.until(within: resume_wait_ms, every: 50, attempt: fn() {
      case manager.get(registry, id) {
        Error(_) -> poll.Fail(Nil)
        Ok(view) ->
          case view.status {
            manager.Resident(_) -> poll.Done(Nil)
            manager.Opening(_) -> poll.Retry
            manager.Reserved
            | manager.Saved
            | manager.Stopping(_)
            | manager.RecoveryBlocked(_) -> poll.Fail(Nil)
          }
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(Nil) | poll.Expired -> Error(Nil)
  }
}
