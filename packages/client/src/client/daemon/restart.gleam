//// Stopping a resident session and opening it again, for a change that only an
//// open can apply (protocol-change/082).
////
//// A session builds its provider gateway, subagent route, summarizer and
//// advisor once, when it opens, from the configuration and the profile its
//// registration names. Changing the profile therefore takes effect at the next
//// open, and this module is how the daemon makes that open happen now: it
//// stops the session, waits for the registry to hold nothing for it, and opens
//// it again. It is the stop and resume of `shareable`, without the isolation
//// between them.
////
//// A stop is not an abort. The runtime retires at a durable commit boundary and
//// writes no terminal state for an operation in progress, so the open that
//// follows resumes it (`docs/architecture/sessions.md`). The hub refuses a
//// profile switch while a strand runs, so in practice the session is idle.
////
//// ## Flow
////
//// `begin` → `restart` → `stopped` → `reopened`
////
//// 1. `begin` starts the work in a process nobody owns and returns at once,
////    because the process that asks is the session's own hub, which the stop
////    ends. A run linked to the hub would end between the stop and the open.
//// 2. `restart` is the whole task, blocking and bounded.
//// 3. `stopped` asks the registry to stop the session and waits until it is
////    saved.
//// 4. `reopened` asks the registry to open it and waits until it is resident.
////
//// ## What a failure leaves
////
//// The two steps do not share a transaction. A failed stop leaves the session
//// running, still on the roles it opened with, with the new profile saved for
//// its next open. A failed open leaves it stopped and saved, and an ordinary
//// open from any client builds it under the new profile.

import client/daemon/manager
import gleam/erlang/process
import gleam/result
import weft/poll

/// How long the task waits for the stopping session to leave the registry, in
/// milliseconds. An idle session stops in well under a second; the wait is long
/// for a session that is draining a tool.
pub const stop_wait_ms = 15_000

/// How long the task waits for the reopened session to become resident, in
/// milliseconds. It matches the page's resume wait (`ui_socket.resume_wait_ms`).
pub const resume_wait_ms = 30_000

/// Where a restart stopped, for the daemon to log. Neither variant carries text
/// from the registry.
pub type Failure {
  /// The session did not finish stopping, so it was not reopened.
  NotStopped

  /// The session stopped and did not become resident again.
  NotReopened
}

/// Starts `restart` in a process that no session owns and returns at once;
/// `report` is called from that process with the failure, if there is one.
///
/// The process is a plain `spawn_unlinked` for the reason `ui_socket.detached`
/// gives: every weft start links its scope to the caller, and a run the caller
/// does not outlive is cancelled, while this one must outlive the session whose
/// stop it begins. It ends when `restart` returns, which the registry's call
/// timeouts and the two waits bound at about a minute.
///
/// ## Examples
///
/// ```gleam
/// // restart.begin(registry, session_id, fn(failure) { log_it(failure) })
/// ```
pub fn begin(
  registry: manager.Manager(instance),
  id: String,
  report: fn(Failure) -> Nil,
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      case restart(registry, id) {
        Ok(Nil) -> Nil
        Error(failure) -> report(failure)
      }
    })
  Nil
}

/// Stops the session and opens it again, blocking until it is resident or one
/// step fails.
///
/// ## Examples
///
/// ```gleam
/// // restart.restart(registry, session_id)
/// ```
pub fn restart(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Failure) {
  use Nil <- result.try(
    stopped(registry, id) |> result.replace_error(NotStopped),
  )
  reopened(registry, id, within: resume_wait_ms)
  |> result.replace_error(NotReopened)
}

// Asks the registry to stop the session, then reads it until the stop is over.
// `stop_session` marks the slot closing in the turn that answers it, and a
// closing slot never reopens, so a session seen resident or opening here is a
// new incarnation that a client's own open started after the drain
// (`ui_socket.drained` reads it the same way). The stop that was asked for has
// completed, and waiting on for `Saved` would only run out the clock. A status
// that cannot end without another request ends the wait at once.
fn stopped(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Nil) {
  use _ <- result.try(
    manager.stop_session(registry, id) |> result.replace_error(Nil),
  )
  let outcome =
    poll.until(within: stop_wait_ms, every: 100, attempt: fn() {
      case manager.get(registry, id) {
        Error(_) -> poll.Fail(Nil)
        Ok(view) ->
          case view.status {
            manager.Saved | manager.Resident(_) | manager.Opening(_) ->
              poll.Done(Nil)
            manager.Stopping(_) -> poll.Retry
            manager.Reserved | manager.RecoveryBlocked(_) -> poll.Fail(Nil)
          }
      }
    })
  settled(outcome)
}

/// The registry's open, the turn `sessions.open` runs, then a wait of at most
/// `within` milliseconds until the session is resident. A status that cannot
/// become resident without another request ends the wait at once. A concurrent
/// open by a client that noticed the stop joins the same operation, so both
/// callers end on the one incarnation.
///
/// ## Examples
///
/// ```gleam
/// // restart.reopened(registry, session_id, within: 30_000)
/// ```
pub fn reopened(
  registry: manager.Manager(instance),
  id: String,
  within wait_ms: Int,
) -> Result(Nil, Nil) {
  use _ <- result.try(manager.open(registry, id) |> result.replace_error(Nil))
  let outcome =
    poll.until(within: wait_ms, every: 50, attempt: fn() {
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
  settled(outcome)
}

fn settled(outcome: poll.Outcome(Nil, Nil)) -> Result(Nil, Nil) {
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(Nil) | poll.Expired -> Error(Nil)
  }
}
