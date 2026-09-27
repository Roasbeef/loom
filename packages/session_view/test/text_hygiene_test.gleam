//// `text_hygiene.unchanged_prefix` against the pass it describes.
////
//// A host that sanitizes a growing text keeps the prefix this function
//// vouches for and runs the pass over the rest only, so the property it
//// states must hold for every text: the pass over the whole equals the
//// prefix followed by the pass over the rest. The texts here are built from
//// a seeded sequence of pieces that the pass keeps, rewrites or removes —
//// every UTF-8 width, carriage returns, tabs, escape sequences that complete
//// and ones that do not, C1 controls and the direction and format marks.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import session_view/text_hygiene

const pieces = [
  "plain", " ", "\n", "wörd", "漢字", "👍🏽", "🇺🇸", "e\u{301}", "\r\n", "\r", "\t",
  "\u{1b}[31m", "\u{1b}[", "\u{1b}]0;title\u{7}", "\u{1b}]open", "\u{9b}2J",
  "\u{9d}osc\u{9c}", "\u{85}", "\u{ad}", "\u{200b}", "\u{202e}", "\u{2066}",
  "\u{fe0f}", "\u{feff}", "\u{e0041}", "\u{7f}", "\u{0}", "\u{61c}", "\u{2028}",
]

fn text(seed: Int, count: Int, acc: List(String)) -> String {
  case count {
    0 -> string.concat(acc)
    _ -> {
      let seed = { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
      let index = { seed / 65_536 } % list.length(pieces)
      let piece = case list.drop(pieces, index) {
        [piece, ..] -> piece
        [] -> ""
      }
      text(seed, count - 1, [piece, ..acc])
    }
  }
}

fn split_at(value: String, bytes: Int) -> #(String, String) {
  let bits = bit_array.from_string(value)
  let assert Ok(head) =
    bit_array.slice(bits, 0, bytes) |> result.try(bit_array.to_string)
    as "the prefix ends on a character boundary"
  let assert Ok(rest) =
    bit_array.slice(bits, bytes, bit_array.byte_size(bits) - bytes)
    |> result.try(bit_array.to_string)
    as "so the rest starts on one"
  #(head, rest)
}

fn check(seed: Int) -> Nil {
  case seed > 2000 {
    True -> Nil
    False -> {
      let value = text(seed, seed % 12, [])
      let #(head, rest) = split_at(value, text_hygiene.unchanged_prefix(value))
      assert text_hygiene.multiline(value)
        == head <> text_hygiene.multiline(rest)
        as "the pass over the text is the prefix and the pass over the rest"
      assert text_hygiene.multiline(head) == head
        as "the pass leaves the prefix as it is"
      check(seed + 1)
    }
  }
}

pub fn the_unchanged_prefix_splits_the_pass_test() {
  check(1)
}

pub fn clean_text_is_unchanged_whole_and_a_rewrite_ends_the_prefix_test() {
  let clean = "plain wörd 漢字 👍🏽 🇺🇸 e\u{301}\nnext line"
  assert text_hygiene.unchanged_prefix(clean) == string.byte_size(clean)
  assert text_hygiene.unchanged_prefix("ab\r\ncd") == 2
  assert text_hygiene.unchanged_prefix("ab\tcd") == 2
  assert text_hygiene.unchanged_prefix("漢\u{200b}字") == 3
  assert text_hygiene.unchanged_prefix("\u{1b}[31mred") == 0
  assert text_hygiene.unchanged_prefix("") == 0
}
