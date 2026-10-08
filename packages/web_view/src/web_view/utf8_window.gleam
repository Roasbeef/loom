//// UTF-8 windows with byte bounds, without segmenting an entire result.
////
//// The input comes from valid stored JSON or a Gleam String. At most three
//// continuation bytes precede a boundary; aligning both ends to the preceding
//// boundary makes consecutive fixed byte windows partition the original text.

import gleam/bit_array
import gleam/int
import gleam/result

/// Takes a complete UTF-8 prefix within a byte limit.
///
/// ## Examples
///
/// ```gleam
/// assert utf8_window.prefix("λx", 1) == ""
/// ```
pub fn prefix(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  let size = int.min(bit_array.byte_size(bytes), int.max(0, limit))
  window(bytes, 0, size) |> result.unwrap("")
}

/// Reads the complete codepoints between the preceding boundaries of a window.
/// The caller includes up to three preceding bytes for a nonzero start.
///
/// ## Examples
///
/// ```gleam
/// assert utf8_window.window(<<"λx":utf8>>, 0, 2) == Ok("λ")
/// ```
pub fn window(bytes: BitArray, start: Int, end: Int) -> Result(String, Nil) {
  case start >= 0 && end >= start && end <= bit_array.byte_size(bytes) {
    False -> Error(Nil)
    True -> {
      let first = boundary(bytes, start, 3)
      let last = boundary(bytes, end, 3)
      use slice <- result.try(bit_array.slice(bytes, first, last - first))
      bit_array.to_string(slice)
    }
  }
}

// A continuation byte cannot begin a codepoint. Walking back at most three
// bytes finds the start without decoding any text outside this small window.
fn boundary(bytes: BitArray, at: Int, remaining: Int) -> Int {
  case at == 0 || remaining == 0 || at == bit_array.byte_size(bytes) {
    True -> at
    False ->
      case bit_array.slice(bytes, at, 1) {
        Ok(<<byte:8>>) if byte >= 128 && byte < 192 ->
          boundary(bytes, at - 1, remaining - 1)
        Ok(_) | Error(_) -> at
      }
  }
}
