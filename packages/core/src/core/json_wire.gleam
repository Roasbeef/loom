//// Lossless conversion between the JSON blackboard and capability values.
//// Binary values and non-text object keys are refused rather than coerced.

import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/dict
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// One JsonValue as the msgpack value the wire carries.
///
/// ## Examples
///
/// ```gleam
/// of_json(json.Null) == msgpack.NilValue
/// ```
pub fn of_json(value: JsonValue) -> MsgPackValue {
  case value {
    json.Null -> msgpack.NilValue
    json.Bool(value:) -> msgpack.BoolValue(value)
    json.Int(value:) -> msgpack.IntValue(value)
    json.Float(value:) -> msgpack.FloatValue(value)
    json.String(value:) -> msgpack.StringValue(value)
    json.Array(items:) -> msgpack.ArrayValue(list.map(items, of_json))
    json.Object(fields:) ->
      msgpack.MapValue(
        list.map(fields, fn(entry) {
          #(msgpack.StringValue(entry.0), of_json(entry.1))
        }),
      )
  }
}

/// One msgpack value as a JsonValue, or why it has no JSON form.
///
/// ## Examples
///
/// ```gleam
/// to_json(msgpack.NilValue) == Ok(json.Null)
/// ```
pub fn to_json(value: MsgPackValue) -> Result(JsonValue, String) {
  convert(value, 0)
}

/// Converts a MsgPack value to a JSON value, checking nesting depth and key constraints.
///
/// Hand-built report values have not crossed the wire decoder. Bound their
/// nesting here and reject ambiguous objects before serializing them.
fn convert(value: MsgPackValue, depth: Int) -> Result(JsonValue, String) {
  // Map MsgPack variants to their equivalent JSON representations.
  case value {
    msgpack.NilValue -> Ok(json.Null)
    msgpack.BoolValue(value:) -> Ok(json.Bool(value))
    msgpack.IntValue(value:) -> Ok(json.Int(value))
    msgpack.FloatValue(value:) -> Ok(json.Float(value))
    msgpack.StringValue(value:) -> Ok(json.String(value))
    msgpack.BinaryValue(bytes: _) ->
      Error(
        "must not hold raw bytes: the blackboard stores JSON, which has no "
        <> "binary form; send text instead",
      )
    msgpack.ArrayValue(_) | msgpack.MapValue(_) if depth >= json.max_depth ->
      Error("JSON containers exceed the maximum nesting depth")
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) { convert(item, depth + 1) })
      |> result.map(json.Array)
    msgpack.MapValue(entries:) -> {
      use Nil <- result.try(unique_keys(entries))
      list.try_map(entries, fn(entry) {
        case entry.0 {
          msgpack.StringValue(key) ->
            convert(entry.1, depth + 1) |> result.map(fn(held) { #(key, held) })
          msgpack.NilValue
          | msgpack.BoolValue(..)
          | msgpack.IntValue(..)
          | msgpack.FloatValue(..)
          | msgpack.BinaryValue(..)
          | msgpack.ArrayValue(..)
          | msgpack.MapValue(..) ->
            Error(
              "must key its objects by text: the blackboard stores JSON, "
              <> "whose object keys are always strings",
            )
        }
      })
      |> result.map(json.Object)
    }
  }
}

/// Ensures all keys in an object map are unique.
fn unique_keys(
  entries: List(#(MsgPackValue, MsgPackValue)),
) -> Result(Nil, String) {
  list.try_fold(entries, dict.new(), fn(seen, entry) {
    case dict.has_key(seen, entry.0) {
      True -> Error("JSON object keys must be unique")
      False -> Ok(dict.insert(seen, entry.0, Nil))
    }
  })
  |> result.replace(Nil)
}

// --- direct JSON object field accessors ------------------------------------

/// Looks up one member of a JSON object by `key`.
///
/// Direct value-taking function (no closure wrapper), so callers do not
/// construct higher-order decoder closures.
///
/// ## Examples
///
/// ```gleam
/// json_wire.field(json.Object([#("a", json.Int(1))]), "a") == Ok(json.Int(1))
/// ```
pub fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(members) ->
      list.key_find(members, key)
      |> result.map_error(fn(_) { "missing " <> key })
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected an object")
  }
}

/// Decodes a non-empty UTF-8 string of at most `limit` bytes.
///
/// ## Examples
///
/// ```gleam
/// json_wire.bounded_text(json.String("ok"), 16) == Ok("ok")
/// ```
pub fn bounded_text(value: JsonValue, limit: Int) -> Result(String, String) {
  case value {
    json.String(word) ->
      case word != "" && string.byte_size(word) <= limit {
        True -> Ok(word)
        False -> Error("expected nonempty bounded text")
      }
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected text")
  }
}

/// Reads a required non-empty string field of at most `limit` bytes from an
/// object.
///
/// ## Examples
///
/// ```gleam
/// json_wire.text_at(json.Object([#("k", json.String("v"))]), "k", 16) == Ok("v")
/// ```
pub fn text_at(
  value: JsonValue,
  key: String,
  limit: Int,
) -> Result(String, String) {
  use found <- result.try(field(value, key))
  bounded_text(found, limit)
  |> result.map_error(fn(reason) { key <> ": " <> reason })
}

/// Reads an optional non-empty string field of at most `limit` bytes from an
/// object, returning `None` when absent, null, or malformed.
///
/// ## Examples
///
/// ```gleam
/// json_wire.optional_text_at(json.Object([]), "k", 16) == option.None
/// ```
pub fn optional_text_at(
  value: JsonValue,
  key: String,
  limit: Int,
) -> Option(String) {
  text_at(value, key, limit) |> option.from_result
}

/// Reads a required non-negative integer field from an object.
///
/// ## Examples
///
/// ```gleam
/// json_wire.count_at(json.Object([#("n", json.Int(3))]), "n") == Ok(3)
/// ```
pub fn count_at(value: JsonValue, key: String) -> Result(Int, String) {
  use found <- result.try(field(value, key))

  // Validate that the resolved field value is a non-negative integer count.
  case found {
    json.Int(count) if count >= 0 -> Ok(count)
    json.Int(_)
    | json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(key <> " is not a count")
  }
}

/// Reads an optional non-negative integer field from an object, returning
/// `None` when absent, null, or malformed.
///
/// ## Examples
///
/// ```gleam
/// json_wire.optional_count_at(json.Object([]), "n") == option.None
/// ```
pub fn optional_count_at(value: JsonValue, key: String) -> Option(Int) {
  count_at(value, key) |> option.from_result
}
