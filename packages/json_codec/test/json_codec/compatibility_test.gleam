//// The portable implementation is an independent oracle for the selected
//// backend. Values include all constructors; text mutations compare complete
//// corruption records rather than only agreement that something was rejected.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/string
import json_codec
import qcheck

/// Fixed seed for values, wire mutations and the generator reach census.
const compatibility_seed = 9117

const compatibility_cases = 800

const fragments = [
  "", "plain", "é中😀", "e\u{0301}", "\"\\\n\r\t\u{0008}\u{000C}",
  "\u{000B}\u{001B}", "\u{0000}\u{001F}", "\\u001B", "\u{2028}\u{2029}",
]

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_seed(qcheck.seed(compatibility_seed))
  |> qcheck.with_test_count(compatibility_cases)
}

fn texts() -> qcheck.Generator(String) {
  let fragment =
    qcheck.map(qcheck.bounded_int(0, list.length(fragments) - 1), fn(index) {
      let assert Ok(part) = list.first(list.drop(fragments, index))
        as "the index is drawn from the fragment table"
      part
    })
  qcheck.generic_list(fragment, qcheck.bounded_int(0, 6))
  |> qcheck.map(string.concat)
}

/// Draw the constructor first so shrinking can remove container structure.
fn values(depth: Int) -> qcheck.Generator(JsonValue) {
  let maximum_kind = case depth > 0 {
    True -> 6
    False -> 4
  }

  use kind <- qcheck.bind(qcheck.bounded_int(0, maximum_kind))

  // Containers draw only smaller trees; scalars remain the shrink targets.
  case kind {
    0 -> qcheck.return(json.Null)
    1 -> qcheck.map(qcheck.bounded_int(0, 1), fn(n) { json.Bool(n == 1) })
    2 -> qcheck.map(qcheck.bounded_int(-2_000_000, 2_000_000), json.Int)
    3 ->
      qcheck.map(qcheck.bounded_int(-2_000_000, 2_000_000), fn(n) {
        json.Float(int.to_float(n) *. 0.0000001)
      })
    4 -> qcheck.map(texts(), json.String)
    5 ->
      qcheck.generic_list(values(depth - 1), qcheck.bounded_int(0, 4))
      |> qcheck.map(json.Array)
    _ ->
      qcheck.generic_list(values(depth - 1), qcheck.bounded_int(0, 4))
      |> qcheck.map(fn(items) {
        json.Object(
          list.index_map(items, fn(value, index) {
            #("key-" <> int.to_string(index), value)
          }),
        )
      })
  }
}

pub fn selected_codec_preserves_values_and_exact_encoder_bytes_test() {
  let selected = json_codec.platform()
  let reference = json_codec.portable()
  qcheck.run(config(), values(3), fn(value) {
    let text = reference.to_string(value)
    assert selected.to_string(value) == text
    assert selected.parse(text) == reference.parse(text)
    assert selected.parse(text) == Ok(value)
  })
}

pub fn wire_mutations_preserve_complete_refusals_test() {
  let selected = json_codec.platform()
  let reference = json_codec.portable()
  qcheck.run(config(), qcheck.tuple2(values(2), texts()), fn(pair) {
    let #(value, extra) = pair
    let text = reference.to_string(value)
    let inputs = [
      text <> "?",
      "[" <> text,
      "{\"z\":" <> text <> ",\"z\":null}",
      "\u{000B}" <> text,
      "\"" <> extra <> "\\q\"",
      string.drop_end(text, 1),
    ]
    list.each(inputs, fn(input) {
      assert selected.parse(input) == reference.parse(input)
    })
  })
}

pub fn object_order_duplicates_controls_and_number_spellings_stay_exact_test() {
  let selected = json_codec.platform()
  let reference = json_codec.portable()
  let scalars = [
    json.Float(0.0),
    json.Float(-0.0),
    json.Float(1.0e300),
    json.Float(1.0e-300),
    json.Float(1.0e20),
    json.Float(-1.25e-7),
    json.String("\u{000B}\\u001B\u{001B}"),
  ]
  let duplicate =
    json.Object([
      #("z", json.Int(1)),
      #("a", json.Int(2)),
      #("z", json.Int(3)),
    ])

  // Encoding a hand-built duplicate object is defined, though parsing refuses it.
  list.each([duplicate, ..scalars], fn(value) {
    assert selected.to_string(value) == reference.to_string(value)
  })
  let ordered = "{\"z\":1,\"a\":2,\"é\":3}"
  assert selected.parse(ordered) == reference.parse(ordered)
  assert selected.parse(reference.to_string(duplicate))
    == reference.parse(reference.to_string(duplicate))
}

pub fn every_control_byte_keeps_its_escaped_spelling_in_keys_and_values_test() {
  let selected = json_codec.platform()
  let reference = json_codec.portable()
  int.range(0, 32, Nil, fn(_, byte) {
    let assert Ok(codepoint) = string.utf_codepoint(byte)
      as "every control byte is a valid Unicode codepoint"
    let text = string.from_utf_codepoints([codepoint])
    let value = json.Object([#(text, json.String(text))])
    assert selected.to_string(value) == reference.to_string(value)
  })
}

pub fn the_generator_reaches_each_value_constructor_and_text_fragment_test() {
  let #(examples, _) =
    qcheck.generate(
      values(3),
      compatibility_cases,
      qcheck.seed(compatibility_seed),
    )
  let kinds = list.map(examples, kind)
  assert list.all([0, 1, 2, 3, 4, 5, 6], fn(k) { list.contains(kinds, k) })

  let #(strings, _) =
    qcheck.generate(
      texts(),
      compatibility_cases,
      qcheck.seed(compatibility_seed),
    )
  assert list.contains(strings, "")
  let observed = string.concat(strings)
  assert list.all(fragments, fn(fragment) {
    string.contains(observed, fragment)
  })
}

fn kind(value: JsonValue) -> Int {
  case value {
    json.Null -> 0
    json.Bool(_) -> 1
    json.Int(_) -> 2
    json.Float(_) -> 3
    json.String(_) -> 4
    json.Array(_) -> 5
    json.Object(_) -> 6
  }
}
