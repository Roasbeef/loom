//// Shared SQLite tuning, with explicit overrides for each database.
////
//// Connection-local settings may be applied before ownership admission. Journal
//// changes are separate because they can write the database header: a session
//// opener must first validate the file and acquire its writer lease. Schema
//// identity/version PRAGMAs and WAL retirement remain with their owning database;
//// they are lifecycle operations, not performance defaults.
////
//// Options are trusted host configuration, never model or wire SQL. Extend the
//// typed record when another PRAGMA is needed rather than accepting arbitrary
//// statement strings. Every command uses the binding's busy-total exec path.
////
//// `refusing_unopenable_path` is the other shared rule here, and it is about
//// the binding rather than about performance. `esqlite3_nif:open/1` leaks the
//// handle it has just closed when `sqlite3_open` fails: it calls
//// `sqlite3_close_v2` on the connection and then releases the NIF resource
//// without clearing the pointer, so the resource destructor closes the same
//// connection a second time. The second close frees memory SQLite may have
//// handed to another connection in the same emulator, and that connection's
//// next statement answers `SQLITE_MISUSE` from a header check on memory it no
//// longer owns. The damage is node-wide and lands on whichever database
//// happens to be open at the time, so a caller that hands SQLite a path it
//// cannot open corrupts unrelated work. Refusing such a path before the open
//// is what keeps that unreachable.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight

/// Enforcement of schema-declared foreign-key relationships.
pub type ForeignKeys {
  /// Preserve legacy stores whose schema owns its own reference validation.
  Disabled

  /// Enforce declared references, as required by daemon membership tables.
  Enabled
}

/// The persistent journal policy, applied only after database admission.
pub type Journal {
  /// Allow readers alongside one writer using the write-ahead log.
  Wal

  /// Use SQLite's rollback journal for a database which requires it.
  Delete
}

/// Host-selected options. Record updates provide per-database overrides.
pub type Options {
  Options(
    /// Maximum wait for a contended lock; zero requests immediate refusal.
    busy_timeout_ms: Int,
    /// Persistent journal mode, separate from connection-local configuration.
    journal: Journal,
    /// Schema-specific foreign-key enforcement.
    foreign_keys: ForeignKeys,
    /// Optional positive page-cache target in KiB; None keeps SQLite's default.
    cache_kib: Option(Int),
  )
}

/// The shared tuning defaults used by session, catalogue and search stores.
///
/// ## Examples
///
/// ```gleam
/// let options = sqlite_policy.defaults()
/// let catalogue = sqlite_policy.Options(..options, foreign_keys: sqlite_policy.Enabled)
/// ```
pub fn defaults() -> Options {
  Options(
    busy_timeout_ms: 5000,
    journal: Wal,
    foreign_keys: Disabled,
    cache_kib: None,
  )
}

/// Applies connection-local options without changing the database journal.
///
/// Invalid numeric settings are refused before any setting is applied.
///
/// ## Examples
///
/// ```gleam
/// // sqlite_policy.configure_connection(connection, sqlite_policy.defaults())
/// ```
pub fn configure_connection(
  connection: sqlight.Connection,
  options: Options,
) -> Result(Nil, sqlight.Error) {
  use Nil <- result.try(validate(options))
  use Nil <- result.try(sqlight.exec(
    "PRAGMA busy_timeout = " <> int.to_string(options.busy_timeout_ms),
    on: connection,
  ))
  let foreign_keys = case options.foreign_keys {
    Disabled -> "OFF"
    Enabled -> "ON"
  }
  use Nil <- result.try(sqlight.exec(
    "PRAGMA foreign_keys = " <> foreign_keys,
    on: connection,
  ))
  case options.cache_kib {
    None -> Ok(Nil)
    Some(kib) ->
      sqlight.exec(
        "PRAGMA cache_size = -" <> int.to_string(kib),
        on: connection,
      )
  }
}

/// Applies journal policy after the caller has established file ownership.
///
/// Success means the database is in the requested mode, not merely that the
/// statement ran: the pragma answers with the mode the database ended up in,
/// which is not always the one asked for. SQLite keeps an in-memory database in
/// memory mode even when WAL is requested, and that answer is accepted. No
/// caller may treat this function as proof of session lease acquisition.
///
/// ## Examples
///
/// ```gleam
/// // sqlite_policy.configure_database(connection, options)
/// ```
pub fn configure_database(
  connection: sqlight.Connection,
  options: Options,
) -> Result(Nil, sqlight.Error) {
  let journal = case options.journal {
    Wal -> "WAL"
    Delete -> "DELETE"
  }

  // The change and the read-back are two statements on purpose, and the
  // split is what keeps this total under contention. Changing the journal
  // mode is the one statement here that takes a database-wide lock, so it
  // is the one that returns SQLITE_BUSY when another connection is opening
  // the same file. On the prepared-statement path the binding hands that
  // back as the atom `'$busy'`, for which it has no clause, and the caller
  // dies of a `case_clause` instead of receiving an error — which is
  // exactly what eight racing creators produced on a loaded machine.
  // `sqlight.exec` runs the statement through `sqlite3_exec`, which reports
  // the busy result as an ordinary error, so a contended open refuses
  // instead of crashing.
  use Nil <- result.try(sqlight.exec(
    "PRAGMA journal_mode = " <> journal,
    on: connection,
  ))

  // Reading the mode back is what makes success mean the database is in the
  // requested mode rather than that the statement ran. A temporary or
  // in-memory database keeps its own journal and declines the change by
  // reporting the mode it kept, and an exec discards rows, so the exec
  // above answers Ok to a change that happened and to one that did not. The
  // property at stake is the one this module's doc advertises — readers
  // alongside one writer — which a database left in rollback-journal mode
  // does not have. This second statement only reads the mode already
  // settled by the first, so it takes no lock of its own.
  use reported <- result.try(sqlight.query(
    "PRAGMA journal_mode",
    on: connection,
    with: [],
    expecting: decode.at([0], decode.string),
  ))
  case reported {
    [mode] -> confirm(journal, mode)

    // The pragma answers with exactly one row in every SQLite version this
    // binding supports, so no row at all is a binding change, not a decline.
    [] | [_, _, ..] ->
      Error(declined(
        "SQLite reported no journal mode for the requested " <> journal,
      ))
  }
}

// SQLite reports modes in lower case. An in-memory database legitimately stays
// in "memory" whatever the file policy asks for, which the caller-facing doc
// records; every other disagreement is a declined change wearing a plain reply.
fn confirm(requested: String, reported: String) -> Result(Nil, sqlight.Error) {
  let reported = string.lowercase(reported)
  case reported == string.lowercase(requested) || reported == "memory" {
    True -> Ok(Nil)
    False ->
      Error(declined(
        "SQLite declined journal mode "
        <> requested
        <> " and remains in "
        <> reported,
      ))
  }
}

/// Refuses a path `sqlite3_open` would fail on, before the open is attempted.
///
/// A failed open corrupts the emulator's SQLite state through the binding's
/// double close (see this module's documentation), so every caller that opens
/// a database file at a host-supplied path goes through here first. The two
/// deterministic refusals are the ones a repository actually produces: the
/// path names a directory, or its parent directory is not there. A missing
/// file is not one of them, because `sqlight.open` creating the database is
/// what a first open relies on.
///
/// ## Examples
///
/// ```gleam
/// // sqlite_policy.refusing_unopenable_path("/data/loom-search.db") == Ok(Nil)
/// ```
pub fn refusing_unopenable_path(path: String) -> Result(Nil, String) {
  // SQLite reads these two as requests for a private database rather than as
  // paths, and neither reaches the filesystem, so neither can fail the open.
  use <- bool.guard(when: path == ":memory:" || path == "", return: Ok(Nil))

  use Nil <- result.try(case simplifile.is_directory(path) {
    Ok(True) -> Error("a directory sits at " <> path)
    Ok(False) -> Ok(Nil)

    // A path that cannot be inspected is not a path that can be shown to be
    // unopenable, so the open decides. That is the pre-existing behaviour,
    // and it is reached only for permission and I/O faults on the parent.
    Error(_) -> Ok(Nil)
  })
  case parent_directory(path) {
    None -> Ok(Nil)
    Some(parent) ->
      case simplifile.is_directory(parent) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> Error("no directory at " <> parent <> " to hold " <> path)
        Error(_) -> Ok(Nil)
      }
  }
}

// The directory a file path lives in, or `None` for a bare name, which lives
// in the working directory and so has no parent to check.
fn parent_directory(path: String) -> Option(String) {
  case string.split(path, "/") {
    [] | [_] -> None

    // A leading separator leaves an empty first segment, and the parent of
    // `/loom.db` is the root directory rather than the empty string.
    segments ->
      case string.join(list.take(segments, list.length(segments) - 1), "/") {
        "" -> Some("/")
        parent -> Some(parent)
      }
  }
}

fn declined(message: String) -> sqlight.Error {
  sqlight.SqlightError(code: sqlight.Misuse, message:, offset: -1)
}

fn validate(options: Options) -> Result(Nil, sqlight.Error) {
  let valid_cache = case options.cache_kib {
    None -> True
    Some(kib) -> kib > 0
  }
  case options.busy_timeout_ms >= 0 && valid_cache {
    True -> Ok(Nil)
    False ->
      Error(sqlight.SqlightError(
        code: sqlight.Misuse,
        message: "SQLite tuning requires a nonnegative busy timeout and positive cache KiB",
        offset: -1,
      ))
  }
}
