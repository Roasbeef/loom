//// The optimized validator must recognize exactly the existing profile grammar.
//// The grapheme oracle preserves the old implementation independently of the
//// byte walk; generated strings and positional byte checks guard its edges.

import gleam/bit_array
import gleam/list
import gleam/string
import qcheck
import storage/catalogue

/// Generated mixed Unicode strings agree with the original grapheme grammar.
pub fn profile_names_match_the_grapheme_oracle_test() {
  let palette = [
    "a", "z", "0", "9", "_", "-", "A", " ", ".", "/", "\u{0000}", "\n", "é",
    "\u{0301}", "漢", "😀", "\u{200d}",
  ]
  let character =
    qcheck.bounded_int(from: 0, to: list.length(palette) - 1)
    |> qcheck.map(fn(index) {
      let assert [chosen, ..] = list.drop(palette, index)
        as "the generator index is bounded by the palette"
      chosen
    })
  let names =
    qcheck.generic_list(
      elements_from: character,
      length_from: qcheck.bounded_int(from: 0, to: 40),
    )
    |> qcheck.map(string.concat)

  qcheck.default_config()
  |> qcheck.with_test_count(5000)
  |> qcheck.with_seed(qcheck.seed(6197))
  |> qcheck.run(names, fn(name) {
    assert catalogue.is_profile_name(name) == original_grammar(name)
  })
}

/// Every ASCII byte is checked in the first, middle and final positions.
pub fn profile_names_cover_each_ascii_byte_and_length_boundary_test() {
  list.index_map(list.repeat(Nil, 128), fn(_, byte) {
    let assert Ok(character) = bit_array.to_string(<<byte>>)
      as "a single ASCII byte is valid UTF-8"
    list.each(
      [
        character,
        character <> "a",
        "a" <> character,
        "a" <> character <> string.repeat("z", 30),
        string.repeat("a", 31) <> character,
        string.repeat("a", 32) <> character,
      ],
      fn(name) {
        assert catalogue.is_profile_name(name) == original_grammar(name)
      },
    )
  })

  // Long valid prefixes and multibyte suffixes cannot bypass the byte limit.
  list.each(
    [
      "",
      "a",
      string.repeat("a", 32),
      string.repeat("a", 33),
      string.repeat("a", 100_000),
      "a\u{0301}",
      "aé",
      "a😀",
      string.repeat("a", 31) <> "é",
    ],
    fn(name) {
      assert catalogue.is_profile_name(name) == original_grammar(name)
    },
  )
}

/// The old implementation is an oracle, deliberately retaining its expensive
/// grapheme lists so the candidate cannot make its own mistake pass the test.
fn original_grammar(text: String) -> Bool {
  case string.to_graphemes(text) {
    [first, ..rest] ->
      string.length(text) <= 32
      && letter(first)
      && list.all(rest, fn(grapheme) {
        letter(grapheme)
        || grapheme == "_"
        || grapheme == "-"
        || list.contains(string.to_graphemes("0123456789"), grapheme)
      })
    [] -> False
  }
}

fn letter(grapheme: String) -> Bool {
  list.contains(string.to_graphemes("abcdefghijklmnopqrstuvwxyz"), grapheme)
}
