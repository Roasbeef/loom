//// The transcript's images as the page addresses them and the daemon serves
//// them (protocol-change/051, the addendum on images).
////
//// A row of the transcript may carry images: a person's message, or a tool's
//// result. The page draws each as an `<img>` whose `src` is a same-origin
//// address, and the daemon answers that address with the bytes. The
//// stylesheet's `img-src 'self'` is what admits the request and is unchanged,
//// and nothing about the image travels as a `data:` or `blob:` URL.
////
//// This module holds the two halves' shared rules and none of their
//// machinery. `address` is the one place the address is built, and every
//// piece of it comes from the page: its session, the name of the row
//// (`session_view/transcript_image.ref`, built from the engine's own keys) and
//// a position. `serve` is the one place the bytes are checked before they are
//// answered with: the declared type must be one of four raster formats, the
//// base64 must decode, the size must fit, and the bytes' own magic number
//// must say the type that was declared. SVG is not among the four, since it
//// is markup and can carry script, and a same-origin response served with a
//// type the browser would render as a document would run under the page's
//// origin.
////
//// An address is relative to the page's own, which is
//// `/ui/p/<key>/sessions/<id>`. The page key is a secret the component never
//// holds, and a relative reference resolves against it, so the component
//// writes `<id>/image/<name>/<position>` and the browser makes it
//// `/ui/p/<key>/sessions/<id>/image/<name>/<position>`.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session_view/pasted_image
import session_view/transcript_image.{type Image}

/// The most bytes of one image the daemon answers with: the terminal's own
/// limit for an image (`pasted_image.max_image_bytes`), since nothing larger
/// can have been sent through either host.
pub const max_served_bytes = pasted_image.max_image_bytes

/// The most characters of a row's name the daemon considers. A name is a
/// block or step key with its slash replaced, digits and a few marks, and is
/// never near this long; the bound is what keeps a request from making the
/// daemon compare a megabyte of path.
pub const max_ref_length = 48

/// An image the daemon has checked and will answer with.
pub type Served {
  Served(
    /// The media type, one of the four raster types.
    mime_type: String,
    /// The image's bytes.
    bytes: BitArray,
  )
}

/// Why the daemon will not answer with an image.
pub type Refusal {
  /// The declared type is not a raster type, the base64 does not decode, or
  /// the bytes are not the type they were declared as.
  NotAnImage

  /// The image is larger than `max_served_bytes`.
  TooLarge
}

/// The address an image is drawn at, relative to the page's own.
///
/// ## Examples
///
/// ```gleam
/// assert image.address("0198", "7.0-2", 1) == "0198/image/7.0-2/1"
/// ```
pub fn address(session: String, ref: String, position: Int) -> String {
  session <> "/image/" <> ref <> "/" <> int.to_string(position)
}

/// Whether the page draws an image at all. A type outside the four raster
/// types is left to the row's own `[image <type>]` text, and no request is
/// ever made for it.
///
/// ## Examples
///
/// ```gleam
/// assert image.drawn(transcript_image.Image("image/png", "iVBOR"))
/// ```
pub fn drawn(image: Image) -> Bool {
  pasted_image.is_raster(image.mime_type)
}

/// Whether `ref` can be the name of a row: 1 to `max_ref_length` characters,
/// each a digit, `.`, `~` or `-`. The daemon checks it before it asks the page
/// for anything, and the page compares it with the names it drew, so a name
/// that is not one of the page's simply finds nothing.
///
/// ## Examples
///
/// ```gleam
/// assert image.plausible_ref("7.0-2")
/// assert !image.plausible_ref("../x")
/// ```
pub fn plausible_ref(ref: String) -> Bool {
  let marks = string.to_graphemes(ref)
  let length = list.length(marks)
  length >= 1 && length <= max_ref_length && list.all(marks, is_mark)
}

fn is_mark(grapheme: String) -> Bool {
  case grapheme {
    "." | "~" | "-" -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Checks one image the page holds before the daemon answers with it.
///
/// ## Examples
///
/// ```gleam
/// assert image.serve(transcript_image.Image("image/svg+xml", "PHN2Zz4="))
///   == Error(image.NotAnImage)
/// ```
pub fn serve(image: Image) -> Result(Served, Refusal) {
  // The base64 text of the largest admissible image is a third longer than
  // its bytes, so a longer text is refused before it is decoded.
  let encoded_limit = max_served_bytes / 3 * 4 + 4
  case drawn(image), string.byte_size(image.data) > encoded_limit {
    False, _ -> Error(NotAnImage)
    True, True -> Error(TooLarge)
    True, False -> checked(image)
  }
}

fn checked(image: Image) -> Result(Served, Refusal) {
  use bytes <- result.try(
    bit_array.base64_decode(image.data) |> result.replace_error(NotAnImage),
  )
  case bit_array.byte_size(bytes) > max_served_bytes {
    True -> Error(TooLarge)
    False ->
      case pasted_image.media_type(bytes) == Some(image.mime_type) {
        True -> Ok(Served(image.mime_type, bytes))
        False -> Error(NotAnImage)
      }
  }
}
