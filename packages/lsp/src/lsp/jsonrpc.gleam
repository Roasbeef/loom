//// The JSON-RPC 2.0 envelope the language-server client speaks: requests,
//// notifications and responses as `core/json` values, with total codecs.
////
//// `lsp` carries its own envelope codec instead of importing the one in
//// `gleam_mcp`. The LSP client talks to a child process over a framed byte
//// stream and nothing else, yet `gleam_mcp` ships the whole MCP SDK in one
//// package: its HTTP server and client stacks (`mist`, `glisten`, `gun` and
//// their dependencies) come along with any import of it, and from here none
//// of them is reachable. Every package that depends on `lsp` (`tools`,
//// `codemode`, `client`) would inherit that closure in its `manifest.toml`.
//// The envelope itself is small, so a second copy costs less than the
//// dependency. ADR-015 (`docs/adr/015-language-servers-as-jailed-leases.md`)
//// records the move off `gleam_mcp` in an addendum.
////
//// The module follows the envelope codec Loom's own `packages/mcp` carried
//// before the MCP client moved into `gleam_mcp` (commit `89247eb29`): the
//// request and notification encoders and `decode` for one inbound message
//// are that codec's. The success and error response encoders did not exist
//// there; they are taken from `gleam_mcp/jsonrpc`, where #514 had added them. It owns the envelope alone. LSP's methods live in
//// `lsp/protocol`, the `Content-Length` framing in `lsp/framing`, and
//// nothing here performs I/O.
////
//// ## Flow
////
//// Outbound, `lsp/protocol` builds a `"params"` value and calls `request` or
//// `notification`; `lsp/client` serializes the result with
//// `core/json.to_string` and hands it to `lsp/framing`. Inbound,
//// `lsp/framing` yields one body as text, and `decode` settles it as exactly
//// one of three things: a `Response` to a request this client sent, a
//// `ServerRequest` the server expects an answer to, or a `Notification`.
//// A body that is not a JSON-RPC message settles as a `MessageFault` value
//// rather than a crash, and the client decides what to do with the stream.
////
//// The posture is strict on the envelope and tolerant of content. A wrong
//// or missing `"jsonrpc"`, an id that is neither an integer nor a string,
//// and a response carrying both or neither of `"result"` and `"error"` are all
//// refused. Unknown extra fields are ignored, and `"params"`, `"result"` and
//// error `"data"` are carried raw for `lsp/protocol` to interpret.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The one JSON-RPC version this module speaks, and the exact string the
/// `"jsonrpc"` field must carry on every message in both directions.
pub const version = "2.0"

/// A JSON-RPC message id. The client mints integer ids; the decoder accepts
/// both forms because the server chooses its own ids for the requests it
/// sends, and echoes ours back in whichever JSON type carried them.
///
/// Constructor invariants: none beyond the types. JSON integers are
/// arbitrary precision, so `IdInt` carries any magnitude the wire can. A
/// fractional, null or structured id never decodes into this type; it is a
/// `MessageFault` at the boundary instead.
pub type Id {
  /// An integer id, which is what this client mints.
  IdInt(value: Int)

  /// A string id, accepted from the server and echoed back verbatim.
  IdString(value: String)
}

/// The error member of a failed response: JSON-RPC's `{code, message,
/// data?}` object. `data` is carried raw and uninterpreted.
pub type RpcError {
  RpcError(code: Int, message: String, data: Option(JsonValue))
}

/// One decoded inbound message, discriminated the way JSON-RPC 2.0
/// discriminates: a `method` makes it a request (with an id) or a
/// notification (without one), and no `method` makes it a response.
pub type Inbound {
  /// A response to a request this client sent: the echoed id plus either the
  /// raw `result` value or the typed error object.
  Response(id: Id, outcome: Result(JsonValue, RpcError))

  /// A request the server sent and expects an answer to.
  ServerRequest(id: Id, method: String, params: Option(JsonValue))

  /// A notification from the server: fire and forget, no id to answer.
  Notification(method: String, params: Option(JsonValue))
}

/// Why an inbound message was refused. Both constructors are plain data. A
/// fault is the settled outcome of decoding hostile input, never a crash and
/// never a reason to kill a process.
pub type MessageFault {
  /// The text is not a single well-formed JSON document.
  MalformedMessage(report: CorruptionReport)

  /// The document parsed but is not a JSON-RPC 2.0 message. `reason` names
  /// what a well-formed one would have carried.
  BadMessage(reason: String)
}

// --- encoding --------------------------------------------------------------

/// Encodes one request. `params` is omitted from the wire entirely when
/// `None`, matching the spec's "MAY be omitted" rather than sending null.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(jsonrpc.request(jsonrpc.IdInt(1), "shutdown", None))
///   == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}"
/// ```
///
pub fn request(id: Id, method: String, params: Option(JsonValue)) -> JsonValue {
  json.Object(
    [
      #("jsonrpc", json.String(version)),
      #("id", encode_id(id)),
      #("method", json.String(method)),
    ]
    |> with_params(params),
  )
}

/// Encodes one notification: a request without an id, which the peer must
/// never answer. `params` is omitted when `None`.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(jsonrpc.notification("exit", None))
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"
/// ```
///
pub fn notification(method: String, params: Option(JsonValue)) -> JsonValue {
  json.Object(
    [#("jsonrpc", json.String(version)), #("method", json.String(method))]
    |> with_params(params),
  )
}

/// Encodes a successful response to a request the server sent.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(jsonrpc.response(jsonrpc.IdInt(3), json.Null))
///   == "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}"
/// ```
///
pub fn response(id: Id, value: JsonValue) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(version)),
    #("id", encode_id(id)),
    #("result", value),
  ])
}

/// Encodes an error response. The id is optional because JSON-RPC allows an
/// error for a request whose id could not be read; the member is then
/// omitted. `data` is omitted when `None`.
///
/// ## Examples
///
/// ```gleam
/// let error = jsonrpc.RpcError(-32601, "method not found", None)
/// assert json.to_string(jsonrpc.error_response(Some(jsonrpc.IdInt(3)), error))
///   == "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}"
/// ```
///
pub fn error_response(id: Option(Id), error: RpcError) -> JsonValue {
  let details = [
    #("code", json.Int(error.code)),
    #("message", json.String(error.message)),
  ]
  let details = case error.data {
    None -> details
    Some(data) -> list.append(details, [#("data", data)])
  }
  let fields = [#("jsonrpc", json.String(version))]
  let fields = case id {
    None -> fields
    Some(id) -> list.append(fields, [#("id", encode_id(id))])
  }

  json.Object(list.append(fields, [#("error", json.Object(details))]))
}

fn with_params(
  fields: List(#(String, JsonValue)),
  params: Option(JsonValue),
) -> List(#(String, JsonValue)) {
  case params {
    None -> fields
    Some(params) -> list.append(fields, [#("params", params)])
  }
}

fn encode_id(id: Id) -> JsonValue {
  case id {
    IdInt(value:) -> json.Int(value)
    IdString(value:) -> json.String(value)
  }
}

// --- decoding --------------------------------------------------------------

/// Decodes one inbound message, the body `lsp/framing` yielded. Total: every
/// malformed input settles as a `MessageFault` value.
///
/// A message carrying a `method` is a request or a notification, split by
/// whether an id is present. One without is a response, and must carry an id
/// and exactly one of `result` and `error`. A message carrying both a
/// `method` and a `result` or `error` fits neither shape and is refused
/// rather than guessed at. An error response whose id is `null`, which is
/// legal JSON-RPC for a request the peer could not read, is also refused: it
/// answers nothing this client can correlate, so a fault naming it is more
/// honest than a value nobody can match.
///
/// ## Examples
///
/// ```gleam
/// assert jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
///   == Ok(jsonrpc.Response(jsonrpc.IdInt(1), Ok(json.Object([]))))
/// ```
///
/// ```gleam
/// let assert Error(jsonrpc.BadMessage(_)) = jsonrpc.decode("{}")
/// ```
///
pub fn decode(text: String) -> Result(Inbound, MessageFault) {
  decode_profile(text, json.StandardJson)
}

/// Decodes the same envelope with a closed allocation profile before nodes exist.
///
/// ## Examples
/// `decode_profile(text, json.RegisteredLspJson)` shares the total JSON-RPC checks.
pub fn decode_profile(
  text: String,
  profile: json.ParseProfile,
) -> Result(Inbound, MessageFault) {
  use value <- result.try(
    json.parse_profile(text, profile)
    |> result.map_error(fn(report) { MalformedMessage(report:) }),
  )
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(BadMessage(reason: "a json object message"))
  })
  use Nil <- result.try(check_version(fields))

  case list.key_find(fields, "method") {
    Ok(method) -> decode_call(fields, method)
    Error(Nil) -> decode_response(fields)
  }
}

fn check_version(
  fields: List(#(String, JsonValue)),
) -> Result(Nil, MessageFault) {
  case list.key_find(fields, "jsonrpc") {
    Ok(json.String(found)) if found == version -> Ok(Nil)
    _ -> Error(BadMessage(reason: "a \"jsonrpc\" field carrying \"2.0\""))
  }
}

// A message with a `method` is a request when an id is present and a
// notification when it is absent. `params` is carried raw. The spec wants a
// structured value, but interpreting it is `lsp/protocol`'s job, and a
// server that sent a scalar fails there with a better-worded fault.
fn decode_call(
  fields: List(#(String, JsonValue)),
  method: JsonValue,
) -> Result(Inbound, MessageFault) {
  use method <- result.try(case method {
    json.String(method) -> Ok(method)
    _ -> Error(BadMessage(reason: "a string method name"))
  })
  use Nil <- result.try(check_no_outcome(fields))
  let params = option.from_result(list.key_find(fields, "params"))

  case list.key_find(fields, "id") {
    Error(Nil) -> Ok(Notification(method:, params:))
    Ok(id) -> {
      use id <- result.try(decode_id(id))
      Ok(ServerRequest(id:, method:, params:))
    }
  }
}

// A request or notification carrying a `result` or `error` fits neither the
// call shape nor the response shape, and refusing beats picking one.
fn check_no_outcome(
  fields: List(#(String, JsonValue)),
) -> Result(Nil, MessageFault) {
  case list.key_find(fields, "result"), list.key_find(fields, "error") {
    Error(Nil), Error(Nil) -> Ok(Nil)
    _, _ ->
      Error(BadMessage(
        reason: "no result or error on a message carrying a method",
      ))
  }
}

fn decode_response(
  fields: List(#(String, JsonValue)),
) -> Result(Inbound, MessageFault) {
  use id <- result.try(case list.key_find(fields, "id") {
    Ok(id) -> decode_id(id)
    Error(Nil) -> Error(BadMessage(reason: "an id on a response"))
  })

  case list.key_find(fields, "result"), list.key_find(fields, "error") {
    Ok(result), Error(Nil) -> Ok(Response(id:, outcome: Ok(result)))
    Error(Nil), Ok(error) -> {
      use error <- result.try(decode_error(error))
      Ok(Response(id:, outcome: Error(error)))
    }
    Ok(_), Ok(_) ->
      Error(BadMessage(reason: "exactly one of result and error, not both"))
    Error(Nil), Error(Nil) ->
      Error(BadMessage(reason: "exactly one of result and error, not neither"))
  }
}

fn decode_id(value: JsonValue) -> Result(Id, MessageFault) {
  case value {
    json.Int(id) -> Ok(IdInt(id))
    json.String(id) -> Ok(IdString(id))
    _ -> Error(BadMessage(reason: "an integer or string id"))
  }
}

fn decode_error(value: JsonValue) -> Result(RpcError, MessageFault) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(BadMessage(reason: "a json object error member"))
  })
  use code <- result.try(case list.key_find(fields, "code") {
    Ok(json.Int(code)) -> Ok(code)
    _ -> Error(BadMessage(reason: "an integer error code"))
  })
  use message <- result.try(case list.key_find(fields, "message") {
    Ok(json.String(message)) -> Ok(message)
    _ -> Error(BadMessage(reason: "a string error message"))
  })
  let data = option.from_result(list.key_find(fields, "data"))

  Ok(RpcError(code:, message:, data:))
}
