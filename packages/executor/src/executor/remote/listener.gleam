//// Fixed-capacity connection workers around the authenticated remote service.
////
//// The listener admits at most four simultaneous exchanges. Each worker owns
//// one bounded `connection.serve_one` call at a time; it cannot accept a second
//// socket while a slow peer holds its credit. The TLS backlog is separately
//// fixed at eight. Native execution and its watchdog belong to the service,
//// so exhausting connection slots cannot prevent a native deadline from firing.
////
//// The embedding host owns the listener and this supervisor as separate
//// resources. It closes the listener before stopping the worker subtree, then
//// drains native custody independently. Stopping network workers is not proof
//// that an executor's descendants have retired. No process here releases a
//// journal fence or invents a terminal result when a connection disappears.

import executor/remote/connection
import executor/remote/service
import executor/remote/tls
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import weft/actor

/// Validated connection capacity and a finite whole-exchange deadline.
pub opaque type Config {
  Config(
    listener: tls.Listener,
    executor: service.Service,
    workers: Int,
    within_ms: Int,
  )
}

/// Configuration refusal occurs before any accepting process exists.
pub type Error {
  /// More than four concurrent frames would exceed the service's admission plan.
  InvalidCapacity

  /// Every accepted socket must have a bounded lifetime, including handshake.
  InvalidDeadline
}

type Message {
  Accept
}

/// Validates the fixed pool before it enters the host's supervision tree.
///
/// ## Examples
///
/// ```gleam
/// // listener.configure(tls_listener, service, workers: 4, within_ms: 5000)
/// ```
pub fn configure(
  listener: tls.Listener,
  executor: service.Service,
  workers workers: Int,
  within_ms within_ms: Int,
) -> Result(Config, Error) {
  case workers >= 1 && workers <= 4, within_ms >= 100 && within_ms <= 30_000 {
    False, _ -> Error(InvalidCapacity)
    True, False -> Error(InvalidDeadline)
    True, True -> Ok(Config(listener:, executor:, workers:, within_ms:))
  }
}

/// Describes the bounded acceptor subtree for the embedding host's supervisor.
///
/// A failed worker can be replaced without changing request identity or native
/// custody. Restart intensity is finite; repeated infrastructure failure stops
/// the subtree instead of creating an unlimited connection retry loop.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.new(supervisor.OneForOne)
/// // |> supervisor.add(listener.supervised(config))
/// // |> supervisor.start
/// ```
pub fn supervised(
  config: Config,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  list.repeat(Nil, times: config.workers)
  |> list.fold(
    supervisor.new(supervisor.OneForOne)
      |> supervisor.restart_tolerance(intensity: 4, period: 10),
    fn(tree, _) {
      let child =
        actor.new(config)
        |> actor.periodic(every: 10, sending: Accept)
        |> actor.on_message(handle)
        |> actor.supervised
        |> supervision.timeout(config.within_ms + 1000)
      supervisor.add(tree, child)
    },
  )
  |> supervisor.supervised
}

fn handle(config: Config, message: Message) -> actor.Next(Config, Message) {
  case message {
    Accept -> {
      // Returning restores exactly this worker's one connection credit. A peer
      // failure leaves retained service evidence unchanged and closes its socket.
      let _ =
        connection.serve_one(config.listener, config.executor, config.within_ms)
      actor.continue(config)
    }
  }
}
