//// The pure-Gleam client's view of the frozen ClientGateway protocol.
////
//// Only client-owned presentation types live here. Durable entries are
//// decoded through `core/codec`, so this client and the server share the
//// same total boundary for conversation data without importing the server
//// package or reaching behind the websocket.

import core/codec
import core/entry.{type Entry}
import core/json.{type JsonValue}
import core/message.{type Usage, type UserBlock}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// One strand from a snapshot.
pub type Strand {
  Strand(
    /// The stable wire identifier used by subsequent commands.
    id: String,
    /// The optional operator-facing strand name.
    name: Option(String),
    /// The open-set operation phase, or `None` when the strand is idle.
    live_phase: Option(String),
  )
}

/// One model catalogue row.
pub type ModelInfo {
  ModelInfo(
    /// The stable catalogue name accepted by `set_config`.
    name: String,
    /// The provider dialect that shapes model requests.
    dialect: String,
    /// The upstream provider's model identifier.
    model_id: String,
    /// The orchestration roles this model can fill.
    roles: List(String),
    /// The roles currently routed to this model.
    active: List(String),
  )
}

/// One entry attributed to its strand.
pub type EntryRecord {
  EntryRecord(
    /// The strand whose durable history owns the entry.
    strand: String,
    /// The entry decoded through the shared core codec.
    entry: Entry,
  )
}

/// One event the terminal needs to render.
pub type Event {
  /// An authoritative replacement for all client-visible session state.
  FullSnapshot(
    /// The subscribed session identifier.
    session: String,
    /// Every strand visible to this connection.
    strands: List(Strand),
    /// Durable conversation entries in replay order.
    entries: List(EntryRecord),
    /// Session usage accumulated before the live subscription began.
    usage: Usage,
  )
  /// An authoritative replacement for the visible strand set.
  StrandsSnapshot(
    /// Every strand visible to this connection.
    strands: List(Strand),
  )
  /// An authoritative replacement for the model catalogue.
  ModelsSnapshot(
    /// Every model the server exposes to this session.
    models: List(ModelInfo),
  )
  /// The active strand's effective model selection.
  ConfigSnapshot(
    /// The selected catalogue name, when one is configured.
    model_name: Option(String),
  )
  /// A newly durable entry that supersedes matching transient fragments.
  EntryAdded(
    /// The owning strand and decoded entry.
    record: EntryRecord,
  )
  /// One transient provider fragment that has not become durable yet.
  StreamDelta(
    /// The strand receiving the fragment.
    strand: String,
    /// The open-set stream kind, such as `thinking` or `text`.
    kind: String,
    /// The sanitized-later fragment bytes.
    text: String,
  )
  /// A liveness transition for one strand operation.
  OperationChanged(
    /// The strand whose operation moved.
    strand: String,
    /// The open-set display phase; `done` clears liveness.
    phase: String,
  )
  /// One usage-ledger append to add to the snapshot baseline.
  UsageChanged(
    /// The server-authoritative provider usage row.
    usage: Usage,
  )
  /// A tool action awaiting an explicit operator decision.
  EscalationPending(
    /// The escalation identifier used by a later decision command.
    id: String,
    /// The requested tool name.
    tool: String,
    /// A bounded, untrusted description of the requested action.
    preview: String,
  )
  /// A structured server refusal or request failure.
  ServerError(
    /// The stable machine-readable error code.
    code: String,
    /// The untrusted operator-facing explanation.
    message: String,
  )
  /// A forward-compatible event the current client does not render.
  Ignored(
    /// The unknown event name retained for diagnostics.
    name: String,
  )
}

/// Encodes a full-session subscription.
///
/// ## Examples
///
/// ```gleam
/// protocol.subscribe(1, "session-a")
/// ```
pub fn subscribe(id: Int, session: String) -> String {
  command(id, "subscribe", [#("session", json.String(session))])
}

/// Encodes a prompt for one strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.prompt(2, "main", "inspect the tree")
/// ```
pub fn prompt(id: Int, strand: String, text: String) -> String {
  command(id, "prompt", [
    #("strand", json.String(strand)),
    #("text", json.String(text)),
  ])
}

/// Encodes one ordered rich-content prompt for an idle strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.prompt_content(3, "main", [message.UserText("inspect", None)])
/// ```
///
pub fn prompt_content(
  id: Int,
  strand: String,
  content: List(UserBlock),
) -> String {
  command(id, "prompt_content", [
    #("strand", json.String(strand)),
    #("content", json.Array(list.map(content, codec.encode_user_block))),
  ])
}

/// Encodes an immediate steer for one live strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.steer(3, "main", "use the narrower invariant")
/// ```
pub fn steer(id: Int, strand: String, text: String) -> String {
  command(id, "steer", [
    #("strand", json.String(strand)),
    #("text", json.String(text)),
  ])
}

/// Encodes a turn queued behind one live strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.follow_up(4, "main", "review the result")
/// ```
pub fn follow_up(id: Int, strand: String, text: String) -> String {
  command(id, "follow_up", [
    #("strand", json.String(strand)),
    #("text", json.String(text)),
  ])
}

/// Encodes a model-catalogue request.
///
/// ## Examples
///
/// ```gleam
/// protocol.models(5)
/// ```
pub fn models(id: Int) -> String {
  command(id, "models", [])
}

/// Requests one strand's effective configuration without changing it.
///
/// `set_config` with an empty object is the frozen protocol's readback form:
/// the server applies no fields and replies with an authoritative config
/// snapshot.
///
/// ## Examples
///
/// ```gleam
/// protocol.config(6, "main")
/// ```
pub fn config(id: Int, strand: String) -> String {
  command(id, "set_config", [
    #("strand", json.String(strand)),
    #("config", json.Object([])),
  ])
}

/// Encodes a by-name model switch for one strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.set_model(6, "main", "baseten-kimi-k3")
/// ```
pub fn set_model(id: Int, strand: String, name: String) -> String {
  command(id, "set_config", [
    #("strand", json.String(strand)),
    #("config", json.Object([#("model_name", json.String(name))])),
  ])
}

/// Encodes an abort for one strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.abort(7, "main")
/// ```
pub fn abort(id: Int, strand: String) -> String {
  command(id, "abort", [#("strand", json.String(strand))])
}

/// Encodes a branch-scope fork of one strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.fork(8, "main", "review")
/// ```
pub fn fork(id: Int, strand: String, name: String) -> String {
  command(id, "fork", [
    #("strand", json.String(strand)),
    #("scope", json.String("branch")),
    #("name", json.String(name)),
  ])
}

/// Encodes a standalone compaction for one strand.
///
/// ## Examples
///
/// ```gleam
/// protocol.compact(9, "main")
/// ```
pub fn compact(id: Int, strand: String) -> String {
  command(id, "compact", [#("strand", json.String(strand))])
}

fn command(id: Int, name: String, body: List(#(String, JsonValue))) -> String {
  json.Object([
    #("v", json.Int(1)),
    #("id", json.Int(id)),
    #("cmd", json.String(name)),
    #("body", json.Object(body)),
  ])
  |> json.to_string
}

/// Decodes one server event without panicking on malformed input.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = protocol.decode_event("not json")
/// ```
pub fn decode_event(text: String) -> Result(Event, String) {
  use value <- result.try(
    json.parse(text)
    |> result.map_error(fn(report) { report.expected }),
  )
  use fields <- result.try(object_fields(value, "event envelope"))
  use Nil <- result.try(case list.key_find(fields, "v") {
    Ok(json.Int(1)) -> Ok(Nil)
    _ -> Error("event envelope needs v = 1")
  })
  use name <- result.try(required_string(fields, "event"))
  let body = case list.key_find(fields, "body") {
    Ok(value) -> value
    Error(Nil) -> json.Object([])
  }
  decode_body(name, body)
}

fn decode_body(name: String, body: JsonValue) -> Result(Event, String) {
  case name {
    "snapshot" -> decode_snapshot(body)
    "entry" -> result.map(decode_entry_record(body), EntryAdded)
    "stream_delta" -> decode_delta(body)
    "op_transition" -> decode_operation(body)
    "usage" -> decode_usage(body)
    "escalation" -> decode_escalation(body)
    "error" -> decode_error(body)
    other -> Ok(Ignored(other))
  }
}

fn decode_snapshot(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "snapshot body"))
  use mode <- result.try(required_string(fields, "mode"))
  case mode {
    "full" -> {
      use session <- result.try(required_string(fields, "session"))
      use strands <- result.try(decode_strands(fields))
      use entries <- result.try(decode_entries(fields))
      use usage_value <- result.try(required_value(fields, "usage"))
      use usage <- result.try(
        codec.decode_usage(usage_value)
        |> result.map_error(fn(report) { report.expected }),
      )
      Ok(FullSnapshot(session:, strands:, entries:, usage:))
    }
    "strands" -> result.map(decode_strands(fields), StrandsSnapshot)
    "models" -> result.map(decode_models(fields), ModelsSnapshot)
    "config" -> {
      use config <- result.try(required_object(fields, "config"))
      use model_name <- result.try(optional_string(config, "model_name"))
      Ok(ConfigSnapshot(model_name:))
    }
    "resume" -> Ok(Ignored("snapshot.resume"))
    other -> Ok(Ignored("snapshot." <> other))
  }
}

fn decode_entries(
  fields: List(#(String, JsonValue)),
) -> Result(List(EntryRecord), String) {
  case list.key_find(fields, "entries") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode_entry_record)
    Ok(_) -> Error("entries must be an array")
  }
}

fn decode_entry_record(value: JsonValue) -> Result(EntryRecord, String) {
  use fields <- result.try(object_fields(value, "entry body"))
  use strand <- result.try(required_string(fields, "strand"))
  use entry_value <- result.try(required_value(fields, "entry"))
  use entry <- result.try(
    codec.decode_entry(codec_entry(entry_value))
    |> result.map_error(fn(report) { report.expected }),
  )
  Ok(EntryRecord(strand:, entry:))
}

fn decode_strands(
  fields: List(#(String, JsonValue)),
) -> Result(List(Strand), String) {
  case list.key_find(fields, "strands") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode_strand)
    Ok(_) -> Error("strands must be an array")
  }
}

fn decode_strand(value: JsonValue) -> Result(Strand, String) {
  use fields <- result.try(object_fields(value, "strand"))
  use id <- result.try(required_string(fields, "id"))
  use name <- result.try(optional_string(fields, "name"))
  use live_phase <- result.try(case list.key_find(fields, "live_op") {
    Error(Nil) -> Ok(None)
    Ok(value) -> {
      use live <- result.try(object_fields(value, "live_op"))
      use phase <- result.try(required_string(live, "phase"))
      Ok(Some(phase))
    }
  })
  Ok(Strand(id:, name:, live_phase:))
}

fn decode_models(
  fields: List(#(String, JsonValue)),
) -> Result(List(ModelInfo), String) {
  case list.key_find(fields, "models") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode_model)
    Ok(_) -> Error("models must be an array")
  }
}

fn decode_model(value: JsonValue) -> Result(ModelInfo, String) {
  use fields <- result.try(object_fields(value, "model"))
  use name <- result.try(required_string(fields, "name"))
  use dialect <- result.try(required_string(fields, "dialect"))
  use model_id <- result.try(required_string(fields, "model_id"))
  use roles <- result.try(string_array(fields, "roles"))
  use active <- result.try(string_array(fields, "active"))
  Ok(ModelInfo(name:, dialect:, model_id:, roles:, active:))
}

fn decode_delta(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "stream_delta body"))
  use strand <- result.try(required_string(fields, "strand"))
  use kind <- result.try(required_string(fields, "kind"))
  use text <- result.try(optional_string(fields, "text"))
  use tool <- result.try(optional_string(fields, "tool_name"))
  use _arguments <- result.try(optional_string(fields, "arguments_fragment"))
  let content = case kind {
    // Arguments are incremental JSON fragments and are not safe or useful to
    // render until the durable tool-call entry supplies a complete value.
    "tool_call" -> option.unwrap(tool, "tool")
    _ -> option.unwrap(text, "")
  }
  Ok(StreamDelta(strand:, kind:, text: content))
}

fn decode_operation(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "op_transition body"))
  use strand <- result.try(required_string(fields, "strand"))
  use phase <- result.try(required_string(fields, "phase"))
  Ok(OperationChanged(strand:, phase:))
}

fn decode_usage(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "usage body"))
  use value <- result.try(required_value(fields, "usage"))
  use usage <- result.try(
    codec.decode_usage(value)
    |> result.map_error(fn(report) { report.expected }),
  )
  Ok(UsageChanged(usage:))
}

fn decode_escalation(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "escalation body"))
  use status <- result.try(required_string(fields, "status"))
  case status {
    "pending" -> {
      use id <- result.try(required_string(fields, "escalation_id"))
      use tool <- result.try(defaulted_string(fields, "tool"))
      use preview <- result.try(defaulted_string(fields, "preview"))
      Ok(EscalationPending(id:, tool:, preview:))
    }
    _ -> Ok(Ignored("escalation." <> status))
  }
}

fn decode_error(body: JsonValue) -> Result(Event, String) {
  use fields <- result.try(object_fields(body, "error body"))
  use code <- result.try(required_string(fields, "code"))
  use message <- result.try(required_string(fields, "message"))
  Ok(ServerError(code:, message:))
}

fn object_fields(
  value: JsonValue,
  place: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(place <> " must be an object")
  }
}

fn required_object(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(#(String, JsonValue)), String) {
  use value <- result.try(required_value(fields, key))
  object_fields(value, key)
}

fn required_value(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { key <> " is required" })
}

fn required_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) -> Error(key <> " must be a string")
    Error(Nil) -> Error(key <> " is required")
  }
}

fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.String(value)) -> Ok(Some(value))
    Ok(_) -> Error(key <> " must be a string")
  }
}

fn defaulted_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  optional_string(fields, key)
  |> result.map(option.unwrap(_, ""))
}

fn string_array(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(value) -> Ok(value)
          json.Object(..)
          | json.Array(..)
          | json.Int(..)
          | json.Float(..)
          | json.Bool(..)
          | json.Null -> Error(key <> " entries must be strings")
        }
      })
    Ok(json.Object(..))
    | Ok(json.String(..))
    | Ok(json.Int(..))
    | Ok(json.Float(..))
    | Ok(json.Bool(..))
    | Ok(json.Null) -> Error(key <> " must be an array")
  }
}

// The client wire nests tool-call bodies where the core durability codec
// keeps them inline. This is the same normalization the server protocol uses
// before asking the shared total decoder to interpret an entry.
fn codec_entry(value: JsonValue) -> JsonValue {
  map_object_field(value, "message", codec_message)
  |> map_object_field("retainedTail", fn(tail) {
    case tail {
      json.Array(items) -> json.Array(list.map(items, codec_message))
      json.Object(..)
      | json.String(..)
      | json.Int(..)
      | json.Float(..)
      | json.Bool(..)
      | json.Null -> tail
    }
  })
}

fn codec_message(value: JsonValue) -> JsonValue {
  map_object_field(value, "content", fn(content) {
    case content {
      json.Array(items) -> json.Array(list.map(items, codec_block))
      json.Object(..)
      | json.String(..)
      | json.Int(..)
      | json.Float(..)
      | json.Bool(..)
      | json.Null -> content
    }
  })
}

fn codec_block(value: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "type"), list.key_find(fields, "toolCall") {
        Ok(json.String("toolCall")), Ok(json.Object(call_fields)) ->
          json.Object([#("type", json.String("toolCall")), ..call_fields])
        _, _ -> value
      }
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> value
  }
}

fn map_object_field(
  value: JsonValue,
  key: String,
  change: fn(JsonValue) -> JsonValue,
) -> JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 == key {
            True -> #(key, change(field.1))
            False -> field
          }
        }),
      )
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> value
  }
}
