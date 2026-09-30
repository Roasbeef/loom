//// An image the composer holds, as data.
////
//// The record is separate from `tui/image_drop`, which reads a dropped file
//// from disk, because the composer and the transcript only carry and show
//// an image that has already been read. Keeping the file read out of this
//// module keeps the composer free of the file system.
////
//// The module also names which images a host admits: the four raster
//// formats every provider adapter reads, identified by the bytes' own magic
//// numbers and never by a file name or a declared type. The terminal
//// (`tui/image_drop`) and the web page's composer and image route
//// (`web_view/image`) both decide by it, so the two hosts agree on what an
//// image is.

import gleam/option.{type Option, None, Some}

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

/// Identifies the supported raster formats from their magic bytes: PNG,
/// JPEG, GIF and WebP. Anything else, SVG included, is `None`.
///
/// ## Examples
///
/// ```gleam
/// assert pasted_image.media_type(<<0xFF, 0xD8, 0xFF>>) == Some("image/jpeg")
/// assert pasted_image.media_type(<<"<svg":utf8>>) == None
/// ```
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

/// Whether `mime_type` names one of the raster formats `media_type` can
/// identify. A declared type is a claim and not evidence, so a host that
/// serves or accepts bytes checks the bytes with `media_type` as well.
///
/// ## Examples
///
/// ```gleam
/// assert pasted_image.is_raster("image/png")
/// assert !pasted_image.is_raster("image/svg+xml")
/// ```
pub fn is_raster(mime_type: String) -> Bool {
  case mime_type {
    "image/png" | "image/jpeg" | "image/gif" | "image/webp" -> True
    _ -> False
  }
}
