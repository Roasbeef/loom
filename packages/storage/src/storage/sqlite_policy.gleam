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

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
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
/// SQLite keeps an in-memory database in memory mode even when WAL is requested.
/// No caller may treat this function as proof of session lease acquisition.
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
  sqlight.exec("PRAGMA journal_mode = " <> journal, on: connection)
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
