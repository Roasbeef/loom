//// Disposable read connections for shipped-daemon lifecycle observations.
////
//// An in-flight deadline retires a control owner. Each observation therefore
//// authenticates a fresh connection to the original endpoint and requests its closure
//// before returning. A retry cannot reuse a retired inbox or consume the
//// fixture's separate mutation connection. Probing never launches a daemon,
//// and the original epoch must still match before any read is sent.

import gleam/erlang/process
import tui/daemon
import tui/daemon/bootstrap
import tui/daemon/protocol

/// Reads one session through a disposable, authenticated control connection.
///
/// Only this read may be retried by an observation loop. A lost mutation reply
/// still belongs to the fixture's command connection and remains ambiguous.
///
/// ## Examples
///
/// ```gleam
/// // daemon_observation.session(connected, session_id, 2000)
/// ```
pub fn session(
  connected: bootstrap.Connected,
  id: String,
  within_ms: Int,
) -> Result(protocol.Reply, daemon.Failure) {
  let assert Ok(observation) =
    bootstrap.probe(
      connected.paths,
      connected.record,
      process.self(),
      within_ms,
    )
    as "the observation reconnects to the original authenticated daemon epoch"
  let answer =
    daemon.request(observation.control, protocol.GetSession(id), within_ms)
  daemon.close(observation.control)
  answer
}
