//// SQLite implementation of the bounded client reader.
////
//// The existing storage actor calls these functions on its own connection.
//// Capture holds one short deferred transaction through metadata selection and
//// initial inventory, and ends it before replying. Later pages/fragments use
//// immutable rows and never keep a SQLite snapshot pinned across network waits.
//// Every new query is generated from storage/sql/snapshot.sql. Header queries
//// fetch lengths before payloads; the entry decoder never runs on this path.

import core/codec
import core/corruption
import core/ids
import core/json
import core/register
import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/snapshot.{type Error}
import storage/sql
import storage/storage

/// Captures mutable metadata without reserving SQLite's writer lock.
///
/// ## Examples
///
/// ```gleam
/// // Called only by sqlite's connection owner: snapshot_sqlite.capture(conn, plan).
/// ```
pub fn capture(
  conn: sqlight.Connection,
  plan: snapshot.Plan,
) -> Result(snapshot.Cut, Error) {
  use Nil <- result.try(snapshot.validate(plan))
  use Nil <- result.try(
    sqlight.exec("BEGIN DEFERRED", on: conn) |> result.map_error(database_error),
  )
  let captured = {
    use cut <- result.try(capture_cut(conn, plan))
    use Nil <- result.map(
      sqlight.exec("COMMIT", on: conn) |> result.map_error(database_error),
    )
    cut
  }
  case captured {
    Ok(cut) -> Ok(cut)
    Error(error) -> {
      let _rolled_back = sqlight.exec("ROLLBACK", on: conn)
      Error(error)
    }
  }
}

fn capture_cut(
  conn: sqlight.Connection,
  plan: snapshot.Plan,
) -> Result(snapshot.Cut, Error) {
  use summary <- result.try(one(conn, sql.snapshot_session()))
  use next_seq <- result.try(required(summary.next_seq))
  use message_count <- result.try(required(summary.message_count))
  use usage_bytes <- result.try(required(summary.usage_bytes))
  use <- bool.lazy_guard(
    next_seq < 1 || message_count < 0 || usage_bytes < 0,
    fn() { Error(invalid_row("nonnegative counts and a positive high-water")) },
  )
  use Nil <- result.try(snapshot.check_budget(0, usage_bytes))
  use stored_usage <- result.try(one(conn, sql.snapshot_usage_value()))
  use usage_blob <- result.try(required(stored_usage.usage_payload))
  use value <- result.try(payload(usage_blob))
  use usage <- result.try(
    codec.decode_usage(value) |> result.map_error(corrupt),
  )
  use #(cells, metadata_bytes) <- result.try(snapshot.collect(
    plan,
    snapshot.Source(
      headers: fn(namespace, prefix, predicate) {
        headers(conn, namespace, prefix, predicate)
      },
      header: fn(namespace, key) { header(conn, namespace, key) },
      cell: fn(header) { cell(conn, header) },
    ),
    initial_bytes: usage_bytes,
  ))
  use rows <- result.try(query(
    conn,
    sql.snapshot_recent_entries(Some(next_seq), plan.recent_entries),
  ))
  use recent <- result.map(
    list.try_map(rows, fn(row) {
      descriptor(row.id, row.seq, row.payload_bytes)
    }),
  )
  snapshot.Cut(
    next_seq:,
    stats: storage.SessionStats(message_count:, usage:),
    cells:,
    metadata_bytes:,
    recent: list.reverse(recent),
  )
}

fn headers(
  conn: sqlight.Connection,
  namespace: register.RegisterNs,
  prefix: String,
  predicate: snapshot.Predicate,
) -> Result(List(snapshot.Header), Error) {
  let #(field, expected) = case predicate {
    snapshot.All -> #("", "")
    snapshot.StringFieldEquals(field, expected) -> #(field, expected)
  }

  // Both statements bound the prefix as a key range rather than testing every
  // key in the namespace, so the successor has to be computed before either
  // runs. An empty string is how they spell "no upper bound"; a real successor
  // always has at least one code point, so the two cannot be confused.
  use upper <- result.try(prefix_successor(prefix))
  let upper = option.unwrap(upper, "")

  // Keys are variable-size payloads too. Account the complete selection before
  // returning even its headers, not merely before fetching register values.
  use budget <- result.try(one(
    conn,
    sql.snapshot_register_budget(
      register.ns_to_string(namespace),
      prefix,
      upper,
      field,
      expected,
    ),
  ))
  use Nil <- result.try(snapshot.check_budget(
    budget.cell_count,
    budget.total_bytes,
  ))
  use rows <- result.try(query(
    conn,
    sql.snapshot_register_headers(
      register.ns_to_string(namespace),
      prefix,
      upper,
      field,
      expected,
    ),
  ))
  list.try_map(rows, fn(row) {
    use byte_length <- result.map(required(row.value_bytes))
    snapshot.Header(namespace, row.key, row.seq, byte_length)
  })
}

// The smallest string sorting above every key that carries `prefix`. `None` is
// the prefix that has no successor: the empty one, or one whose code points are
// all the maximum. For those the lower bound alone already admits exactly the
// prefixed keys, so the range stays open above rather than borrowing a bound
// that would drop keys. Working in code points keeps the literal-prefix
// property of `Selection` intact: no character in the prefix is a pattern, so
// none needs escaping.
fn prefix_successor(prefix: String) -> Result(Option(String), Error) {
  let trimmed =
    string.to_utf_codepoints(prefix)
    |> list.reverse
    |> list.drop_while(fn(point) {
      string.utf_codepoint_to_int(point) == maximum_code_point
    })
  case trimmed {
    [] -> Ok(None)
    [last, ..earlier] -> {
      use next <- result.map(next_code_point(string.utf_codepoint_to_int(last)))
      Some(string.from_utf_codepoints(list.reverse([next, ..earlier])))
    }
  }
}

// The largest code point a string can hold, and so the one with no successor.
const maximum_code_point = 0x10FFFF

// The next code point after one taken from an existing string. The trailing
// maximum has already been dropped, so the increment stays in range, and the
// only value whose increment is not a code point at all is the one just below
// the UTF-16 surrogate block. An unrepresentable answer would silently widen
// the scan past the prefix, so it fails the read instead.
fn next_code_point(code: Int) -> Result(UtfCodepoint, Error) {
  case code {
    0xD7FF -> string.utf_codepoint(0xE000)
    other -> string.utf_codepoint(other + 1)
  }
  |> result.replace_error(snapshot.InvalidRequest)
}

fn header(
  conn: sqlight.Connection,
  namespace: register.RegisterNs,
  key: String,
) -> Result(snapshot.Header, Error) {
  use row <- result.try(one(
    conn,
    sql.snapshot_register_header(register.ns_to_string(namespace), key),
  ))
  use byte_length <- result.map(required(row.value_bytes))
  snapshot.Header(namespace, key, row.seq, byte_length)
}

fn cell(
  conn: sqlight.Connection,
  header: snapshot.Header,
) -> Result(snapshot.Cell, Error) {
  use row <- result.try(one(
    conn,
    sql.snapshot_register_value(
      register.ns_to_string(header.namespace),
      header.key,
      header.seq,
    ),
  ))
  use value <- result.map(payload(row.value))
  snapshot.Cell(
    header.namespace,
    header.key,
    storage.Register(register.value(value), header.seq),
  )
}

/// Returns at most one bounded descriptor page, without entry payloads.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_sqlite.page(conn, 0, cut.next_seq, 100)
/// ```
pub fn page(
  conn: sqlight.Connection,
  after: Int,
  before: Int,
  limit: Int,
) -> Result(List(snapshot.Descriptor), Error) {
  use Nil <- result.try(snapshot.validate_page(after, before, limit))
  use rows <- result.try(query(
    conn,
    sql.snapshot_entry_page(Some(after), Some(before), limit),
  ))
  list.try_map(rows, fn(row) { descriptor(row.id, row.seq, row.payload_bytes) })
}

fn descriptor(
  id: String,
  seq: Option(Int),
  bytes: Option(Int),
) -> Result(snapshot.Descriptor, Error) {
  use id <- result.try(ids.parse_entry_id(id) |> result.map_error(corrupt))
  use seq <- result.try(required(seq))
  use byte_length <- result.try(required(bytes))
  snapshot.validate_descriptor(snapshot.Descriptor(id:, seq:, byte_length:))
}

/// Slices the immutable blob in SQLite before it crosses into BEAM memory.
///
/// Descriptor identity, sequence and length must still match. A byte offset
/// may split UTF-8; the receiver decodes only the completely reassembled record.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_sqlite.fragment(conn, descriptor, 0)
/// ```
pub fn fragment(
  conn: sqlight.Connection,
  descriptor: snapshot.Descriptor,
  offset: Int,
) -> Result(BitArray, Error) {
  use Nil <- result.try(snapshot.validate_fragment(descriptor, offset))
  use row <- result.map(one(
    conn,
    sql.snapshot_entry_fragment(
      offset,
      snapshot.fragment_bytes_limit,
      ids.entry_id_to_string(descriptor.id),
      Some(descriptor.seq),
      descriptor.byte_length,
    ),
  ))
  row.fragment
}

fn payload(bytes: BitArray) -> Result(json.JsonValue, Error) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { invalid_row("UTF-8 JSON bytes") }),
  )
  json.parse(text) |> result.map_error(corrupt)
}

fn required(value: Option(a)) -> Result(a, Error) {
  case value {
    Some(value) -> Ok(value)
    None -> Error(invalid_row("a non-null column"))
  }
}

fn invalid_row(expected: String) -> Error {
  corrupt(corruption.report(
    at: "storage/snapshot",
    on: "row",
    expected:,
    context: "invalid stored snapshot row",
  ))
}

fn query(
  conn: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(statement, params, decoder) = generated
  use params <- result.try(list.try_map(params, parameter))
  sqlight.query(statement, on: conn, with: params, expecting: decoder)
  |> result.map_error(database_error)
}

fn one(
  conn: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(a, Error) {
  use rows <- result.try(query(conn, generated))
  case rows {
    [row] -> Ok(row)
    [] -> Error(snapshot.MissingRecord)
    [_, _, ..] -> Error(invalid_row("exactly one stored row"))
  }
}

fn parameter(param: dev.Param) -> Result(sqlight.Value, Error) {
  case param {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamNullable(Some(inner)) -> parameter(inner)
    dev.ParamNullable(None) -> Ok(sqlight.null())
    dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamBitArray(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) -> Error(snapshot.InvalidRequest)
  }
}

fn database_error(error: sqlight.Error) -> Error {
  snapshot.StorageFailure(storage.BackendFault(
    "snapshot SQLite: " <> error.message,
  ))
}

fn corrupt(report: corruption.CorruptionReport) -> Error {
  snapshot.StorageFailure(storage.CorruptRow(report))
}
