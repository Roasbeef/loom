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

import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
