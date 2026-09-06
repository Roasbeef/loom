//// A two-connection provider: the first response remains unfinished until
//// its client closes; the explicitly recovered request receives a final answer.
//// One managed process owns the listener and both accepted sockets. Its death
//// closes them even when the concurrent fixture body fails an assertion.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws as socket
import support/provider_http
import weft
import weft/actor
import weft/poll

/// Original connection termination, never inferred from elapsed time.
pub type Closure {
  /// The native client actually closed its accepted connection.
  ClientClosed

  /// The finite test hold expired without a peer close.
  HoldExpired
}

/// Classifies the actual passive receive without promoting timeout to closure.
///
/// ## Examples
///
/// `classify_closure(Error(atom.to_dynamic(atom.create("closed"))))`.
pub fn classify_closure(
  received: Result(BitArray, Dynamic),
) -> Result(Closure, String) {
  case received {
    Ok(_) -> Error("unexpected bytes on held connection")
    Error(reason) ->
      case
        reason == atom.to_dynamic(atom.create("closed")),
        reason == atom.to_dynamic(atom.create("timeout"))
      {
        True, _ -> Ok(ClientClosed)
        False, True -> Ok(HoldExpired)
        False, False -> Error("unexpected held socket failure")
      }
  }
}

type Outcome(a) {
  PeerFinished
  BodyFinished(a)
}

type State {
  State(port: Int, requests: Int, closed: Option(Closure))
}

type Message {
  Update(State)
  Read(process.Subject(State))
}

/// Cross-process observation through the actor's own reply protocol.
pub opaque type Witness {
  Witness(process.Subject(Message))
}

/// Returns the observed request count and original connection's closure.
/// This actor snapshot detects evidence already recorded at the boundary;
/// it does not linearize the caller's next command with another sender.
///
/// ## Examples
///
/// `snapshot(witness) == #(1, None)`.
pub fn snapshot(witness: Witness) -> #(Int, Option(Closure)) {
  let state = read(witness)
  #(state.requests, state.closed)
}

/// Waits for the actual complete request and streamed startup.
///
/// ## Examples
///
/// `await_started(witness)`.
pub fn await_started(witness: Witness) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 10, attempt: fn() {
      case read(witness).requests > 0 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the original A request reaches its held provider"
  Nil
}

/// Requires exact client closure, retaining timeout as a distinct failure.
///
/// ## Examples
///
/// `await_closed(witness)`.
pub fn await_closed(witness: Witness) -> Nil {
  let assert poll.Answered(ClientClosed) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case read(witness).closed {
        Some(ending) -> poll.Done(ending)
        None -> poll.Retry
      }
    })
    as "the original provider socket actually closes"
  Nil
}

fn read(witness: Witness) -> State {
  let Witness(subject) = witness
  actor.call(subject, 1000, Read)
}

/// Runs the body beside one finite provider, retaining both completed outcomes.
///
/// ## Examples
///
/// `with_server(fn(url, witness) { exercise(url, witness) })`.
pub fn with_server(run: fn(String, Witness) -> a) -> a {
  let assert Ok(book) =
    actor.new(State(0, 0, None))
    |> actor.on_message(fn(state, message) {
      case message {
        Update(next) -> actor.continue(next)
        Read(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
    as "the observation actor owns all reply routing"
  let watch = process.monitor(book.pid)
  let witness = Witness(book.data)

  // The socket owner and native body share observations through the actor,
  // never by receiving on a Subject created in another process.
  let outcomes =
    weft.new([
      fn() {
        serve(book.data)
        Ok(PeerFinished)
      },
      fn() {
        let assert poll.Answered(port) =
          poll.until(within: 5000, every: 10, attempt: fn() {
            let state = read(witness)
            case state.port > 0 {
              True -> poll.Done(state.port)
              False -> poll.Retry
            }
          })
          as "the original listener publishes its actual ephemeral port"
        Ok(
          BodyFinished(run("http://127.0.0.1:" <> int.to_string(port), witness)),
        )
      },
    ])
    |> weft.deadline(110_000)
    |> weft.start

  // Retain the original actor witness through both outcomes, including a
  // failed body or peer, before closing the fixture's observation boundary.
  process.unlink(book.pid)
  process.kill(book.pid)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "the original observation actor retires after both tasks"
  let assert [
    weft.Completed(0, PeerFinished),
    weft.Completed(1, BodyFinished(value)),
  ] = outcomes
    as "both original socket owner and bounded native body complete"
  value
}

fn serve(book: process.Subject(Message)) -> Nil {
  let assert Ok(listener) =
    socket.tcp_listen(0, [socket.Binary, socket.Active(False)])
    as "the managed provider owns its listener"
  let assert Ok(port) = socket.tcp_port(listener)
    as "the listener has a bound port"
  process.send(book, Update(State(port, 0, None)))
  let assert Ok(first) = socket.tcp_accept(listener, 30_000)
    as "the admitted A prompt connects to the held provider"
  let initial = request(first)
  send(
    first,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
  )
  chunk(
    first,
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"held-original\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n",
  )
  process.send(book, Update(State(port, 1, None)))

  // This 30-second hold is below provider_ffi's 300-second response timeout.
  // A timeout is reported distinctly and cannot satisfy the stop witness.
  let assert Ok(ending) = classify_closure(socket.tcp_receive(first, 0, 30_000))
    as "the held connection may only close or reach its explicit deadline"
  process.send(book, Update(State(port, 1, Some(ending))))
  assert ending == ClientClosed as "hold expiry is not provider cancellation"
  let _ = socket.tcp_close(first)

  // Explicit reopen resumes the admitted operation, not a second user command.
  let assert Ok(second) = socket.tcp_accept(listener, 30_000)
    as "explicit reopen recovers the unfinished original request"
  let recovered = request(second)
  process.send(book, Update(State(port, 2, Some(ending))))
  assert recovered == initial as "recovery sends the exact same decoded request"
  let _ = socket.tcp_close(listener)
  send(
    second,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
  )
  chunk(
    second,
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"recovered\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"recoveredanswer\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  )
  send(second, "0\r\n\r\n")
  let _ = socket.tcp_close(second)
  Nil
}

// Read only Content-Length HTTP/1.1 from the known production client. Headers
// are consumed one byte at a time, bounded before allocation; no generic HTTP
// parser or request chunking is introduced for this two-request fixture.
fn request(peer: socket.Socket) -> json.JsonValue {
  let assert poll.Answer(headers) =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 10_000,
      every: poll.Fixed(0),
      from: "",
      attempt: fn(headers) {
        case string.ends_with(headers, "\r\n\r\n") {
          True -> poll.Settled(headers)
          False -> {
            assert string.byte_size(headers) < 8192
              as "request headers fit the fixture cap"
            let assert Ok(byte) = socket.tcp_receive(peer, 1, 1000)
              as "request headers arrive within the read deadline"
            let assert Ok(byte) = bit_array.to_string(byte)
              as "fixture request headers are ASCII"
            poll.Pending(headers <> byte)
          }
        }
      },
    )
    as "the bounded HTTP header is complete"
  let assert Ok(length) = declared_length(headers)
    as "request framing and allocation bounds are checked before body recv"
  let assert Ok(bytes) = socket.tcp_receive(peer, length, 10_000)
    as "the complete request body arrives"
  let assert Ok(text) = bit_array.to_string(bytes) as "the request is UTF-8"
  let assert Ok(value) = json.parse(text) as "the request is JSON"
  assert field(value, "model") == json.String("fixture")
  assert field(value, "stream") == json.Bool(True)
  let assert json.Array(messages) = field(value, "messages")
    as "request messages are present"
  let assert Ok(latest) = list.last(messages) as "the latest message exists"
  assert field(latest, "role") == json.String("user")
  let assert json.Array(blocks) = field(latest, "content")
    as "the latest user content is explicit"
  let content = case blocks {
    [content] -> content
    [author, content] -> {
      assert field(author, "type") == json.String("text")
      let assert json.String(label) = field(author, "text")
        as "the attribution block is text"
      assert string.starts_with(
        label,
        "Human author (name and principal are attribution data): ",
      )
      content
    }
    _ -> panic as "the latest user message has no unrelated content"
  }
  assert field(content, "type") == json.String("text")
  assert field(content, "text") == json.String("held A prompt")
  value
}

/// Accepts only the bounded Content-Length framing used by the real client.
/// This is not a general HTTP parser: request chunking and other routes fail.
///
/// ## Examples
///
/// `declared_length("POST /v1/messages HTTP/1.1\r\n...\r\n\r\n")`.
pub fn declared_length(headers: String) -> Result(Int, String) {
  use <- bool.guard(
    when: string.byte_size(headers) > 8192,
    return: Error("headers exceed fixture limit"),
  )
  use <- bool.guard(
    when: !string.ends_with(headers, "\r\n\r\n"),
    return: Error("incomplete headers"),
  )
  use lines <- result.try(case string.split(headers, "\r\n") {
    ["POST /v1/messages HTTP/1.1", ..lines] -> Ok(lines)
    _ -> Error("unexpected provider route")
  })
  use fields <- result.try(
    lines
    |> list.filter(fn(line) { line != "" })
    |> list.try_map(fn(line) {
      use pair <- result.try(
        string.split_once(line, ":") |> result.replace_error("malformed header"),
      )
      Ok(#(string.lowercase(pair.0), string.trim(pair.1)))
    }),
  )
  use <- bool.guard(
    when: list.key_find(fields, "x-api-key") != Ok(provider_http.dummy_key),
    return: Error("invalid dummy key"),
  )
  use <- bool.guard(
    when: list.key_find(fields, "transfer-encoding") != Error(Nil),
    return: Error("request transfer encoding is unsupported"),
  )
  use encoded <- result.try(
    case list.filter(fields, fn(field) { field.0 == "content-length" }) {
      [#(_, encoded)] -> Ok(encoded)
      _ -> Error("expected one Content-Length")
    },
  )
  use length <- result.try(
    int.parse(encoded) |> result.replace_error("invalid Content-Length"),
  )
  use <- bool.guard(
    when: length < 1 || length > 262_144,
    return: Error("body exceeds fixture bounds"),
  )
  Ok(length)
}

fn field(value: json.JsonValue, key: String) -> json.JsonValue {
  let assert json.Object(fields) = value
    as "fixture protocol fields are JSON objects"
  list.key_find(fields, key) |> result.unwrap(json.Null)
}

fn send(peer: socket.Socket, text: String) -> Nil {
  assert tcp.send(peer, bit_array.from_string(text)) == Ok(Nil)
    as "the owned provider socket sends its exact response bytes"
}

fn chunk(peer: socket.Socket, text: String) -> Nil {
  let assert Ok(size) = int.to_base_string(string.byte_size(text), 16)
    as "the fixed hexadecimal chunk base is valid"
  send(peer, size <> "\r\n" <> text <> "\r\n")
}
