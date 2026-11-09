//// JSON whitespace has four byte spellings and never changes string content.
//// The oracle states the tree and source positions independently of the parser
//// and serializer, including non-JSON whitespace that must remain corruption.

import core/corruption
import core/json
import gleam/int
import gleam/list
import gleam/string
import qcheck

/// Fixed seed and case count for independently varied whitespace boundaries.
const whitespace_seed = 9013

const whitespace_cases = 400

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_seed(qcheck.seed(whitespace_seed))
  |> qcheck.with_test_count(whitespace_cases)
}

fn gaps() -> qcheck.Generator(String) {
  let byte =
    qcheck.map(qcheck.bounded_int(0, 3), fn(index) {
      case index {
        0 -> " "
        1 -> "\t"
        2 -> "\n"
        _ -> "\r"
      }
    })
  qcheck.generic_list(byte, qcheck.bounded_int(0, 80))
  |> qcheck.map(string.concat)
}

pub fn legal_whitespace_preserves_structure_and_string_content_test() {
  qcheck.run(config(), qcheck.tuple2(gaps(), gaps()), fn(pair) {
    let #(a, b) = pair
    let document =
      a
      <> "{"
      <> b
      <> "\"é\""
      <> a
      <> ":"
      <> b
      <> "["
      <> a
      <> "true,"
      <> b
      <> "null"
      <> a
      <> ",\"kept \\t\\n\\r space\""
      <> b
      <> "]"
      <> a
      <> "}"
      <> b
    assert json.parse(document)
      == Ok(
        json.Object([
          #(
            "é",
            json.Array([
              json.Bool(True),
              json.Null,
              json.String("kept \t\n\r space"),
            ]),
          ),
        ]),
      )
  })
}

pub fn whitespace_refusals_keep_codepoint_offsets_and_context_test() {
  qcheck.run(config(), gaps(), fn(gap) {
    // The earlier non-ASCII string occupies codepoints rather than UTF-8 bytes.
    let prefix = "[\"é\"," <> gap
    let codepoints = list.length(string.to_utf_codepoints(gap))
    let offset = 5 + codepoints
    let invalid = [
      "\u{0000}",
      "\u{000B}",
      "\u{000C}",
      "\u{0085}",
      "\u{00A0}",
      "?",
    ]
    list.each(invalid, fn(byte) {
      assert json.parse(prefix <> byte <> "]")
        == Error(corruption.report(
          at: "core/json.parse",
          on: "codepoint offset " <> int.to_string(offset),
          expected: "a json value",
          context: byte <> "]",
        ))
    })

    assert json.parse(gap <> "null" <> gap <> "?")
      == Error(corruption.report(
        at: "core/json.parse",
        on: "codepoint offset " <> int.to_string(2 * codepoints + 4),
        expected: "end of input after the document",
        context: "?",
      ))
  })
}

pub fn the_whitespace_generator_reaches_every_byte_and_empty_gap_test() {
  let #(examples, _) =
    qcheck.generate(gaps(), whitespace_cases, qcheck.seed(whitespace_seed))
  assert list.contains(examples, "")
  let observed = string.concat(examples)
  assert list.all([" ", "\t", "\n", "\r"], fn(byte) {
    string.contains(observed, byte)
  })
}
