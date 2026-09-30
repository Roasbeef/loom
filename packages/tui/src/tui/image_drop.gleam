//// Safe local image admission for terminal paste events.
////
//// A terminal drag arrives as pasted path text. This module removes only the
//// quoting forms terminals themselves add, never invokes a shell, and reads a
//// regular file only after its declared size fits the prompt limit. The local
//// path remains presentation state and is never part of a protocol block.
////
//// The read happens before the step, not in it. The host reads the path a
//// paste names with `load_paste` when it builds the step's message
//// (`runtime.message`), and the message carries what the read found
//// (`msg.Pasted`) to the composer's paste handler. The step therefore
//// touches no file, and a paste whose image attaches is still one event:
//// the image is in the composer when the step that handled the paste
//// returns, so a key pressed after the paste finds it there and pasted text
//// that is not an image keeps its place among the keys around it. Because
//// the read travels inside the message it was taken for, it cannot be
//// attached to another paste or outlive its event.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/pasted_image.{type Image, Image, max_image_bytes}
import simplifile
import tui/internal/ffi_file

/// Loads a pasted path when it names a supported image.
///
/// `Ok(None)` means the paste stays ordinary text. Inspection or read failures
/// return an explanation so the caller can leave the editor untouched.
///
/// This performs the file-system reads. Only the host calls it, when it
/// builds the message for a paste, before the step.
///
/// ## Examples
///
/// ```gleam
/// assert image_drop.load_paste("ordinary words") == Ok(None)
/// ```
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

/// Identifies the supported image formats from their magic bytes. The
/// answer is `session_view/pasted_image.media_type`'s, which the web page
/// shares.
///
/// ## Examples
///
/// ```gleam
/// assert image_drop.media_type(<<0xFF, 0xD8, 0xFF>>) == Some("image/jpeg")
/// ```
///
pub fn media_type(bytes: BitArray) -> Option(String) {
  pasted_image.media_type(bytes)
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
