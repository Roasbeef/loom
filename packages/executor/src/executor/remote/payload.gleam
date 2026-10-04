//// Exact immutable bytes retained beside admission evidence.
////
//// Request (128 KiB), authorization (1 KiB), terminal (32 KiB), and up to
//// 64 ordered output items (16 KiB each, 1 MiB cumulative) reserve capacity
//// before native work. These are encoded payload limits, not SQLite page/WAL
//// size claims. Tombstones and payloads stay until administrative disposition;
//// this slice offers no deletion API. Receipt and witnessed drain authorize
//// reducer compaction without erasing the only recoverable result bytes.

import gleam/bit_array
import gleam/list
import gleam/result

/// An immutable named payload slot. Output ordinal starts at zero.
pub type Item {
  /// The exact canonical prepared request.
  Request(
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )

  /// Frozen lifetime authorization, never recreated on recovery.
  Authority(
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )

  /// One ordered output frame, retained before advertisement.
  Output(
    /// The bounded ordered item number, never a new logical request identity.
    ordinal: Int,
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )

  /// A durable cancellation reservation, independent of a prepared request.
  /// Its exact refusal bytes fence an intermediate Admitted record on recovery.
  Cancellation(
    /// Exact bounded cancellation/refusal intent, never a fabricated command.
    bytes: BitArray,
  )

  /// The exact terminal verdict, retained before its digest is announced.
  Terminal(
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )
}

/// A size, ordinal, ordering or missing-request violation.
pub type Error {
  /// The inventory exceeded its declared byte/count bound or schema.
  Invalid
}

/// Returns the SQL slot and exact bytes without changing them.
///
/// ## Examples
///
/// ```gleam
/// payload.fields(payload.Request(<<1>>)) // -> #(0, 0, <<1>>).
/// ```
pub fn fields(item: Item) -> #(Int, Int, BitArray) {
  case item {
    Request(bytes) -> #(0, 0, bytes)
    Authority(bytes) -> #(1, 0, bytes)
    Output(ordinal, bytes) -> #(2, ordinal, bytes)
    Terminal(bytes) -> #(3, 0, bytes)
    Cancellation(bytes) -> #(4, 0, bytes)
  }
}

/// Decodes bounded database fields through the same item validator.
///
/// ## Examples
///
/// ```gleam
/// payload.from_fields(0, 0, <<1>>) // -> Ok(Request(<<1>>)).
/// ```
pub fn from_fields(
  kind: Int,
  ordinal: Int,
  bytes: BitArray,
) -> Result(Item, Error) {
  use item <- result.try(case kind, ordinal {
    0, 0 -> Ok(Request(bytes))
    1, 0 -> Ok(Authority(bytes))
    2, ordinal -> Ok(Output(ordinal, bytes))
    3, 0 -> Ok(Terminal(bytes))
    4, 0 -> Ok(Cancellation(bytes))
    _, _ -> Error(Invalid)
  })
  use Nil <- result.try(validate(item))
  Ok(item)
}

/// Bounds an item before submitting it to SQLite or a network queue.
///
/// ## Examples
///
/// ```gleam
/// payload.validate(payload.Output(64, <<1>>)) // -> Error(Invalid).
/// ```
pub fn validate(item: Item) -> Result(Nil, Error) {
  let #(_, ordinal, bytes) = fields(item)
  let maximum = case item {
    Request(_) -> 131_072
    Authority(_) -> 1024
    Output(_, _) -> 16_384
    Terminal(_) | Cancellation(_) -> 32_768
  }
  case
    bit_array.byte_size(bytes) > 0
    && bit_array.byte_size(bytes) <= maximum
    && bit_array.bit_size(bytes) % 8 == 0
    && ordinal >= 0
    && ordinal < 64
  {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

/// Checks aggregate bounds and unique slots. Empty inventory is valid for lookup.
///
/// ## Examples
///
/// ```gleam
/// payload.validate_inventory([payload.Request(<<1>>)])
/// ```
pub fn validate_inventory(items: List(Item)) -> Result(List(Item), Error) {
  use Nil <- result.try(case list.drop(items, 68) == [] {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  use _ <- result.try(
    list.try_fold(items, #(0, []), fn(acc, item) {
      use Nil <- result.try(validate(item))
      let #(kind, ordinal, bytes) = fields(item)
      let #(total, slots) = acc
      let size = case item {
        Output(_, _) -> bit_array.byte_size(bytes)
        Request(_) | Authority(_) | Terminal(_) | Cancellation(_) -> 0
      }
      case
        total + size <= 1_048_576 && !list.contains(slots, #(kind, ordinal))
      {
        True -> Ok(#(total + size, [#(kind, ordinal), ..slots]))
        False -> Error(Invalid)
      }
    }),
  )
  use Nil <- result.try(case items {
    [] -> Ok(Nil)
    _ ->
      case
        list.any(items, fn(item) {
          case item {
            Request(_) | Cancellation(_) -> True
            _ -> False
          }
        })
      {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
  })
  Ok(items)
}
