//// Allocation admission before core/msgpack constructs any values.
////
//// This scanner recognizes only the tags the positional schema uses: integer,
//// boolean, text, binary and array. It slices past scalar payloads and counts
//// nodes without constructing lists or decoding strings. Maps, nil, floating
//// point and extension tags have no meaning in this schema and fail here.
//// Container recursion is at most 32 levels and sibling scanning is tail
//// recursive. Claimed lengths must fit the bytes already present.

import gleam/bit_array
import gleam/result

/// Maximum simultaneously open containers, including the envelope.
pub const max_depth = 32

/// Aggregate scalar and container nodes, including the envelope.
pub const max_nodes = 65_536

/// Maximum elements in any individual positional array or inventory.
pub const max_container = 8192

/// Admits exactly one byte-aligned value before allocating decoded lists.
///
/// ## Examples
///
/// `scan(<<0x91, 1>>)` succeeds; trailing bytes and maps fail.
@internal
pub fn scan(bytes: BitArray) -> Result(Nil, Nil) {
  use Nil <- result.try(check(fn() { bit_array.bit_size(bytes) % 8 == 0 }))
  use #(rest, _) <- result.try(node(bytes, 0, max_nodes))
  case rest {
    <<>> -> Ok(Nil)
    _ -> Error(Nil)
  }
}

fn node(
  bytes: BitArray,
  depth: Int,
  budget: Int,
) -> Result(#(BitArray, Int), Nil) {
  use Nil <- result.try(check(fn() { budget > 0 }))
  let left = budget - 1

  // Scalar headers transfer no allocation responsibility to the core decoder
  // until the complete payload is present in this bounded semantic content.
  case bytes {
    <<0xc2, rest:bytes>> | <<0xc3, rest:bytes>> -> Ok(#(rest, left))
    <<0xcc, _:size(8), rest:bytes>> | <<0xd0, _:size(8), rest:bytes>> ->
      Ok(#(rest, left))
    <<0xcd, _:size(16), rest:bytes>> | <<0xd1, _:size(16), rest:bytes>> ->
      Ok(#(rest, left))
    <<0xce, _:size(32), rest:bytes>> | <<0xd2, _:size(32), rest:bytes>> ->
      Ok(#(rest, left))
    <<0xcf, _:size(64), rest:bytes>> | <<0xd3, _:size(64), rest:bytes>> ->
      Ok(#(rest, left))
    <<0xd9, length:size(8), rest:bytes>>
    | <<0xc4, length:size(8), rest:bytes>> -> skip(length, rest, left)
    <<0xda, length:size(16), rest:bytes>>
    | <<0xc5, length:size(16), rest:bytes>> -> skip(length, rest, left)
    <<0xdb, length:size(32), rest:bytes>>
    | <<0xc6, length:size(32), rest:bytes>> -> skip(length, rest, left)
    <<0xdc, count:size(16), rest:bytes>> -> container(count, rest, depth, left)
    <<0xdd, count:size(32), rest:bytes>> -> container(count, rest, depth, left)
    <<tag, rest:bytes>> if tag <= 0x7f || tag >= 0xe0 -> Ok(#(rest, left))
    <<tag, rest:bytes>> if tag >= 0xa0 && tag <= 0xbf ->
      skip(tag - 0xa0, rest, left)
    <<tag, rest:bytes>> if tag >= 0x90 && tag <= 0x9f ->
      container(tag - 0x90, rest, depth, left)
    _ -> Error(Nil)
  }
}

fn skip(
  length: Int,
  bytes: BitArray,
  left: Int,
) -> Result(#(BitArray, Int), Nil) {
  case bytes {
    <<_:bytes-size(length), rest:bytes>> -> Ok(#(rest, left))
    _ -> Error(Nil)
  }
}

fn container(
  count: Int,
  bytes: BitArray,
  depth: Int,
  left: Int,
) -> Result(#(BitArray, Int), Nil) {
  use Nil <- result.try(
    check(fn() {
      depth < max_depth
      && count <= max_container
      && count <= left
      && count <= bit_array.byte_size(bytes)
    }),
  )
  siblings(count, bytes, depth + 1, left)
}

fn siblings(
  count: Int,
  bytes: BitArray,
  depth: Int,
  left: Int,
) -> Result(#(BitArray, Int), Nil) {
  case count {
    0 -> Ok(#(bytes, left))
    _ -> {
      use #(rest, budget) <- result.try(node(bytes, depth, left))
      siblings(count - 1, rest, depth, budget)
    }
  }
}

fn check(valid: fn() -> Bool) -> Result(Nil, Nil) {
  case valid() {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}
