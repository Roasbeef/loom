//// A compact in-process language server for the manager's tests.
////
//// It plugs into `lsp/client` through the real `mcp/transport`
//// `ChannelTransport` seam, so the client runs its production path —
//// framing, JSON-RPC correlation, capability gating, settlement — with no
//// process outside the VM. `packages/lsp` has a richer fake of its own, but
//// test support does not cross package boundaries, and the manager needs
//// only this much: an `initialize` answered with chosen capabilities, every
//// other request answered by a script over its method and params, a log of
//// what the client sent, and a way to die.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import lsp/framing
import mcp/jsonrpc
import mcp/transport

/// How the script answers one request.
pub type Answer {
  /// A successful result.
  Answer(result: JsonValue)

  /// A JSON-RPC error in the server's own words.
  Refuse(message: String)
}

/// One thing the client sent, oldest first.
pub type Seen {
  /// A request or notification, by method, with its params.
  Sent(method: String, params: Option(JsonValue))

  /// The client closed the transport.
  Closed
}

/// A handle on one started fake.
pub opaque type Fake {
  Fake(subject: Subject(Msg))
}

type Msg {
  Connected(inbound: Subject(transport.TransportEvent))
  FromClient(frame: String)
  ClientClosed
  Die(reason: String)
  Log(reply: Subject(List(Seen)))
}

type State {
  State(
    capabilities: JsonValue,
    script: fn(String, Option(JsonValue)) -> Answer,
    inbound: Option(Subject(transport.TransportEvent)),
    buffer: framing.Buffer,
    log: List(Seen),
  )
}

/// Starts a fake that advertises `capabilities` and answers every request
/// but the lifecycle ones with `script`.
pub fn start(
  capabilities: JsonValue,
  script: fn(String, Option(JsonValue)) -> Answer,
) -> Fake {
  let assert Ok(started) =
    actor.new(
      State(
        capabilities:,
        script:,
        inbound: None,
        buffer: framing.new(),
        log: [],
      ),
    )
    |> actor.on_message(handle)
    |> actor.start
    as "the fake language server must start"
  Fake(subject: started.data)
}

/// The transport `lsp/client.start` is handed.
pub fn seam(fake: Fake) -> transport.Transport {
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

/// Everything the client sent, oldest first.
pub fn seen(fake: Fake) -> List(Seen) {
  process.call(fake.subject, waiting: 5000, sending: Log)
}

/// The methods the client sent, in order, `<close>` where it closed.
pub fn methods(fake: Fake) -> List(String) {
  list.map(seen(fake), fn(entry) {
    case entry {
      Sent(method:, params: _) -> method
      Closed -> "<close>"
    }
  })
}

/// The server dies: its transport reports closed.
pub fn die(fake: Fake, reason: String) -> Nil {
  process.send(fake.subject, Die(reason:))
}

/// Capabilities advertising every request the manager sends, with
/// full-text sync.
pub fn everything() -> JsonValue {
  json.Object([
    #("definitionProvider", json.Bool(True)),
    #("referencesProvider", json.Bool(True)),
    #("hoverProvider", json.Bool(True)),
    #("documentSymbolProvider", json.Bool(True)),
    #("renameProvider", json.Bool(True)),
    #("textDocumentSync", json.Int(1)),
  ])
}

/// A `Location` at one zero-based position.
pub fn location(uri: String, line: Int, character: Int) -> JsonValue {
  let at =
    json.Object([
      #("line", json.Int(line)),
      #("character", json.Int(character)),
    ])
  json.Object([
    #("uri", json.String(uri)),
    #("range", json.Object([#("start", at), #("end", at)])),
  ])
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connected(inbound:) ->
      actor.continue(State(..state, inbound: Some(inbound)))
    FromClient(frame:) -> actor.continue(from_client(state, frame))
    ClientClosed -> {
      deliver(state, transport.TransportClosed(reason: "fake stdin closed"))
      actor.continue(State(..state, log: [Closed, ..state.log]))
    }
    Die(reason:) -> {
      deliver(state, transport.TransportClosed(reason:))
      actor.continue(state)
    }
    Log(reply:) -> {
      process.send(reply, list.reverse(state.log))
      actor.continue(state)
    }
  }
}

fn from_client(state: State, frame: String) -> State {
  let assert Ok(#(buffer, bodies)) =
    framing.push(state.buffer, bit_array.from_string(frame))
    as "the client wrote a frame its own framer refuses"
  list.fold(bodies, State(..state, buffer:), fn(state, body) {
    let assert Ok(decoded) = jsonrpc.decode(body)
      as "the client wrote a body its own codec cannot decode"
    case decoded {
      jsonrpc.ServerRequest(id:, method:, params:) -> {
        answer(state, id, method, params)
        State(..state, log: [Sent(method:, params:), ..state.log])
      }
      jsonrpc.Notification(method:, params:) ->
        State(..state, log: [Sent(method:, params:), ..state.log])
      jsonrpc.Response(..) -> state
    }
  })
}

fn answer(
  state: State,
  id: jsonrpc.Id,
  method: String,
  params: Option(JsonValue),
) -> Nil {
  let reply = case method {
    "initialize" ->
      jsonrpc.response(id, json.Object([#("capabilities", state.capabilities)]))
    "shutdown" -> jsonrpc.response(id, json.Null)
    _ ->
      case state.script(method, params) {
        Answer(result:) -> jsonrpc.response(id, result)
        Refuse(message:) ->
          jsonrpc.error_response(
            id,
            jsonrpc.RpcError(code: -32_803, message:, data: None),
          )
      }
  }
  deliver(
    state,
    transport.TransportData(bytes: bit_array.from_string(framing.frame(reply))),
  )
}

fn deliver(state: State, event: transport.TransportEvent) -> Nil {
  case state.inbound {
    Some(inbound) -> process.send(inbound, event)
    None -> Nil
  }
}
