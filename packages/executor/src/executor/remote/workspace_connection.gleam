//// One authenticated, bounded semantic workspace exchange per connection.
////
//// The LWS domain prefix separates this endpoint from the native command wire.
//// Its hello reuses that wire's version, role, peer-label and complete-scope
//// validation, but generation is echoed only as connection correlation. There
//// is no streaming-control authority to renew: workspace effect identity and
//// scope sealing live in the durable journal. Reconnect cannot recreate a claim.
////
//// A command and complete canonical invocation follow the hello. The invocation
//// carries its original UUID and is checked against the configured scope before
//// service dispatch. A completion is transferred in bounded chunks and checked
//// against that original request before returning to the owner. The owner must
//// durably retain it before sending Acknowledge on a later exchange.
////
//// An outer weft deadline covers DNS, TLS and all frames together. The creating
//// worker owns its socket, so forced worker exit closes a partial exchange.
//// Filesystem effects belong to the separately supervised workspace service;
//// losing the network worker does not cancel or replay them. The embedding host
//// uses listener.configure_workspace for stable service-ingress credits and
//// closes listener admission before sealing/stopping the effect service. The
//// standalone serve_one helper proves socket closure only; a production credit
//// cannot be recycled until its separately owned service ask has replied.

import core/workspace as cw
import executor/remote/connection
import executor/remote/identity
import executor/remote/tls
import executor/remote/wire
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import executor/remote/workspace_transfer as transfer
import gleam/erlang/process
import gleam/result
import tools/workspace
import tools/workspace_codec as codec
import weft

/// Closed commands operate on the exact invocation supplied with the exchange.
pub type Command {
  /// Reserve and claim once, or return existing durable evidence.
  Submit

  /// Observe evidence without creating permission to execute.
  Query

  /// The owner has already retained the exact completion durably.
  Acknowledge(digest: identity.Digest)
}

/// Validated peer configuration and its equivalent semantic scope.
pub opaque type Client {
  Client(connection: connection.Config, scope: cw.Scope)
}

/// One configured service; a peer cannot select a filesystem host or journal.
pub opaque type Server {
  Server(
    owner: String,
    executor: String,
    scope: identity.Scope,
    service: service.Service,
  )
}

/// Transport failure never grants a fresh effect identity.
pub type Error {
  /// Trusted endpoint configuration is inconsistent before any exchange.
  InvalidConfiguration

  /// Input failed local validation before this call sent any bytes.
  InvalidInvocation

  /// The remote outcome is not established, including a service refusal.
  Uncertain
}

/// A closed decoded operation created only by the authenticated reader.
@internal
pub opaque type Request {
  Request(
    command: Command,
    bytes: BitArray,
    reply: process.Subject(Result(journal.Status, service.Error)),
  )
}

type Route {
  Direct
  Relayed(process.Subject(Request))
}

/// Validates the endpoint before any connection or content allocation.
///
/// ## Examples
///
/// `client(config)` refuses an invalid peer label or unbounded exchange budget.
pub fn client(config: connection.Config) -> Result(Client, Error) {
  use _ <- result.try(identity.executor_id(config.owner) |> invalid)
  let fields = identity.scope_fields(config.scope)
  use scope <- result.try(
    cw.scope_from_fields(fields.0, fields.1, fields.2, fields.3, fields.4)
    |> invalid,
  )
  case
    config.executor == fields.2
    && config.hostname != ""
    && config.port > 0
    && config.port <= 65_535
    && config.within_ms > 0
    && config.within_ms <= 30_000
    && config.generation > 0
    && config.generation <= 2_147_483_647
  {
    True -> Ok(Client(config, scope))
    False -> Error(InvalidConfiguration)
  }
}

/// Binds a provisioned owner and complete scope to one already-started service.
///
/// ## Examples
///
/// `server(owner, scope, service)` refuses a service for another workspace epoch.
pub fn server(
  owner: String,
  scope: identity.Scope,
  executor: service.Service,
) -> Result(Server, Error) {
  use _ <- result.try(identity.executor_id(owner) |> invalid)
  let fields = identity.scope_fields(scope)
  use semantic <- result.try(
    cw.scope_from_fields(fields.0, fields.1, fields.2, fields.3, fields.4)
    |> invalid,
  )
  case semantic == service.scope(executor) {
    True -> Ok(Server(owner, fields.2, scope, executor))
    False -> Error(InvalidConfiguration)
  }
}

/// Exchanges exact previously reserved invocation bytes, without a retry loop.
///
/// ## Examples
///
/// `exchange(client, Submit, bytes)` can return Unknown after a durable claim.
pub fn exchange(
  client: Client,
  command: Command,
  bytes: BitArray,
) -> Result(journal.Status, Error) {
  use invocation <- result.try(
    validate(client.scope, bytes) |> result.replace_error(InvalidInvocation),
  )
  bounded(client.connection.within_ms, fn() {
    use socket <- result.try(
      tls.connect(
        client.connection.tls,
        client.connection.hostname,
        client.connection.port,
      )
      |> uncertain,
    )
    let answer =
      owner_exchange(socket, client.connection, command, bytes, invocation)
    tls.close(socket)
    answer
  })
}

/// Compatibility helper with caller-owned admission and bounded socket custody.
/// Return does not prove consumption of a queued service ask. Production uses
/// serve_relayed through the stable listener actor.
///
/// ## Examples
///
/// A bounded acceptor pool calls `serve_one(listener, server, 5000)`.
pub fn serve_one(
  listener: tls.Listener,
  server: Server,
  within_ms: Int,
) -> Result(Nil, Error) {
  bounded(within_ms, fn() {
    use socket <- result.try(tls.accept(listener) |> uncertain)
    let answer = executor_exchange(socket, server, Direct)
    tls.close(socket)
    answer
  })
}

/// Reads one socket inside the listener's bounded run, handing asks to its credit.
/// Worker exit closes transport, while the listener retains the service reply.
///
/// ## Examples
///
/// `serve_relayed(listener, server, requests)` is one listener task.
@internal
pub fn serve_relayed(
  listener: tls.Listener,
  server: Server,
  requests: process.Subject(Request),
) -> Result(Nil, Error) {
  use socket <- result.try(tls.accept(listener) |> uncertain)
  let answer = executor_exchange(socket, server, Relayed(requests))
  tls.close(socket)
  answer
}

/// Exposes the concrete service identity for the credit's lifecycle monitor.
///
/// ## Examples
///
/// `service_pid(server)` identifies only this configured endpoint.
@internal
pub fn service_pid(server: Server) -> process.Pid {
  service.pid(server.service)
}

/// Dispatches only the closed decoded command, with credit-owned reply custody.
///
/// ## Examples
///
/// `dispatch(request, server, reply)` sends one validated service operation.
@internal
pub fn dispatch(
  request: Request,
  server: Server,
  reply: process.Subject(Result(journal.Status, service.Error)),
) -> Nil {
  let operation = case request.command {
    Submit -> service.SubmitOperation
    Query -> service.QueryOperation
    Acknowledge(digest) ->
      service.AcknowledgeOperation(identity.digest_bytes(digest))
  }
  service.send_operation(server.service, operation, request.bytes, reply)
}

/// Forwards the final service result to the original worker's serial wait.
///
/// ## Examples
///
/// `respond(request, response)` never sends a new service ask.
@internal
pub fn respond(
  request: Request,
  response: Result(journal.Status, service.Error),
) -> Nil {
  process.send(request.reply, response)
}

fn bounded(within: Int, work: fn() -> Result(a, Error)) -> Result(a, Error) {
  case within > 0 && within <= 30_000 {
    False -> Error(InvalidConfiguration)
    True ->
      case weft.new([work]) |> weft.deadline(within) |> weft.start {
        [weft.Completed(_, value)] -> Ok(value)
        [weft.Failed(_, error)] -> Error(error)
        _ -> Error(Uncertain)
      }
  }
}

fn owner_exchange(
  socket: tls.Connection,
  config: connection.Config,
  command: Command,
  bytes: BitArray,
  invocation: workspace.Invocation,
) -> Result(journal.Status, Error) {
  let hello =
    wire.Envelope(
      wire.Owner,
      config.owner,
      config.executor,
      config.generation,
      config.scope,
      wire.Hello,
    )
  use Nil <- result.try(write_hello(socket, hello))
  use reply <- result.try(read_hello(
    socket,
    wire.Executor,
    config.owner,
    config.executor,
    config.scope,
  ))
  use Nil <- result.try(case reply.generation == config.generation {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  })
  use Nil <- result.try(tls.send(socket, command_bytes(command)) |> uncertain)
  use Nil <- result.try(
    transfer.send(socket, transfer.Invocation, bytes) |> uncertain,
  )
  read_status(socket, workspace.request(invocation))
}

fn executor_exchange(
  socket: tls.Connection,
  server: Server,
  route: Route,
) -> Result(Nil, Error) {
  use hello <- result.try(read_hello(
    socket,
    wire.Owner,
    server.owner,
    server.executor,
    server.scope,
  ))
  use Nil <- result.try(write_hello(
    socket,
    wire.Envelope(..hello, role: wire.Executor),
  ))
  use frame <- result.try(tls.receive(socket) |> uncertain)
  use command <- result.try(parse_command(frame))
  use bytes <- result.try(
    transfer.receive(socket, transfer.Invocation) |> uncertain,
  )
  use _ <- result.try(validate(service.scope(server.service), bytes))

  // The relayed route retains service custody outside the socket deadline.
  // Direct remains only for the standalone compatibility/test helper.
  let status = case route {
    Direct ->
      case command {
        Submit -> service.submit(server.service, bytes)
        Query -> service.query(server.service, bytes)
        Acknowledge(digest) ->
          service.acknowledge(
            server.service,
            bytes,
            identity.digest_bytes(digest),
          )
      }
    Relayed(requests) -> {
      let reply = process.new_subject()
      process.send(requests, Request(command, bytes, reply))
      process.receive_forever(reply)
    }
  }
  case status {
    Ok(status) -> write_status(socket, status)
    Error(_) -> tls.send(socket, <<"LWR", 1, 5>>) |> uncertain
  }
}

fn validate(
  scope: cw.Scope,
  bytes: BitArray,
) -> Result(workspace.Invocation, Error) {
  use invocation <- result.try(codec.decode_invocation(bytes) |> uncertain)
  case workspace.invocation_identity(invocation).0 == scope {
    True -> Ok(invocation)
    False -> Error(Uncertain)
  }
}

fn write_hello(
  socket: tls.Connection,
  hello: wire.Envelope,
) -> Result(Nil, Error) {
  use bytes <- result.try(wire.encode(hello) |> uncertain)
  tls.send(socket, <<"LWS", 1, bytes:bits>>) |> uncertain
}

fn read_hello(
  socket: tls.Connection,
  role: wire.Role,
  owner: String,
  executor: String,
  scope: identity.Scope,
) -> Result(wire.Envelope, Error) {
  use frame <- result.try(tls.receive(socket) |> uncertain)
  use bytes <- result.try(case frame {
    <<"LWS", 1, bytes:bytes>> -> Ok(bytes)
    _ -> Error(Uncertain)
  })
  use hello <- result.try(
    wire.decode(bytes, role, owner, executor, scope) |> uncertain,
  )
  case hello.body {
    wire.Hello -> Ok(hello)
    _ -> Error(Uncertain)
  }
}

fn command_bytes(command: Command) -> BitArray {
  case command {
    Submit -> <<"LWQ", 1, 0>>
    Query -> <<"LWQ", 1, 1>>
    Acknowledge(digest) -> <<"LWQ", 1, 2, identity.digest_bytes(digest):bits>>
  }
}

fn parse_command(bytes: BitArray) -> Result(Command, Error) {
  case bytes {
    <<"LWQ", 1, 0>> -> Ok(Submit)
    <<"LWQ", 1, 1>> -> Ok(Query)
    <<"LWQ", 1, 2, bytes:bytes-size(32)>> ->
      identity.digest(bytes) |> result.map(Acknowledge) |> uncertain
    _ -> Error(Uncertain)
  }
}

fn write_status(
  socket: tls.Connection,
  status: journal.Status,
) -> Result(Nil, Error) {
  case status {
    journal.Accepted -> tls.send(socket, <<"LWR", 1, 0>>) |> uncertain
    journal.Unknown -> tls.send(socket, <<"LWR", 1, 1>>) |> uncertain
    journal.Finished(bytes) -> {
      use Nil <- result.try(tls.send(socket, <<"LWR", 1, 2>>) |> uncertain)
      transfer.send(socket, transfer.Completion, bytes) |> uncertain
    }
    journal.Acknowledged(digest) ->
      tls.send(socket, <<"LWR", 1, 3, digest:bits>>) |> uncertain
    journal.Cancelled -> tls.send(socket, <<"LWR", 1, 4>>) |> uncertain
  }
}

fn read_status(
  socket: tls.Connection,
  request: workspace.Request,
) -> Result(journal.Status, Error) {
  use frame <- result.try(tls.receive(socket) |> uncertain)
  case frame {
    <<"LWR", 1, 0>> -> Ok(journal.Accepted)
    <<"LWR", 1, 1>> -> Ok(journal.Unknown)
    <<"LWR", 1, 2>> -> {
      use bytes <- result.try(
        transfer.receive(socket, transfer.Completion) |> uncertain,
      )
      use _ <- result.try(codec.decode_completion(request, bytes) |> uncertain)
      Ok(journal.Finished(bytes))
    }
    <<"LWR", 1, 3, digest:bytes-size(32)>> -> Ok(journal.Acknowledged(digest))
    <<"LWR", 1, 4>> -> Ok(journal.Cancelled)
    _ -> Error(Uncertain)
  }
}

fn invalid(value: Result(a, b)) -> Result(a, Error) {
  result.replace_error(value, InvalidConfiguration)
}

fn uncertain(value: Result(a, b)) -> Result(a, Error) {
  result.replace_error(value, Uncertain)
}
