//// Exact persisted bytes govern reuse, independently of sequence and key.

import core/clock
import core/codec
import core/json
import core/register
import core/tx
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import simplifile
import sqlight
import storage/internal/register_cache
import storage/sqlite
import storage/storage

pub fn changed_persisted_bytes_are_never_hidden_test() {
  let path = "build/test_db/register-cache-external.db"
  let _ = simplifile.create_directory_all("build/test_db")
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  let assert Ok(store) =
    sqlite.open(sqlite.config(path, "cache-test"), clock.fixed(1000))
    as "the fixture owns its store"
  let first = register.value(json.String("first"))
  let assert Ok(_) =
    storage.commit(
      store,
      tx.Tx([tx.SetRegister(register.FactCustom, "key", first)], []),
    )
    as "the initial value is durable"
  let assert Ok(Some(cell)) =
    storage.get_register(store, register.FactCustom, "key")
    as "the first read warms reuse"
  assert cell.value == first
  let assert Ok(conn) = sqlight.open(path) as "an external editor opens"

  // Neither key nor sequence changes when another connection replaces bytes.
  let second = register.value(json.String("second"))
  let blob =
    codec.encode_register_value(second)
    |> json.to_string
    |> bit_array.from_string
  assert sqlight.query(
      "UPDATE registers SET value=?1",
      conn,
      [sqlight.blob(blob)],
      decode.success(Nil),
    )
    == Ok([])
  let assert Ok(Some(changed)) =
    storage.get_register(store, register.FactCustom, "key")
    as "a warm read sees changed bytes at the same sequence"
  assert changed.seq == cell.seq
  assert changed.value == second
  assert storage.list_registers(store, register.FactCustom, Some("ke"))
    == Ok([#("key", changed)])

  // Equal bytes can be reused, but the current SQL sequence still wins.
  assert sqlight.exec("UPDATE registers SET seq=99", conn) == Ok(Nil)
  let assert Ok(Some(resequenced)) =
    storage.get_register(store, register.FactCustom, "key")
    as "sequence-only changes are visible"
  assert resequenced.seq == 99
  assert resequenced.value == second

  // Warm data cannot mask invalid JSON, invalid UTF-8 or a malformed row type.
  list.each(
    [
      "UPDATE registers SET value=x'7b'",
      "UPDATE registers SET value=x'ff'",
      "UPDATE registers SET value=42",
    ],
    fn(statement) {
      assert sqlight.exec(statement, conn) == Ok(Nil)
      let assert Error(_) =
        storage.get_register(store, register.FactCustom, "key")
        as "a point read refuses current corruption"
      let assert Error(_) =
        storage.list_registers(store, register.FactCustom, None)
        as "a list read refuses current corruption"
    },
  )
  assert sqlight.exec("DELETE FROM registers", conn) == Ok(Nil)
  assert storage.get_register(store, register.FactCustom, "key") == Ok(None)
  assert storage.list_registers(store, register.FactCustom, None) == Ok([])
  assert sqlight.close(conn) == Ok(Nil)
  assert storage.close(store) == Ok(Nil)
}

pub fn inventory_overflow_and_oversized_values_remain_total_test() {
  let cache =
    int.range(0, 130, register_cache.new(), fn(cache, n) {
      let value = register.value(json.String(int.to_string(n)))
      let blob =
        codec.encode_register_value(value)
        |> json.to_string
        |> bit_array.from_string
      let assert Ok(#(decoded, cache)) = register_cache.read(cache, blob)
        as "capacity rollover preserves every decoded value"
      assert decoded == value
      cache
    })
  let value = register.value(json.String(string.repeat("x", 300_000)))
  let blob =
    codec.encode_register_value(value)
    |> json.to_string
    |> bit_array.from_string
  let assert Ok(#(decoded, unchanged)) = register_cache.read(cache, blob)
    as "oversized input decodes without admission"
  assert decoded == value
  assert unchanged == cache
  let assert Error(_) = register_cache.read(cache, <<255>>)
    as "invalid UTF-8 never enters the inventory"
}

// Inspect only the synthetic actor's private slot, never a live daemon.
fn cache_state(store: storage.Storage(process.Subject(message))) {
  let assert Ok(pid) = process.subject_owner(store.handle)
    as "the fixture actor owns the handle"
  let assert Ok(cache) =
    decode.run(system.get_state(pid), decode.at([7, 2], decode.int))
    as "the private actor state has its cache slot"
  cache
}

pub fn failed_close_releases_warmed_inventory_test() {
  let path = "build/test_db/register-cache-close.db"
  let _ = simplifile.create_directory_all("build/test_db")
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path, "cache-close") |> sqlite.busy_timeout(10),
      clock.fixed(1000),
    )
    as "the fixture owns its store"
  let value = register.value(json.Array(list.repeat(json.Null, 8192)))
  let assert Ok(_) =
    storage.commit(
      store,
      tx.Tx([tx.SetRegister(register.FactCustom, "key", value)], []),
    )
    as "the fixture persists its payload"
  let assert Ok(Some(_)) =
    storage.get_register(store, register.FactCustom, "key")
    as "the read warms the inventory"
  assert cache_state(store) > 0
  let assert Ok(blocker) = sqlight.open(path) as "the blocker opens"
  assert sqlight.exec("BEGIN IMMEDIATE", blocker) == Ok(Nil)
  let assert Error(_) = storage.close(store)
    as "lease release fails under the write lock"
  assert cache_state(store) == 0
  assert sqlight.exec("ROLLBACK", blocker) == Ok(Nil)
  assert sqlight.close(blocker) == Ok(Nil)
  let assert Error(_) = storage.close(store)
    as "the first close failure remains remembered"
}

pub fn entry_and_byte_bounds_evict_old_inventory_test() {
  let cache =
    int.range(0, 64, register_cache.new(), fn(cache, n) {
      let blob = bit_array.from_string(int.to_string(n))
      let assert Ok(#(_, cache)) = register_cache.read(cache, blob)
        as "each small distinct value enters the inventory"
      cache
    })
  let last = bit_array.from_string("999")
  let assert Ok(#(_, after_entry_limit)) = register_cache.read(cache, last)
    as "the sixty-fifth value starts a new inventory"
  let assert Ok(#(_, only_last)) =
    register_cache.read(register_cache.new(), last)
    as "the expected inventory contains only the last value"
  assert after_entry_limit == only_last
  let assert Ok(#(_, hit)) = register_cache.read(after_entry_limit, last)
    as "a hit leaves inventory unchanged"
  assert hit == after_entry_limit

  // Individually admissible blobs exceed the byte budget together.
  let a =
    bit_array.from_string(
      json.to_string(json.String(string.repeat("a", 140_000))),
    )
  let b =
    bit_array.from_string(
      json.to_string(json.String(string.repeat("b", 140_000))),
    )
  let assert Ok(#(_, first)) = register_cache.read(register_cache.new(), a)
    as "the first large value fits"
  let assert Ok(#(_, after_byte_limit)) = register_cache.read(first, b)
    as "the second large value displaces the old inventory"
  let assert Ok(#(_, only_b)) = register_cache.read(register_cache.new(), b)
    as "the expected inventory contains only the second value"
  assert after_byte_limit == only_b
}

pub fn warmed_reader_observes_replacement_writer_test() {
  let path = "build/test_db/register-cache-fence.db"
  let _ = simplifile.create_directory_all("build/test_db")
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  let assert Ok(old) =
    sqlite.open(
      sqlite.config(path, "old") |> sqlite.lease_ttl(10),
      clock.fixed(1000),
    )
    as "the first writer owns the initial lease"
  let first = register.value(json.String("first"))
  let second = register.value(json.String("second"))
  let write = fn(value) {
    tx.Tx([tx.SetRegister(register.FactCustom, "key", value)], [])
  }
  let assert Ok(_) = storage.commit(old, write(first))
    as "the first value commits"
  let assert Ok(Some(cell)) =
    storage.get_register(old, register.FactCustom, "key")
    as "the old reader warms the first payload"
  let rejected =
    tx.Tx([tx.SetRegister(register.FactCustom, "key", second)], [
      tx.Expect(register.FactCustom, "key", Some(999)),
    ])
  let assert Error(tx.StaleExpectation(..)) = storage.commit(old, rejected)
    as "a failed CAS cannot insert tentative cache data"
  assert storage.get_register(old, register.FactCustom, "key") == Ok(Some(cell))
  let assert Ok(replacement) =
    sqlite.open(
      sqlite.config(path, "new") |> sqlite.lease_ttl(10),
      clock.fixed(2000),
    )
    as "the later writer steals the expired lease"
  let assert Ok(_) = storage.commit(replacement, write(second))
    as "the replacement value commits"
  let assert Ok(Some(current)) =
    storage.get_register(old, register.FactCustom, "key")
    as "the old reader still observes current durable bytes"
  assert current.value == second
  assert current.seq > cell.seq
  let assert Error(tx.LeaseLost(..)) = storage.commit(old, write(first))
    as "reuse cannot bypass writer fencing"
  assert storage.close(old) == Ok(Nil)
  assert storage.close(replacement) == Ok(Nil)
}
