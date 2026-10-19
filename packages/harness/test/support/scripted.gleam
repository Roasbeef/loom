//// A scripted Anthropic provider for `harness` tests.
////
//// The transport performs in-memory scripted work only. Each request gets a
//// monitorable owner process and cancelling kills it, matching the production
//// transport contract without pretending to cancel external I/O (the same
//// shape `client`'s tests use; `harness` cannot import `client`). A script is
//// a function from the request body to the turn the model takes next, so a
//// test decides from what the request already carries, not from a counter
//// which would disagree with a retry.

import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import provider/http

/// What the scripted model does on one request.
pub type Turn {
  /// Call one tool with these JSON arguments, then stop for its result.
  CallTool(id: String, name: String, arguments: json.JsonValue)

  /// Answer in text and end the turn.
  Say(text: String)
}

type ScriptControl {
  BeginScript
  CancelScript
  CreatorExited
}

/// A transport which sends each request body to `observed` and replays the
/// turn `script` picks for it.
pub fn transport(
  observed: Subject(String),
  script: fn(String) -> Turn,
) -> http.Transport {
  prepared(fn(request, events) {
    process.send(observed, request.body)
    replay(script(request.body), events)
  })
}

/// How many tool results a request body already carries. A script decides its
/// next turn from this: zero results means the model has not called a tool.
pub fn tool_results(body: String) -> Int {
  list.length(string.split(body, "\"tool_result\"")) - 1
}

fn prepared(
  replay: fn(http.HttpRequest, Subject(http.HttpEvent)) -> Nil,
) -> http.Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let creator = process.self()
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let control = process.new_subject()
        let creator_monitor = process.monitor(creator)
        process.send(ready, control)
        let command =
          process.new_selector()
          |> process.select_map(control, fn(command) { command })
          |> process.select_specific_monitor(creator_monitor, fn(_down) {
            CreatorExited
          })
          |> process.selector_receive_forever()
        process.demonitor_process(creator_monitor)
        case command {
          BeginScript -> replay(request, events)
          CancelScript | CreatorExited -> Nil
        }
      })
    let control = process.receive_forever(ready)
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(control, CancelScript)
        }),
        begin: fn() { process.send(control, BeginScript) },
      ),
    )
  })
}

fn replay(turn: Turn, events: Subject(http.HttpEvent)) -> Nil {
  process.send(
    events,
    http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
  )
  let #(content, reason) = case turn {
    CallTool(id:, name:, arguments:) -> #(call(id, name, arguments), "tool_use")
    Say(text:) -> #(text_block(text), "end_turn")
  }
  let body =
    sse(
      "message_start",
      json.Object([
        #("type", json.String("message_start")),
        #(
          "message",
          json.Object([
            #("id", json.String("m")),
            #("model", json.String("test")),
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
    )
    <> content
    <> sse(
      "content_block_stop",
      json.Object([
        #("type", json.String("content_block_stop")),
        #("index", json.Int(0)),
      ]),
    )
    <> sse(
      "message_delta",
      json.Object([
        #("type", json.String("message_delta")),
        #("delta", json.Object([#("stop_reason", json.String(reason))])),
        #("usage", json.Object([#("output_tokens", json.Int(1))])),
      ]),
    )
    <> sse(
      "message_stop",
      json.Object([#("type", json.String("message_stop"))]),
    )
  process.send(events, http.ResponseChunk(bit_array.from_string(body)))
  process.send(events, http.ResponseEnd)
}

fn sse(kind: String, value: json.JsonValue) -> String {
  "event: " <> kind <> "\ndata: " <> json.to_string(value) <> "\n\n"
}

fn text_block(text: String) -> String {
  sse(
    "content_block_start",
    json.Object([
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #(
        "content_block",
        json.Object([
          #("type", json.String("text")),
          #("text", json.String(text)),
        ]),
      ),
    ]),
  )
}

fn call(id: String, name: String, arguments: json.JsonValue) -> String {
  sse(
    "content_block_start",
    json.Object([
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #(
        "content_block",
        json.Object([
          #("type", json.String("tool_use")),
          #("id", json.String(id)),
          #("name", json.String(name)),
          #("input", json.Object([])),
        ]),
      ),
    ]),
  )
  <> sse(
    "content_block_delta",
    json.Object([
      #("type", json.String("content_block_delta")),
      #("index", json.Int(0)),
      #(
        "delta",
        json.Object([
          #("type", json.String("input_json_delta")),
          #("partial_json", json.String(json.to_string(arguments))),
        ]),
      ),
    ]),
  )
}
