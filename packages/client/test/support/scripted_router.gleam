//// A scripted router model for the live lane's tests.
////
//// The settings it builds route the `router` role to a model named
//// `router-1` behind an Anthropic-shaped transport that answers from a
//// function the test gives. Everything above the wire is the real code: the
//// gateway, the routing, the request encoding and the session runtime. A claim
//// about what a model was shown is made on the request the transport received,
//// and a claim about what it did is made through the reply the script gave.

import client/catalog
import client/owned_assembly_test
import client/serve
import core/clock
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import provider/http
import provider/model
import provider/secret

/// The router's model id, which no other role of the settings uses.
pub const router_model = "router-1"

/// The main role's model id. A request that reaches it was routed wrongly.
pub const main_model = "main-1"

/// One provider request as the model was shown it.
pub type Request {
  Request(
    /// The model id the request named.
    model: String,
    /// The names of the tools it advertised, sorted.
    tools: List(String),
    /// The system prompt.
    system: String,
    /// The text of every message, in order, with its role.
    messages: List(#(String, String)),
    /// The whole body, for a claim about what is not in it.
    raw: String,
  )
}

/// What the script does with a request.
pub type Reply {
  /// Call `route` with these `(trigger, action)` items.
  Route(items: List(#(String, String)))

  /// End the turn with this text and no tool call.
  Say(text: String)

  /// Answer with this HTTP status, which fails the run.
  Fail(status: Int)

  /// Never answer, so a trial stays in flight until something stops it.
  Hang
}

/// The settings of a daemon-shaped session whose models are scripted. `seen`
/// receives every request before the script answers it.
///
/// ## Examples
///
/// ```gleam
/// // scripted_router.settings(fn(_) { scripted_router.Say("ok") }, seen)
/// ```
pub fn settings(
  behave: fn(Request) -> Reply,
  seen: Subject(Request),
) -> serve.Settings {
  let base = owned_assembly_test.settings()
  let catalogue =
    catalog.Catalog(
      models: [entry("main", main_model), entry("router", router_model)],
      roles: [
        #(model.Main, ["main"]),
        #(catalog.router_role, ["router"]),
      ],
      profiles: [],
      mcp_servers: [],
      lsp_servers: [],
    )
  serve.Settings(
    ..base,
    catalog: catalogue,
    gateway: catalog.gateway(
      catalogue,
      transport: transport(fn(request, events, hold) {
        let parsed = read(request.body)
        process.send(seen, parsed)
        answer(behave(parsed), parsed, events, hold)
      }),
      secrets: secret.from_list([
        #("MAIN_KEY", "fixture-key"),
        #("ROUTER_KEY", "fixture-key"),
      ]),
      clock: clock.fixed(at: 0),
    ),
  )
}

fn entry(name: String, model_id: String) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url: "https://" <> name <> ".test",
    api_key_env: string.uppercase(name) <> "_KEY",
    model_id:,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    pricing: None,
    vision: catalog.TextOnly,
    max_images: 8,
    cyber_access: None,
    service_tier: None,
  )
}

/// The candidate a request is about, read from the host's thread note, which
/// names it first. A script routes the candidate it is shown.
///
/// ## Examples
///
/// ```gleam
/// // scripted_router.candidate_of(request) == "gh-c-3001"
/// ```
pub fn candidate_of(request: Request) -> String {
  let found =
    list.find_map(request.messages, fn(each) {
      case string.split_once(each.1, "Candidate ") {
        Ok(#(_, rest)) ->
          case string.split_once(rest, " arrived") {
            Ok(#(id, _)) -> Ok(id)
            Error(Nil) -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })
  result.unwrap(found, "")
}

/// How many `route` results a request already carries, which is a script's
/// place in its conversation.
///
/// ## Examples
///
/// ```gleam
/// // scripted_router.results_in(request) == 0
/// ```
pub fn results_in(request: Request) -> Int {
  string.split(request.raw, "\"type\":\"tool_result\"")
  |> list.length
  |> int.subtract(1)
}

fn read(body: String) -> Request {
  let assert Ok(parsed) = json.parse(body) as "the provider request is JSON"
  let messages = case field(parsed, "messages") {
    json.Array(items) -> items
    _ -> []
  }
  let tool_names = case field(parsed, "tools") {
    json.Array(items) ->
      list.filter_map(items, fn(item) {
        case field(item, "name") {
          json.String(name) -> Ok(name)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
  Request(
    model: text(field(parsed, "model")),
    tools: list.sort(tool_names, string.compare),
    system: system_text(field(parsed, "system")),
    messages: list.flat_map(messages, message_texts),
    raw: body,
  )
}

// The system prompt arrives as a string or as a list of blocks.
fn system_text(value: JsonValue) -> String {
  case value {
    json.String(found) -> found
    json.Array(blocks) ->
      blocks |> list.map(fn(b) { text(field(b, "text")) }) |> string.join("\n")
    _ -> ""
  }
}

fn message_texts(message: JsonValue) -> List(#(String, String)) {
  let role = text(field(message, "role"))
  case field(message, "content") {
    json.String(found) -> [#(role, found)]
    json.Array(blocks) ->
      list.map(blocks, fn(block) { #(role, text(field(block, "text"))) })
    _ -> []
  }
}

fn text(value: JsonValue) -> String {
  case value {
    json.String(found) -> found
    _ -> ""
  }
}

fn field(value: JsonValue, key: String) -> JsonValue {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.unwrap(json.Null)
    _ -> json.Null
  }
}

// --- replies ------------------------------------------------------------------

// The scripted transport. It is `support/provider.transport` with one addition:
// a script can `hold` the request open and still be stopped, because the hold
// ends when the request is cancelled or its creator exits. A script that slept
// instead would never exit, and a session could not close with the request
// still in flight, which is the situation a wall limit creates.
type Control {
  BeginScript
  CancelScript
  CreatorExited
}

fn transport(
  replay: fn(http.HttpRequest, Subject(http.HttpEvent), fn() -> Nil) -> Nil,
) -> http.Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let creator = process.self()
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let control = process.new_subject()
        let watch = process.monitor(creator)
        process.send(ready, control)
        let next = fn() {
          process.new_selector()
          |> process.select_map(control, fn(command) { command })
          |> process.select_specific_monitor(watch, fn(_down) { CreatorExited })
          |> process.selector_receive_forever()
        }
        case next() {
          BeginScript -> {
            replay(request, events, fn() {
              let _ = next()
              Nil
            })
          }
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

fn answer(
  reply: Reply,
  request: Request,
  events: Subject(http.HttpEvent),
  hold: fn() -> Nil,
) -> Nil {
  case reply {
    Hang -> hold()
    Fail(status) -> {
      process.send(events, http.ResponseStatus(status, []))
      process.send(
        events,
        http.ResponseChunk(bit_array.from_string("{\"error\":\"scripted\"}")),
      )
      process.send(events, http.ResponseEnd)
    }
    Say(words) -> stream(events, text_turn(words))
    Route(items) -> stream(events, route_turn(request, items))
  }
}

fn stream(events: Subject(http.HttpEvent), body: String) -> Nil {
  process.send(
    events,
    http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
  )
  process.send(events, http.ResponseChunk(bit_array.from_string(body)))
  process.send(events, http.ResponseEnd)
}

fn route_turn(request: Request, items: List(#(String, String))) -> String {
  let arguments =
    json.Object([
      #(
        "items",
        json.Array(
          list.map(items, fn(item) {
            // Each action takes exactly the arguments that mean something for
            // it: an accept has a title, the others that name a ticket have
            // one, and an ignore has neither.
            json.Object([
              #("trigger", json.String(item.0)),
              #("action", json.String(item.1)),
              ..case item.1 {
                "accept" -> [#("title", json.String("scripted"))]
                "ignore" -> []
                _ -> [#("ticket", json.String("t-1"))]
              }
            ])
          }),
        ),
      ),
    ])
  tool_turn("route-" <> int.to_string(results_in(request)), "route", arguments)
}

fn text_turn(words: String) -> String {
  started()
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":"
      <> json.to_string(json.String(words))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("end_turn")
}

fn tool_turn(id: String, name: String, arguments: JsonValue) -> String {
  started()
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\""
      <> id
      <> "\",\"name\":\""
      <> name
      <> "\",\"input\":{}}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
      <> json.to_string(json.String(json.to_string(arguments)))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started() -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"scripted\",\"model\":\"scripted\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> reason
      <> "\"},\"usage\":{\"output_tokens\":3}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse(event: String, data: String) -> String {
  "event: " <> event <> "\ndata: " <> data <> "\n\n"
}
