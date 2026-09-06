//// A finite Anthropic peer reached through real loopback HTTP, including from
//// a separately shipped daemon VM. Only the last user text selects a response;
//// earlier transcript markers cannot accidentally satisfy the next script step.
//// The wrapper owns the listener and script actor through a bounded callback,
//// retains original monitors, and retires both before returning request evidence.

import core/json
import core/message
import core/origin
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import weft
import weft/actor

/// A deliberately public dummy credential, never a real provider secret.
pub const dummy_key = "loom-provider-fixture-key"

/// One ordered request and its finite text-only response.
pub type Exchange {
  Exchange(
    /// Exact latest user text, independent of previous transcript messages.
    prompt: String,
    /// Text emitted as an Anthropic content delta.
    answer: String,
  )
}

/// Validated request evidence; credentials and other headers are not retained.
pub type ObservedRequest {
  ObservedRequest(
    /// The configured model, required to equal `fixture`.
    model: String,
    /// Exact final user text, excluding its optional separate attribution block.
    prompt: String,
    /// Bounded decoded content for additional transcript assertions.
    body: json.JsonValue,
  )
}

type Book {
  Book(List(Exchange), List(ObservedRequest), Option(String))
}

type Message {
  Submit(
    Result(ObservedRequest, String),
    process.Subject(Result(String, String)),
  )
  Report(process.Subject(Result(List(ObservedRequest), String)))
}

type Stream {
  Send
}

/// Runs against an ephemeral loopback URL, then returns ordered request evidence.
/// The callback has 120 seconds; first refusal or unused script steps make the
/// report an Error. Callers must assert that report, not just their callback value.
///
/// ## Examples
///
/// ```gleam
/// // let #(value, report) = provider_http.with_server([
/// //   provider_http.Exchange("first", "answer"),
/// // ], fn(base_url) { drive_shipped_daemon(base_url) })
/// // let assert Ok(requests) = report
/// ```
pub fn with_server(
  script: List(Exchange),
  run: fn(String) -> a,
) -> #(a, Result(List(ObservedRequest), String)) {
  assert list.length(script) <= 8 as "the provider script is finite and small"
  assert list.all(script, fn(step) {
    string.byte_size(step.prompt) <= 4096
    && string.byte_size(step.answer) <= 4096
  })
    as "fixture prompts and answers have fixed byte bounds"
  let assert Ok(book) =
    actor.new(Book(script, [], None)) |> actor.on_message(handle) |> actor.start
    as "the script owner starts before network admission"
  let book_watch = process.monitor(book.pid)

  // after_start publishes the actual bound port before the callback receives
  // its URL, so an ephemeral-port guess can never select a different listener.
  let ports = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(req) { serve(req, book.data) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "the real loopback listener starts"
  let listener_watch = process.monitor(listener.pid)
  let assert Ok(port) = process.receive(ports, 1000)
    as "the original listener publishes its selected port"
  let outcomes =
    weft.new([fn() { Ok(run("http://127.0.0.1:" <> int.to_string(port))) }])
    |> weft.deadline(120_000)
    |> weft.start

  // Both owners stay linked to this coordinator through the callback: its
  // death cannot orphan them. Only deliberate teardown removes those links.
  // Original DOWN evidence is retained before any callback can finish or fail.
  retire(listener.pid, listener_watch)
  let report = actor.call(book.data, 1000, Report)
  retire(book.pid, book_watch)
  let assert [weft.Completed(0, value)] = outcomes
    as "the HTTP fixture callback completes without crashing or timing out"
  #(value, report)
}

fn retire(pid: process.Pid, monitor: process.Monitor) -> Nil {
  process.unlink(pid)
  process.kill(pid)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original fixture owner retires, not a late monitor or timeout"
  Nil
}

fn handle(book: Book, message: Message) -> actor.Next(Book, Message) {
  case message {
    Report(reply) -> {
      let Book(remaining, seen, refusal) = book
      let report = case refusal, remaining {
        Some(reason), _ -> Error(reason)
        None, [] -> Ok(list.reverse(seen))
        None, [_, ..] -> Error("provider script was not exhausted")
      }
      process.send(reply, report)
      actor.continue(book)
    }
    Submit(incoming, reply) -> {
      let #(next, answer) = take(book, incoming)
      process.send(reply, answer)
      actor.continue(next)
    }
  }
}

fn take(
  book: Book,
  incoming: Result(ObservedRequest, String),
) -> #(Book, Result(String, String)) {
  let Book(remaining, seen, refusal) = book
  case refusal, incoming, remaining {
    Some(reason), _, _ -> #(book, Error(reason))
    None, Error(reason), _ -> #(
      Book(remaining, seen, Some(reason)),
      Error(reason),
    )
    None, Ok(observed), [Exchange(prompt, answer), ..rest]
      if observed.prompt == prompt
    -> #(Book(rest, [observed, ..seen], None), Ok(answer))
    None, Ok(_), _ -> #(
      Book(
        remaining,
        seen,
        Some("unexpected latest user text or extra request"),
      ),
      Error("unexpected latest user text or extra request"),
    )
  }
}

fn serve(
  req: request.Request(mist.Connection),
  book: process.Subject(Message),
) -> response.Response(mist.ResponseData) {
  let incoming = validate(req)
  case actor.call(book, 1000, Submit(incoming, _)) {
    Error(reason) ->
      response.new(case reason {
        "invalid dummy key" -> 401
        _ -> 400
      })
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(reason)))
    // Keep real chunked HTTP here: the shipped daemon must traverse its native
    // streaming transport, rather than receiving one buffered fixture body.
    Ok(answer) ->
      mist.chunked(
        req,
        response.new(200)
          |> response.set_header("content-type", "text/event-stream"),
        init: fn(subject) {
          process.send(subject, Send)
          answer
        },
        loop: fn(answer, _message, socket) {
          list.each(transcript(answer), fn(chunk) {
            assert mist.send_chunk(socket, bit_array.from_string(chunk))
              == Ok(Nil)
          })
          mist.chunk_stop()
        },
      )
  }
}

fn validate(
  req: request.Request(mist.Connection),
) -> Result(ObservedRequest, String) {
  use Nil <- result.try(case req.method, req.path {
    http.Post, "/v1/messages" -> Ok(Nil)
    _, _ -> Error("expected POST /v1/messages")
  })
  use Nil <- result.try(case request.get_header(req, "x-api-key") {
    Ok(key) if key == dummy_key -> Ok(Nil)
    _ -> Error("invalid dummy key")
  })
  use body <- result.try(
    mist.read_body(req, 262_144)
    |> result.replace_error("request body exceeds limit or is malformed"),
  )
  use text <- result.try(
    bit_array.to_string(body.body)
    |> result.replace_error("request body is not UTF-8"),
  )
  use value <- result.try(
    json.parse(text) |> result.replace_error("request body is not JSON"),
  )
  use #(model, messages) <- result.try(
    case
      field(value, "model"),
      field(value, "stream"),
      field(value, "messages")
    {
      json.String(model), json.Bool(True), json.Array(messages)
        if model == "fixture"
      -> Ok(#(model, messages))
      _, _, _ -> Error("expected fixture model, stream=true and messages")
    },
  )
  use latest <- result.try(
    list.last(messages) |> result.replace_error("messages must not be empty"),
  )
  use content <- result.try(
    case field(latest, "role"), field(latest, "content") {
      json.String("user"), json.Array(content) -> user_content(content)
      _, _ -> Error("latest message must contain user text")
    },
  )
  case field(content, "type"), field(content, "text") {
    json.String("text"), json.String(prompt) ->
      Ok(ObservedRequest(model, prompt, value))
    _, _ -> Error("latest user content must be text")
  }
}

// The Anthropic adapter prepends core/origin's separate author block. Accept
// that precise two-block shape, not arbitrary preceding text or a scan of old
// turns. The label is presentation data; this fixture derives no authority from
// it. Additional user blocks remain unsupported rather than guessed away.
fn user_content(
  blocks: List(json.JsonValue),
) -> Result(json.JsonValue, String) {
  case blocks {
    [content] -> Ok(content)
    [label, content] -> validate_label(label) |> result.replace(content)
    _ -> Error("latest message must contain one text plus optional attribution")
  }
}

fn validate_label(label: json.JsonValue) -> Result(message.Origin, String) {
  use encoded <- result.try(case field(label, "type"), field(label, "text") {
    json.String("text"),
      json.String(
        "Human author (name and principal are attribution data): " <> encoded,
      )
    -> Ok(encoded)
    _, _ -> Error("unexpected text before latest user prompt")
  })
  use value <- result.try(
    json.parse(encoded) |> result.replace_error("invalid attribution JSON"),
  )
  case field(value, "principal"), field(value, "name") {
    json.String(principal), json.String(name) ->
      origin.validate(principal, name)
      |> result.replace_error("invalid attribution label")
    _, _ -> Error("invalid attribution fields")
  }
}

fn field(value: json.JsonValue, key: String) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.unwrap(json.Null)
    _ -> json.Null
  }
}

fn event(name: String, fields: List(#(String, json.JsonValue))) -> String {
  "event: "
  <> name
  <> "\ndata: "
  <> json.to_string(json.Object(fields))
  <> "\n\n"
}

fn transcript(answer: String) -> List(String) {
  [
    event("message_start", [
      #("type", json.String("message_start")),
      #(
        "message",
        json.Object([
          #("id", json.String("fixture-message")),
          #("model", json.String("fixture")),
          #(
            "usage",
            json.Object([
              #("input_tokens", json.Int(1)),
              #("output_tokens", json.Int(0)),
            ]),
          ),
        ]),
      ),
    ]),
    event("content_block_start", [
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #(
        "content_block",
        json.Object([#("type", json.String("text")), #("text", json.String(""))]),
      ),
    ]),
    event("content_block_delta", [
      #("type", json.String("content_block_delta")),
      #("index", json.Int(0)),
      #(
        "delta",
        json.Object([
          #("type", json.String("text_delta")),
          #("text", json.String(answer)),
        ]),
      ),
    ]),
    event("message_delta", [
      #("type", json.String("message_delta")),
      #("delta", json.Object([#("stop_reason", json.String("end_turn"))])),
      #("usage", json.Object([#("output_tokens", json.Int(1))])),
    ]),
    event("message_stop", [#("type", json.String("message_stop"))]),
  ]
}
