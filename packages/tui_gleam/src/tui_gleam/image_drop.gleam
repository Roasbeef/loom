//// Safe local image admission for terminal paste events.
////
//// A terminal drag arrives as pasted path text. This module removes only the
//// quoting forms terminals themselves add, never invokes a shell, and reads a
//// regular file only after its declared size fits the prompt limit. The local
//// path remains presentation state and is never part of a protocol block.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tui_gleam/internal/ffi_file

/// The largest image file admitted before a prompt frame is constructed.
pub const max_image_bytes = 20_971_520

/// One locally admitted image attachment.
pub type Image {
  Image(
    /// The local path used only for later presentation and removal.
    local_path: String,
    /// The path's final component shown in the composer.
    filename: String,
    /// The media type established from magic bytes, not the extension.
    mime_type: String,
    /// The exact file size read into the attachment.
    byte_size: Int,
    /// Base64-encoded image bytes sent through the typed user-block codec.
    data: String,
  )
}

/// Loads a pasted path when it names a supported image.
///
/// `Ok(None)` means the paste stays ordinary text. Inspection or read failures
/// return an explanation so the caller can leave the editor untouched.
///
/// ## Examples
///
/// ```gleam
/// assert image_drop.load_paste("ordinary words") == Ok(None)
/// ```
///
pub fn load_paste(text: String) -> Result(Option(Image), String) {
  case pasted_path(text) {
    None -> Ok(None)
    Some(path) -> load_path(path)
  }
}

fn load_path(path: String) -> Result(Option(Image), String) {
  use info <- result.try(case simplifile.file_info(path) {
    Ok(info) -> Ok(Some(info))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error("cannot inspect dropped file: " <> simplifile.describe_error(error))
  })
  case info {
    None -> Ok(None)
    Some(info) ->
      case simplifile.file_info_type(info) == simplifile.File {
        False -> Ok(None)
        True -> inspect_image(path, info.size)
      }
  }
}

fn inspect_image(
  path: String,
  stated_size: Int,
) -> Result(Option(Image), String) {
  use header <- result.try(
    ffi_file.read_prefix(path, 12)
    |> result.map_error(fn(reason) { "cannot read dropped file: " <> reason }),
  )
  case media_type(header) {
    None -> Ok(None)
    Some(_) -> read_image(path, stated_size)
  }
}

fn read_image(path: String, stated_size: Int) -> Result(Option(Image), String) {
  use _ <- result.try(admit_size(stated_size))
  use bytes <- result.try(
    ffi_file.read_bounded(path, max_image_bytes)
    |> result.map_error(fn(reason) { "cannot read dropped file: " <> reason }),
  )
  let byte_size = bit_array.byte_size(bytes)
  use _ <- result.try(admit_size(byte_size))
  case media_type(bytes) {
    None -> Ok(None)
    Some(mime_type) ->
      Ok(
        Some(Image(
          local_path: path,
          filename: filename(path),
          mime_type:,
          byte_size:,
          data: bit_array.base64_encode(bytes, True),
        )),
      )
  }
}

fn admit_size(size: Int) -> Result(Nil, String) {
  case size_allowed(size) {
    True -> Ok(Nil)
    False -> Error("dropped image exceeds the 20 MiB limit")
  }
}

/// Reports whether an image size fits the pre-frame admission limit.
@internal
pub fn size_allowed(size: Int) -> Bool {
  case size <= max_image_bytes {
    True -> True
    False -> False
  }
}

/// Identifies the supported image formats from their magic bytes.
///
/// ## Examples
///
/// ```gleam
/// assert image_drop.media_type(<<0xFF, 0xD8, 0xFF>>) == Some("image/jpeg")
/// ```
///
pub fn media_type(bytes: BitArray) -> Option(String) {
  case bytes {
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> ->
      Some("image/png")
    <<0xFF, 0xD8, 0xFF, _:bits>> -> Some("image/jpeg")
    <<"GIF87a", _:bits>> | <<"GIF89a", _:bits>> -> Some("image/gif")
    <<"RIFF", _:size(32), "WEBP", _:bits>> -> Some("image/webp")
    _ -> None
  }
}

/// Resolves only terminal quote and backslash-space escaping into one path.
///
/// Unquoted whitespace means the paste contains more than one token and stays
/// text. No expansion, substitution, globbing, or command evaluation occurs.
///
/// ## Examples
///
/// ```gleam
/// assert image_drop.pasted_path("/tmp/a\\ b.png") == Some("/tmp/a b.png")
/// assert image_drop.pasted_path("a.png b.png") == None
/// ```
///
pub fn pasted_path(text: String) -> Option(String) {
  let text = string.trim(text)
  case string.to_graphemes(text) {
    ["\"", ..rest] -> quoted_path(rest, "\"")
    ["'", ..rest] -> quoted_path(rest, "'")
    [] -> None
    graphemes -> unescape_path(graphemes, [])
  }
}

fn quoted_path(graphemes: List(String), quote: String) -> Option(String) {
  case list.reverse(graphemes) {
    [last, ..rest] if last == quote ->
      rest |> list.reverse |> string.concat |> non_empty
    _ -> None
  }
}

fn unescape_path(
  graphemes: List(String),
  reversed: List(String),
) -> Option(String) {
  case graphemes {
    [] -> reversed |> list.reverse |> string.concat |> non_empty
    ["\\", " ", ..rest] -> unescape_path(rest, [" ", ..reversed])
    [" ", ..] | ["\t", ..] | ["\n", ..] | ["\r", ..] -> None
    [grapheme, ..rest] -> unescape_path(rest, [grapheme, ..reversed])
  }
}

fn non_empty(text: String) -> Option(String) {
  case text == "" {
    True -> None
    False -> Some(text)
  }
}

fn filename(path: String) -> String {
  path
  |> string.replace("\\", "/")
  |> string.split("/")
  |> last_non_empty(path)
}

fn last_non_empty(parts: List(String), fallback: String) -> String {
  case list.reverse(parts) {
    ["", ..rest] -> last_non_empty(list.reverse(rest), fallback)
    [part, ..] -> part
    [] -> fallback
  }
}
