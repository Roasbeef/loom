import core/json
import gleam/list
import gleam/string
import gleam/string_tree
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

// --- the byte-run string codec ------------------------------------------

// The run-based encoder must print exactly what the codepoint encoder
// prints. The oracle is kept in the module for this comparison; the
// strings mix escapes at the start, the middle and the end of a run with
// multi-byte neighbours on both sides, which is where a byte scan that
// split a codepoint or missed an escape would show.
pub fn run_encoder_matches_the_codepoint_oracle_test() {
  let crafted = [
    "",
    "\"",
    "\\",
    "plain ascii",
    "quote \" inside",
    "tab\there and newline\nthere",
    "\u{0001}control first",
    "control last\u{001f}",
    "ünïcödé \"quoted\" ünïcödé",
    "日本語\\日本語",
    "emoji 🎉 then \u{0008} then 🎉",
    "\"\"\"\\\\\\",
    "ends with a backslash\\",
  ]
  let #(generated, _seed) =
    generate.list_of(generate.seed(23), 300, generate.small_string)
  list.each(list.append(crafted, generated), fn(text) {
    assert json.to_string(json.String(text))
      == string_tree.to_string(json.build_string_by_codepoint(text))
  })
}

// A parse must cut runs at the same places the encoder did and rebuild
// the same string, escapes and multi-byte neighbours included.
pub fn escapes_beside_multibyte_text_round_trip_test() {
  let texts = [
    "日本語\"日本語",
    "🎉\\🎉",
    "ü\nü\tü",
    "a\u{0000}b",
    "\"日本語\"",
  ]
  list.each(texts, fn(text) {
    assert json.parse(json.to_string(json.String(text)))
      == Ok(json.String(text))
  })
}

// A raw control character inside a string is still a corruption report,
// wherever in the run it sits.
pub fn a_raw_control_character_is_corruption_test() {
  let assert Error(_) = json.parse("\"ok\u{0001}\"")
  let assert Error(_) = json.parse("\"日本語\u{001f}日本語\"")
  let assert Error(_) = json.parse("\"\u{000a}\"")
}

// Escapes at every byte offset must agree with the independent codepoint
// encoder, including when the preceding chunk ends inside a UTF-8 codepoint.
pub fn string_escape_boundaries_match_the_codepoint_oracle_test() {
  let escaped_codes = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
    0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
    0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x22, 0x5C,
  ]
  list.each([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], fn(offset) {
    let prefix = string.repeat("x", offset)
    list.each([prefix, prefix <> "é中🎉"], fn(prefix) {
      list.each(escaped_codes, fn(code) {
        let assert Ok(point) = string.utf_codepoint(code)
          as "the fixture uses valid control and escape codepoints"
        let text = prefix <> string.from_utf_codepoints([point]) <> "é中🎉 tail"
        let encoded = json.to_string(json.String(text))
        assert encoded
          == string_tree.to_string(json.build_string_by_codepoint(text))
        assert json.parse(encoded) == Ok(json.String(text))
      })
    })
  })
}

// A chunk cannot skip a delimiter, unknown escape or raw C0 control. These
// failures are decoder properties, independent of what the encoder emits.
pub fn string_boundaries_preserve_decoder_refusals_test() {
  let controls = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
    0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
    0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
  ]
  list.each([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], fn(offset) {
    let prefix = string.repeat("x", offset) <> "é中🎉"
    assert json.parse("\"" <> prefix <> "\"") == Ok(json.String(prefix))
    let assert Error(_) = json.parse("\"" <> prefix <> "\" trailing")
      as "a closing quote ends the document before trailing data"
    let assert Error(_) = json.parse("\"" <> prefix <> "\\q\"")
      as "unknown escapes remain corrupt at every offset"
    list.each(controls, fn(code) {
      let assert Ok(point) = string.utf_codepoint(code)
        as "the fixture uses a valid C0 codepoint"
      let raw =
        "\"" <> prefix <> string.from_utf_codepoints([point]) <> "tail\""
      let assert Error(_) = json.parse(raw)
        as "a raw control cannot be hidden inside a chunk"
    })
  })
}

// A long string with nothing to escape takes the fast path and comes back
// byte for byte; one with a single escape in the middle takes the run path
// and comes back the same.
pub fn long_strings_round_trip_test() {
  let clean =
    string.repeat("the quick brown fox jumps over the lazy dog ", 2000)
  assert json.parse(json.to_string(json.String(clean)))
    == Ok(json.String(clean))
  let escaped = clean <> "\"" <> clean
  assert json.parse(json.to_string(json.String(escaped)))
    == Ok(json.String(escaped))
}

// The report still counts the offset in codepoints, not bytes.
pub fn a_report_offset_counts_codepoints_test() {
  let assert Error(report) = json.parse("\"日本語\" x")
  assert string.contains(report.subject, "codepoint offset 6")
}

// Key order is the one difference two encoders of the same arguments are
// free to disagree on, so the canonical form erases it at every depth and
// keeps array order, which is part of the value.
pub fn canonical_sorts_keys_at_every_depth_and_keeps_arrays_test() {
  let streamed =
    json.Object([
      #("scope", json.String("repository")),
      #("limit", json.Int(15)),
      #("action", json.Object([#("z", json.Null), #("a", json.Int(1))])),
      #("order", json.Array([json.Int(2), json.Int(1)])),
    ])
  let reordered =
    json.Object([
      #("order", json.Array([json.Int(2), json.Int(1)])),
      #("action", json.Object([#("a", json.Int(1)), #("z", json.Null)])),
      #("limit", json.Int(15)),
      #("scope", json.String("repository")),
    ])
  assert json.canonical(streamed) == json.canonical(reordered)
  assert json.to_string(json.canonical(streamed))
    == "{\"action\":{\"a\":1,\"z\":null},\"limit\":15,\"order\":[2,1],\"scope\":\"repository\"}"
}

pub fn registered_profile_counts_entire_tree_before_node_construction_test() {
  let exact = "[" <> string.repeat("null,", 199_998) <> "null]"
  let assert Ok(json.Array(values)) =
    json.parse_profile(exact, json.RegisteredLspJson)
    as "The root array and its values consume exactly 200000 nodes."
  assert list.length(values) == 199_999
  let over = "[" <> string.repeat("null,", 199_999) <> "null]"
  let assert Error(_) = json.parse_profile(over, json.RegisteredLspJson)
    as "One more value is refused before its node is constructed."
  assert json.parse_profile(over, json.StandardJson) == json.parse(over)

  // Object keys and values spend the same budget, across nested containers.
  let nested = "[" <> string.repeat("null,", 199_996) <> "{\"key\":null}]"
  let assert Ok(_) = json.parse_profile(nested, json.RegisteredLspJson)
    as "Nested object container, key and value complete the exact budget."
  let extra_key = "[" <> string.repeat("null,", 199_997) <> "{\"key\":null}]"
  let assert Error(_) = json.parse_profile(extra_key, json.RegisteredLspJson)
    as "Keys cannot escape aggregate node accounting."
}

pub fn registered_profile_preserves_standard_syntax_depth_and_errors_test() {
  list.each(
    [
      "123456789012345678901234567890",
      "[1.5,-0.25,1e3,true,null,\"\\uD83D\\uDE00\"]",
      "{\"k\":1,\"k\":2}",
      "[1,]",
      "\"\\uD800\"",
      "1e99999",
      string.repeat("[", json.max_depth) <> string.repeat("]", json.max_depth),
      string.repeat("[", json.max_depth + 1)
        <> string.repeat("]", json.max_depth + 1),
    ],
    fn(text) {
      assert json.parse_profile(text, json.RegisteredLspJson)
        == json.parse(text)
      assert json.parse_profile(text, json.StandardJson) == json.parse(text)
    },
  )
}
