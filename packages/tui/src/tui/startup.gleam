//// Local daemon discovery overlaps the terminal's workspace and model setup.
//// Only the resolver moves into a weft task: subjects, terminal identity and
//// the model stay in the caller. The original terminal owns the authenticated
//// control connection throughout its handshake, including normal terminal exit.
////
//// The resolver owns the single startup deadline. An additional worker-killing
//// deadline could interrupt the handoff after a control owner starts but before
//// its handle returns, leaving no handle to close while the terminal lives.
//// There is therefore no live-terminal cancellation API. A caller must join
//// even when it no longer wants the connection, then close an unused success.
//// Joining consumes both the one outcome and its final accounting message.
//// Unexpected worker or accounting loss is fatal to the original terminal,
//// matching the former inline resolver crash: an unpublished control handle
//// cannot be recovered, but terminal death retires its control guardian.

import gleam/erlang/process.{type Pid, type Selector}
import gleam/int
import host/bootstrap as host
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import weft

const startup_timeout_ms = 90_000

/// One resolver whose reply belongs to the terminal that called `begin`.
pub opaque type Pending {
  Pending(events: Selector(Event), monitor: process.Monitor)
}

type Event {
  Answer(weft.Pulled(daemon_bootstrap.Connected, String))
  RelayDown(process.Down)
}

/// Starts local discovery without moving terminal preparation into a worker.
///
/// ## Examples
///
/// ```gleam
/// let pending = startup.begin(options)
/// // Prepare the terminal model here, in this process.
/// let connected = startup.join(pending)
/// ```
pub fn begin(options: bootstrap.Options) -> Pending {
  begin_with(fn(owner, within) {
    bootstrap.resolve_daemon(options, owner, within)
  })
}

/// Uses the same lifetime and accounting with a supplied resolver. The resolver
/// must honor the supplied remaining budget and terminal ownership contract.
///
/// ## Examples
///
/// ```gleam
/// let pending = startup.begin_with(fn(_, _) { Error("refused") })
/// startup.join(pending) // -> Error("refused")
/// ```
@internal
pub fn begin_with(
  resolve: fn(Pid, Int) -> Result(daemon_bootstrap.Connected, String),
) -> Pending {
  let terminal = process.self()
  let deadline = host.monotonic_time_ms() + startup_timeout_ms
  let replies = process.new_subject()
  let relay =
    weft.new([
      fn() {
        resolve(terminal, int.max(0, deadline - host.monotonic_time_ms()))
      },
    ])
    |> weft.cancel_when_exits(terminal)
    |> weft.start_relayed(replies)
  let monitor = process.monitor(relay)
  let events =
    process.new_selector()
    |> process.select_map(replies, Answer)
    |> process.select_specific_monitor(monitor, RelayDown)
  Pending(events, monitor)
}

/// Joins the resolver and its final account before handing control to the UI.
/// A missing or invalid account closes any success already received. Relay
/// monitoring makes an unexpected relay exit fatal rather than a lost wait;
/// terminal death also closes a control handle the worker never published.
///
/// ## Examples
///
/// ```gleam
/// startup.begin_with(fn(_, _) { Error("refused") })
/// |> startup.join // -> Error("refused")
/// ```
pub fn join(pending: Pending) -> Result(daemon_bootstrap.Connected, String) {
  let result = case process.selector_receive_forever(pending.events) {
    Answer(weft.PulledOutcome(outcome)) -> finish(pending.events, outcome)
    Answer(weft.AllDelivered) -> fatal()
    Answer(weft.RunLost(_)) -> fatal()
    Answer(weft.NotYet) -> fatal()
    RelayDown(_) -> fatal()
  }
  process.demonitor_process(pending.monitor)
  result
}

fn finish(
  events: Selector(Event),
  outcome: weft.Outcome(daemon_bootstrap.Connected, String),
) -> Result(daemon_bootstrap.Connected, String) {
  case process.selector_receive_forever(events) {
    Answer(weft.AllDelivered) -> outcome_result(outcome)
    Answer(weft.PulledOutcome(extra)) -> {
      close_unused(outcome)

      // A one-task run cannot deliver a second outcome. Still close a second
      // connection if that invariant ever fails instead of silently losing it.
      close_unused(extra)
      fatal()
    }
    Answer(weft.RunLost(_)) -> {
      close_unused(outcome)
      fatal()
    }
    Answer(weft.NotYet) -> {
      close_unused(outcome)
      fatal()
    }
    RelayDown(_) -> {
      close_unused(outcome)
      fatal()
    }
  }
}

fn outcome_result(
  outcome: weft.Outcome(daemon_bootstrap.Connected, String),
) -> Result(daemon_bootstrap.Connected, String) {
  case outcome {
    weft.Completed(value: connected, ..) -> Ok(connected)
    weft.Failed(error: reason, ..) -> Error(reason)
    weft.Crashed(..) | weft.DrainProofLost(..) -> fatal()
    weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.CancellationUnconfirmed(..) -> fatal()
  }
}

// The terminal has not entered raw/alternate-screen mode yet. Its death is
// the existing guardian's proof to close even an unpublished control socket.
fn fatal() -> Result(daemon_bootstrap.Connected, String) {
  process.kill(process.self())
  Error("daemon startup lost ownership accounting")
}

fn close_unused(
  outcome: weft.Outcome(daemon_bootstrap.Connected, String),
) -> Nil {
  case outcome {
    weft.Completed(value: connected, ..) -> daemon.close(connected.control)
    weft.Failed(..)
    | weft.Crashed(..)
    | weft.DrainProofLost(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.CancellationUnconfirmed(..) -> Nil
  }
}
