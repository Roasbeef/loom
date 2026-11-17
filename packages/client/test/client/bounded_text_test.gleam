//// `bounded_text.clip` cuts by bytes at a codepoint boundary.

import client/bounded_text
import gleam/string

pub fn text_within_the_bound_is_unchanged_test() {
  assert bounded_text.clip("hello", 5) == "hello"
  assert bounded_text.clip("", 0) == ""
}

// A cut inside a codepoint moves back to the boundary before it.
pub fn a_cut_never_splits_a_codepoint_test() {
  assert bounded_text.clip("héllo", 2) == "h"
  assert bounded_text.clip("héllo", 3) == "hé"
  assert bounded_text.clip("😀😀", 5) == "😀"
  assert bounded_text.clip("😀", 3) == ""
}

// One letter with a million combining accents is one grapheme cluster; the
// cut keeps the bytes it was asked for without walking the rest.
pub fn a_long_grapheme_is_cut_by_bytes_test() {
  let text = "a" <> string.repeat("\u{0301}", 1_000_000)
  let cut = bounded_text.clip(text, 512)
  assert string.byte_size(cut) == 511
  assert string.starts_with(text, cut)
}
