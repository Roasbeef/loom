//// Updating a running daemon is an authenticated lifecycle operation. The
//// original PID and birth identity remain the retirement witness even when
//// control sockets close or another launcher publishes a newer endpoint.

import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import host/endpoint
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as discovery
import tui/daemon/protocol
import weft/poll

/// Captures the current daemon without starting one or selecting a session.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.capture(paths)
/// ```
pub fn capture(
  paths: endpoint.Paths,
) -> Result(Option(discovery.Connected), String) {
  use available <- result.try(endpoint.availability(paths))
  case available {
    endpoint.Vacant -> Ok(None)
    endpoint.Occupied(record) ->
      discovery.probe(paths, record, process.self(), 5000)
      |> result.map(Some)
  }
}

/// Retires the captured daemon and verifies the replacement's build identity.
///
/// A lost shutdown reply is inconclusive: the old daemon may have closed the
/// socket while completing shutdown. Only observing its native retirement
/// permits progress. Expiry leaves the installed trees intact and reports
/// that no replacement was started; the updater never escalates to SIGKILL.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.restart(previous, options, expected_commit)
/// ```
pub fn restart(
  previous: Option(discovery.Connected),
  options: bootstrap.Options,
  expected_commit: String,
) -> Result(Nil, String) {
  use Nil <- result.try(retire(previous))
  use connected <- result.try(bootstrap.reconnect_daemon(
    options,
    process.self(),
    30_000,
  ))
  let identity = daemon.hello(connected.control).build
  daemon.close(connected.control)
  case identity {
    Some(protocol.Build(_, commit)) if commit == expected_commit -> Ok(Nil)
    Some(_) ->
      Error(
        "installed release, but the accepting daemon reports a different commit",
      )
    None ->
      Error(
        "installed release, but the accepting daemon reports no build identity",
      )
  }
}

fn retire(previous: Option(discovery.Connected)) {
  case previous {
    None -> Ok(Nil)
    Some(connected) -> {
      let _reply = daemon.request(connected.control, protocol.Shutdown, 5000)
      daemon.close(connected.control)
      await_retirement(connected.record.fence)
    }
  }
}

fn await_retirement(fence) {
  case
    poll.until(within: 90_000, every: 50, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) ->
      Error("cannot verify old daemon retirement: " <> reason)
    poll.Expired ->
      Error(
        "release installed; old daemon has not retired after 90 seconds; no replacement started",
      )
  }
}
