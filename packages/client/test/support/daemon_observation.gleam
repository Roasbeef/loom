//// One authenticated connection and one deadline per lifecycle observation.
////
//// An in-flight deadline retires a control owner. A lifecycle wait therefore
//// gives its handshake and status reads the remainder of one shared budget,
//// rather than retrying a retired owner after a shorter request deadline.
//// Each wait authenticates the original endpoint and epoch, then requests
//// closure before checking its outcome. The fixture's mutation connection
//// remains separate; an observation never launches a daemon or resends a
//// mutation whose reply was lost.

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

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - native.monotonic_time_ms())
}
