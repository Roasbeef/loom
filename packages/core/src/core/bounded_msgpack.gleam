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
//// The shared raw walk lives in `core/internal/msgpack_scan`; this wrapper
//// selects only its unchanged native profile before semantic decoding.

import core/corruption.{type CorruptionReport}
import core/internal/msgpack_scan
import core/msgpack as mp
import gleam/result

/// Decodes one complete value under the unchanged fixed native wire bounds.
///
/// ## Examples
///
/// ```gleam
/// assert bounded_msgpack.decode(<<0x91, 0xc0>>)
///   == Ok(msgpack.ArrayValue([msgpack.NilValue]))
/// ```
pub fn decode(bytes: BitArray) -> Result(mp.MsgPackValue, CorruptionReport) {
  use Nil <- result.try(msgpack_scan.native(bytes))
  mp.decode(bytes)
}
