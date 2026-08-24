import core/json
import gleam/list
import gleam/string
import support/generate

// --- parsing basics -----------------------------------------------------

pub fn parse_scalars_test() {
  assert json.parse("null") == Ok(json.Null)
  assert json.parse("true") == Ok(json.Bool(True))
  assert json.parse("false") == Ok(json.Bool(False))
  assert json.parse("0") == Ok(json.Int(0))
  assert json.parse("-0") == Ok(json.Int(0))
  assert json.parse("42") == Ok(json.Int(42))
  assert json.parse("-17") == Ok(json.Int(-17))
  assert json.parse("\"hi\"") == Ok(json.String("hi"))
}

pub fn parse_big_integer_test() {
  // Arbitrary precision on the BEAM: far beyond 2^63.
  assert json.parse("123456789012345678901234567890")
    == Ok(json.Int(123_456_789_012_345_678_901_234_567_890))
}

pub fn parse_floats_test() {
  assert json.parse("1.5") == Ok(json.Float(1.5))
  assert json.parse("-0.25") == Ok(json.Float(-0.25))
  assert json.parse("1e3") == Ok(json.Float(1000.0))
  assert json.parse("1E3") == Ok(json.Float(1000.0))
  assert json.parse("1e+3") == Ok(json.Float(1000.0))
  assert json.parse("25e-2") == Ok(json.Float(0.25))
  assert json.parse("1.25e2") == Ok(json.Float(125.0))
}

pub fn parse_whitespace_test() {
  assert json.parse(" \t\r\n [ 1 , 2 ] \n")
    == Ok(json.Array([json.Int(1), json.Int(2)]))
}

pub fn parse_nested_structures_test() {
  let text = "{\"a\":[{\"b\":[1,[2,[3,{\"c\":null}]]]}],\"d\":{}}"
  let expected =
    json.Object([
      #(
        "a",
        json.Array([
          json.Object([
            #(
              "b",
              json.Array([
                json.Int(1),
                json.Array([
                  json.Int(2),
                  json.Array([json.Int(3), json.Object([#("c", json.Null)])]),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
      #("d", json.Object([])),
    ])
  assert json.parse(text) == Ok(expected)
}

pub fn parse_empty_containers_test() {
  assert json.parse("{}") == Ok(json.Object([]))
  assert json.parse("[]") == Ok(json.Array([]))
}

pub fn parse_rejects_duplicate_keys_test() {
  // A duplicated key has no single meaning across decoders (first- versus
  // last-occurrence precedence), so the parser refuses to pick one.
  let assert Error(_report) = json.parse("{\"a\":1,\"a\":2}")
  // Also in a nested object, and with more fields around the duplicate.
  let assert Error(_report) = json.parse("{\"o\":{\"b\":1,\"c\":2,\"b\":3}}")
  // The same key in two different objects is fine.
  assert json.parse("{\"o\":{\"a\":1},\"p\":{\"a\":2}}")
    == Ok(
      json.Object([
        #("o", json.Object([#("a", json.Int(1))])),
        #("p", json.Object([#("a", json.Int(2))])),
      ]),
    )
}

pub fn parse_depth_at_bound_still_decodes_test() {
  // Exactly max_depth nested arrays decode ...
  let text =
    string.repeat("[", json.max_depth) <> string.repeat("]", json.max_depth)
  let assert Ok(_value) = json.parse(text)
  // ... and so do exactly max_depth nested objects.
  let objects =
    string.repeat("{\"k\":", json.max_depth - 1)
    <> "{}"
    <> string.repeat("}", json.max_depth - 1)
  let assert Ok(_value) = json.parse(objects)
}

pub fn parse_depth_past_bound_rejected_test() {
  let over = json.max_depth + 1
  let arrays = string.repeat("[", over) <> string.repeat("]", over)
  let assert Error(_report) = json.parse(arrays)
  let objects =
    string.repeat("{\"k\":", over - 1) <> "{}" <> string.repeat("}", over - 1)
  let assert Error(_report) = json.parse(objects)
  // Far past the bound — thousands of one-byte headers — is refused
  // in-band too, not by exhausting the parser.
  let assert Error(_report) = json.parse(string.repeat("[", 100_000))
}

// --- strings and unicode ------------------------------------------------

pub fn parse_escapes_test() {
  assert json.parse("\"a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\"")
    == Ok(json.String("a\"b\\c/d\u{0008}e\u{000C}f\ng\rh\ti"))
}

pub fn parse_unicode_escape_test() {
  assert json.parse("\"\\u0041\\u00e9\\u4e2d\"") == Ok(json.String("Aé中"))
}

pub fn parse_surrogate_pair_test() {
  // U+1D11E musical symbol G clef, and U+1F600 emoji.
  assert json.parse("\"\\ud834\\udd1e\"") == Ok(json.String("𝄞"))
  assert json.parse("\"\\ud83d\\ude00\"") == Ok(json.String("😀"))
}

pub fn parse_raw_unicode_test() {
  assert json.parse("\"漢字 και ώ 🦊\"") == Ok(json.String("漢字 και ώ 🦊"))
}

pub fn serialize_escapes_control_characters_test() {
  assert json.to_string(json.String("a\nb\u{0001}c")) == "\"a\\nb\\u0001c\""
}

pub fn serialize_escapes_quotes_and_backslashes_test() {
  assert json.to_string(json.String("say \"hi\" \\ bye"))
    == "\"say \\\"hi\\\" \\\\ bye\""
}

// --- serialization ------------------------------------------------------

pub fn serialize_compact_forms_test() {
  assert json.to_string(json.Null) == "null"
  assert json.to_string(json.Bool(True)) == "true"
  assert json.to_string(json.Int(-5)) == "-5"
  assert json.to_string(json.Array([json.Int(1), json.Int(2)])) == "[1,2]"
  assert json.to_string(json.Object([#("a", json.Int(1)), #("b", json.Null)]))
    == "{\"a\":1,\"b\":null}"
}

pub fn serialized_floats_stay_floats_test() {
  let assert Ok(json.Float(1.0)) = json.parse(json.to_string(json.Float(1.0)))
  let assert Ok(json.Float(_)) = json.parse(json.to_string(json.Float(1.0e30)))
}

// --- roundtrip properties -----------------------------------------------

pub fn roundtrip_property_test() {
  roundtrip_loop(generate.seed(21), 200)
}

fn roundtrip_loop(seed: generate.Seed, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let #(value, seed) = generate.json_value(seed, 4)
      assert json.parse(json.to_string(value)) == Ok(value)
      roundtrip_loop(seed, remaining - 1)
    }
  }
}

pub fn roundtrip_unicode_heavy_strings_test() {
  let seed = generate.seed(22)
  let #(texts, _seed) = generate.list_of(seed, 200, generate.small_string)
  list.each(texts, fn(text) {
    assert json.parse(json.to_string(json.String(text)))
      == Ok(json.String(text))
  })
}

pub fn roundtrip_deeply_nested_test() {
  let deep =
    list.fold(generate.range(1, 100), from: json.Int(0), with: fn(inner, _) {
      json.Object([#("k", json.Array([inner]))])
    })
  assert json.parse(json.to_string(deep)) == Ok(deep)
}

// --- adversarial inputs -------------------------------------------------

pub fn adversarial_corpus_test() {
  let corpus = [
    "",
    " ",
    "nul",
    "nulll",
    "truefalse",
    "TRUE",
    "{",
    "}",
    "[",
    "]",
    "{]",
    "[}",
    "[1,",
    "[1,]",
    "[,1]",
    "{\"a\"}",
    "{\"a\":}",
    "{\"a\":1,}",
    "{a:1}",
    "{\"a\" 1}",
    "{\"a\":1 \"b\":2}",
    "\"unterminated",
    "\"bad escape \\x\"",
    "\"\\u12\"",
    "\"\\u123g\"",
    // lone surrogates, both orders
    "\"\\ud834\"",
    "\"\\udd1e\"",
    "\"\\ud834\\u0041\"",
    // raw control character inside a string
    "\"a\u{0001}b\"",
    "01",
    "1.",
    ".5",
    "+1",
    "1e",
    "1e+",
    "--1",
    "0x10",
    "1 2",
    "[1] tail",
    "NaN",
    "Infinity",
    // a float literal beyond ieee 754 double range
    "1e999",
    "-1e999",
    // duplicated object keys
    "{\"v\":1,\"v\":2}",
    "{\"a\":1,\"b\":{\"c\":1,\"c\":2}}",
    // nesting past the depth bound, arrays and objects
    string.repeat("[", json.max_depth + 1)
      <> string.repeat("]", json.max_depth + 1),
    string.repeat("[", 50_000),
    string.repeat("{\"k\":", json.max_depth + 1) <> "0",
  ]
  list.each(corpus, fn(text) {
    let assert Error(_report) = json.parse(text)
  })
}
