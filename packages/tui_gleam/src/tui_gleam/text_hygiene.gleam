//// Terminal-safe text normalization.
////
//// Every server and model string is untrusted terminal input. The etui
//// buffer measures control characters as zero-width graphemes, but a backend
//// may still emit their bytes. Replacing controls before they reach a span
//// keeps model output from becoming terminal control traffic.

import gleam/list
import gleam/string

/// Replaces invisible and direction-changing codepoints while preserving line
/// feeds for markdown block parsing.
///
/// ## Examples
///
/// ```gleam
/// assert text_hygiene.multiline("one\r\ntwo") == "one\ntwo"
/// ```
pub fn multiline(text: String) -> String {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    case code == 0x0A, invisible(code) {
      True, _ -> "\n"
      False, True -> "�"
      False, False -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

/// Produces a terminal-safe value that cannot escape its current row.
///
/// ## Examples
///
/// ```gleam
/// assert text_hygiene.single_line("one\ntwo") == "one two"
/// ```
pub fn single_line(text: String) -> String {
  text |> multiline |> string.replace("\n", " ")
}

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
