//// The identity a transcript row carries for an image it could be drawn from.
////
//// A row is a cache key, so it holds a fingerprint and the header's facts
//// rather than the image. The fingerprint has to tell two images apart that
//// share a size and a header, and it has to cost the same on a large image
//// as on a small one.

import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import session_view/image_header

// A PNG header for `width` by `height`, then `body` as the rest of the file.
fn png(width: Int, height: Int, body: String) -> String {
  <<
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, width:32,
    height:32, 8, 6, 0, 0, 0, body:utf8,
  >>
  |> bit_array.base64_encode(True)
}

pub fn a_readable_header_makes_a_picture_test() {
  let data = png(1200, 700, string.repeat("pixels ", 200))
  let assert Some(picture) = image_header.picture("image/png", data)
  assert picture.width == 1200
  assert picture.height == 700
  assert picture.mime_type == "image/png"
  assert picture.bytes == image_header.byte_size(data)
  assert picture.fingerprint == image_header.fingerprint(data)
}

pub fn an_unreadable_header_makes_no_picture_test() {
  assert image_header.picture("image/png", "bm90IGFuIGltYWdl") == None
  assert image_header.picture("image/png", "") == None
}

pub fn two_images_of_one_size_have_different_fingerprints_test() {
  let first = png(640, 480, string.repeat("a", 600) <> "end-one")
  let second = png(640, 480, string.repeat("a", 600) <> "end-two")
  assert image_header.fingerprint(first) != image_header.fingerprint(second)
  assert image_header.fingerprint(first) == image_header.fingerprint(first)
}

pub fn a_middle_difference_changes_the_fingerprint_test() {
  let first = png(640, 480, string.repeat("a", 900))
  let second =
    png(
      640,
      480,
      string.repeat("a", 430) <> "different" <> string.repeat("a", 461),
    )
  assert image_header.fingerprint(first) != image_header.fingerprint(second)
}

pub fn a_short_text_is_its_own_samples_test() {
  assert image_header.fingerprint("aGk=") == "4:aGk=:aGk=:aGk="
  assert image_header.fingerprint("") == "0:::"
}
