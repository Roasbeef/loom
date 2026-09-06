//// An owned read-only connection for the shared history coordinator.
////
//// Acquire returns the native handle before configuration or source inspection.
//// The coordinator retains it in state, then executes bounded indexed reads
//// between mailbox turns. Identity, generation and high-water come from one
//// short transaction on this connection, never separate path-based opens.
//// Close failure leaves the handle owned; caller timeout proves no retirement.
//// Entry bytes use the snapshot reader's descriptor and fragment bounds.

import core/ids
import core/json
import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import parrot/dev
import sqlight
import storage/internal/snapshot_sqlite
import storage/snapshot
import storage/sql
import storage/sqlite_policy

/// A connection that never acquires, renews or releases a conversation lease.
/// Ownership is linear: after successful close, this raw capability is invalid.
/// Externally reachable read-after-retirement refusal belongs to its actor owner.
@internal
pub opaque type Source {
  Source(connection: sqlight.Connection, path: String)
}

/// The immutable inventory boundary and rewrite generation on one connection.
@internal
pub type Cut {
  Cut(
    /// Identity verified against the catalogue's expected session.
    session: ids.SessionId,
    /// Source rewrite counter, including restored earlier generations.
    generation: Int,
    /// Only entries strictly below this sequence belong to this cut.
    next_seq: Int,
  )
}

/// Opens without creating a missing source or applying schema changes.
///
/// ## Examples
///
/// ```gleam
/// // history_source.acquire(canonical_path)
/// ```
@internal
pub fn acquire(path: String) -> Result(Source, String) {
  let encoded =
    path
    |> string.split("/")
    |> list.map(uri.percent_encode)
    |> string.join("/")
  sqlight.open("file:" <> encoded <> "?mode=ro&cache=private")
  |> result.map(fn(connection) { Source(connection, path) })
  |> result.map_error(describe)
}

/// The trusted canonical path selected when this connection was acquired.
///
/// ## Examples
///
/// ```gleam
/// // history_source.path(source)
/// ```
@internal
pub fn path(source: Source) -> String {
  source.path
}

/// Applies finite connection-local busy handling to an already retained handle.
/// This never configures database journaling or runs migrations on the source.
///
/// ## Examples
///
/// ```gleam
/// // history_source.initialize(source, 1000)
/// ```
@internal
pub fn initialize(source: Source, busy_ms: Int) -> Result(Nil, String) {
  use <- bool.guard(
    when: busy_ms <= 0 || busy_ms > 5000,
    return: Error("history source busy timeout must be between 1 and 5000"),
  )
  let options =
    sqlite_policy.Options(..sqlite_policy.defaults(), busy_timeout_ms: busy_ms)
  sqlite_policy.configure_connection(source.connection, options)
  |> result.map_error(describe)
}

/// Reads bounded identity metadata and generation in one short transaction.
/// A missing identity never becomes an implicit grant to read a different file.
///
/// ## Examples
///
/// ```gleam
/// // history_source.inspect(source, expected_session)
/// ```
@internal
pub fn inspect(source: Source, expected: ids.SessionId) -> Result(Cut, String) {
  use Nil <- result.try(statement(source, "BEGIN DEFERRED"))
  let read = {
    use header <- result.try(one(source, sql.history_source_header()))
    use <- bool.guard(
      when: header.metadata_bytes < 0
        || header.metadata_bytes > snapshot.metadata_bytes_limit,
      return: Error("history source metadata exceeds its byte budget"),
    )
    use next_seq <- result.try(case header.next_seq {
      Some(value) if value > 0 -> Ok(value)
      Some(_) | None -> Error("invalid history source high-water")
    })
    use row <- result.try(one(source, sql.history_source_metadata()))
    use blob <- result.try(row.metadata |> result_from_option)
    use text <- result.try(
      bit_array.to_string(blob)
      |> result.replace_error("source metadata is not UTF-8"),
    )
    use value <- result.try(
      json.parse(text) |> result.map_error(string.inspect),
    )
    use fields <- result.try(case value {
      json.Object(fields) -> Ok(fields)
      _ -> Error("source metadata is not an object")
    })
    use <- bool.guard(
      when: list.key_find(fields, "session_id")
        != Ok(json.String(ids.session_id_to_string(expected))),
      return: Error("history source session identity mismatch"),
    )
    use generation <- result.try(case list.key_find(fields, "generation") {
      Ok(json.Int(value)) if value >= 0 -> Ok(value)
      Error(Nil) -> Ok(0)
      Ok(_) -> Error("invalid history source generation")
    })
    use Nil <- result.map(statement(source, "COMMIT"))
    Cut(expected, generation, next_seq)
  }
  case read {
    Ok(cut) -> Ok(cut)
    Error(reason) -> {
      let _rollback = statement(source, "ROLLBACK")
      Error(reason)
    }
  }
}

/// Reads at most one bounded descriptor page below the captured high-water.
///
/// ## Examples
///
/// ```gleam
/// // history_source.page(source, cut, after: 0, limit: 10)
/// ```
@internal
pub fn page(
  source: Source,
  cut: Cut,
  after: Int,
  limit: Int,
) -> Result(List(snapshot.Descriptor), String) {
  snapshot_sqlite.page(source.connection, after, cut.next_seq, limit)
  |> result.map_error(string.inspect)
}

/// Looks up one entry's size before any payload crosses the native boundary.
///
/// ## Examples
///
/// ```gleam
/// // history_source.entry(source, cut, entry_id)
/// ```
@internal
pub fn entry(
  source: Source,
  cut: Cut,
  id: ids.EntryId,
) -> Result(snapshot.Descriptor, String) {
  use rows <- result.try(query(
    source,
    sql.history_source_entry(ids.entry_id_to_string(id), Some(cut.next_seq)),
  ))
  use row <- result.try(case rows {
    [row] -> Ok(row)
    [] -> Error("history entry was not found")
    [_, _, ..] -> Error("history entry identity is ambiguous")
  })
  use seq <- result.try(result_from_option(row.seq))
  use bytes <- result.try(result_from_option(row.payload_bytes))
  let descriptor = snapshot.Descriptor(id, seq, bytes)
  snapshot.validate_descriptor(descriptor) |> result.map_error(string.inspect)
}

/// Reads one bounded fragment without decoding or materializing the entry.
///
/// ## Examples
///
/// ```gleam
/// // history_source.fragment(source, descriptor, 0)
/// ```
@internal
pub fn fragment(
  source: Source,
  descriptor: snapshot.Descriptor,
  offset: Int,
) -> Result(BitArray, String) {
  snapshot_sqlite.fragment(source.connection, descriptor, offset)
  |> result.map_error(string.inspect)
}

/// Returns the actual native close result, never a timeout-as-drain verdict.
///
/// ## Examples
///
/// ```gleam
/// // history_source.close(source)
/// ```
@internal
pub fn close(source: Source) -> Result(Nil, String) {
  sqlight.close(source.connection) |> result.map_error(describe)
}

// Transaction control and the two ROLLBACK paths above; every other statement
// on this connection is a generated query.
fn statement(source: Source, text: String) -> Result(Nil, String) {
  sqlight.exec(text, source.connection) |> result.map_error(describe)
}

// A nullable column that the reader requires. The source file is another
// process's database, so a missing value is bad data rather than a bug here.
fn result_from_option(value: Option(a)) -> Result(a, String) {
  case value {
    Some(value) -> Ok(value)
    None -> Error("history source contains a missing required field")
  }
}

fn query(
  source: Source,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), String) {
  let #(statement, params, decoder) = generated
  use params <- result.try(list.try_map(params, parameter))
  sqlight.query(statement, source.connection, params, decoder)
  |> result.map_error(describe)
}

// The session catalog holds exactly one row, so both "no row" and "several"
// mean the file is not the single-session database this reader was given.
fn one(
  source: Source,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(a, String) {
  use rows <- result.try(query(source, generated))
  case rows {
    [row] -> Ok(row)
    [] | [_, _, ..] -> Error("history source requires exactly one session row")
  }
}

// The history queries bind only non-null strings and nullable integers. The
// remaining variants are listed rather than caught, so a future generator
// change breaks the build here instead of binding something unintended, the
// way the catalogue and snapshot bridges already do.
fn parameter(value: dev.Param) -> Result(sqlight.Value, String) {
  case value {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamNullable(Some(value)) -> parameter(value)
    dev.ParamNullable(None) -> Ok(sqlight.null())
    dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamBitArray(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) -> Error("unsupported history query parameter")
  }
}

fn describe(error: sqlight.Error) -> String {
  error.message
}
