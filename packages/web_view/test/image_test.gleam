//// `web_view/image`: how the page addresses a transcript image and what the
//// daemon checks before it answers with one (protocol-change/051, the
//// addendum on images). A response served from the page's own origin with a
//// type a browser renders as a document would run under that origin, so each
//// refusal here is one way the bytes could be something other than a picture.

import gleam/bit_array
import gleam/string
import session_view/transcript_image.{Image}
import web_view/image

const png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

fn encoded(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, True)
}

pub fn an_address_is_relative_to_the_pages_own_test() {
  assert image.address("0198", "7.0-2", 1) == "0198/image/7.0-2/1"
}

pub fn a_row_name_holds_only_digits_and_three_marks_test() {
  assert image.plausible_ref("7.0")
  assert image.plausible_ref("7.0-2")
  assert image.plausible_ref("12.3~-4")
  assert !image.plausible_ref("")
  assert !image.plausible_ref("../x")
  assert !image.plausible_ref("7.0/2")
  assert !image.plausible_ref("7.0 2")
  assert !image.plausible_ref("%2e")
  assert !image.plausible_ref("a")
  assert image.plausible_ref(string.repeat("1", image.max_ref_length))
  assert !image.plausible_ref(string.repeat("1", image.max_ref_length + 1))
}

pub fn only_the_four_raster_types_are_drawn_test() {
  assert image.drawn(Image("image/png", "x"))
  assert image.drawn(Image("image/jpeg", "x"))
  assert image.drawn(Image("image/gif", "x"))
  assert image.drawn(Image("image/webp", "x"))
  assert !image.drawn(Image("image/svg+xml", "x"))
  assert !image.drawn(Image("text/html", "x"))
  assert !image.drawn(Image("image/x-<b>", "x"))
}

pub fn a_png_is_served_with_its_type_and_bytes_test() {
  let bytes = <<png_header:bits, 1, 2, 3>>
  assert image.serve(Image("image/png", encoded(bytes)))
    == Ok(image.Served("image/png", bytes))
}

pub fn an_svg_is_refused_however_it_is_declared_test() {
  let svg = <<"<svg xmlns=\"http://www.w3.org/2000/svg\"><script/></svg>":utf8>>

  // Declared as what it is, and declared as a PNG to slip past the type
  // check: the first fails the allowlist and the second the magic number.
  assert image.serve(Image("image/svg+xml", encoded(svg)))
    == Error(image.NotAnImage)
  assert image.serve(Image("image/png", encoded(svg)))
    == Error(image.NotAnImage)
}

pub fn html_declared_as_an_image_is_refused_test() {
  let html = <<"<html><script>alert(1)</script></html>":utf8>>
  assert image.serve(Image("image/gif", encoded(html)))
    == Error(image.NotAnImage)
}

pub fn a_declared_type_must_be_the_one_the_bytes_say_test() {
  let jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0>>
  assert image.serve(Image("image/png", encoded(jpeg)))
    == Error(image.NotAnImage)
  assert image.serve(Image("image/jpeg", encoded(jpeg)))
    == Ok(image.Served("image/jpeg", jpeg))
}

pub fn text_that_is_not_base64_is_refused_test() {
  assert image.serve(Image("image/png", "not base64 !!"))
    == Error(image.NotAnImage)
  assert image.serve(Image("image/png", "")) == Error(image.NotAnImage)
}

// An image of exactly `total` bytes that begins as a PNG does.
fn png_of(total: Int) -> BitArray {
  let padding = total - bit_array.byte_size(png_header)
  <<png_header:bits, 0:size({ padding * 8 })>>
}

pub fn the_largest_image_the_terminal_admits_is_served_test() {
  let bytes = png_of(image.max_served_bytes)
  assert image.serve(Image("image/png", encoded(bytes)))
    == Ok(image.Served("image/png", bytes))
}

pub fn one_byte_more_is_refused_after_the_decode_test() {
  // Its base64 text is exactly as long as the largest admissible image's, so
  // the length check lets it through and the byte count is what refuses it.
  let bytes = png_of(image.max_served_bytes + 1)
  assert image.serve(Image("image/png", encoded(bytes)))
    == Error(image.TooLarge)
}

pub fn text_longer_than_any_admissible_image_is_refused_undecoded_test() {
  assert image.serve(Image(
      "image/png",
      string.repeat("A", image.max_served_bytes * 2),
    ))
    == Error(image.TooLarge)
}
