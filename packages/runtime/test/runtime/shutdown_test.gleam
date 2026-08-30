//// Closing a session is a shutdown, not a kill.
////
//// `api.close` used to `exit(Supervisor, kill)`, which reaches every
//// child at once through the links and reports each one as a crash. The
//// tree now terminates the way OTP terminates a supervision tree: in
//// reverse start order, with the ordinary `shutdown` reason. Two things
//// are observable from outside and both are asserted here — the reason a
//// child dies with, and the order the children die in. The third, that
//// the writer lease is released on the way out, is what makes the file
//// reopenable at once instead of after its lease TTL.
////
//// Provider drains add a second lifetime. The drain ledger may outlive an
//// abnormally killed root while an old request still owns native work, so
//// close must await that stable name independently before releasing the
//// writer lease. The final test kills the root first to pin that distinction.

import core/clock
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, Abnormal, Killed, Normal, ProcessDown}
import gleam/list
import gleam/option.{Some}
import machine/operation.{ReplayNever}
import provider/stream
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import simplifile
import support/fake
import support/harness
import support/recorder

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

// A quiet session: nothing is ever asked of the provider or a tool, so
// the tree is idle and the only thing under test is how it stops.
fn idle_effects(rec: process.Subject(recorder.Message)) -> effects.Effects {
  fake.effects(
    rec,
    clock.stepping(from: 1_000_000, by: 7),
    [#("read", ReplayNever)],
    fn(_spec) { fake.Reply(fake.answer("unused", 1)) },
    fn(_run) {
      fake.ToolReply(text: "unused", is_error: False, terminate: False)
    },
  )
}

fn open_idle(name: String) -> #(String, api.Runtime) {
  let path = fresh_path(name)
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
    as "the fresh sqlite session must open"
  let assert Ok(runtime) =
    api.open(
      opened,
      idle_effects(recorder.start()),
      api.default_options(harness.configuration()),
    )
    as "the session tree must boot"
  #(path, runtime)
}

fn writer_pid(runtime: api.Runtime) -> Pid {
  let assert Ok(pid) =
    process.subject_owner(process.named_subject(runtime.tree.writer))
    as "the writer must be registered"
  pid
}

fn driver_pid(runtime: api.Runtime) -> Pid {
  let assert Ok(subject) = supervisor.strand_subject(runtime.tree, "main")
    as "the booter must have started a driver for main"
  let assert Ok(pid) = process.subject_owner(subject)
    as "the driver must be registered"
  pid
}

// Starts monitoring every watched pid *before* the tree is asked to
// stop — a monitor placed on a process that is already gone reports
// `noproc`, which would make this test pass for the wrong reason.
fn watch(watched: List(#(String, Pid))) -> process.Selector(process.Down) {
  list.fold(watched, process.new_selector(), fn(selector, entry) {
    process.select_specific_monitor(
      selector,
      process.monitor(entry.1),
      fn(down) { down },
    )
  })
}

// Drains the deaths in arrival order, labelled.
fn deaths(
  selector: process.Selector(process.Down),
  watched: List(#(String, Pid)),
) -> List(#(String, process.ExitReason)) {
  collect(selector, list.map(watched, fn(entry) { #(entry.1, entry.0) }), [])
}

fn collect(
  selector: process.Selector(process.Down),
  labels: List(#(Pid, String)),
  seen: List(#(String, process.ExitReason)),
) -> List(#(String, process.ExitReason)) {
  case list.length(seen) >= list.length(labels) {
    True -> list.reverse(seen)
    False ->
      case process.selector_receive(from: selector, within: 5000) {
        Error(Nil) -> list.reverse(seen)
        Ok(ProcessDown(pid:, reason:, ..)) ->
          case list.key_find(labels, pid) {
            Ok(label) -> collect(selector, labels, [#(label, reason), ..seen])
            Error(Nil) -> collect(selector, labels, seen)
          }
        Ok(_port_down) -> collect(selector, labels, seen)
      }
  }
}

/// Every child dies with `shutdown`, the reason a supervisor uses when a
/// stop was asked for, rather than `killed`, the reason a brutal kill
/// propagates. The difference is not cosmetic: `killed` is what the
/// interleave harness injects to simulate a crash, so a close that
/// produced it made an orderly shutdown indistinguishable from a fault.
pub fn close_stops_every_child_with_shutdown_test() {
  let #(_path, runtime) = open_idle("close_shutdown_reason")
  let watched = [
    #("driver", driver_pid(runtime)),
    #("writer", writer_pid(runtime)),
  ]
  let selector = watch(watched)
  let _closed = api.close(runtime)
  let reported = deaths(selector, watched)
  assert list.length(reported) == 2
    as "both the driver and the writer must be gone once close returns"
  assert list.map(reported, described)
    == ["driver: shutdown", "writer: shutdown"]
    as "a close asked for must read as a shutdown, never as a kill"
}

// A death as a person would say it, so a failure names the reason it saw
// rather than printing a dynamic.
fn described(death: #(String, process.ExitReason)) -> String {
  let reason = case death.1 {
    Normal -> "normal"
    Killed -> "killed"
    Abnormal(reason:) -> atom.to_string(atom.cast_from_dynamic(reason))
  }
  death.0 <> ": " <> reason
}

/// Reverse start order, which is the only order that means anything
/// here: the strand drivers commit *through* the writer, so a writer
/// that outlives them cannot be handed a transaction by a process that
/// is already gone.
pub fn close_stops_the_drivers_before_the_writer_test() {
  let #(_path, runtime) = open_idle("close_shutdown_order")
  let watched = [
    #("driver", driver_pid(runtime)),
    #("writer", writer_pid(runtime)),
  ]
  let selector = watch(watched)
  let _closed = api.close(runtime)
  let order = list.map(deaths(selector, watched), fn(death) { death.0 })
  assert order == ["driver", "writer"]
    as "the strand driver must be gone before the writer it commits through"
}

/// And the point of all of it: the lease is released, so the same file
/// opens again at once rather than after its 60-second TTL.
pub fn close_releases_the_writer_lease_test() {
  let #(path, runtime) = open_idle("close_releases_lease")
  let assert Ok(Nil) = api.close(runtime)
    as "close must report the handle sealed"
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 2_000_000, by: 7),
    )
    as "a second opener must win the lease immediately"
  assert reopened.lease_interval_ms == Some(20_000)
  let _sealed = session.close(reopened)
}

/// A provider reaper may outlive every ordinary worker while native teardown
/// is still in flight. The drain ledger is the last root child to stop, so
/// close must keep both the supervisor and the SQLite lease alive until that
/// reaper's independently monitored owner exits.
pub fn close_holds_the_lease_until_provider_reapers_drain_test() {
  let path = fresh_path("close_waits_provider_drain")
  let rec = recorder.start()
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
  let base = idle_effects(rec)
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let eff =
    effects.Effects(
      ..base,
      provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
        let events = process.new_subject()
        let ready = process.new_subject()
        let owner =
          process.spawn_unlinked(fn() {
            let release = process.new_subject()
            process.send(ready, release)
            let _release = process.receive_forever(release)
            Nil
          })
        let release = process.receive_forever(ready)
        process.send(started, #(owner, release))
        stream.owned(events:, owner:, cancel: fn() {
          process.send(cancelled, Nil)
        })
      }),
    )
  let assert Ok(runtime) =
    api.open(opened, eff, api.default_options(harness.configuration()))
  let assert Ok(_operation) = api.prompt(runtime, [fake.user("wait")])
  let assert Ok(#(owner, release)) = process.receive(started, within: 5000)
  let closed = process.new_subject()
  let _closer =
    process.spawn_unlinked(fn() { process.send(closed, api.close(runtime)) })

  let assert Ok(Nil) = process.receive(cancelled, within: 5000)
  assert process.is_alive(owner)
  assert process.receive(closed, within: 20) == Error(Nil)
    as "close must not release the writer lease ahead of provider drain"
  process.send(release, Nil)
  let assert Ok(Ok(Nil)) = process.receive(closed, within: 5000)

  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 2_000_000, by: 7),
    )
    as "the drained session must reopen immediately"
  let _sealed = session.close(reopened)
}

/// An abnormal root death must not erase the independent drain barrier.
///
/// This is the case an orderly shutdown test cannot cover: the root has
/// already disappeared before `api.close` begins, while its trapped-exit drain
/// ledger and an old provider reaper still own a stubborn request.
pub fn close_after_root_death_still_waits_for_provider_drain_test() {
  let path = fresh_path("close_after_root_death_waits_provider_drain")
  let rec = recorder.start()
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
  let base = idle_effects(rec)
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let eff =
    effects.Effects(
      ..base,
      provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
        let events = process.new_subject()
        let ready = process.new_subject()
        let owner =
          process.spawn_unlinked(fn() {
            let release = process.new_subject()
            process.send(ready, release)
            let _release = process.receive_forever(release)
            Nil
          })
        let release = process.receive_forever(ready)
        process.send(started, #(owner, release))
        stream.owned(events:, owner:, cancel: fn() {
          process.send(cancelled, Nil)
        })
      }),
    )
  let assert Ok(runtime) =
    api.open(opened, eff, api.default_options(harness.configuration()))
  let assert Ok(_operation) = api.prompt(runtime, [fake.user("wait")])
  let assert Ok(#(owner, release)) = process.receive(started, within: 5000)

  process.kill(runtime.tree.supervisor)
  let assert Ok(Nil) = process.receive(cancelled, within: 5000)
  let closed = process.new_subject()
  let _closer =
    process.spawn_unlinked(fn() { process.send(closed, api.close(runtime)) })

  assert process.is_alive(owner)
  assert process.receive(closed, within: 20) == Error(Nil)
    as "close must retain the lease after the root dies but before drain"
  process.send(release, Nil)
  let assert Ok(Ok(Nil)) = process.receive(closed, within: 5000)

  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 2_000_000, by: 7),
    )
    as "the lease must reopen immediately after the retained drain completes"
  let _sealed = session.close(reopened)
}
