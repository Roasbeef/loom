//// A bounded SQLite kind-filter benchmark over a fixed one-MiB transcript.
//// The scan asks for its oldest compaction beneath 128 newer messages, so
//// unrelated payload decoding is visible independently of command execution.

import core/clock
import core/entry.{type Entry}
import core/json
import core/tx.{InsertEntry, Tx}
import gleam/erlang/atom
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage
import support/fixtures

/// Measures 31 exact kind-filtered scans, reporting the first separately.
///
/// ## Examples
///
/// `cd packages/storage && gleam run -m bench_branch`.
pub fn main() -> Nil {
  let directory = "build/bench_branch_" <> int.to_string(microseconds())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the benchmark owns a fresh database directory"
  let path = directory <> "/branch.db"
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "bench"), clock.fixed(at: 10_000))
    as "the benchmark store opens"

  // Persist the fixed transcript once, outside every timed scan.
  let #(checkpoint, ctx) =
    fixtures.compaction_entry(fixtures.new_ctx(), None, "summary")
  let text = string.repeat("history ", 1024)
  let #(chain, _ctx) =
    int.range(from: 0, to: 128, with: #([checkpoint], ctx), run: fn(acc, _) {
      let #(built, ctx) = acc
      let assert [parent, ..] = built as "the branch has its checkpoint"
      let #(item, ctx) = fixtures.message_entry(ctx, Some(parent.id), text)
      #([item, ..built], ctx)
    })
  let assert [tip, ..] = chain as "the transcript has a tip"
  assert list.length(chain) == 129
  let assert Ok(_) =
    storage.commit(
      store,
      Tx(writes: list.map(list.reverse(chain), InsertEntry), expected: []),
    )
    as "the transcript is durable before measurement"

  // The compaction stop is inclusive even though SQL excludes newer messages.
  let query =
    storage.branch_scan(tip.id)
    |> storage.branch_stop_at_kind(storage.Compaction)
    |> storage.branch_kind(storage.Compaction)
    |> storage.branch_limit(1)
  let samples =
    list.repeat(Nil, 31)
    |> list.map(fn(_) {
      let started = microseconds()
      let assert Ok(found) = storage.scan_branch(store, query)
        as "the filtered scan succeeds"
      let elapsed = microseconds() - started
      assert list.map(found, fn(item: Entry) { item.id }) == [checkpoint.id]
      elapsed
    })

  // Retain every observation and keep the first out of the warm percentiles.
  let assert [cold, ..warm] = samples as "all observations exist"
  let sorted = list.sort(warm, int.compare)
  let assert [p50, ..] = list.drop(sorted, 14) as "thirty warm samples exist"
  let assert [p95, ..] = list.drop(sorted, 28) as "thirty warm samples exist"
  io.println(
    json.to_string(
      json.Object([
        #("messages", json.Int(128)),
        #("message_bytes", json.Int(string.byte_size(text))),
        #("cold_us", json.Int(cold)),
        #("p50_us", json.Int(p50)),
        #("p95_us", json.Int(p95)),
        #("warm_samples_us", json.Array(list.map(warm, json.Int))),
      ]),
    ),
  )

  // Close the actor before removing SQLite's private files.
  let assert Ok(Nil) = storage.close(store) as "the benchmark store closes"
  let assert Ok(Nil) = simplifile.delete(directory)
    as "the benchmark releases its private database"
  Nil
}

// OTP's monotonic clock is required for elapsed microseconds; no wall-clock
// conversion or injected clock belongs in this external measurement.
fn microseconds() -> Int {
  monotonic_time(atom.create("microsecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int
