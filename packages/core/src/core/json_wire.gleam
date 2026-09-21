//// Lossless conversion between the JSON blackboard and capability values.
//// Binary values and non-text object keys are refused rather than coerced.

import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/dict
import gleam/list
import gleam/result

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

// Hand-built report values have not crossed the wire decoder. Bound their
// nesting here and reject ambiguous objects before serializing them.
fn convert(value: MsgPackValue, depth: Int) -> Result(JsonValue, String) {
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
