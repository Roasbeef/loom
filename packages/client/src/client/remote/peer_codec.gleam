//// The bounded JSON carried by the stable peer exchange (protocol 105).
////
//// A revision names one implemented operation, not a release. The envelope
//// carries the request correlation and serving epoch through dispatch, so a
//// replacement cannot receive a constructor selected for its predecessor.
//// The payload is data; authority remains with the receiving TopHost.

import client/remote_top
import core/json.{type JsonValue}
import gleam/list
import gleam/result
import gleam/string

/// The maximum bytes of a features request.
pub const feature_request_bytes = 4096

/// The maximum bytes of a features response.
pub const feature_reply_bytes = 16_384

/// The maximum bytes of an operation request or response.
pub const operation_bytes = 1_048_576

/// The maximum number of advertised operation revisions.
pub const max_revisions = 64

/// The operation revisions implemented by this endpoint.
pub const revisions = [
  "094.placements.1", "094.create.1", "094.sessions.1", "094.history.1",
  "094.send.1", "094.stop.1", "094.archive.1", "094.resolve.1",
]

/// One read-only observation of the peer's current incarnation.
pub type Features {
  Features(
    /// The serving daemon's current epoch, fenced again at dispatch.
    epoch: String,
    /// The serving build's reported identity, which need not be unique.
    build: String,
    /// Literal operation revisions the endpoint can dispatch.
    revisions: List(String),
  )
}

/// A decoded request and the correlation it expects echoed.
pub type Request {
  /// Read-only discovery before selecting an operation revision.
  FeaturesRequest(
    /// The correlation to echo in the response.
    id: String,
  )

  /// An operation fenced to the observed epoch and revision.
  OperationRequest(
    /// The request's reply correlation.
    id: String,
    /// The epoch returned by the preceding feature observation.
    epoch: String,
    /// The exact operation revision the caller selected.
    revision: String,
    /// Operation-specific data, decoded before invoking the host.
    body: JsonValue,
  )
}

/// A correlated peer answer, including bounded non-dispatch failures.
pub type Response {
  /// The current incarnation and its supported operations.
  FeaturesResponse(
    /// The correlation supplied by the caller.
    id: String,
    /// The current epoch, build and supported revisions.
    features: Features,
  )

  /// The existing host's successful result as JSON.
  OperationResponse(
    /// The correlation supplied by the caller.
    id: String,
    /// The completed operation's result.
    value: JsonValue,
  )

  /// The host's typed refusal, retaining its retry classification.
  RefusalResponse(
    /// The correlation supplied by the caller.
    id: String,
    /// The host's original refusal classification.
    refusal: remote_top.Refusal,
  )

  /// No operation with the requested version or revision was dispatched.
  Unsupported(
    /// The correlation supplied by the caller, when readable.
    id: String,
  )

  /// The expected epoch did not match, so no operation was dispatched.
  Stale(
    /// The correlation supplied by the caller, when readable.
    id: String,
  )

  /// The request could not be decoded, so no operation was dispatched.
  Malformed(
    /// The correlation supplied by the caller, when readable.
    id: String,
  )

  /// The request or response exceeded its applicable byte ceiling.
  Oversized(
    /// The correlation supplied by the caller, when readable.
    id: String,
  )
}

/// Why a request cannot be dispatched; none of these carries peer text.
pub type RequestError {
  /// The JSON or required fields cannot be decoded completely.
  InvalidRequest

  /// The envelope version or operation is not supported here.
  UnsupportedRequest

  /// The encoded request exceeds the applicable byte limit.
  OversizedRequest
}

/// Encodes a feature request with the caller's correlation.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.features_request("r1")
/// ```
pub fn features_request(id: String) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(1)),
      #("op", json.String("features")),
      #("request_id", json.String(id)),
    ]),
  )
}

/// Encodes a fenced operation without changing its body.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.operation_request("r1", "epoch", "094.stop.1", json.Array([]))
/// ```
pub fn operation_request(
  id: String,
  epoch: String,
  revision: String,
  body: JsonValue,
) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(1)),
      #("op", json.String("operation")),
      #("request_id", json.String(id)),
      #("epoch", json.String(epoch)),
      #("revision", json.String(revision)),
      #("body", body),
    ]),
  )
}

/// Decodes one bounded request before any operation is dispatched.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.decode_request(peer_codec.features_request("r1"))
/// ```
pub fn decode_request(text: String) -> Result(Request, RequestError) {
  use <- request_bound(text, operation_bytes)
  use value <- result.try(
    json.parse(text) |> result.replace_error(InvalidRequest),
  )
  use fields <- result.try(
    object(value) |> result.replace_error(InvalidRequest),
  )
  use version <- result.try(
    integer(fields, "v") |> result.replace_error(InvalidRequest),
  )
  use id <- result.try(
    identifier(fields, "request_id") |> result.replace_error(InvalidRequest),
  )
  use op <- result.try(
    text_field(fields, "op") |> result.replace_error(InvalidRequest),
  )

  // Features have a smaller control budget than operation payloads.
  case version, op {
    1, "features" -> {
      use <- request_bound(text, feature_request_bytes)
      Ok(FeaturesRequest(id))
    }
    1, "operation" -> {
      use epoch <- result.try(
        identifier(fields, "epoch") |> result.replace_error(InvalidRequest),
      )
      use revision <- result.try(
        identifier(fields, "revision") |> result.replace_error(InvalidRequest),
      )
      use body <- result.map(
        field(fields, "body") |> result.replace_error(InvalidRequest),
      )
      OperationRequest(id:, epoch:, revision:, body:)
    }
    _, _ -> Error(UnsupportedRequest)
  }
}

/// Serializes a response, replacing oversize output with a bounded error.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.encode_response(peer_codec.Unsupported("r1"))
/// ```
pub fn encode_response(response: Response) -> String {
  // Feature answers and operation answers have different byte ceilings.
  let #(id, kind, extra, limit) = case response {
    FeaturesResponse(id, Features(epoch:, build:, revisions:)) -> #(
      id,
      "features",
      [
        #("epoch", json.String(epoch)),
        #("build", json.String(build)),
        #("revisions", json.Array(list.map(revisions, json.String))),
      ],
      feature_reply_bytes,
    )
    OperationResponse(id, value) -> #(
      id,
      "ok",
      [#("body", value)],
      operation_bytes,
    )
    RefusalResponse(id, refusal) -> #(
      id,
      "refused",
      [#("body", encode_refusal(refusal))],
      operation_bytes,
    )
    Unsupported(id) -> #(id, "unsupported", [], feature_reply_bytes)
    Stale(id) -> #(id, "stale", [], feature_reply_bytes)
    Malformed(id) -> #(id, "malformed", [], feature_reply_bytes)
    Oversized(id) -> #(id, "oversized", [], feature_reply_bytes)
  }

  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(1)),
        #("request_id", json.String(id)),
        #("kind", json.String(kind)),
        ..extra
      ]),
    )

  // An oversize result stays an explicit error even after an effect ran.
  case string.byte_size(text) <= limit {
    True -> text
    False ->
      json.to_string(
        json.Object([
          #("v", json.Int(1)),
          #("request_id", json.String(id)),
          #("kind", json.String("oversized")),
        ]),
      )
  }
}

/// Decodes a response and verifies that it belongs to the request.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.decode_response(text, "r1", peer_codec.feature_reply_bytes)
/// ```
pub fn decode_response(
  text: String,
  expected: String,
  limit: Int,
) -> Result(Response, String) {
  use <- bounded(text, limit)
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid JSON"),
  )
  use fields <- result.try(object(value))
  use version <- result.try(integer(fields, "v"))
  use id <- result.try(identifier(fields, "request_id"))
  use kind <- result.try(text_field(fields, "kind"))

  // A response for another request cannot authorize this operation.
  case version == 1 && id == expected {
    False -> Error("reply version or correlation does not match")
    True -> decode_response_kind(fields, id, kind)
  }
}

/// Decodes each response shape without accepting an unknown kind as success.
fn decode_response_kind(
  fields: List(#(String, JsonValue)),
  id: String,
  kind: String,
) -> Result(Response, String) {
  // Each response kind has its own complete shape; unknown kinds are errors.
  case kind {
    "features" -> {
      use epoch <- result.try(identifier(fields, "epoch"))
      use build <- result.try(identifier(fields, "build"))
      use value <- result.try(field(fields, "revisions"))
      use revisions <- result.try(strings(value))

      // Bound the advertised list before trusting it for revision selection.
      case list.length(revisions) <= max_revisions {
        True -> Ok(FeaturesResponse(id, Features(epoch:, build:, revisions:)))
        False -> Error("too many revisions")
      }
    }
    "ok" ->
      field(fields, "body")
      |> result.map(fn(value) { OperationResponse(id, value) })
    "refused" -> {
      use body <- result.try(field(fields, "body"))
      use refusal <- result.map(decode_refusal(body))
      RefusalResponse(id, refusal)
    }
    "unsupported" -> Ok(Unsupported(id))
    "stale" -> Ok(Stale(id))
    "malformed" -> Ok(Malformed(id))
    "oversized" -> Ok(Oversized(id))
    _ -> Error("unknown reply kind")
  }
}

/// Reads an object without guessing values missing from it.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected object")
  }
}

/// Reads one required JSON field.
fn field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, key) |> result.replace_error("missing field")
}

/// Reads a required text field.
fn text_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  use value <- result.try(field(fields, key))

  // Missing or nontext fields cannot become empty strings.
  case value {
    json.String(text) -> Ok(text)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected text")
  }
}

/// Reads a required integer field.
fn integer(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  use value <- result.try(field(fields, key))

  // Numeric fields must retain their integral representation.
  case value {
    json.Int(number) -> Ok(number)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected integer")
  }
}

/// Keeps correlation, epoch and revision text bounded before echoing it.
fn identifier(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  use text <- result.try(text_field(fields, key))

  // Bounded identifiers keep even rejection replies bounded.
  case string.byte_size(text) > 0 && string.byte_size(text) <= 256 {
    True -> Ok(text)
    False -> Error("invalid identifier")
  }
}

/// Enforces the request ceiling without a string-based failure classifier.
fn request_bound(
  text: String,
  limit: Int,
  then: fn() -> Result(a, RequestError),
) -> Result(a, RequestError) {
  case string.byte_size(text) <= limit {
    True -> then()
    False -> Error(OversizedRequest)
  }
}

/// Refuses oversize text before parsing.
fn bounded(
  text: String,
  limit: Int,
  then: fn() -> Result(a, String),
) -> Result(a, String) {
  case string.byte_size(text) <= limit {
    True -> then()
    False -> Error("oversized")
  }
}

/// Decodes a bounded revision list as nonempty text.
fn strings(value: JsonValue) -> Result(List(String), String) {
  case value {
    json.Array(items) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(text) ->
            case string.byte_size(text) > 0 && string.byte_size(text) <= 256 {
              True -> Ok(text)
              False -> Error("invalid revision")
            }
          json.Object(_)
          | json.Array(_)
          | json.Int(_)
          | json.Float(_)
          | json.Bool(_)
          | json.Null -> Error("invalid revision")
        }
      })
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected revision list")
  }
}

/// Encodes an existing refusal so its retry classification survives the wire.
fn encode_refusal(refusal: remote_top.Refusal) -> JsonValue {
  // Preserve the refusal variant that controls the sender's retry policy.
  let #(kind, value, number) = case refusal {
    remote_top.UnknownSpawner(node) -> #("unknown_spawner", node, 0)
    remote_top.TopLevelOff -> #("top_level_off", "", 0)
    remote_top.NotOffered(what, name) -> #(
      "not_offered",
      offered_word(what) <> ":" <> name,
      0,
    )
    remote_top.CapReached(cap, limit) -> #("cap_reached", cap_word(cap), limit)
    remote_top.NotRelayed -> #("not_relayed", "", 0)
    remote_top.InvalidArgument(reason) -> #("invalid_argument", reason, 0)
    remote_top.NotYetOpen(reason) -> #("not_yet_open", reason, 0)
    remote_top.StoreFailure(reason) -> #("store_failure", reason, 0)
  }

  json.Array([json.String(kind), json.String(value), json.Int(number)])
}

/// Reads the same closed refusal variants the receiving host can return.
fn decode_refusal(value: JsonValue) -> Result(remote_top.Refusal, String) {
  // An unknown refusal is unreadable, never a conclusive rejection.
  case value {
    json.Array([json.String("unknown_spawner"), json.String(node), json.Int(0)]) ->
      Ok(remote_top.UnknownSpawner(node))
    json.Array([json.String("top_level_off"), json.String(""), json.Int(0)]) ->
      Ok(remote_top.TopLevelOff)
    json.Array([json.String("not_relayed"), json.String(""), json.Int(0)]) ->
      Ok(remote_top.NotRelayed)
    json.Array([
      json.String("invalid_argument"),
      json.String(reason),
      json.Int(0),
    ]) -> Ok(remote_top.InvalidArgument(reason))
    json.Array([json.String("not_yet_open"), json.String(reason), json.Int(0)]) ->
      Ok(remote_top.NotYetOpen(reason))
    json.Array([json.String("store_failure"), json.String(reason), json.Int(0)]) ->
      Ok(remote_top.StoreFailure(reason))
    json.Array([json.String("cap_reached"), json.String(cap), json.Int(limit)]) ->
      cap_of(cap) |> result.map(fn(cap) { remote_top.CapReached(cap, limit) })
    json.Array([json.String("not_offered"), json.String(what), json.Int(0)]) -> {
      use #(kind, name) <- result.try(
        string.split_once(what, ":") |> result.replace_error("invalid offer"),
      )
      use kind <- result.map(offered_of(kind))
      remote_top.NotOffered(kind, name)
    }
    json.Array(_)
    | json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid refusal")
  }
}

fn cap_word(cap: remote_top.Cap) -> String {
  case cap {
    remote_top.MaxSessions -> "sessions"
    remote_top.MaxPerHour -> "hour"
  }
}

/// Recognizes only the two caps the existing host enforces.
fn cap_of(word: String) -> Result(remote_top.Cap, String) {
  case word {
    "sessions" -> Ok(remote_top.MaxSessions)
    "hour" -> Ok(remote_top.MaxPerHour)
    _ -> Error("invalid cap")
  }
}

/// Preserves which offered resource the host refused.
fn offered_word(what: remote_top.Offered) -> String {
  case what {
    remote_top.OfferedFolder -> "folder"
    remote_top.OfferedExecutor -> "executor"
    remote_top.OfferedPool -> "pool"
    remote_top.OfferedProfile -> "profile"
    remote_top.OfferedModel -> "model"
  }
}

/// Rejects unknown offer categories instead of inventing one.
fn offered_of(word: String) -> Result(remote_top.Offered, String) {
  case word {
    "folder" -> Ok(remote_top.OfferedFolder)
    "executor" -> Ok(remote_top.OfferedExecutor)
    "pool" -> Ok(remote_top.OfferedPool)
    "profile" -> Ok(remote_top.OfferedProfile)
    "model" -> Ok(remote_top.OfferedModel)
    _ -> Error("invalid offer")
  }
}

/// Extracts a valid correlation for a bounded refusal, when the request has one.
///
/// ## Examples
///
/// ```gleam
/// // peer_codec.request_id(peer_codec.features_request("r1")) == "r1"
/// ```
pub fn request_id(text: String) -> String {
  let read = {
    use <- bounded(text, operation_bytes)
    use value <- result.try(
      json.parse(text) |> result.replace_error("invalid JSON"),
    )
    use fields <- result.try(object(value))
    identifier(fields, "request_id")
  }
  result.unwrap(read, "")
}
