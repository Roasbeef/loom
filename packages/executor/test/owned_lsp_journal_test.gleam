//// Actual original SQLite custody for permanent live and finite history paths.
////
//// The fixture parent records the resource-free ACK before a separate message
//// initializes its writer. Temporary writers self-adopt into actual weft runs.
//// Checkpoints retain exact original PIDs; actual close, close ACK, normal DOWN
//// and managed aggregate completion are independently observed.

import core/clock
import core/generation as g
import core/ids
import core/lsp_command as id
import core/remote_tool
import core/workspace
import executor/remote/lsp_journal as j
import executor/remote/lsp_wire as wire
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import lsp/query
import simplifile
import sqlight
import weft
import weft/actor

type Fixture {
  Fixture(
    path: String,
    directory: String,
    binding: j.Binding,
    contract: g.Digest,
    incarnation: ids.EntryId,
    limits: j.Limits,
    clock: j.Clock,
    profiles: id.EnrolledProfiles,
    scope: workspace.Scope,
    enrollment: g.Digest,
  )
}

type NodeState {
  Empty
  Original(j.ParkedFresh)
}

type NodeMessage {
  Park(j.FreshInput, j.Probe, process.Subject(j.ParkedFresh))
  Initialise(process.Subject(Result(j.LiveStore, j.Error)))
  Release(process.Subject(Result(Nil, j.Error)))
  Stop
}

type Running {
  Running(
    run: weft.Detached(Nil, j.Error),
    scope_watch: process.Monitor,
    workers: process.Subject(process.Pid),
    ready: process.Subject(j.OwnedRecovery),
    finish: process.Subject(process.Subject(Nil)),
    events: process.Subject(j.OwnershipEvent),
  )
}

pub fn resource_free_parent_death_before_ack_and_before_initialise_test() {
  list.each([j.BeforeAck, j.AfterAcquire], fn(stage) {
    fixture(fn(f) {
      let node = node()
      let events = process.new_subject()
      let parked = process.new_subject()
      process.send(
        node.data,
        Park(fresh_input(f), j.Observed(stage, events), parked),
      )
      let writer = case stage {
        j.BeforeAck -> checkpoint(events, j.BeforeAck).0
        _ -> j.fresh_owner(receive(parked))
      }
      let watch = process.monitor(writer)
      process.kill(node.pid)
      assert_down(watch)
      assert !process.is_alive(writer)
      assert simplifile.exists(f.path, False) == Ok(False)
    })
  })
}

pub fn resource_free_release_and_late_initialise_refuse_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original = park(node.data, f, j.Unobserved)
    assert j.release_fresh(original) == Ok(Nil)
    assert !process.is_alive(j.fresh_owner(original))
    assert j.initialise_fresh(original) == Error(j.Uncertain)
    assert j.release_fresh(original) == Error(j.Uncertain)
    assert simplifile.exists(f.path, False) == Ok(False)
    assert process.receive(events, 0) == Error(Nil)
    process.send(node.data, Stop)
  })
}

pub fn acquired_parent_loss_closes_actual_connection_before_setup_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original = park(node.data, f, j.Observed(j.AfterAcquire, events))
    let reply = process.new_subject()
    process.send(node.data, Initialise(reply))
    let #(writer, _) = checkpoint(events, j.AfterAcquire)
    assert writer == j.fresh_owner(original)
    let watch = process.monitor(writer)
    assert simplifile.exists(f.path, False) == Ok(True)
    assert scalar(
        f.path,
        "SELECT count(*) FROM sqlite_master WHERE name='lsp_meta'",
      )
      == 0
    process.kill(node.pid)
    actual_close(events, writer)
    assert_down(watch)
    assert scalar(
        f.path,
        "SELECT count(*) FROM sqlite_master WHERE name='lsp_meta'",
      )
      == 0
    assert process.receive(reply, 0) == Error(Nil)
  })
}

pub fn committed_ready_lost_parent_and_duplicate_initialise_never_recreate_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original =
      park(node.data, f, j.Observed(j.AfterCommitBeforeReady, events))
    let reply = process.new_subject()
    process.send(node.data, Initialise(reply))
    let #(writer, permit) = checkpoint(events, j.AfterCommitBeforeReady)
    let watch = process.monitor(writer)
    assert scalar(f.path, "SELECT format FROM lsp_meta") == 1
    process.send(permit, j.SuppressReply)
    process.kill(node.pid)
    actual_close(events, writer)
    assert_down(watch)
    assert process.receive(reply, 0) == Error(Nil)
    assert j.initialise_fresh(original) == Error(j.Uncertain)
    assert j.park_fresh(fresh_input(f)) |> result.try(j.initialise_fresh)
      == Error(j.AlreadyExists)
  })
}

pub fn live_original_endpoint_first_claim_and_distinct_store_test() {
  fixture(fn(f) {
    let node = node()
    let original = park(node.data, f, j.Unobserved)
    let store = initialise(node.data)
    assert j.initialise_fresh(original) == Error(j.Uncertain)
    let request = wire.Diagnostics(None)
    let #(_, lease, input) = identity(f, 1, request)
    let assert Ok(j.FreshLease(claim)) =
      j.reserve_lease_live(store, lease, input, "gleam", "/workspace")
      as "Only original first reservation returns startup custody."
    let assert Ok(j.RetainedLease(_)) =
      j.reserve_lease_live(store, lease, input, "gleam", "/workspace")
      as "Duplicate reservation returns history only."
    assert j.verify_lease_startup(store, f.binding, claim, f.clock.era)
      == Ok(Nil)
    let assert Ok(other) =
      j.recover(
        f.path,
        f.binding,
        f.contract,
        f.incarnation,
        f.limits,
        f.clock,
        f.profiles,
      )
      as "Distinct original endpoint retains only recovery history."
    assert j.verify_lease_startup(other, f.binding, claim, f.clock.era)
      == Error(j.Conflict)
    assert j.release(other) == Ok(Nil)
    assert j.release_fresh(original) == Ok(Nil)
    process.send(node.data, Stop)
  })
}

pub fn parent_normal_exit_after_commit_closes_actual_original_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original = park(node.data, f, j.Observed(j.AfterAcquire, events))
    let reply = process.new_subject()
    process.send(node.data, Initialise(reply))
    let #(writer, permit) = checkpoint(events, j.AfterAcquire)
    process.send(permit, j.Proceed)
    let assert Ok(_) = receive(reply)
      as "Original setup COMMIT grants readiness."
    let watch = process.monitor(writer)
    process.send(node.data, Stop)
    actual_close(events, writer)
    assert normal_down(watch) == Ok(Nil)
    assert j.release_fresh(original) == Error(j.Uncertain)
    assert scalar(f.path, "SELECT format FROM lsp_meta") == 1
  })
}

pub fn close_ack_requires_original_normal_down_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original =
      park(node.data, f, j.Observed(j.AfterCloseAckBeforeExit, events))
    let _store = initialise(node.data)
    let reply = process.new_subject()
    process.send(node.data, Release(reply))
    actual_close(events, j.fresh_owner(original))
    let #(writer, permit) = checkpoint(events, j.AfterCloseAckBeforeExit)
    let watch = process.monitor(writer)
    assert process.is_alive(writer)
    assert process.receive(reply, 0) == Error(Nil)
    process.send(permit, j.Proceed)
    assert receive(reply) == Ok(Nil)
    assert normal_down(watch) == Ok(Nil)
    assert j.release_fresh(original) == Error(j.Uncertain)
    process.send(node.data, Stop)
  })
}

pub fn abnormal_down_after_close_ack_and_lost_ack_refuse_test() {
  list.each([j.AfterCloseAckBeforeExit, j.BeforeCloseAck], fn(stage) {
    fixture(fn(f) {
      let node = node()
      let events = process.new_subject()
      let original = park(node.data, f, j.Observed(stage, events))
      let _store = initialise(node.data)
      let answer = process.new_subject()
      let run =
        weft.new_prepared([
          weft.managed(fn(_ledger) {
            process.send(answer, j.release_fresh(original))
            Ok(Nil)
          }),
        ])
        |> weft.start_detached
      let scope_watch = process.monitor(weft.scope_pid(run))
      case stage {
        j.BeforeCloseAck -> {
          let #(writer, permit) = checkpoint(events, stage)
          process.send(permit, j.SuppressReply)
          actual_close(events, writer)
        }
        _ -> {
          actual_close(events, j.fresh_owner(original))
          let #(writer, _) = checkpoint(events, stage)
          process.kill(writer)
        }
      }
      assert receive(answer) == Error(j.Uncertain)
      assert weft.pull(run, 1000) == weft.PulledOutcome(weft.Completed(0, Nil))
      assert weft.pull(run, 1000) == weft.AllDelivered
      assert normal_down(scope_watch) == Ok(Nil)
      assert j.release_fresh(original) == Error(j.Uncertain)
      process.send(node.data, Stop)
    })
  })
}

pub fn synthetic_close_refusal_retains_connection_and_fences_work_test() {
  fixture(fn(f) {
    let node = node()
    let events = process.new_subject()
    let original = park(node.data, f, j.Observed(j.BeforeCloseAck, events))
    assert process.is_alive(j.fresh_owner(original))
    let store = initialise(node.data)
    let reply = process.new_subject()
    process.send(node.data, Release(reply))
    let #(writer, permit) = checkpoint(events, j.BeforeCloseAck)
    process.send(permit, j.RefuseClose)
    assert receive(reply) == Error(j.Uncertain)
    assert process.is_alive(writer)
    assert process.receive(events, 0) == Error(Nil)
    assert j.seal(store) == Error(j.Uncertain)
    let watch = process.monitor(writer)
    process.send(node.data, Stop)
    actual_close(events, writer)
    assert normal_down(watch) == Ok(Nil)
  })
}

pub fn history_exact_result_receipt_parent_binding_and_original_anchor_test() {
  fixture(fn(f) {
    let store = legacy(f)
    let request = wire.Definition(query.SymbolQuery("name", None, None))
    let #(capture, lease, input) = identity(f, 1, request)
    let assert Ok(_) =
      j.reserve_lease_live(store, lease, input, "gleam", "/workspace")
      as "Original permanent lease."
    let assert Ok(history) = j.capture_finite(store, capture, request)
      as "Original captured anchor."
    let assert Ok(#(anchor, e0)) = j.captured_anchor(history) as "Original E0."
    let assert Ok(j.FreshFinite(claim)) =
      j.accept_finite(store, timed(capture, anchor, 2000), request)
      as "Original single finite admission."
    let value = wire.Definitions(query.Served([], query.Warm))
    let assert Ok(receipt) = j.finish(claim, value)
      as "Original immutable result."
    assert j.release(store) == Ok(Nil)
    let before = scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
    let outcome =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use original <- result.try(j.recover_owned(recovery_input(f), ledger))
          let assert Ok(retained) =
            j.inspect_finite_owned(original, capture, request)
            as "Exact historical capture."
          assert j.retained_result(retained) == Ok(value)
          assert j.captured_anchor(retained) == Ok(#(anchor, e0))
          assert j.acknowledge_exact_owned(
              original,
              capture,
              request,
              digest_of(<<99>>),
            )
            == Error(j.Conflict)
          assert j.acknowledge_exact_owned(
              original,
              capture,
              request,
              j.receipt_fields(receipt).3,
            )
            == Ok(Nil)
          let assert Ok(retained) =
            j.inspect_finite_owned(original, capture, request)
            as "Exact committed receipt."
          assert j.finite_disposition(retained) == j.Acknowledged
          assert j.inspect_finite_owned(
              original,
              capture,
              wire.Diagnostics(None),
            )
            == Error(j.Invalid)
          let assert Ok(lease_history) = j.inspect_lease_owned(original, lease)
            as "Historical lease only."
          assert j.lease_disposition(lease_history) == j.UncertainLease
          j.release_owned(original)
        }),
      ])
      |> weft.start
    assert outcome == [weft.Completed(0, Nil)]
    assert scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
      == before

    // A history-only input retains a changed binding rather than choosing latest.
    let assert Ok(other_key) = g.key(f.scope, f.contract, 2)
      as "Different retained generation."
    let assert Ok(wrong) =
      j.recovery_input(
        f.path,
        j.binding(other_key, f.enrollment),
        f.contract,
        f.limits,
        f.profiles,
      )
      as "Different historical binding."
    let outcome =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use original <- result.try(j.recover_owned(wrong, ledger))
          assert j.inspect_finite_owned(original, capture, request)
            == Error(j.Conflict)
          j.release_owned(original)
        }),
      ])
      |> weft.start
    assert outcome == [weft.Completed(0, Nil)]
  })
}

pub fn history_worker_loss_before_adoption_and_before_ack_opens_no_sql_test() {
  list.each([j.BeforeAdopt, j.BeforeAck], fn(stage) {
    fixture(fn(f) {
      let store = legacy(f)
      let request = wire.Diagnostics(None)
      let #(capture, _, _) = identity(f, 1, request)
      let assert Ok(_) = j.capture_finite(store, capture, request)
        as "An unfinished original makes pre-adoption SQL mutation observable."
      assert j.release(store) == Ok(Nil)
      let before = store_bytes(f)
      let running = history(f, stage)
      let worker = receive(running.workers)
      let #(writer, permit) = checkpoint(running.events, stage)
      let watch = process.monitor(writer)
      process.kill(worker)
      case stage {
        j.BeforeAdopt -> {
          let assert weft.PulledOutcome(weft.Crashed(..)) =
            weft.pull(running.run, 1000)
            as "Original request worker loss is sealed before adoption."
          process.send(permit, j.Proceed)
          assert_down(watch)
          finish_run(running)
        }
        _ -> {
          process.send(permit, j.Proceed)
          assert normal_down(watch) == Ok(Nil)
          let assert weft.PulledOutcome(weft.Crashed(..)) =
            weft.pull(running.run, 1000)
            as "Original adopted worker loss remains lost business outcome."
          finish_run(running)
        }
      }
      assert store_bytes(f) == before
      assert process.receive(running.ready, 0) == Error(Nil)
    })
  })
}

pub fn history_acquired_cancellation_joins_actual_owner_and_scope_test() {
  fixture(fn(f) {
    let store = legacy(f)
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(f, 1, request)
    let assert Ok(original) = j.capture_finite(store, capture, request)
      as "Retained original capture."
    assert j.release(store) == Ok(Nil)
    let before = scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
    let running = history(f, j.AfterAcquire)
    let _worker = receive(running.workers)
    let #(writer, permit) = checkpoint(running.events, j.AfterAcquire)
    let watch = process.monitor(writer)
    weft.cancel_detached(running.run)
    assert weft.pull(running.run, 0) == weft.NotYet
    assert process.is_alive(writer)
    process.send(permit, j.Proceed)
    actual_close(running.events, writer)
    assert normal_down(watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Abandoned(..)) =
      weft.pull(running.run, 1000)
      as "Original cancellation remains a cancelled observation."
    finish_run(running)
    assert scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
      == before
    let result =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use recovered <- result.try(j.recover_owned(recovery_input(f), ledger))
          let assert Ok(history) =
            j.inspect_finite_owned(recovered, capture, request)
            as "Original capture remains history."
          assert j.captured_anchor(history) == j.captured_anchor(original)
          assert j.finite_disposition(history) == j.Unknown
          j.release_owned(recovered)
        }),
      ])
      |> weft.start
    assert result == [weft.Completed(0, Nil)]
  })
}

pub fn history_begin_refusal_poison_and_missing_inputs_close_original_test() {
  fixture(fn(f) {
    let store = legacy(f)
    assert j.release(store) == Ok(Nil)
    let assert Ok(lock) = sqlight.open(f.path)
      as "Independent real original SQL blocker."
    assert sqlight.exec("BEGIN IMMEDIATE", lock) == Ok(Nil)
    let running = history(f, j.AfterAcquire)
    let _worker = receive(running.workers)
    let #(writer, permit) = checkpoint(running.events, j.AfterAcquire)
    let watch = process.monitor(writer)
    process.send(permit, j.Proceed)
    actual_close(running.events, writer)
    assert normal_down(watch) == Ok(Nil)
    assert weft.pull(running.run, 1000)
      == weft.PulledOutcome(weft.Failed(0, j.Uncertain))
    finish_run(running)
    assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
    assert sqlight.close(lock) == Ok(Nil)
    mutate(
      f.path,
      "PRAGMA ignore_check_constraints=ON; UPDATE lsp_meta SET format=2",
    )
    let result =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert j.recover_owned(recovery_input(f), ledger) == Error(j.Corrupt)
          let assert Ok(missing) =
            j.recovery_input(
              f.directory <> "/absent.db",
              f.binding,
              f.contract,
              f.limits,
              f.profiles,
            )
            as "Resource-free missing selection."
          assert j.recover_owned(missing, ledger) == Error(j.Missing)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert result == [weft.Completed(0, Nil)]
    assert simplifile.exists(f.directory <> "/absent.db", False) == Ok(False)
  })
}

pub fn history_close_ack_waits_for_exact_normal_owner_and_scope_test() {
  fixture(fn(f) {
    let store = legacy(f)
    assert j.release(store) == Ok(Nil)
    let running = history(f, j.AfterCloseAckBeforeExit)
    let _worker = receive(running.workers)
    let _original = receive(running.ready)
    finish(running)
    let assert j.ConnectionClosed(writer, Ok(Nil)) = receive(running.events)
      as "Actual original SQLite close precedes explicit ACK."
    let #(same, permit) = checkpoint(running.events, j.AfterCloseAckBeforeExit)
    assert same == writer
    let watch = process.monitor(writer)
    assert process.is_alive(writer)
    assert weft.pull(running.run, 0) == weft.NotYet
    process.send(permit, j.Proceed)
    assert normal_down(watch) == Ok(Nil)
    assert weft.pull(running.run, 1000)
      == weft.PulledOutcome(weft.Completed(0, Nil))
    finish_run(running)
  })
}

pub fn history_post_commit_lost_ready_retains_original_cleanup_test() {
  fixture(fn(f) {
    let store = legacy(f)
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(f, 1, request)
    let assert Ok(original) = j.capture_finite(store, capture, request)
      as "Original capture before recovery."
    assert j.release(store) == Ok(Nil)
    let before = scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
    let running = history(f, j.AfterCommitBeforeReady)
    let _worker = receive(running.workers)
    let #(writer, permit) = checkpoint(running.events, j.AfterCommitBeforeReady)
    let watch = process.monitor(writer)
    assert scalar(f.path, "SELECT phase FROM lsp_finite") == 8
    process.send(permit, j.SuppressReply)
    weft.cancel_detached(running.run)
    actual_close(running.events, writer)
    assert normal_down(watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Abandoned(..)) =
      weft.pull(running.run, 1000)
      as "Lost original ready never becomes a new historical authority."
    finish_run(running)
    assert process.receive(running.ready, 0) == Error(Nil)
    assert scalar(f.path, "SELECT sum(reserved_bytes) FROM lsp_identity")
      == before
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use recovered <- result.try(j.recover_owned(recovery_input(f), ledger))
          let assert Ok(retained) =
            j.inspect_finite_owned(recovered, capture, request)
            as "Recovery preserves original anchor after a lost ready result."
          assert j.captured_anchor(retained) == j.captured_anchor(original)
          assert j.finite_disposition(retained) == j.Unknown
          j.release_owned(recovered)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
  })
}

pub fn history_query_poison_closes_actual_owner_without_release_shortcut_test() {
  fixture(fn(f) {
    let store = legacy(f)
    let request = wire.Diagnostics(None)
    let #(_, lease, input) = identity(f, 1, request)
    let assert Ok(_) =
      j.reserve_lease(store, lease, input, "gleam", "/workspace")
      as "Original permanent lease history."
    assert j.release(store) == Ok(Nil)
    let running = history(f, j.AfterCommitBeforeReady)
    let _worker = receive(running.workers)
    let #(writer, permit) = checkpoint(running.events, j.AfterCommitBeforeReady)
    let watch = process.monitor(writer)
    process.send(permit, j.Proceed)
    let original = receive(running.ready)
    mutate(
      f.path,
      "PRAGMA ignore_check_constraints=ON; UPDATE lsp_meta SET format=2",
    )
    assert j.inspect_lease_owned(original, lease) == Error(j.Corrupt)
    let assert j.ConnectionClosed(closed, Ok(Nil)) = receive(running.events)
      as "Poison cleanup attempted actual SQLite close."
    assert closed == writer
    assert normal_down(watch) == Ok(Nil)
    assert j.release_owned(original) == Error(j.Uncertain)
    finish(running)
    assert weft.pull(running.run, 1000)
      == weft.PulledOutcome(weft.Failed(0, j.Uncertain))
    finish_run(running)
  })
}

pub fn history_command_full_parent_and_changed_metadata_refuse_test() {
  fixture(fn(f) {
    let store = legacy(f)
    let request = wire.Diagnostics(None)
    let #(_, lease, input) = identity(f, 1, request)
    let assert Ok(_) =
      j.reserve_lease(store, lease, input, "gleam", "/workspace")
      as "Complete original lease parent."
    let assert Ok(ref) = id.lsp_startup_command(lease, id.ServerLease)
      as "Closed original command parent."
    let assert Ok(_) = j.reserve_command(store, ref, request, None)
      as "Command history retains its full original parent."
    assert j.release(store) == Ok(Nil)
    let #(_, other_lease, _) = identity(f, 2, request)
    let assert Ok(other_ref) =
      id.lsp_startup_command(other_lease, id.ServerLease)
      as "A different complete parent cannot select the original command."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use recovered <- result.try(j.recover_owned(recovery_input(f), ledger))
          let assert Ok(history) =
            j.inspect_command_owned(recovered, ref, request, None)
            as "Original command readback after recovery."
          assert j.command_disposition(history) == j.UnknownCommand
          assert j.inspect_command_owned(recovered, other_ref, request, None)
            == Error(j.Missing)
          j.release_owned(recovered)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
    let assert Ok(lower) = j.limits(31, 64_000_000)
      as "Changed immutable limits."
    let assert Ok(wrong_limit) =
      j.recovery_input(f.path, f.binding, f.contract, lower, f.profiles)
      as "Resource-free changed immutable ceilings."
    let assert Ok(wrong_contract) =
      j.recovery_input(
        f.path,
        f.binding,
        digest_of(<<99>>),
        f.limits,
        f.profiles,
      )
      as "Resource-free changed semantic contract."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert j.recover_owned(wrong_limit, ledger) == Error(j.Corrupt)
          assert j.recover_owned(wrong_contract, ledger) == Error(j.Corrupt)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
  })
}

pub fn coordinator_death_still_joins_original_adopted_writer_test() {
  fixture(fn(f) {
    let store = legacy(f)
    assert j.release(store) == Ok(Nil)
    let controls = #(
      process.new_subject(),
      process.new_subject(),
      process.new_subject(),
      process.new_subject(),
    )
    let reports = process.new_subject()
    let outer =
      weft.new_prepared([
        weft.managed(fn(_ledger) {
          let original =
            history_on(
              f,
              j.BeforeCloseAck,
              controls.0,
              controls.1,
              controls.2,
              controls.3,
            )
          process.send(reports, #(process.self(), original))
          process.receive(process.new_subject(), 6000)
          |> result.replace_error(j.Uncertain)
        }),
      ])
      |> weft.deadline(8000)
      |> weft.start_detached
    let outer_watch = process.monitor(weft.scope_pid(outer))
    let #(coordinator, original) = receive(reports)
    let inner_watch = process.monitor(weft.scope_pid(original.run))
    let _worker = receive(original.workers)
    let _ready = receive(original.ready)
    process.kill(coordinator)
    let #(writer, permit) = checkpoint(original.events, j.BeforeCloseAck)
    let watch = process.monitor(writer)
    assert process.is_alive(writer)
    process.send(permit, j.Proceed)
    actual_close(original.events, writer)
    assert normal_down(watch) == Ok(Nil)
    assert normal_down(inner_watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Crashed(..)) = weft.pull(outer, 1000)
      as "Coordinator loss supplies no recovered business observation."
    assert weft.pull(outer, 1000) == weft.AllDelivered
    assert normal_down(outer_watch) == Ok(Nil)
  })
}

fn node() {
  let assert Ok(started) =
    actor.new(Empty)
    |> actor.on_message(handle_node)
    |> actor.unlinked
    |> actor.start
    as "Actual fixture permanent parent actor."
  started
}

fn handle_node(state: NodeState, message: NodeMessage) {
  case message {
    Park(input, probe, reply) -> {
      let assert Empty = state as "One original writer per fixture parent."
      let assert Ok(original) = j.park_fresh_observed(input, probe)
        as "Original parent itself creates linked writer."
      process.send(reply, original)
      actor.continue(Original(original))
    }
    Initialise(reply) -> {
      let assert Original(original) = state
        as "Original ACK retained before SQL."
      process.send(reply, j.initialise_fresh(original))
      actor.continue(state)
    }
    Release(reply) -> {
      let assert Original(original) = state
        as "Release names exact retained writer."
      process.send(reply, j.release_fresh(original))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn park(
  node: process.Subject(NodeMessage),
  f: Fixture,
  probe: j.Probe,
) -> j.ParkedFresh {
  let reply = process.new_subject()
  process.send(node, Park(fresh_input(f), probe, reply))
  receive(reply)
}

fn initialise(node: process.Subject(NodeMessage)) -> j.Store {
  let reply = process.new_subject()
  process.send(node, Initialise(reply))
  let assert Ok(ready) = receive(reply) as "Original committed LiveStore."
  j.live_store(ready)
}

fn fresh_input(f: Fixture) -> j.FreshInput {
  let assert Ok(input) =
    j.fresh_input(
      f.path,
      f.binding,
      f.contract,
      f.incarnation,
      f.limits,
      f.clock,
      f.profiles,
    )
    as "Immutable checked live originals."
  input
}

fn recovery_input(f: Fixture) -> j.RecoveryInput {
  let assert Ok(input) =
    j.recovery_input(f.path, f.binding, f.contract, f.limits, f.profiles)
    as "History selection supplies no Clock or incarnation."
  input
}

fn legacy(f: Fixture) -> j.Store {
  let assert Ok(store) =
    j.fresh(
      f.path,
      f.binding,
      f.contract,
      f.incarnation,
      f.limits,
      f.clock,
      f.profiles,
    )
    as "Unchanged legacy constructor seeds actual SQL."
  store
}

fn history(f: Fixture, stage: j.Checkpoint) -> Running {
  let workers = process.new_subject()
  let ready = process.new_subject()
  let finish = process.new_subject()
  let events = process.new_subject()
  history_on(f, stage, workers, ready, finish, events)
}

fn history_on(
  f: Fixture,
  stage: j.Checkpoint,
  workers: process.Subject(process.Pid),
  ready: process.Subject(j.OwnedRecovery),
  finish: process.Subject(process.Subject(Nil)),
  events: process.Subject(j.OwnershipEvent),
) -> Running {
  let input = recovery_input(f)
  let run =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let finish_here = process.new_subject()
        process.send(finish, finish_here)
        process.send(workers, process.self())
        use original <- result.try(j.recover_owned_observed(
          input,
          ledger,
          j.Observed(stage, events),
        ))
        process.send(ready, original)
        use Nil <- result.try(
          process.receive(finish_here, 6000)
          |> result.replace_error(j.Uncertain),
        )
        j.release_owned(original)
      }),
    ])
    |> weft.deadline(8000)
    |> weft.start_detached
  Running(
    run,
    process.monitor(weft.scope_pid(run)),
    workers,
    ready,
    finish,
    events,
  )
}

fn finish(running: Running) -> Nil {
  process.send(receive(running.finish), Nil)
}

fn finish_run(running: Running) -> Nil {
  assert weft.pull(running.run, 1000) == weft.AllDelivered
  assert normal_down(running.scope_watch) == Ok(Nil)
}

fn checkpoint(
  events: process.Subject(j.OwnershipEvent),
  stage: j.Checkpoint,
) -> #(process.Pid, process.Subject(j.Permit)) {
  let assert j.CheckpointReached(actual, writer, permit) = receive(events)
    as "Exact original selected custody checkpoint."
  assert actual == stage
  #(writer, permit)
}

fn actual_close(
  events: process.Subject(j.OwnershipEvent),
  writer: process.Pid,
) -> Nil {
  let assert j.ConnectionClosed(original, outcome) = receive(events)
    as "Actual SQLite close, separate from ACK or normal DOWN."
  assert original == writer
  assert outcome == Ok(Nil)
}

fn receive(subject: process.Subject(a)) -> a {
  let assert Ok(value) = process.receive(subject, 6000)
    as "Bounded original fixture reply."
  value
}

fn normal_down(watch: process.Monitor) -> Result(Nil, Nil) {
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Nil)
      }
    })
    |> process.selector_receive(1000)
    |> result.unwrap(Error(Nil))
  process.demonitor_process(watch)
  outcome
}

fn assert_down(watch: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "Exact original writer DOWN before fixture teardown."
  process.demonitor_process(watch)
}

fn scalar(path: String, text: String) -> Int {
  let assert Ok(connection) = sqlight.open(path)
    as "Actual independent SQL reader."
  let assert Ok([value]) =
    sqlight.query(
      text,
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
    as "One actual SQL scalar."
  assert sqlight.close(connection) == Ok(Nil)
  value
}

fn mutate(path: String, text: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
    as "Actual independent corrupt metadata fixture."
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn store_bytes(f: Fixture) -> BitArray {
  let assert Ok(bytes) = simplifile.read_bits(f.path)
    as "Original closed SQL bytes."
  bytes
}

fn digest_of(bytes: BitArray) -> g.Digest {
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "Canonical fixture digest."
  digest
}

fn fixture(run: fn(Fixture) -> Nil) -> Nil {
  let directory =
    "/private/tmp/loom-owned-lsp-"
    <> bit_array.base16_encode(crypto.strong_random_bytes(8))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "Unique actual SQLite fixture."
  let generator = ids.generator(clock.fixed(1000), 800)
  let #(session, generator) = ids.mint_session(generator)
  let #(incarnation, _) = ids.mint_entry(generator)
  let assert Ok(selector) = workspace.selector("executor", "workspace")
    as "Complete fixture selector."
  let assert Ok(selected) = workspace.registered_binding(selector, 1, 1)
    as "Original authority epochs."
  let scope = workspace.scope(session, selected)
  let enrollment = digest_of(<<1>>)
  let contract = digest_of(<<2>>)
  let assert Ok(key) = g.key(scope, contract, 1)
    as "Exact original generation key."
  let binding = j.binding(key, enrollment)
  let assert Ok(limits) = j.limits(32, 64_000_000)
    as "Immutable reduced fixture ceilings."
  let assert Ok(profiles) =
    id.enrolled_profiles(scope, enrollment, [id.Profile("gleam", "/workspace")])
    as "Original enrolled profile."
  let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000001")
    as "Original trusted fixture era."
  let clock = j.Clock(era, fn() { -1000 }, fn() { <<1:size(256)>> })
  run(Fixture(
    directory <> "/lsp.db",
    directory,
    binding,
    contract,
    incarnation,
    limits,
    clock,
    profiles,
    scope,
    enrollment,
  ))
  assert simplifile.delete(directory) == Ok(Nil)
}

fn identity(rig: Fixture, number: Int, request: wire.Request) {
  let generator = ids.generator(clock.fixed(1000), number)
  let #(operation, generator) = ids.mint_op(generator)
  let #(request_id, _) = ids.mint_entry(generator)
  let assert Ok(step) = workspace.step("lsp.query")
    as "The physical step is valid."
  let assert Ok(input) = wire.semantic_input(request)
    as "The semantic input is canonical."
  let #(_, digest, _) = id.input_fields(input)
  let assert Ok(system) =
    remote_tool.system_child(workspace.scope_fields(rig.scope).0, "lsp", number)
    as "The original system child is retained."
  let assert Ok(tool) =
    remote_tool.key(
      workspace.scope_fields(rig.scope).0,
      operation,
      "lsp.query",
      0,
      string.repeat("0", 64),
      request_id,
    )
    as "The tool retains the real original invocation."
  let assert Ok(origin) =
    remote_tool.tool_child(
      tool,
      remote_tool.AdmittedCapability(
        "lsp.query",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
    as "Ordinary finite queries use admitted tool provenance."
  let assert Ok(child) =
    id.original_child_ref(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      digest,
    )
    as "The exact controlled child retains every coordinate."
  let assert Ok(parent) = id.parent_control(child)
    as "The original control reference is complete."
  let assert Ok(capture) =
    id.lsp_capture(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      input,
      parent,
      rig.enrollment,
      rig.contract,
    )
    as "The finite original is valid."
  let assert Ok(lease_input) = j.lease_input("gleam", "/workspace", request_id)
    as "The complete lease input names its original incarnation."
  let assert Ok(lease) =
    id.lsp_service_key(
      system,
      rig.scope,
      operation,
      step,
      request_id,
      digest_of(lease_input),
      rig.enrollment,
      rig.contract,
    )
    as "The session lease has its independent exact input."
  #(capture, lease, lease_input)
}

fn timed(
  capture: id.FiniteCapture,
  anchor: id.FiniteAnchor,
  remaining: Int,
) -> id.LspInvocation {
  let parent = id.capture_parent(capture)
  let assert Ok(control) =
    id.verify_parent_control(capture, parent, remaining, 0, None)
    as "The actual original parent supplies its remaining interval."
  let assert Ok(digest) = wire.parent_digest(parent)
    as "The canonical parent digest is retained."
  let assert Ok(proposal) = id.finite_timing_proposal(anchor, control, digest)
    as "The original proposal uses the retained anchor."
  let assert Ok(invocation) = id.lsp_invocation(capture, proposal, digest)
    as "The timing is fixed without an owner absolute timestamp."
  invocation
}
