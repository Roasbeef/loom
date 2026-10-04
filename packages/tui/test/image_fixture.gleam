//// Images for the tests that draw them.
////
//// Most tests need an image only for what its header says and for the
//// signature of its bytes, so `png` builds the opening of a PNG whose header
//// claims any size, and `corrupt` builds one that the header reader accepts
//// but whose whole is not valid base64. `chart` is a real, complete PNG, a
//// bar chart in flat colours that compresses to under two kilobytes, for the
//// review render that a person looks at in a terminal that draws it.

import gleam/bit_array
import gleam/string
import tui/demo_image

/// The opening of a PNG whose header says `width` by `height`, as base64.
/// The signature is real, so the bytes pass a PNG check; the rest is zeros,
/// so it is not an image a terminal can show.
///
/// ## Examples
///
/// ```gleam
/// let data = image_fixture.png(1200, 700)
/// ```
pub fn png(width: Int, height: Int) -> String {
  <<
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, width:32,
    height:32, 8, 6, 0, 0, 0, 0:size(1024)-unit(8),
  >>
  |> bit_array.base64_encode(True)
}

/// The same opening with `seed` mixed into the body, so two images of one
/// size differ in the samples a fingerprint takes.
///
/// ## Examples
///
/// ```gleam
/// assert image_fixture.png_seeded(8, 8, "a") != image_fixture.png_seeded(8, 8, "b")
/// ```
pub fn png_seeded(width: Int, height: Int, seed: String) -> String {
  <<
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, width:32,
    height:32, 8, 6, 0, 0, 0, seed:utf8, 0:size(1024)-unit(8), seed:utf8,
  >>
  |> bit_array.base64_encode(True)
}

/// A PNG whose header reads, followed by enough valid base64 that the
/// header reader's prefix is whole, and then a character that is not base64:
/// the picture exists, and decoding it fails.
///
/// ## Examples
///
/// ```gleam
/// let data = image_fixture.corrupt(640, 480)
/// ```
pub fn corrupt(width: Int, height: Int) -> String {
  png(width, height) <> string.repeat("A", 90_000) <> "!"
}

/// A PNG of `bytes` decoded bytes: a real header and a body of zeros, more
/// than the budget for an image when `bytes` is large.
///
/// ## Examples
///
/// ```gleam
/// let data = image_fixture.heavy(1200, 700, 5_000_000)
/// ```
pub fn heavy(width: Int, height: Int, bytes: Int) -> String {
  <<
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, width:32,
    height:32, 8, 6, 0, 0, 0, 0:size(bytes)-unit(8),
  >>
  |> bit_array.base64_encode(True)
}

/// The opening of a JPEG whose start-of-frame says `width` by `height`.
///
/// ## Examples
///
/// ```gleam
/// let data = image_fixture.jpeg(640, 480)
/// ```
pub fn jpeg(width: Int, height: Int) -> String {
  <<
    0xFF, 0xD8, 0xFF, 0xE0, 16:16, 0:size(14)-unit(8), 0xFF, 0xC0, 17:16, 8,
    height:16, width:16, 3, 0:size(9)-unit(8),
  >>
  |> bit_array.base64_encode(True)
}

/// A complete 480 by 280 PNG: six bars of rising height on a dark ground
/// inside a white frame. Scaled or placed wrongly, it shows. It is the image
/// the `--demo` launch carries, kept in one place (`tui/demo_image`).
///
/// ## Examples
///
/// ```gleam
/// let data = image_fixture.chart()
/// ```
pub fn chart() -> String {
  demo_image.chart()
}
