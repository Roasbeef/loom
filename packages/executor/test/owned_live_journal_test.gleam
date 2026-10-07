//// Original permanent-parent controls for live Fresh SQLite custody.
////
//// A real weft actor starts and records each linked resource-free original.
//// Finite managed workers only observe initialization and release. The SQL
//// writer never becomes their child, and all execution uses its actual Journal.

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
import executor/remote/identity
import executor/remote/journal as native
import executor/remote/resource_journal as resource
import executor/remote/workspace_journal as workspace
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/actor

type Family {
  Native
  Workspace
  Resource
}

type Parked {
  NativeOwner(native.ParkedFresh)
  WorkspaceOwner(workspace.ParkedFresh)
  ResourceOwner(resource.ParkedFresh)
}

type Live {
  NativeReady(native.LiveFresh)
  WorkspaceReady(workspace.LiveFresh)
  ResourceReady(resource.LiveFresh)
}

type Parent {
  Parent(
    path: String,
    family: Family,
    probes: process.Subject(native.FreshObservation),
    parked: process.Subject(Parked),
    original: Option(Parked),
    dependency: Option(native.ParkedFresh),
    dependency_ready: Option(native.LiveFresh),
    dependencies: process.Subject(native.LiveFresh),
    children: process.Subject(process.Pid),
  )
}

type ParentMessage {
  Start
  SetupNative
  RetireNative(process.Subject(Result(Nil, native.Error)))
  Stop
}

type Running {
  Running(
    subject: process.Subject(ParentMessage),
    pid: process.Pid,
    probes: process.Subject(native.FreshObservation),
    parked: process.Subject(Parked),
    dependencies: process.Subject(native.LiveFresh),
    dependency: Option(process.Pid),
  )
}

type Borrowed {
  Borrowed(
    run: weft.Detached(Nil, Nil),
    workers: process.Subject(process.Pid),
    answers: process.Subject(Result(Live, Nil)),
  )
}

/// All three projected Journals share their real existing first-claim semantics.
pub fn projected_original_live_claims_and_legacy_history_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let running = start(directory <> "/fresh.sqlite", family)
      let original = parked(running)
      let borrowed = initialise(original)
      ready_boundaries(running)
      let assert Ok(Ok(ready)) = process.receive(borrowed.answers, 1000)
        as "Actual same original readiness."
      finish_borrow(borrowed)
      assert init(original) == Error(Nil)
      case ready {
        NativeReady(ready) -> {
          let book = native.fresh_journal(ready)
          let assert Ok(_) = native.admit(book, native_key(), digest(1))
            as "Actual native admission."
          let assert Ok(first) =
            native.apply(
              book,
              native_key(),
              digest(1),
              admission.AuthorizeLaunch,
            )
            as "First COMMIT grants Launch."
          assert first.effect == admission.Launch(native_key())
          let assert Ok(repeated) =
            native.apply(
              book,
              native_key(),
              digest(1),
              admission.AuthorizeLaunch,
            )
            as "Exact duplicate retained."
          assert repeated.effect == admission.NoLaunch
        }
        WorkspaceReady(ready) -> {
          let book = workspace.fresh_journal(ready)
          assert workspace.admit(book, invocation()) == Ok(workspace.Accepted)
          let assert Ok(workspace.Claimed(claim)) =
            workspace.claim(book, invocation())
            as "Original workspace claim."
          let assert Ok(workspace.Existing(_)) =
            workspace.claim(book, invocation())
            as "Duplicate cannot claim."
          assert workspace.finish(claim, completed_read())
            == Ok(workspace.Finished(completed_read()))
        }
        ResourceReady(ready) -> {
          let book = resource.fresh_journal(ready)
          let assert Ok(resource.FreshClaim(_)) =
            resource.admit_preparation(book, compiled())
            as "Original first-only preparation COMMIT."
          let assert Ok(resource.Retained(_)) =
            resource.admit_preparation(book, compiled())
            as "Duplicate preparation has no claim."
          let assert Ok(dependency) =
            process.receive(running.dependencies, 1000)
            as "Same actual native from permanent parent."
          assert native.validate_fresh_dependency(
              dependency,
              native_scope(),
              running.pid,
            )
            == Ok(native.fresh_journal(dependency))
          assert resource.native_endpoint(book)
            == native.fresh_journal(dependency)
        }
      }
      strict_close(running, original, native.Proceed)
      assert release(original) == Error(Nil)
      stop_parent(running)

      // Existing constructors still recover the exact closed store without claims.
      case family {
        Native -> {
          let assert Ok(book) =
            native.recover(
              directory <> "/fresh.sqlite",
              native_scope(),
              capacity(),
            )
            as "Legacy recovery still observes history."
          let assert Ok(again) =
            native.apply(
              book,
              native_key(),
              digest(1),
              admission.AuthorizeLaunch,
            )
            as "Recovery cannot mint the original effect."
          assert again.effect == admission.NoLaunch
          assert native.release(book) == Ok(Nil)
        }
        Workspace -> {
          let assert Ok(book) =
            workspace.recover(
              directory <> "/fresh.sqlite",
              scope(),
              workspace_limits(),
            )
            as "Legacy workspace metadata unchanged."
          let assert Ok(workspace.Existing(_)) =
            workspace.claim(book, invocation())
            as "Recovered completed row cannot claim."
          assert workspace.release(book) == Ok(Nil)
        }
        Resource -> {
          let assert Ok(nbook) =
            native.recover(
              directory <> "/fresh.sqlite.native",
              native_scope(),
              capacity(),
            )
            as "Same retained native store."
          let assert Ok(book) =
            resource.recover(
              directory <> "/fresh.sqlite",
              enrolled(),
              resource_limits(),
              nbook,
            )
            as "Exact resource metadata unchanged."
          let assert Ok(resource.Retained(_)) =
            resource.admit_preparation(book, compiled())
            as "Recovered row cannot mint fresh preparation."
          assert resource.release_endpoint(book) == Ok(Nil)
          assert native.release(nbook) == Ok(Nil)
        }
      }
    })
  })
}

/// An original link kills a parked child on actual normal parent death.
pub fn parent_normal_exit_before_initialise_opens_no_database_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let path = directory <> "/parked.sqlite"
      let running = start(path, family)
      let original = parked(running)
      let watch = process.monitor(owner(original))
      stop_parent(running)
      assert normal_down(watch) == Ok(Nil)
      assert simplifile.exists(path, False) == Ok(False)
      assert init(original) == Error(Nil)
    })
  })
}

/// Parent loss before startup ACK never opens the parked child's SQLite path.
pub fn actual_parent_death_before_ack_has_no_sql_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let path = directory <> "/before-ack.sqlite"
      let running = start(path, family)
      let ack = boundary(running, native.BeforeFreshStartAck)
      let watch = process.monitor(ack.owner)
      let parent_watch = process.monitor(running.pid)
      let native_watch = watch_dependency(running)
      process.kill(running.pid)
      assert down(parent_watch) == Error(Nil)
      process.send(ack.permit, native.Proceed)
      assert down(watch) == Error(Nil)
      join_dependency(native_watch)
      assert simplifile.exists(path, False) == Ok(False)
    })
  })
}

/// The finite initialization observer is never the original writer's parent.
pub fn finite_observer_death_after_acquired_does_not_orphan_writer_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let running = start(directory <> "/observer.sqlite", family)
      let original = parked(running)
      let borrowed = initialise(original)
      permit(running, native.BeforeFreshSqlOpen)
      let acquired = boundary(running, native.AfterFreshOpen)
      let assert Ok(worker) = process.receive(borrowed.workers, 1000)
        as "Actual borrowed observer worker."
      process.kill(worker)
      let assert weft.PulledOutcome(weft.Crashed(0, _)) =
        weft.pull(borrowed.run, 1000)
        as "Scope observed actual observer death."
      assert weft.pull(borrowed.run, 1000) == weft.AllDelivered
      assert process.is_alive(running.pid)
      assert process.is_alive(owner(original))
      process.send(acquired.permit, native.Proceed)
      permit(running, native.BeforeFreshReadyReply)
      assert init(original) == Error(Nil)
      strict_close(running, original, native.Proceed)
      stop_parent(running)
    })
  })
}

/// Real failed setup is observed while the independent writer lock remains held.
pub fn acquired_actual_busy_setup_failure_closes_original_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let path = directory <> "/busy.sqlite"
      let running = start(path, family)
      let original = parked(running)
      let borrowed = initialise(original)
      permit(running, native.BeforeFreshSqlOpen)
      let acquired = boundary(running, native.AfterFreshOpen)
      let assert Ok(lock) = sqlight.open(path)
        as "Independent actual SQL locker."
      assert sqlight.exec("PRAGMA journal_mode=WAL; BEGIN IMMEDIATE", lock)
        == Ok(Nil)
      process.send(acquired.permit, native.Proceed)

      // The production 5000-ms busy failure precedes this existing close checkpoint.
      let assert Ok(closing) = process.receive(running.probes, 6000)
        as "Exact original setup fails while real lock is still held."
      assert closing.checkpoint == native.BeforeFreshCloseReply
      assert closing.owner == owner(original)
      assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
      assert sqlight.close(lock) == Ok(Nil)
      let watch = process.monitor(owner(original))
      process.send(closing.permit, native.Proceed)
      permit(running, native.AfterFreshCloseBeforeExit)
      assert normal_down(watch) == Ok(Nil)
      let assert weft.PulledOutcome(_) = weft.pull(borrowed.run, 1000)
        as "Actual failed or timed-out borrowed observation."
      assert weft.pull(borrowed.run, 1000) == weft.AllDelivered
      assert init(original) == Error(Nil)
      assert release(original) == Error(Nil)
      stop_parent(running)
    })
  })
}

/// Admitted setup can COMMIT before the queued actual parent exit is processed.
pub fn acquired_parent_death_retains_setup_and_actual_cleanup_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let path = directory <> "/admitted.sqlite"
      let running = start(path, family)
      let original = parked(running)
      let borrowed = initialise(original)
      permit(running, native.BeforeFreshSqlOpen)
      let acquired = boundary(running, native.AfterFreshOpen)
      let parent_watch = process.monitor(running.pid)
      let child_watch = process.monitor(owner(original))
      let native_watch = watch_dependency(running)
      process.kill(running.pid)
      assert down(parent_watch) == Error(Nil)
      process.send(acquired.permit, native.Proceed)
      permit(running, native.BeforeFreshReadyReply)
      assert down(child_watch) == Error(Nil)
      join_dependency(native_watch)
      let assert weft.PulledOutcome(_) = weft.pull(borrowed.run, 1000)
        as "Actual observer result does not authorize replacement assembly."
      assert weft.pull(borrowed.run, 1000) == weft.AllDelivered
      assert simplifile.exists(path, False) == Ok(True)
      assert init(original) == Error(Nil)
      assert release(original) == Error(Nil)
    })
  })
}

/// Suppressed Ready after actual COMMIT cannot recreate readiness or Fresh.
pub fn commit_lost_ready_reply_retains_original_only_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let running = start(directory <> "/committed.sqlite", family)
      let original = parked(running)
      let borrowed = initialise(original)
      permit(running, native.BeforeFreshSqlOpen)
      permit(running, native.AfterFreshOpen)
      let ready = boundary(running, native.BeforeFreshReadyReply)
      process.send(ready.permit, native.SuppressReply)
      let assert Ok(worker) = process.receive(borrowed.workers, 1000)
        as "Original finite observer."
      process.kill(worker)
      let assert weft.PulledOutcome(weft.Crashed(0, _)) =
        weft.pull(borrowed.run, 1000)
        as "Lost Ready has no replacement readiness."
      assert weft.pull(borrowed.run, 1000) == weft.AllDelivered
      assert init(original) == Error(Nil)
      strict_close(running, original, native.Proceed)
      readback_metadata(running, directory <> "/committed.sqlite", family)
      stop_parent(running)
    })
  })
}

/// Strict release retains uncertainty for lost ACK and failed explicit close.
pub fn strict_release_lost_ack_and_synthetic_refusal_test() {
  list.each([native.SuppressReply, native.RefuseClose], fn(decision) {
    list.each([Native, Workspace, Resource], fn(family) {
      fixture(fn(directory) {
        let running = start(directory <> "/close.sqlite", family)
        let original = parked(running)
        let borrowed = initialise(original)
        ready_boundaries(running)
        let assert Ok(Ok(_)) = process.receive(borrowed.answers, 1000)
          as "Real SQL Ready before synthetic close control."
        finish_borrow(borrowed)
        let parent_watch = process.monitor(running.pid)
        let native_watch = watch_dependency(running)
        strict_close(running, original, decision)
        case decision {
          native.RefuseClose -> {
            assert down(parent_watch) == Error(Nil)
            join_dependency(native_watch)
          }
          native.Proceed | native.SuppressReply -> {
            process.demonitor_process(parent_watch)
            case native_watch {
              None -> Nil
              Some(watch) -> process.demonitor_process(watch)
            }
            stop_parent(running)
          }
        }
      })
    })
  })
}

/// Resource refuses scope-correct readiness from a different actual parent.
pub fn resource_exact_native_dependency_parent_refusal_test() {
  fixture(fn(directory) {
    let running = start(directory <> "/native.sqlite", Native)
    let original = parked(running)
    let borrowed = initialise(original)
    ready_boundaries(running)
    let assert Ok(Ok(NativeReady(ready))) =
      process.receive(borrowed.answers, 1000)
      as "Opaque actual native readiness."
    finish_borrow(borrowed)
    assert native.validate_fresh_dependency(ready, native_scope(), running.pid)
      == Ok(native.fresh_journal(ready))
    assert native.validate_fresh_dependency(
        ready,
        native_scope(),
        process.self(),
      )
      == Error(native.BindingMismatch)
    let #(session, name, executor, session_epoch, _) =
      identity.scope_fields(native_scope())
    let assert Ok(session) = ids.parse_session_id(session)
      as "Original full session."
    let assert Ok(name) = identity.workspace_id(name)
      as "Original full workspace."
    let assert Ok(executor) = identity.executor_id(executor)
      as "Original executor."
    let assert Ok(session_epoch) = identity.epoch(session_epoch)
      as "Original session epoch."
    let assert Ok(changed_epoch) = identity.epoch(8)
      as "Different full scope epoch."
    assert native.validate_fresh_dependency(
        ready,
        identity.scope(session, name, executor, session_epoch, changed_epoch),
        running.pid,
      )
      == Error(native.BindingMismatch)
    let assert Ok(input) =
      resource.fresh_input(
        directory <> "/refused.sqlite",
        enrolled(),
        resource_limits(),
        ready,
      )
      as "Scope matches without granting new parent custody."
    assert resource.park_fresh(input) == Error(resource.BindingMismatch)
    assert simplifile.exists(directory <> "/refused.sqlite", False) == Ok(False)
    strict_close(running, original, native.Proceed)
    assert native.validate_fresh_dependency(ready, native_scope(), running.pid)
      == Error(native.Closed)
    stop_parent(running)
  })
}

/// Native loss between park and initialization refuses before resource SQL opens.
pub fn resource_revalidates_original_native_after_park_test() {
  fixture(fn(directory) {
    let path = directory <> "/resource.sqlite"
    let running = start(path, Resource)
    let original = parked(running)
    let answer = process.new_subject()
    process.send(running.subject, RetireNative(answer))
    assert process.receive(answer, 1000) == Ok(Ok(Nil))
    let borrowed = initialise(original)
    permit(running, native.BeforeFreshSqlOpen)
    permit(running, native.AfterFreshCloseBeforeExit)
    let assert Ok(Error(Nil)) = process.receive(borrowed.answers, 1000)
      as "Original native loss refuses without resource SQL."
    finish_borrow(borrowed)
    assert simplifile.exists(path, False) == Ok(False)
    let watch = process.monitor(running.pid)
    process.send(running.subject, Stop)
    assert normal_down(watch) == Ok(Nil)
  })
}

/// Normal parent shutdown closes Ready originals but grants no strict ACK proof.
pub fn parent_normal_exit_after_ready_joins_actual_originals_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let running = start(directory <> "/ready.sqlite", family)
      let original = parked(running)
      let borrowed = initialise(original)
      ready_boundaries(running)
      let assert Ok(Ok(_)) = process.receive(borrowed.answers, 1000)
        as "Actual SQL metadata COMMIT."
      finish_borrow(borrowed)
      let watch = process.monitor(owner(original))
      stop_parent(running)
      assert normal_down(watch) == Ok(Nil)
      assert release(original) == Error(Nil)
    })
  })
}

/// Every live business failure retains checked original SQL cleanup custody.
pub fn actual_poisoned_business_query_closes_original_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let path = directory <> "/poison.sqlite"
      let running = start(path, family)
      let original = parked(running)
      let borrowed = initialise(original)
      ready_boundaries(running)
      let assert Ok(Ok(ready)) = process.receive(borrowed.answers, 1000)
        as "Actual initialized business endpoint."
      finish_borrow(borrowed)
      let assert Ok(connection) = sqlight.open(path)
        as "Real external corruptor, never a replacement Journal."
      let table = case family {
        Native -> "custody_meta"
        Workspace -> "workspace_meta"
        Resource -> "resource_meta"
      }
      assert sqlight.exec("DROP TABLE " <> table, connection) == Ok(Nil)
      assert sqlight.close(connection) == Ok(Nil)
      case ready {
        NativeReady(ready) ->
          assert_error(native.admit(
            native.fresh_journal(ready),
            native_key(),
            digest(1),
          ))
        WorkspaceReady(ready) ->
          assert_error(workspace.admit(
            workspace.fresh_journal(ready),
            invocation(),
          ))
        ResourceReady(ready) ->
          assert_error(resource.admit_preparation(
            resource.fresh_journal(ready),
            compiled(),
          ))
      }
      let closing = boundary(running, native.BeforeFreshCloseReply)
      let watch = process.monitor(owner(original))
      process.send(closing.permit, native.Proceed)
      permit(running, native.AfterFreshCloseBeforeExit)
      assert normal_down(watch) == Ok(Nil)
      assert release(original) == Error(Nil)
      stop_parent(running)
    })
  })
}

fn assert_error(value: Result(a, e)) -> Nil {
  let assert Error(_) = value as "Actual SQL failure grants no execution claim."
  Nil
}

/// A lost finite close observer cannot cancel the admitted original close.
pub fn finite_close_observer_death_keeps_original_parent_custody_test() {
  list.each([Native, Workspace, Resource], fn(family) {
    fixture(fn(directory) {
      let running = start(directory <> "/close-observer.sqlite", family)
      let original = parked(running)
      let borrowed = initialise(original)
      ready_boundaries(running)
      let assert Ok(Ok(_)) = process.receive(borrowed.answers, 1000)
        as "Actual original live writer."
      finish_borrow(borrowed)
      let workers = process.new_subject()
      let run =
        weft.new_prepared([
          weft.managed(fn(_ledger) {
            process.send(workers, process.self())
            release(original)
          }),
        ])
        |> weft.deadline(3000)
        |> weft.start_detached
      let closing = boundary(running, native.BeforeFreshCloseReply)
      let watch = process.monitor(owner(original))
      let assert Ok(worker) = process.receive(workers, 1000)
        as "Actual borrowed close observer."
      process.kill(worker)
      let assert weft.PulledOutcome(weft.Crashed(..)) = weft.pull(run, 1000)
        as "Original run has observed observer death."
      assert weft.pull(run, 1000) == weft.AllDelivered
      assert process.is_alive(running.pid)
      assert process.is_alive(closing.owner)
      process.send(closing.permit, native.Proceed)
      permit(running, native.AfterFreshCloseBeforeExit)
      assert normal_down(watch) == Ok(Nil)
      assert release(original) == Error(Nil)
      stop_parent(running)
    })
  })
}

fn readback_metadata(running: Running, path: String, family: Family) -> Nil {
  case family {
    Native -> {
      assert native.fresh(path, native_scope(), capacity())
        == Error(native.AlreadyExists)
      let assert Ok(book) = native.recover(path, native_scope(), capacity())
        as "Lost Ready retained exact native metadata."
      assert native.scope(book) == native_scope()
      assert native.release(book) == Ok(Nil)
    }
    Workspace -> {
      assert workspace.fresh(path, scope(), workspace_limits())
        == Error(workspace.AlreadyExists)
      let assert Ok(book) = workspace.recover(path, scope(), workspace_limits())
        as "Lost Ready retained exact workspace metadata."
      assert workspace.mode(book) == Ok(workspace.Open)
      assert workspace.release(book) == Ok(Nil)
    }
    Resource -> {
      let assert Ok(dependency) = process.receive(running.dependencies, 1000)
        as "Same original native still owned by permanent parent."
      let nbook = native.fresh_journal(dependency)
      assert resource.fresh(path, enrolled(), resource_limits(), nbook)
        == Error(resource.AlreadyExists)
      let assert Ok(book) =
        resource.recover(path, enrolled(), resource_limits(), nbook)
        as "Lost Ready retained exact resource metadata."
      assert resource.enrolled(book) == enrolled()
      assert resource.release_endpoint(book) == Ok(Nil)
    }
  }
}

fn start(path: String, family: Family) -> Running {
  let probes = process.new_subject()
  let parked = process.new_subject()
  let dependencies = process.new_subject()
  let children = process.new_subject()
  let assert Ok(started) =
    actor.new(Parent(
      path,
      family,
      probes,
      parked,
      None,
      None,
      None,
      dependencies,
      children,
    ))
    |> actor.trapping_exits(True)
    |> actor.on_message(parent_handle)
    |> actor.unlinked
    |> actor.start
    as "Actual permanent parent actor."
  process.send(started.data, Start)
  let dependency = case family {
    Native | Workspace -> None
    Resource -> {
      let assert Ok(pid) = process.receive(children, 1000)
        as "Original native dependency recorded before resource startup."
      Some(pid)
    }
  }
  Running(started.data, started.pid, probes, parked, dependencies, dependency)
}

fn parent_handle(
  state: Parent,
  message: ParentMessage,
) -> actor.Next(Parent, ParentMessage) {
  case message {
    Start ->
      case state.family {
        Native -> {
          let assert Ok(input) =
            native.fresh_input(state.path, native_scope(), capacity())
            as "Native Fresh inputs."
          let assert Ok(original) =
            native.park_fresh_observed(
              input,
              native.FreshObserved(state.probes),
            )
            as "Linked native original."
          process.send(state.parked, NativeOwner(original))
          actor.continue(Parent(..state, original: Some(NativeOwner(original))))
        }
        Workspace -> {
          let assert Ok(input) =
            workspace.fresh_input(state.path, scope(), workspace_limits())
            as "Workspace Fresh inputs."
          let assert Ok(original) =
            workspace.park_fresh_observed(
              input,
              native.FreshObserved(state.probes),
            )
            as "Linked workspace original."
          process.send(state.parked, WorkspaceOwner(original))
          actor.continue(
            Parent(..state, original: Some(WorkspaceOwner(original))),
          )
        }
        Resource -> {
          let assert Ok(input) =
            native.fresh_input(
              state.path <> ".native",
              native_scope(),
              capacity(),
            )
            as "Exact native dependency inputs."
          let assert Ok(original) = native.park_fresh(input)
            as "Actual same-parent native original."
          process.send(state.children, native.fresh_owner(original))
          actor.continue(Parent(..state, dependency: Some(original)))
          |> actor.then_handle(SetupNative)
        }
      }
    SetupNative -> {
      let assert Some(original) = state.dependency
        as "Original dependency installed before Initialize."
      let assert Ok(ready) = native.initialise_fresh(original)
        as "Original native readiness."
      let assert Ok(input) =
        resource.fresh_input(state.path, enrolled(), resource_limits(), ready)
        as "Exact dependency retained."
      let assert Ok(original) =
        resource.park_fresh_observed(input, native.FreshObserved(state.probes))
        as "Actual same-parent resource original."
      process.send(state.dependencies, ready)
      process.send(state.parked, ResourceOwner(original))
      actor.continue(
        Parent(
          ..state,
          original: Some(ResourceOwner(original)),
          dependency_ready: Some(ready),
        ),
      )
    }
    RetireNative(reply) -> {
      let assert Some(original) = state.dependency
        as "Actual recorded native dependency."
      process.send(reply, native.release_fresh(original))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn parked(running: Running) -> Parked {
  permit(running, native.BeforeFreshStartAck)
  let assert Ok(original) = process.receive(running.parked, 1000)
    as "Actual parent recorded original parked handle."
  original
}

fn initialise(original: Parked) -> Borrowed {
  let workers = process.new_subject()
  let answers = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        process.send(workers, process.self())
        let answer = init(original)
        process.send(answers, answer)
        Ok(Nil)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  Borrowed(run, workers, answers)
}

fn init(original: Parked) -> Result(Live, Nil) {
  case original {
    NativeOwner(original) ->
      native.initialise_fresh(original)
      |> result.map(NativeReady)
      |> result.replace_error(Nil)
    WorkspaceOwner(original) ->
      workspace.initialise_fresh(original)
      |> result.map(WorkspaceReady)
      |> result.replace_error(Nil)
    ResourceOwner(original) ->
      resource.initialise_fresh(original)
      |> result.map(ResourceReady)
      |> result.replace_error(Nil)
  }
}

fn owner(original: Parked) -> process.Pid {
  case original {
    NativeOwner(original) -> native.fresh_owner(original)
    WorkspaceOwner(original) -> workspace.fresh_owner(original)
    ResourceOwner(original) -> resource.fresh_owner(original)
  }
}

fn release(original: Parked) -> Result(Nil, Nil) {
  case original {
    NativeOwner(original) ->
      native.release_fresh(original) |> result.replace_error(Nil)
    WorkspaceOwner(original) ->
      workspace.release_fresh(original) |> result.replace_error(Nil)
    ResourceOwner(original) ->
      resource.release_fresh(original) |> result.replace_error(Nil)
  }
}

fn boundary(
  running: Running,
  expected: native.FreshCheckpoint,
) -> native.FreshObservation {
  let assert Ok(observation) = process.receive(running.probes, 1000)
    as "Exact original closed lifecycle checkpoint."
  assert observation.checkpoint == expected
  observation
}

fn permit(running: Running, checkpoint: native.FreshCheckpoint) -> Nil {
  process.send(boundary(running, checkpoint).permit, native.Proceed)
}

fn ready_boundaries(running: Running) -> Nil {
  permit(running, native.BeforeFreshSqlOpen)
  permit(running, native.AfterFreshOpen)
  permit(running, native.BeforeFreshReadyReply)
}

fn finish_borrow(borrowed: Borrowed) -> Nil {
  assert weft.pull(borrowed.run, 1000)
    == weft.PulledOutcome(weft.Completed(0, Nil))
  assert weft.pull(borrowed.run, 1000) == weft.AllDelivered
}

fn strict_close(
  running: Running,
  original: Parked,
  decision: native.RecoveryPermit,
) -> Nil {
  let answer = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        process.send(answer, release(original))
        Ok(Nil)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  let closing = boundary(running, native.BeforeFreshCloseReply)
  let watch = process.monitor(owner(original))
  process.send(closing.permit, decision)
  case decision {
    native.Proceed | native.SuppressReply -> {
      let exiting = boundary(running, native.AfterFreshCloseBeforeExit)
      assert process.is_alive(exiting.owner)

      // The actual exit permit is withheld while the original release observer
      // has a bounded opportunity to publish. A zero-time mailbox sample cannot
      // reject an ACK-only observer that simply has not been scheduled yet.
      assert weft.pull(run, 1000) == weft.NotYet
      assert process.receive(answer, 0) == Error(Nil)
      process.send(exiting.permit, native.Proceed)
      assert normal_down(watch) == Ok(Nil)
      let assert Ok(actual) = process.receive(answer, 1000)
        as "Actual strict close result."
      case decision {
        native.Proceed -> {
          assert actual == Ok(Nil)
        }
        native.SuppressReply -> {
          assert actual == Error(Nil)
        }
        native.RefuseClose -> panic as "Closed permit table."
      }
    }
    native.RefuseClose -> {
      assert down(watch) == Error(Nil)
      assert process.receive(answer, 1000) == Ok(Error(Nil))
    }
  }
  assert weft.pull(run, 1000) == weft.PulledOutcome(weft.Completed(0, Nil))
  assert weft.pull(run, 1000) == weft.AllDelivered
}

fn stop_parent(running: Running) -> Nil {
  let watch = process.monitor(running.pid)
  let native_watch = watch_dependency(running)
  process.send(running.subject, Stop)
  assert normal_down(watch) == Ok(Nil)
  join_dependency(native_watch)
}

fn watch_dependency(running: Running) -> Option(process.Monitor) {
  case running.dependency {
    None -> None
    Some(pid) -> Some(process.monitor(pid))
  }
}

fn join_dependency(watch: Option(process.Monitor)) -> Nil {
  case watch {
    None -> Nil
    Some(watch) -> {
      let _ = down(watch)
      Nil
    }
  }
}

fn normal_down(watch: process.Monitor) -> Result(Nil, Nil) {
  down(watch)
}

fn down(watch: process.Monitor) -> Result(Nil, Nil) {
  let received =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason:, ..) -> reason
        process.PortDown(reason:, ..) -> reason
      }
    })
    |> process.selector_receive(1000)
  process.demonitor_process(watch)
  let assert Ok(reason) = received
    as "Actual original DOWN, never timeout as failure evidence."
  case reason {
    process.Normal -> Ok(Nil)
    _ -> Error(Nil)
  }
}

fn fixture(run: fn(String) -> Nil) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-owned-live-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory(directory)
    as "Unique real SQL fixture."
  run(directory)
  let assert Ok(Nil) = simplifile.delete(directory)
    as "Joined original test resources removed."
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
