//// Parent-owned registry acquisition uses the actual SQLite implementation.
////
//// A permanent fixture node starts its linked writer and records its ACK before
//// a separate typed command initializes it. Checkpoints release one ordering
//// point; no callback or alternate SQL path runs behind them. An independent
//// SQLite write lock remains held until the actual BEGIN response is observed.
//// Native close observations, exact original DOWN and returned ACK are separate.
//// The one-shot close refusal is explicitly synthetic, not SQLite contention.

import broker/enrollment
import broker/exec
import broker/policy
import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import executor/generation_registry as r
import executor/generation_scope_plan as p
import executor/remote/admission
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import weft/actor

type NodeState {
  Empty
  Original(r.Parked)
}

type Mode {
  Fresh
  Recover
}

type NodeMessage {
  Park(
    Option(r.Checkpoint),
    process.Subject(r.OwnershipEvent),
    process.Subject(r.Parked),
  )
  Initialize(Mode, String, process.Subject(Result(r.Store, r.Error)))
  Release(process.Subject(Result(Nil, r.Error)))
  Stop
}

pub fn parent_death_before_original_ack_acquires_no_sql_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = process.new_subject()
    process.send(node.data, Park(Some(r.BeforeAck), events, parked))
    let assert Ok(r.CheckpointReached(r.BeforeAck, writer, _)) =
      process.receive(events, 1000)
      as "resource-free initializer before ACK"
    let down = process.monitor(writer)
    process.kill(node.pid)
    await_down(down)
    assert process.receive(parked, 0) == Error(Nil)
    assert simplifile.exists(path, False) == Ok(False)
  })
}

pub fn parent_death_after_ack_before_initialize_has_no_sql_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, None, events)
    let writer = r.parked_pid(parked)
    assert process.is_alive(writer)
    let down = process.monitor(writer)
    process.kill(node.pid)
    await_down(down)
    assert simplifile.exists(path, False) == Ok(False)
    assert r.release_parked(parked) == Error(r.Uncertain)
  })
}

pub fn explicit_resource_free_release_joins_original_and_refuses_late_sql_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, None, events)
    assert r.release_parked(parked) == Ok(Nil)
    assert !process.is_alive(r.parked_pid(parked))
    assert r.fresh_owned(parked, path, uuid(10), r.selected_limits())
      == Error(r.Uncertain)
    assert simplifile.exists(path, False) == Ok(False)
    process.send(node.data, Stop)
  })
}

pub fn owned_open_refusal_before_acquire_has_no_connection_to_close_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterAcquire), events)
    let down = process.monitor(r.parked_pid(parked))
    let reply = process.new_subject()
    process.send(node.data, Initialize(Recover, path, reply))
    assert process.receive(reply, 1000) == Ok(Error(r.Missing))
    await_down(down)
    assert process.receive(events, 0) == Error(Nil)
    assert simplifile.exists(path, False) == Ok(False)
    process.send(node.data, Stop)
  })
}

pub fn parent_normal_exit_closes_its_original_committed_connection_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.BeforeAck), events)
    let store = initialize(node.data, Fresh, path)
    begin_succeeded(events, r.parked_pid(parked))
    let plan = plan()
    let assert Ok(r.Fresh(claim)) =
      r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      as "only original post-COMMIT claim"
    let down = process.monitor(r.parked_pid(parked))
    process.send(node.data, Stop)
    actual_close(events, r.parked_pid(parked))
    await_down(down)
    assert r.prepare_publication(claim, digest(8)) == Error(r.Uncertain)
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 1
    assert scalar(path, "SELECT reservation FROM generation_record") > 0
  })
}

pub fn parent_death_after_acquire_closes_actual_connection_before_setup_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterAcquire), events)
    let ready = process.new_subject()
    process.send(node.data, Initialize(Fresh, path, ready))
    let writer = r.parked_pid(parked)
    let assert Ok(r.CheckpointReached(r.AfterAcquire, pid, _)) =
      process.receive(events, 1000)
      as "Acquired custody precedes setup gate"
    assert pid == writer
    assert simplifile.exists(path, False) == Ok(True)
    let down = process.monitor(writer)
    process.kill(node.pid)
    actual_close(events, writer)
    await_down(down)
    assert process.receive(ready, 0) == Error(Nil)
    assert scalar(
        path,
        "SELECT COUNT(*) FROM sqlite_master WHERE name='generation_meta'",
      )
      == 0
  })
}

pub fn actual_locked_begin_refusal_then_parent_death_closes_connection_test() {
  directory(fn(path) {
    seed(path)
    let assert Ok(lock) = sqlight.open(path)
      as "independent actual SQLite writer"
    assert sqlight.exec("BEGIN IMMEDIATE", lock) == Ok(Nil)
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterAcquire), events)
    let ready = process.new_subject()
    process.send(node.data, Initialize(Recover, path, ready))
    let writer = r.parked_pid(parked)
    let assert Ok(r.CheckpointReached(r.AfterAcquire, pid, permit)) =
      process.receive(events, 1000)
      as "recorded connection before locked setup"
    assert pid == writer
    let down = process.monitor(writer)
    process.send(permit, Nil)
    let assert Ok(r.BeginAttempted(attempted)) = process.receive(events, 1000)
      as "same synchronous setup turn invokes actual BEGIN"
    assert attempted == writer
    process.kill(node.pid)

    // The external lock stays held through SQL refusal; no timing guess unlocks it.
    let assert Ok(r.BeginFinished(finished, Error(r.Uncertain))) =
      process.receive(events, 7000)
      as "actual BEGIN refused under held lock"
    assert finished == writer
    actual_close(events, writer)
    await_down(down)
    assert process.receive(ready, 0) == Error(Nil)
    assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
    assert sqlight.close(lock) == Ok(Nil)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
  })
}

pub fn committed_setup_lost_ready_closes_original_without_recreating_claim_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterCommit), events)
    let ready = process.new_subject()
    process.send(node.data, Initialize(Fresh, path, ready))
    let writer = r.parked_pid(parked)
    begin_succeeded(events, writer)
    let assert Ok(r.CheckpointReached(r.AfterCommit, pid, _)) =
      process.receive(events, 1000)
      as "real setup COMMIT before Ready"
    assert pid == writer
    assert scalar(path, "SELECT format FROM generation_meta") == 2
    let down = process.monitor(writer)
    process.kill(node.pid)
    actual_close(events, writer)
    await_down(down)
    assert process.receive(ready, 0) == Error(Nil)
    assert r.release_parked(parked) == Error(r.Uncertain)
    let assert Ok(history) = r.recover(path, uuid(99), r.selected_limits())
      as "committed empty history after original Ready loss"
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
    assert r.release(history) == Ok(Nil)
  })
}

pub fn setup_validation_failure_closes_actual_connection_and_keeps_metadata_test() {
  directory(fn(path) {
    seed(path)
    mutate(
      path,
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_meta SET format=99",
    )
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.BeforeAck), events)
    let writer = r.parked_pid(parked)
    let down = process.monitor(writer)
    let ready = process.new_subject()
    process.send(node.data, Initialize(Recover, path, ready))
    assert process.receive(ready, 1000) == Ok(Error(r.Corrupt))
    actual_close(events, writer)
    await_down(down)
    assert scalar(path, "SELECT format FROM generation_meta") == 99
    assert r.release_parked(parked) == Error(r.Uncertain)
    process.send(node.data, Stop)
  })
}

pub fn owned_original_recovery_preserves_plan_and_fences_old_authority_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, None, events)
    let store = initialize(node.data, Fresh, path)
    let plan = plan()
    let original = p.original(plan)
    let assert Ok(r.Fresh(claim)) =
      r.admit_planned(store, original, doors(), 1, None, plan)
      as "complete original plan admission"
    let charge = scalar(path, "SELECT reservation FROM generation_record")
    assert r.fresh_owned(parked, path, uuid(99), r.selected_limits())
      == Error(r.Uncertain)
    assert r.release(store) == Ok(Nil)
    process.send(node.data, Stop)

    let recovered_node = start_node()
    let recovered = park(recovered_node.data, None, events)
    let history = initialize(recovered_node.data, Recover, path)
    assert r.scope_plan(history, g.association_key(original)) == Ok(Some(plan))
    assert r.admit_planned(history, original, doors(), 1, None, plan)
      == Ok(r.Retained(r.Unknown))
    assert r.prepare_publication(claim, digest(8)) == Error(r.Uncertain)
    assert scalar(path, "SELECT reservation FROM generation_record") == charge
    assert r.release_parked(recovered) == Ok(Nil)
    process.send(recovered_node.data, Stop)
  })
}

pub fn owned_version_one_migration_retains_history_without_plan_backfill_test() {
  directory(fn(path) {
    let plan = plan()
    let assert Ok(store) = r.fresh(path, uuid(1), r.selected_limits())
      as "real existing format-two fixture"
    let assert Ok(r.Fresh(_)) =
      r.admit(store, p.original(plan), doors(), 1, None)
      as "legacy association without provenance"
    assert r.release(store) == Ok(Nil)
    let charge = scalar(path, "SELECT reservation FROM generation_record")

    // Recreate the original format-one metadata while retaining its exact old rows.
    mutate(
      path,
      "DROP TABLE generation_scope_plan; ALTER TABLE generation_meta RENAME TO old_generation_meta; CREATE TABLE generation_meta(id INTEGER PRIMARY KEY CHECK(id=1),format INTEGER NOT NULL CHECK(format=1),live_limit INTEGER NOT NULL,row_limit INTEGER NOT NULL,byte_limit INTEGER NOT NULL); INSERT INTO generation_meta SELECT id,1,live_limit,row_limit,byte_limit FROM old_generation_meta; DROP TABLE old_generation_meta;",
    )
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, None, events)
    let history = initialize(node.data, Recover, path)
    assert scalar(path, "SELECT format FROM generation_meta") == 2
    assert scalar(path, "SELECT reservation FROM generation_record") == charge
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
    assert r.scope_plan(history, g.association_key(p.original(plan)))
      == Ok(None)
    assert r.admit_planned(history, p.original(plan), doors(), 1, None, plan)
      == Error(r.Conflict)
    assert r.release_parked(parked) == Ok(Nil)
    process.send(node.data, Stop)
  })
}

pub fn explicit_close_ack_and_original_normal_down_are_both_required_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterClose), events)
    let _store = initialize(node.data, Fresh, path)
    let writer = r.parked_pid(parked)
    begin_succeeded(events, writer)
    let reply = process.new_subject()
    process.send(node.data, Release(reply))
    actual_close(events, writer)
    let assert Ok(r.CheckpointReached(r.AfterClose, pid, permit)) =
      process.receive(events, 1000)
      as "native close succeeded before ACK"
    assert pid == writer
    assert process.is_alive(writer)
    assert process.receive(reply, 0) == Error(Nil)
    process.send(permit, Nil)
    assert process.receive(reply, 1000) == Ok(Ok(Nil))
    assert !process.is_alive(writer)
    process.send(node.data, Stop)
  })
}

pub fn native_close_success_lost_ack_and_abnormal_down_remain_uncertain_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterClose), events)
    let _store = initialize(node.data, Fresh, path)
    let writer = r.parked_pid(parked)
    begin_succeeded(events, writer)
    let reply = process.new_subject()
    let _observer =
      process.spawn_unlinked(fn() {
        process.send(reply, r.release_parked(parked))
      })
    actual_close(events, writer)
    let assert Ok(r.CheckpointReached(r.AfterClose, pid, _)) =
      process.receive(events, 1000)
      as "withheld ACK after actual close"
    assert pid == writer
    process.kill(writer)
    assert process.receive(reply, 1000) == Ok(Error(r.Uncertain))
    assert r.release_parked(parked) == Error(r.Uncertain)
    assert scalar(path, "SELECT format FROM generation_meta") == 2
    process.send(node.data, Stop)
  })
}

pub fn close_ack_before_abnormal_original_exit_still_refuses_release_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.AfterCloseAck), events)
    let _store = initialize(node.data, Fresh, path)
    let writer = r.parked_pid(parked)
    begin_succeeded(events, writer)
    let reply = process.new_subject()
    let _observer =
      process.spawn_unlinked(fn() {
        process.send(reply, r.release_parked(parked))
      })
    actual_close(events, writer)
    let assert Ok(r.CheckpointReached(r.AfterCloseAck, pid, _)) =
      process.receive(events, 1000)
      as "close ACK sent before original exit"
    assert pid == writer
    assert process.receive(reply, 0) == Error(Nil)
    process.kill(writer)
    assert process.receive(reply, 1000) == Ok(Error(r.Uncertain))
  })
}

pub fn synthetic_close_refusal_retains_actual_connection_for_cleanup_test() {
  directory(fn(path) {
    let node = start_node()
    let events = process.new_subject()
    let parked = park(node.data, Some(r.RefuseCloseOnce), events)
    let store = initialize(node.data, Fresh, path)
    let writer = r.parked_pid(parked)
    begin_succeeded(events, writer)
    assert r.release(store) == Error(r.Uncertain)
    assert process.is_alive(writer)
    assert r.close_generation(store, g.association_key(p.original(plan())))
      == Error(r.Uncertain)
    assert process.receive(events, 0) == Error(Nil)
    let down = process.monitor(writer)
    process.send(node.data, Stop)
    actual_close(events, writer)
    await_down(down)
  })
}

fn start_node() -> actor.Started(process.Subject(NodeMessage)) {
  let assert Ok(node) =
    actor.new(Empty)
    |> actor.unlinked
    |> actor.on_message(handle_node)
    |> actor.start
    as "permanent original fixture node, independently controlled"
  node
}

fn handle_node(
  state: NodeState,
  message: NodeMessage,
) -> actor.Next(NodeState, NodeMessage) {
  case message {
    Park(stage, events, reply) -> {
      let assert Empty = state as "only one original writer per fixture node"
      let assert Ok(parked) = case stage {
        None -> r.park()
        Some(stage) -> r.park_observed(stage, events)
      }
        as "original parent invokes parked startup itself"
      process.send(reply, parked)
      actor.continue(Original(parked))
    }
    Initialize(mode, path, reply) -> {
      let assert Original(parked) = state
        as "ACK retained before initialization"
      let outcome = case mode {
        Fresh -> r.fresh_owned(parked, path, uuid(10), r.selected_limits())
        Recover -> r.recover_owned(parked, path, uuid(20), r.selected_limits())
      }
      process.send(reply, outcome)
      actor.continue(state)
    }
    Release(reply) -> {
      let assert Original(parked) = state as "close names the original writer"
      process.send(reply, r.release_parked(parked))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn park(
  node: process.Subject(NodeMessage),
  stage: Option(r.Checkpoint),
  events: process.Subject(r.OwnershipEvent),
) -> r.Parked {
  let reply = process.new_subject()
  process.send(node, Park(stage, events, reply))
  case stage {
    Some(r.BeforeAck) -> {
      let assert Ok(r.CheckpointReached(r.BeforeAck, _, permit)) =
        process.receive(events, 1000)
        as "release resource-free ACK checkpoint"
      process.send(permit, Nil)
    }
    Some(r.AfterAcquire)
    | Some(r.AfterCommit)
    | Some(r.AfterClose)
    | Some(r.AfterCloseAck)
    | Some(r.RefuseCloseOnce)
    | None -> Nil
  }
  let assert Ok(parked) = process.receive(reply, 1000)
    as "original ACK retained"
  parked
}

fn initialize(
  node: process.Subject(NodeMessage),
  mode: Mode,
  path: String,
) -> r.Store {
  let reply = process.new_subject()
  process.send(node, Initialize(mode, path, reply))
  let assert Ok(Ok(store)) = process.receive(reply, 1000)
    as "real setup and COMMIT"
  store
}

fn begin_succeeded(
  events: process.Subject(r.OwnershipEvent),
  writer: process.Pid,
) {
  assert process.receive(events, 1000) == Ok(r.BeginAttempted(writer))
  assert process.receive(events, 1000) == Ok(r.BeginFinished(writer, Ok(Nil)))
}

fn actual_close(
  events: process.Subject(r.OwnershipEvent),
  writer: process.Pid,
) {
  assert process.receive(events, 1000)
    == Ok(r.ConnectionClosed(writer, Ok(Nil)))
}

fn await_down(watch: process.Monitor) {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "exact original writer terminates"
  process.demonitor_process(watch)
}

fn seed(path: String) {
  let assert Ok(store) = r.fresh(path, uuid(1), r.selected_limits())
    as "real SQLite registry seed"
  assert r.release(store) == Ok(Nil)
}

fn directory(run: fn(String) -> Nil) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    "/private/tmp/loom-owned-registry-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory(root) == Ok(Nil)
  run(root <> "/registry.sqlite")
  assert simplifile.delete(root) == Ok(Nil)
}

fn scalar(path: String, text: String) -> Int {
  let assert Ok(connection) = sqlight.open(path) as "independent SQL readback"
  let assert Ok([value]) =
    sqlight.query(
      text,
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
    as "real scalar"
  assert sqlight.close(connection) == Ok(Nil)
  value
}

fn mutate(path: String, text: String) {
  let assert Ok(connection) = sqlight.open(path) as "independent fixture SQL"
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn uuid(number: Int) -> ids.EntryId {
  let assert Ok(value) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "fixture UUID"
  value
}

fn digest(number: Int) -> g.Digest {
  let assert Ok(value) = g.digest(<<number:size(256)>>) as "fixture digest"
  value
}

fn doors() -> BitArray {
  let assert Ok(value) =
    mp.encode(mp.ArrayValue([mp.StringValue("original doors")]))
    as "original canonical doors"
  value
}

fn plan() -> p.Plan {
  let enrolled = enrollment_fixture(1)
  let assert Ok(capacity) = admission.capacity(7) as "selected native capacity"
  let assert Ok(plan) =
    p.new(
      association_fixture(1, enrolled),
      enrolled,
      "owner@owner.example.invalid",
      "/state/native.sqlite",
      capacity,
      p.Journal("/state/workspace.sqlite", 3, 100_000),
      p.Journal("/state/resource.sqlite", 5, 200_000),
      p.DisabledLsp,
    )
    as "full immutable provenance fixture"
  plan
}

fn enrollment_fixture(number: Int) -> enrollment.SessionEnrollment {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.entry_id_to_string(uuid(number)),
      "checkout",
      "linux",
      2,
      7,
    )
    as "complete original scope"
  let policy =
    policy.SandboxPolicy(
      ["/work", "/alloc"],
      ["/tc", "/seed", "/work"],
      ["/work/.git"],
      policy.NetworkOff,
      policy.Limits(11, 12, 13, 14, 15, 16),
      ["PATH", "HOME"],
      policy.ScratchTmpfs,
      [
        policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
        policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
      ],
    )
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(scope, ["/"], policy, exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        policy.mounts,
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "full valid enrollment"
  enrolled
}

fn association_fixture(
  number: Int,
  enrolled: enrollment.SessionEnrollment,
) -> g.GenerationAssociation {
  let assert Ok(bytes) = enrollment.encode(enrolled)
    as "canonical enrollment body"
  let assert Ok(key) =
    g.key(enrollment.native_facts(enrolled).scope, digest(1), 1)
    as "full generation key"
  g.association(
    key,
    content_hash(bytes),
    uuid(number + 1000),
    g.FirstGeneration,
  )
}

fn content_hash(bytes: BitArray) -> g.Digest {
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "actual digest"
  digest
}
