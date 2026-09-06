//// Pure stop-and-wait transfer state. Storage reads are explicit requests to
//// the gateway, not work hidden in this module. Each successful continuation
//// emits one bounded fragment; it never accumulates history or a reply queue.
//// The gateway owns authorization, the absolute deadline and read failure.
////
//// A requested read carries the wait it may be answered in, and this module
//// computes that wait rather than publishing the deadline for a caller to do
//// the arithmetic with. The distinction is load-bearing: a transfer one
//// millisecond short of its retention deadline used to fund a reader exchange
//// with that millisecond, and the timeout which inevitably came back was then
//// read as proof the storage actor was wedged — one read-only client's
//// pacing stopping the session for every attachment. A read it cannot fund
//// is now not a read at all but `Exhausted`.

import client/protocol
import core/ids
import core/json
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/snapshot

/// Raw pieces fit below the observer's 64-KiB encoded message ceiling.
pub const piece_bytes = 24_576

/// Metadata is sized before serialization, including escaping and wrappers.
pub const metadata_encoded_limit = 2_097_152

/// One transfer expires from capture, not from the last successful fragment.
pub const lifetime_ms = 30_000

/// The longest a single bounded reader exchange may wait (protocol-015).
pub const reader_maximum_ms = 5000

/// The shortest one may wait, below which no read is requested at all.
///
/// A read funded with the last few milliseconds of a retention window is a
/// timeout with extra steps: the reader is asked a question it cannot answer
/// in the time given, and the answer — `snapshot.ReadTimedOut` — is then
/// read as evidence about the reader rather than the budget. Refusing under
/// this floor is what keeps a client's own pacing out of the reader's health
/// record; the gateway's split of that verdict is the second half of it.
pub const reader_minimum_ms = 1000

/// The history window is explicit; recent entries do not imply parent closure.
pub type Window {
  /// The capture's latest descriptors, at most one hundred.
  Recent

  /// All immutable entries after the last adopted cut, in bounded pages.
  Reconcile(from_seq: Int)

  /// One historical descriptor page between exclusive sequence bounds.
  History(after_seq: Int, before_seq: Int)

  /// Exact current escalation cells, without changing the adopted history cut.
  Escalations(ids: List(String))
}

/// Retained state contains bounded metadata and at most one descriptor page.
pub opaque type Transfer {
  Transfer(
    id: String,
    next_seq: Int,
    index: Int,
    deadline: Int,
    metadata: BitArray,
    metadata_offset: Int,
    entries: List(snapshot.Descriptor),
    range: Option(#(Int, Int)),
    window: Window,
    offset: Int,
    fragment: BitArray,
    fragment_offset: Int,
    more_after: Option(Int),
  )
}

/// A caller performs at most one requested bounded read before stepping again.
pub type Step {
  /// The response consumes one credit and returns its next retained state.
  Emit(event: protocol.Event, next: Transfer)

  /// This window is complete, not necessarily the whole conversation tree.
  End(event: protocol.Event)

  /// Fetch at most one hundred descriptors between exclusive bounds.
  ///
  /// `within_ms` is the wait this exchange is funded with, and it is carried
  /// here rather than recomputed by the caller so that a read the transfer
  /// cannot fund is unrepresentable: `step` answers `Exhausted` instead of
  /// handing back a request with a budget nobody can wait out.
  ReadPage(after_seq: Int, before_seq: Int, within_ms: Int)

  /// Fetch one storage-sized fragment, never a complete large record.
  ///
  /// `within_ms` is funded exactly as `ReadPage`'s is.
  ReadFragment(descriptor: snapshot.Descriptor, offset: Int, within_ms: Int)

  /// Corruption or an inconsistent reader response refuses the transfer.
  Refused(reason: String)

  /// Neither the retention window nor this request's own wall has enough left
  /// to fund a bounded reader exchange, so none is requested. The transfer is
  /// over from the client's point of view and it must capture a fresh one.
  Exhausted
}

/// Starts a transfer only after the complete metadata fits its encoded budget.
///
/// ## Examples
///
/// ```gleam
/// // transfer.start(cut, metadata, "connection:1", Recent, now)
/// ```
pub fn start(
  cut: snapshot.Cut,
  metadata: json.JsonValue,
  id: String,
  window: Window,
  now: Int,
) -> Result(Transfer, String) {
  use _ <- result.try(encoded_size(metadata, metadata_encoded_limit))
  let encoded = bit_array.from_string(json.to_string(metadata))
  let #(entries, range) = case window {
    Recent -> #(cut.recent, None)
    Escalations(_) -> #([], None)
    Reconcile(from_seq) -> #(
      [],
      Some(#(int.max(0, from_seq - 1), cut.next_seq)),
    )
    History(after, before) -> #(
      [],
      Some(#(after, int.min(before, cut.next_seq))),
    )
  }
  Ok(Transfer(
    id,
    cut.next_seq,
    0,
    now + lifetime_ms,
    encoded,
    0,
    entries,
    range,
    window,
    0,
    <<>>,
    0,
    None,
  ))
}

/// Tests continuation identity and its absolute retention deadline.
///
/// ## Examples
///
/// ```gleam
/// // transfer.matches(current, snapshot_id, index, now)
/// ```
pub fn matches(transfer: Transfer, id: String, index: Int, now: Int) -> Bool {
  transfer.id == id && transfer.index == index && now < transfer.deadline
}

/// Allows the one gateway heartbeat to expire retained state without timer IDs.
///
/// ## Examples
///
/// ```gleam
/// // transfer.expired(current, now)
/// ```
pub fn expired(transfer: Transfer, now: Int) -> Bool {
  now >= transfer.deadline
}

/// Produces one response or one bounded reader request without performing I/O.
///
/// `now` is the current monotonic instant and `until` the instant by which the
/// request being answered must have its reply, which the caller derives from
/// the socket's own wait. A reader exchange is funded with whichever of the
/// two remainders is smaller, capped at `reader_maximum_ms`; when that is
/// below `reader_minimum_ms` the answer is `Exhausted` and no read is asked
/// for. The budget arithmetic lives here, beside the deadline it is computed
/// from, so no caller can spend a window this module knows to be gone.
///
/// ## Examples
///
/// ```gleam
/// // transfer.step(current, now: 1000, until: 6000)
/// ```
pub fn step(transfer: Transfer, now now: Int, until until: Int) -> Step {
  let budget =
    int.min(reader_maximum_ms, int.min(transfer.deadline - now, until - now))
  case bit_array.byte_size(transfer.metadata) > 0 {
    True -> metadata_piece(transfer)
    False -> entry_piece(transfer, budget)
  }
}

// Every read request passes through here, which is what makes an under-funded
// one unrepresentable rather than merely unlikely.
fn funded(budget: Int, read: fn(Int) -> Step) -> Step {
  case budget >= reader_minimum_ms {
    True -> read(budget)
    False -> Exhausted
  }
}

fn metadata_piece(transfer: Transfer) -> Step {
  let total = bit_array.byte_size(transfer.metadata)
  let size = int.min(piece_bytes, total - transfer.metadata_offset)
  case bit_array.slice(transfer.metadata, transfer.metadata_offset, size) {
    Error(Nil) -> Refused("invalid metadata offset")
    Ok(bytes) -> {
      let next_offset = transfer.metadata_offset + size
      let retained = case next_offset == total {
        True -> <<>>
        False -> transfer.metadata
      }
      Emit(
        chunk(
          transfer,
          "metadata",
          "metadata",
          json.Null,
          total,
          transfer.metadata_offset,
          bytes,
        ),
        Transfer(
          ..transfer,
          index: transfer.index + 1,
          metadata: retained,
          metadata_offset: next_offset,
        ),
      )
    }
  }
}

fn entry_piece(transfer: Transfer, budget: Int) -> Step {
  case transfer.entries {
    [] ->
      case transfer.range {
        Some(#(after, before)) ->
          funded(budget, fn(within) { ReadPage(after, before, within) })
        None ->
          End(
            protocol.SnapshotEnd(
              json.Object([
                #("snapshot_id", json.String(transfer.id)),
                #("index", json.Int(transfer.index)),
                #("next_seq", json.Int(transfer.next_seq)),
                #("more_after", case transfer.more_after {
                  None -> json.Null
                  Some(seq) -> json.Int(seq)
                }),
              ]),
            ),
          )
      }
    [descriptor, ..rest] ->
      buffered_entry_piece(transfer, descriptor, rest, budget)
  }
}

// A retained backend fragment is split without fetching or decoding the entry.
fn buffered_entry_piece(transfer: Transfer, descriptor, rest, budget) -> Step {
  case bit_array.byte_size(transfer.fragment) {
    0 ->
      funded(budget, fn(within) {
        ReadFragment(descriptor, transfer.offset, within)
      })
    total -> {
      let size = int.min(piece_bytes, total - transfer.fragment_offset)
      case bit_array.slice(transfer.fragment, transfer.fragment_offset, size) {
        Error(Nil) -> Refused("invalid entry fragment offset")
        Ok(bytes) -> {
          let offset = transfer.offset + size
          let fragment_offset = transfer.fragment_offset + size
          let #(entries, offset, fragment, fragment_offset) = case
            offset == descriptor.byte_length,
            fragment_offset == total
          {
            True, _ -> #(rest, 0, <<>>, 0)
            False, True -> #(transfer.entries, offset, <<>>, 0)
            False, False -> #(
              transfer.entries,
              offset,
              transfer.fragment,
              fragment_offset,
            )
          }
          Emit(
            chunk(
              transfer,
              "entry",
              ids.entry_id_to_string(descriptor.id),
              json.Int(descriptor.seq),
              descriptor.byte_length,
              transfer.offset,
              bytes,
            ),
            Transfer(
              ..transfer,
              index: transfer.index + 1,
              entries:,
              offset:,
              fragment:,
              fragment_offset:,
            ),
          )
        }
      }
    }
  }
}

fn chunk(
  transfer: Transfer,
  kind,
  record_id,
  record_seq,
  total,
  offset,
  bytes,
) {
  protocol.SnapshotChunk(
    json.Object([
      #("snapshot_id", json.String(transfer.id)),
      #("index", json.Int(transfer.index)),
      #("kind", json.String(kind)),
      #("record_id", json.String(record_id)),
      #("record_seq", record_seq),
      #("total_bytes", json.Int(total)),
      #("offset", json.Int(offset)),
      #("data", json.String(bit_array.base64_encode(bytes, True))),
    ]),
  )
}

/// Accepts one descriptor page without retaining any previous page.
///
/// ## Examples
///
/// ```gleam
/// // transfer.accept_page(current, descriptors)
/// ```
pub fn accept_page(
  transfer: Transfer,
  page: List(snapshot.Descriptor),
) -> Result(Transfer, String) {
  use #(after, before) <- result.try(option.to_result(
    transfer.range,
    "unexpected descriptor page",
  ))
  use <- bool.guard(
    list.drop(page, snapshot.page_limit) != [],
    Error("oversized descriptor page"),
  )
  use last <- result.try(
    list.try_fold(page, after, fn(previous, descriptor) {
      case
        descriptor.seq > previous
        && descriptor.seq < before
        && descriptor.byte_length > 0
        && descriptor.byte_length <= snapshot.record_bytes_limit
      {
        True -> Ok(descriptor.seq)
        False -> Error("invalid entry descriptor")
      }
    }),
  )
  let full = list.drop(page, snapshot.page_limit - 1) != []
  let range = case transfer.window, full {
    Reconcile(_), True -> Some(#(last, before))
    _, _ -> None
  }
  let more_after = case transfer.window, full {
    History(..), True -> Some(last)
    _, _ -> None
  }
  Ok(Transfer(..transfer, entries: page, range:, more_after:))
}

/// Rejects premature EOF and any reader fragment outside the advertised record.
///
/// ## Examples
///
/// ```gleam
/// // transfer.accept_fragment(current, bytes)
/// ```
pub fn accept_fragment(
  transfer: Transfer,
  bytes: BitArray,
) -> Result(Transfer, String) {
  case transfer.entries {
    [] -> Error("unexpected entry fragment")
    [descriptor, ..] -> {
      let size = bit_array.byte_size(bytes)
      case
        size > 0
        && size <= snapshot.fragment_bytes_limit
        && transfer.offset + size <= descriptor.byte_length
      {
        True -> Ok(Transfer(..transfer, fragment: bytes, fragment_offset: 0))
        False -> Error("invalid entry fragment length")
      }
    }
  }
}

// A bounded walk precedes serialization. Six bytes per UTF-8 source byte is a
// safe bound for JSON string escapes; scalar numbers use their actual encoding.
/// Bounds encoded JSON before allocating its rendered binary.
///
/// ## Examples
///
/// ```gleam
/// assert transfer.encoded_size(json.String("x"), 3) == Ok(3)
/// ```
@internal
pub fn encoded_size(value: json.JsonValue, budget: Int) -> Result(Int, String) {
  use <- bool.guard(budget < 0, Error("encoded metadata exceeds its limit"))
  let sized = case value {
    json.Null | json.Bool(_) -> Ok(5)
    json.Int(_) | json.Float(_) -> Ok(string.byte_size(json.to_string(value)))
    json.String(text) -> Ok(quoted_size(text))
    json.Array(values) ->
      list.try_fold(values, 2, fn(size, value) {
        use child <- result.try(encoded_size(value, budget - size - 1))
        Ok(size + child + 1)
      })
    json.Object(fields) ->
      list.try_fold(fields, 2, fn(size, field) {
        let #(key, value) = field
        let prefix = size + 2 + quoted_size(key)
        use child <- result.try(encoded_size(value, budget - prefix))
        Ok(prefix + child)
      })
  }
  use size <- result.try(sized)
  case size <= budget {
    True -> Ok(size)
    False -> Error("encoded metadata exceeds its limit")
  }
}

fn quoted_size(text: String) -> Int {
  list.fold(string.to_utf_codepoints(text), 2, fn(size, point) {
    let code = string.utf_codepoint_to_int(point)
    let bytes = case code {
      code if code < 32 -> 6
      34 | 92 -> 2
      code if code < 128 -> 1
      code if code < 2048 -> 2
      code if code < 65_536 -> 3
      _ -> 4
    }
    size + bytes
  })
}
