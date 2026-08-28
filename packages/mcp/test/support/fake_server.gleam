//// An in-process fake MCP server for the client actor's deterministic
//// tests. It plugs into the client through the real `ChannelTransport`
//// seam, so the actor runs its production path — framing, decoding,
//// correlation, the death latch — minus any OS process.
////
//// The fake is a scripted actor: every line the client writes is decoded
//// with `mcp/jsonrpc` (a client request decodes as a `ServerRequest`, a
//// client notification as a `Notification`, and the client's own
//// method-not-found answer as a `Response`) and handed to the test's
//// script, which threads its own state and answers with `Action`s —
//// framed replies, raw bytes, or a transport close. Every line the
//// client ever wrote is recorded for assertions (`seen`), and a test can
//// also `inject` unsolicited actions from outside the script.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import mcp/jsonrpc.{type Inbound}
import mcp/stdio
import mcp/transport

/// One thing the fake does in response to a client line (or an
/// injection), delivered to the client in list order.
pub type Action {
  /// Frame `message` with `stdio.frame` and deliver it as inbound bytes.
  Reply(message: JsonValue)
  /// Deliver arbitrary bytes verbatim — malformed lines, oversized
  /// lines, split chunks.
  Raw(bytes: BitArray)
  /// Close the transport with this reason.
  Close(reason: String)
}

/// A handle on one started fake, generic over the script's own state.
pub opaque type Fake(state) {
  Fake(subject: Subject(Msg(state)))
}

type Msg(state) {
  Connected(inbound: Subject(transport.TransportEvent))
  FromClient(line: String)
  ClientClosed
  Inject(actions: List(Action))
  Seen(reply: Subject(List(String)))
}

type State(state) {
  State(
    script: fn(state, Inbound) -> #(state, List(Action)),
    script_state: state,
    inbound: Option(Subject(transport.TransportEvent)),
    // Newest first; `seen` reverses.
    lines: List(String),
  )
}

/// Starts a fake speaking `script`, threaded from `initial`.
pub fn start(
  initial: state,
  script: fn(state, Inbound) -> #(state, List(Action)),
) -> Fake(state) {
  let assert Ok(started) =
    actor.new(State(script:, script_state: initial, inbound: None, lines: []))
    |> actor.on_message(handle)
    |> actor.start
    as "the fake mcp server failed to start"
  Fake(subject: started.data)
}

/// The transport to hand `client.start`: connects the fake to the
/// client's inbound subject and routes every outbound line back here.
pub fn seam(fake: Fake(state)) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) {
    process.send(fake.subject, Connected(inbound:))
    transport.Connection(
      send: fn(line) {
        process.send(fake.subject, FromClient(line:))
        Ok(Nil)
      },
      close: fn() { process.send(fake.subject, ClientClosed) },
    )
  })
}

/// Delivers actions to the client outside the script — unsolicited
/// notifications, garbage, a close.
pub fn inject(fake: Fake(state), actions: List(Action)) -> Nil {
  process.send(fake.subject, Inject(actions:))
}

/// Every line the client has written, oldest first, trailing newline
/// trimmed.
pub fn seen(fake: Fake(state)) -> List(String) {
  process.call(fake.subject, waiting: 5000, sending: Seen)
}

fn handle(state: State(s), msg: Msg(s)) -> actor.Next(State(s), Msg(s)) {
  case msg {
    Connected(inbound:) ->
      actor.continue(State(..state, inbound: Some(inbound)))
    FromClient(line:) -> {
      let line = trim_newline(line)
      let state = State(..state, lines: [line, ..state.lines])
      let assert Ok(decoded) = jsonrpc.decode(line)
        as "the client sent a line its own codec cannot decode"
      let #(script_state, actions) = state.script(state.script_state, decoded)
      deliver(state.inbound, actions)
      actor.continue(State(..state, script_state:))
    }
    ClientClosed -> actor.continue(state)
    Inject(actions:) -> {
      deliver(state.inbound, actions)
      actor.continue(state)
    }
    Seen(reply:) -> {
      process.send(reply, list.reverse(state.lines))
      actor.continue(state)
    }
  }
}

fn deliver(
  inbound: Option(Subject(transport.TransportEvent)),
  actions: List(Action),
) -> Nil {
  case inbound {
    None -> Nil
    Some(subject) ->
      list.each(actions, fn(action) {
        case action {
          Reply(message:) ->
            process.send(
              subject,
              transport.TransportData(
                bytes: bit_array.from_string(stdio.frame(message)),
              ),
            )
          Raw(bytes:) -> process.send(subject, transport.TransportData(bytes:))
          Close(reason:) ->
            process.send(subject, transport.TransportClosed(reason:))
        }
      })
  }
}

fn trim_newline(line: String) -> String {
  case string.ends_with(line, "\n") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}
