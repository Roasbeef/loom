//// The orchestration and notes routers share core's JSON value conversion.
//// Keeping this forwarding boundary preserves their internal imports while
//// report helpers in the satellite use the same conversion rules.

import core/json.{type JsonValue}
import core/json_wire
import core/msgpack.{type MsgPackValue}

/// Converts a stored JSON value to the wire representation.
///
/// ## Examples
///
/// ```gleam
/// of_json(json.Null) == msgpack.NilValue
/// ```
pub fn of_json(value: JsonValue) -> MsgPackValue {
  json_wire.of_json(value)
}

/// Refuses values that JSON cannot represent without losing information.
///
/// ## Examples
///
/// ```gleam
/// to_json(msgpack.NilValue) == Ok(json.Null)
/// ```
pub fn to_json(value: MsgPackValue) -> Result(JsonValue, String) {
  json_wire.to_json(value)
}
