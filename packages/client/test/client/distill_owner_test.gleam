//// Original SQLite actor retirement under a managed distillation ledger.
//// Gates pause real startup-link transfer; every gate has a finite release wait.

import client/internal/distill_owner as custody
import client/memory
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session/session
import simplifile
import weft

/// Upper bound on every wait that spans real SQLite work or a gate release.
///
/// Each wait covers opening and migrating a database, committing a head
/// transaction, or a message a peer sends right after such work. With about
/// 2300 client tests sharing 32 cores, that work took longer than the earlier
/// 1 s to 3 s bounds and two tests timed out together. The waits are ceilings
/// for a run that has already been started, not delays, so a passing run pays
/// nothing for the larger value. It reuses `reply_wait_ms` from
/// `tui_approval_effect_test`, and the run deadline uses it too so that one
/// bound covers the whole run rather than a bound per message.
const work_wait_ms = 20_000

fn path(lane: String) -> String {
  let root = "build/test_db/distill-owner-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the owned test directory must exist"
  root <> "/source.db"
}

fn acquisition(
  path: String,
  arrived: Subject(#(Pid, Subject(Nil))),
) -> custody.Acquisition {
  fn() {
    use #(opened, retire, transfer) <- result.try(
      session.open_sqlite_custody(
        path:,
        owner: "owned-test",
        lease_ttl_ms: 60_000,
        clock: clock.fixed(at: 1000),
      )
      |> result.map_error(custody.OpenFailed),
    )
    Ok(
      #(opened, fn() { retire() |> result.map_error(string.inspect) }, fn() {
        use pid <- result.map(transfer())
        let release = process.new_subject()
        process.send(arrived, #(pid, release))
        let assert Ok(Nil) = process.receive(release, work_wait_ms)
          as "the transfer test gate must be released"
        pid
      }),
    )
  }
}

fn run(acquire: custody.Acquisition) -> weft.Detached(Nil, String) {
  weft.new_prepared([
    weft.managed(fn(ledger) {
      use builder <- result.try(custody.builder(ledger))
      use owned <- result.try(
        custody.open_with(ledger, builder, acquire)
        |> result.map_error(string.inspect),
      )
      custody.close(owned)
    }),
  ])
  |> weft.deadline(work_wait_ms)
  |> weft.start_detached
}

pub fn owned_distillation_closes_original_sqlite_actor_test() {
  let arrived = process.new_subject()
  let running = run(acquisition(path("normal"), arrived))
  let assert Ok(#(pid, release)) = process.receive(arrived, work_wait_ms)
    as "the actual SQLite actor must reach transfer"
  let watch = process.monitor(pid)
  process.send(release, Nil)
  let assert weft.PulledOutcome(weft.Completed(..)) =
    weft.pull(running, work_wait_ms)
    as "completion must follow owned close"
  assert weft.pull(running, work_wait_ms) == weft.AllDelivered
  let assert Ok(process.Normal) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(work_wait_ms)
    as "the original SQLite actor must retire normally"
}

pub fn owned_distillation_cancellation_during_transfer_retains_sqlite_test() {
  let arrived = process.new_subject()
  let running = run(acquisition(path("cancel-transfer"), arrived))
  let assert Ok(#(pid, release)) = process.receive(arrived, work_wait_ms)
    as "the actual SQLite actor must reach transfer"
  let watch = process.monitor(pid)
  weft.cancel_detached(running)

  // Killing the builder cannot complete the run while its holder is in transfer.
  assert weft.pull(running, 20) == weft.NotYet
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(0)
    == Error(Nil)
  process.send(release, Nil)
  let assert weft.PulledOutcome(weft.Abandoned(..)) =
    weft.pull(running, work_wait_ms)
    as "cancelled work waits for owned cleanup"
  assert weft.pull(running, work_wait_ms) == weft.AllDelivered
  let assert Ok(process.Normal) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(work_wait_ms)
    as "cancellation must close the original actor normally"
}

/// Cancellation after publication cannot remove custody during acquisition.
pub fn owned_distillation_cancellation_before_open_keeps_published_holder_test() {
  let acquiring = process.new_subject()
  let arrived = process.new_subject()
  let acquire = acquisition(path("cancel-acquire"), arrived)
  let running =
    run(fn() {
      let proceed = process.new_subject()
      process.send(acquiring, proceed)
      let assert Ok(Nil) = process.receive(proceed, work_wait_ms)
        as "the acquisition gate must be released"
      acquire()
    })
  let assert Ok(proceed) = process.receive(acquiring, work_wait_ms)
    as "the adopted holder must reach acquisition"
  weft.cancel_detached(running)
  assert weft.pull(running, 20) == weft.NotYet
  process.send(proceed, Nil)
  let assert Ok(#(pid, release)) = process.receive(arrived, work_wait_ms)
    as "the surviving holder must retain the actual acquired actor"
  let watch = process.monitor(pid)
  process.send(release, Nil)
  let assert weft.PulledOutcome(weft.Abandoned(..)) =
    weft.pull(running, work_wait_ms)
    as "cancelled acquisition must drain before an outcome"
  assert weft.pull(running, work_wait_ms) == weft.AllDelivered
  let assert Ok(process.Normal) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(work_wait_ms)
    as "the acquired actor must retire despite builder death"
}

/// A cleanup failure cannot certify retirement or erase already committed data.
pub fn owned_distillation_close_failure_retains_postcommit_custody_test() {
  process.trap_exits(True)
  let retained = process.new_subject()
  let published = process.new_subject()
  let failed = process.new_subject()
  let database = path("failed-close")
  let acquire = fn() {
    use #(opened, retire, transfer) <- result.try(
      session.open_sqlite_custody(
        path: database,
        owner: "owned-failure",
        lease_ttl_ms: 60_000,
        clock: clock.fixed(at: 1000),
      )
      |> result.map_error(custody.OpenFailed),
    )
    process.send(retained, #(process.self(), retire))
    Ok(#(
      opened,
      fn() { Error("injected close failure after commit") },
      transfer,
    ))
  }
  let running =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        use builder <- result.try(custody.builder(ledger))
        use owned <- result.try(
          custody.open_with(ledger, builder, acquire)
          |> result.map_error(string.inspect),
        )
        use opened <- result.try(
          memory.from_owned_session(
            custody.session(owned),
            ids.generator(clock.fixed(at: 1000), seed: 71),
          )
          |> result.map_error(string.inspect),
        )
        use Nil <- result.try(
          memory.advance_head(opened, ids: [], expected: None, cursors: [
            #(memory.cursor_key("source"), json.Int(7)),
          ])
          |> result.map_error(string.inspect),
        )
        process.send(published, opened)
        let outcome = custody.close(owned)
        process.send(failed, outcome)
        outcome
      }),
    ])
    |> weft.deadline(work_wait_ms)
    |> weft.cancel_grace(1000)
    |> weft.start_detached
  let assert Ok(#(holder, retire)) = process.receive(retained, work_wait_ms)
    as "test must retain cleanup for its intentionally blocked holder"
  let scope_watch = process.monitor(weft.scope_pid(running))
  let assert Ok(opened) = process.receive(published, work_wait_ms)
    as "the real head transaction must commit"
  assert process.receive(failed, work_wait_ms)
    == Ok(Error("injected close failure after commit"))
  assert weft.pull(running, 20) == weft.NotYet
  assert process.is_alive(holder)
  let assert Ok(Some(#(json.Int(7), _))) =
    memory.cell(opened, memory.cursor_key("source"))
    as "cleanup failure must not be described as rollback"
  let assert Ok(#([], Some(_))) = memory.head(opened)
    as "head and cursor remain committed together"

  // Test-only cleanup retires the actual SQLite actor, then destroys the blocked
  // proof holder. Its abnormal exit must remain loss of proof, not success.
  assert retire() == Ok(Nil)
  process.kill(holder)
  let assert weft.PulledOutcome(weft.DrainProofLost(..)) =
    weft.pull(running, work_wait_ms)
    as "destroying a blocked holder cannot establish retirement"
  // Done accounts for delivery, not drain: the original scope's exit carries
  // the verdict even when Done reaches the caller before that exit.
  assert weft.pull(running, work_wait_ms) == weft.AllDelivered
  let assert Ok(reason) =
    process.new_selector()
    |> process.select_specific_monitor(scope_watch, fn(down) { down.reason })
    |> process.selector_receive(work_wait_ms)
    as "the original scope exit must remain observable"
  assert reason != process.Normal
  process.trap_exits(False)
}
