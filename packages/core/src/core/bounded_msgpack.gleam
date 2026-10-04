//// Fixed resource bounds for remote MessagePack values before term decoding.
////
//// `decode` first scans the complete raw value without constructing strings,
//// arrays or maps. Only a successful scan reaches `core/msgpack.decode`, which
//// checks UTF-8, duplicate map keys and finite floats. The scanner carries one
//// remaining node budget through all siblings; entering a container never
//// renews it. Binary contents remain opaque, so callers decoding a nested wire
//// frame must apply this boundary again to that frame.
////
//// The fixed profile preserves the remote native wire contract: nonempty input
//// of at most 256 KiB, values at depths 0 through 16, 2,048 total nodes, at most
//// 128 elements per array or entries per map, 8 KiB strings and 128 KiB binaries.
//// These are logical decoding bounds, not a promise of equal resident memory.
//// The scanner accepts exactly the tag subset of `core/msgpack`; trailing,
//// truncated, unsupported and non-byte-aligned input cannot reach term decoding.
//// `scan` dispatches tags, `skip` bounds raw payloads, `scan_many` threads the
//// shared budget, and `fail` builds a fixed diagnostic without reflecting input.

import core/corruption.{type CorruptionReport}
import core/msgpack as mp
import gleam/bit_array
import gleam/result

/// Decodes one complete MessagePack value under the fixed remote wire bounds.
/// Raw lengths and counts are checked before the ordinary total decoder can
/// allocate containers. Semantic corruption still comes from that decoder.
///
/// ## Examples
///
/// ```gleam
/// assert bounded_msgpack.decode(<<0x91, 0xc0>>)
///   == Ok(msgpack.ArrayValue([msgpack.NilValue]))
/// let assert Error(_) = bounded_msgpack.decode(<<0xdc, 129:size(16)>>)
/// ```
pub fn decode(bytes: BitArray) -> Result(mp.MsgPackValue, CorruptionReport) {
  use Nil <- result.try(
    case
      bit_array.byte_size(bytes) > 0 && bit_array.byte_size(bytes) <= 262_144
    {
      True -> Ok(Nil)
      False -> Error(fail())
    },
  )
  use parsed <- result.try(scan(bytes, 0, 2048))
  use Nil <- result.try(case parsed.0 == <<>> {
    True -> Ok(Nil)
    False -> Error(fail())
  })
  mp.decode(bytes)
}

fn scan(
  bytes: BitArray,
  depth: Int,
  nodes: Int,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // Count this node before reading its tag, including empty containers.
  use Nil <- result.try(case depth <= 16 && nodes > 0 {
    True -> Ok(Nil)
    False -> Error(fail())
  })

  // Container children consume the same budget as their parent and siblings.
  case bytes {
    <<tag, rest:bits>>
      if tag <= 0x7f || tag >= 0xe0 || tag == 0xc0 || tag == 0xc2 || tag == 0xc3
    -> Ok(#(rest, nodes - 1))
    <<tag, rest:bits>> if tag >= 0xa0 && tag <= 0xbf ->
      skip(rest, tag - 0xa0, nodes - 1, 8192)
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f ->
      scan_many(rest, tag - 0x90, depth + 1, nodes - 1)
    <<tag, rest:bits>> if tag >= 0x80 && tag <= 0x8f ->
      scan_many(rest, { tag - 0x80 } * 2, depth + 1, nodes - 1)
    <<0xdc, n:size(16), rest:bits>> if n <= 128 ->
      scan_many(rest, n, depth + 1, nodes - 1)
    <<0xdd, n:size(32), rest:bits>> if n <= 128 ->
      scan_many(rest, n, depth + 1, nodes - 1)
    <<0xde, n:size(16), rest:bits>> if n <= 128 ->
      scan_many(rest, n * 2, depth + 1, nodes - 1)
    <<0xdf, n:size(32), rest:bits>> if n <= 128 ->
      scan_many(rest, n * 2, depth + 1, nodes - 1)
    <<0xd9, n, rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xda, n:size(16), rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xdb, n:size(32), rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xc4, n, rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<0xc5, n:size(16), rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<0xc6, n:size(32), rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<tag, rest:bits>> if tag == 0xcc || tag == 0xd0 ->
      skip(rest, 1, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xcd || tag == 0xd1 ->
      skip(rest, 2, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xce || tag == 0xd2 ->
      skip(rest, 4, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xcf || tag == 0xd3 || tag == 0xcb ->
      skip(rest, 8, nodes - 1, 8)
    _ -> Error(fail())
  }
}

fn skip(
  bytes: BitArray,
  count: Int,
  nodes: Int,
  maximum: Int,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // A declared payload must both fit its field limit and exist in the input.
  case bytes {
    <<_:bytes-size(count), rest:bits>> if count <= maximum -> Ok(#(rest, nodes))
    _ -> Error(fail())
  }
}

fn scan_many(
  bytes: BitArray,
  count: Int,
  depth: Int,
  nodes: Int,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // The returned remainder transfers the shared node budget to the next sibling.
  case count {
    0 -> Ok(#(bytes, nodes))
    _ -> {
      use parsed <- result.try(scan(bytes, depth, nodes))
      scan_many(parsed.0, count - 1, depth, parsed.1)
    }
  }
}

fn fail() -> CorruptionReport {
  corruption.report(
    at: "core/bounded_msgpack.decode",
    on: "remote value",
    expected: "one complete MessagePack value within the fixed remote bounds",
    context: "",
  )
}
