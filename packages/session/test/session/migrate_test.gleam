//// Migrate-on-open (pi §2.8, spec WP-C): a session file from a newer
//// build refuses to open; an older file runs the ordered migration chain
//// under the open. The chain is empty today — these tests exercise the
//// seam with a tampered version and a synthetic step.

import core/clock
import gleam/dynamic/decode
import session/session
import simplifile
import sqlight
import storage/sqlite
import storage/storage

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

// Creates a session file, closes it, and stamps the given storage
// version into its catalog — simulating a file written by another build.
fn tampered_file(name: String, version: Int) -> String {
  let path = fresh_path(name)
  let assert Ok(sess) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
  let assert Ok(Nil) = session.close(sess)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.query(
      "UPDATE session SET storage_version = ?1",
      on: conn,
      with: [sqlight.int(version)],
      expecting: decode.dynamic,
    )
  let assert Ok(Nil) = sqlight.close(conn)
  path
}

pub fn the_chain_is_empty_today_test() {
  assert session.migration_chain() == []
}

pub fn newer_version_refuses_to_open_test() {
  let path = tampered_file("migrate_newer", 99)
  let assert Error(session.SqliteOpenFailed(error: sqlite.UnsupportedVersion(
    found: 99,
    supported: 1,
  ))) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 50_000),
    )
}

pub fn older_version_without_a_step_refuses_to_open_test() {
  let path = tampered_file("migrate_no_step", 0)
  let assert Error(session.SqliteOpenFailed(error: sqlite.UnsupportedVersion(
    found: 0,
    supported: 1,
  ))) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 50_000),
    )
}

pub fn older_version_runs_the_chain_test() {
  let path = tampered_file("migrate_step", 0)
  let step =
    sqlite.Migration(
      from_version: 0,
      statements: "CREATE TABLE IF NOT EXISTS migration_probe(x INTEGER)",
    )
  let assert Ok(store) =
    sqlite.open_with_migrations(
      sqlite.config(path:, owner: "writer-2"),
      clock.stepping(from: 50_000, by: 1),
      [step],
    )
  // The store is usable after migrating.
  let assert Ok(stats) = storage.stats(store)
  assert stats.message_count == 0
  let assert Ok(Nil) = storage.close(store)

  // The step ran and the version advanced — reopening with an empty
  // chain now succeeds outright.
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok([version]) =
    sqlight.query(
      "SELECT storage_version FROM session",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  assert version == 1
  let assert Ok([probes]) =
    sqlight.query(
      "SELECT COUNT(*) FROM sqlite_master
       WHERE type = 'table' AND name = 'migration_probe'",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  assert probes == 1
  let assert Ok(Nil) = sqlight.close(conn)
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-3",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 90_000),
    )
  let assert Ok(Nil) = session.close(reopened)
}
