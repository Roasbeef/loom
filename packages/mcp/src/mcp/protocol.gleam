//// The Model Context Protocol messages Loom's v1 client needs, and
//// nothing more: the initialize lifecycle, `tools/list`, `tools/call`,
//// and `ping`, targeting MCP revision 2025-06-18 (the initialize-based
//// lifecycle) over the `mcp/jsonrpc` envelope.
////
//// Deliberately absent — not deferred by accident, refused for v1:
//// resources, prompts, logging, sampling, roots, elicitation, progress,
//// cancellation, completion, `listChanged` handling, and the 2026-07-28
//// stateless mode. Every omitted feature is surface a hostile server
//// could push data through; a tool-calling client needs none of it.
////
//// Builders here return the full JSON-RPC message value, ready for
//// `mcp/stdio.frame`; decoders take the raw `result` value the
//// `mcp/jsonrpc` layer already extracted from a `Response`. Every
//// decoder is total: a lying server settles as a `ProtocolFault` value,
//// never a crash. The posture is `client/protocol`'s: required
//// discriminators are strict, unknown extra fields inside known shapes
//// are ignored, and payloads this slice does not interpret (tool input
//// schemas, structured content) are carried raw.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mcp/jsonrpc.{type Id}

/// The protocol revision this client asks for in `initialize`.
pub const requested_version = "2025-06-18"

/// The protocol revisions this client can speak, newest first. A server
/// may answer `initialize` with any revision; one outside this list is an
/// `UnsupportedVersion` fault, not a connection to limp along on.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.supported_versions()
///   == ["2025-06-18", "2025-03-26", "2024-11-05"]
/// ```
///
pub fn supported_versions() -> List(String) {
  ["2025-06-18", "2025-03-26", "2024-11-05"]
}

/// Why a well-formed JSON-RPC result failed to decode as the MCP shape it
/// was supposed to carry. Plain data, never a crash.
pub type ProtocolFault {
  /// The server negotiated a protocol revision this client cannot speak.
  /// Carries both sides so the refusal can be worded without re-asking.
  UnsupportedVersion(server: String, supported: List(String))
  /// The result is not the shape the method promises; `reason` names the
  /// field (and, inside a list, the index) that broke it.
  BadResult(reason: String)
}

// --- initialize ------------------------------------------------------------

/// What the server declared about its tools in `initialize`: presence
/// means the server serves `tools/list` and `tools/call`; `list_changed`
/// is whether it will emit `notifications/tools/list_changed`. Decoded
/// faithfully, but v1 ignores `list_changed` — this client lists once per
/// connection and never subscribes.
pub type ToolsCapability {
  ToolsCapability(list_changed: Bool)
}

/// A decoded `initialize` result.
///
/// Constructor invariants: `protocol_version` is always a member of
/// `supported_versions` — the decoder refuses anything else, so no value
/// of this type names a revision the client cannot speak. `tools` is
/// `None` when the server declared no tools capability. `instructions`
/// is carried verbatim when present; whether to show it to a model is a
/// downstream trust decision, not this layer's.
pub type InitializeResult {
  InitializeResult(
    protocol_version: String,
    tools: Option(ToolsCapability),
    server_name: Option(String),
    server_version: Option(String),
    instructions: Option(String),
  )
}

/// Builds the `initialize` request that opens every MCP connection.
/// `client_version` is Loom's own version, carried in `clientInfo`.
///
/// The declared capabilities object is **deliberately empty**: this
/// client never declares `sampling` (a server must not be able to spend
/// our model), `roots` (a server learns nothing about the filesystem),
/// or `elicitation` (a server must not be able to put questions to a
/// human through us). That is a security decision from issue #106, not
/// an unfinished list — adding a capability here widens what every
/// connected server may ask of the harness.
///
/// ## Examples
///
/// ```gleam
/// // protocol.initialize_request(jsonrpc.IdInt(1), "0.1.0")
/// ```
///
pub fn initialize_request(id: Id, client_version: String) -> JsonValue {
  jsonrpc.request(
    id,
    "initialize",
    Some(
      json.Object([
        #("protocolVersion", json.String(requested_version)),
        #("capabilities", json.Object([])),
        #(
          "clientInfo",
          json.Object([
            #("name", json.String("loom")),
            #("version", json.String(client_version)),
          ]),
        ),
      ]),
    ),
  )
}

/// Decodes an `initialize` result. Total. The negotiated version must be
/// a member of `supported_versions`; `serverInfo` and `instructions` are
/// tolerated absent; the capabilities object is reduced to the one
/// question v1 asks of it — does the server declare tools, and did it
/// promise list-changed notifications.
///
/// ## Examples
///
/// ```gleam
/// // protocol.decode_initialize_result(result_value)
/// ```
///
pub fn decode_initialize_result(
  value: JsonValue,
) -> Result(InitializeResult, ProtocolFault) {
  use fields <- result.try(object_fields(value, "an initialize result object"))
  use protocol_version <- result.try(required_string(fields, "protocolVersion"))
  use Nil <- result.try(check_version(protocol_version))
  use tools <- result.try(decode_tools_capability(fields))
  use #(server_name, server_version) <- result.try(decode_server_info(fields))
  use instructions <- result.try(optional_string(fields, "instructions"))
  Ok(InitializeResult(
    protocol_version:,
    tools:,
    server_name:,
    server_version:,
    instructions:,
  ))
}

// Membership in `supported_versions` is the whole check: the list is
// newest-first for callers that rank, but acceptance is unordered.
fn check_version(server: String) -> Result(Nil, ProtocolFault) {
  case list.contains(supported_versions(), server) {
    True -> Ok(Nil)
    False -> Error(UnsupportedVersion(server:, supported: supported_versions()))
  }
}

fn decode_tools_capability(
  fields: List(#(String, JsonValue)),
) -> Result(Option(ToolsCapability), ProtocolFault) {
  case list.key_find(fields, "capabilities") {
    Error(Nil) -> Ok(None)
    Ok(capabilities) -> {
      use capability_fields <- result.try(object_fields(
        capabilities,
        "a capabilities object",
      ))
      case list.key_find(capability_fields, "tools") {
        Error(Nil) -> Ok(None)
        Ok(tools) -> {
          use tool_fields <- result.try(object_fields(
            tools,
            "a tools capability object",
          ))
          use list_changed <- result.try(defaulted_bool(
            tool_fields,
            "listChanged",
          ))
          Ok(Some(ToolsCapability(list_changed:)))
        }
      }
    }
  }
}

// `serverInfo` is optional as a whole and both of its fields are
// tolerated absent; a present field of the wrong type is still a fault.
fn decode_server_info(
  fields: List(#(String, JsonValue)),
) -> Result(#(Option(String), Option(String)), ProtocolFault) {
  case list.key_find(fields, "serverInfo") {
    Error(Nil) -> Ok(#(None, None))
    Ok(info) -> {
      use info_fields <- result.try(object_fields(info, "a serverInfo object"))
      use name <- result.try(optional_string(info_fields, "name"))
      use version <- result.try(optional_string(info_fields, "version"))
      Ok(#(name, version))
    }
  }
}

/// Builds the `notifications/initialized` notification that completes the
/// lifecycle handshake after a successful `initialize` result.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.initialized())
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
/// ```
///
pub fn initialized() -> JsonValue {
  jsonrpc.notification("notifications/initialized", None)
}

// --- tools/list ------------------------------------------------------------

/// One tool as the server lists it.
///
/// Constructor invariants: `name` is non-empty — the decoder refuses a
/// listing without one. `input_schema` and `output_schema` are carried
/// **raw**: deep JSON-Schema interpretation is a later slice's job, and
/// this layer neither validates nor normalizes them.
pub type ToolDescriptor {
  ToolDescriptor(
    name: String,
    title: Option(String),
    description: Option(String),
    input_schema: JsonValue,
    output_schema: Option(JsonValue),
  )
}

/// One page of a `tools/list` result. `next_cursor` present means the
/// server has more; feed it back into `list_tools_request`.
pub type ToolsPage {
  ToolsPage(tools: List(ToolDescriptor), next_cursor: Option(String))
}

/// Builds a `tools/list` request. `cursor` continues a paginated listing;
/// `None` asks for the first page (and omits the params entirely).
///
/// ## Examples
///
/// ```gleam
/// // protocol.list_tools_request(jsonrpc.IdInt(2), None)
/// ```
///
pub fn list_tools_request(id: Id, cursor: Option(String)) -> JsonValue {
  let params = case cursor {
    None -> None
    Some(cursor) -> Some(json.Object([#("cursor", json.String(cursor))]))
  }
  jsonrpc.request(id, "tools/list", params)
}

/// Decodes one `tools/list` result page. Total, and strict about the
/// whole list: an entry that is not an object, or whose `name` is missing
/// or empty, or whose `inputSchema` is absent, fails the **entire** page
/// with a fault naming the index — a server lying about one tool is not
/// a server to half-trust.
///
/// ## Examples
///
/// ```gleam
/// // protocol.decode_tools_page(result_value)
/// ```
///
pub fn decode_tools_page(value: JsonValue) -> Result(ToolsPage, ProtocolFault) {
  use fields <- result.try(object_fields(value, "a tools/list result object"))
  use entries <- result.try(case list.key_find(fields, "tools") {
    Ok(json.Array(entries)) -> Ok(entries)
    Ok(_) -> Error(BadResult(reason: "tools must be an array"))
    Error(Nil) -> Error(BadResult(reason: "tools is required"))
  })
  use tools <- result.try(
    list.index_map(entries, fn(entry, index) { #(index, entry) })
    |> list.try_map(fn(indexed) {
      let #(index, entry) = indexed
      decode_tool(entry, index)
    }),
  )
  use next_cursor <- result.try(optional_string(fields, "nextCursor"))
  Ok(ToolsPage(tools:, next_cursor:))
}

fn decode_tool(
  value: JsonValue,
  index: Int,
) -> Result(ToolDescriptor, ProtocolFault) {
  let at = fn(field: String) {
    "tools[" <> int.to_string(index) <> "]." <> field
  }
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ ->
      Error(BadResult(
        reason: "tools[" <> int.to_string(index) <> "] must be an object",
      ))
  })
  use name <- result.try(case list.key_find(fields, "name") {
    Ok(json.String(name)) ->
      case string.is_empty(name) {
        False -> Ok(name)
        True -> Error(BadResult(reason: at("name") <> " must be non-empty"))
      }
    _ -> Error(BadResult(reason: at("name") <> " must be a string"))
  })
  use title <- result.try(
    optional_string(fields, "title")
    |> result.map_error(fn(_) {
      BadResult(reason: at("title") <> " must be a string")
    }),
  )
  use description <- result.try(
    optional_string(fields, "description")
    |> result.map_error(fn(_) {
      BadResult(reason: at("description") <> " must be a string")
    }),
  )
  use input_schema <- result.try(case list.key_find(fields, "inputSchema") {
    Ok(schema) -> Ok(schema)
    Error(Nil) -> Error(BadResult(reason: at("inputSchema") <> " is required"))
  })
  let output_schema = option.from_result(list.key_find(fields, "outputSchema"))
  Ok(ToolDescriptor(name:, title:, description:, input_schema:, output_schema:))
}

// --- tools/call ------------------------------------------------------------

/// One block of a tool result's content. v1 keeps text and drops every
/// other payload on the floor by design — an image or resource from an
/// untrusted server is bytes the harness has no channel to carry safely
/// yet — but the *kind* survives, so a result that was mostly pictures
/// can be reported as such rather than as empty.
pub type ContentBlock {
  /// A `{type: "text"}` block's text, verbatim and untrusted.
  Text(text: String)
  /// Any other block kind (`image`, `audio`, `resource`, ...): the type
  /// name alone, payload dropped.
  Other(kind: String)
}

/// A decoded `tools/call` result.
///
/// Constructor invariants: `is_error` reads absent as `False`, per the
/// MCP schema's default — it flags a *tool-level* failure the model is
/// meant to see, distinct from a JSON-RPC error, which `mcp/jsonrpc`
/// already settled. `structured_content` is carried raw when present.
pub type CallToolResult {
  CallToolResult(
    content: List(ContentBlock),
    is_error: Bool,
    structured_content: Option(JsonValue),
  )
}

/// Builds a `tools/call` request. `arguments` is passed through raw; the
/// caller owns conformance to the tool's declared input schema.
///
/// ## Examples
///
/// ```gleam
/// // protocol.call_tool_request(jsonrpc.IdInt(3), "echo", arguments)
/// ```
///
pub fn call_tool_request(
  id: Id,
  name: String,
  arguments: JsonValue,
) -> JsonValue {
  jsonrpc.request(
    id,
    "tools/call",
    Some(
      json.Object([
        #("name", json.String(name)),
        #("arguments", arguments),
      ]),
    ),
  )
}

/// Decodes a `tools/call` result. Total. A content block whose `type` is
/// missing or not a string is a fault naming the index; unknown block
/// kinds survive as `Other` with their payload dropped.
///
/// ## Examples
///
/// ```gleam
/// // protocol.decode_call_tool_result(result_value)
/// ```
///
pub fn decode_call_tool_result(
  value: JsonValue,
) -> Result(CallToolResult, ProtocolFault) {
  use fields <- result.try(object_fields(value, "a tools/call result object"))
  use blocks <- result.try(case list.key_find(fields, "content") {
    Ok(json.Array(blocks)) -> Ok(blocks)
    Ok(_) -> Error(BadResult(reason: "content must be an array"))
    Error(Nil) -> Error(BadResult(reason: "content is required"))
  })
  use content <- result.try(
    list.index_map(blocks, fn(block, index) { #(index, block) })
    |> list.try_map(fn(indexed) {
      let #(index, block) = indexed
      decode_content_block(block, index)
    }),
  )
  use is_error <- result.try(defaulted_bool(fields, "isError"))
  let structured_content =
    option.from_result(list.key_find(fields, "structuredContent"))
  Ok(CallToolResult(content:, is_error:, structured_content:))
}

fn decode_content_block(
  value: JsonValue,
  index: Int,
) -> Result(ContentBlock, ProtocolFault) {
  let at = "content[" <> int.to_string(index) <> "]"
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(BadResult(reason: at <> " must be an object"))
  })
  use kind <- result.try(case list.key_find(fields, "type") {
    Ok(json.String(kind)) -> Ok(kind)
    _ -> Error(BadResult(reason: at <> ".type must be a string"))
  })
  case kind {
    "text" ->
      case list.key_find(fields, "text") {
        Ok(json.String(text)) -> Ok(Text(text:))
        _ -> Error(BadResult(reason: at <> ".text must be a string"))
      }
    other -> Ok(Other(kind: other))
  }
}

// --- ping ------------------------------------------------------------------

/// Builds a `ping` request; either side may send one, and the answer is
/// an empty result.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.ping_request(jsonrpc.IdInt(7)))
///   == "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}"
/// ```
///
pub fn ping_request(id: Id) -> JsonValue {
  jsonrpc.request(id, "ping", None)
}

/// Decodes a `ping` result: an object, contents ignored (the schema says
/// empty; tolerance to extra fields is the same forward-compatibility
/// every other shape gets). A non-object is still a fault.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_ping_result(json.Object([])) == Ok(Nil)
/// ```
///
pub fn decode_ping_result(value: JsonValue) -> Result(Nil, ProtocolFault) {
  use _fields <- result.try(object_fields(value, "a ping result object"))
  Ok(Nil)
}

// --- shared helpers ---------------------------------------------------------

fn object_fields(
  value: JsonValue,
  expected: String,
) -> Result(List(#(String, JsonValue)), ProtocolFault) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(BadResult(reason: expected))
  }
}

fn required_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, ProtocolFault) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) -> Error(BadResult(reason: key <> " must be a string"))
    Error(Nil) -> Error(BadResult(reason: key <> " is required"))
  }
}

fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(BadResult(reason: key <> " must be a string"))
  }
}

// Absent reads as `False` — the MCP schema's stated default for both
// `listChanged` and `isError` — but present-and-not-a-bool is a fault.
fn defaulted_bool(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Bool, ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(False)
    Ok(json.Bool(value)) -> Ok(value)
    Ok(_) -> Error(BadResult(reason: key <> " must be a boolean"))
  }
}
