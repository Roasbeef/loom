//// Exact register reads are forwarded through the writer in bounded batches.

import core/clock
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import runtime/writer
import session/session
import storage/storage
import weft/registry as address

pub fn batches_exact_keys_without_scanning_test() {
  let requests = process.new_subject()
  let assert Ok(original) = session.open_memory(clock.fixed(at: 1000))
    as "the session opens"
  let get_registers = original.store.get_registers
  let store =
    storage.Storage(..original.store, get_registers: fn(handle, ns, keys) {
      process.send(requests, #(ns, keys))
      get_registers(handle, ns, keys)
    })
  let sess = session.Session(..original, store:)
  let assert Ok(namespace) = address.start() as "the registry starts"
  let name = address.new_address(namespace)
  let assert Ok(started) =
    writer.start(
      writer.Options(
        session: sess,
        after_commit: fn(_) { Nil },
        subscribers: [],
      ),
      name,
    )
    as "the writer starts"
  let keys =
    int.range(from: 0, to: 260, with: [], run: fn(acc, n) {
      ["key-" <> int.to_string(n), ..acc]
    })
    |> list.reverse
  let writes =
    list.map(keys, fn(key) {
      SetRegister(register.PendingEntry, key, register.value(json.String(key)))
    })
  let assert Ok(_) = writer.commit(name, Tx(writes: writes, expected: []))
    as "the cells commit"
  let assert Ok(cells) =
    writer.get_registers_batched(
      name,
      register.PendingEntry,
      list.append(keys, ["key-0", "missing"]),
    )
    as "the batch reads succeed"
  assert dict.size(cells) == 260
  let assert Ok(storage.Register(seq:, ..)) = dict.get(cells, "key-0")
    as "the stored sequence is returned"
  assert seq > 0
  assert !dict.has_key(cells, "missing")
  let assert Ok(#(register.PendingEntry, first)) =
    process.receive(requests, within: 1000)
    as "the requested batch arrives"
  let assert Ok(#(register.PendingEntry, second)) =
    process.receive(requests, within: 1000)
    as "the requested batch arrives"
  let assert Ok(#(register.PendingEntry, third)) =
    process.receive(requests, within: 1000)
    as "the requested batch arrives"
  assert list.length(first) == 128
  assert list.length(second) == 128
  assert list.length(third) == 5
  assert list.flatten([first, second, third]) == list.append(keys, ["missing"])
  assert writer.get_registers_batched(name, register.PendingEntry, [])
    == Ok(dict.new())
  assert process.receive(requests, within: 0) == Error(Nil)
  assert writer.get_registers(name, register.PendingEntry, keys)
    == Error(writer.Underlying(storage.RegisterReadLimitExceeded(128)))
  assert process.receive(requests, within: 0) == Error(Nil)
  assert session.close(original) == Ok(Nil)
  assert writer.get_registers(name, register.PendingEntry, [])
    == Error(writer.Underlying(storage.HandleClosed))
  let assert Ok(#(register.PendingEntry, [])) =
    process.receive(requests, within: 1000)
    as "the requested batch arrives"
  process.send_exit(started.pid)
  assert address.stop(namespace) == Ok(Nil)
}
