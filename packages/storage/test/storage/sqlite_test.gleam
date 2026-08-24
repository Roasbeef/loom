//// Smoke tests for the SQLite backend: open, commit, read back, plan,
//// lease lifecycle, reopen persistence. The full cross-backend behavior
//// matrix lives in the conformance package.

import core/clock
import core/register
import core/tx.{InsertEntry, InsertUsage, SetRegister, Tx}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage
import support/fixtures

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

fn open_store(name: String, owner: String) {
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path: fresh_path(name), owner:),
      clock.stepping(from: 10_000, by: 1),
    )
  store
}

pub fn commit_and_read_back_test() {
  let store = open_store("smoke", "w1")
  let ctx = fixtures.new_ctx()
  let #(a, ctx) = fixtures.message_entry(ctx, None, "a")
  let #(b, ctx) = fixtures.message_entry(ctx, Some(a.id), "b")
  let #(row, _ctx) = fixtures.usage_row(ctx, Some(b.id), 50)
  let assert Ok(result) =
    storage.commit(
      store,
      Tx(
        writes: [
          InsertEntry(a),
          InsertEntry(b),
          InsertUsage(row),
          SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(b.id)),
          ),
        ],
        expected: [],
      ),
    )
  assert result.first_seq == 1
  assert result.seqs == [1, 2, 3, 4]

  let assert Ok(found) = storage.get_entries(store, [a.id, b.id])
  let assert Ok(stored_b) = dict.get(found, b.id)
  assert stored_b.seq == 2
  assert stored_b.parent == Some(a.id)

  let assert Ok(Some(cell)) =
    storage.get_register(store, register.StrandLeaf, "main")
  assert cell.seq == 4
  assert register.read_leaf(cell.value) == Ok(Some(b.id))

  let assert Ok(rows) = storage.scan_usage(store, storage.usage_scan())
  let assert [stored_row] = rows
  assert stored_row.seq == 3
  assert stored_row.entry_id == Some(b.id)
  assert stored_row.usage == row.usage
  assert stored_row.details == row.details

  let assert Ok(stats) = storage.stats(store)
  assert stats.message_count == 2
  assert stats.usage == row.usage

  let assert Ok(scanned) =
    storage.scan_branch(store, storage.branch_scan(from: b.id))
  assert list.map(scanned, fn(entry) { entry.id }) == [b.id, a.id]

  let assert Ok(Nil) = storage.close(store)
  // Idempotent.
  assert storage.close(store) == Ok(Nil)
}

pub fn branch_plan_drives_from_branch_entries_test() {
  let store = open_store("plan", "w1")
  let assert Ok(lines) = sqlite.scan_branch_plan(store.handle)
  let plan = string.join(lines, with: "\n")
  assert string.contains(plan, "ix_be_seq")
  assert !string.contains(plan, "TEMP B-TREE")
  let assert Ok(Nil) = storage.close(store)
}

pub fn reopen_preserves_data_test() {
  let path = fresh_path("reopen")
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path:, owner: "w1"),
      clock.stepping(from: 10_000, by: 1),
    )
  let ctx = fixtures.new_ctx()
  let #(a, _ctx) = fixtures.message_entry(ctx, None, "a")
  let assert Ok(_) =
    storage.commit(store, Tx(writes: [InsertEntry(a)], expected: []))
  let assert Ok(Nil) = storage.close(store)

  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path:, owner: "w2"),
      clock.stepping(from: 20_000, by: 1),
    )
  let assert Ok(found) = storage.get_entries(store, [a.id])
  let assert Ok(stored) = dict.get(found, a.id)
  assert stored.seq == 1
  // Seqs continue after the reopened session's high-water mark.
  let #(b, _ctx) =
    fixtures.message_entry(fixtures.new_ctx() |> advance(2), Some(a.id), "b")
  let assert Ok(result) =
    storage.commit(store, Tx(writes: [InsertEntry(b)], expected: []))
  assert result.first_seq == 2
  let assert Ok(Nil) = storage.close(store)
}

// Advances the fixture context so ids differ from ones minted earlier
// with the same seed.
fn advance(ctx: fixtures.Ctx, by: Int) -> fixtures.Ctx {
  case by <= 0 {
    True -> ctx
    False -> {
      let #(_, ctx) = fixtures.mint(ctx)
      advance(ctx, by - 1)
    }
  }
}

pub fn lease_held_refuses_second_open_test() {
  let path = fresh_path("lease_held")
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "w1"), clock.fixed(at: 10_000))
  let assert Error(sqlite.LeaseHeld(owner: "w1", expires_at_ms: _)) =
    sqlite.open(sqlite.config(path:, owner: "w2"), clock.fixed(at: 10_001))
  let assert Ok(Nil) = storage.close(store)
  // After close the lease is released and a new owner may open.
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "w2"), clock.fixed(at: 10_002))
  let assert Ok(Nil) = storage.close(store)
}
