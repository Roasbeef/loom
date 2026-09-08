//// Shared tuning tests inspect SQLite itself, not just rendered statements.
//// Connection-local overrides must not alter the journal before admission.

import gleam/dynamic/decode
import gleam/option.{Some}
import gleam/string
import simplifile
import sqlight
import storage/sqlite_policy as policy
import support/fixtures

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

  // An in-memory database stays in memory mode whatever the file policy asks
  // for. That answer is the documented exception to journal verification, so it
  // must remain a success rather than becoming a refusal.
  assert policy.configure_database(first, defaults) == Ok(Nil)
  assert journal(first) == "memory"
  assert policy.defaults() == defaults
  assert sqlight.close(first) == Ok(Nil)
  assert sqlight.close(second) == Ok(Nil)
}

pub fn journal_policy_is_separate_from_pre_admission_settings_test() {
  let path = fixtures.scratch("sqlite-policy-journal") <> "/policy.db"
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

pub fn declined_journal_change_is_not_reported_as_success_test() {
  // An empty path opens SQLite's private temporary database, which cannot be
  // moved into WAL. It declines by answering with the mode it kept instead of
  // by failing the statement, so this is the reachable case that separates
  // running the pragma from reading its answer.
  let assert Ok(temporary) = sqlight.open("") as "temporary database opens"
  let declined = policy.configure_database(temporary, policy.defaults())
  let assert Error(sqlight.SqlightError(code: sqlight.Misuse, ..)) = declined
    as "a declined journal change is an error, not a silent success"
  assert journal(temporary) == "delete"
  assert sqlight.close(temporary) == Ok(Nil)
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

// The refusal exists because a failed `sqlite3_open` corrupts every other
// connection in the emulator, not because opening a directory is untidy, so
// what these cases pin is that the refusal happens before SQLite sees the
// path at all.
pub fn a_directory_is_refused_before_the_open_test() {
  let scratch = fixtures.scratch("sqlite-policy-unopenable")
  let occupied = scratch <> "/loom-search.db"
  let assert Ok(Nil) = simplifile.create_directory_all(occupied)
    as "the obstruction must exist before the path is judged"
  let assert Error(reason) = policy.refusing_unopenable_path(occupied)
    as "a directory in the database's place is refused"
  assert string.contains(reason, occupied)
}

pub fn a_missing_parent_directory_is_refused_before_the_open_test() {
  let assert Error(reason) =
    policy.refusing_unopenable_path("/nonexistent/loom-policy/index.db")
    as "a database under a directory that is not there is refused"
  assert string.contains(reason, "/nonexistent/loom-policy")
}

// A first open creates its database, and the whole durability plane relies on
// that, so a missing file under a directory that exists must stay allowed.
pub fn a_missing_file_under_a_real_directory_is_allowed_test() {
  let scratch = fixtures.scratch("sqlite-policy-first-open")
  assert policy.refusing_unopenable_path(scratch <> "/fresh.db") == Ok(Nil)
  assert policy.refusing_unopenable_path(":memory:") == Ok(Nil)
  assert policy.refusing_unopenable_path("") == Ok(Nil)
}

// A `file:` URI is not a filesystem path, and its parent directory is the
// literal `file:`, so judging one here would refuse every URI open. The
// callers that build URIs judge the decoded path they built the URI from, so
// the rule has to pass a URI through rather than guess at its meaning.
pub fn a_file_uri_is_not_judged_as_a_path_test() {
  assert policy.refusing_unopenable_path(
      "file:/nonexistent/loom-policy/index.db?mode=ro",
    )
    == Ok(Nil)
}

// A read-only open cannot create the database, so a registered source that has
// since been deleted is a refusal rather than a fresh file.
pub fn a_missing_file_is_refused_for_a_read_only_open_test() {
  let scratch = fixtures.scratch("sqlite-policy-read-only")
  let absent = scratch <> "/removed.db"
  assert policy.refusing_unopenable_path(absent) == Ok(Nil)
  let assert Error(reason) = policy.refusing_unreadable_path(absent)
    as "a read-only open of a file that is not there is refused"
  assert string.contains(reason, absent)
}
