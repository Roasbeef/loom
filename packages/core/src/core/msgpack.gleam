//// The msgpack codec for the effect-plane framing protocol.
////
//// Per ADR-003 this is a self-contained pure-Gleam codec over bit arrays,
//// covering exactly the subset the framing protocol uses: nil, bool,
//// integers of every width (negative and positive fixint, uint 8–64,
//// int 8–64), float64, str (fixstr, str 8/16/32), bin (8/16/32), array
//// (fixarray, array 16/32), and map (fixmap, map 16/32).
////
//// Decoding is total: truncated input, unsupported tag bytes (ext types,
//// float32, the never-used `0xc1`), invalid utf-8 in a str, trailing
//// bytes, and non-byte-aligned bit arrays are all corruption reports,
//// never crashes. Non-finite float64 payloads (NaN, infinities) are also
//// reported as corruption — the BEAM cannot represent them.
////
//// Encoding is canonical: every value is written in the smallest encoding
//// that fits, so equal values always produce identical bytes. The golden
//// fixtures under `protocol/msgpack-fixtures/` pin this canonical form for
//// cross-language conformance.

import core/corruption.{type CorruptionReport}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A msgpack value as plain data. Constructor invariants:
///
/// - `IntValue`: encodable only within `[-2^63, 2^64 - 1]`, the range
///   msgpack can represent; `encode` reports anything outside it.
/// - `FloatValue`: always finite (a BEAM float).
/// - `StringValue`: a valid utf-8 string (a Gleam `String`).
/// - `BinaryValue`: byte-aligned; a ragged bit array fails to encode.
/// - `MapValue`: entry order is meaningful and preserved; duplicate keys
///   are representable and readers take the first occurrence.
pub type MsgPackValue {
  /// The msgpack nil.
  NilValue
  /// A msgpack boolean.
  BoolValue(value: Bool)
  /// A msgpack integer of any width.
  IntValue(value: Int)
  /// A msgpack float64.
  FloatValue(value: Float)
  /// A msgpack str: utf-8 text.
  StringValue(value: String)
  /// A msgpack bin: raw bytes.
  BinaryValue(bytes: BitArray)
  /// A msgpack array.
  ArrayValue(items: List(MsgPackValue))
  /// A msgpack map with arbitrary keys, in order.
  MapValue(entries: List(#(MsgPackValue, MsgPackValue)))
}

/// Why a value could not be encoded. Encoding is total over encodable
/// values; these variants name the two ways a Gleam value can exceed what
/// msgpack represents.
pub type EncodeError {
  /// The integer falls outside `[-2^63, 2^64 - 1]`.
  IntegerOutOfRange(value: Int)
  /// A str, bin, array, or map is longer than `2^32 - 1` bytes or
  /// elements, or a bin is not byte-aligned.
  UnencodableLength(length: Int)
}

/// Encodes a value to its canonical (smallest) msgpack bytes.
///
/// ## Examples
///
/// ```gleam
/// assert msgpack.encode(msgpack.NilValue) == Ok(<<0xc0>>)
/// ```
///
/// ```gleam
/// assert msgpack.encode(msgpack.IntValue(128)) == Ok(<<0xcc, 128>>)
/// ```
///
pub fn encode(value: MsgPackValue) -> Result(BitArray, EncodeError) {
  case encode_tree(value) {
    Ok(tree) -> Ok(bytes_tree.to_bit_array(tree))
    Error(error) -> Error(error)
  }
}

/// Decodes exactly one msgpack value from `bytes`, requiring the whole
/// input to be consumed. Total: every malformed input is a
/// `CorruptionReport`, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert msgpack.decode(<<0xc0>>) == Ok(msgpack.NilValue)
/// ```
///
/// ```gleam
/// let assert Error(_report) = msgpack.decode(<<0xcc>>)
/// ```
///
pub fn decode(bytes: BitArray) -> Result(MsgPackValue, CorruptionReport) {
  case decode_value(bytes) {
    Ok(#(value, rest)) ->
      case bit_array.bit_size(rest) {
        0 -> Ok(value)
        _ -> Error(fail(rest, "no trailing bytes after the value"))
      }
    Error(report) -> Error(report)
  }
}

// --- encoding -----------------------------------------------------------

fn encode_tree(value: MsgPackValue) -> Result(BytesTree, EncodeError) {
  case value {
    NilValue -> Ok(bytes_tree.from_bit_array(<<0xc0>>))
    BoolValue(value: False) -> Ok(bytes_tree.from_bit_array(<<0xc2>>))
    BoolValue(value: True) -> Ok(bytes_tree.from_bit_array(<<0xc3>>))
    IntValue(value:) -> encode_int(value)
    FloatValue(value:) -> Ok(bytes_tree.from_bit_array(<<0xcb, value:float>>))
    StringValue(value:) -> encode_string(value)
    BinaryValue(bytes:) -> encode_binary(bytes)
    ArrayValue(items:) -> encode_array(items)
    MapValue(entries:) -> encode_map(entries)
  }
}

fn encode_int(value: Int) -> Result(BytesTree, EncodeError) {
  let bytes = case value {
    _ if value >= 0 && value <= 0x7f -> Ok(<<value:size(8)>>)
    _ if value < 0 && value >= -32 -> Ok(<<value:size(8)>>)
    _ if value > 0 && value <= 0xff -> Ok(<<0xcc, value:size(8)>>)
    _ if value > 0 && value <= 0xffff -> Ok(<<0xcd, value:size(16)>>)
    _ if value > 0 && value <= 0xffffffff -> Ok(<<0xce, value:size(32)>>)
    _ if value > 0 && value <= 0xffffffffffffffff -> Ok(<<0xcf, value:size(64)>>)
    _ if value < 0 && value >= -128 -> Ok(<<0xd0, value:size(8)>>)
    _ if value < 0 && value >= -32_768 -> Ok(<<0xd1, value:size(16)>>)
    _ if value < 0 && value >= -2_147_483_648 -> Ok(<<0xd2, value:size(32)>>)
    _ if value < 0 && value >= -9_223_372_036_854_775_808 ->
      Ok(<<0xd3, value:size(64)>>)
    _ -> Error(IntegerOutOfRange(value:))
  }
  result.map(bytes, bytes_tree.from_bit_array)
}

fn encode_string(value: String) -> Result(BytesTree, EncodeError) {
  let bytes = bit_array.from_string(value)
  let length = bit_array.byte_size(bytes)
  let fixstr_tag = 0xa0 + length
  let header = case length {
    _ if length <= 31 -> Ok(<<fixstr_tag:size(8)>>)
    _ if length <= 0xff -> Ok(<<0xd9, length:size(8)>>)
    _ if length <= 0xffff -> Ok(<<0xda, length:size(16)>>)
    _ if length <= 0xffffffff -> Ok(<<0xdb, length:size(32)>>)
    _ -> Error(UnencodableLength(length:))
  }
  use header <- result.map(header)
  bytes_tree.from_bit_array(header)
  |> bytes_tree.append(bytes)
}

fn encode_binary(bytes: BitArray) -> Result(BytesTree, EncodeError) {
  let bits = bit_array.bit_size(bytes)
  let length = bit_array.byte_size(bytes)
  let ragged = bits % 8 != 0
  let header = case length {
    _ if ragged -> Error(UnencodableLength(length: bits))
    _ if length <= 0xff -> Ok(<<0xc4, length:size(8)>>)
    _ if length <= 0xffff -> Ok(<<0xc5, length:size(16)>>)
    _ if length <= 0xffffffff -> Ok(<<0xc6, length:size(32)>>)
    _ -> Error(UnencodableLength(length:))
  }
  use header <- result.map(header)
  bytes_tree.from_bit_array(header)
  |> bytes_tree.append(bytes)
}

fn encode_array(items: List(MsgPackValue)) -> Result(BytesTree, EncodeError) {
  let length = list.length(items)
  let fixarray_tag = 0x90 + length
  let header = case length {
    _ if length <= 15 -> Ok(<<fixarray_tag:size(8)>>)
    _ if length <= 0xffff -> Ok(<<0xdc, length:size(16)>>)
    _ if length <= 0xffffffff -> Ok(<<0xdd, length:size(32)>>)
    _ -> Error(UnencodableLength(length:))
  }
  use header <- result.try(header)
  use trees <- result.map(list.try_map(items, encode_tree))
  bytes_tree.concat([bytes_tree.from_bit_array(header), ..trees])
}

fn encode_map(
  entries: List(#(MsgPackValue, MsgPackValue)),
) -> Result(BytesTree, EncodeError) {
  let length = list.length(entries)
  let fixmap_tag = 0x80 + length
  let header = case length {
    _ if length <= 15 -> Ok(<<fixmap_tag:size(8)>>)
    _ if length <= 0xffff -> Ok(<<0xde, length:size(16)>>)
    _ if length <= 0xffffffff -> Ok(<<0xdf, length:size(32)>>)
    _ -> Error(UnencodableLength(length:))
  }
  use header <- result.try(header)
  use trees <- result.map(
    list.try_map(entries, fn(entry) {
      let #(key, value) = entry
      use key_tree <- result.try(encode_tree(key))
      use value_tree <- result.map(encode_tree(value))
      bytes_tree.append_tree(key_tree, value_tree)
    }),
  )
  bytes_tree.concat([bytes_tree.from_bit_array(header), ..trees])
}

// --- decoding -----------------------------------------------------------

fn fail(bytes: BitArray, expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/msgpack.decode",
    on: int.to_string(bit_array.byte_size(bytes)) <> " bytes remaining",
    expected:,
    context: excerpt(bytes),
  )
}

// Shows at most the first 16 remaining bytes of input in a report.
fn excerpt(bytes: BitArray) -> String {
  case bit_array.bit_size(bytes) {
    0 -> "end of input"
    _ ->
      case bit_array.slice(from: bytes, at: 0, take: 16) {
        Ok(head) -> "0x" <> string.lowercase(bit_array.base16_encode(head))
        Error(Nil) ->
          "0x"
          <> string.lowercase(bit_array.base16_encode(bytes))
          <> " (ragged)"
      }
  }
}

fn decode_value(
  bytes: BitArray,
) -> Result(#(MsgPackValue, BitArray), CorruptionReport) {
  case bytes {
    <<0xc0, rest:bits>> -> Ok(#(NilValue, rest))
    <<0xc2, rest:bits>> -> Ok(#(BoolValue(value: False), rest))
    <<0xc3, rest:bits>> -> Ok(#(BoolValue(value: True), rest))
    <<0xcb, value:float, rest:bits>> -> Ok(#(FloatValue(value:), rest))
    <<0xcc, value:size(8), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xcd, value:size(16), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xce, value:size(32), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xcf, value:size(64), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xd0, value:signed-size(8), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xd1, value:signed-size(16), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xd2, value:signed-size(32), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xd3, value:signed-size(64), rest:bits>> -> Ok(#(IntValue(value:), rest))
    <<0xd9, length:size(8), rest:bits>> -> decode_string(length, rest)
    <<0xda, length:size(16), rest:bits>> -> decode_string(length, rest)
    <<0xdb, length:size(32), rest:bits>> -> decode_string(length, rest)
    <<0xc4, length:size(8), rest:bits>> -> decode_binary(length, rest)
    <<0xc5, length:size(16), rest:bits>> -> decode_binary(length, rest)
    <<0xc6, length:size(32), rest:bits>> -> decode_binary(length, rest)
    <<0xdc, length:size(16), rest:bits>> -> decode_array(length, rest)
    <<0xdd, length:size(32), rest:bits>> -> decode_array(length, rest)
    <<0xde, length:size(16), rest:bits>> -> decode_map(length, rest)
    <<0xdf, length:size(32), rest:bits>> -> decode_map(length, rest)
    <<tag, rest:bits>> if tag <= 0x7f -> Ok(#(IntValue(value: tag), rest))
    <<tag, rest:bits>> if tag >= 0xe0 -> Ok(#(IntValue(value: tag - 256), rest))
    <<tag, rest:bits>> if tag >= 0x80 && tag <= 0x8f ->
      decode_map(tag - 0x80, rest)
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f ->
      decode_array(tag - 0x90, rest)
    <<tag, rest:bits>> if tag >= 0xa0 && tag <= 0xbf ->
      decode_string(tag - 0xa0, rest)
    <<tag, _rest:bits>> -> Error(tag_error(bytes, tag))
    _ -> Error(fail(bytes, "a byte-aligned msgpack value"))
  }
}

// Reached when a leading tag byte matched no complete pattern: either the
// tag is outside the ADR-003 subset, or its payload is truncated. The two
// are distinguished so reports name the real problem.
fn tag_error(bytes: BitArray, tag: Int) -> CorruptionReport {
  case tag {
    0xc1 -> fail(bytes, "a valid tag byte, not the never-used 0xc1")
    0xca -> fail(bytes, "no float32: only float64 (0xcb) is supported")
    _ if tag >= 0xc7 && tag <= 0xc9 ->
      fail(bytes, "no ext types: outside the supported msgpack subset")
    _ if tag >= 0xd4 && tag <= 0xd8 ->
      fail(bytes, "no fixext types: outside the supported msgpack subset")
    // Every remaining tag is in the supported subset, so the payload must
    // have been truncated — this also covers a float64 whose bit pattern
    // is NaN or an infinity, which the BEAM cannot match or represent.
    _ -> fail(bytes, "a complete payload for tag " <> tag_name(tag))
  }
}

fn tag_name(tag: Int) -> String {
  "0x" <> string.lowercase(int.to_base16(tag))
}

fn decode_string(
  length: Int,
  bytes: BitArray,
) -> Result(#(MsgPackValue, BitArray), CorruptionReport) {
  use #(payload, rest) <- result.try(take_bytes(length, bytes, "str"))
  case bit_array.to_string(payload) {
    Ok(value) -> Ok(#(StringValue(value:), rest))
    Error(Nil) -> Error(fail(payload, "valid utf-8 in a str payload"))
  }
}

fn decode_binary(
  length: Int,
  bytes: BitArray,
) -> Result(#(MsgPackValue, BitArray), CorruptionReport) {
  use #(payload, rest) <- result.map(take_bytes(length, bytes, "bin"))
  #(BinaryValue(bytes: payload), rest)
}

fn take_bytes(
  length: Int,
  bytes: BitArray,
  kind: String,
) -> Result(#(BitArray, BitArray), CorruptionReport) {
  let available = bit_array.byte_size(bytes)
  case bit_array.slice(from: bytes, at: 0, take: length) {
    Ok(payload) ->
      case bit_array.slice(from: bytes, at: length, take: available - length) {
        Ok(rest) -> Ok(#(payload, rest))
        Error(Nil) ->
          Error(fail(bytes, "a byte-aligned " <> kind <> " payload"))
      }
    Error(Nil) ->
      Error(fail(
        bytes,
        int.to_string(length) <> " payload bytes for a " <> kind,
      ))
  }
}

fn decode_array(
  length: Int,
  bytes: BitArray,
) -> Result(#(MsgPackValue, BitArray), CorruptionReport) {
  use #(items, rest) <- result.map(decode_array_loop(length, bytes, []))
  #(ArrayValue(items:), rest)
}

fn decode_array_loop(
  remaining: Int,
  bytes: BitArray,
  accumulator: List(MsgPackValue),
) -> Result(#(List(MsgPackValue), BitArray), CorruptionReport) {
  case remaining {
    0 -> Ok(#(list.reverse(accumulator), bytes))
    _ -> {
      use #(item, rest) <- result.try(decode_value(bytes))
      decode_array_loop(remaining - 1, rest, [item, ..accumulator])
    }
  }
}

fn decode_map(
  length: Int,
  bytes: BitArray,
) -> Result(#(MsgPackValue, BitArray), CorruptionReport) {
  use #(entries, rest) <- result.map(decode_map_loop(length, bytes, []))
  #(MapValue(entries:), rest)
}

fn decode_map_loop(
  remaining: Int,
  bytes: BitArray,
  accumulator: List(#(MsgPackValue, MsgPackValue)),
) -> Result(#(List(#(MsgPackValue, MsgPackValue)), BitArray), CorruptionReport) {
  case remaining {
    0 -> Ok(#(list.reverse(accumulator), bytes))
    _ -> {
      use #(key, rest) <- result.try(decode_value(bytes))
      use #(value, rest) <- result.try(decode_value(rest))
      decode_map_loop(remaining - 1, rest, [#(key, value), ..accumulator])
    }
  }
}
