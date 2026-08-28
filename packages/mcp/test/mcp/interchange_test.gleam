import core/json
import core/msgpack
import mcp/interchange

// --- msgpack out to JSON --------------------------------------------------

pub fn scalars_cross_to_json_test() {
  assert interchange.to_json(msgpack.NilValue) == Ok(json.Null)
  assert interchange.to_json(msgpack.BoolValue(True)) == Ok(json.Bool(True))
  assert interchange.to_json(msgpack.IntValue(-7)) == Ok(json.Int(-7))
  assert interchange.to_json(msgpack.FloatValue(1.5)) == Ok(json.Float(1.5))
  assert interchange.to_json(msgpack.StringValue("hi")) == Ok(json.String("hi"))
}

pub fn a_msgpack_integer_always_fits_json_test() {
  // The largest thing msgpack can carry still crosses: `core/json.Int` is
  // arbitrary precision, so this direction has no range to refuse.
  assert interchange.to_json(msgpack.IntValue(interchange.max_msgpack_int))
    == Ok(json.Int(interchange.max_msgpack_int))
}

pub fn containers_cross_to_json_test() {
  let value =
    msgpack.MapValue([
      #(msgpack.StringValue("query"), msgpack.StringValue("loom")),
      #(
        msgpack.StringValue("limits"),
        msgpack.ArrayValue([msgpack.IntValue(1), msgpack.NilValue]),
      ),
    ])
  assert interchange.to_json(value)
    == Ok(
      json.Object([
        #("query", json.String("loom")),
        #("limits", json.Array([json.Int(1), json.Null])),
      ]),
    )
}

pub fn a_binary_argument_is_refused_test() {
  let value =
    msgpack.MapValue([
      #(msgpack.StringValue("blob"), msgpack.BinaryValue(<<1, 2>>)),
    ])
  assert interchange.to_json(value)
    == Error(interchange.NotJson(at: "$.blob", what: "a byte string"))
}

pub fn a_non_string_map_key_is_refused_test() {
  let value = msgpack.MapValue([#(msgpack.IntValue(1), msgpack.NilValue)])
  let assert Error(interchange.NotJson(at:, what: _)) =
    interchange.to_json(value)
    as "an integer-keyed map has no JSON object to become"
  assert at == interchange.root_path
}

// --- JSON back to msgpack -------------------------------------------------

pub fn scalars_cross_to_msgpack_test() {
  assert interchange.to_msgpack(json.Null) == Ok(msgpack.NilValue)
  assert interchange.to_msgpack(json.Bool(False))
    == Ok(msgpack.BoolValue(False))
  assert interchange.to_msgpack(json.Int(7)) == Ok(msgpack.IntValue(7))
  assert interchange.to_msgpack(json.Float(0.25))
    == Ok(msgpack.FloatValue(0.25))
  assert interchange.to_msgpack(json.String("ok"))
    == Ok(msgpack.StringValue("ok"))
}

pub fn containers_cross_to_msgpack_test() {
  let value =
    json.Object([
      #("items", json.Array([json.String("a"), json.Bool(True)])),
    ])
  assert interchange.to_msgpack(value)
    == Ok(
      msgpack.MapValue([
        #(
          msgpack.StringValue("items"),
          msgpack.ArrayValue([
            msgpack.StringValue("a"),
            msgpack.BoolValue(True),
          ]),
        ),
      ]),
    )
}

pub fn the_msgpack_integer_bounds_are_inclusive_test() {
  assert interchange.to_msgpack(json.Int(interchange.max_msgpack_int))
    == Ok(msgpack.IntValue(interchange.max_msgpack_int))
  assert interchange.to_msgpack(json.Int(interchange.min_msgpack_int))
    == Ok(msgpack.IntValue(interchange.min_msgpack_int))
}

/// The bounds this module restates are the encoder's own. `core/msgpack`
/// is where an integer is actually accepted or refused, and these two
/// constants are a copy of its range written down somewhere else — so
/// the copy is bound to the original here rather than left to be true by
/// having once been read correctly. Gleam integers are arbitrary
/// precision, which is exactly why the copy can be wrong without anything
/// noticing: `max + 1` is a perfectly ordinary `IntValue` to build.
pub fn the_restated_bounds_are_the_encoders_own_test() {
  let assert Ok(_max) =
    msgpack.encode(msgpack.IntValue(interchange.max_msgpack_int))
    as "the largest integer this module admits must encode"
  let assert Ok(_min) =
    msgpack.encode(msgpack.IntValue(interchange.min_msgpack_int))
    as "the smallest integer this module admits must encode"

  assert msgpack.encode(msgpack.IntValue(interchange.max_msgpack_int + 1))
    == Error(msgpack.IntegerOutOfRange(value: interchange.max_msgpack_int + 1))
  assert msgpack.encode(msgpack.IntValue(interchange.min_msgpack_int - 1))
    == Error(msgpack.IntegerOutOfRange(value: interchange.min_msgpack_int - 1))
}

pub fn an_out_of_range_integer_fails_the_whole_result_test() {
  // Never wrapped, never clamped, never turned into a float: the whole
  // conversion refuses, and the path names the field that did it.
  let value =
    json.Object([
      #("ok", json.String("kept")),
      #("count", json.Int(interchange.max_msgpack_int + 1)),
    ])
  assert interchange.to_msgpack(value)
    == Error(interchange.NotMsgpack(
      at: "$.count",
      what: "an integer outside msgpack's range",
    ))

  assert interchange.to_msgpack(json.Int(interchange.min_msgpack_int - 1))
    == Error(interchange.NotMsgpack(
      at: interchange.root_path,
      what: "an integer outside msgpack's range",
    ))
}

pub fn a_refusal_names_an_indexed_path_test() {
  let value =
    json.Object([
      #(
        "rows",
        json.Array([json.Int(0), json.Int(interchange.max_msgpack_int + 1)]),
      ),
    ])
  let assert Error(fault) = interchange.to_msgpack(value)
    as "the second row is out of range"
  assert fault
    == interchange.NotMsgpack(
      at: "$.rows[1]",
      what: "an integer outside msgpack's range",
    )
}

pub fn a_round_trip_preserves_a_json_shaped_value_test() {
  let value =
    json.Object([
      #("a", json.Array([json.Int(1), json.String("two"), json.Null])),
      #("b", json.Object([#("c", json.Bool(True))])),
    ])
  let assert Ok(packed) = interchange.to_msgpack(value)
    as "the value is json-shaped throughout"
  assert interchange.to_json(packed) == Ok(value)
}

pub fn describe_words_both_directions_test() {
  assert interchange.describe(interchange.NotJson(
      at: "$.blob",
      what: "a byte string",
    ))
    == "$.blob is a byte string, which does not cross to JSON"
  assert interchange.describe(interchange.NotMsgpack(at: "$", what: "big"))
    == "$ is big, which does not cross to msgpack"
}
