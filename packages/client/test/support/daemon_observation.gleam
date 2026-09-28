//// One authenticated connection and one deadline per lifecycle observation.
////
//// An in-flight deadline retires a control owner. A lifecycle wait therefore
//// gives its handshake and status reads the remainder of one shared budget,
//// rather than retrying a retired owner after a shorter request deadline.
//// Each wait authenticates the original endpoint and epoch, then requests
//// closure before checking its outcome. The fixture's mutation connection
//// remains separate; an observation never launches a daemon or resends a
//// mutation whose reply was lost.
////
//// `session_until` is the same one-deadline rule for a wait that polls over
//// the fixture's own control connection instead of a separate one: each
//// read gets what is left of the wait, never a fixed budget of its own.

import gleam/erlang/process
import gleam/int
import gleam/string
import host/bootstrap as native
import tui/daemon
import tui/daemon/bootstrap
import tui/daemon/protocol
import weft/poll

/// Observes session lifecycle state within one fifteen-second deadline.
///
/// The caller decides which states have settled and which still need time.
/// Transport failure ends the observation; it cannot retry a retired owner.
/// The handshake consumes the same budget as the status reads that follow it.
///
/// ## Examples
///
/// ```gleam
/// // daemon_observation.until(connected, session_id, inspect_session)
/// ```
pub fn until(
  connected: bootstrap.Connected,
  id: String,
  inspect_session: fn(protocol.Session) -> poll.Attempt(Nil, String),
) -> Nil {
  let deadline = native.monotonic_time_ms() + 15_000
  let assert Ok(observation) =
    bootstrap.probe(
      connected.paths,
      connected.record,
      process.self(),
      remaining(deadline),
    )
    as "the observation reconnects to the original authenticated daemon epoch"
  let outcome =
    poll.until(within: remaining(deadline), every: 25, attempt: fn() {
      let budget = remaining(deadline)
      case budget {
        0 -> poll.Fail("lifecycle observation deadline expired")
        _ ->
          case
            daemon.request(observation.control, protocol.GetSession(id), budget)
          {
            Ok(protocol.SessionReply(session)) -> inspect_session(session)
            other -> poll.Fail(string.inspect(other))
          }
      }
    })

  // Even a failed observation releases its separate control connection before
  // the assertion unwinds the fixture and native cleanup begins.
  daemon.close(observation.control)
  let assert poll.Answered(Nil) = outcome
    as "the lifecycle observation settles within its shared deadline"
  Nil
}

/// Polls one session's catalogue row over a control the fixture already
/// holds, giving every read the time left in the wait.
///
/// A timed-out read retires the control owner, so a fixed per-read budget
/// inside a longer wait lets one slow reply end the whole wait while most of
/// it is left. That happened in the containerised signoff when a registry
/// catalogue read stalled for 2.6 s under the flat two-second budget these
/// waits used. Here the wait's deadline is taken once and each `GetSession`
/// is sent with what remains; at the deadline no read is sent and the wait
/// expires. A reply that is not a session row asks again, as the loops this
/// replaces did, and a transport failure ends the wait with its description.
///
/// ## Examples
///
/// ```gleam
/// // daemon_observation.session_until(control, id, within: 15_000, every: 25, inspect: daemon_observation.saved)
/// ```
pub fn session_until(
  control: daemon.Connection,
  id: String,
  within within_ms: Int,
  every every_ms: Int,
  inspect inspect_session: fn(protocol.Session) -> poll.Attempt(a, String),
) -> poll.Outcome(a, String) {
  let deadline = native.monotonic_time_ms() + within_ms
  poll.until(within: within_ms, every: every_ms, attempt: fn() {
    case remaining(deadline) {
      0 -> poll.Retry
      budget ->
        case daemon.request(control, protocol.GetSession(id), budget) {
          Ok(protocol.SessionReply(session)) -> inspect_session(session)
          Ok(_) -> poll.Retry
          Error(reason) -> poll.Fail(string.inspect(reason))
        }
    }
  })
}

/// Settles a `session_until` wait once the session's runtime has retired to
/// `Saved`, and keeps waiting on any other status.
///
/// ## Examples
///
/// ```gleam
/// // daemon_observation.session_until(control, id, within: 15_000, every: 25, inspect: daemon_observation.saved)
/// ```
pub fn saved(session: protocol.Session) -> poll.Attempt(Nil, String) {
  case session.status {
    protocol.Saved -> poll.Done(Nil)
    protocol.Reserved
    | protocol.Opening(_)
    | protocol.Resident(_)
    | protocol.Stopping(_)
    | protocol.RecoveryBlocked -> poll.Retry
  }
}

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - native.monotonic_time_ms())
}
