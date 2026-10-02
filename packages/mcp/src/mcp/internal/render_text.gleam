//// Shared inert-text rendering for MCP source and discovery surfaces.

import gleam/int
import gleam/list
import gleam/string

/// Replaces every invisible or direction-changing codepoint with one
/// space: C0 and C1 controls (`\n`, `\r`, `\t` included), U+00AD,
/// U+061C, U+2028/U+2029, U+200B–U+200F, U+202A–U+202E, U+2060–U+2069,
/// U+FE00–U+FE0F, U+FEFF and the tag-character plane U+E0000–U+E007F.
/// All other Unicode passes. This is what keeps attacker prose inside
/// the one comment line the generator wrote it into.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.sanitize("a\nb") == "a b"
/// ```
///
pub fn sanitize(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.map(fn(codepoint) {
    case invisible(string.utf_codepoint_to_int(codepoint)) {
      True -> " "
      False -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

// C0/C1 controls, line/paragraph separators, the zero-width and
// direction-control sets (bidi overrides, the Arabic letter mark, the
// word joiner and invisible operators), the soft hyphen, variation
// selectors, the BOM, and the tag-character plane — the last being the
// classic vector for instructions visible to a model and invisible to a
// human reading the same rendered text.
fn invisible(code: Int) -> Bool {
  code < 0x20
  || code == 0x7F
  || { code >= 0x80 && code <= 0x9F }
  || code == 0xAD
  || code == 0x061C
  || code == 0x2028
  || code == 0x2029
  || { code >= 0x200B && code <= 0x200F }
  || { code >= 0x202A && code <= 0x202E }
  || { code >= 0x2060 && code <= 0x2069 }
  || { code >= 0xFE00 && code <= 0xFE0F }
  || code == 0xFEFF
  || { code >= 0xE0000 && code <= 0xE007F }
}

/// Caps text at `max` characters, cutting on a codepoint boundary and
/// ending a cut text with `…` (counted inside the cap).
///
/// ## Examples
///
/// ```gleam
/// assert codegen.truncate("abcdef", 4) == "abc…"
/// assert codegen.truncate("abcd", 4) == "abcd"
/// ```
///
pub fn truncate(text: String, max: Int) -> String {
  // `drop_start` against `""` answers "longer than max?" without
  // `string.length`'s walk of a possibly 10 KiB description (lint R5).
  case string.drop_start(text, max) == "" {
    True -> text
    False -> string.slice(text, 0, max - 1) <> "…"
  }
}

// Greedy word wrap. Every line break in an emitted comment comes from
// here — never from the server's text, whose breaks `sanitize` already
// flattened. A word longer than the width gets its own (long) line
// rather than a mid-word cut.
/// Wraps already sanitized prose at generator-owned line boundaries.
///
/// ## Examples
///
/// ```gleam
/// assert render_text.wrap("a b", 2) == ["a", "b"]
/// ```
pub fn wrap(text: String, width: Int) -> List(String) {
  let words = list.filter(string.split(text, " "), fn(word) { word != "" })
  let #(lines, last, _) =
    list.fold(words, #([], "", 0), fn(state, word) {
      let #(lines, current, length) = state
      let word_length = string.length(word)
      case current {
        "" -> #(lines, word, word_length)
        _ ->
          case length + 1 + word_length <= width {
            True -> #(lines, current <> " " <> word, length + 1 + word_length)
            False -> #([current, ..lines], word, word_length)
          }
      }
    })
  case last {
    "" -> list.reverse(lines)
    _ -> list.reverse([last, ..lines])
  }
}

/// Sanitizes and caps untrusted comment prose.
///
/// ## Examples
///
/// ```gleam
/// assert render_text.clean("abc", 10) == "abc"
/// ```
pub fn clean(text: String, cap: Int) -> String {
  truncate(sanitize(text), cap)
}

/// Escapes text for the inside of a Gleam string literal. Total: `\` and
/// `"` are escaped, and any codepoint outside printable ASCII
/// (0x20–0x7E) is emitted as Gleam's `\u{...}` escape, so a literal can
/// never carry a raw newline, control character, or bidi override.
///
/// ## Examples
///
/// ```gleam
/// assert codegen.escape("a\"b\\c") == "a\\\"b\\\\c"
/// assert codegen.escape("名") == "\\u{540D}"
/// ```
///
pub fn escape(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.map(escape_codepoint)
  |> string.concat
}

fn escape_codepoint(codepoint: UtfCodepoint) -> String {
  let code = string.utf_codepoint_to_int(codepoint)
  case code {
    0x5C -> "\\\\"
    0x22 -> "\\\""
    _ if code >= 0x20 && code <= 0x7E -> string.from_utf_codepoints([codepoint])
    _ -> "\\u{" <> int.to_base16(code) <> "}"
  }
}

/// Places escaped text inside an inert source literal.
///
/// ## Examples
///
/// ```gleam
/// assert render_text.lit("abc") == "\"abc\""
/// ```
pub fn lit(text: String) -> String {
  "\"" <> escape(text) <> "\""
}
