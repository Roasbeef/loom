//// `pasted_image` names which images a host admits: four raster formats
//// identified by their magic bytes, never by a declared type.

import gleam/option.{None, Some}
import session_view/pasted_image

pub fn media_type_reads_the_four_raster_formats_test() {
  assert pasted_image.media_type(<<
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0,
    >>)
    == Some("image/png")
  assert pasted_image.media_type(<<0xFF, 0xD8, 0xFF, 0xE0>>)
    == Some("image/jpeg")
  assert pasted_image.media_type(<<"GIF87a":utf8>>) == Some("image/gif")
  assert pasted_image.media_type(<<"GIF89a":utf8>>) == Some("image/gif")
  assert pasted_image.media_type(<<"RIFF":utf8, 0:32, "WEBP":utf8>>)
    == Some("image/webp")
}

pub fn media_type_refuses_markup_and_short_input_test() {
  assert pasted_image.media_type(<<"<svg xmlns=":utf8>>) == None
  assert pasted_image.media_type(<<"<html>":utf8>>) == None
  assert pasted_image.media_type(<<0x89, 0x50>>) == None
  assert pasted_image.media_type(<<>>) == None
}

pub fn is_raster_admits_only_the_four_types_test() {
  assert pasted_image.is_raster("image/png")
  assert pasted_image.is_raster("image/jpeg")
  assert pasted_image.is_raster("image/gif")
  assert pasted_image.is_raster("image/webp")
  assert !pasted_image.is_raster("image/svg+xml")
  assert !pasted_image.is_raster("image/PNG")
  assert !pasted_image.is_raster("text/html")
  assert !pasted_image.is_raster("")
}
