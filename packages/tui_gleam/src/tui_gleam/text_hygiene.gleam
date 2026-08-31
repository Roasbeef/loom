//// Terminal-safe text normalization.
////
//// Every server and model string is untrusted terminal input. The etui
//// buffer measures control characters as zero-width graphemes, but a backend
//// may still emit their bytes. Replacing controls before they reach a span
//// keeps model output from becoming terminal control traffic.

import gleam/list
import gleam/option.{type Option, None, Some}
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
  |> strip_terminal_sequences
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

// Complete terminal escape sequences are formatting instructions rather than
// transcript text. Removing them as units avoids leaving their visible CSI or
// OSC payload behind after the leading control byte is replaced.
fn strip_terminal_sequences(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> strip_sequences([])
  |> list.reverse
  |> string.from_utf_codepoints
}

fn strip_sequences(
  remaining: List(UtfCodepoint),
  kept: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case remaining {
    [] -> kept
    [first, ..rest] ->
      case terminal_sequence_tail(first, rest) {
        Some(after) -> strip_sequences(after, kept)
        None -> strip_sequences(rest, [first, ..kept])
      }
  }
}

fn terminal_sequence_tail(
  first: UtfCodepoint,
  rest: List(UtfCodepoint),
) -> Option(List(UtfCodepoint)) {
  case string.utf_codepoint_to_int(first) {
    0x1B -> escape_sequence_tail(rest)
    0x9B -> csi_tail(rest)
    0x9D -> osc_tail(rest)
    _ -> None
  }
}

fn escape_sequence_tail(
  remaining: List(UtfCodepoint),
) -> Option(List(UtfCodepoint)) {
  case remaining {
    [kind, ..rest] ->
      case string.utf_codepoint_to_int(kind) {
        0x5B -> csi_tail(rest)
        0x5D -> osc_tail(rest)
        _ -> None
      }
    [] -> None
  }
}

fn csi_tail(remaining: List(UtfCodepoint)) -> Option(List(UtfCodepoint)) {
  case remaining {
    [] -> None
    [first, ..rest] -> {
      let code = string.utf_codepoint_to_int(first)
      case code >= 0x40 && code <= 0x7E {
        True -> Some(rest)
        False -> csi_tail(rest)
      }
    }
  }
}

fn osc_tail(remaining: List(UtfCodepoint)) -> Option(List(UtfCodepoint)) {
  case remaining {
    [] -> None
    [first, ..rest] ->
      case string.utf_codepoint_to_int(first) {
        0x07 -> Some(rest)
        0x9C -> Some(rest)
        0x1B -> osc_escape_tail(rest)
        _ -> osc_tail(rest)
      }
  }
}

fn osc_escape_tail(
  remaining: List(UtfCodepoint),
) -> Option(List(UtfCodepoint)) {
  case remaining {
    [] -> None
    [first, ..rest] ->
      case string.utf_codepoint_to_int(first) == 0x5C {
        True -> Some(rest)
        False -> osc_tail(remaining)
      }
  }
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
