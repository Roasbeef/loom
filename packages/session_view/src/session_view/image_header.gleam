//// What a transcript can say about an image without drawing it.
////
//// An image a tool returned, or a person attached, is held in its entry as
//// base64 text with a declared media type. A terminal that cannot draw it
//// still owes the reader what it is: its type, its size in pixels and its
//// size in bytes. This module reads the pixel size from the header of a
//// PNG, a JPEG or a GIF, which is where each keeps it, and builds the one
//// row of words the transcript draws for an image.
////
//// The header is a claim made by bytes the model or a tool chose, so it is
//// read totally: a short, truncated or malformed header answers `None`,
//// and the row then says nothing about the pixel size rather than
//// something wrong. Only the opening of the data is decoded, since every
//// header this reads sits in its first 64 KiB, and the byte size comes
//// from the base64 length without decoding the rest. The module is pure
//// and portable (lint R6).

import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/text_hygiene

/// The pixel width and height an image's header declares, or `None` when
/// the header is not a PNG's, a JPEG's or a GIF's, or cannot be read.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.dimensions("") == option.None
/// ```
pub fn dimensions(data: String) -> Option(#(Int, Int)) {
  // 87,380 base64 characters decode to 65,535 bytes, and the count is a
  // multiple of four, so the prefix decodes on its own.
  case bit_array.base64_decode(string.slice(data, 0, 87_380)) {
    Ok(bytes) -> header(bytes)
    Error(Nil) -> None
  }
}

// The three headers, by their signatures.
fn header(bytes: BitArray) -> Option(#(Int, Int)) {
  case bytes {
    <<
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      _length:32,
      "IHDR",
      width:32,
      height:32,
      _:bits,
    >> -> positive(width, height)
    <<"GIF8", _version:16, width:16-little, height:16-little, _:bits>> ->
      positive(width, height)
    <<0xFF, 0xD8, rest:bits>> -> jpeg(rest)
    _ -> None
  }
}

// A JPEG's size is in its start-of-frame segment, after any number of
// others; each segment states its length, so the walk skips them whole.
fn jpeg(bytes: BitArray) -> Option(#(Int, Int)) {
  case bytes {
    <<0xFF, 0xFF, rest:bits>> -> jpeg(<<0xFF, rest:bits>>)
    <<0xFF, marker, _length:16, _precision, height:16, width:16, _:bits>>
      if marker >= 0xC0
      && marker <= 0xCF
      && marker != 0xC4
      && marker != 0xC8
      && marker != 0xCC
    -> positive(width, height)
    <<0xFF, marker, rest:bits>>
      if marker == 0x01 || { marker >= 0xD0 && marker <= 0xD7 }
    -> jpeg(rest)
    <<0xFF, _marker, length:16, rest:bits>> if length >= 2 ->
      case
        bit_array.slice(
          rest,
          length - 2,
          bit_array.byte_size(rest) - length + 2,
        )
      {
        Ok(after) -> jpeg(after)
        Error(Nil) -> None
      }
    _ -> None
  }
}

fn positive(width: Int, height: Int) -> Option(#(Int, Int)) {
  case width > 0 && height > 0 {
    True -> Some(#(width, height))
    False -> None
  }
}

/// The number of bytes base64 `data` decodes to, read from its length and
/// its padding without decoding it.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.byte_size("aGk=") == 2
/// ```
pub fn byte_size(data: String) -> Int {
  let length = string.length(data)
  let padding = case string.ends_with(data, "==") {
    True -> 2
    False ->
      case string.ends_with(data, "=") {
        True -> 1
        False -> 0
      }
  }
  int.max(0, length / 4 * 3 - padding)
}

/// A byte count as a reader says it: `512 B`, `84 KB`, `1.2 MB`.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.size_text(86_016) == "84 KB"
/// ```
pub fn size_text(bytes: Int) -> String {
  case bytes < 1024, bytes < 1024 * 1024 {
    True, _ -> int.to_string(bytes) <> " B"
    False, True -> int.to_string({ bytes + 512 } / 1024) <> " KB"
    False, False -> {
      let tenths = { bytes * 10 + 524_288 } / 1_048_576
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " MB"
    }
  }
}

/// The words of an image's row: its place among its row's images, its
/// media type, its pixel size when the header says, and its byte size,
/// `image 1 · image/png · 1200×700 · 84 KB`.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.describe(1, "image/png", "aGk=")
///   == "image 1 · image/png · 2 B"
/// ```
pub fn describe(position: Int, mime_type: String, data: String) -> String {
  let pixels = case dimensions(data) {
    Some(#(width, height)) ->
      " · " <> int.to_string(width) <> "×" <> int.to_string(height)
    None -> ""
  }
  "image "
  <> int.to_string(position)
  <> " · "
  <> text_hygiene.single_line(mime_type)
  <> pixels
  <> " · "
  <> size_text(byte_size(data))
}
