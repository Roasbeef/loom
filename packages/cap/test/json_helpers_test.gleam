//// JSON text crosses into notes and child-result values through one codec.

import cap/report
import core/json
import core/msgpack
import gleam/list
import gleam/result
import gleam/string

pub fn nested_json_round_trips_without_numeric_or_null_coercion_test() {
  let value =
    report.object([
      #("escaped", report.string("hello\n\"世界\"")),
      #(
        "items",
        report.list([
          report.int(9_007_199_254_740_993),
          report.float(1.25),
          report.null(),
          report.bool(False),
        ]),
      ),
    ])
  assert report.encode_json(value) |> result.try(report.decode_json)
    == Ok(value)
  assert report.decode_json("null") == Ok(report.null())
}

pub fn lossy_json_values_are_refused_test() {
  list.each(
    [
      msgpack.BinaryValue(<<1>>),
      msgpack.MapValue([#(msgpack.IntValue(1), msgpack.NilValue)]),
      report.object([#("x", report.int(1)), #("x", report.int(2))]),
    ],
    fn(value) {
      let assert Error(_) = report.encode_json(report.list([value]))
        as "nested non-JSON values must fail encoding"
    },
  )
  list.each(["{\"x\":1,\"x\":2}", "true false", "[", "1e9999"], fn(text) {
    let assert Error(_) = report.decode_json(text)
      as "ambiguous or malformed JSON must fail parsing"
  })
}

pub fn json_nesting_bound_is_consistent_in_both_directions_test() {
  let at_limit =
    list.fold(list.repeat(Nil, json.max_depth), report.null(), fn(value, _) {
      report.list([value])
    })
  assert report.encode_json(at_limit) |> result.try(report.decode_json)
    == Ok(at_limit)
  let assert Error(_) = report.encode_json(report.list([at_limit]))
    as "encoding refuses one container beyond the shared bound"
  let too_deep =
    string.repeat("[", json.max_depth + 1)
    <> "null"
    <> string.repeat("]", json.max_depth + 1)
  let assert Error(_) = report.decode_json(too_deep)
    as "parsing refuses the same excessive nesting"
}
