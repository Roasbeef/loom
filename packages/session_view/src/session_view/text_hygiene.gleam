//// Terminal-safe text normalization.
////
//// Every server and model string is untrusted terminal input. The etui
//// buffer measures control characters as zero-width graphemes, but a backend
//// may still emit their bytes. Replacing controls before they reach a span
//// keeps model output from becoming terminal control traffic.

import gleam/bit_array
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
  case unchanged_prefix(text) == string.byte_size(text) {
    // Most displayed labels and transcript text need no rewrite. The empty
    // second segment makes concat copy on the BEAM even for a single input,
    // so a small slice cannot keep a large incoming frame alive. The scan
    // avoids building and reversing a codepoint list just to copy safe text.
    True -> string.concat([text, ""])
    False ->
      text
      |> string.replace("\r\n", "\n")
      |> string.replace("\r", "\n")
      |> strip_terminal_sequences
  }
}

// Complete terminal escape sequences are formatting instructions rather than
// transcript text. Removing them as units avoids leaving their visible CSI or
// OSC payload behind after the leading control byte is replaced. The same
// pass replaces unsafe codepoints, so safe text is decoded and rebuilt only
// once rather than allocating a separate one-character string for each codepoint.
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
        None -> strip_sequences(rest, keep_visible(first, kept))
      }
  }
}

// Keep codepoints until the final string construction. This also preserves
// owned output rather than returning a slice of the untrusted input buffer.
fn keep_visible(first: UtfCodepoint, kept: List(UtfCodepoint)) {
  let code = string.utf_codepoint_to_int(first)

  // Tabs are ordinary source indentation, but cannot reach the terminal as
  // control bytes. Four literal spaces keep them readable in every renderer.
  case code == 0x09, code != 0x0A && invisible(code) {
    True, _ -> list.append(string.to_utf_codepoints("    "), kept)
    False, True -> list.append(string.to_utf_codepoints("�"), kept)
    False, False -> [first, ..kept]
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
  csi_tail_with(remaining, False)
}

fn csi_tail_with(
  remaining: List(UtfCodepoint),
  intermediates_started: Bool,
) -> Option(List(UtfCodepoint)) {
  case remaining {
    [] -> None
    [first, ..rest] -> {
      let code = string.utf_codepoint_to_int(first)
      case
        code >= 0x40 && code <= 0x7E,
        code >= 0x30 && code <= 0x3F && !intermediates_started,
        code >= 0x20 && code <= 0x2F
      {
        True, _, _ -> Some(rest)
        False, True, _ -> csi_tail_with(rest, False)
        False, False, True -> csi_tail_with(rest, True)
        False, False, False -> None
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

/// How many leading bytes of `text` `multiline` leaves exactly as they are,
/// whatever follows them.
///
/// The prefix ends before the first codepoint the pass would replace, drop
/// or rewrite: a carriage return, a tab, an escape that opens a sequence, or
/// any other control, format or direction codepoint. None of those is in the
/// prefix, so no rewrite can start in it and none that starts later reaches
/// back into it, and for `n = unchanged_prefix(text)` the pass satisfies
///
/// `multiline(text) == first n bytes of text <> multiline(the rest)`.
///
/// A host that sanitizes a growing text can therefore keep the prefix it has
/// already checked and pass only what follows it, and when the whole text is
/// unchanged it need not rebuild the text at all. The scan reads a byte or a
/// codepoint per step without decoding the text into a list.
///
/// ## Examples
///
/// ```gleam
/// assert text_hygiene.unchanged_prefix("plain text") == 10
/// assert text_hygiene.unchanged_prefix("one\r\ntwo") == 3
/// ```
pub fn unchanged_prefix(text: String) -> Int {
  unchanged_bytes(bit_array.from_string(text), 0)
}

// One step of `unchanged_prefix`. Printable ASCII and the line feed are the
// common case and are checked by value; a longer UTF-8 sequence is decoded
// by arithmetic, which every target supports, and kept unless `invisible`
// says the pass would replace it. The text is a `String`, so every sequence
// is well formed and the arms below are the only shapes it can take.
fn unchanged_bytes(bits: BitArray, count: Int) -> Int {
  case bits {
    <<byte, rest:bytes>> if byte >= 0x20 && byte < 0x7F ->
      unchanged_bytes(rest, count + 1)
    <<0x0A, rest:bytes>> -> unchanged_bytes(rest, count + 1)
    <<lead, second, rest:bytes>> if lead >= 0xC2 && lead < 0xE0 ->
      kept_codepoint(rest, count, 2, { lead - 0xC0 } * 64 + second - 0x80)
    <<lead, second, third, rest:bytes>> if lead >= 0xE0 && lead < 0xF0 ->
      kept_codepoint(
        rest,
        count,
        3,
        { lead - 0xE0 } * 4096 + { second - 0x80 } * 64 + third - 0x80,
      )
    <<lead, second, third, fourth, rest:bytes>> if lead >= 0xF0 -> {
      let high = { lead - 0xF0 } * 262_144 + { second - 0x80 } * 4096
      let code = high + { third - 0x80 } * 64 + fourth - 0x80
      kept_codepoint(rest, count, 4, code)
    }
    _ -> count
  }
}

// A decoded codepoint of `width` bytes extends the prefix past it if the
// pass keeps it, and ends the prefix where it begins if the pass replaces it.
fn kept_codepoint(rest: BitArray, count: Int, width: Int, code: Int) -> Int {
  case invisible(code) {
    True -> count
    False -> unchanged_bytes(rest, count + width)
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

/// Keeps the last `width` graphemes of a value, marking any cut with `…`.
///
/// A fixed-height overlay row must survive its own clip rather than reflow
/// into the row below, so an over-wide path or identifier is cut here instead.
/// The cut takes the front because a canonical path and a catalogue model id
/// share their leading segments; the tail is what tells two rows apart.
///
/// ## Examples
///
/// ```gleam
/// assert text_hygiene.fit_tail("/home/me/work/project", 10) == "…k/project"
/// ```
pub fn fit_tail(text: String, width: Int) -> String {
  let length = string.length(text)
  case width <= 0, length <= width {
    True, _ -> ""
    False, True -> text
    False, False ->
      "…"
      <> string.slice(text, at_index: length - { width - 1 }, length: width - 1)
  }
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
