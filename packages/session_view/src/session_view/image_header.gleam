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
////
//// A host that can draw the picture needs more than the words: it must tell
//// this image from another without carrying the image in a transcript line,
//// which is a cache key and has to stay small. `picture` gives that
//// identity, a fingerprint of the data, together with the facts a host
//// needs to size a box before it has decoded anything.

import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// What a host that draws an image needs to know about it before it holds
/// the image: which image it is, what it claims to be, how large it says it
/// is, and how many bytes it weighs.
///
/// A picture is built only when the header can be read, so a line that
/// carries one has a pixel size a box can be fitted to. The fingerprint is
/// not a hash: it is the byte count and three short samples of the data,
/// which stays cheap on a multi-megabyte string and is enough to tell two
/// different images of one size apart.
pub type Picture {
  Picture(
    /// The image's identity, as `fingerprint` computes it.
    fingerprint: String,
    /// The media type the entry declares. It is a claim about the bytes.
    mime_type: String,
    /// The pixel width the header declares.
    width: Int,
    /// The pixel height the header declares.
    height: Int,
    /// The decoded size of the image in bytes.
    bytes: Int,
  )
}

/// The picture of an image, or `None` when its header cannot be read.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.picture("image/png", "aGk=") == option.None
/// ```
pub fn picture(mime_type: String, data: String) -> Option(Picture) {
  case dimensions(data) {
    Some(#(width, height)) ->
      Some(Picture(
        fingerprint: fingerprint(data),
        mime_type:,
        width:,
        height:,
        bytes: byte_size(data),
      ))
    None -> None
  }
}

/// The identity of an image's data: its length, and the first, middle and
/// last 32 bytes of the base64 text.
///
/// The head of an image is its header, which two screenshots of one window
/// share, so the middle and the tail carry the difference. The samples are
/// taken from the binary, so the cost does not grow with the image.
///
/// ## Examples
///
/// ```gleam
/// assert image_header.fingerprint("aGk=") == "4:aGk=:aGk=:aGk="
/// ```
pub fn fingerprint(data: String) -> String {
  let bytes = bit_array.from_string(data)
  let size = bit_array.byte_size(bytes)
  int.to_string(size)
  <> ":"
  <> sample(bytes, 0)
  <> ":"
  <> sample(bytes, size / 2 - 16)
  <> ":"
  <> sample(bytes, size - 32)
}

// Up to 32 bytes of the text from `at`, which is clamped into the data.
// Base64 is ASCII, so a slice never splits a character; anything that is
// not text samples as nothing.
fn sample(bytes: BitArray, at: Int) -> String {
  let size = bit_array.byte_size(bytes)
  let start = int.clamp(at, 0, int.max(0, size - 32))
  bit_array.slice(bytes, start, int.min(32, size - start))
  |> result.try(bit_array.to_string)
  |> result.unwrap("")
}

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
  let length = string.byte_size(data)
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
