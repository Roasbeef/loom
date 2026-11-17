//// The executor's end of the untrusted link (protocol-change/109).
////
//// An untrusted executor's daemon is never an Erlang peer. It runs the same
//// host, ledger and workspace plane as a trusted one, registered on its own
//// node, and this gateway is how an orchestrator reaches them: a TLS listener
//// that admits only the orchestrators whose certificates hash to a configured
//// pin, and, per connection, a process that turns frames into the host's
//// `HostMessage`s and the plane's `OwnerMessage`s into frames. The host cannot
//// tell that its peer is not a distribution node.
////
//// ## Three kinds of process
////
//// - **A connection** per accepted socket runs the handshake, waits for
////   `hello`, and then serves frames. Each request gets a **waiter**, a
////   process of its own that owns the reply subject the host sees, so the
////   host's monitor reads the waiter's death the way it reads a trusted
////   orchestrator's effect process dying. `cancel` kills the waiter, and the
////   host cancels the call. A dropped connection kills no waiter: each waits
////   for its answer and exits, so a partition never cancels a call.
////   A `clear_call` (protocol-change/117) gets a **tunnel waiter** instead,
////   which is the reverse: linked to its connection, it clears the call on the
////   plane's broker with `broker.over`, closes the child's stdin, and sends
////   `cleared` and then every non-empty chunk and the settlement as frames.
////   A tunnelled call is never re-sent, so its child must not outlive the
////   connection: a crash takes the waiters with it, every normal stop unlinks
////   and kills them first (`stopped`), and a `cancel` unlinks one before
////   killing it so the connection survives.
//// - **A proxy** per binding stands in for the session's owner port. Its
////   subject is the `owner_port` the host is given at attach, so the plane is
////   built exactly as for a trusted orchestrator. It sends each owner request
////   as a `callback` on its orchestrator's current connection and answers the
////   plane from the `answer`, or at once with the in-band failure when there
////   is no connection, and it fails everything outstanding when the
////   connection drops.
//// - **The book** knows, per orchestrator pin, the current connection and the
////   proxies, so a reconnection re-points every proxy of that orchestrator,
////   and an answer reaches the proxy of the binding it names. One
////   orchestrator cannot name another's binding, because the book keys
////   proxies by the pin the handshake admitted. It also keeps, per binding,
////   the plane's broker subject and base policy an attach was answered with,
////   recorded before the attach's response is sent; a tunnelled call clears on
////   that broker under the meet of that base with its own, with no grants and
////   this executor's own demand (`cleared_spec`).
////
//// The executor never dials. A proxy with no connection waits for the
//// orchestrator to dial again.
////
//// ## Flow
////
//// `start` → `accepting` → `connection` → `serve` → `proxy`
////
//// 1. `start` listens, starts the book and the acceptor.
//// 2. `accepting` hands each accepted socket to a new `connection`, which runs
////    the handshake in its own process.
//// 3. `serve` is a connection's event handler: requests become waiters,
////    answers go to proxies, and waiters' replies go out as responses.
//// 4. `proxy` is a binding's owner port.

import broker/broker
import broker/exec
import broker/internal/call
import broker/policy.{type SandboxPolicy}
import client/internal/ffi_os
import client/internal/ffi_tls_stream.{type Stream}
import client/remote/address.{type Address}
import client/remote/blob_service
import client/remote/blob_transfer
import client/remote/protocol.{type HostMessage, type OwnerMessage}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_bridge.{type OwnerReply}
import client/remote/untrusted_codec
import client/remote/untrusted_wire.{type Request, type Response}
import core/clock
import core/corruption
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/state_machine as sm

/// How an untrusted executor listens.
pub type Config {
  Config(
    /// The interface to listen on, an IP literal, or `""` for every one.
    address: String,
    /// The port, or zero to pick one.
    port: Int,
    /// This executor's certificate, key and authority.
    credentials: ffi_tls_stream.Credentials,
    /// The pins of the orchestrators that may connect.
    orchestrators: List(BitArray),
    /// The executor's host on this node.
    host: Address(HostMessage(RemoteCensus)),
    /// The keeper of placed blobs (protocol-change/110), or `None` for an
    /// executor that takes none, which refuses every blob request.
    blobs: Option(blob_service.Service),
    /// The enforcement this executor demands of a tunnelled call
    /// (protocol-change/117), the setting its planes are built with. The
    /// orchestrator's spec carries none, so it cannot ask for less.
    demand: exec.EnforcementDemand,
    /// Where connections, refusals and violations are logged.
    logger: Logger,
  )
}

/// What the book records for a binding at its attach: the plane's broker and
/// the base policy it was built with, which a tunnelled call clears on and
/// under.
type Plane {
  Plane(broker: Subject(broker.Msg), base_policy: SandboxPolicy)
}

/// Whether a tunnel waiter's frame is its last.
type TunnelEnd {
  /// More frames follow.
  Continues

  /// The waiter ends after this frame.
  Ends
}

/// A running gateway.
pub type Gateway {
  Gateway(
    /// The port the listener is bound to.
    port: Int,
    /// The acceptor, whose exit ends the gateway.
    acceptor: Pid,
  )
}

/// What the book receives.
pub opaque type BookMessage {
  /// A connection from orchestrator `pin` finished its greeting.
  Joined(pin: BitArray, connection: Subject(ConnectionMessage), pid: Pid)

  /// The proxy for `binding`, made if it is new. An earlier binding of the
  /// same session from the same orchestrator is retired.
  ProxyFor(
    pin: BitArray,
    session: String,
    incarnation: Int,
    binding: BitArray,
    reply: Subject(Result(Subject(OwnerMessage), Nil)),
  )

  /// The session `binding` was made for, if the orchestrator holds it, which is
  /// what a blob request is placed for.
  HolderOf(
    pin: BitArray,
    binding: BitArray,
    reply: Subject(Result(String, Nil)),
  )

  /// A scope closed: the session's binding retires if it is still the one the
  /// closed open made, so a late close never retires a newer open's binding.
  Closed(pin: BitArray, session: String, incarnation: Int)

  /// The proxy control subject for `binding`, if the orchestrator holds one.
  ProxyOf(
    pin: BitArray,
    binding: BitArray,
    reply: Subject(Result(Subject(ProxyMessage), Nil)),
  )

  /// A connection went down.
  ConnectionDown(down: process.Down)

  /// The plane an attach of `binding` was answered with. The attach's waiter
  /// asks this, and waits for the reply, before it sends the attach's
  /// response, so a `clear_call` that follows the response finds the record.
  Recorded(pin: BitArray, binding: BitArray, plane: Plane, reply: Subject(Nil))

  /// The plane recorded for `binding`, if this orchestrator holds the binding
  /// and its attach recorded one.
  PlaneOf(pin: BitArray, binding: BitArray, reply: Subject(Result(Plane, Nil)))
}

/// What a connection receives.
pub opaque type ConnectionMessage {
  /// The acceptor has handed the socket over; run the handshake.
  Begin

  /// The socket delivered something.
  Inbound(inbound: ffi_tls_stream.Inbound)

  /// A waiter's answer to request `id`, or `None` for an ack.
  Replied(id: Int, response: Option(Response))

  /// A proxy's callback frame, to send as it is.
  Outgoing(frame: BitArray)

  /// A tunnel waiter's frame for tunnelled call `id`: its `cleared`, or one
  /// of its events. A waiter's last frame removes it.
  FromTunnel(id: Int, frame: untrusted_wire.Frame, end: TunnelEnd)

  /// `hello` took too long.
  HelloExpired
}

/// What a proxy receives besides the plane's `OwnerMessage`s.
pub opaque type ProxyMessage {
  /// The orchestrator's current connection.
  Connected(connection: Subject(ConnectionMessage))

  /// The orchestrator has no connection.
  Disconnected

  /// The orchestrator's answer to callback `id`, not yet decoded.
  Answered(id: Int, body: JsonValue)

  /// A newer attach of the session replaced this binding.
  Retire
}

/// A connection's phase.
type Phase {
  /// Handed over, handshake not yet run.
  Accepted

  /// Handshake done, `hello` awaited.
  Waiting(stream: Stream, pin: BitArray)

  /// Greeted: frames flow.
  Serving(stream: Stream, pin: BitArray)
}

/// A connection's data.
type Connection {
  Connection(
    /// The connection's own subject, for waiters and proxies.
    subject: Subject(ConnectionMessage),
    /// The socket before its handshake.
    raw: Stream,
    /// The book.
    book: Subject(BookMessage),
    /// The host.
    host: Address(HostMessage(RemoteCensus)),
    /// The keeper of placed blobs, if this executor takes them.
    blobs: Option(blob_service.Service),
    /// The waiters of requests not yet answered, by request id.
    waiters: Dict(Int, Pid),
    /// The tunnel waiters of calls not yet settled, by request id. Each is
    /// linked to this connection (protocol-change/117).
    tunnels: Dict(Int, Pid),
    /// The enforcement a tunnelled call is cleared with.
    demand: exec.EnforcementDemand,
    /// Where things are logged.
    logger: Logger,
  )
}

/// The book's state.
type Book {
  Book(
    /// The book's own subject.
    subject: Subject(BookMessage),
    /// Each orchestrator's current connection.
    connections: Dict(BitArray, #(Subject(ConnectionMessage), Pid)),
    /// Each proxy, by orchestrator and binding.
    proxies: Dict(#(BitArray, BitArray), Proxy),
    /// Each session's current binding, by orchestrator.
    sessions: Dict(#(BitArray, String), BitArray),
    /// The keeper of placed blobs, told when a binding retires.
    blobs: Option(blob_service.Service),
    /// Where the book and its proxies log.
    logger: Logger,
  )
}

/// One proxy, as the book holds it.
type Proxy {
  Proxy(
    /// The session the binding was made for.
    session: String,
    /// The scope incarnation of the attach that made it.
    incarnation: Int,
    /// The subject the host is given as the owner port.
    owner: Subject(OwnerMessage),
    /// The proxy's control subject.
    control: Subject(ProxyMessage),
    /// The plane the binding's attach was answered with, once it is.
    plane: Option(Plane),
  )
}

/// A proxy's state.
type ProxyState {
  ProxyState(
    /// The binding it answers for.
    binding: BitArray,
    /// The orchestrator's current connection.
    connection: Option(Subject(ConnectionMessage)),
    /// The next callback id.
    next_id: Int,
    /// Callbacks awaiting an answer, by id.
    outstanding: Dict(Int, OwnerReply),
    /// Where a callback that cannot be sent is logged.
    logger: Logger,
  )
}

/// What a proxy's selector delivers.
type ProxyEvent {
  /// An owner request from the plane.
  Owner(message: OwnerMessage)

  /// A control message.
  Control(message: ProxyMessage)
}

/// How long an accept waits before it waits again. The loop has nothing else
/// to do; the bound only keeps the acceptor answering system messages.
const accept_ms = 60_000

/// How long a client has to finish the TLS handshake.
const handshake_ms = 10_000

/// How long an orchestrator has to send `hello` after the handshake.
const hello_ms = 10_000

/// How long a connection waits for the book.
const book_ms = 5000

/// The most callbacks one proxy has outstanding; beyond it the plane is
/// answered with the in-band failure at once.
pub const max_proxy_callbacks = 64

/// Listens, starts the book and the acceptor, and answers the bound port.
/// The book and the acceptor are linked to the caller; the daemon unlinks the
/// acceptor, and the book, like the daemon's other services, ends only with
/// the process that started it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(gateway) = untrusted_gateway.start(config)
/// ```
pub fn start(config: Config) -> Result(Gateway, String) {
  use listener <- result.try(
    ffi_tls_stream.listen(
      config.address,
      config.port,
      config.credentials,
      config.orchestrators,
      untrusted_wire.max_frame_bytes,
    )
    |> result.map_error(fn(_failure) {
      "the untrusted executor listener could not start"
    }),
  )
  use port <- result.try(
    ffi_tls_stream.port_of(listener)
    |> result.replace_error("the untrusted executor listener has no port"),
  )
  use book <- result.try(start_book(config.blobs, config.logger))
  let served =
    Served(book:, host: config.host, blobs: config.blobs, demand: config.demand)
  let acceptor =
    process.spawn(fn() { accepting(listener, served, config.logger) })
  Ok(Gateway(port:, acceptor:))
}

/// What every connection serves: the book, the host and the blob keeper.
type Served {
  Served(
    book: Subject(BookMessage),
    host: Address(HostMessage(RemoteCensus)),
    blobs: Option(blob_service.Service),
    demand: exec.EnforcementDemand,
  )
}

/// Accepts connections for as long as the listener is open, handing each to
/// a connection process of its own.
fn accepting(
  listener: ffi_tls_stream.Listener,
  served: Served,
  logger: Logger,
) -> Nil {
  // A timeout only means nobody connected; a closed listener ends the loop.
  case ffi_tls_stream.accept(listener, accept_ms) {
    Ok(raw) -> {
      handed(raw, served, logger)
      accepting(listener, served, logger)
    }
    Error(ffi_tls_stream.TimedOut)
    | Error(ffi_tls_stream.Refused)
    | Error(ffi_tls_stream.Unavailable) -> accepting(listener, served, logger)
    Error(ffi_tls_stream.Closed) | Error(ffi_tls_stream.InvalidConfiguration) ->
      Nil
  }
}

/// Starts a connection for an accepted socket and gives the socket to it. A
/// connection that cannot start, or cannot take the socket, closes it.
fn handed(raw: Stream, served: Served, logger: Logger) -> Nil {
  let started =
    connection(raw, served, logger)
    |> result.try(fn(started) {
      ffi_tls_stream.hand_to(raw, started.pid)
      |> result.replace(started.data)
      |> result.map_error(fn(_failure) {
        // A connection that never got its socket would wait in `Accepted`
        // forever, so it is stopped here.
        process.kill(started.pid)
      })
    })

  // The handshake runs in the connection, after it owns the socket.
  case started {
    Ok(subject) -> process.send(subject, Begin)
    Error(Nil) -> ffi_tls_stream.close(raw)
  }
}

/// Starts one connection's machine, unlinked, so a connection that fails
/// takes nothing else with it.
fn connection(
  raw: Stream,
  served: Served,
  logger: Logger,
) -> Result(sm.Started(Subject(ConnectionMessage)), Nil) {
  sm.new_with_initialiser(1000, fn(subject) {
    let data =
      Connection(
        subject:,
        raw:,
        book: served.book,
        host: served.host,
        blobs: served.blobs,
        waiters: dict.new(),
        tunnels: dict.new(),
        demand: served.demand,
        logger:,
      )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> ffi_tls_stream.select(Inbound)
    sm.initialised(Accepted, data)
    |> sm.selecting(selector)
    |> sm.returning(subject)
    |> Ok
  })
  |> sm.on_event(serve)
  |> sm.unlinked
  |> sm.start
  |> result.replace_error(Nil)
}

/// A connection's event handler.
fn serve(
  phase: Phase,
  data: Connection,
  message: ConnectionMessage,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  // The handshake, the greeting and the frames each belong to one phase; a
  // waiter's reply and a proxy's callback go out once the link is serving.
  case phase, message {
    Accepted, Begin -> handshaken(data)
    Waiting(stream:, pin:), Inbound(inbound:) ->
      hello(stream, pin, data, inbound)
    Waiting(stream:, ..), HelloExpired ->
      closed(stream, data, "the orchestrator sent no hello")
    Serving(stream:, pin:), Inbound(inbound:) ->
      framed(stream, pin, data, inbound)
    Serving(stream:, ..), Replied(id:, response:) ->
      replied(stream, data, id, response)
    Serving(stream:, ..), Outgoing(frame:) -> outgoing(stream, data, frame)
    Serving(stream:, ..), FromTunnel(id:, frame:, end:) ->
      outgoing(
        stream,
        tunnel_ended(data, id, end),
        untrusted_codec.encode_frame(frame),
      )
    _, Replied(id:, ..) ->
      sm.keep(Connection(..data, waiters: dict.delete(data.waiters, id)))
    _, FromTunnel(id:, end:, ..) -> sm.keep(tunnel_ended(data, id, end))
    _, Begin | _, Inbound(..) | _, Outgoing(..) | _, HelloExpired ->
      sm.keep(data)
  }
}

/// Runs the TLS handshake, reads the orchestrator's pin and waits for
/// `hello`.
fn handshaken(
  data: Connection,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let shaken =
    ffi_tls_stream.handshake(data.raw, handshake_ms)
    |> result.try(fn(stream) {
      ffi_tls_stream.peer_pin(stream)
      |> result.try(fn(pin) {
        ffi_tls_stream.arm(stream) |> result.replace(#(stream, pin))
      })
    })

  // A peer whose certificate is not pinned fails the handshake itself.
  case shaken {
    Ok(#(stream, pin)) ->
      sm.transition(to: Waiting(stream:, pin:), data:)
      |> sm.with_state_timeout(after: hello_ms, sending: HelloExpired)
    Error(_failure) -> sm.stop()
  }
}

/// The orchestrator's first frame. A `hello` of the same versions is
/// answered with `welcome` and the connection joins the book; any other
/// first frame closes it. A `hello` of other versions is answered with this
/// executor's versions before the close, so the orchestrator can say why.
fn hello(
  stream: Stream,
  pin: BitArray,
  data: Connection,
  inbound: ffi_tls_stream.Inbound,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let welcome =
    untrusted_codec.encode_frame(untrusted_wire.Welcome(
      wire: untrusted_wire.version,
      protocol: protocol.version,
    ))

  // Only a well-formed hello moves the connection on.
  case inbound {
    ffi_tls_stream.Received(frame:) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(untrusted_codec.HelloEnvelope(wire:, protocol: theirs))
          if wire == untrusted_wire.version && theirs == protocol.version
        -> greeted(stream, pin, data, welcome)
        Ok(untrusted_codec.HelloEnvelope(..)) -> {
          let _sent = ffi_tls_stream.send(stream, welcome)
          closed(stream, data, "the orchestrator speaks another version")
        }
        Ok(_other) -> closed(stream, data, "the first frame was not hello")
        Error(report) -> closed(stream, data, corruption.describe(report))
      }
    ffi_tls_stream.Ended | ffi_tls_stream.Broken -> sm.stop()
  }
}

/// Answers `welcome`, joins the book, and starts serving.
fn greeted(
  stream: Stream,
  pin: BitArray,
  data: Connection,
  welcome: BitArray,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let ready =
    ffi_tls_stream.send(stream, welcome)
    |> result.try(fn(_sent) { ffi_tls_stream.arm(stream) })

  // The book is told before any request is read, and it handles messages
  // from one sender in order, so a proxy made for this connection's first
  // attach already knows the connection.
  case ready {
    Ok(Nil) -> {
      process.send(
        data.book,
        Joined(pin:, connection: data.subject, pid: process.self()),
      )
      log.info(data.logger, "untrusted_gateway.joined", [])
      sm.transition(to: Serving(stream:, pin:), data:)
    }
    Error(_failure) -> closed(stream, data, "the welcome could not be sent")
  }
}

/// One frame from a greeted orchestrator.
fn framed(
  stream: Stream,
  pin: BitArray,
  data: Connection,
  inbound: ffi_tls_stream.Inbound,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  // An orchestrator sends requests, cancels and answers and nothing else.
  case inbound {
    ffi_tls_stream.Received(frame:) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(untrusted_codec.RequestEnvelope(id:, body:)) ->
          requested(stream, pin, data, id, body)
        Ok(untrusted_codec.CancelEnvelope(id:)) ->
          armed(stream, cancelled(data, id))
        Ok(untrusted_codec.AnswerEnvelope(binding:, id:, body:)) -> {
          routed(data, pin, binding, id, body)
          armed(stream, data)
        }
        Ok(untrusted_codec.HelloEnvelope(..))
        | Ok(untrusted_codec.WelcomeEnvelope(..))
        | Ok(untrusted_codec.ResponseEnvelope(..))
        | Ok(untrusted_codec.CallbackEnvelope(..))
        | Ok(untrusted_codec.OversizedEnvelope(..))
        | Ok(untrusted_codec.CallEventEnvelope(..)) ->
          closed(
            stream,
            data,
            "an orchestrator sent a frame only an executor sends",
          )
        Error(report) -> closed(stream, data, corruption.describe(report))
      }
    ffi_tls_stream.Ended | ffi_tls_stream.Broken -> stopped(data)
  }
}

/// A request: decoded, then run by a waiter of its own. An attach first gets
/// its binding's proxy from the book, to stand in for the owner port.
fn requested(
  stream: Stream,
  pin: BitArray,
  data: Connection,
  id: Int,
  body: JsonValue,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let decoded =
    untrusted_codec.decode_request(body)
    |> result.map_error(corruption.describe)
    |> result.try(fn(request) {
      port_for(data, pin, request)
      |> result.map(fn(port) { #(request, port) })
    })

  // A request that does not decode, or an attach whose proxy cannot be made,
  // closes the connection; the orchestrator sends it again on the next one.
  case decoded {
    Ok(#(request, port)) -> armed(stream, waiting(data, pin, id, request, port))
    Error(reason) -> closed(stream, data, reason)
  }
}

/// The owner port an attach is given: its binding's proxy.
fn port_for(
  data: Connection,
  pin: BitArray,
  request: Request,
) -> Result(Option(Subject(OwnerMessage)), String) {
  // Only an attach names an owner port.
  case request {
    untrusted_wire.AttachRequest(session:, incarnation:, binding:, ..) ->
      call.try_call(data.book, waiting: book_ms, sending: ProxyFor(
        pin:,
        session:,
        incarnation:,
        binding:,
        reply: _,
      ))
      |> result.replace_error(Nil)
      |> result.flatten
      |> result.map(Some)
      |> result.replace_error("the executor could not make the session's proxy")
    _other -> Ok(None)
  }
}

/// Starts the waiter for one request. An ack and a stop are sent from here,
/// because they have no answer to wait for.
fn waiting(
  data: Connection,
  pin: BitArray,
  id: Int,
  request: Request,
  port: Option(Subject(OwnerMessage)),
) -> Connection {
  let host = data.host
  let book = data.book
  let blobs = data.blobs
  let connection = data.subject
  let carrier = process.self()

  // The waiter is unlinked on purpose: the host reads its death as an abort,
  // so it must not die with this connection for any other reason. When the
  // connection dies first, the waiter leaves with `noconnection`, which the
  // host reads as a partition (`untrusted_bridge.ask_host`). A weft run would
  // tie it to a scope this connection owns and kill it with another reason.
  // A tunnelled call's waiter is the reverse, and is linked (`tunnelled`).
  case request, untrusted_wire.response_kind(request) {
    untrusted_wire.ClearCallRequest(binding:, spec:, waiting_ms:), _ ->
      tunnelled(data, pin, id, binding, spec, waiting_ms)
    _, None -> {
      let _none = untrusted_bridge.ask_host(host, request, port, carrier)
      data
    }
    _, Some(_kind) -> {
      let waiter =
        process.spawn_unlinked(fn() {
          let response =
            answer(
              Answering(host:, book:, blobs:, pin:, carrier:),
              request,
              port,
            )
          process.send(connection, Replied(id:, response:))
        })
      Connection(..data, waiters: dict.insert(data.waiters, id, waiter))
    }
  }
}

/// What a waiter needs to answer one request.
type Answering {
  Answering(
    host: Address(HostMessage(RemoteCensus)),
    book: Subject(BookMessage),
    blobs: Option(blob_service.Service),
    pin: BitArray,
    carrier: Pid,
  )
}

/// Answers one request in its waiter. Most go to the host; a blob request goes
/// to the blob keeper for the binding's session, and an outcome piece is cut
/// from the host's ledger (protocol-change/110). A close that the host answered
/// tells the book, so the closed open's binding retires.
fn answer(
  answering: Answering,
  request: Request,
  port: Option(Subject(OwnerMessage)),
) -> Option(Response) {
  let Answering(host:, carrier:, ..) = answering

  // The three requests of 110 have their own answerers; the rest are 078's.
  case request {
    untrusted_wire.BlobStatusRequest(binding:, digest:) ->
      Some(untrusted_wire.BlobStatusAnswered(
        held_by(answering, binding)
        |> result.try(fn(found) { blob_service.stage(found.0, found.1, digest) }),
      ))
    untrusted_wire.BlobPutRequest(binding:, piece:) ->
      Some(
        untrusted_wire.BlobPutAnswered(case held_by(answering, binding) {
          Ok(#(service, holder)) -> blob_service.take(service, holder, piece)
          Error(reason) -> blob_transfer.Refused(reason)
        }),
      )
    untrusted_wire.OutcomePieceRequest(key:, offset:) ->
      Some(untrusted_bridge.outcome_piece(host, key, offset, carrier))

    // The plane an attach was answered with is recorded under its binding
    // before the response leaves, so a clearance that follows it finds both.
    untrusted_wire.AttachRequest(binding:, ..) -> {
      let #(response, census) =
        untrusted_bridge.ask_attach(host, request, port, carrier)
      recorded(answering, binding, census)
      Some(response)
    }

    untrusted_wire.CloseRequest(session:, incarnation:, ..) -> {
      let response = untrusted_bridge.ask_host(host, request, port, carrier)
      closed_scope(answering, session, incarnation, response)
      response
    }
    _other -> untrusted_bridge.ask_host(host, request, port, carrier)
  }
}

/// The keeper and the holder a blob request is placed for: the binding must be
/// one this orchestrator holds in the book, which answers its session.
fn held_by(
  answering: Answering,
  binding: BitArray,
) -> Result(#(blob_service.Service, blob_service.Holder), String) {
  use service <- result.try(option.to_result(
    answering.blobs,
    "this executor takes no placed blobs",
  ))
  use session <- result.map(
    call.try_call(answering.book, waiting: book_ms, sending: HolderOf(
      pin: answering.pin,
      binding:,
      reply: _,
    ))
    |> result.replace_error(Nil)
    |> result.flatten
    |> result.replace_error("the binding is not one this orchestrator holds"),
  )
  #(service, blob_service.Holder(pin: answering.pin, binding:, session:))
}

/// Tells the book a scope closed, when the host says it did.
fn closed_scope(
  answering: Answering,
  session: String,
  incarnation: Int,
  response: Option(Response),
) -> Nil {
  // Only a close the host carried out retires the binding; a refused one
  // leaves the scope, and its binding, as they were.
  case response {
    Some(untrusted_wire.CloseAnswered(Ok(_outcome))) ->
      process.send(
        answering.book,
        Closed(pin: answering.pin, session:, incarnation:),
      )
    _other -> Nil
  }
}

/// Cancels request `id` by killing its waiter, which the host reads as the
/// asker dying and so as an abort. A tunnelled call's waiter is killed the
/// same way, and the broker's relay reads its death as the caller's, but it
/// is linked to this connection, which does not trap exits, so it is unlinked
/// first or its death would end the connection too.
fn cancelled(data: Connection, id: Int) -> Connection {
  // A request already answered has no waiter left to kill.
  case dict.get(data.waiters, id), dict.get(data.tunnels, id) {
    Ok(waiter), _ -> {
      process.kill(waiter)
      Connection(..data, waiters: dict.delete(data.waiters, id))
    }
    Error(Nil), Ok(tunnel) -> {
      process.unlink(tunnel)
      process.kill(tunnel)
      Connection(..data, tunnels: dict.delete(data.tunnels, id))
    }
    Error(Nil), Error(Nil) -> data
  }
}

/// Tells the book the plane an attach was answered with, and waits for the
/// book's reply, so the record is in place before the attach's response is
/// sent. A refused attach records nothing.
fn recorded(
  answering: Answering,
  binding: BitArray,
  census: Option(RemoteCensus),
) -> Nil {
  // Only an attach the host answered has a plane to record.
  case census {
    None -> Nil
    Some(census) -> {
      let plane =
        Plane(broker: census.broker, base_policy: census.census.base_policy)
      let _answered =
        call.try_call(answering.book, waiting: book_ms, sending: Recorded(
          pin: answering.pin,
          binding:,
          plane:,
          reply: _,
        ))
      Nil
    }
  }
}

/// Starts the waiter of one tunnelled call (protocol-change/117), linked to
/// this connection. A waiter killed with its connection may be inside
/// `broker.clear_call`, waiting out a full pool in its own process: it dies at
/// once, and a call the broker dispatches afterwards still names it as the
/// caller, so the relay's monitor on it cancels the child as it starts. This
/// is the reverse of a `run`'s waiter, which outlives its connection so the
/// call's outcome reaches the ledger for the orchestrator's re-send; a
/// tunnelled call is never re-sent.
fn tunnelled(
  data: Connection,
  pin: BitArray,
  id: Int,
  binding: BitArray,
  spec: untrusted_wire.TunnelSpec,
  waiting_ms: Int,
) -> Connection {
  let book = data.book
  let demand = data.demand
  let report = fn(frame, end) {
    process.send(data.subject, FromTunnel(id:, frame:, end:))
  }
  let waiter =
    process.spawn(fn() {
      tunnel_waiter(book, pin, binding, spec, waiting_ms, demand, id, report)
    })
  Connection(..data, tunnels: dict.insert(data.tunnels, id, waiter))
}

/// One tunnelled call, in its waiter: the plane recorded for the binding, the
/// spec this executor clears, its clearance, and its events. The waiter owns
/// the events subject, and `cleared` reaches the connection before the first
/// event because both are messages from this one process.
fn tunnel_waiter(
  book: Subject(BookMessage),
  pin: BitArray,
  binding: BitArray,
  spec: untrusted_wire.TunnelSpec,
  waiting_ms: Int,
  demand: exec.EnforcementDemand,
  id: Int,
  report: fn(untrusted_wire.Frame, TunnelEnd) -> Nil,
) -> Nil {
  let cleared = fn(answer) {
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(answer),
    )
  }
  let plane =
    call.try_call(book, waiting: book_ms, sending: PlaneOf(
      pin:,
      binding:,
      reply: _,
    ))
    |> result.replace_error(Nil)
    |> result.flatten
  let events = process.new_subject()

  // A binding this orchestrator does not hold, or one whose attach recorded
  // no plane, has no broker to clear on.
  case plane {
    Error(Nil) -> report(cleared(Error(broker.BrokerUnavailable)), Ends)
    Ok(plane) -> {
      let handle =
        broker.over(plane.broker, clock.from_function(ffi_os.system_time_ms))
      let executor_spec = cleared_spec(plane, spec, demand)

      // The call clears or is refused; a cleared call's stdin is closed at
      // once, because no tunnelled caller writes input.
      case
        broker.clear_call(handle, executor_spec, events:, waiting: waiting_ms)
      {
        Error(refusal) -> report(cleared(Error(refusal)), Ends)
        Ok(call) -> {
          broker.stdin(handle, call, data: <<>>, eof: True)
          report(cleared(Ok(Nil)), Continues)
          forwarded_events(events, id, report)
        }
      }
    }
  }
}

/// The spec this executor clears for a tunnelled call. Its base is the meet
/// of the plane's base with the orchestrator's, so a spec can narrow the
/// plane's base and never widen it; the plane's writable roots are counted as
/// readable for the meet, because the meet intersects the two lists apart and
/// a Git call's read policy lists a writable root as readable, which the jail
/// already allows. There are no grants, because a tunnelled call has no
/// escalation that could approve one, and the demand is this executor's own.
fn cleared_spec(
  plane: Plane,
  spec: untrusted_wire.TunnelSpec,
  demand: exec.EnforcementDemand,
) -> broker.CallSpec {
  let base = plane.base_policy
  let view =
    policy.SandboxPolicy(
      ..base,
      readable_roots: list.unique(list.append(
        base.readable_roots,
        base.writable_roots,
      )),
    )
  let #(base_policy, _narrowed) =
    policy.compose(base: view, requirements: spec.base_policy, grants: [])
  broker.CallSpec(
    op_id: spec.op_id,
    step_id: spec.step_id,
    base_policy:,
    requirements: spec.requirements,
    grants: [],
    response: spec.response,
    demand:,
    argv: spec.argv,
    env: spec.env,
    cwd: spec.cwd,
    budget: spec.budget,
  )
}

/// Forwards a cleared call's events until its settlement. A chunk with no
/// bytes is not forwarded: the helper sends one when a stream's admitted
/// bytes reach its cap exactly and the child writes more, to say truncation
/// began, and the settled result says the same thing.
fn forwarded_events(
  events: Subject(broker.CallEvent),
  id: Int,
  report: fn(untrusted_wire.Frame, TunnelEnd) -> Nil,
) -> Nil {
  let event = fn(event) { untrusted_wire.CallEvent(call: id, event:) }

  // The broker delivers exactly one settlement after a clearance, and it is
  // the waiter's last frame.
  case process.receive_forever(events) {
    broker.CallOutput(stream:, data:, ..) ->
      case bit_array.byte_size(data) {
        0 -> forwarded_events(events, id, report)
        _bytes -> {
          report(event(untrusted_wire.TunnelOutput(stream:, data:)), Continues)
          forwarded_events(events, id, report)
        }
      }
    broker.CallSettled(outcome:) ->
      report(event(untrusted_wire.TunnelSettled(outcome:)), Ends)
  }
}

/// Forgets a tunnel waiter whose last frame has arrived.
fn tunnel_ended(data: Connection, id: Int, end: TunnelEnd) -> Connection {
  // A waiter that goes on keeps its place.
  case end {
    Continues -> data
    Ends -> Connection(..data, tunnels: dict.delete(data.tunnels, id))
  }
}

/// Stops the connection normally. A normal stop does not propagate through a
/// link, so the tunnel waiters are unlinked and killed first: the executor
/// must not keep a child running for an orchestrator whose connection is gone.
/// The other waiters run on.
fn stopped(data: Connection) -> sm.Next(Phase, Connection, ConnectionMessage) {
  dict.each(data.tunnels, fn(_id, tunnel) {
    process.unlink(tunnel)
    process.kill(tunnel)
  })
  sm.stop()
}

/// Hands an answer to the proxy of the binding it names, if this
/// orchestrator holds one.
fn routed(
  data: Connection,
  pin: BitArray,
  binding: BitArray,
  id: Int,
  body: JsonValue,
) -> Nil {
  let control =
    call.try_call(data.book, waiting: book_ms, sending: ProxyOf(
      pin:,
      binding:,
      reply: _,
    ))
    |> result.replace_error(Nil)
    |> result.flatten

  // A binding this orchestrator does not hold here has nobody to answer.
  case control {
    Ok(control) -> process.send(control, Answered(id:, body:))
    Error(Nil) -> Nil
  }
}

/// A waiter's answer, sent as the response to its request. A response whose
/// frame would pass `max_frame_bytes` or hold more than `max_frame_values`
/// values is sent as an `Oversized` instead, which the orchestrator follows by
/// fetching the outcome in pieces (protocol-change/110) or, for a reply that
/// holds no outcome, answers as lost at once; sent whole, the orchestrator
/// would refuse it by closing the connection, and the re-send on the next
/// connection would meet the same frame.
fn replied(
  stream: Stream,
  data: Connection,
  id: Int,
  response: Option(Response),
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let data = Connection(..data, waiters: dict.delete(data.waiters, id))

  // Only a request with a reply has a waiter, and its waiter always replies.
  case response {
    Some(response) -> {
      let fitting =
        untrusted_codec.encode_fitting(untrusted_wire.Response(id:, response:))

      // A response over either bound goes out as its description. A fetched
      // outcome is parsed under the same value bound, so one that holds too
      // many values is answered lost rather than asked for again.
      let frame = case fitting {
        Ok(frame) -> frame
        Error(untrusted_codec.Unfit(bytes:, ..)) ->
          untrusted_codec.encode_frame(untrusted_bridge.oversized(
            id,
            response,
            bytes,
          ))
      }

      outgoing(stream, data, frame)
    }
    None -> sm.keep(data)
  }
}

/// Sends a frame. A failed send is a dead connection.
fn outgoing(
  stream: Stream,
  data: Connection,
  frame: BitArray,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  // The book's monitor tells the proxies when this connection stops.
  case ffi_tls_stream.send(stream, frame) {
    Ok(Nil) -> sm.keep(data)
    Error(_failure) -> closed(stream, data, "a send failed")
  }
}

/// Asks for the next frame.
fn armed(
  stream: Stream,
  data: Connection,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  // A connection that cannot be read any more is closed.
  case ffi_tls_stream.arm(stream) {
    Ok(Nil) -> sm.keep(data)
    Error(_failure) -> closed(stream, data, "the connection could not be read")
  }
}

/// Logs why, closes the socket and stops. The request waiters run on; the
/// tunnel waiters are killed (`stopped`).
fn closed(
  stream: Stream,
  data: Connection,
  reason: String,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  log.warn(data.logger, "untrusted_gateway.closed", [
    field.text("reason", reason),
  ])
  ffi_tls_stream.close(stream)
  stopped(data)
}

/// Starts the book, linked to the caller.
fn start_book(
  blobs: Option(blob_service.Service),
  logger: Logger,
) -> Result(Subject(BookMessage), String) {
  actor.new_with_initialiser(1000, fn(subject) {
    let book =
      Book(
        subject:,
        connections: dict.new(),
        proxies: dict.new(),
        sessions: dict.new(),
        blobs:,
        logger:,
      )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(ConnectionDown)
    actor.initialised(book)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(booked)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("the untrusted executor's book did not start")
}

/// The book's handler.
fn booked(book: Book, message: BookMessage) -> actor.Next(Book, BookMessage) {
  // Each message is one change to who is connected or which proxy answers.
  case message {
    Joined(pin:, connection:, pid:) ->
      actor.continue(joined(book, pin, connection, pid))
    ProxyFor(pin:, session:, incarnation:, binding:, reply:) ->
      case proxy_for(book, pin, session, incarnation, binding) {
        Ok(#(book, proxy)) -> {
          process.send(reply, Ok(proxy.owner))
          actor.continue(book)
        }
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(book)
        }
      }
    ProxyOf(pin:, binding:, reply:) -> {
      dict.get(book.proxies, #(pin, binding))
      |> result.map(fn(proxy) { proxy.control })
      |> process.send(reply, _)
      actor.continue(book)
    }
    HolderOf(pin:, binding:, reply:) -> {
      dict.get(book.proxies, #(pin, binding))
      |> result.map(fn(proxy) { proxy.session })
      |> process.send(reply, _)
      actor.continue(book)
    }
    Closed(pin:, session:, incarnation:) ->
      actor.continue(closed_binding(book, pin, session, incarnation))
    ConnectionDown(down:) -> actor.continue(departed(book, down))

    // A record lands on the binding's proxy, so it retires with the binding;
    // a binding retired first records nothing.
    Recorded(pin:, binding:, plane:, reply:) -> {
      let book = with_plane(book, pin, binding, plane)
      process.send(reply, Nil)
      actor.continue(book)
    }
    PlaneOf(pin:, binding:, reply:) -> {
      dict.get(book.proxies, #(pin, binding))
      |> result.try(fn(proxy) { option.to_result(proxy.plane, Nil) })
      |> process.send(reply, _)
      actor.continue(book)
    }
  }
}

/// Records the plane an attach of `binding` was answered with on the binding's
/// proxy.
fn with_plane(
  book: Book,
  pin: BitArray,
  binding: BitArray,
  plane: Plane,
) -> Book {
  // A binding retired before its record arrived records nothing.
  case dict.get(book.proxies, #(pin, binding)) {
    Ok(proxy) ->
      Book(
        ..book,
        proxies: dict.insert(
          book.proxies,
          #(pin, binding),
          Proxy(..proxy, plane: Some(plane)),
        ),
      )
    Error(Nil) -> book
  }
}

/// Retires a session's binding after its scope closed, if the binding is the
/// one the closed incarnation's attach made.
fn closed_binding(
  book: Book,
  pin: BitArray,
  session: String,
  incarnation: Int,
) -> Book {
  let current =
    dict.get(book.sessions, #(pin, session))
    |> result.try(fn(binding) { dict.get(book.proxies, #(pin, binding)) })

  // A newer open of the session has a binding of its own, which this close
  // does not touch.
  case current {
    Ok(proxy) if proxy.incarnation == incarnation ->
      retire_session(book, pin, session)
    Ok(_newer) | Error(Nil) -> book
  }
}

/// A connection from `pin` is now that orchestrator's current one, and every
/// proxy of that orchestrator is told so.
fn joined(
  book: Book,
  pin: BitArray,
  connection: Subject(ConnectionMessage),
  pid: Pid,
) -> Book {
  let _monitor = process.monitor(pid)
  each_proxy(book, pin, Connected(connection))
  Book(
    ..book,
    connections: dict.insert(book.connections, pin, #(connection, pid)),
  )
}

/// A connection went down. If it was its orchestrator's current one, every
/// proxy of that orchestrator fails what it has outstanding.
fn departed(book: Book, down: process.Down) -> Book {
  // Only a process monitor is one the book made.
  let gone = case down {
    process.ProcessDown(pid:, ..) ->
      dict.to_list(book.connections)
      |> list.find(fn(entry) { entry.1.1 == pid })
      |> result.map(fn(entry) { entry.0 })
    process.PortDown(..) -> Error(Nil)
  }

  // A connection a newer one already replaced is not the current one.
  case gone {
    Ok(pin) -> {
      each_proxy(book, pin, Disconnected)
      Book(..book, connections: dict.delete(book.connections, pin))
    }
    Error(Nil) -> book
  }
}

/// Sends one control message to every proxy of an orchestrator.
fn each_proxy(book: Book, pin: BitArray, message: ProxyMessage) -> Nil {
  dict.each(book.proxies, fn(at, proxy) {
    // Another orchestrator's proxies are not told.
    case at.0 == pin {
      True -> process.send(proxy.control, message)
      False -> Nil
    }
  })
}

/// The proxy for a binding: the existing one, or a new one that knows the
/// orchestrator's current connection, retiring the session's earlier binding
/// from the same orchestrator.
fn proxy_for(
  book: Book,
  pin: BitArray,
  session: String,
  incarnation: Int,
  binding: BitArray,
) -> Result(#(Book, Proxy), Nil) {
  // A re-sent attach names the binding it named before, and keeps its proxy.
  case dict.get(book.proxies, #(pin, binding)) {
    Ok(proxy) -> Ok(#(book, proxy))
    Error(Nil) -> {
      let book = retire_session(book, pin, session)
      let connection =
        dict.get(book.connections, pin)
        |> result.map(fn(entry) { entry.0 })
        |> option.from_result
      use proxy <- result.map(start_proxy(
        session,
        incarnation,
        binding,
        connection,
        book.logger,
      ))
      #(
        Book(
          ..book,
          proxies: dict.insert(book.proxies, #(pin, binding), proxy),
          sessions: dict.insert(book.sessions, #(pin, session), binding),
        ),
        proxy,
      )
    }
  }
}

/// Retires a session's current proxy from one orchestrator, if it has one.
fn retire_session(book: Book, pin: BitArray, session: String) -> Book {
  let current =
    dict.get(book.sessions, #(pin, session))
    |> result.try(fn(binding) {
      dict.get(book.proxies, #(pin, binding))
      |> result.map(fn(proxy) { #(binding, proxy) })
    })

  // A session's first attach has nothing to retire.
  case current {
    Ok(#(binding, proxy)) -> {
      process.send(proxy.control, Retire)
      released(book, pin, binding)
      Book(
        ..book,
        proxies: dict.delete(book.proxies, #(pin, binding)),
        sessions: dict.delete(book.sessions, #(pin, session)),
      )
    }
    Error(Nil) -> book
  }
}

/// Tells the blob keeper a binding retired, so its claims are given back.
fn released(book: Book, pin: BitArray, binding: BitArray) -> Nil {
  // An executor that takes no blobs has no claims to give back.
  case book.blobs {
    Some(service) -> blob_service.release(service, pin, binding)
    None -> Nil
  }
}

/// Starts a proxy, a weft actor linked to the book. Its owner subject is the
/// one the host is given; its control subject is the book's and the
/// connection's. A proxy that cannot start is a book that cannot serve, so it
/// fails the book's turn.
fn start_proxy(
  session: String,
  incarnation: Int,
  binding: BitArray,
  connection: Option(Subject(ConnectionMessage)),
  logger: Logger,
) -> Result(Proxy, Nil) {
  actor.new_with_initialiser(1000, fn(_subject) {
    let owner = process.new_subject()
    let control = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select_map(owner, Owner)
      |> process.select_map(control, Control)
    actor.initialised(ProxyState(
      binding:,
      connection:,
      next_id: 1,
      outstanding: dict.new(),
      logger:,
    ))
    |> actor.selecting(selector)
    |> actor.returning(Proxy(
      session:,
      incarnation:,
      owner:,
      control:,
      plane: None,
    ))
    |> Ok
  })
  |> actor.on_message(proxy)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

/// A proxy's handler.
fn proxy(
  state: ProxyState,
  event: ProxyEvent,
) -> actor.Next(ProxyState, ProxyEvent) {
  // An owner request goes out or fails at once; the connection's comings and
  // goings re-point the proxy; an answer settles one callback; `Retire` ends
  // it after failing what it holds.
  case event {
    Owner(message:) ->
      actor.continue(forwarded(state, untrusted_bridge.callback_of(message)))

    // A callback still outstanding went out on the earlier connection, whose
    // answer the link no longer sends, so it is failed now; the earlier
    // connection's `DOWN` may arrive after this, or not count.
    Control(Connected(connection:)) ->
      actor.continue(failed_all(
        ProxyState(..state, connection: Some(connection)),
      ))
    Control(Disconnected) ->
      actor.continue(failed_all(ProxyState(..state, connection: None)))
    Control(Answered(id:, body:)) -> actor.continue(settled(state, id, body))
    Control(Retire) -> {
      let _failed = failed_all(state)
      actor.stop()
    }
  }
}

/// Sends a callback on the current connection, or fails it at once when
/// there is none or the proxy is full.
fn forwarded(
  state: ProxyState,
  forward: untrusted_bridge.Forward,
) -> ProxyState {
  // A tail has no reply to fail.
  case forward, state.connection {
    untrusted_bridge.Forwarded(callback:, reply:), Some(connection) ->
      case dict.size(state.outstanding) >= max_proxy_callbacks, reply {
        True, Some(reply) -> {
          untrusted_bridge.fail_owner(reply)
          state
        }
        _, _ -> sent_callback(state, connection, callback, reply)
      }
    untrusted_bridge.Forwarded(reply: Some(reply), ..), None -> {
      untrusted_bridge.fail_owner(reply)
      state
    }
    untrusted_bridge.Forwarded(reply: None, ..), None -> state
  }
}

/// Puts one callback on the wire under the next id. A callback past either
/// frame bound is not sent: the orchestrator would refuse it by closing the
/// connection and re-send every outstanding request, so it is logged and its
/// asker is failed instead, and the id is kept for the next callback because
/// the orchestrator never sees this one.
fn sent_callback(
  state: ProxyState,
  connection: Subject(ConnectionMessage),
  callback: untrusted_wire.Callback,
  reply: Option(OwnerReply),
) -> ProxyState {
  let id = state.next_id
  let fitting =
    untrusted_codec.encode_fitting(untrusted_wire.Callback(
      binding: state.binding,
      id:,
      callback:,
    ))

  // A frame that does not fit leaves no wire state and no outstanding entry.
  case fitting {
    Error(untrusted_codec.Unfit(reason:, ..)) -> {
      log.warn(state.logger, "untrusted_gateway.callback_unfit", [
        field.text("reason", reason),
      ])
      let _failed = option.map(reply, untrusted_bridge.fail_owner)
      state
    }
    Ok(frame) -> {
      process.send(connection, Outgoing(frame))

      // A tail waits for no answer, so it holds no place.
      let outstanding = case reply {
        Some(reply) -> dict.insert(state.outstanding, id, reply)
        None -> state.outstanding
      }

      ProxyState(..state, next_id: id + 1, outstanding:)
    }
  }
}

/// An answer: decoded against the kind its callback waits for and handed to
/// the plane. One that does not decode fails the callback instead, because
/// the plane must hear something.
fn settled(state: ProxyState, id: Int, body: JsonValue) -> ProxyState {
  // An answer to a callback this proxy no longer holds is dropped.
  case dict.get(state.outstanding, id) {
    Error(Nil) -> state
    Ok(reply) -> {
      let delivered =
        untrusted_codec.decode_answer(
          untrusted_bridge.answer_kind_of(reply),
          body,
        )
        |> result.replace_error(Nil)
        |> result.try(untrusted_bridge.answer_owner(reply, _))

      // An answer that did not decode still owes the plane a reply.
      let _failed = case delivered {
        Ok(Nil) -> Nil
        Error(Nil) -> untrusted_bridge.fail_owner(reply)
      }

      ProxyState(..state, outstanding: dict.delete(state.outstanding, id))
    }
  }
}

/// Fails every outstanding callback with the owner-unavailable failure.
fn failed_all(state: ProxyState) -> ProxyState {
  dict.each(state.outstanding, fn(_id, reply) {
    untrusted_bridge.fail_owner(reply)
  })
  ProxyState(..state, outstanding: dict.new())
}
