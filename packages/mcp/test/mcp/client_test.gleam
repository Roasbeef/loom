//// The client actor against a scripted in-process fake server: the
//// handshake and its refusals, pagination and its cap, correlation
//// under interleaving, the -32601 answer to server requests, the drop
//// of notifications and late responses, and every way the peer dies —
//// all through the production transport seam, no OS process anywhere.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mcp/client
import mcp/jsonrpc.{type Id, type Inbound}
import mcp/protocol
import mcp/stdio
import support/fake_server.{type Action, Close, Raw, Reply}

// --- fixtures ---------------------------------------------------------------

fn response(id: Id, result: JsonValue) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String("2.0")),
    #("id", encode_id(id)),
    #("result", result),
  ])
}

fn encode_id(id: Id) -> JsonValue {
  case id {
    jsonrpc.IdInt(value:) -> json.Int(value)
    jsonrpc.IdString(value:) -> json.String(value)
  }
}

fn initialize_result(version: String) -> JsonValue {
  json.Object([
    #("protocolVersion", json.String(version)),
    #("capabilities", json.Object([#("tools", json.Object([]))])),
  ])
}

fn initialize_result_without_tools() -> JsonValue {
  json.Object([
    #("protocolVersion", json.String(protocol.requested_version)),
    #("capabilities", json.Object([])),
  ])
}

fn text_result(text: String) -> JsonValue {
  json.Object([
    #(
      "content",
      json.Array([
        json.Object([
          #("type", json.String("text")),
          #("text", json.String(text)),
        ]),
      ]),
    ),
  ])
}

fn tools_page(names: List(String), next: Option(String)) -> JsonValue {
  let tools =
    json.Array(
      list.map(names, fn(name) {
        json.Object([
          #("name", json.String(name)),
          #("inputSchema", json.Object([])),
        ])
      }),
    )
  json.Object(case next {
    None -> [#("tools", tools)]
    Some(cursor) -> [#("tools", tools), #("nextCursor", json.String(cursor))]
  })
}

// Wraps a per-test script with the standard good handshake: initialize
// answered with the requested version and a tools capability, the
// initialized notification swallowed.
fn with_handshake(
  rest: fn(state, Inbound) -> #(state, List(Action)),
) -> fn(state, Inbound) -> #(state, List(Action)) {
  fn(state, inbound) {
    case inbound {
      jsonrpc.ServerRequest(id:, method: "initialize", ..) -> #(state, [
        Reply(response(id, initialize_result(protocol.requested_version))),
      ])
      jsonrpc.Notification(method: "notifications/initialized", ..) -> #(
        state,
        [],
      )
      other -> rest(state, other)
    }
  }
}

fn started(
  initial: state,
  script: fn(state, Inbound) -> #(state, List(Action)),
) -> #(client.Client, fake_server.Fake(state)) {
  let fake = fake_server.start(initial, script)
  let assert Ok(connected) =
    client.start(fake_server.seam(fake), client.options("0.1.0"))
    as "the scripted handshake should succeed"
  #(connected, fake)
}

// The cursor of a tools/list request's params, if any.
fn cursor_of(params: Option(JsonValue)) -> Option(String) {
  case params {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "cursor") {
        Ok(json.String(cursor)) -> Some(cursor)
        _ -> None
      }
    _ -> None
  }
}

// The tool name of a tools/call request's params.
fn tool_name_of(params: Option(JsonValue)) -> String {
  case params {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "name") {
        Ok(json.String(name)) -> name
        _ -> panic as "tools/call params should carry a string name"
      }
    _ -> panic as "tools/call should carry params"
  }
}

// Polls `seen` until a line satisfies the predicate — the client's reply
// to an injected server request races the test's own read, so the
// assertion waits it out rather than assuming arrival order.
fn eventually_seen(
  fake: fake_server.Fake(state),
  predicate: fn(String) -> Bool,
  attempts: Int,
) -> Bool {
  case list.any(fake_server.seen(fake), predicate) {
    True -> True
    False ->
      case attempts <= 0 {
        True -> False
        False -> {
          process.sleep(10)
          eventually_seen(fake, predicate, attempts - 1)
        }
      }
  }
}

// --- the handshake ----------------------------------------------------------

pub fn handshake_and_call_tool_round_trip_test() {
  let #(connected, fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/call", params:) -> {
            assert tool_name_of(params) == "echo"
            #(state, [Reply(response(id, text_result("hi")))])
          }
          _ -> #(state, [])
        }
      }),
    )
  let assert Ok(result) =
    client.call_tool(connected, "echo", json.Object([]), 1000)
  assert result.content == [protocol.Text("hi")]
  assert result.is_error == False
  // The lifecycle completed: the initialized notification reached the
  // server after the initialize result was accepted.
  assert list.contains(
    fake_server.seen(fake),
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
  client.stop(connected)
}

pub fn a_server_negotiating_an_unknown_version_is_refused_test() {
  let fake =
    fake_server.start(Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "initialize", ..) -> #(state, [
          Reply(response(id, initialize_result("2099-01-01"))),
        ])
        _ -> #(state, [])
      }
    })
  let assert Error(client.VersionUnsupported(server:, supported:)) =
    client.start(fake_server.seam(fake), client.options("0.1.0"))
  assert server == "2099-01-01"
  assert supported == protocol.supported_versions()
}

pub fn a_server_without_the_tools_capability_is_refused_test() {
  let fake =
    fake_server.start(Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "initialize", ..) -> #(state, [
          Reply(response(id, initialize_result_without_tools())),
        ])
        _ -> #(state, [])
      }
    })
  let assert Error(client.ToolsNotDeclared) =
    client.start(fake_server.seam(fake), client.options("0.1.0"))
}

pub fn a_silent_server_fails_the_handshake_at_its_deadline_test() {
  let fake = fake_server.start(Nil, fn(state, _inbound) { #(state, []) })
  let assert Error(client.HandshakeFailed(error:)) =
    client.start(
      fake_server.seam(fake),
      client.options("0.1.0") |> client.with_handshake_timeout(100),
    )
  assert error == client.CallTimedOut(after_ms: 100)
}

// --- tools/list -------------------------------------------------------------

pub fn list_tools_follows_pagination_to_exhaustion_test() {
  let #(connected, _fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/list", params:) ->
            case cursor_of(params) {
              None -> #(state, [
                Reply(response(id, tools_page(["alpha"], Some("c1")))),
              ])
              Some("c1") -> #(state, [
                Reply(response(id, tools_page(["beta"], Some("c2")))),
              ])
              Some("c2") -> #(state, [
                Reply(response(id, tools_page(["gamma"], None))),
              ])
              Some(_) -> panic as "an unexpected cursor was requested"
            }
          _ -> #(state, [])
        }
      }),
    )
  let assert Ok(tools) = client.list_tools(connected, 1000)
  assert list.map(tools, fn(tool) { tool.name }) == ["alpha", "beta", "gamma"]
  client.stop(connected)
}

pub fn a_server_paginating_forever_is_refused_at_the_cap_test() {
  let #(connected, fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/list", ..) -> #(state, [
            Reply(response(id, tools_page(["again"], Some("again")))),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Error(client.TooManyPages(cap:)) =
    client.list_tools(connected, 1000)
  assert cap == client.max_tool_pages
  // Exactly the cap's worth of pages was requested, not one more.
  let pages =
    fake_server.seen(fake)
    |> list.filter(string.contains(_, "tools/list"))
  assert list.length(pages) == client.max_tool_pages
  client.stop(connected)
}

// --- correlation ------------------------------------------------------------

type Held {
  NothingHeld
  Holding(id: Id, name: String)
}

pub fn out_of_order_responses_correlate_to_their_own_calls_test() {
  // The fake holds the first tools/call until the second arrives, then
  // answers them in reverse order; each caller must still get the result
  // carrying its own tool's name.
  let #(connected, _fake) =
    started(
      NothingHeld,
      with_handshake(fn(held, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/call", params:) -> {
            let name = tool_name_of(params)
            case held {
              NothingHeld -> #(Holding(id:, name:), [])
              Holding(id: first_id, name: first_name) -> #(NothingHeld, [
                Reply(response(id, text_result(name <> "-result"))),
                Reply(response(first_id, text_result(first_name <> "-result"))),
              ])
            }
          }
          _ -> #(held, [])
        }
      }),
    )
  let results = process.new_subject()
  process.spawn(fn() {
    process.send(results, #(
      "a",
      client.call_tool(connected, "a", json.Object([]), 2000),
    ))
  })
  process.spawn(fn() {
    process.send(results, #(
      "b",
      client.call_tool(connected, "b", json.Object([]), 2000),
    ))
  })
  assert_own_result(results)
  assert_own_result(results)
  client.stop(connected)
}

fn assert_own_result(
  results: process.Subject(
    #(String, Result(protocol.CallToolResult, client.ClientError)),
  ),
) -> Nil {
  let assert Ok(#(name, outcome)) = process.receive(results, 3000)
    as "both concurrent callers should be answered"
  let assert Ok(result) = outcome as "each concurrent call should succeed"
  assert result.content == [protocol.Text(name <> "-result")]
  Nil
}

// --- server-initiated traffic -----------------------------------------------

pub fn a_server_request_is_answered_method_not_found_test() {
  let probe =
    "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"sampling/createMessage\"}\n"
  let #(connected, fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/call", ..) -> #(state, [
            Raw(bit_array.from_string(probe)),
            Reply(response(id, text_result("ok"))),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Ok(_) = client.call_tool(connected, "echo", json.Object([]), 1000)
  // The fake saw the refusal: a response to its own id carrying -32601.
  assert eventually_seen(fake, refuses_server_request("srv-1", _), 100)
  client.stop(connected)
}

fn refuses_server_request(expected_id: String, line: String) -> Bool {
  case jsonrpc.decode(line) {
    Ok(jsonrpc.Response(
      id: jsonrpc.IdString(id),
      outcome: Error(jsonrpc.RpcError(code:, ..)),
    )) -> id == expected_id && code == client.method_not_found_code
    _ -> False
  }
}

pub fn a_server_notification_is_dropped_test() {
  let #(connected, fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/call", ..) -> #(state, [
            Reply(jsonrpc.notification("notifications/tools/list_changed", None)),
            Reply(response(id, text_result("ok"))),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Ok(result) =
    client.call_tool(connected, "echo", json.Object([]), 1000)
  assert result.content == [protocol.Text("ok")]
  // The notification produced no answer: the client has written exactly
  // initialize, initialized, and the one tools/call.
  process.sleep(20)
  assert list.length(fake_server.seen(fake)) == 3
  client.stop(connected)
}

// --- deaths -----------------------------------------------------------------

pub fn an_oversized_line_settles_in_flight_calls_and_latches_death_test() {
  let #(connected, _fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(method: "tools/call", ..) -> #(state, [
            Raw(
              bit_array.from_string(string.repeat("a", stdio.max_line_bytes + 1)),
            ),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Error(client.Unavailable(reason:)) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  assert string.contains(reason, "exceeded")
  // Dead stays dead, in-band, without waiting out any deadline.
  let assert Error(client.Unavailable(_)) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  client.stop(connected)
}

pub fn a_malformed_line_settles_in_flight_calls_and_latches_death_test() {
  let #(connected, _fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(method: "tools/call", ..) -> #(state, [
            Raw(bit_array.from_string("this is not json\n")),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Error(client.Unavailable(_)) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  let assert Error(client.Unavailable(_)) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  client.stop(connected)
}

pub fn a_transport_close_mid_call_settles_the_caller_test() {
  let #(connected, _fake) =
    started(
      Nil,
      with_handshake(fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(method: "tools/call", ..) -> #(state, [
            Close("server crashed"),
          ])
          _ -> #(state, [])
        }
      }),
    )
  let assert Error(client.Unavailable(reason: "server crashed")) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  let assert Error(client.Unavailable(reason: "server crashed")) =
    client.call_tool(connected, "echo", json.Object([]), 2000)
  client.stop(connected)
}

pub fn a_timed_out_call_is_forgotten_and_its_late_response_dropped_test() {
  // The first tools/call is held with no answer; its caller times out.
  // On the second tools/call the fake answers the *forgotten* first id
  // and then the second — the stale response must vanish silently and
  // the live call must get its own result.
  let #(connected, _fake) =
    started(
      NothingHeld,
      with_handshake(fn(held, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, method: "tools/call", params:) ->
            case held {
              NothingHeld -> #(Holding(id:, name: tool_name_of(params)), [])
              Holding(id: stale_id, ..) -> #(NothingHeld, [
                Reply(response(stale_id, text_result("stale"))),
                Reply(response(id, text_result("fresh"))),
              ])
            }
          _ -> #(held, [])
        }
      }),
    )
  let assert Error(client.CallTimedOut(after_ms: 100)) =
    client.call_tool(connected, "slow", json.Object([]), 100)
  let assert Ok(result) =
    client.call_tool(connected, "fast", json.Object([]), 2000)
  assert result.content == [protocol.Text("fresh")]
  client.stop(connected)
}

pub fn calls_after_stop_answer_unavailable_test() {
  let #(connected, _fake) =
    started(Nil, with_handshake(fn(state, _inbound) { #(state, []) }))
  client.stop(connected)
  let assert Error(client.Unavailable(_)) =
    client.call_tool(connected, "echo", json.Object([]), 1000)
}
