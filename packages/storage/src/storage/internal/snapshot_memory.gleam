//// The in-memory reader shares the SQLite reader's cut and byte contracts.
////
//// Memory already owns decoded entries and registers. It serializes at most
//// one selected record at a time, while descriptor selection retains only the
//// bounded inventory window. Unlike SQLite, it cannot avoid serialization to
//// measure an encoded row; it is the ephemeral/testing backend, not a second
//// production large-history transport. No snapshot keeps a second state tree.

import core/codec
import core/entry.{type Entry}
import core/ids
import core/json
import core/register.{type RegisterNs}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import storage/snapshot.{type Error}
import storage/storage.{type Register, type SessionStats}

/// Existing immutable backend state, borrowed only for one dispatch.
pub type View {
  View(
    /// Existing decoded entries; descriptor selection does not copy the map.
    entries: Dict(String, Entry),
    /// Existing mutable cells, frozen by this dispatch's immutable state value.
    registers: Dict(String, Dict(String, Register)),
    /// The first sequence not allocated at this cut.
    next_seq: Int,
    /// Statistics from the same state as the register and entry maps.
    stats: SessionStats,
  )
}

/// Captures metadata and recent descriptors from one immutable state value.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_memory.capture(view, plan)
/// ```
pub fn capture(view: View, plan: snapshot.Plan) -> Result(snapshot.Cut, Error) {
  use Nil <- result.try(snapshot.validate(plan))
  let usage_bytes =
    string.byte_size(json.to_string(codec.encode_usage(view.stats.usage)))
  use #(cells, metadata_bytes) <- result.try(snapshot.collect(
    plan,
    snapshot.Source(
      headers: fn(namespace, prefix, predicate) {
        headers(view, namespace, prefix, predicate)
      },
      header: fn(namespace, key) { header(view, namespace, key) },
      cell: fn(header) { cell(view, header) },
    ),
    initial_bytes: usage_bytes,
  ))
  let entries =
    bounded_entries(
      view,
      0,
      view.next_seq,
      plan.recent_entries,
      storage.NewestFirst,
    )
  use recent <- result.map(list.try_map(list.reverse(entries), descriptor))
  snapshot.Cut(view.next_seq, view.stats, cells, metadata_bytes, recent)
}

fn headers(
  view: View,
  namespace: RegisterNs,
  prefix: String,
  predicate: snapshot.Predicate,
) -> Result(List(snapshot.Header), Error) {
  let cells =
    dict.get(view.registers, register.ns_to_string(namespace))
    |> result.lazy_unwrap(dict.new)
  let selected =
    dict.fold(cells, Ok([]), fn(acc, key, value) {
      use acc <- result.try(acc)
      case string.starts_with(key, prefix) {
        False -> Ok(acc)
        True -> {
          let header = make_header(namespace, key, value)
          use Nil <- result.try(snapshot.check_budget(
            1,
            header.byte_length
              + string.byte_size(key)
              + string.byte_size(register.ns_to_string(namespace))
              + 65,
          ))
          use matches <- result.try(snapshot.matches(
            predicate,
            value.value.payload,
          ))
          case matches {
            False -> Ok(acc)
            True -> {
              Ok(list.take([header, ..acc], snapshot.metadata_cells_limit + 1))
            }
          }
        }
      }
    })
  result.map(selected, fn(headers) {
    list.sort(headers, fn(a, b) { string.compare(a.key, b.key) })
  })
}

fn make_header(
  namespace: RegisterNs,
  key: String,
  value: Register,
) -> snapshot.Header {
  snapshot.Header(
    namespace,
    key,
    value.seq,
    string.byte_size(json.to_string(codec.encode_register_value(value.value))),
  )
}

fn header(
  view: View,
  namespace: RegisterNs,
  key: String,
) -> Result(snapshot.Header, Error) {
  use value <- result.map(find(view, namespace, key))
  make_header(namespace, key, value)
}

fn cell(view: View, header: snapshot.Header) -> Result(snapshot.Cell, Error) {
  use value <- result.map(find(view, header.namespace, header.key))
  snapshot.Cell(header.namespace, header.key, value)
}

fn find(
  view: View,
  namespace: RegisterNs,
  key: String,
) -> Result(Register, Error) {
  use cells <- result.try(
    dict.get(view.registers, register.ns_to_string(namespace))
    |> result.replace_error(snapshot.MissingRecord),
  )
  dict.get(cells, key) |> result.replace_error(snapshot.MissingRecord)
}

/// Reads one bounded ascending inventory window below a fixed high-water.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_memory.page(view, 0, cut.next_seq, 100)
/// ```
pub fn page(
  view: View,
  after: Int,
  before: Int,
  limit: Int,
) -> Result(List(snapshot.Descriptor), Error) {
  use Nil <- result.try(snapshot.validate_page(after, before, limit))
  bounded_entries(view, after, before, limit, storage.OldestFirst)
  |> list.try_map(descriptor)
}

// The dictionary walk never converts the whole inventory to a list. It keeps
// only the requested window, and serializes only its surviving entries.
fn bounded_entries(
  view: View,
  after: Int,
  before: Int,
  limit: Int,
  ordering: storage.ScanOrder,
) -> List(Entry) {
  dict.fold(view.entries, [], fn(acc, _, entry) {
    case entry.seq > after && entry.seq < before {
      False -> acc
      True ->
        [entry, ..acc]
        |> list.sort(fn(a, b) {
          case ordering {
            storage.OldestFirst -> int.compare(a.seq, b.seq)
            storage.NewestFirst -> int.compare(b.seq, a.seq)
          }
        })
        |> list.take(limit)
    }
  })
}

fn descriptor(entry: Entry) -> Result(snapshot.Descriptor, Error) {
  snapshot.validate_descriptor(snapshot.Descriptor(
    entry.id,
    entry.seq,
    bit_array.byte_size(encoded(entry)),
  ))
}

fn encoded(entry: Entry) -> BitArray {
  entry |> codec.encode_entry |> json.to_string |> bit_array.from_string
}

/// Returns the same byte slice SQLite produces, including split UTF-8.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_memory.fragment(view, descriptor, 0)
/// ```
pub fn fragment(
  view: View,
  descriptor: snapshot.Descriptor,
  offset: Int,
) -> Result(BitArray, Error) {
  use Nil <- result.try(snapshot.validate_fragment(descriptor, offset))
  use entry <- result.try(
    dict.get(view.entries, ids.entry_id_to_string(descriptor.id))
    |> result.replace_error(snapshot.MissingRecord),
  )
  let bytes = encoded(entry)
  case
    entry.seq == descriptor.seq
    && bit_array.byte_size(bytes) == descriptor.byte_length
  {
    False -> Error(snapshot.MissingRecord)
    True ->
      bit_array.slice(
        bytes,
        offset,
        int.min(snapshot.fragment_bytes_limit, descriptor.byte_length - offset),
      )
      |> result.replace_error(snapshot.InvalidRequest)
  }
}
