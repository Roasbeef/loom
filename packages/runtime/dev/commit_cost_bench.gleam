//// Matched concurrent commit cost experiment for the two storage backends.
//// Each caller reads its own leaf, then commits a message and guarded leaf
//// update. Timing includes the mailbox wait, serialization and execution;
//// it does not separate SQLite sync, CPU, or writer scheduling.

import core/clock
import core/entry.{MessageEntry}
import core/ids
import core/message.{UserMessage, UserText}
import core/register
import core/tx.{Expect, InsertEntry, SetRegister, Tx}
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import simplifile
import storage/memory
import storage/sqlite
import storage/storage.{type Storage}
import weft
import weft/poll

/// Runs the bounded fresh-store cases and prints individual latency samples.
///
/// ## Examples
///
/// `cd packages/runtime && gleam run -m commit_cost_bench`
pub fn main() -> Nil {
  list.each([1, 2, 3], fn(repetition) {
    list.each([1, 8, 32, 128], fn(callers) {
      run_pair(callers, repetition, 200)
    })
  })
}

/// Runs a small correctness-only workload for both storage backends.
///
/// ## Examples
///
/// `cd packages/runtime && gleam run -m commit_cost_bench_smoke`
pub fn smoke() -> Nil {
  run_pair(2, 1, 3)
}

fn run_pair(callers: Int, repetition: Int, iterations: Int) -> Nil {
  let assert Ok(memory_store) = memory.open(clock.fixed(10_000))
  run_case("memory", callers, repetition, iterations, memory_store)
  let assert Ok(Nil) = storage.close(memory_store)

  let dir = "build/commit_cost_bench_" <> int.to_string(now_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(sqlite_store) =
    sqlite.open(
      sqlite.config(dir <> "/session.db", "bench"),
      clock.fixed(10_000),
    )
  run_case("sqlite", callers, repetition, iterations, sqlite_store)
  let assert Ok(Nil) = storage.close(sqlite_store)
  let assert Ok(Nil) = simplifile.delete(dir)
  Nil
}

fn run_case(
  name: String,
  callers: Int,
  repetition: Int,
  iterations: Int,
  store: Storage(handle),
) -> Nil {
  let workers = int.range(1, callers + 1, [], fn(acc, n) { [n, ..acc] })
  let tasks =
    list.map(workers, fn(worker) {
      fn() {
        let ctx = ids.generator(clock.stepping(1000, 1), worker)
        Ok(#(worker, run_worker(store, worker, ctx, iterations, [], None)))
      }
    })
  let start = now_ms()
  let outcomes =
    weft.new(tasks)
    |> weft.limit(callers)
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.deadline(120_000)
    |> weft.start
  let completed = weft.values(outcomes)
  assert list.length(completed) == callers
  let elapsed = now_ms() - start
  assert elapsed >= 0
  let samples =
    list.flat_map(completed, fn(item) {
      let #(_, #(samples, _)) = item
      samples
    })
  list.each(completed, fn(item) {
    let #(worker, #(_, id)) = item
    let key = "worker-" <> int.to_string(worker)
    let assert Ok(Some(cell)) =
      storage.get_register(store, register.StrandLeaf, key)
    assert register.read_leaf(cell.value) == Ok(Some(id))
    let assert Ok(entries) = storage.get_entries(store, [id])
    let assert Ok(_) = dict.get(entries, id)
    let assert Ok(branch) = storage.scan_branch(store, storage.branch_scan(id))
    assert list.length(branch) == iterations
    let assert [tip, ..] = branch
    assert tip.id == id
  })
  let assert Ok(stats) = storage.stats(store)
  assert stats.message_count == callers * iterations
  assert list.all(samples, fn(sample) { sample >= 0 })
  io.println(
    "case,"
    <> name
    <> ","
    <> int.to_string(callers)
    <> ","
    <> int.to_string(repetition)
    <> ","
    <> int.to_string(list.length(samples))
    <> ","
    <> int.to_string(elapsed),
  )
  list.each(samples, fn(sample) {
    io.println(
      "latency_ms,"
      <> name
      <> ","
      <> int.to_string(callers)
      <> ","
      <> int.to_string(repetition)
      <> ","
      <> int.to_string(sample),
    )
  })
}

fn run_worker(
  store: Storage(handle),
  worker: Int,
  ctx: ids.Generator,
  left: Int,
  samples: List(Int),
  last: option.Option(ids.EntryId),
) -> #(List(Int), ids.EntryId) {
  case left {
    0 -> {
      let assert Some(id) = last
      #(samples, id)
    }
    _ -> {
      let key = "worker-" <> int.to_string(worker)
      let assert Ok(existing) =
        storage.get_register(store, register.StrandLeaf, key)
      let seq = case existing {
        None -> None
        Some(cell) -> Some(cell.seq)
      }
      let leaf = case existing {
        None -> None
        Some(cell) -> {
          let assert Ok(leaf) = register.read_leaf(cell.value)
          leaf
        }
      }
      assert leaf == last
      let #(id, ctx) = ids.mint_entry(ctx)
      let entry =
        MessageEntry(
          id:,
          parent: last,
          seq: 0,
          ts: 0,
          message: UserMessage(
            content: [
              UserText(
                text: "Representative user message for a simple turn.",
                text_signature: None,
              ),
            ],
            timestamp: 0,
            origin: None,
          ),
          terminate: False,
        )
      let started = now_ms()
      let assert Ok(_) =
        storage.commit(
          store,
          Tx(
            writes: [
              InsertEntry(entry),
              SetRegister(
                register.StrandLeaf,
                key,
                register.leaf_value(Some(entry.id)),
              ),
            ],
            expected: [Expect(register.StrandLeaf, key, seq)],
          ),
        )
      run_worker(
        store,
        worker,
        ctx,
        left - 1,
        [now_ms() - started, ..samples],
        Some(entry.id),
      )
    }
  }
}

fn now_ms() -> Int {
  poll.monotonic().now()
}
