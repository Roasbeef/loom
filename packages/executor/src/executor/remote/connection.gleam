//// One-credit request/reply transport over the exact pinned TLS primitive.
////
//// Each exchange opens an authenticated socket, negotiates closed versions and
//// roles, sends one command, receives one bounded response, and closes. There
//// is no cast writer queue, so one caller holds at most one frame credit. Root
//// bounds simultaneous callers/connections at assembly (initial maximum four).
//// A weft deadline owns connect, DNS, TLS and all socket I/O together; caller
//// death/cancel kills and joins the worker. The socket remains worker-owned and
//// OTP closes it on owner death, including a resolver/handshake overrun. Native
//// service and watchdog never run inside this reader/writer worker. An exchange
//// failure after possible send is uncertain, irrespective of TLS error detail.
////
//// Executor serve_one accepts exactly one socket and one command. Its bounded
//// managed lifetime closes idle/nonreading peers; no further frame is read until
//// the service's bounded admission ask completes. Root supplies a bounded pool
//// of at most four such workers and owns listener shutdown. This API does not
//// silently create unlimited connection workers or an insecure fallback.

import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import gleam/result
import weft

/// Owner-side immutable peer configuration, separate from logical request IDs.
pub type Config {
  /// Establishment, framing and application exchange share a hard worker budget.
  Config(
    /// The immutable tls value retained by this boundary.
    tls: tls.Settings,
    /// The configured endpoint name checked by TLS certificate validation.
    hostname: String,
    /// The configured peer port; it never chooses a workspace binding.
    port: Int,
    /// One supervised budget for DNS, connect, handshake and complete exchange.
    within_ms: Int,
    /// The provisioned owner label bound to the pinned peer certificate.
    owner: String,
    /// The provisioned executor label from the administrative scope.
    executor: String,
    /// The current monotone transport generation, separate from request identity.
    generation: Int,
    /// The exact session/workspace binding and original authority epochs.
    scope: identity.Scope,
  )
}

import executor/remote/identity

/// Transport uncertainty keeps logical request/evidence custody with its owner.
pub type Error {
  /// A connect/read/write/version/schema/peer or task deadline failed.
  Uncertain
}

/// Exchanges one closed owner command with bounded caller-owned socket custody.
///
/// ## Examples
///
/// ```gleam
/// connection.exchange(config, wire.Query(key, digest, 0))
/// ```
pub fn exchange(config: Config, body: wire.Body) -> Result(wire.Body, Error) {
  bounded(config.within_ms, fn() { client_exchange(config, body) })
}

/// Accepts and serves one connection; root bounds concurrent calls/listeners.
/// Returns only after socket closure or its worker has been killed and joined.
///
/// ## Examples
///
/// ```gleam
/// connection.serve_one(listener, service, 5000)
/// ```
pub fn serve_one(
  listener: tls.Listener,
  executor: service.Service,
  within_ms: Int,
) -> Result(Nil, Error) {
  bounded(within_ms, fn() {
    use socket <- result.try(tls.accept(listener) |> transport)
    let outcome = server_exchange(socket, executor)
    tls.close(socket)
    outcome
  })
}

fn bounded(within: Int, work: fn() -> Result(a, Error)) -> Result(a, Error) {
  use Nil <- result.try(case within > 0 && within <= 30_000 {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  })
  case weft.new([work]) |> weft.deadline(within) |> weft.start {
    [weft.Completed(_, value)] -> Ok(value)
    [weft.Failed(_, error)] -> Error(error)
    _ -> Error(Uncertain)
  }
}

fn client_exchange(
  config: Config,
  body: wire.Body,
) -> Result(wire.Body, Error) {
  use socket <- result.try(
    tls.connect(config.tls, config.hostname, config.port) |> transport,
  )
  let outcome = owner_exchange(socket, config, body)
  tls.close(socket)
  outcome
}

fn owner_exchange(
  socket: tls.Connection,
  config: Config,
  body: wire.Body,
) -> Result(wire.Body, Error) {
  let hello =
    wire.Envelope(
      wire.Owner,
      config.owner,
      config.executor,
      config.generation,
      config.scope,
      wire.Hello,
    )
  use bytes <- result.try(wire.encode(hello) |> transport)
  use Nil <- result.try(tls.send(socket, bytes) |> transport)
  use reply <- result.try(read(
    socket,
    wire.Executor,
    config.owner,
    config.executor,
    config.scope,
  ))
  use Nil <- result.try(
    case reply.body == wire.Hello && reply.generation == config.generation {
      True -> Ok(Nil)
      False -> Error(Uncertain)
    },
  )
  use bytes <- result.try(
    wire.encode(wire.Envelope(..hello, body:)) |> transport,
  )
  use Nil <- result.try(tls.send(socket, bytes) |> transport)
  use reply <- result.try(read(
    socket,
    wire.Executor,
    config.owner,
    config.executor,
    config.scope,
  ))
  case reply.generation == config.generation {
    True -> Ok(reply.body)
    False -> Error(Uncertain)
  }
}

fn server_exchange(
  socket: tls.Connection,
  executor: service.Service,
) -> Result(Nil, Error) {
  let config = service.configuration(executor)
  use hello <- result.try(read(
    socket,
    wire.Owner,
    config.owner,
    config.executor,
    config.scope,
  ))
  use Nil <- result.try(case hello.body == wire.Hello {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  })
  use body <- result.try(service.exchange(executor, hello) |> transport)
  use Nil <- result.try(write(socket, hello, body))
  use command <- result.try(read(
    socket,
    wire.Owner,
    config.owner,
    config.executor,
    config.scope,
  ))
  use Nil <- result.try(case command.generation == hello.generation {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  })
  let response = case service.exchange(executor, command) {
    Ok(body) -> body
    Error(service.Invalid) -> wire.Rejected(1)
    Error(service.Capacity) -> wire.Rejected(2)
    Error(service.Expired) -> wire.Rejected(3)
    Error(service.Uncertain) -> wire.Rejected(4)
  }
  write(socket, command, response)
}

fn write(
  socket: tls.Connection,
  request: wire.Envelope,
  body: wire.Body,
) -> Result(Nil, Error) {
  use bytes <- result.try(
    wire.encode(wire.Envelope(..request, role: wire.Executor, body:))
    |> transport,
  )
  tls.send(socket, bytes) |> transport
}

fn read(
  socket: tls.Connection,
  role: wire.Role,
  owner: String,
  executor: String,
  scope: identity.Scope,
) -> Result(wire.Envelope, Error) {
  use bytes <- result.try(tls.receive(socket) |> transport)
  wire.decode(bytes, role, owner, executor, scope) |> transport
}

fn transport(value: Result(a, e)) -> Result(a, Error) {
  result.map_error(value, fn(_) { Uncertain })
}
