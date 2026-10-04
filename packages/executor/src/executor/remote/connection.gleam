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
//// The production listener calls serve_relayed inside its own bounded run.
//// The decoded Hello and operation are handed to that stable credit, which
//// sends to the service and owns the actual reply beyond socket-worker death.
//// Serial waits permit only one unresolved handoff. The compatibility serve_one
//// helper shares this parser through a direct route; its return proves only
//// socket closure and must never recycle a production service-ingress credit.
////
//// exchange_command uses the same owner_exchange engine with a closed outbound
//// route. encode_route changes only post-Hello framing; read_route requires the
//// exact ref before exposing the native reply. Server read remains native-only;
//// enabling service commands requires authenticated association before launch.

import core/command
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import gleam/erlang/process
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

/// A decoded request can only be created by this module's protocol reader.
/// Its worker reply endpoint carries no arbitrary service callback.
@internal
pub opaque type Request {
  Request(
    envelope: wire.Envelope,
    reply: process.Subject(Result(wire.Body, service.Error)),
  )
}

type OutboundRoute {
  NativeRoute
  CommandRoute(command.CommandRef)
}

type Route {
  Direct(service.Service)
  Relayed(process.Subject(Request))
}

/// Exchanges one closed owner command with bounded caller-owned socket custody.
///
/// ## Examples
///
/// ```gleam
/// connection.exchange(config, wire.Query(key, digest, 0))
/// ```
pub fn exchange(config: Config, body: wire.Body) -> Result(wire.Body, Error) {
  bounded(config.within_ms, fn() { client_exchange(config, NativeRoute, body) })
}

/// Exchanges one physical command under its original complete retained route.
/// Hello stays on the native lane. A plain reply, changed ref or generation is
/// uncertain; no retry changes authority. The current native server intentionally
/// refuses this wrapper until authenticated command admission is assembled.
///
/// ## Examples
///
/// ```gleam
/// let expired = connection.Config(..config, within_ms: 0)
/// assert connection.exchange_command(expired, ref, wire.Query(key, digest, 0))
///   == Error(connection.Uncertain)
/// ```
pub fn exchange_command(
  config: Config,
  ref: command.CommandRef,
  body: wire.Body,
) -> Result(wire.Body, Error) {
  bounded(config.within_ms, fn() {
    client_exchange(config, CommandRoute(ref), body)
  })
}

/// Compatibility helper for standalone exchanges with caller-owned admission.
/// Return proves socket closure, not consumption of a queued service ask. The
/// production listener uses serve_relayed and retains that independent custody.
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
    let outcome = server_exchange(socket, executor, Direct(executor))
    tls.close(socket)
    outcome
  })
}

/// Runs socket I/O inside the listener's already bounded relayed run.
/// Decoded asks go to the stable listener credit; this worker never sends to
/// the service. Its death closes the socket without releasing service custody.
///
/// ## Examples
///
/// `serve_relayed(listener, executor, requests)` is one listener task.
@internal
pub fn serve_relayed(
  listener: tls.Listener,
  executor: service.Service,
  requests: process.Subject(Request),
) -> Result(Nil, Error) {
  use socket <- result.try(tls.accept(listener) |> transport)
  let outcome = server_exchange(socket, executor, Relayed(requests))
  tls.close(socket)
  outcome
}

/// Sends the closed decoded envelope with a reply endpoint owned by the credit.
///
/// ## Examples
///
/// `dispatch(request, executor, reply)` transfers one service ask.
@internal
pub fn dispatch(
  request: Request,
  executor: service.Service,
  reply: process.Subject(Result(wire.Body, service.Error)),
) -> Nil {
  service.send_exchange(executor, request.envelope, reply)
}

/// Forwards an actual service answer; a dead socket worker receives no work.
///
/// ## Examples
///
/// `respond(request, response)` completes the worker's serial ask.
@internal
pub fn respond(
  request: Request,
  response: Result(wire.Body, service.Error),
) -> Nil {
  process.send(request.reply, response)
}

fn ask(
  route: Route,
  envelope: wire.Envelope,
) -> Result(wire.Body, service.Error) {
  case route {
    Direct(executor) -> service.exchange(executor, envelope)
    Relayed(requests) -> {
      let reply = process.new_subject()
      process.send(requests, Request(envelope, reply))
      process.receive_forever(reply)
    }
  }
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
  route: OutboundRoute,
  body: wire.Body,
) -> Result(wire.Body, Error) {
  use socket <- result.try(
    tls.connect(config.tls, config.hostname, config.port) |> transport,
  )
  let outcome = owner_exchange(socket, config, route, body)
  tls.close(socket)
  outcome
}

fn owner_exchange(
  socket: tls.Connection,
  config: Config,
  route: OutboundRoute,
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
    encode_route(route, wire.Envelope(..hello, body:)) |> transport,
  )
  use Nil <- result.try(tls.send(socket, bytes) |> transport)
  use reply <- result.try(read_route(socket, config, route))
  case reply.generation == config.generation {
    True -> Ok(reply.body)
    False -> Error(Uncertain)
  }
}

// The owner engine changes only the closed frame codec after ordinary Hello.
fn encode_route(
  route: OutboundRoute,
  envelope: wire.Envelope,
) -> Result(BitArray, wire.Error) {
  case route {
    NativeRoute -> wire.encode(envelope)
    CommandRoute(ref) -> {
      use command <- result.try(wire.command_envelope(ref, envelope))
      wire.encode_command(command)
    }
  }
}

fn read_route(
  socket: tls.Connection,
  config: Config,
  route: OutboundRoute,
) -> Result(wire.Envelope, Error) {
  case route {
    NativeRoute ->
      read(socket, wire.Executor, config.owner, config.executor, config.scope)
    CommandRoute(ref) -> {
      use bytes <- result.try(tls.receive(socket) |> transport)
      use command <- result.try(
        wire.decode_command(
          bytes,
          wire.Executor,
          config.owner,
          config.executor,
          config.scope,
        )
        |> transport,
      )
      case wire.command_ref(command) == ref {
        True -> Ok(wire.native_envelope(command))
        False -> Error(Uncertain)
      }
    }
  }
}

fn server_exchange(
  socket: tls.Connection,
  executor: service.Service,
  route: Route,
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
  use body <- result.try(ask(route, hello) |> transport)
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
  let response = case ask(route, command) {
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
