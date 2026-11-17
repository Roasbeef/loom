//// A cut of text another machine chose, bounded by bytes.
////
//// Text that arrives from an untrusted executor (a refusal's reason, a
//// helper's failure message, a Git diagnostic) can be as long as a frame, and
//// some of it is stored or shown. Clipping it with `string.slice` or measuring
//// it with `string.length` walks grapheme clusters from the start, and the
//// sender chooses the clusters: one letter followed by millions of combining
//// accents is a single grapheme that costs seconds and hundreds of megabytes to
//// walk. `clip` never looks past the bytes it keeps: it takes a byte prefix and
//// moves the cut back to the nearest codepoint boundary, which is at most three
//// bytes away in UTF-8.

import gleam/bit_array
import gleam/result

/// `text` cut to at most `max_bytes` bytes, ending on a codepoint boundary.
/// Text within the bound is returned as it is. The cut may split a grapheme
/// cluster, which leaves valid text with a mark missing from its last letter.
///
/// ## Examples
///
/// ```gleam
/// assert bounded_text.clip("héllo", 2) == "h"
/// assert bounded_text.clip("hello", 512) == "hello"
/// ```
pub fn clip(text: String, max_bytes: Int) -> String {
  let bytes = bit_array.from_string(text)

  // Measuring a binary's bytes is constant time; only a cut is decoded.
  case bit_array.byte_size(bytes) <= max_bytes {
    True -> text
    False -> prefix(bytes, max_bytes, 4)
  }
}

/// The longest valid UTF-8 prefix of `bytes` within `length` bytes, trying at
/// most `tries` lengths: a codepoint is at most four bytes, so one of four
/// consecutive cut points is a boundary of any valid text.
fn prefix(bytes: BitArray, length: Int, tries: Int) -> String {
  let decoded =
    bit_array.slice(bytes, 0, length) |> result.try(bit_array.to_string)

  // A cut inside a codepoint does not decode; the next shorter one is tried.
  case decoded, length <= 0 || tries <= 1 {
    Ok(text), _ -> text
    Error(Nil), True -> ""
    Error(Nil), False -> prefix(bytes, length - 1, tries - 1)
  }
}
