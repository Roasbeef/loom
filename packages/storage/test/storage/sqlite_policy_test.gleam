//// Shared tuning tests inspect SQLite itself, not just rendered statements.
//// Connection-local overrides must not alter the journal before admission.

import gleam/dynamic/decode
import gleam/option.{Some}
import simplifile
import sqlight
import storage/sqlite_policy as policy

fn number(connection: sqlight.Connection, pragma: String) {
  let assert Ok([value]) =
    sqlight.query(
      pragma,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    as "SQLite returns one numeric setting"
  value
}

fn journal(connection: sqlight.Connection) {
  let assert Ok([value]) =
    sqlight.query(
      "PRAGMA journal_mode",
      on: connection,
      with: [],
      expecting: decode.at([0], decode.string),
    )
    as "SQLite returns its actual journal mode"
  value
}

pub fn database_overrides_do_not_change_shared_defaults_test() {
  let assert Ok(first) = sqlight.open(":memory:") as "first connection opens"
  let assert Ok(second) = sqlight.open(":memory:") as "second connection opens"
  let defaults = policy.defaults()
  let custom =
    policy.Options(
      ..defaults,
      busy_timeout_ms: 17,
      foreign_keys: policy.Enabled,
      cache_kib: Some(1024),
    )
  assert policy.configure_connection(first, custom) == Ok(Nil)
  assert policy.configure_connection(second, defaults) == Ok(Nil)
  assert number(first, "PRAGMA busy_timeout") == 17
  assert number(first, "PRAGMA foreign_keys") == 1
  assert number(first, "PRAGMA cache_size") == -1024
  assert number(second, "PRAGMA busy_timeout") == defaults.busy_timeout_ms
  assert number(second, "PRAGMA foreign_keys") == 0
  assert journal(first) == "memory"
  assert policy.defaults() == defaults
  assert sqlight.close(first) == Ok(Nil)
  assert sqlight.close(second) == Ok(Nil)
}

pub fn journal_policy_is_separate_from_pre_admission_settings_test() {
  let assert Ok(Nil) = simplifile.create_directory_all("build/test_db")
    as "fixture directory exists"
  let path = "build/test_db/sqlite-policy.db"
  let assert Ok(connection) = sqlight.open(path) as "fixture opens"
  let defaults = policy.defaults()
  assert policy.configure_database(
      connection,
      policy.Options(..defaults, journal: policy.Delete),
    )
    == Ok(Nil)
  assert journal(connection) == "delete"
  assert policy.configure_connection(connection, defaults) == Ok(Nil)
  assert journal(connection) == "delete"
  assert policy.configure_database(connection, defaults) == Ok(Nil)
  assert journal(connection) == "wal"
  assert sqlight.close(connection) == Ok(Nil)
}

pub fn invalid_options_fail_before_any_pragma_changes_test() {
  let assert Ok(connection) = sqlight.open(":memory:") as "connection opens"
  let defaults = policy.defaults()
  assert policy.configure_connection(connection, defaults) == Ok(Nil)
  let invalid =
    policy.Options(..defaults, busy_timeout_ms: 17, cache_kib: Some(0))
  let assert Error(sqlight.SqlightError(code: sqlight.Misuse, ..)) =
    policy.configure_connection(connection, invalid)
    as "invalid cache setting refuses the whole configuration"
  assert number(connection, "PRAGMA busy_timeout") == defaults.busy_timeout_ms
  assert sqlight.close(connection) == Ok(Nil)
}
