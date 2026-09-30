//// `web_view/image`: how the page addresses a transcript image and what the
//// daemon checks before it answers with one (protocol-change/051, the
//// addendum on images). A response served from the page's own origin with a
//// type a browser renders as a document would run under that origin, so each
//// refusal here is one way the bytes could be something other than a picture.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import session_view/composer
import session_view/pasted_image
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

// --- what the composer may attach -------------------------------------------

pub fn no_images_admit_to_no_images_test() {
  assert image.admit([]) == Ok([])
}

pub fn an_image_is_admitted_by_its_bytes_and_sent_canonically_test() {
  let bytes = <<png_header:bits, 1, 2, 3, 4>>
  let assert Ok([admitted]) = image.admit([encoded(bytes)])
    as "a PNG is admitted"
  assert admitted
    == pasted_image.Image(
      local_path: "",
      filename: "attached image",
      mime_type: "image/png",
      byte_size: 12,
      data: encoded(bytes),
    )
}

pub fn the_type_is_the_bytes_and_never_the_browsers_claim_test() {
  let jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0>>
  let gif = <<"GIF89a":utf8, 0>>
  let webp = <<"RIFF":utf8, 0:32, "WEBP":utf8>>
  let assert Ok(images) =
    image.admit([encoded(jpeg), encoded(gif), encoded(webp)])
    as "each is admitted"
  assert list.map(images, fn(admitted) { admitted.mime_type })
    == ["image/jpeg", "image/gif", "image/webp"]
}

pub fn markup_is_not_an_image_however_it_arrives_test() {
  let refusal =
    Error(
      "Only PNG, JPEG, GIF and WebP images can be attached. Nothing was sent.",
    )
  assert image.admit([encoded(<<"<svg xmlns=\"x\"><script/></svg>":utf8>>)])
    == refusal
  assert image.admit([encoded(<<"<html></html>":utf8>>)]) == refusal
  assert image.admit([encoded(<<>>)]) == refusal
  assert image.admit([encoded(<<png_header:bits, 1>>), encoded(<<"x":utf8>>)])
    == refusal
}

pub fn an_attachment_that_is_not_base64_is_refused_test() {
  assert image.admit(["not base64 !!"])
    == Error("An attached image is not valid base64. Nothing was sent.")
  assert image.admit(["data:image/png;base64,iVBORw0KGgo="])
    == Error("An attached image is not valid base64. Nothing was sent.")
}

pub fn at_most_four_images_are_admitted_test() {
  let one = encoded(<<png_header:bits, 1>>)
  let assert Ok(four) = image.admit(list.repeat(one, image.max_attached))
    as "four are admitted"
  assert list.length(four) == 4
  assert image.admit(list.repeat(one, image.max_attached + 1))
    == Error("A prompt carries at most 4 images. Nothing was sent.")
}

pub fn the_images_of_one_prompt_total_at_most_eight_mebibytes_test() {
  let half = encoded(png_of(image.max_attached_bytes / 2))
  assert list.length(result.unwrap(image.admit([half, half]), [])) == 2
  let over = encoded(png_of(image.max_attached_bytes / 2 + 1))
  assert image.admit([half, over])
    == Error("The images total more than 8 MiB. Nothing was sent.")
}

pub fn the_element_is_told_the_daemons_own_limits_test() {
  assert image.limits_attribute()
    == "{\"count\":4,\"bytes\":8388608,\"types\":[\"image/png\",\"image/jpeg\",\"image/gif\",\"image/webp\"]}"
  assert list.all(image.raster_types, pasted_image.is_raster)
  assert image.max_attached == composer.max_image_attachments
  assert image.max_attached_bytes <= pasted_image.max_image_bytes
}
