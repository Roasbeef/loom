//// Matched writer-path scans, point reads and bulk reads by ownership width.
//// Measures the read primitive and decoding, not complete admission.
//// Run from packages/runtime: gleam run -m pending_read_bench.
//// SQLite uses an in-memory database; durations are wall milliseconds.

import core/clock
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation.{PendingCustom}
import runtime/writer
import session/session.{type Session}
import storage/storage
import weft/poll
import weft/registry as address

type Backend {
  Memory
  Sqlite
}

/// Compare writer-path namespace scans, point reads and bounded bulk reads.
///
/// ## Examples
///
/// ```gleam
/// // Run with `gleam run -m pending_read_bench`.
/// ```
pub fn main() {
  run_backend("memory", Memory)
  run_backend("sqlite-memory", Sqlite)
}

/// Run the same setup, reads, assertions and teardown with one iteration.
/// Check the actual setup, read paths and teardown with one small case per backend.
///
/// ## Examples
///
/// ```gleam
/// // pending_read_bench.smoke()
/// ```
pub fn smoke() {
  run_case("memory-smoke", Memory, 1, 129, 1, 1)
  run_case("sqlite-smoke", Sqlite, 1, 129, 1, 1)
}

fn run_backend(label: String, backend: Backend) {
  list.each([0, 100, 1000], fn(backlog) {
    list.each([0, 1, 32, 128], fn(width) {
      run_case(label, backend, backlog, width, 7, 50)
    })
  })
}

fn run_case(
  label: String,
  backend: Backend,
  backlog: Int,
  width: Int,
  samples: Int,
  reads: Int,
) {
  let assert Ok(sess) = case backend {
    Sqlite ->
      session.open_sqlite(
        path: ":memory:",
        owner: "bench",
        lease_ttl_ms: 300_000,
        clock: clock.fixed(at: 1000),
      )
    Memory -> session.open_memory(clock.fixed(at: 1000))
  }
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  let assert Ok(started) =
    writer.start(
      writer.Options(
        session: sess,
        after_commit: fn(_) { Nil },
        subscribers: [],
      ),
      name,
    )
  let keys = names("own-", width)
  seed(sess, list.append(keys, names("other-", backlog)))
  let expected = list.map(keys, fn(key) { #(key, payload()) }) |> dict.from_list
  list.each(["baseline", "point", "bulk"], fn(mode) {
    let now = poll.monotonic().now
    let samples =
      list.map(list.repeat(Nil, samples), fn(_) {
        let start = now()
        list.each(list.repeat(Nil, reads), fn(_) {
          let values = case mode {
            "baseline" -> {
              let assert Ok(cells) =
                writer.list_registers(name, register.PendingEntry, None)
              let decoded =
                list.map(cells, fn(pair) {
                  let #(key, storage.Register(value:, ..)) = pair
                  let assert Ok(payload) =
                    codec.decode_pending_entry(value.payload)
                  #(key, payload)
                })
                |> dict.from_list
              list.map(keys, fn(key) {
                let assert Ok(value) = dict.get(decoded, key)
                #(key, value)
              })
              |> dict.from_list
            }
            "point" ->
              list.map(keys, fn(key) {
                let assert Ok(Some(storage.Register(value:, ..))) =
                  writer.get_register(name, register.PendingEntry, key)
                let assert Ok(payload) =
                  codec.decode_pending_entry(value.payload)
                #(key, payload)
              })
              |> dict.from_list
            _ -> {
              let assert Ok(cells) =
                writer.get_registers_batched(name, register.PendingEntry, keys)
              dict.to_list(cells)
              |> list.map(fn(pair) {
                let #(key, storage.Register(value:, ..)) = pair
                let assert Ok(payload) =
                  codec.decode_pending_entry(value.payload)
                #(key, payload)
              })
              |> dict.from_list
            }
          }
          assert values == expected
        })
        now() - start
      })
    io.println(
      label
      <> " backlog="
      <> int.to_string(backlog)
      <> " own="
      <> int.to_string(width)
      <> " mode="
      <> mode
      <> " loads="
      <> int.to_string(reads)
      <> " elapsed_ms=["
      <> string.join(list.map(samples, int.to_string), ",")
      <> "]",
    )
  })
  process.unlink(started.pid)
  process.kill(started.pid)
  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 10, attempt: fn() {
      case process.is_alive(started.pid) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    as "the writer must stop before its storage closes"
  assert address.stop(registry) == Ok(Nil)
  assert storage.close(sess.store) == Ok(Nil)
}

fn names(prefix: String, count: Int) -> List(String) {
  int.range(from: 0, to: count, with: [], run: fn(acc, i) {
    [prefix <> int.to_string(i), ..acc]
  })
}

fn payload() {
  PendingCustom(
    custom_type: "bench",
    data: Some(json.String(string.repeat("x", 1024))),
  )
}

fn seed(sess: Session, keys: List(String)) {
  let writes =
    list.map(keys, fn(key) {
      SetRegister(
        ns: register.PendingEntry,
        key:,
        value: register.value(codec.encode_pending_entry(payload())),
      )
    })
  case writes {
    [] -> Nil
    _ -> {
      let assert Ok(_) = storage.commit(sess.store, Tx(writes:, expected: []))
      Nil
    }
  }
}
