//// Matched actor-path register read microbenchmark. Run from packages/runtime:
//// gleam run -m register_read_bench
//// SQLite uses :memory: to isolate SQL and actor costs from filesystem latency.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import runtime/api
import runtime/writer
import session/session.{type Session}
import storage/storage
import weft/poll
import weft/registry as address

type Backend {
  Memory
  SqliteMemory
}

/// Runs the matched register-read benchmark.
///
/// ## Examples
///
/// ```gleam
/// // Run with `gleam run -m register_read_bench`.
/// ```
pub fn main() {
  run_backend(Memory)
  run_backend(SqliteMemory)
}

/// Runs the memory-backed workload and its actual teardown as a bounded smoke.
///
/// ## Examples
///
/// ```gleam
/// // register_read_bench.smoke()
/// ```
pub fn smoke() {
  run_backend(Memory)
}

fn run_backend(backend: Backend) {
  let label = case backend {
    Memory -> "memory"
    SqliteMemory -> "sqlite-memory"
  }
  let assert Ok(sess) = case backend {
    SqliteMemory ->
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
  list.each([64, 4096, 300_000], fn(size) {
    let seqs = seed(sess, size)
    verify_custom(sess, name, size, seqs)
    let iterations = case size {
      300_000 -> 65
      _ -> 500
    }
    list.each([1, 65], fn(width) {
      list.each(["direct", "writer"], fn(path) {
        let now = poll.monotonic().now
        let samples =
          list.map(numbers(1, 7), fn(_) {
            let start = now()
            list.each(numbers(1, iterations), fn(i) {
              let key = int.to_string(i % width)
              list.each(numbers(1, 5), fn(_) {
                case path {
                  "direct" -> {
                    let assert Ok(Some(_)) =
                      storage.get_register(sess.store, register.FactCustom, key)
                    Nil
                  }
                  _ -> {
                    let assert Ok(Some(_)) =
                      writer.get_register(name, register.FactCustom, key)
                    Nil
                  }
                }
              })
            })
            now() - start
          })
        io.println(
          label
          <> " size="
          <> int.to_string(size)
          <> " width="
          <> int.to_string(width)
          <> " path="
          <> path
          <> " reads/sample="
          <> int.to_string(iterations * 5)
          <> " elapsed_ms="
          <> "["
          <> string.join(list.map(samples, int.to_string), ", ")
          <> "]",
        )
      })
    })
  })
  control_bench(sess, name, label)
  // Stop and observe the writer before retiring the registry or its store.
  // Otherwise an in-flight lease renewal can reach a closed backend.
  let monitor = process.monitor(started.pid)
  process.unlink(started.pid)
  process.kill(started.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, within: 5000)
  let assert Ok(Nil) = address.stop(registry)
  let assert Ok(Nil) = storage.close(sess.store)
  Nil
}

fn seed(sess: Session, size: Int) {
  let payload = string.repeat("x", size)
  let writes =
    list.map(numbers(0, 64), fn(i) {
      SetRegister(
        ns: register.FactCustom,
        key: int.to_string(i),
        value: register.value(json.String(payload <> int.to_string(i))),
      )
    })
  let assert Ok(committed) =
    storage.commit(sess.store, Tx(writes:, expected: []))
  committed.seqs
}

fn numbers(from: Int, to: Int) -> List(Int) {
  int.range(from:, to: to + 1, with: [], run: fn(xs, i) { [i, ..xs] })
  |> list.reverse
}

// Validate both routes against every committed key and its assigned sequence.
// This intentionally warms the backend before either timed path.
fn verify_custom(
  sess: Session,
  name: address.Address(writer.Message),
  size: Int,
  seqs: List(Int),
) {
  assert list.length(seqs) == 65
  let payload = string.repeat("x", size)
  list.each(list.zip(numbers(0, 64), seqs), fn(pair) {
    let #(i, seq) = pair
    let key = int.to_string(i)
    let expected =
      storage.Register(value: register.value(json.String(payload <> key)), seq:)
    let assert Ok(Some(direct)) =
      storage.get_register(sess.store, register.FactCustom, key)
    let assert Ok(Some(via_writer)) =
      writer.get_register(name, register.FactCustom, key)
    assert direct == expected
    assert via_writer == expected
  })
}

fn control_bench(
  sess: Session,
  name: address.Address(writer.Message),
  label: String,
) {
  let #(op_id, _) = ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 1))
  let op_key = ids.op_id_to_string(op_id)
  let config =
    strand.StrandConfiguration(
      model: strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: ["read", "write", "slow"],
    )
  let op =
    operation.Operation(
      id: op_id,
      strand: "main",
      source_leaf: None,
      started_at: 1000,
      intent: operation.RunIntent(prompt_entries: []),
    )
  let state =
    operation.RunState(
      control: operation.Running,
      settings: api.default_options(config).settings,
      phase: operation.Starting,
      inbox: operation.Inbox(steer: [], follow_up: [], writes: []),
      latest_assistant: None,
    )
  let values = [
    #(
      register.StrandState,
      "main",
      register.value(
        codec.encode_strand_state(
          strand.StrandState(
            current_operation: Some(op_id),
            pending_next_run: [],
          ),
        ),
      ),
    ),
    #(register.OpMeta, op_key, register.value(codec.encode_operation(op))),
    #(register.OpState, op_key, register.value(codec.encode_state(state))),
    #(
      register.StrandConfig,
      "main",
      register.value(codec.encode_configuration(config)),
    ),
    #(register.StrandLeaf, "main", register.leaf_value(None)),
  ]
  let writes =
    list.map(values, fn(item) {
      let #(ns, key, value) = item
      SetRegister(ns:, key:, value:)
    })
  let assert Ok(committed) =
    storage.commit(sess.store, Tx(writes:, expected: []))
  assert list.length(committed.seqs) == 5
  list.each(list.zip(values, committed.seqs), fn(item) {
    let #(#(ns, key, value), seq) = item
    let expected = storage.Register(value:, seq:)
    assert read_cell(sess, name, "direct", ns, key) == expected
    assert read_cell(sess, name, "writer", ns, key) == expected
  })
  list.each(numbers(1, 7), fn(sample) {
    let paths = case sample % 2 {
      0 -> ["writer", "direct"]
      _ -> ["direct", "writer"]
    }
    list.each(paths, fn(path) {
      let now = poll.monotonic().now
      let start = now()
      list.each(numbers(1, 500), fn(_) {
        control_load(sess, name, path, op_key)
      })
      io.println(
        label
        <> " control path="
        <> path
        <> " sample="
        <> int.to_string(sample)
        <> " loads=500 elapsed_ms="
        <> int.to_string(now() - start),
      )
    })
  })
}

fn read_cell(
  sess: Session,
  name: address.Address(writer.Message),
  path: String,
  ns: register.RegisterNs,
  key: String,
) -> storage.Register {
  case path {
    "direct" -> {
      let assert Ok(Some(cell)) = storage.get_register(sess.store, ns, key)
      cell
    }
    _ -> {
      let assert Ok(Some(cell)) = writer.get_register(name, ns, key)
      cell
    }
  }
}

fn control_load(
  sess: Session,
  name: address.Address(writer.Message),
  path: String,
  op_key: String,
) {
  let strand_cell = read_cell(sess, name, path, register.StrandState, "main")
  let assert Ok(_) = codec.decode_strand_state(strand_cell.value.payload)
  let meta = read_cell(sess, name, path, register.OpMeta, op_key)
  let assert Ok(_) = codec.decode_operation(meta.value.payload)
  let state = read_cell(sess, name, path, register.OpState, op_key)
  let assert Ok(_) = codec.decode_state(state.value.payload)
  let config = read_cell(sess, name, path, register.StrandConfig, "main")
  let assert Ok(_) = codec.decode_configuration(config.value.payload)
  let leaf = read_cell(sess, name, path, register.StrandLeaf, "main")
  let assert Ok(_) = register.read_leaf(leaf.value)
  Nil
}
