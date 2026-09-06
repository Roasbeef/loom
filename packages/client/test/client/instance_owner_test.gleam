//// Ownership tests over controllable cleanup capabilities. These prove the
//// holder's ordering and failure policy, not the retirement of real helpers,
//// SQLite connections, or runtime effects; assembly tests must prove those.

import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session/session
import simplifile
import storage/sqlite

fn parked() -> #(Pid, Subject(Nil)) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      process.send(ready, release)
      process.receive_forever(release)
    })
  let assert Ok(release) = process.receive(ready, 1000) as "worker parked"
  #(pid, release)
}

fn down(watch: Monitor, within: Int) {
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(down) { down })
  |> process.selector_receive(within)
}

fn new_owner() {
  let #(builder, _release) = parked()
  let failures = process.new_subject()
  let assert Ok(owner) =
    custody.start(
      builder,
      fn() { process.kill(builder) },
      consumer: process.self(),
      failures:,
    )
    as "custody published before builder begins"
  #(owner, builder, failures)
}

pub fn real_sqlite_lease_remains_held_until_owned_drain_finishes_test() {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 491)
  let #(file_id, _) = ids.mint_session(generator)
  let path =
    "build/test_db/custody-" <> ids.session_id_to_string(file_id) <> ".db"
  let assert Ok(Nil) = simplifile.create_directory_all("build/test_db")
    as "test database directory exists"
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path:,
      owner: "custody-writer",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 1000),
    )
    as "owned SQLite connection opens"
  let assert Ok(#(identity, _)) = session.ensure_id(opened, generator)
    as "canonical identity is stored before runtime recovery"
  let #(owner, _builder, _failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let draining = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      retire() |> result.map_error(string.inspect)
    })
    as "real connection cleanup is retained independently of its builder"
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      let release = process.new_subject()
      process.send(draining, release)
      process.receive_forever(release)
      Ok(Nil)
    })
    as "runtime drain can outlive the report deadline"

  assert custody.close(owner, within_ms: 20) == custody.StillClosing
  let assert Ok(release) = process.receive(draining, 1000) as "drain started"
  let assert Error(session.SqliteOpenFailed(sqlite.LeaseHeld(..))) =
    session.open_sqlite_owned(
      path:,
      owner: "replacement-writer",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 1001),
    )
    as "a report timeout does not release the real writer lease"
  assert session.id(opened) == Ok(Some(identity))

  process.send(release, Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "custody reports retirement only after the connection actor exits"
  let assert Ok(#(replacement, retire_replacement)) =
    session.open_sqlite_owned(
      path:,
      owner: "replacement-writer",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 1001),
    )
    as "confirmed cleanup permits immediate reopen without waiting for TTL"
  assert session.id(replacement) == Ok(Some(identity))
  assert retire_replacement() == Ok(Nil)
}

pub fn cleanup_uses_dependency_order_not_publication_order_test() {
  let #(owner, _builder, failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let steps = process.new_subject()
  let order = [
    custody.Runtime,
    custody.Services,
    custody.Broker,
    custody.Helpers,
    custody.Mcp,
    custody.Storage,
    custody.Namespace,
  ]
  list.each(list.reverse(order), fn(part) {
    let assert Ok(Nil) =
      custody.publish(owner, part, fn() {
        process.send(steps, part)
        Ok(Nil)
      })
      as "each boundary publishes once"
  })

  custody.cancel(owner)
  custody.cancel(owner)
  list.each(order, fn(part) {
    assert process.receive(steps, 1000) == Ok(part)
  })
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "witness retires normally after all cleanup"
  assert process.receive(steps, 0) == Error(Nil)
  assert process.receive(failures, 0) == Error(Nil)
}

pub fn raw_builder_death_initiates_cleanup_test() {
  let #(owner, builder, failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "partial boot published its connection"

  // There is no task result and no explicit cancel from the consumer.
  process.kill(builder)
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "builder kill did not lose published custody"
  assert process.receive(failures, 0) == Error(Nil)
}

pub fn cleanup_waits_for_builder_exit_test() {
  let #(builder, release) = parked()
  let stopped = process.new_subject()
  let steps = process.new_subject()
  let failures = process.new_subject()
  let assert Ok(owner) =
    custody.start(
      builder,
      fn() { process.send(stopped, Nil) },
      consumer: process.self(),
      failures:,
    )
    as "custody started"
  let watch = process.monitor(custody.owner(owner))
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      process.send(steps, Nil)
      Ok(Nil)
    })
    as "runtime cleanup published"

  custody.cancel(owner)
  assert process.receive(stopped, 1000) == Ok(Nil)
  assert process.receive(steps, 100) == Error(Nil)
  assert down(watch, 0) == Error(Nil)
  process.send(release, Nil)
  assert process.receive(steps, 1000) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "cleanup followed builder exit"
}

pub fn pending_drain_retains_storage_and_refuses_publication_test() {
  let #(owner, _builder, _failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let draining = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      let release = process.new_subject()
      process.send(draining, release)
      process.receive_forever(release)
      Ok(Nil)
    })
    as "runtime cleanup published"
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "storage cleanup published"

  custody.cancel(owner)
  let assert Ok(release) = process.receive(draining, 1000) as "drain began"
  assert process.receive(closed, 100) == Error(Nil)
  assert down(watch, 0) == Error(Nil)
  let assert Error(_) =
    custody.publish(owner, custody.Namespace, fn() { Ok(Nil) })
    as "closing cannot admit new work"
  process.send(release, Nil)
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "successful drain released the storage step"
}

pub fn duplicate_publication_does_not_replace_cleanup_test() {
  let #(owner, _builder, _failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, "original")
      Ok(Nil)
    })
    as "first publication accepted"
  let assert Error(_) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, "replacement")
      Ok(Nil)
    })
    as "duplicate cannot overwrite the first resource"
  custody.cancel(owner)
  assert process.receive(closed, 1000) == Ok("original")
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "original cleanup completed"
  assert process.receive(closed, 0) == Error(Nil)
}

pub fn failed_drain_retains_the_reservation_and_lease_test() {
  let #(owner, _builder, failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      Error("drain proof was lost")
    })
    as "failing runtime cleanup published"
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "lease release published"

  custody.cancel(owner)
  assert process.receive(failures, 1000)
    == Ok(custody.Failed(custody.Runtime, "drain proof was lost"))
  custody.cancel(owner)
  assert process.receive(closed, 100) == Error(Nil)
  assert down(watch, 0) == Error(Nil)
  assert process.receive(failures, 0) == Error(Nil)
  process.demonitor_process(watch)
  // The unresolved witness deliberately survives until this test VM exits.
  // Killing it to make a process-count assertion pass would erase the proof
  // that a production daemon must retain as a blocked reservation.
}

pub fn cleanup_worker_crash_does_not_run_lease_release_test() {
  let #(owner, _builder, failures) = new_owner()
  let watch = process.monitor(custody.owner(owner))
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      panic as "injected cleanup worker crash"
    })
    as "crashing cleanup published"
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "lease release published"

  custody.cancel(owner)
  let assert Ok(custody.Interrupted(_)) = process.receive(failures, 1000)
    as "worker crash is not a successful close"
  assert process.receive(closed, 100) == Error(Nil)
  assert down(watch, 0) == Error(Nil)
  process.demonitor_process(watch)
}

pub fn consumer_death_cancels_builder_and_partial_resources_test() {
  let #(builder, _release_builder) = parked()
  let #(consumer, release_consumer) = parked()
  let failures = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    custody.start(builder, fn() { process.kill(builder) }, consumer:, failures:)
    as "custody watches its independent consumer"
  let watch = process.monitor(custody.owner(owner))
  let builder_watch = process.monitor(builder)
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "partial boot published its connection"

  process.send(release_consumer, Nil)
  let assert Ok(process.ProcessDown(..)) = down(builder_watch, 1000)
    as "consumer death cancelled the builder"
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "partial resources drained after consumer death"
}

pub fn close_reports_success_only_after_cleanup_test() {
  let #(owner, _builder, _failures) = new_owner()
  let closed = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Storage, fn() {
      process.send(closed, Nil)
      Ok(Nil)
    })
    as "storage cleanup published"
  assert custody.close(owner, within_ms: 1000) == custody.Closed
  assert process.receive(closed, 0) == Ok(Nil)
}

pub fn close_deadline_reports_without_destroying_custody_test() {
  let #(owner, _builder, _failures) = new_owner()
  let entered = process.new_subject()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() {
      let release = process.new_subject()
      process.send(entered, release)
      process.receive_forever(release)
      Ok(Nil)
    })
    as "delayed cleanup published"

  assert custody.close(owner, within_ms: 20) == custody.StillClosing
  let assert Ok(release) = process.receive(entered, 1000)
    as "cleanup is pending"
  let watch = process.monitor(custody.owner(owner))
  assert down(watch, 0) == Error(Nil)
  process.send(release, Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    down(watch, 1000)
    as "late drain proof survived the report deadline"
}

pub fn close_retains_failure_for_later_callers_test() {
  let #(owner, _builder, _failures) = new_owner()
  let assert Ok(Nil) =
    custody.publish(owner, custody.Runtime, fn() { Error("unconfirmed drain") })
    as "failing cleanup published"
  let failure =
    custody.RecoveryBlocked(custody.Failed(custody.Runtime, "unconfirmed drain"))
  assert custody.close(owner, within_ms: 1000) == failure
  assert custody.close(owner, within_ms: 1000) == failure
}
