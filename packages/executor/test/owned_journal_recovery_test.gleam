//// Original SQLite owner controls for restricted managed history recovery.
////
//// Every writer PID comes from its own resource-free checkpoint. The tests
//// monitor those originals before permitting adoption, SQL activation or close.
//// Weft owns all request workers and coordinators; no replacement writer,
//// callback factory or hand-maintained cancellation process is used.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/service_input
import core/command
import core/ids
import core/remote_tool
import core/workspace as cw
import executor/remote/admission
import executor/remote/compile_completion
import executor/remote/identity
import executor/remote/journal as native
import executor/remote/launch_completion
import executor/remote/resource_journal as resource
import executor/remote/workspace_journal as workspace
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft

type Family {
  Native
  Workspace
  Resource
}

type Recovered {
  NativeOwner(native.OwnedRecovery)
  WorkspaceOwner(workspace.OwnedRecovery)
  ResourceOwner(resource.OwnedRecovery)
}

type Fixture {
  Fixture(
    directory: String,
    native_path: String,
    workspace_path: String,
    resource_path: String,
    original: resource.Input,
  )
}

type Running {
  Running(
    run: weft.Detached(Nil, Nil),
    scope_watch: process.Monitor,
    workers: process.Subject(process.Pid),
    ready: process.Subject(Recovered),
    finish: process.Subject(process.Subject(Nil)),
    probes: process.Subject(native.RecoveryObservation),
  )
}

/// Retained results and exact receipts use shared real SQL transactions.
pub fn retained_results_receipts_and_legacy_behavior_test() {
  fixture(fn(f) {
    let native_input = native_input(f)
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use original <- result.try(
            native.recover_owned(native_input, ledger)
            |> result.replace_error(Nil),
          )
          let assert Ok(items) =
            native.payloads_owned(original, native_key(), digest(1))
            as "Original retained payloads."
          assert items == []
          assert native.confirm_owner_receipt_owned(
              original,
              native_key(),
              digest(1),
              digest(3),
            )
            == Error(native.Rejected(admission.ResultConflict))
          let assert Ok(receipt) =
            native.confirm_owner_receipt_owned(
              original,
              native_key(),
              digest(1),
              digest(2),
            )
            as "Exact original owner receipt."
          assert receipt.effect == admission.NoLaunch
          let assert Ok(evidence) =
            native.inspect_owned(original, native_key(), digest(1))
            as "Exact committed original receipt readback."
          assert admission.phase(evidence)
            == admission.Refused(digest(2), admission.ReceiptDurable)
          native.release_owned(original) |> result.replace_error(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]

    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use original <- result.try(
            workspace.recover_owned(
              f.workspace_path,
              scope(),
              workspace_limits(),
              ledger,
            )
            |> result.replace_error(Nil),
          )
          assert workspace.inspect_owned(original, invocation())
            == Ok(workspace.Finished(completed_read()))
          assert workspace.acknowledge_owned(original, invocation(), <<
              0:size(256),
            >>)
            == Error(workspace.Conflict)
          assert workspace.acknowledge_owned(
              original,
              invocation(),
              workspace.digest(completed_read()),
            )
            == Ok(workspace.Acknowledged(workspace.digest(completed_read())))
          workspace.release_owned(original) |> result.replace_error(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]

    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use original <- result.try(
            resource.recover_owned(
              f.resource_path,
              enrolled(),
              resource_limits(),
              native_input,
              ledger,
            )
            |> result.replace_error(Nil),
          )
          let assert Ok(resource.CompileRetained(
            retained,
            resource.ReceiptPending,
          )) = resource.inspect_compile_owned(original, f.original)
            as "Full retained Compile completion."
          assert resource.acknowledge_compile_owned(
              original,
              f.original,
              digest(3),
            )
            == Error(resource.Conflict)
          let hash = resource.retained_compile_digest(retained)
          let assert Ok(resource.CompileRetained(
            _,
            resource.ReceiptAcknowledged,
          )) = resource.acknowledge_compile_owned(original, f.original, hash)
            as "Exact original Compile receipt."
          let launch = launched(f.original.key)
          let assert Ok(resource.LaunchRetained(
            retained,
            resource.ReceiptPending,
          )) = resource.inspect_launch_owned(original, launch)
            as "Canonical retained original Launch refusal."
          assert resource.acknowledge_launch_owned(original, launch, digest(3))
            == Error(resource.Conflict)
          let expected = resource.retained_launch_digest(retained)
          assert resource.acknowledge_launch_owned(original, launch, expected)
            == Ok(resource.LaunchRetained(
              retained,
              resource.ReceiptAcknowledged,
            ))
          assert resource.inspect_launch_owned(original, launch)
            == Ok(resource.LaunchRetained(
              retained,
              resource.ReceiptAcknowledged,
            ))
          resource.release_owned(original) |> result.replace_error(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]

    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          use n <- result.try(
            native.recover_owned(native_input, ledger)
            |> result.replace_error(Nil),
          )
          let assert Ok(evidence) =
            native.inspect_owned(n, native_key(), digest(1))
            as "Reopened exact native receipt is durable."
          assert admission.phase(evidence)
            == admission.Refused(digest(2), admission.ReceiptDurable)
          use Nil <- result.try(
            native.release_owned(n) |> result.replace_error(Nil),
          )
          use w <- result.try(
            workspace.recover_owned(
              f.workspace_path,
              scope(),
              workspace_limits(),
              ledger,
            )
            |> result.replace_error(Nil),
          )
          assert workspace.inspect_owned(w, invocation())
            == Ok(workspace.Acknowledged(workspace.digest(completed_read())))
          use Nil <- result.try(
            workspace.release_owned(w) |> result.replace_error(Nil),
          )
          use r <- result.try(
            resource.recover_owned(
              f.resource_path,
              enrolled(),
              resource_limits(),
              native_input,
              ledger,
            )
            |> result.replace_error(Nil),
          )
          let assert Ok(resource.CompileRetained(
            _,
            resource.ReceiptAcknowledged,
          )) = resource.inspect_compile_owned(r, f.original)
            as "Reopened original Compile receipt."
          let assert Ok(resource.LaunchRetained(_, resource.ReceiptAcknowledged)) =
            resource.inspect_launch_owned(r, launched(f.original.key))
            as "Reopened original Launch receipt."
          resource.release_owned(r) |> result.replace_error(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]

    // Legacy release retains its previous Closed and uncertain behavior.
    let assert Ok(legacy) =
      native.recover(f.native_path, native_scope(), capacity())
      as "Unchanged ordinary recovery."
    assert native.release(legacy) == Ok(Nil)

    // Legacy ACK precedes DOWN, so its immediate retry can remain uncertain.
    case native.release(legacy) {
      Ok(Nil) | Error(native.Uncertain) -> Nil
      Error(_) ->
        panic as "Legacy release retains only its existing closed or uncertain outcomes."
    }
  })
}

/// A refused adoption opens no DB, even when the original requester dies first.
pub fn worker_death_before_adoption_refuses_without_open_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(f) {
      let before = store_bytes(f, family)
      let started = start(f, family)
      let worker = receive_worker(started)
      let first = checkpoint(started, native.BeforeAdopt)
      let watch = process.monitor(first.owner)
      process.kill(worker)

      // The original scope must seal worker loss before this actor publishes.
      let assert weft.PulledOutcome(weft.Crashed(..)) =
        weft.pull(started.run, 1000)
        as "Original killed request worker."
      process.send(first.permit, native.Proceed)
      assert normal_down(watch) == Ok(Nil)
      finish_run(started)
      assert store_bytes(f, family) == before
      assert process.is_alive(first.owner) == False
    })
  })
}

/// Adopted resource-free actors close after their initializer's caller disappears.
pub fn worker_death_before_ack_opens_no_sql_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(f) {
      let before = store_bytes(f, family)
      let started = start(f, family)
      let worker = receive_worker(started)
      let first = checkpoint(started, native.BeforeAdopt)
      process.send(first.permit, native.Proceed)
      let ack = checkpoint(started, native.BeforeStartAck)
      assert ack.owner == first.owner
      let watch = process.monitor(first.owner)
      process.kill(worker)
      process.send(ack.permit, native.Proceed)
      let exit = checkpoint(started, native.AfterCloseBeforeExit)
      assert exit.owner == first.owner
      assert store_bytes(f, family) == before
      process.send(exit.permit, native.Proceed)
      assert normal_down(watch) == Ok(Nil)
      let assert weft.PulledOutcome(weft.Crashed(..)) =
        weft.pull(started.run, 1000)
        as "Original worker loss stays uncertain."
      finish_run(started)
    })
  })
}

/// Real recovery blocked by another SQL writer remains owned through cancellation.
pub fn blocked_begin_cancellation_joins_original_writers_test() {
  list.each([Native, Workspace], fn(family) {
    fixture(fn(f) {
      let path = case family {
        Native -> f.native_path
        Workspace -> f.workspace_path
        Resource -> f.resource_path
      }
      let assert Ok(lock) = sqlight.open(path)
        as "Independent original SQL blocker."
      assert sqlight.exec("BEGIN IMMEDIATE", lock) == Ok(Nil)
      let started = start(f, family)
      let _ = receive_worker(started)
      permit(started, native.BeforeAdopt)
      permit(started, native.BeforeStartAck)
      let opened = checkpoint(started, native.BeforeSqlOpen)
      let watch = process.monitor(opened.owner)
      process.send(opened.permit, native.Proceed)
      weft.cancel_detached(started.run)

      // The existing SQLite busy timeout must fail setup while this lock is held.
      // Cancellation remains queued behind that actual original initialization turn.
      let closing = failed_setup_checkpoint(started)
      assert closing.owner == opened.owner
      assert weft.pull(started.run, 0) == weft.NotYet
      assert process.is_alive(opened.owner)
      assert process.receive(started.ready, 0) == Error(Nil)
      assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
      assert sqlight.close(lock) == Ok(Nil)
      process.send(closing.permit, native.Proceed)
      permit(started, native.AfterCloseBeforeExit)
      assert normal_down(watch) == Ok(Nil)
      let assert weft.PulledOutcome(weft.Abandoned(..)) =
        weft.pull(started.run, 1000)
        as "Cancellation ends only observation."
      finish_run(started)
    })
  })
}

/// Original resource DOWN precedes automatic native close on ordinary release.
pub fn resource_release_proves_reverse_order_and_waits_native_down_test() {
  fixture(fn(f) {
    let started = start(f, Resource)
    let _ = receive_worker(started)
    let #(parent, child) = ready_resource(started)
    let parent_watch = process.monitor(parent)
    let child_watch = process.monitor(child)
    finish(started)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == parent
    assert process.is_alive(child)
    process.send(closing.permit, native.Proceed)
    let stopped = checkpoint(started, native.AfterCloseBeforeExit)
    assert stopped.owner == parent
    assert process.is_alive(child)
    assert process.receive(started.probes, 0) == Error(Nil)
    process.send(stopped.permit, native.Proceed)
    assert normal_down(parent_watch) == Ok(Nil)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == child

    // Native automatic cancellation needs no second racy release ACK.
    process.send(closing.permit, native.SuppressReply)
    let stopped = checkpoint(started, native.AfterCloseBeforeExit)
    assert stopped.owner == child
    assert weft.pull(started.run, 0) == weft.NotYet
    process.send(stopped.permit, native.Proceed)
    assert normal_down(child_watch) == Ok(Nil)
    assert weft.pull(started.run, 1000)
      == weft.PulledOutcome(weft.Completed(0, Nil))
    finish_run(started)
  })
}

/// A killed worker cannot cancel native beside its still-live resource parent.
pub fn resource_worker_loss_preserves_original_reverse_order_test() {
  fixture(fn(f) {
    let started = start(f, Resource)
    let worker = receive_worker(started)
    let #(parent, child) = ready_resource(started)
    let parent_watch = process.monitor(parent)
    let child_watch = process.monitor(child)
    process.kill(worker)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == parent
    assert process.is_alive(child)
    assert process.receive(started.probes, 0) == Error(Nil)
    process.send(closing.permit, native.Proceed)
    let stopped = checkpoint(started, native.AfterCloseBeforeExit)
    assert stopped.owner == parent
    process.send(stopped.permit, native.Proceed)
    assert normal_down(parent_watch) == Ok(Nil)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == child
    process.send(closing.permit, native.Proceed)
    permit(started, native.AfterCloseBeforeExit)
    assert normal_down(child_watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Crashed(..)) =
      weft.pull(started.run, 1000)
      as "Lost worker grants no history result."
    finish_run(started)
  })
}

/// SQL close ACK loss remains uncertain even though the managed owner joins normally.
pub fn lost_close_reply_does_not_become_closed_success_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(f) {
      let started = start(f, family)
      let _ = receive_worker(started)
      let #(owner, child) = case family {
        Native | Workspace -> #(ready_single(started), None)
        Resource -> {
          let #(parent, child) = ready_resource(started)
          #(parent, Some(child))
        }
      }
      let watch = process.monitor(owner)
      finish(started)
      let closing = checkpoint(started, native.BeforeCloseReply)
      process.send(closing.permit, native.SuppressReply)
      permit(started, native.AfterCloseBeforeExit)
      assert normal_down(watch) == Ok(Nil)
      case child {
        None -> Nil
        Some(child) -> {
          let watch = process.monitor(child)
          let closing = checkpoint(started, native.BeforeCloseReply)
          assert closing.owner == child
          process.send(closing.permit, native.Proceed)
          permit(started, native.AfterCloseBeforeExit)
          assert normal_down(watch) == Ok(Nil)
        }
      }
      assert weft.pull(started.run, 1000)
        == weft.PulledOutcome(weft.Failed(0, Nil))
      finish_run(started)
    })
  })
}

/// The labelled synthetic refusal preserves real SQL custody and loses drain proof.
pub fn synthetic_close_refusal_is_abnormal_not_a_release_witness_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(f) {
      let started = start(f, family)
      let _ = receive_worker(started)
      let owners = case family {
        Native | Workspace -> #(ready_single(started), None)
        Resource -> {
          let #(parent, child) = ready_resource(started)
          #(parent, Some(child))
        }
      }
      let watch = process.monitor(owners.0)
      finish(started)
      let closing = checkpoint(started, native.BeforeCloseReply)
      assert closing.owner == owners.0
      process.send(closing.permit, native.RefuseClose)
      assert normal_down(watch) == Error(Nil)
      case owners.1 {
        None -> Nil
        Some(child) -> {
          let closing = checkpoint(started, native.BeforeCloseReply)
          assert closing.owner == child
          process.send(closing.permit, native.Proceed)
          permit(started, native.AfterCloseBeforeExit)
        }
      }
      let assert weft.PulledOutcome(weft.DrainProofLost(..)) =
        weft.pull(started.run, 1000)
        as "Ignored close errors cannot prove drain."
      let _ = weft.pull(started.run, 1000)
      assert normal_down(started.scope_watch) == Error(Nil)
    })
  })
}

/// Unavailable original metadata is refused without creating a new database.
pub fn missing_and_changed_binding_never_expose_owned_history_test() {
  fixture(fn(f) {
    let missing = f.directory <> "/absent.sqlite"
    let assert Ok(input) =
      native.recovery_input(missing, native_scope(), capacity())
      as "Checked metadata creates no store."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert native.recover_owned(input, ledger) == Error(native.Missing)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
    assert simplifile.exists(missing, False) == Ok(False)
    let assert Ok(wrong) = admission.capacity(5) as "Changed original capacity."
    let assert Ok(input) =
      native.recovery_input(f.native_path, native_scope(), wrong)
      as "Different immutable recovery metadata."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert native.recover_owned(input, ledger)
            == Error(native.BindingMismatch)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
  })
}

/// An enclosing request coordinator can die without flattening original custody.
pub fn coordinator_death_preserves_resource_before_native_test() {
  fixture(fn(f) {
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
            start_on(
              f,
              Resource,
              controls.0,
              controls.1,
              controls.2,
              controls.3,
            )
          process.send(reports, #(process.self(), original))
          let held = process.new_subject()
          process.receive(held, 1000) |> result.replace_error(Nil)
        }),
      ])
      |> weft.deadline(3000)
      |> weft.start_detached
    let outer_watch = process.monitor(weft.scope_pid(outer))
    let assert Ok(#(coordinator, original)) = process.receive(reports, 1000)
      as "The original request coordinator starts its own linked managed run."
    let started =
      Running(
        ..original,
        scope_watch: process.monitor(weft.scope_pid(original.run)),
      )
    let _ = receive_worker(started)
    let #(parent, child) = ready_resource(started)
    let parent_watch = process.monitor(parent)
    let child_watch = process.monitor(child)
    process.kill(coordinator)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == parent
    assert process.is_alive(child)
    assert process.receive(started.probes, 0) == Error(Nil)
    process.send(closing.permit, native.Proceed)
    let stopped = checkpoint(started, native.AfterCloseBeforeExit)
    assert stopped.owner == parent
    process.send(stopped.permit, native.Proceed)
    assert normal_down(parent_watch) == Ok(Nil)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == child
    process.send(closing.permit, native.Proceed)
    permit(started, native.AfterCloseBeforeExit)
    assert normal_down(child_watch) == Ok(Nil)
    assert normal_down(started.scope_watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Crashed(..)) = weft.pull(outer, 1000)
      as "Dead coordinator returns no execution or recovery result."
    assert weft.pull(outer, 1000) == weft.AllDelivered
    assert normal_down(outer_watch) == Ok(Nil)
  })
}

/// Loss while SQL activation or validated reply is pending leaves the original owned.
pub fn worker_loss_during_owned_initialisation_test() {
  list.each([native.BeforeSqlOpen, native.BeforeInitialiseReply], fn(boundary) {
    list.each([Native, Workspace], fn(family) {
      fixture(fn(f) {
        let started = start(f, family)
        let worker = receive_worker(started)
        permit(started, native.BeforeAdopt)
        permit(started, native.BeforeStartAck)
        case boundary {
          native.BeforeInitialiseReply -> permit(started, native.BeforeSqlOpen)
          native.BeforeSqlOpen -> Nil
          native.BeforeAdopt
          | native.BeforeStartAck
          | native.BeforeCloseReply
          | native.AfterCloseBeforeExit ->
            panic as "Closed initialization test table."
        }
        let pending = checkpoint(started, boundary)
        let watch = process.monitor(pending.owner)
        process.kill(worker)
        process.send(pending.permit, native.Proceed)
        case boundary {
          native.BeforeSqlOpen -> permit(started, native.BeforeInitialiseReply)
          native.BeforeInitialiseReply -> Nil
          native.BeforeAdopt
          | native.BeforeStartAck
          | native.BeforeCloseReply
          | native.AfterCloseBeforeExit ->
            panic as "Closed initialization test table."
        }
        permit(started, native.BeforeCloseReply)
        permit(started, native.AfterCloseBeforeExit)
        assert normal_down(watch) == Ok(Nil)
        assert process.receive(started.ready, 0) == Error(Nil)
        let assert weft.PulledOutcome(weft.Crashed(..)) =
          weft.pull(started.run, 1000)
          as "No replacement history handle appears after caller loss."
        finish_run(started)
      })
    })
  })
}

/// Missing native and changed resource metadata drain the actual partial graph.
pub fn resource_acquisition_failure_drains_originals_test() {
  fixture(fn(f) {
    let before = store_bytes(f, Resource)
    let missing = f.directory <> "/absent-native.sqlite"
    let assert Ok(input) =
      native.recovery_input(missing, native_scope(), capacity())
      as "Checked absent native grants no database."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert resource.recover_owned(
              f.resource_path,
              enrolled(),
              resource_limits(),
              input,
              ledger,
            )
            == Error(resource.Uncertain)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
    assert simplifile.exists(missing, False) == Ok(False)
    assert store_bytes(f, Resource) == before

    let assert Ok(changed) = resource.limits(5, 30_000_000)
      as "Different immutable resource limits."
    let outcomes =
      weft.new_prepared([
        weft.managed(fn(ledger) {
          assert resource.recover_owned(
              f.resource_path,
              enrolled(),
              changed,
              native_input(f),
              ledger,
            )
            == Error(resource.BindingMismatch)
          Ok(Nil)
        }),
      ])
      |> weft.start
    assert outcomes == [weft.Completed(0, Nil)]
    assert store_bytes(f, Resource) == before
  })
}

/// A real blocked resource transaction holds native custody until resource joins.
pub fn blocked_resource_begin_cancellation_preserves_order_test() {
  fixture(fn(f) {
    let assert Ok(lock) = sqlight.open(f.resource_path)
      as "Independent original resource writer blocker."
    assert sqlight.exec("BEGIN IMMEDIATE", lock) == Ok(Nil)
    let started = start(f, Resource)
    let _ = receive_worker(started)
    let #(parent, child, opening) = resource_opening(started)
    let parent_watch = process.monitor(parent)
    let child_watch = process.monitor(child)
    process.send(opening.permit, native.Proceed)
    weft.cancel_detached(started.run)

    // The exact resource setup fails under the still-held real SQL writer lock.
    // Native remains beneath it until resource cleanup and original DOWN finish.
    let closing = failed_setup_checkpoint(started)
    assert closing.owner == parent
    assert weft.pull(started.run, 0) == weft.NotYet
    assert process.is_alive(parent)
    assert process.is_alive(child)
    assert process.receive(started.ready, 0) == Error(Nil)
    assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
    assert sqlight.close(lock) == Ok(Nil)
    process.send(closing.permit, native.Proceed)
    let stopped = checkpoint(started, native.AfterCloseBeforeExit)
    assert stopped.owner == parent
    assert process.is_alive(child)
    assert process.receive(started.probes, 0) == Error(Nil)
    process.send(stopped.permit, native.Proceed)
    assert normal_down(parent_watch) == Ok(Nil)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == child
    process.send(closing.permit, native.Proceed)
    permit(started, native.AfterCloseBeforeExit)
    assert normal_down(child_watch) == Ok(Nil)
    let assert weft.PulledOutcome(weft.Abandoned(..)) =
      weft.pull(started.run, 1000)
      as "Cancellation returns no recovered handle or new execution claim."
    finish_run(started)
  })
}

/// A lost resource initialization reply never exposes a handle after cancellation.
pub fn lost_initialisation_reply_retains_original_graph_test() {
  fixture(fn(f) {
    let started = start(f, Resource)
    let _ = receive_worker(started)
    let #(parent, child, opening) = resource_opening(started)
    let parent_watch = process.monitor(parent)
    let child_watch = process.monitor(child)
    process.send(opening.permit, native.Proceed)
    let reply = checkpoint(started, native.BeforeInitialiseReply)
    assert reply.owner == parent
    process.send(reply.permit, native.SuppressReply)
    weft.cancel_detached(started.run)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == parent
    process.send(closing.permit, native.Proceed)
    permit(started, native.AfterCloseBeforeExit)
    assert normal_down(parent_watch) == Ok(Nil)
    let closing = checkpoint(started, native.BeforeCloseReply)
    assert closing.owner == child
    process.send(closing.permit, native.Proceed)
    permit(started, native.AfterCloseBeforeExit)
    assert normal_down(child_watch) == Ok(Nil)
    assert process.receive(started.ready, 0) == Error(Nil)
    let assert weft.PulledOutcome(weft.Abandoned(..)) =
      weft.pull(started.run, 1000)
      as "Reply loss and cancellation mint no replacement history authority."
    finish_run(started)
  })
}

/// Failed setup close retains the opened original for abnormal cleanup.
pub fn setup_close_failure_never_proves_normal_release_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(f) {
      let probes = process.new_subject()
      let run =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            let probe = native.Observed(probes)
            case family {
              Native -> {
                let assert Ok(changed) = admission.capacity(5)
                  as "Changed native metadata reaches actual setup refusal."
                let assert Ok(input) =
                  native.recovery_input(f.native_path, native_scope(), changed)
                  as "Checked changed native metadata."
                assert native.recover_owned_observed(input, ledger, None, probe)
                  == Error(native.BindingMismatch)
              }
              Workspace -> {
                let assert Ok(changed) = workspace.limits(5, 100_000_000)
                  as "Changed workspace metadata reaches actual setup refusal."
                assert workspace.recover_owned_observed(
                    f.workspace_path,
                    scope(),
                    changed,
                    ledger,
                    probe,
                  )
                  == Error(workspace.BindingMismatch)
              }
              Resource -> {
                let assert Ok(changed) = resource.limits(5, 30_000_000)
                  as "Changed resource metadata reaches actual setup refusal."
                assert resource.recover_owned_observed(
                    f.resource_path,
                    enrolled(),
                    changed,
                    native_input(f),
                    ledger,
                    probe,
                  )
                  == Error(resource.BindingMismatch)
              }
            }
            Ok(Nil)
          }),
        ])
        |> weft.deadline(3000)
        |> weft.start_detached
      let started =
        Running(
          run,
          process.monitor(weft.scope_pid(run)),
          process.new_subject(),
          process.new_subject(),
          process.new_subject(),
          probes,
        )
      let first = checkpoint(started, native.BeforeAdopt)
      let watch = process.monitor(first.owner)
      process.send(first.permit, native.Proceed)
      permit(started, native.BeforeStartAck)
      let child = case family {
        Native | Workspace -> None
        Resource -> {
          let second = checkpoint(started, native.BeforeAdopt)
          process.send(second.permit, native.Proceed)
          permit(started, native.BeforeStartAck)
          permit(started, native.BeforeSqlOpen)
          permit(started, native.BeforeInitialiseReply)
          Some(second.owner)
        }
      }
      permit(started, native.BeforeSqlOpen)
      let closing = checkpoint(started, native.BeforeCloseReply)
      assert closing.owner == first.owner
      process.send(closing.permit, native.RefuseClose)
      assert normal_down(watch) == Error(Nil)
      case child {
        None -> Nil
        Some(original) -> {
          let watch = process.monitor(original)
          let closing = checkpoint(started, native.BeforeCloseReply)
          assert closing.owner == original
          process.send(closing.permit, native.Proceed)
          permit(started, native.AfterCloseBeforeExit)
          assert normal_down(watch) == Ok(Nil)
        }
      }
      let assert weft.PulledOutcome(weft.DrainProofLost(..)) =
        weft.pull(run, 1000)
        as "Setup close refusal cannot be sealed as successful drain."
      assert weft.pull(run, 1000) == weft.AllDelivered
      assert normal_down(started.scope_watch) == Error(Nil)

      // Reopen only after original DOWN and actual managed aggregate teardown.
      let outcomes =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            use recovered <- result.try(recover(
              f,
              family,
              ledger,
              native.Unobserved,
            ))
            release(recovered)
          }),
        ])
        |> weft.start
      assert outcomes == [weft.Completed(0, Nil)]
    })
  })
}

fn start(f: Fixture, family: Family) -> Running {
  let workers = process.new_subject()
  let ready = process.new_subject()
  let finish = process.new_subject()
  let probes = process.new_subject()
  start_on(f, family, workers, ready, finish, probes)
}

fn start_on(
  f: Fixture,
  family: Family,
  workers: process.Subject(process.Pid),
  ready: process.Subject(Recovered),
  finish: process.Subject(process.Subject(Nil)),
  probes: process.Subject(native.RecoveryObservation),
) -> Running {
  let run =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let permit_finish = process.new_subject()
        process.send(finish, permit_finish)
        process.send(workers, process.self())
        use original <- result.try(recover(
          f,
          family,
          ledger,
          native.Observed(probes),
        ))
        process.send(ready, original)
        let assert Ok(Nil) = process.receive(permit_finish, 1000)
          as "Test permits orderly original close."
        release(original)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  Running(
    run,
    process.monitor(weft.scope_pid(run)),
    workers,
    ready,
    finish,
    probes,
  )
}

fn recover(
  f: Fixture,
  family: Family,
  ledger: weft.Ledger,
  probe: native.RecoveryProbe,
) -> Result(Recovered, Nil) {
  case family {
    Native ->
      native.recover_owned_observed(native_input(f), ledger, None, probe)
      |> result.map(NativeOwner)
      |> result.replace_error(Nil)
    Workspace ->
      workspace.recover_owned_observed(
        f.workspace_path,
        scope(),
        workspace_limits(),
        ledger,
        probe,
      )
      |> result.map(WorkspaceOwner)
      |> result.replace_error(Nil)
    Resource ->
      resource.recover_owned_observed(
        f.resource_path,
        enrolled(),
        resource_limits(),
        native_input(f),
        ledger,
        probe,
      )
      |> result.map(ResourceOwner)
      |> result.replace_error(Nil)
  }
}

fn release(original: Recovered) -> Result(Nil, Nil) {
  case original {
    NativeOwner(original) ->
      native.release_owned(original) |> result.replace_error(Nil)
    WorkspaceOwner(original) ->
      workspace.release_owned(original) |> result.replace_error(Nil)
    ResourceOwner(original) ->
      resource.release_owned(original) |> result.replace_error(Nil)
  }
}

fn finish(started: Running) -> Nil {
  let assert Ok(subject) = process.receive(started.finish, 1000)
    as "The original worker owns its completion permit."
  process.send(subject, Nil)
}

fn receive_worker(started: Running) -> process.Pid {
  let assert Ok(worker) = process.receive(started.workers, 1000)
    as "Original managed request worker."
  worker
}

fn checkpoint(
  started: Running,
  expected: native.RecoveryCheckpoint,
) -> native.RecoveryObservation {
  let assert Ok(observation) = process.receive(started.probes, 1000)
    as "Deterministic original writer boundary."
  assert observation.checkpoint == expected
  observation
}

// The shared setup's existing 5000-ms busy timeout determines this observation.
// This finite test-only wait fits the unchanged EUnit budget; the original run
// deadline, cancellation, SQL timeout and ordinary checkpoint waits stay unchanged.
fn failed_setup_checkpoint(started: Running) -> native.RecoveryObservation {
  let assert Ok(observation) = process.receive(started.probes, 6000)
    as "Exact original setup fails before the independent SQL lock is released."
  assert observation.checkpoint == native.BeforeCloseReply
  observation
}

fn permit(started: Running, expected: native.RecoveryCheckpoint) -> Nil {
  process.send(checkpoint(started, expected).permit, native.Proceed)
}

fn ready_single(started: Running) -> process.Pid {
  let original = checkpoint(started, native.BeforeAdopt)
  process.send(original.permit, native.Proceed)
  permit(started, native.BeforeStartAck)
  permit(started, native.BeforeSqlOpen)
  permit(started, native.BeforeInitialiseReply)
  let assert Ok(_) = process.receive(started.ready, 1000)
    as "Only validated original recovery is exposed."
  original.owner
}

fn resource_opening(
  started: Running,
) -> #(process.Pid, process.Pid, native.RecoveryObservation) {
  let parent = checkpoint(started, native.BeforeAdopt)
  process.send(parent.permit, native.Proceed)
  permit(started, native.BeforeStartAck)
  let child = checkpoint(started, native.BeforeAdopt)
  assert child.owner != parent.owner
  process.send(child.permit, native.Proceed)
  permit(started, native.BeforeStartAck)
  permit(started, native.BeforeSqlOpen)
  permit(started, native.BeforeInitialiseReply)
  let opening = checkpoint(started, native.BeforeSqlOpen)
  assert opening.owner == parent.owner
  #(parent.owner, child.owner, opening)
}

fn ready_resource(started: Running) -> #(process.Pid, process.Pid) {
  let #(parent, child, opening) = resource_opening(started)
  process.send(opening.permit, native.Proceed)
  permit(started, native.BeforeInitialiseReply)
  let assert Ok(ResourceOwner(_)) = process.receive(started.ready, 1000)
    as "Same original native is installed once."
  #(parent, child)
}

fn normal_down(watch: process.Monitor) -> Result(Nil, Nil) {
  let answer =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Nil)
      }
    })
    |> process.selector_receive(1000)
  process.demonitor_process(watch)
  result.unwrap(answer, Error(Nil))
}

fn finish_run(started: Running) -> Nil {
  assert weft.pull(started.run, 1000) == weft.AllDelivered
  assert normal_down(started.scope_watch) == Ok(Nil)
}

fn store_bytes(f: Fixture, family: Family) -> BitArray {
  let path = case family {
    Native -> f.native_path
    Workspace -> f.workspace_path
    Resource -> f.resource_path
  }
  let assert Ok(bytes) = simplifile.read_bits(path)
    as "Original closed store bytes."
  bytes
}

fn fixture(run: fn(Fixture) -> Nil) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-owned-history-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory(directory)
    as "Unique real SQL fixture."
  let native_path = directory <> "/native.sqlite"
  let workspace_path = directory <> "/workspace.sqlite"
  let resource_path = directory <> "/resource.sqlite"
  let assert Ok(book) = native.fresh(native_path, native_scope(), capacity())
    as "Original native store."
  let assert Ok(_) = native.admit(book, native_key(), digest(1))
    as "Original admitted key."
  let assert Ok(_) =
    native.apply(
      book,
      native_key(),
      digest(1),
      admission.RefuseBeforeLaunch(digest(2)),
    )
    as "Exact original terminal without execution."
  let assert Ok(wbook) =
    workspace.fresh(workspace_path, scope(), workspace_limits())
    as "Original workspace store."
  assert workspace.admit(wbook, invocation()) == Ok(workspace.Accepted)
  let assert Ok(workspace.Claimed(claim)) = workspace.claim(wbook, invocation())
    as "Original workspace claim."
  assert workspace.finish(claim, completed_read())
    == Ok(workspace.Finished(completed_read()))
  assert workspace.release(wbook) == Ok(Nil)
  let original = compiled()
  let assert Ok(rbook) =
    resource.fresh(resource_path, enrolled(), resource_limits(), book)
    as "Original resource and same native store."
  assert resource.reserve(rbook, original) == Ok(resource.Reserved)
  let assert Ok(resource.Claimed(claim)) =
    resource.claim_preparation(rbook, original)
    as "Original preparation claim."
  let assert Ok(completion) =
    compile_completion.failed_before_native(
      enrolled(),
      original.key,
      compile.WorkspaceSetupFailed("original failure"),
    )
    as "Closed original Compile result."
  let assert Ok(_) = resource.fail_preparation(claim, completion)
    as "Real retained Compile transaction."
  let launch = launched(original.key)
  assert resource.reserve(rbook, launch) == Ok(resource.Reserved)
  let assert Ok(resource.Claimed(claim)) =
    resource.claim_preparation(rbook, launch)
    as "Original no-dispatch Launch preparation fence."
  let assert Ok(completion) =
    launch_completion.refused_before_native(
      enrolled(),
      launch.key,
      "original clearance refusal",
    )
    as "Canonical original Launch refusal."
  let assert Ok(_) = resource.fail_launch_preparation(claim, completion)
    as "Real retained Launch transaction excludes future native association."
  assert resource.release_endpoint(rbook) == Ok(Nil)
  assert native.release(book) == Ok(Nil)
  run(Fixture(directory, native_path, workspace_path, resource_path, original))
  let assert Ok(Nil) = simplifile.delete(directory)
    as "Only original joined test resources are removed."
  Nil
}

fn scope() -> cw.Scope {
  let assert Ok(value) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Complete original scope."
  value
}

fn native_scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(name) = identity.workspace_id("checkout")
    as "Original workspace."
  let assert Ok(executor) = identity.executor_id("linux")
    as "Original executor."
  let assert Ok(session_epoch) = identity.epoch(2) as "Original session epoch."
  let assert Ok(workspace_epoch) = identity.epoch(7)
    as "Original workspace epoch."
  identity.scope(session, name, executor, session_epoch, workspace_epoch)
}

fn native_key() -> identity.RequestKey {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let assert Ok(id) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
    as "Original native request."
  identity.request_key(native_scope(), op, id)
}

fn digest(number: Int) -> identity.Digest {
  let assert Ok(value) = identity.digest(<<number:size(256)>>)
    as "Exact digest."
  value
}

fn capacity() -> admission.Capacity {
  let assert Ok(value) = admission.capacity(4) as "Original native capacity."
  value
}

fn native_input(f: Fixture) -> native.RecoveryInput {
  let assert Ok(input) =
    native.recovery_input(f.native_path, native_scope(), capacity())
    as "Original retained native inputs."
  input
}

fn workspace_limits() -> workspace.Limits {
  let assert Ok(value) = workspace.limits(4, 100_000_000)
    as "Original workspace quotas."
  value
}

fn resource_limits() -> resource.Limits {
  let assert Ok(value) = resource.limits(4, 30_000_000)
    as "Original resource quotas."
  value
}

fn entry(number: Int) -> ids.EntryId {
  let assert Ok(value) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Original UUID."
  value
}

fn invocation() -> BitArray {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let assert Ok(step) = cw.step("read") as "Original physical step."
  let assert Ok(path) = cw.relative_path("a") as "Original relative path."
  let assert Ok(bytes) =
    codec.encode_invocation(w.invocation(
      scope(),
      op,
      step,
      w.System(w.WorktreeObservation),
      entry(5),
      w.Read(path, w.Text),
    ))
    as "Canonical original workspace invocation."
  bytes
}

fn completed_read() -> BitArray {
  let assert Ok(path) = cw.relative_path("a") as "Original read path."
  let assert Ok(bytes) =
    codec.encode_completion(
      w.Read(path, w.Text),
      Ok(local.Completed(w.ReadCompleted(Ok(w.TextRead("retained"))), None)),
    )
    as "Canonical original read completion."
  bytes
}

fn base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/alloc"],
    readable_roots: ["/tc", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkOff,
    limits: policy.Limits(11, 12, 13, 14, 15, 16),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchTmpfs,
    mounts: [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(value) =
    enrollment.new(
      enrollment.NativeFacts(scope(), ["/"], base(), exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        base().mounts,
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete original enrollment."
  value
}

fn compiled() -> resource.Input {
  let assert Ok(decoded) =
    service_input.compile_input(
      enrolled(),
      service_input.WorkspaceProgram,
      "pub fn main() { Nil }",
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Canonical original Compile input."
  let body = service_input.encode_compile(decoded)
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let assert Ok(parent) =
    remote_tool.key(session, op, "parent", 3, string.repeat("a", 64), entry(4))
    as "Complete original parent key."
  let assert Ok(step) = cw.step("physical:build")
    as "Original physical build coordinate."
  let hash = string.lowercase(bit_array.base16_encode(resource.digest(body)))
  let assert Ok(key) =
    command.service_key(
      parent,
      command.CompileService,
      scope(),
      op,
      step,
      entry(6),
      hash,
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Exact input-digest-linked service key."
  resource.Input(key, body)
}

fn launched(producer: command.ServiceKey) -> resource.Input {
  let #(scope, operation, step) = command.coordinates(producer)
  let #(digest, _, contract) = command.digests(producer)
  let artifact =
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      ids.entry_id_to_string(command.request_id(producer)),
      digest,
      "issued-artifact",
      contract,
      compile.entry_module,
      "sha256-" <> string.repeat("e", 64),
    )
  let assert Ok(decoded) =
    service_input.launch_input(
      enrolled(),
      producer,
      artifact,
      [],
      cw.root(),
      base(),
      string.repeat("d", 64),
    )
    as "Canonical original Launch data grants no artifact authority."
  let body = service_input.encode_launch(decoded)
  let assert Ok(step) = cw.step("physical:run") as "Original Launch coordinate."
  let hash = string.lowercase(bit_array.base16_encode(resource.digest(body)))
  let assert Ok(key) =
    command.service_key(
      command.parent(producer),
      command.LaunchService,
      scope,
      operation,
      step,
      entry(7),
      hash,
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Exact canonical original Launch key."
  resource.Input(key, body)
}
