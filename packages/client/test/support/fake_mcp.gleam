//// A stateless in-process MCP server for the wiring's tests.
////
//// It plugs into the real `mcp/transport.ChannelTransport` seam, so the
//// client actor under it runs its production path — framing, decoding,
//// id correlation, the death latch — with no OS process anywhere. The
//// answer is computed inside the connection's own `send`, which runs on
//// the client actor's process, so a reply is enqueued to that actor's
//// inbound subject before `send` returns and arrives on its next
//// iteration: no second process, no scheduling to wait on, and a whole
//// `tools/call` round trip that is deterministic.
////
//// `packages/mcp` has a scripted fake of its own for the client's own
//// tests. This one is deliberately smaller: what these tests need is a
//// server that answers correctly so that the *translation* on either
//// side of it can be asserted on.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, Some}
import mcp/jsonrpc
import mcp/protocol
import mcp/stdio
import mcp/transport

/// What the fake answers one `tools/call` with.
pub type Answer {
  /// A well-formed `tools/call` result, as its raw JSON.
  Answers(result: JsonValue)
  /// A JSON-RPC error response.
  Fails(code: Int, message: String)
}

/// The transport to hand `mcp/client.start`: a server declaring `tools`,
/// listing `tools`, and answering every `tools/call` through `call`.
pub fn seam(
  tools tools: List(JsonValue),
  call call: fn(String, JsonValue) -> Answer,
) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) {
    transport.Connection(
      send: fn(line) {
        list.each(answer(line, tools, call), fn(reply) {
          process.send(
            inbound,
            transport.TransportData(
              bytes: bit_array.from_string(stdio.frame(reply)),
            ),
          )
        })
        Ok(Nil)
      },
      close: fn() { Nil },
    )
  })
}

/// One tool descriptor with an object schema of string properties.
pub fn tool(name: String, properties: List(String)) -> JsonValue {
  json.Object([
    #("name", json.String(name)),
    #("description", json.String("the " <> name <> " tool")),
    #(
      "inputSchema",
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object(
            list.map(properties, fn(property) {
              #(property, json.Object([#("type", json.String("string"))]))
            }),
          ),
        ),
        #("required", json.Array(list.map(properties, json.String))),
      ]),
    ),
  ])
}

/// A `tools/call` result carrying one text block.
pub fn text_result(text: String, is_error: Bool) -> JsonValue {
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
    #("isError", json.Bool(is_error)),
  ])
}

fn answer(
  line: String,
  tools: List(JsonValue),
  call: fn(String, JsonValue) -> Answer,
) -> List(JsonValue) {
  case jsonrpc.decode(line) {
    Ok(jsonrpc.ServerRequest(id:, method: "initialize", params: _)) -> [
      ok(id, initialize_result()),
    ]
    Ok(jsonrpc.ServerRequest(id:, method: "tools/list", params: _)) -> [
      ok(id, json.Object([#("tools", json.Array(tools))])),
    ]
    Ok(jsonrpc.ServerRequest(id:, method: "tools/call", params:)) -> [
      called(id, params, call),
    ]
    // Notifications get nothing, and so does anything this fake does not
    // speak: the client is what decides that a silence is a timeout.
    Ok(_other) -> []
    Error(_fault) -> []
  }
}

fn called(
  id: jsonrpc.Id,
  params: Option(JsonValue),
  call: fn(String, JsonValue) -> Answer,
) -> JsonValue {
  let fields = case params {
    Some(json.Object(fields)) -> fields
    _other -> []
  }
  let name = case list.key_find(fields, "name") {
    Ok(json.String(name)) -> name
    _other -> ""
  }
  let arguments = case list.key_find(fields, "arguments") {
    Ok(value) -> value
    Error(Nil) -> json.Object([])
  }
  case call(name, arguments) {
    Answers(result:) -> ok(id, result)
    Fails(code:, message:) -> failed(id, code, message)
  }
}

fn initialize_result() -> JsonValue {
  json.Object([
    #("protocolVersion", json.String(protocol.requested_version)),
    #("capabilities", json.Object([#("tools", json.Object([]))])),
    #(
      "serverInfo",
      json.Object([
        #("name", json.String("fake")),
        #("version", json.String("0")),
      ]),
    ),
  ])
}

fn ok(id: jsonrpc.Id, result: JsonValue) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", encode_id(id)),
    #("result", result),
  ])
}

fn failed(id: jsonrpc.Id, code: Int, message: String) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", encode_id(id)),
    #(
      "error",
      json.Object([
        #("code", json.Int(code)),
        #("message", json.String(message)),
      ]),
    ),
  ])
}

fn encode_id(id: jsonrpc.Id) -> JsonValue {
  case id {
    jsonrpc.IdInt(value:) -> json.Int(value)
    jsonrpc.IdString(value:) -> json.String(value)
  }
}
