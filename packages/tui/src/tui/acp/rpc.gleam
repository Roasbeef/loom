//// JSON-RPC 2.0 frames for the Agent Client Protocol's stdio transport.
////
//// ACP is JSON-RPC 2.0 with one frame per line on standard input and output.
//// The peer on the other end is another program's code, not Loom's, so this
//// module is the closed boundary the issue asks for: every line is decoded
//// exactly once into one of three variants, or refused with the error
//// object JSON-RPC prescribes for that failure. Nothing past this module
//// ever sees raw JSON text, and nothing in it can crash the process, because
//// a protocol mismatch must fail the exchange and never the daemon client.
////
//// The module knows nothing about ACP's methods. It answers *is this a
//// well-formed request, notification or response, and what is its id*; the
//// next layer (`tui/acp/schema`) answers whether the params of a method are
//// well formed. Keeping the split means a frame that is not even JSON-RPC
//// gets `-32700` or `-32600` here, a known frame with bad params gets
//// `-32602` there, and an unknown method gets `-32601` from the server, each
//// from exactly one place.
////
//// ## Flow
////
//// `decode` → `classify` → `request_id`
////
//// 1. `decode` bounds the line, parses it with the core JSON parser (which
////    is itself total) and insists on one object.
//// 2. `classify` reads the version marker and decides whether the object is
////    a call, a notification or a reply by which of the method, id, result
////    and error members it carries.
//// 3. `request_id` admits only a string or an integer id, the two forms
////    ACP's schema uses, so an id that cannot be echoed back is refused
////    instead of being mangled on the way out.
////
//// The `encode_*` functions are the only writers: each produces a complete
//// frame without its terminating newline, which the transport adds.

import core/json.{type JsonValue}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The most bytes one frame may carry before it is refused unread by the
/// decoder. Four mebibytes admits a prompt with a few embedded screenshots
/// and nothing a hostile peer could use to make the client buffer without
/// limit.
pub const max_frame_bytes = 4_194_304

/// JSON-RPC: the line was not JSON.
pub const parse_error = -32_700

/// JSON-RPC: the JSON was not a request, notification or response.
pub const invalid_request = -32_600

/// JSON-RPC: the method does not exist or is not offered.
pub const method_not_found = -32_601

/// JSON-RPC: the method exists but its params are wrong.
pub const invalid_params = -32_602

/// JSON-RPC: the method was understood and the server could not finish it.
pub const internal_error = -32_603

/// ACP: the request needs a credential the client has not supplied.
pub const auth_required = -32_000

/// ACP: the named resource, here a session, does not exist.
pub const resource_not_found = -32_002

/// The identity a request carries, echoed byte for byte in its response.
pub type Id {
  /// An integer id, which is what every ACP client implementation sends.
  NumberId(value: Int)

  /// A string id, which JSON-RPC allows and ACP does not forbid.
  TextId(value: String)
}

/// A JSON-RPC error object.
pub type WireError {
  WireError(
    /// The numeric class, one of the constants above or an ACP extension.
    code: Int,
    /// A short sentence for a person reading a log. Never a credential.
    message: String,
    /// Structured detail the peer may use, when there is any.
    data: Option(JsonValue),
  )
}

/// One decoded line.
pub type Inbound {
  /// A request the peer expects exactly one response to.
  Call(
    /// The id the response must carry.
    id: Id,
    /// The method name, not yet checked against ACP's set.
    method: String,
    /// The params object; `{}` when the frame carried none.
    params: JsonValue,
  )

  /// A notification: no id, no response, and no way to refuse it.
  Notification(
    /// The method name, not yet checked against ACP's set.
    method: String,
    /// The params object; `{}` when the frame carried none.
    params: JsonValue,
  )

  /// The peer's answer to a request this side sent.
  Reply(
    /// The id of the request being answered.
    id: Id,
    /// The result, or the error object the peer returned.
    outcome: Result(JsonValue, WireError),
  )
}

/// A line that could not be decoded, and the response owed for it.
pub type Refusal {
  Refusal(
    /// The id to answer under, when the frame was well formed enough to
    /// carry one. `None` encodes as `null`, as the specification requires
    /// when the id cannot be determined.
    id: Option(Id),
    /// The error object to send.
    error: WireError,
  )
}

/// Decodes one line of standard input.
///
/// ## Examples
///
/// ```gleam
/// let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"
/// let assert Ok(rpc.Call(id: rpc.NumberId(1), method: "initialize", ..)) =
///   rpc.decode(line)
/// ```
///
/// ```gleam
/// let assert Error(rpc.Refusal(id: None, error:)) = rpc.decode("[]")
/// assert error.code == rpc.invalid_request
/// ```
pub fn decode(line: String) -> Result(Inbound, Refusal) {
  // The bound is checked on the bytes before any parsing, so an oversized
  // line costs a size comparison and no allocation proportional to it.
  case string.byte_size(line) > max_frame_bytes {
    True -> Error(refuse(None, invalid_request, "frame exceeds the size limit"))
    False -> parse_line(line)
  }
}

/// Parses a bounded line into one JSON object and hands it to `classify`.
fn parse_line(line: String) -> Result(Inbound, Refusal) {
  case json.parse(line) {
    Error(_) -> Error(refuse(None, parse_error, "the frame is not valid JSON"))
    Ok(json.Object(fields)) -> classify(fields)
    Ok(_) ->
      Error(refuse(None, invalid_request, "a frame must be a JSON object"))
  }
}

/// Decides which of the three frame shapes an object is, by the members it carries.
///
/// A response carries `result` or `error` and never `method`; a request
/// carries `method`, and an `id` is what separates a call from a
/// notification. The id is read first so that every later refusal can be
/// addressed to the sender when the id is usable.
fn classify(fields: List(#(String, JsonValue))) -> Result(Inbound, Refusal) {
  let id = request_id(fields)
  let addressed = option.from_result(id) |> option.flatten

  // The version marker comes first: a frame that is not JSON-RPC 2.0 is
  // refused under its own id when it has a usable one.
  use <- bool.lazy_guard(
    list.key_find(fields, "jsonrpc") != Ok(json.String("2.0")),
    fn() {
      Error(refuse(addressed, invalid_request, "jsonrpc must be \"2.0\""))
    },
  )
  use id <- result.try(
    result.map_error(id, fn(_) {
      refuse(None, invalid_request, "id must be a string or an integer")
    }),
  )

  // The members present decide the shape; a frame that fits none is refused.
  case
    list.key_find(fields, "method"),
    list.key_find(fields, "result"),
    list.key_find(fields, "error")
  {
    Ok(json.String(method)), Error(Nil), Error(Nil) ->
      call_or_notification(id, method, fields)
    Ok(_), _, _ -> Error(refuse(id, invalid_request, "method must be a string"))
    Error(Nil), Ok(value), Error(Nil) -> reply(id, Ok(value))
    Error(Nil), Error(Nil), Ok(error) -> reply_error(id, error)
    Error(Nil), _, _ ->
      Error(refuse(id, invalid_request, "not a request or a response"))
  }
}

/// Reads the optional `id` member: `Ok(None)` when absent, `Error` when present but unusable.
fn request_id(fields: List(#(String, JsonValue))) -> Result(Option(Id), Nil) {
  case list.key_find(fields, "id") {
    Error(Nil) -> Ok(None)
    Ok(json.Int(value)) -> Ok(Some(NumberId(value)))
    Ok(json.String(value)) -> Ok(Some(TextId(value)))
    Ok(_) -> Error(Nil)
  }
}

/// Builds a call or a notification, enforcing that params are an object.
fn call_or_notification(
  id: Option(Id),
  method: String,
  fields: List(#(String, JsonValue)),
) -> Result(Inbound, Refusal) {
  // A missing params member means no arguments, which ACP spells `{}`.
  let params = list.key_find(fields, "params") |> result.unwrap(json.Object([]))

  // ACP's params are always objects; positional arrays are not part of it.
  case params, id {
    json.Object(_), Some(id) -> Ok(Call(id, method, params))
    json.Object(_), None -> Ok(Notification(method, params))
    _, _ -> Error(refuse(id, invalid_params, "params must be an object"))
  }
}

/// Builds a successful reply, which must name the request it answers.
fn reply(
  id: Option(Id),
  outcome: Result(JsonValue, WireError),
) -> Result(Inbound, Refusal) {
  case id {
    Some(id) -> Ok(Reply(id, outcome))
    None -> Error(refuse(None, invalid_request, "a response needs an id"))
  }
}

/// Builds an error reply from the peer's error object, refusing a malformed one.
fn reply_error(id: Option(Id), error: JsonValue) -> Result(Inbound, Refusal) {
  case error {
    json.Object(members) ->
      case list.key_find(members, "code"), list.key_find(members, "message") {
        Ok(json.Int(code)), Ok(json.String(message)) ->
          reply(id, Error(WireError(code, message, option_of(members, "data"))))
        _, _ ->
          Error(refuse(id, invalid_request, "error needs a code and message"))
      }
    _ -> Error(refuse(id, invalid_request, "error must be an object"))
  }
}

/// Reads an optional member as an `Option`.
fn option_of(
  members: List(#(String, JsonValue)),
  name: String,
) -> Option(JsonValue) {
  list.key_find(members, name) |> option.from_result
}

/// Builds the refusal for a frame, addressed to `id` when it has one.
fn refuse(id: Option(Id), code: Int, message: String) -> Refusal {
  Refusal(id, WireError(code, message, None))
}

/// Encodes a successful response.
///
/// ## Examples
///
/// ```gleam
/// assert rpc.encode_result(rpc.NumberId(1), json.Object([]))
///   == "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
/// ```
pub fn encode_result(id: Id, result: JsonValue) -> String {
  json.Object([
    #("jsonrpc", json.String("2.0")),
    #("id", id_json(id)),
    #("result", result),
  ])
  |> json.to_string
}

/// Encodes an error response. A `None` id encodes as `null`.
///
/// ## Examples
///
/// ```gleam
/// let error = rpc.WireError(rpc.method_not_found, "no such method", None)
/// assert rpc.encode_error(Some(rpc.NumberId(2)), error)
///   == "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}"
/// ```
pub fn encode_error(id: Option(Id), error: WireError) -> String {
  // The `data` member is written only when the error carries some.
  let data = case error.data {
    Some(value) -> [#("data", value)]
    None -> []
  }

  let body =
    json.Object([
      #("code", json.Int(error.code)),
      #("message", json.String(error.message)),
      ..data
    ])

  json.Object([
    #("jsonrpc", json.String("2.0")),
    #("id", option.map(id, id_json) |> option.unwrap(json.Null)),
    #("error", body),
  ])
  |> json.to_string
}

/// Encodes a request this side sends to the peer.
///
/// ## Examples
///
/// ```gleam
/// assert rpc.encode_request(rpc.NumberId(7), "session/request_permission", json.Object([]))
///   == "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/request_permission\",\"params\":{}}"
/// ```
pub fn encode_request(id: Id, method: String, params: JsonValue) -> String {
  json.Object([
    #("jsonrpc", json.String("2.0")),
    #("id", id_json(id)),
    #("method", json.String(method)),
    #("params", params),
  ])
  |> json.to_string
}

/// Encodes a notification this side sends to the peer.
///
/// ## Examples
///
/// ```gleam
/// assert rpc.encode_notification("session/update", json.Object([]))
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}"
/// ```
pub fn encode_notification(method: String, params: JsonValue) -> String {
  json.Object([
    #("jsonrpc", json.String("2.0")),
    #("method", json.String(method)),
    #("params", params),
  ])
  |> json.to_string
}

/// The JSON form of an id.
fn id_json(id: Id) -> JsonValue {
  case id {
    NumberId(value) -> json.Int(value)
    TextId(value) -> json.String(value)
  }
}

/// A server-side error with no structured data, for the layers above.
///
/// ## Examples
///
/// ```gleam
/// assert rpc.error(rpc.invalid_params, "x") == rpc.WireError(-32602, "x", None)
/// ```
pub fn error(code: Int, message: String) -> WireError {
  WireError(code, message, None)
}
