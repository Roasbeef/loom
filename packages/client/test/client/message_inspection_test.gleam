//// Caller-owned messaging views over real runtime queues and receipt stores.
//// The capture hook deliberately consumes between discovery and copying, so
//// tests exercise the ownership race without timing a sleeping driver.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/internal/message_inspection
import client/peer_mail
import client/peers
import codemode/identity
import codemode/satellite
import core/clock
import core/entry
import core/ids
import core/json.{type JsonValue}
import core/message
import core/msgpack
import core/register
import core/tx
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/writer
import session/session
import storage/snapshot
import weft/actor

fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(1_756_000_000_000), seed))
  id
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], 1, None)
}

fn runtime(seed: Int) -> api.Runtime {
  let started = process.new_subject()
  let assert Ok(counter) =
    actor.new(seed)
    |> actor.on_message(fn(value, reply: Subject(Int)) {
      process.send(reply, value)
      actor.continue(value + 1)
    })
    |> actor.start
    as "the injected entropy counter starts"
  let assert Ok(tree) = session.open_memory(clock.fixed(1_756_000_000_000))
    as "the real memory backend opens"
  let configuration =
    strand.StrandConfiguration(
      strand.ModelIdentity("acme", "loom-1"),
      strand.ThinkingOff,
      [],
    )
  let assert Ok(runtime) =
    api.open(
      tree,
      effects.Effects(
        clock: clock.fixed(1_756_000_000_000),
        entropy: fn() { process.call(counter.data, 1000, fn(reply) { reply }) },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            let events = process.new_subject()
            process.send(started, Nil)
            stream.immediate(events, fn() { Nil })
          },
        ),
        tools: effects.ToolSurface(
          recover: fn(_run, _complete) { effects.UnmanagedLocal },
          clear: fn(_) { effects.ClearanceRefused("no tools") },
          run: fn(_) { effects.ToolFailed("no tools") },
          replay_still_safe: fn(_) { False },
          execution_mode: fn(_) { effects.ConcurrentExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    as "the parked runtime opens"
  let assert Ok(_) = api.prompt(runtime, [user("stay busy")])
    as "the provider owns an open run"
  let assert Ok(Nil) = process.receive(started, 5000)
    as "the first request is in flight before sends are admitted"
  runtime
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "inspection is a JSON object"
  let assert Ok(value) = list.key_find(fields, key)
    as "the contract carries the field"
  value
}

fn items(value: JsonValue) -> List(JsonValue) {
  let assert json.Array(rows) = field(value, "items")
    as "the page carries input rows"
  rows
}

fn peer(runtime: api.Runtime, command: peer_mail.Command) -> JsonValue {
  let assert Ok(value) = peer_mail.handle(runtime, clock.fixed(0), command)
    as "the production endpoint answers"
  value
}

pub fn every_pending_input_is_discoverable_across_twelve_item_pages_test() {
  let runtime = runtime(901)
  let ids =
    list.map(numbers(25), fn(number) {
      let assert Ok(id) =
        api.steer(runtime, user("body-" <> int.to_string(number)))
        as "the existing queue accepts a steer"
      ids.entry_id_to_string(id)
    })
  let first = peer(runtime, peer_mail.Inbox("main", "", 12))
  assert list.length(items(first)) == 12
  assert field(first, "total") == json.Int(25)
  let assert json.String(cursor) = field(first, "next")
    as "a partial page carries its cursor"
  let second = peer(runtime, peer_mail.Inbox("main", cursor, 12))
  let assert json.String(cursor) = field(second, "next")
    as "the second page also remains partial"
  let third = peer(runtime, peer_mail.Inbox("main", cursor, 12))
  assert field(third, "next") == json.Null
  let read =
    list.flatten([items(first), items(second), items(third)])
    |> list.map(fn(row) { field(row, "id") })
  assert list.length(read) == 25
  assert list.all(ids, fn(id) { list.contains(read, json.String(id)) })

  // Inspection has not cancelled or consumed any pending input.
  let again = peer(runtime, peer_mail.Inbox("main", "", 12))
  assert field(again, "total") == json.Int(25)
}

pub fn own_pending_and_materialized_inputs_are_readable_but_foreign_ids_are_not_test() {
  let runtime = runtime(902)
  let assert Ok(Some(config)) =
    session.strand_configuration(runtime.session, "main")
    as "main has a configuration"
  let assert Ok(Nil) =
    api.create_idle_strand(runtime, "other", config.value, None)
    as "the second strand is independent"
  let other = api.on_strand(runtime, "other")
  let assert Ok(_) = api.prompt(other, [user("foreign transcript body")])
    as "the other strand has its own branch"
  let assert Ok(other_id) = api.steer(other, user("foreign pending body"))
    as "the other strand receives a pending input"
  assert peer(
      runtime,
      peer_mail.InboxGet("main", ids.entry_id_to_string(other_id)),
    )
    == json.Null
  let assert Ok(Some(session.Cell(value: Some(other_leaf), ..))) =
    session.strand_leaf(runtime.session, "other")
    as "the foreign branch has a leaf"
  assert peer(
      runtime,
      peer_mail.InboxGet("main", ids.entry_id_to_string(other_leaf)),
    )
    == json.Null

  let assert Ok(own_id) = api.steer(runtime, user("own pending body"))
    as "main receives its own pending input"
  let own =
    peer(runtime, peer_mail.InboxGet("main", ids.entry_id_to_string(own_id)))
  assert field(own, "queue") == json.String("steer")
  assert string.contains(json.to_string(own), "own pending body")
  materialize(runtime, own_id)
  let own =
    peer(runtime, peer_mail.InboxGet("main", ids.entry_id_to_string(own_id)))
  assert field(own, "queue") == json.String("materialized")
  assert string.contains(json.to_string(own), "own pending body")
}

pub fn consumption_between_captures_resolves_against_the_same_ownership_leaf_test() {
  let runtime = runtime(903)
  let assert Ok(id) = api.steer(runtime, user("delivered during lookup"))
    as "the input is initially pending"
  let reader = runtime.session.snapshot_reader
  let reader =
    snapshot.Reader(..reader, capture: fn(plan: snapshot.Plan, wait) {
      case
        list.any(plan.selections, fn(selection) {
          case selection {
            snapshot.ExactKey(register.PendingEntry, _) -> True
            _ -> False
          }
        })
      {
        True -> materialize(runtime, id)
        False -> Nil
      }
      reader.capture(plan, wait)
    })
  let tree = session.Session(..runtime.session, snapshot_reader: reader)
  let assert Ok(found) =
    message_inspection.inbox_get(tree, "main", ids.entry_id_to_string(id))
    as "a consumed own input remains inspectable"
  assert field(found, "queue") == json.String("materialized")
  assert string.contains(json.to_string(found), "delivered during lookup")
}

pub fn remote_admission_history_survives_abort_and_filters_the_recipient_test() {
  let runtime = runtime(904)
  let source = ids.session_id_to_string(session_id(905))
  let grant = peer_mail.Grant(source, "reviewer", "main", peer_mail.BusyOnly)
  let _ = peer(runtime, peer_mail.Allow(grant))
  let receipt =
    peer(
      runtime,
      peer_mail.Deliver(
        peer_mail.Source(source, "reviewer", json.Null),
        "main",
        "report-1",
        "retained remote body",
      ),
    )
  assert field(receipt, "admitted") == json.Bool(True)
  assert peer(
      runtime,
      peer_mail.ReceivedGet("other", source, "reviewer", "report-1"),
    )
    == json.Null
  assert peer(
      runtime,
      peer_mail.ReceivedGet("main", source, "reviewer", "report-1"),
    )
    == receipt
  let assert Ok(Some(state)) = session.strand_state(runtime.session, "main")
    as "the admitted message belongs to an active run"
  let assert Some(op) = state.value.current_operation
    as "the provider still owns the operation"
  api.abort(runtime)
  let assert Ok(_) = api.await_result(runtime, op, within_ms: 5000)
    as "terminal cleanup settles before receipt recovery"
  assert peer(
      runtime,
      peer_mail.ReceivedGet("main", source, "reviewer", "report-1"),
    )
    == receipt
  let history = peer(runtime, peer_mail.Received("main", "", 1))
  assert list.length(items(history)) == 1
  assert string.contains(json.to_string(history), "retained remote body")
}

// This transaction is exactly a pending-message placement: ownership and
// payload deletion move together with the new leaf. The parked provider makes
// the test the only consumer, and the production capture still supplies all
// read consistency and branch membership checks under test.
fn materialize(runtime: api.Runtime, id: ids.EntryId) -> Nil {
  let assert Ok(Some(state)) = session.strand_state(runtime.session, "main")
    as "main has strand state"
  let assert Some(op) = state.value.current_operation as "main has an operation"
  let assert Ok(Some(op_state)) = session.op_state(runtime.session, op)
    as "the operation is durable"
  let assert operation.RunState(inbox:, ..) as run = op_state.value
    as "the operation is a run"
  let assert Ok(Some(payload)) =
    writer.get_register(
      runtime.tree.writer,
      register.PendingEntry,
      ids.entry_id_to_string(id),
    )
    as "the input payload is pending"
  let assert Ok(operation.PendingMessage(message:)) =
    codec.decode_pending_entry(payload.value.payload)
    as "the input is a valid message"
  let assert Ok(Some(leaf)) = session.strand_leaf(runtime.session, "main")
    as "main owns its leaf"
  let next =
    operation.RunState(
      ..run,
      inbox: operation.Inbox(
        ..inbox,
        steer: list.filter(inbox.steer, fn(item) { item != id }),
      ),
    )
  let assert Ok(_) =
    writer.commit(
      runtime.tree.writer,
      tx.Tx(
        writes: [
          tx.InsertEntry(entry.MessageEntry(
            id,
            leaf.value,
            0,
            0,
            message,
            False,
          )),
          tx.SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(id)),
          ),
          tx.SetRegister(
            register.OpState,
            ids.op_id_to_string(op),
            register.value(codec.encode_state(next)),
          ),
          tx.DeleteRegister(register.PendingEntry, ids.entry_id_to_string(id)),
        ],
        expected: [
          tx.Expect(
            register.OpState,
            ids.op_id_to_string(op),
            Some(op_state.seq),
          ),
          tx.Expect(register.StrandLeaf, "main", Some(leaf.seq)),
        ],
      ),
    )
    as "placement is atomic with the current owning operation"
  Nil
}

pub fn small_receipt_pages_ignore_foreign_aggregate_cell_and_byte_budgets_test() {
  let runtime = runtime(906)
  let body = string.repeat("x", 2048)
  let receipt = fn(target) {
    json.Object([
      #(
        "request",
        json.Object([
          #(
            "source_session",
            json.String(ids.session_id_to_string(session_id(907))),
          ),
          #("source_strand", json.String("sender")),
          #("target_strand", json.String(target)),
          #("message_id", json.String("fixture")),
          #("body", json.String(body)),
        ]),
      ),
      #("source", json.Null),
      #("admitted", json.Bool(True)),
    ])
  }
  let prefix = "client/peers/receipt/load/"
  let writes =
    list.map(numbers(1050), fn(number) {
      tx.SetRegister(
        register.FactCustom,
        prefix <> int.to_string(number),
        register.value(receipt("other")),
      )
    })
  let writes =
    list.append(writes, [
      tx.SetRegister(
        register.FactCustom,
        prefix <> "zz-own",
        register.value(receipt("main")),
      ),
    ])
  let assert Ok(_) = writer.commit(runtime.tree.writer, tx.Tx(writes, []))
    as "history exceeds both whole-capture cell and aggregate-byte budgets"
  let first = peer(runtime, peer_mail.Received("main", "", 1))
  assert items(first) == []
  let assert json.String(next) = field(first, "next")
    as "a foreign-only page still advances its cursor"
  assert string.starts_with(next, prefix)
  let own = peer(runtime, peer_mail.Received("main", prefix <> "z", 1))
  assert list.length(items(own)) == 1
  assert string.contains(json.to_string(own), body)
  assert field(own, "next") == json.Null
}

fn numbers(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}

// The production router supplies the strand independently of program arguments.
fn routed(runtime: api.Runtime, caller: String, id: String) -> String {
  let wiring =
    peers.Wiring(
      own: peer_mail.Endpoint("owned-session", fn(command) {
        peer_mail.handle(runtime, clock.fixed(0), command)
      }),
      metadata: json.Null,
      directory: None,
    )
  let route =
    peers.router(wiring, caller, fn(_) {
      Error(satellite.CapDenial("unknown", "unexpected fallback"))
    })
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(0), 701))
  let request =
    satellite.CapRequest(
      cap: "peer.inbox_get",
      args: msgpack.MapValue([
        #(msgpack.StringValue("id"), msgpack.StringValue(id)),
        #(msgpack.StringValue("strand"), msgpack.StringValue("main")),
      ]),
      identity: identity.run_phase(identity.for_execution(
        op_id: op,
        step_id: "inspection",
        budget: budget.Budget(max_outstanding: 4, deadline_ms: 9_000_000),
      )),
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [],
      cwd: "/work",
      ordinal: 0,
    )
  let assert Ok(satellite.ServedHere(serve)) = route(request)
    as "the default peer router handles its inspection capability"
  let assert framing.CapOk(msgpack.StringValue(answer)) = serve()
    as "the read-only endpoint returns encoded JSON"
  answer
}

pub fn production_router_ignores_counterfeit_recipient_arguments_test() {
  let runtime = runtime(909)
  let assert Ok(Some(config)) =
    session.strand_configuration(runtime.session, "main")
    as "the source has a configuration"
  let assert Ok(Nil) =
    api.create_idle_strand(runtime, "foreign", config.value, None)
    as "the foreign caller is a real independent strand"
  let assert Ok(id) = api.steer(runtime, user("caller-owned secret body"))
    as "main owns the queued message"
  let id = ids.entry_id_to_string(id)
  assert string.contains(
    routed(runtime, "main", id),
    "caller-owned secret body",
  )
  assert routed(runtime, "foreign", id) == "null"
}
