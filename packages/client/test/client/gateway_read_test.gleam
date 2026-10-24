//// Empty entry cuts have no branches to attribute. The storage seam counts
//// actual per-strand leaf reads, while real durable terminal results prove
//// the shortcut changes neither operation observation nor once-only delivery.

import client/gateway
import client/gateway_read_fixture as fixture
import client/protocol
import core/clock
import core/entry
import core/ids
import core/message
import core/register
import core/tx
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import machine/codec
import machine/operation
import machine/strand
import runtime/api
import session/session
import storage/storage

// The observed store boundary, rather than the implementation's helper count.
type Read {
  Point(register.RegisterNs)
  Namespace(register.RegisterNs)
}

fn counted(store: session.Session, reads: process.Subject(Read)) {
  let backend = store.store
  session.Session(
    ..store,
    store: storage.Storage(
      ..backend,
      get_register: fn(handle, namespace, key) {
        process.send(reads, Point(namespace))
        backend.get_register(handle, namespace, key)
      },
      list_registers: fn(handle, namespace, prefix) {
        process.send(reads, Namespace(namespace))
        backend.list_registers(handle, namespace, prefix)
      },
    ),
  )
}

fn collect(reads: process.Subject(Read)) -> List(Read) {
  case process.receive(reads, 0) {
    Ok(read) -> [read, ..collect(reads)]
    Error(Nil) -> []
  }
}

/// Idle pulls omit only the leaves; operation reads keep their original order.
pub fn idle_pulls_skip_only_unneeded_strand_leaf_reads_test() {
  list.each([1, 8, 64, 128], fn(count) {
    let assert Ok(store) = session.open_memory(clock.fixed(1000))
      as "the fixture store opens"
    let prepared = fixture.open(store, count)
    let reads = process.new_subject()
    let options =
      gateway.Options(
        ..prepared.options,
        runtime: api.Runtime(
          ..prepared.options.runtime,
          session: counted(store, reads),
        ),
      )
    let #(hub, pid) = fixture.start(options)
    let _prime_reads = collect(reads)
    fixture.pull(hub)
    let observed = collect(reads)
    assert list.count(observed, fn(read) { read == Point(register.StrandLeaf) })
      == 0
      as "an empty entry cut never reads a strand leaf"
    assert list.count(observed, fn(read) { read == Point(register.StrandState) })
      == count
      as "operation ownership keeps the original per-strand read"
    assert list.count(observed, fn(read) {
        read == Point(register.StrandLastResult)
      })
      == count
      as "fast terminal outcomes keep the original per-strand read"
    process.unlink(pid)
    process.kill(pid)
    prepared.retire()
    let assert Ok(Nil) = session.close(store) as "the fixture store closes"
  })
}

fn terminal(store: session.Session, key: String, seed: Int) -> ids.OpId {
  let op = ids.mint_op(ids.generator(clock.fixed(1000), seed)).0
  let assert Ok(_) =
    storage.commit(
      store.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.StrandState,
            key,
            register.value(
              codec.encode_strand_state(
                strand.StrandState(
                  current_operation: None,
                  pending_next_run: [],
                ),
              ),
            ),
          ),
          tx.SetRegister(
            register.StrandLastResult,
            key,
            register.value(
              codec.encode_last_result(operation.CompactionLastResult(
                op,
                None,
                operation.StructuralCompleted,
              )),
            ),
          ),
        ],
        [],
      ),
    )
    as "a fast operation clears ownership and publishes its outcome atomically"
  op
}

fn subscribe(hub: gateway.Gateway) -> process.Subject(String) {
  let inbox = process.new_subject()
  let assert Ok(connection) =
    gateway.attach(hub, fn(frame) { process.send(inbox, frame) })
    as "the host fixture attaches"
  gateway.handle_text(
    hub,
    connection,
    protocol.encode_command(protocol.CommandEnvelope(
      1,
      protocol.Subscribe("gateway-read-fixture", None),
    )),
  )
  let assert Ok(_) = process.receive(inbox, 5000)
    as "the subscription snapshot arrives"
  inbox
}

fn next(inbox: process.Subject(String)) -> protocol.EventEnvelope {
  let assert Ok(frame) = process.receive(inbox, 5000)
    as "the durable event arrives"
  let assert Ok(envelope) = protocol.decode_event(frame)
    as "the gateway event decodes"
  envelope
}

/// A fast open and settle between hints still emits the terminal result once.
/// A later commit belongs to a later pull, even when no entry row advances.
pub fn terminal_results_advance_only_the_events_seen_by_this_pull_test() {
  let assert Ok(store) = session.open_memory(clock.fixed(1000))
    as "the fixture store opens"
  let prepared = fixture.open(store, 8)
  let #(hub, pid) = fixture.start(prepared.options)
  let inbox = subscribe(hub)
  let op = terminal(store, "strand-1", 41)
  fixture.pull(hub)
  let done = next(inbox)
  let settled = next(inbox)
  assert done.event
    == protocol.OpTransitionEvent(ids.op_id_to_string(op), "strand-1", "done")
  assert settled.event
    == protocol.StrandResultEvent(
      "strand-1",
      ids.op_id_to_string(op),
      "done",
      None,
    )
  let assert Some(done_seq) = done.seq as "the done transition is durable"
  let assert Some(settled_seq) = settled.seq as "the result is durable"
  assert done_seq < settled_seq
    as "terminal events retain durable sequence order"
  fixture.pull(hub)
  assert process.receive(inbox, 0) == Error(Nil)
    as "another hint replays no completed command or result"
  let successor = terminal(store, "strand-8", 42)
  fixture.pull(hub)
  let _done = next(inbox)
  assert next(inbox).event
    == protocol.StrandResultEvent(
      "strand-8",
      ids.op_id_to_string(successor),
      "done",
      None,
    )
    as "a result after the prior cut remains visible on the next hint"
  process.unlink(pid)
  process.kill(pid)
  prepared.retire()
  let assert Ok(Nil) = session.close(store) as "the fixture store closes"
}

/// A nonempty entry cut retains the original leaf reads and branch attribution;
/// only an actually empty cut can take the shortcut.
pub fn nonempty_entry_cut_still_reads_leaves_and_attributes_the_owner_test() {
  let assert Ok(store) = session.open_memory(clock.fixed(1000))
    as "the fixture store opens"
  let prepared = fixture.open(store, 8)
  let reads = process.new_subject()
  let id = ids.mint_entry(ids.generator(clock.fixed(1000), 45)).0
  let row =
    entry.MessageEntry(
      id:,
      parent: None,
      seq: 0,
      ts: 0,
      message: message.UserMessage(
        [message.UserText("new entry", None)],
        0,
        None,
      ),
      terminate: False,
    )
  let assert Ok(_) =
    storage.commit(
      store.store,
      tx.Tx(
        [
          tx.InsertEntry(row),
          tx.SetRegister(
            register.StrandLeaf,
            "strand-2",
            register.leaf_value(Some(id)),
          ),
        ],
        [],
      ),
    )
    as "the owned entry commits"
  let history = gateway.entry_history_by_heads(counted(store, reads))
  assert history.attribution
    == [#(ids.entry_id_to_string(id), "owned:strand-2")]
    as "the original leaf claim determines the entry owner"
  assert list.count(collect(reads), fn(read) {
      read == Point(register.StrandLeaf)
    })
    == 8
    as "a nonempty cut still performs the original strand-order branch reads"
  prepared.retire()
  let assert Ok(Nil) = session.close(store) as "the fixture store closes"
}
