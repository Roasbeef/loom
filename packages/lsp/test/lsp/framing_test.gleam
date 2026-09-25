import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import lsp/framing

// Two frames back to back. The first body carries "é" (two UTF-8 bytes)
// and "𝄞" (four), so cutting the stream at every byte offset puts a split
// inside a multi-byte character, inside the header, inside the terminator
// and exactly on each frame boundary.
const first_body = "{\"text\":\"café 𝄞\"}"

const second_body = "{\"id\":2}"

fn stream() -> BitArray {
  let first = framing.frame(json.Object([#("text", json.String("café 𝄞"))]))
  let second = framing.frame(json.Object([#("id", json.Int(2))]))
  <<first:utf8, second:utf8>>
}

// Feeds chunks in order, collecting every completed body.
fn feed(chunks: List(BitArray)) -> Result(List(String), framing.FramingFault) {
  let fed =
    list.try_fold(chunks, #(framing.new(), []), fn(state, chunk) {
      let #(buffer, bodies) = state
      use #(buffer, more) <- result.map(framing.push(buffer, chunk))
      #(buffer, list.append(bodies, more))
    })
  use #(_, bodies) <- result.map(fed)
  bodies
}

// 0, 1, ..., count - 1.
fn offsets(count: Int) -> List(Int) {
  int.range(from: count - 1, to: -1, with: [], run: list.prepend)
}

fn split_at(bits: BitArray, at: Int) -> List(BitArray) {
  let size = bit_array.byte_size(bits)
  let assert Ok(head) = bit_array.slice(bits, 0, at) as "in range"
  let assert Ok(tail) = bit_array.slice(bits, at, size - at) as "in range"
  [head, tail]
}

pub fn frame_counts_bytes_not_characters_test() {
  let framed = framing.frame(json.Object([#("text", json.String("café 𝄞"))]))
  assert framed
    == "Content-Length: "
    <> int.to_string(string.byte_size(first_body))
    <> "\r\n\r\n"
    <> first_body
}

pub fn a_whole_stream_in_one_push_yields_both_bodies_in_order_test() {
  assert feed([stream()]) == Ok([first_body, second_body])
}

pub fn every_single_split_point_yields_the_same_bodies_test() {
  let bits = stream()
  let size = bit_array.byte_size(bits)
  offsets(size + 1)
  |> list.each(fn(at) {
    assert feed(split_at(bits, at)) == Ok([first_body, second_body])
  })
}

pub fn one_byte_at_a_time_yields_the_same_bodies_test() {
  let bits = stream()
  let bytes =
    offsets(bit_array.byte_size(bits))
    |> list.map(fn(at) {
      let assert Ok(byte) = bit_array.slice(bits, at, 1) as "in range"
      byte
    })
  assert feed(bytes) == Ok([first_body, second_body])
}

pub fn a_partial_body_is_held_until_complete_test() {
  let assert Ok(#(buffer, [])) =
    framing.push(framing.new(), <<"Content-Length: 2\r\n\r\n{":utf8>>)
    as "the header and half the body"
  assert framing.push(buffer, <<"}":utf8>>) == Ok(#(framing.new(), ["{}"]))
}

pub fn header_names_are_case_insensitive_and_content_type_is_tolerated_test() {
  let bits = <<
    "content-type: application/vscode-jsonrpc; charset=utf-8\r\n":utf8,
    "CONTENT-LENGTH:   2  \r\n\r\n{}":utf8,
  >>
  assert feed([bits]) == Ok(["{}"])
}

pub fn an_empty_body_is_a_frame_test() {
  assert feed([<<"Content-Length: 0\r\n\r\n":utf8>>]) == Ok([""])
}

pub fn missing_content_length_is_refused_test() {
  assert feed([<<"Content-Type: x\r\n\r\n{}":utf8>>])
    == Error(framing.MissingContentLength)
}

pub fn duplicate_content_length_is_refused_test() {
  assert feed([<<"Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}":utf8>>])
    == Error(framing.DuplicateContentLength)
}

pub fn a_signed_or_non_numeric_length_is_refused_test() {
  assert feed([<<"Content-Length: +2\r\n\r\n{}":utf8>>])
    == Error(framing.BadContentLength("+2"))
  assert feed([<<"Content-Length: two\r\n\r\n{}":utf8>>])
    == Error(framing.BadContentLength("two"))
  assert feed([<<"Content-Length: \r\n\r\n{}":utf8>>])
    == Error(framing.BadContentLength(""))
}

pub fn a_line_without_a_colon_is_malformed_test() {
  let assert Error(framing.MalformedHeader(_)) =
    feed([<<"Content-Length 2\r\n\r\n{}":utf8>>])
    as "no colon"
}

pub fn a_header_that_is_not_text_is_malformed_test() {
  let assert Error(framing.MalformedHeader(_)) =
    feed([<<"X: ":utf8, 0xFF, "\r\nContent-Length: 2\r\n\r\n{}":utf8>>])
    as "a stray 0xFF byte"
}

pub fn a_body_that_is_not_utf8_is_refused_test() {
  assert feed([<<"Content-Length: 2\r\n\r\n":utf8, 0xC3, 0x28>>])
    == Error(framing.BodyNotUtf8)
}

pub fn an_endless_header_is_refused_at_the_cap_test() {
  let junk = <<string.repeat("a", framing.max_header_bytes + 3):utf8>>
  let assert Ok(#(buffer, [])) = framing.push(framing.new(), junk)
    as "at the cap, still waiting for a terminator that could fit"
  assert framing.push(buffer, <<"a":utf8>>)
    == Error(framing.HeaderTooLong(framing.max_header_bytes))
}

pub fn an_endless_header_split_into_small_pushes_is_refused_test() {
  let chunk = <<string.repeat("a", 1000):utf8>>
  assert feed(list.repeat(chunk, 9))
    == Error(framing.HeaderTooLong(framing.max_header_bytes))
}

// The declared length is checked when the header is parsed, so the fault
// arrives in the same push as the header, before any body byte is sent.
pub fn a_frame_too_long_is_refused_before_its_body_arrives_test() {
  let declared = framing.max_frame_bytes + 1
  let header = "Content-Length: " <> int.to_string(declared) <> "\r\n\r\n"
  assert framing.push(framing.new(), <<header:utf8>>)
    == Error(framing.FrameTooLong(framing.max_frame_bytes, declared))
}

pub fn a_frame_exactly_at_the_cap_is_accepted_as_a_header_test() {
  let header =
    "Content-Length: " <> int.to_string(framing.max_frame_bytes) <> "\r\n\r\n"
  let assert Ok(#(_, [])) = framing.push(framing.new(), <<header:utf8>>)
    as "the cap itself is allowed"
}
