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
////   proxies by the pin the handshake admitted.
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

import broker/internal/call
import client/internal/ffi_tls_stream.{type Stream}
import client/remote/address.{type Address}
import client/remote/protocol.{type HostMessage, type OwnerMessage}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_bridge.{type OwnerReply}
import client/remote/untrusted_codec
import client/remote/untrusted_wire.{type Request, type Response}
import core/corruption
import core/json.{type JsonValue}
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
    /// Where connections, refusals and violations are logged.
    logger: Logger,
  )
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
    binding: BitArray,
    reply: Subject(Result(Subject(OwnerMessage), Nil)),
  )

  /// The proxy control subject for `binding`, if the orchestrator holds one.
  ProxyOf(
    pin: BitArray,
    binding: BitArray,
    reply: Subject(Result(Subject(ProxyMessage), Nil)),
  )

  /// A connection went down.
  ConnectionDown(down: process.Down)
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
    /// The waiters of requests not yet answered, by request id.
    waiters: Dict(Int, Pid),
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
  )
}

/// One proxy, as the book holds it.
type Proxy {
  Proxy(
    /// The subject the host is given as the owner port.
    owner: Subject(OwnerMessage),
    /// The proxy's control subject.
    control: Subject(ProxyMessage),
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
  use book <- result.try(start_book())
  let acceptor =
    process.spawn(fn() { accepting(listener, book, config.host, config.logger) })
  Ok(Gateway(port:, acceptor:))
}

/// Accepts connections for as long as the listener is open, handing each to
/// a connection process of its own.
fn accepting(
  listener: ffi_tls_stream.Listener,
  book: Subject(BookMessage),
  host: Address(HostMessage(RemoteCensus)),
  logger: Logger,
) -> Nil {
  // A timeout only means nobody connected; a closed listener ends the loop.
  case ffi_tls_stream.accept(listener, accept_ms) {
    Ok(raw) -> {
      handed(raw, book, host, logger)
      accepting(listener, book, host, logger)
    }
    Error(ffi_tls_stream.TimedOut)
    | Error(ffi_tls_stream.Refused)
    | Error(ffi_tls_stream.Unavailable) ->
      accepting(listener, book, host, logger)
    Error(ffi_tls_stream.Closed) | Error(ffi_tls_stream.InvalidConfiguration) ->
      Nil
  }
}

/// Starts a connection for an accepted socket and gives the socket to it. A
/// connection that cannot start, or cannot take the socket, closes it.
fn handed(
  raw: Stream,
  book: Subject(BookMessage),
  host: Address(HostMessage(RemoteCensus)),
  logger: Logger,
) -> Nil {
  let started =
    connection(raw, book, host, logger)
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
  book: Subject(BookMessage),
  host: Address(HostMessage(RemoteCensus)),
  logger: Logger,
) -> Result(sm.Started(Subject(ConnectionMessage)), Nil) {
  sm.new_with_initialiser(1000, fn(subject) {
    let data =
      Connection(subject:, raw:, book:, host:, waiters: dict.new(), logger:)
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
    _, Replied(id:, ..) ->
      sm.keep(Connection(..data, waiters: dict.delete(data.waiters, id)))
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
        | Ok(untrusted_codec.CallbackEnvelope(..)) ->
          closed(
            stream,
            data,
            "an orchestrator sent a frame only an executor sends",
          )
        Error(report) -> closed(stream, data, corruption.describe(report))
      }
    ffi_tls_stream.Ended | ffi_tls_stream.Broken -> sm.stop()
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
    Ok(#(request, port)) -> armed(stream, waiting(data, id, request, port))
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
    untrusted_wire.AttachRequest(session:, binding:, ..) ->
      call.try_call(data.book, waiting: book_ms, sending: ProxyFor(
        pin:,
        session:,
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

/// Starts the waiter for one request. An ack is sent from here, because it
/// has no answer to wait for.
fn waiting(
  data: Connection,
  id: Int,
  request: Request,
  port: Option(Subject(OwnerMessage)),
) -> Connection {
  let host = data.host
  let connection = data.subject
  let carrier = process.self()

  // The waiter is unlinked on purpose: the host reads its death as an abort,
  // so it must not die with this connection for any other reason. When the
  // connection dies first, the waiter leaves with `noconnection`, which the
  // host reads as a partition (`untrusted_bridge.ask_host`). A weft run would
  // tie it to a scope this connection owns and kill it with another reason.
  case request {
    untrusted_wire.AckRequest(..) -> {
      let _none = untrusted_bridge.ask_host(host, request, port, carrier)
      data
    }
    _other -> {
      let waiter =
        process.spawn_unlinked(fn() {
          let response = untrusted_bridge.ask_host(host, request, port, carrier)
          process.send(connection, Replied(id:, response:))
        })
      Connection(..data, waiters: dict.insert(data.waiters, id, waiter))
    }
  }
}

/// Cancels request `id` by killing its waiter, which the host reads as the
/// asker dying and so as an abort.
fn cancelled(data: Connection, id: Int) -> Connection {
  // A request already answered has no waiter left to kill.
  case dict.get(data.waiters, id) {
    Ok(waiter) -> {
      process.kill(waiter)
      Connection(..data, waiters: dict.delete(data.waiters, id))
    }
    Error(Nil) -> data
  }
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

/// A waiter's answer, sent as the response to its request.
fn replied(
  stream: Stream,
  data: Connection,
  id: Int,
  response: Option(Response),
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  let data = Connection(..data, waiters: dict.delete(data.waiters, id))

  // An ack's waiter never replies; every other request has a response.
  case response {
    Some(response) ->
      outgoing(
        stream,
        data,
        untrusted_codec.encode_frame(untrusted_wire.Response(id:, response:)),
      )
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

/// Logs why, closes the socket and stops. The waiters run on.
fn closed(
  stream: Stream,
  data: Connection,
  reason: String,
) -> sm.Next(Phase, Connection, ConnectionMessage) {
  log.warn(data.logger, "untrusted_gateway.closed", [
    field.text("reason", reason),
  ])
  ffi_tls_stream.close(stream)
  sm.stop()
}

/// Starts the book, linked to the caller.
fn start_book() -> Result(Subject(BookMessage), String) {
  actor.new_with_initialiser(1000, fn(subject) {
    let book =
      Book(
        subject:,
        connections: dict.new(),
        proxies: dict.new(),
        sessions: dict.new(),
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
    ProxyFor(pin:, session:, binding:, reply:) ->
      case proxy_for(book, pin, session, binding) {
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
    ConnectionDown(down:) -> actor.continue(departed(book, down))
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
      use proxy <- result.map(start_proxy(binding, connection))
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
      Book(..book, proxies: dict.delete(book.proxies, #(pin, binding)))
    }
    Error(Nil) -> book
  }
}

/// Starts a proxy, a weft actor linked to the book. Its owner subject is the
/// one the host is given; its control subject is the book's and the
/// connection's. A proxy that cannot start is a book that cannot serve, so it
/// fails the book's turn.
fn start_proxy(
  binding: BitArray,
  connection: Option(Subject(ConnectionMessage)),
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
    ))
    |> actor.selecting(selector)
    |> actor.returning(Proxy(owner:, control:))
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
  // A tail has no reply to fail; a declined message was answered already.
  case forward, state.connection {
    untrusted_bridge.Declined, _ -> state
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

/// Puts one callback on the wire under the next id.
fn sent_callback(
  state: ProxyState,
  connection: Subject(ConnectionMessage),
  callback: untrusted_wire.Callback,
  reply: Option(OwnerReply),
) -> ProxyState {
  let id = state.next_id
  let frame =
    untrusted_codec.encode_frame(untrusted_wire.Callback(
      binding: state.binding,
      id:,
      callback:,
    ))
  process.send(connection, Outgoing(frame))

  // A tail waits for no answer, so it holds no place.
  let outstanding = case reply {
    Some(reply) -> dict.insert(state.outstanding, id, reply)
    None -> state.outstanding
  }

  ProxyState(..state, next_id: id + 1, outstanding:)
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
