//// An in-process fake language server for `lsp/client`'s tests. It plugs
//// into the client through the real `mcp/transport.ChannelTransport`
//// seam, so the actor runs its production path — `Content-Length`
//// framing, JSON-RPC decoding, correlation, the death latch — with no OS
//// process anywhere.
////
//// The fake is a scripted actor. Every frame the client writes is
//// unframed with `lsp/framing`, decoded with `mcp/jsonrpc` (a client
//// request decodes as a `ServerRequest`, a notification as a
//// `Notification`, and the client's answer to a server request as a
//// `Response`), logged, and handed to the test's script, which threads
//// its own state and answers with `Action`s. `start` answers `initialize`
//// itself with configurable capabilities and swallows `initialized`, so a
//// script sees only what the test is about; `start_raw` hands the script
//// everything. A test can also `inject` actions from outside the script:
//// a server request, a publication, garbage, a close.
////
//// Going silent is a script that answers nothing. Dying is `Close`.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import lsp/framing
import mcp/jsonrpc.{type Id, type Inbound}
import mcp/transport
import weft/poll

/// One thing the fake does, delivered to the client in list order.
pub type Action {
  /// Frame `message` and deliver it as one inbound chunk.
  Reply(message: JsonValue)

  /// Deliver arbitrary bytes verbatim: garbage, split frames.
  Raw(bytes: BitArray)

  /// Deliver `actions` after `ms` milliseconds, from a timer, so they
  /// arrive behind anything the client handles in the meantime.
  Later(ms: Int, actions: List(Action))

  /// Close the transport with this reason: the server died.
  Close(reason: String)
}

/// One entry of the fake's log, oldest first.
pub type Seen {
  /// A message the client wrote.
  Got(message: Inbound)

  /// The client closed its connection.
  GotClose
}

/// A handle on one started fake.
pub opaque type Fake(state) {
  Fake(subject: Subject(Msg(state)))
}

type Msg(state) {
  Connected(inbound: Subject(transport.TransportEvent))
  FromClient(frame: String)
  ClientClosed
  Inject(actions: List(Action))
  Log(reply: Subject(List(Seen)))
}

type State(state) {
  State(
    script: fn(state, Inbound) -> #(state, List(Action)),
    script_state: state,
    inbound: Option(Subject(transport.TransportEvent)),
    buffer: framing.Buffer,
    self: Subject(Msg(state)),
    // Newest first; `seen` reverses.
    log: List(Seen),
  )
}

/// Starts a fake that answers `initialize` with `capabilities` (the
/// value of the result's `capabilities` field) and swallows
/// `initialized`; every other message goes to `script`.
pub fn start(
  capabilities: JsonValue,
  initial: state,
  script: fn(state, Inbound) -> #(state, List(Action)),
) -> Fake(state) {
  start_raw(initial, fn(state, inbound) {
    case inbound {
      jsonrpc.ServerRequest(id:, method: "initialize", ..) -> #(state, [
        Reply(response(
          id,
          json.Object([
            #("capabilities", capabilities),
            #("serverInfo", json.Object([#("name", json.String("fake"))])),
          ]),
        )),
      ])
      jsonrpc.Notification(method: "initialized", ..) -> #(state, [])
      other -> script(state, other)
    }
  })
}

/// Starts a fake whose script sees every message, `initialize` included.
pub fn start_raw(
  initial: state,
  script: fn(state, Inbound) -> #(state, List(Action)),
) -> Fake(state) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      State(
        script:,
        script_state: initial,
        inbound: None,
        buffer: framing.new(),
        self:,
        log: [],
      )
      |> actor.initialised
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
    as "the fake language server failed to start"
  Fake(subject: started.data)
}

/// The transport to hand `client.start`: connects the fake to the
/// client's inbound subject and routes every outbound frame here.
pub fn seam(fake: Fake(state)) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) {
    process.send(fake.subject, Connected(inbound:))
    transport.Connection(
      send: fn(frame) {
        process.send(fake.subject, FromClient(frame:))
        Ok(Nil)
      },
      close: fn() { process.send(fake.subject, ClientClosed) },
    )
  })
}

/// Delivers actions to the client outside the script.
pub fn inject(fake: Fake(state), actions: List(Action)) -> Nil {
  process.send(fake.subject, Inject(actions:))
}

/// Everything the client has written, and its close, oldest first.
pub fn seen(fake: Fake(state)) -> List(Seen) {
  process.call(fake.subject, waiting: 5000, sending: Log)
}

/// The methods of every request and notification the client wrote, in
/// order, with `"<close>"` where it closed the connection.
pub fn methods(fake: Fake(state)) -> List(String) {
  list.filter_map(seen(fake), fn(entry) {
    case entry {
      Got(jsonrpc.ServerRequest(method:, ..)) -> Ok(method)
      Got(jsonrpc.Notification(method:, ..)) -> Ok(method)
      Got(jsonrpc.Response(..)) -> Error(Nil)
      GotClose -> Ok("<close>")
    }
  })
}

/// Waits up to two seconds for the log to satisfy `ready`, answering the
/// log as it stood when it did. The client's writes arrive
/// asynchronously, so a test that asserts on them waits for them rather
/// than sleeping a guess.
pub fn await(
  fake: Fake(state),
  ready: fn(List(Seen)) -> Bool,
) -> Result(List(Seen), Nil) {
  let outcome =
    poll.until(within: 2000, every: 2, attempt: fn() {
      let log = seen(fake)
      case ready(log) {
        True -> poll.Done(log)
        False -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(value:) -> Ok(value)
    poll.Failed(error: Nil) | poll.Expired -> Error(Nil)
  }
}

/// Waits for the client to have written a message with `method`.
pub fn await_method(fake: Fake(state), method: String) -> Result(Nil, Nil) {
  let found = await(fake, fn(_) { list.contains(methods(fake), method) })
  case found {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(Nil)
  }
}

/// A successful JSON-RPC response.
pub fn response(id: Id, result: JsonValue) -> JsonValue {
  jsonrpc.response(id, result)
}

/// A JSON-RPC error response, in the server's own words.
pub fn error_response(id: Id, code: Int, message: String) -> JsonValue {
  jsonrpc.error_response(id, jsonrpc.RpcError(code:, message:, data: None))
}

/// A `textDocument/publishDiagnostics` notification carrying one error
/// per message, each on line 0.
pub fn publish(
  uri: String,
  version: Option(Int),
  messages: List(String),
) -> JsonValue {
  let position =
    json.Object([#("line", json.Int(0)), #("character", json.Int(0))])
  let diagnostics =
    list.map(messages, fn(message) {
      json.Object([
        #("range", json.Object([#("start", position), #("end", position)])),
        #("severity", json.Int(1)),
        #("message", json.String(message)),
      ])
    })
  let fields = [
    #("uri", json.String(uri)),
    #("diagnostics", json.Array(diagnostics)),
  ]
  let fields = case version {
    Some(version) -> [#("version", json.Int(version)), ..fields]
    None -> fields
  }
  jsonrpc.notification(
    "textDocument/publishDiagnostics",
    Some(json.Object(fields)),
  )
}

/// A request from the server to the client.
pub fn server_request(
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> JsonValue {
  jsonrpc.request(id, method, params)
}

fn handle(state: State(s), msg: Msg(s)) -> actor.Next(State(s), Msg(s)) {
  case msg {
    Connected(inbound:) ->
      actor.continue(State(..state, inbound: Some(inbound)))
    FromClient(frame:) -> actor.continue(from_client(state, frame))

    // The fake's close is immediate, so its witness follows at once.
    ClientClosed -> {
      deliver(state, [Close("the fake server's stdin closed")])
      actor.continue(State(..state, log: [GotClose, ..state.log]))
    }

    Inject(actions:) -> {
      deliver(state, actions)
      actor.continue(state)
    }
    Log(reply:) -> {
      process.send(reply, list.reverse(state.log))
      actor.continue(state)
    }
  }
}

// One frame from the client. The client writes whole frames, but they
// pass through the real framer anyway, so the fake reads exactly what a
// server would.
fn from_client(state: State(s), frame: String) -> State(s) {
  let assert Ok(#(buffer, bodies)) =
    framing.push(state.buffer, bit_array.from_string(frame))
    as "the client wrote a frame its own framer refuses"
  list.fold(bodies, State(..state, buffer:), fn(state, body) {
    let assert Ok(decoded) = jsonrpc.decode(body)
      as "the client wrote a body its own codec cannot decode"
    let state = State(..state, log: [Got(decoded), ..state.log])
    let #(script_state, actions) = state.script(state.script_state, decoded)
    deliver(state, actions)
    State(..state, script_state:)
  })
}

fn deliver(state: State(s), actions: List(Action)) -> Nil {
  case state.inbound {
    None -> Nil
    Some(inbound) -> list.each(actions, deliver_one(state.self, inbound, _))
  }
}

fn deliver_one(
  self: Subject(Msg(s)),
  inbound: Subject(transport.TransportEvent),
  action: Action,
) -> Nil {
  case action {
    Reply(message:) ->
      process.send(
        inbound,
        transport.TransportData(
          bytes: bit_array.from_string(framing.frame(message)),
        ),
      )
    Raw(bytes:) -> process.send(inbound, transport.TransportData(bytes:))
    Later(ms:, actions:) -> {
      let _ = process.send_after(self, ms, Inject(actions:))
      Nil
    }
    Close(reason:) -> process.send(inbound, transport.TransportClosed(reason:))
  }
}
