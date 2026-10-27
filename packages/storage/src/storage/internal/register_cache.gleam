//// Bounded reuse of successfully decoded register payloads within one store.
////
//// SQLite still selects every row. Exact persisted bytes identify the decoded
//// value; namespace, key and sequence remain the current query's responsibility.
//// External edits, lease replacement and failed transactions therefore need no
//// invalidation protocol. A changed blob cannot hit an old decoded value.
////
//// The actor releases this table on close. Entry and encoded-byte limits bound
//// its inventory, not its decoded heap size, which depends on the JSON shape.
//// Overflow starts a fresh inventory rather than maintaining eviction metadata.

import core/codec
import core/corruption.{type CorruptionReport}
import core/json
import core/register.{type RegisterValue}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/result

/// A store-local inventory with at most 64 blobs and 256 KiB of encoded data.
/// Only complete successful decodes enter the table; errors are never retained.
pub opaque type Cache {
  Cache(
    /// Successful complete decodes indexed by exact persisted bytes.
    values: Dict(BitArray, RegisterValue),
    /// The sum of encoded blob lengths, independent of decoded heap size.
    bytes: Int,
  )
}

const maximum_entries = 64

const maximum_bytes = 262_144

/// Start an empty inventory, also used to release all entries on close.
///
/// ## Examples
///
/// ```gleam
/// let cache = register_cache.new()
/// ```
pub fn new() -> Cache {
  Cache(dict.new(), 0)
}

/// Decode current persisted bytes, reusing only an exact successful match.
/// Oversized blobs bypass the inventory without displacing smaller values.
///
/// ## Examples
///
/// ```gleam
/// // register_cache.read(cache, persisted_blob)
/// ```
pub fn read(
  cache: Cache,
  blob: BitArray,
) -> Result(#(RegisterValue, Cache), CorruptionReport) {
  let size = bit_array.byte_size(blob)
  use <- bool.lazy_guard(size > maximum_bytes, fn() {
    use value <- result.map(decode_blob(blob))
    #(value, cache)
  })

  // Check whether the decoded register value is already cached for this blob.
  case dict.get(cache.values, blob) {
    Ok(value) -> Ok(#(value, cache))
    Error(Nil) -> {
      use value <- result.map(decode_blob(blob))

      // A miss alone can change the inventory. No tentative write enters it.
      let cache = case
        dict.size(cache.values) >= maximum_entries
        || cache.bytes + size > maximum_bytes
      {
        True -> new()
        False -> cache
      }

      #(
        value,
        Cache(dict.insert(cache.values, blob, value), cache.bytes + size),
      )
    }
  }
}

/// Decodes a persisted register bit array into a typed register value, reporting corruption on failure.
fn decode_blob(blob: BitArray) -> Result(RegisterValue, CorruptionReport) {
  use text <- result.try(
    bit_array.to_string(blob)
    |> result.map_error(fn(_) {
      corruption.report(
        at: "storage/sqlite.decode",
        on: "register payload",
        expected: "utf-8 json payload",
        context: "invalid utf-8",
      )
    }),
  )
  use value <- result.try(json.parse(text))
  codec.decode_register_value(value)
}
