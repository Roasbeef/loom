//// String scanning preserves decoded values and source positions together.
////
//// The oracle assembles JSON fragments and their independently stated text,
//// rather than encoding with the serializer paired with the parser. Prefixes
//// place mixed escapes after an earlier value and inside object keys so that
//// a scanner cannot reset its document origin at a string or Unicode boundary.

import core/corruption
import core/json
import gleam/int
import gleam/list
import gleam/string
import qcheck

/// Fixed seed and case count for mixed string-run and escape sequences.
const string_seed = 7343

const string_cases = 400

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_seed(qcheck.seed(string_seed))
  |> qcheck.with_test_count(string_cases)
}

/// Each fragment states its wire spelling and decoded text independently.
fn fragments() -> List(#(String, String)) {
  [
    #("", ""),
    #("ordinary text", "ordinary text"),
    #("é中🎉", "é中🎉"),
    #("e\u{0301}", "e\u{0301}"),
    #("\\\"", "\""),
    #("\\\\", "\\"),
    #("\\/", "/"),
    #("\\b", "\u{0008}"),
    #("\\f", "\u{000C}"),
    #("\\n", "\n"),
    #("\\r", "\r"),
    #("\\t", "\t"),
    #("\\u0041", "A"),
    #("\\u00e9", "é"),
    #("\\uD834\\uDD1E", "𝄞"),
  ]
}

fn fragment() -> qcheck.Generator(#(String, String)) {
  qcheck.map(qcheck.bounded_int(0, list.length(fragments()) - 1), fn(index) {
    let assert Ok(value) = list.first(list.drop(fragments(), index))
      as "the generator index is bounded by its fragment table"
    value
  })
}

fn strings() -> qcheck.Generator(List(#(String, String))) {
  qcheck.generic_list(fragment(), qcheck.bounded_int(0, 40))
}

pub fn mixed_string_runs_and_escapes_match_an_independent_oracle_test() {
  qcheck.run(config(), strings(), fn(parts) {
    let encoded = list.map(parts, fn(part) { part.0 }) |> string.concat
    let text = list.map(parts, fn(part) { part.1 }) |> string.concat
    let document =
      " [\"before\",{\"" <> encoded <> "\":[\"" <> encoded <> "\",\"after\"]}] "
    let expected =
      json.Array([
        json.String("before"),
        json.Object([
          #(text, json.Array([json.String(text), json.String("after")])),
        ]),
      ])
    assert json.parse(document) == Ok(expected)
  })
}

pub fn mixed_string_refusals_keep_the_document_offset_and_context_test() {
  qcheck.run(config(), strings(), fn(parts) {
    let encoded = list.map(parts, fn(part) { part.0 }) |> string.concat
    let prefix = " [\"é\", \"" <> encoded
    let start = list.length(string.to_utf_codepoints(prefix))
    let refusals = [
      #(
        "\u{0001}\"",
        0,
        "control characters to be escaped in a string",
        "\u{0001}\"",
      ),
      #("\\q\"", 1, "a valid escape character", "q\""),
      #("\\u12G4\"", 2, "four hexadecimal digits", "12G4\""),
      #("\\uD800\\u0041\"", 6, "a low surrogate escape", "\\u0041\""),
      #("\\uDC00\"", 6, "a valid unicode escape, not a lone surrogate", "\""),
      #("", 0, "a closing \" before end of input", "end of input"),
    ]

    // The offset counts source codepoints, including escape spelling bytes,
    // rather than decoded string length or only bytes since the latest escape.
    list.each(refusals, fn(refusal) {
      let #(suffix, consumed, expected, context) = refusal
      assert json.parse(prefix <> suffix)
        == Error(corruption.report(
          at: "core/json.parse",
          on: "codepoint offset " <> int.to_string(start + consumed),
          expected:,
          context:,
        ))
    })
  })
}

pub fn the_string_generator_reaches_each_fragment_and_empty_sequences_test() {
  let #(examples, _) =
    qcheck.generate(strings(), string_cases, qcheck.seed(string_seed))
  let observed = list.flatten(examples)
  assert list.contains(examples, [])
    as "the oracle exercises the empty string and empty object key"
  assert list.all(fragments(), fn(part) { list.contains(observed, part) })
    as "the fixed corpus reaches every simple escape, Unicode escape and ordinary run"
}
