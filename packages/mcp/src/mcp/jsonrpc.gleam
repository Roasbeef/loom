//// JSON-RPC 2.0 over `core/json.JsonValue`: the framing vocabulary the
//// Model Context Protocol speaks, as pure values with total codecs.
////
//// This module knows nothing about MCP's methods — it owns the envelope
//// alone: what a request, a notification, and a response look like on the
//// wire, and how one inbound message settles into a typed `Inbound` or a
//// `MessageFault` value. The MCP-specific shapes live in `mcp/protocol`,
//// and line framing in `mcp/stdio`; nothing in this package performs I/O.
////
//// The posture follows `client/protocol`: the **envelope is strict** — a
//// wrong or missing `"jsonrpc"`, an id that is neither an integer nor a
//// string, a response carrying both `result` and `error` (or neither) are
//// all refused as fault values — while **content is tolerant**: unknown
//// extra fields inside a known shape are ignored, and `params`, `result`
//// and error `data` are carried raw for the layer above to interpret.
//// Every decoder is total: hostile input settles as a `MessageFault`,
//// never a crash.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The one JSON-RPC version this module speaks, and the exact string the
/// `"jsonrpc"` field must carry on every message in both directions.
pub const version = "2.0"

/// A JSON-RPC message id. We mint integer ids; the decoder accepts both
/// forms because the peer chooses its own ids for server-initiated
/// requests, and echoes ours back in whichever JSON type carried them.
///
/// Constructor invariants: none beyond the types — JSON integers are
/// arbitrary precision, so `IdInt` carries any magnitude the wire can.
/// A fractional, null, or structured id never decodes into this type;
/// it is a `MessageFault` at the boundary instead.
pub type Id {
  /// An integer id (what this client mints).
  IdInt(value: Int)

  /// A string id (accepted from the peer, echoed back verbatim).
  IdString(value: String)
}

/// The error member of a failed response: JSON-RPC's `{code, message,
/// data?}` object. `data` is carried raw and uninterpreted.
pub type RpcError {
  RpcError(code: Int, message: String, data: Option(JsonValue))
}

/// One decoded inbound message, discriminated the way JSON-RPC 2.0
/// discriminates: a `method` makes it a request (with an id) or a
/// notification (without one); no `method` makes it a response.
pub type Inbound {
  /// A response to a request we sent: the echoed id plus either the raw
  /// `result` value or the typed error object.
  Response(id: Id, outcome: Result(JsonValue, RpcError))

  /// A server-initiated request. This client answers method-not-found in
  /// a later slice, but the envelope decodes today so nothing hostile can
  /// hide inside one.
  ServerRequest(id: Id, method: String, params: Option(JsonValue))

  /// A server-initiated notification: fire and forget, no id to answer.
  Notification(method: String, params: Option(JsonValue))
}

/// Why an inbound message was refused. Both constructors are plain data:
/// a fault is the settled outcome of decoding hostile input, never a
/// crash and never a reason to kill a connection process.
pub type MessageFault {
  /// The text is not a single well-formed JSON document.
  MalformedMessage(report: CorruptionReport)

  /// The document parsed but is not a JSON-RPC 2.0 message; `reason`
  /// names what a well-formed one would have carried.
  BadMessage(reason: String)
}

// --- encoding --------------------------------------------------------------

/// Encodes one request. `params` is omitted from the wire entirely when
/// `None`, matching the spec's "MAY be omitted" rather than sending null.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(jsonrpc.request(jsonrpc.IdInt(1), "ping", None))
///   == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
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
/// assert json.to_string(jsonrpc.notification("notifications/initialized", None))
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
/// ```
///
pub fn notification(method: String, params: Option(JsonValue)) -> JsonValue {
  json.Object(
    [#("jsonrpc", json.String(version)), #("method", json.String(method))]
    |> with_params(params),
  )
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

/// Decodes one inbound message (one line of the stdio transport). Total:
/// every malformed input settles as a `MessageFault` value.
///
/// A message carrying a `method` is a request or a notification, split by
/// whether an id is present; one without is a response and must carry an
/// id and exactly one of `result` and `error`. A message carrying both a
/// `method` and a `result`/`error` fits neither shape and is refused
/// rather than guessed at. An error response whose id is `null` — legal
/// JSON-RPC for a request the peer could not read — is also refused: it
/// answers nothing we can correlate, so a fault naming it is the more
/// honest outcome than an uncorrelatable value.
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
  use value <- result.try(
    json.parse(text)
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

// A message with a `method`: a request when an id is present, a
// notification when it is absent. `params` is carried raw — the spec says
// structured value, but interpreting it is the layer above's job and a
// server that sent a scalar will fail there with a better-worded fault.
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

// A request or notification carrying a `result` or `error` fits neither
// the call shape nor the response shape; refusing beats picking one.
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
