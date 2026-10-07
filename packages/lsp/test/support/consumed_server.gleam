//// Bounded deterministic consumed peer for the real client actor tests.
//// No helper or native retirement is claimed by this in-process fixture.

import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lsp/framing
import lsp/internal/consumed_channel as consumed
import lsp/jsonrpc
import lsp/transport
import weft
import weft/actor
import weft/poll

pub type InputMode {
  Flowing
  Blocked
}

pub opaque type Peer {
  Peer(subject: Subject(Msg))
}

type Msg {
  Attach(consumed.Sink, Subject(Nil))
  Feed(BitArray, Subject(Result(Nil, Nil)))
  Close
  Mode(InputMode, Subject(Nil))
  Inspect(Subject(#(Option(consumed.Sink), List(Int), List(String))))
  Ready(Subject(Bool))
  OutputDone(weft.Pulled(Nil, String))
}

type State {
  State(
    sink: Option(consumed.Sink),
    buffer: framing.Buffer,
    mode: InputMode,
    held: Option(Subject(Result(Nil, Nil))),
    sizes: List(Int),
    methods: List(String),
    output: Subject(weft.Pulled(Nil, String)),
    automatic: Int,
  )
}

pub fn start() -> Peer {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      let reports = process.new_subject()
      actor.initialised(State(
        None,
        framing.new(),
        Flowing,
        None,
        [],
        [],
        reports,
        0,
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_map(reports, OutputDone),
      )
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
    as "The fixture starts a bounded local peer."
  Peer(started.data)
}

pub fn seam(peer: Peer) -> transport.Transport {
  transport.ConsumedChannelTransport(fn(sink) {
    process.call(peer.subject, 1000, Attach(sink, _))
    Ok(
      consumed.Session(
        feed: fn(bytes) {
          let reply = process.new_subject()
          process.send(peer.subject, Feed(bytes, reply))
          process.receive_forever(reply)
        },
        close: fn() { process.send(peer.subject, Close) },
      ),
    )
  })
}

pub fn mode(peer: Peer, mode: InputMode) -> Nil {
  process.call(peer.subject, 1000, Mode(mode, _))
}

pub fn inspect(
  peer: Peer,
) -> #(Option(consumed.Sink), List(Int), List(String)) {
  process.call(peer.subject, 1000, Inspect)
}

pub fn emit(peer: Peer, message: json.JsonValue) -> Result(Nil, String) {
  raw(peer, bit_array.from_string(framing.frame(message)))
}

pub fn raw(peer: Peer, bytes: BitArray) -> Result(Nil, String) {
  await_automatic(peer)
  let assert Some(sink) = inspect(peer).0 as "The original peer is attached."
  publish(sink, bytes)
}

pub fn stderr(peer: Peer, bytes: BitArray) -> Result(Nil, String) {
  await_automatic(peer)
  let assert Some(sink) = inspect(peer).0 as "The original peer is attached."
  consumed.publish(sink, consumed.Stderr, bytes, consumed.Intact)
}

pub fn truncate(peer: Peer) -> Result(Nil, String) {
  await_automatic(peer)
  let assert Some(sink) = inspect(peer).0 as "The original peer is attached."
  consumed.publish(sink, consumed.Stdout, <<>>, consumed.Truncated)
}

pub fn shutdown(peer: Peer) -> Nil {
  process.send(peer.subject, Close)
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Attach(sink, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, sink: Some(sink)))
    }
    Ready(reply) -> {
      process.send(reply, state.automatic == 0)
      actor.continue(state)
    }
    Mode(mode, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, mode: mode))
    }
    Inspect(reply) -> {
      process.send(reply, #(
        state.sink,
        list.reverse(state.sizes),
        list.reverse(state.methods),
      ))
      actor.continue(state)
    }
    Feed(bytes, reply) -> {
      let state =
        State(..state, sizes: [bit_array.byte_size(bytes), ..state.sizes])
      case state.mode {
        Blocked -> actor.continue(State(..state, held: Some(reply)))
        Flowing -> {
          let assert Ok(#(buffer, bodies)) = framing.push(state.buffer, bytes)
            as "The client sends bounded well-framed protocol bytes."
          let state = list.fold(bodies, State(..state, buffer:), answer)
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
      }
    }
    Close -> {
      case state.held {
        Some(reply) -> process.send(reply, Error(Nil))
        None -> Nil
      }
      case state.sink {
        Some(sink) ->
          consumed.closed(sink, "the original fixture attachment closed")
        None -> Nil
      }
      actor.stop()
    }
    OutputDone(weft.AllDelivered) ->
      actor.continue(State(..state, automatic: state.automatic - 1))
    OutputDone(_) -> actor.continue(state)
  }
}

fn answer(state: State, body: String) -> State {
  let assert Ok(message) = jsonrpc.decode(body)
    as "Fixture input is actual JSON-RPC from the production client actor."
  case message {
    jsonrpc.ServerRequest(id, "initialize", _) -> {
      let caps =
        json.Object([
          #("definitionProvider", json.Bool(True)),
          #("hoverProvider", json.Bool(True)),
          #("documentSymbolProvider", json.Bool(True)),
          #("textDocumentSync", json.Int(2)),
        ])
      emit_auto(
        State(..state, methods: ["initialize", ..state.methods]),
        jsonrpc.response(id, json.Object([#("capabilities", caps)])),
      )
    }
    jsonrpc.ServerRequest(id, "shutdown", _) -> {
      emit_auto(
        State(..state, methods: ["shutdown", ..state.methods]),
        jsonrpc.response(id, json.Null),
      )
    }
    jsonrpc.ServerRequest(_, method, _) | jsonrpc.Notification(method, _) ->
      State(..state, methods: [method, ..state.methods])
    jsonrpc.Response(_, _) -> state
  }
}

fn emit_auto(state: State, message: json.JsonValue) -> State {
  let assert Some(sink) = state.sink
    as "Automatic replies retain the original sink."
  let bytes = bit_array.from_string(framing.frame(message))
  let _ =
    weft.new_prepared([weft.managed(fn(_) { publish(sink, bytes) })])
    |> weft.deadline(35_000)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: state.output)
  State(..state, automatic: state.automatic + 1)
}

fn publish(sink: consumed.Sink, bytes: BitArray) -> Result(Nil, String) {
  case bytes {
    <<>> -> Ok(Nil)
    bytes -> {
      let size = int.min(bit_array.byte_size(bytes), 32_768)
      let assert Ok(chunk) = bit_array.slice(bytes, 0, size)
        as "Every fixture output slice is within the original array."
      let assert Ok(rest) =
        bit_array.slice(bytes, size, bit_array.byte_size(bytes) - size)
        as "The remaining fixture stream keeps its exact bytes."
      use Nil <- result.try(consumed.publish(
        sink,
        consumed.Stdout,
        chunk,
        consumed.Intact,
      ))
      publish(sink, rest)
    }
  }
}

fn await_automatic(peer: Peer) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(2000, 1, fn() {
      case process.call(peer.subject, 1000, Ready) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "One physical producer waits for its original automatic response to drain."
  Nil
}
