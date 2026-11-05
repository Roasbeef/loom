//// Field lookup must keep its first-match and total-refusal behavior while
//// skipping unknown fields without constructing a search callback. Generated
//// object layouts exercise the public decoder rather than the private search.

import core/corruption
import core/json
import gleam/int
import gleam/list
import machine/codec
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import qcheck

pub fn unknown_fields_and_later_duplicates_preserve_configuration_test() {
  use #(width, value) <- qcheck.run(config(), layouts())
  let expected = configuration(value)
  let input = decorate(codec.encode_configuration(expected), width)
  assert codec.decode_configuration(input) == Ok(expected)
}

pub fn an_invalid_first_duplicate_keeps_its_full_refusal_test() {
  use #(width, value) <- qcheck.run(config(), layouts())
  let assert json.Object(fields) =
    decorate(codec.encode_configuration(configuration(value)), width)
    as "the fixture encodes an object"
  let input = json.Object([#("model", json.Int(value)), ..fields])
  let expected =
    corruption.report(
      at: "machine/codec.model",
      on: "value",
      expected: "a json object",
      context: int.to_string(value),
    )
  assert codec.decode_configuration(input) == Error(expected)
}

pub fn a_missing_field_keeps_its_full_refusal_after_unknown_fields_test() {
  use #(width, value) <- qcheck.run(config(), layouts())
  let assert json.Object(fields) =
    codec.encode_configuration(configuration(value))
    as "the fixture encodes an object"
  let without_model = list.filter(fields, fn(pair) { pair.0 != "model" })
  let input = json.Object(list.append(unknown_fields(width), without_model))
  let expected =
    corruption.report(
      at: "machine/codec.configuration",
      on: "model",
      expected: "a present field",
      context: "absent",
    )
  assert codec.decode_configuration(input) == Error(expected)
}

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(4219))
}

fn layouts() -> qcheck.Generator(#(Int, Int)) {
  qcheck.map2(
    qcheck.bounded_int(from: 0, to: 64),
    qcheck.bounded_int(from: -100, to: 100),
    fn(width, value) { #(width, value) },
  )
}

fn configuration(value: Int) -> strand.StrandConfiguration {
  let label = int.to_string(value)
  StrandConfiguration(
    model: ModelIdentity("provider-" <> label, "model-" <> label),
    thinking_level: ThinkingOff,
    active_tool_names: ["read-" <> label, "write-" <> label],
  )
}

fn unknown_fields(width: Int) -> List(#(String, json.JsonValue)) {
  list.repeat(Nil, width)
  |> list.index_map(fn(_, index) {
    #("unknown-" <> int.to_string(index), json.Array([json.Null]))
  })
}

// Model/configuration objects contain no opaque JSON fields. Reordering and
// inserting ignored fields here must preserve the entire typed result; a wrong
// duplicate after the original must never replace the first field's value.
fn decorate(value: json.JsonValue, width: Int) -> json.JsonValue {
  case value {
    json.Object(fields) -> {
      let fields =
        list.reverse(fields)
        |> list.map(fn(pair) { #(pair.0, decorate(pair.1, width)) })

      case fields {
        [] -> json.Object(unknown_fields(width))
        [#(first, _), ..] ->
          json.Object(list.append(
            unknown_fields(width),
            list.append(fields, [#(first, json.Null)]),
          ))
      }
    }
    json.Array(values) -> json.Array(list.map(values, decorate(_, width)))
    other -> other
  }
}
