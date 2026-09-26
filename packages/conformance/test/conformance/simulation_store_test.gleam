//// The instrumented store's accounting fence.
////
//// The inner memory actor makes a commit visible when it replies, while the
//// wrapper records its counters immediately afterward. The runner reads the
//// inner store directly, so it must see the accounting fence before the inner
//// commit begins or it can accept a terminal result before the counters move.

import conformance/simulation/control.{type Control}
import conformance/simulation/fault
import conformance/simulation/script
import conformance/simulation/store
import core/clock
import core/json
import core/message.{UserMessage, UserText}
import core/register
import core/tx
import gleam/erlang/process
import gleam/option.{None, Some}
import machine/codec
import machine/operation
import session/session.{type Session, Session}
import storage/storage.{type Storage, Storage}

fn probe_commit(
  raw: Session,
  ctl: Control,
  observed: process.Subject(#(Bool, Int)),
  fail: Bool,
) -> Session {
  let inner = raw.store
  let probed: Storage(Nil) =
    Storage(..inner, commit: fn(_handle, transaction) {
      case fail {
        True -> {
          process.send(observed, #(
            control.seam_quiet(ctl),
            control.commits(ctl),
          ))
          Error(tx.Faulted(reason: "injected probe failure"))
        }
        False -> {
          let result = storage.commit(inner, transaction)
          process.send(observed, #(
            control.seam_quiet(ctl),
            control.commits(ctl),
          ))
          result
        }
      }
    })
  Session(..raw, store: probed)
}

fn instrumented_probe(
  ctl: Control,
  observed: process.Subject(#(Bool, Int)),
  fail: Bool,
) -> #(Session, Session) {
  let assert Ok(raw) = session.open_memory(clock.fixed(at: 1_700_000_000_000))
    as "the probe session must open"
  let probed = probe_commit(raw, ctl, observed, fail)
  let instrumented =
    store.instrument(
      probed,
      ctl,
      fault.none(),
      strand: "main",
      lease_interval_ms: 5,
    )
  #(raw, instrumented)
}

/// The accounting fence remains active after the inner commit is visible, and
/// a successful commit keeps the post-commit seam open until the writer closes
/// it.
pub fn accounting_fence_precedes_visible_commit_test() {
  let ctl = control.start()
  let observed = process.new_subject()
  let #(raw, instrumented) = instrumented_probe(ctl, observed, False)
  control.arm(ctl)

  let assert Ok(_) =
    storage.commit(
      instrumented.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.StrandLastResult,
            key: "main",
            value: register.value(json.Null),
          ),
        ],
        expected: [],
      ),
    )
    as "the probe commit must succeed"
  let assert Ok(#(quiet_inside_commit, commits_inside_commit)) =
    process.receive(observed, within: 1000)
    as "the probe must observe the accounting fence"
  assert !quiet_inside_commit
    as "the accounting fence must remain open after the inner commit lands"
  assert commits_inside_commit == 0
    as "the atomic fence-to-seam handoff must follow durable visibility"
  assert control.read(ctl, "last_result:main") == 1
    as "the terminal counter must move before the fence closes"
  assert !control.seam_quiet(ctl)
    as "a successful commit must leave its post-commit seam open"

  control.seam_done(ctl)
  assert control.seam_quiet(ctl)
  let assert Ok(Nil) = session.close(raw) as "the probe session must close"
  control.stop(ctl)
}

/// A writer killed inside its post-commit seam releases that seam, even when
/// the crash was noted before the writer opened it, and a recovered writer
/// still owes the seam its own commit opens.
///
/// An effect-started crash sends its note and then kills the writer from
/// another process, so the writer can commit and open a seam in between. The
/// seam belongs to the dead writer, and nothing else will ever close it.
pub fn recovered_commit_must_close_its_own_seam_test() {
  let ctl = control.start()
  control.arm(ctl)

  // The note is settled before the doomed writer starts, which is the order
  // an effect-started crash can produce when the kill lands late.
  control.note_crash(ctl)
  assert control.crashed(ctl) as "the injected crash must be recorded"

  let opened = process.new_subject()
  let doomed =
    process.spawn_unlinked(fn() {
      let _first = control.note_commit(ctl)
      process.send(opened, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(opened, within: 1000)
    as "the doomed writer must open its seam"
  assert !control.seam_quiet(ctl)
    as "a live writer's seam must hold the run open"

  kill_and_wait(doomed)
  assert control.seam_quiet(ctl) as "the killed writer's seam must close"

  let _second = control.note_commit(ctl)
  assert !control.seam_quiet(ctl)
    as "a recovered writer's commit must open a new seam"
  control.seam_done(ctl)
  assert control.seam_quiet(ctl)
  control.stop(ctl)
}

/// A writer killed after its commit became visible and before the wrapper
/// recorded it releases the accounting fence it opened.
///
/// This is the stall seeds 30 and 44 reached (issue #335): an effect-started
/// crash killed the writer between `commit_started` and `commit_succeeded`,
/// the in-flight count never came back down, and the runner waited out its
/// whole idle budget on a terminal result that was already visible.
pub fn killed_writer_releases_its_accounting_fence_test() {
  let ctl = control.start()
  let inside = process.new_subject()
  let assert Ok(raw) = session.open_memory(clock.fixed(at: 1_700_000_000_000))
    as "the probe session must open"
  let instrumented =
    store.instrument(
      parking_commit(raw, inside),
      ctl,
      fault.none(),
      strand: "main",
      lease_interval_ms: 5,
    )
  control.arm(ctl)

  let writer =
    process.spawn_unlinked(fn() {
      storage.commit(instrumented.store, terminal_transaction())
    })
  let assert Ok(Nil) = process.receive(inside, within: 1000)
    as "the writer must park after the inner commit lands"
  assert !control.seam_quiet(ctl)
    as "a live writer's in-flight commit must hold the fence"

  kill_and_wait(writer)
  assert control.seam_quiet(ctl)
    as "a killed writer's in-flight commit must release its fence"
  assert control.notes(ctl) == []
    as "releasing a dead writer's fence is not an accounting violation"
  let assert Ok(Nil) = session.close(raw) as "the probe session must close"
  control.stop(ctl)
}

// The inner commit lands and the committing process then parks for good,
// which holds it at exactly the point an effect-started crash can kill it:
// the commit is durable and visible, and the wrapper has not yet recorded it.
fn parking_commit(raw: Session, inside: process.Subject(Nil)) -> Session {
  let inner = raw.store
  let parked: Storage(Nil) =
    Storage(..inner, commit: fn(_handle, transaction) {
      let _landed = storage.commit(inner, transaction)
      process.send(inside, Nil)
      process.sleep_forever()
      Error(tx.Faulted(reason: "unreachable: the committer parks forever"))
    })
  Session(..raw, store: parked)
}

fn terminal_transaction() -> tx.Tx {
  tx.Tx(
    writes: [
      tx.SetRegister(
        ns: register.StrandLastResult,
        key: "main",
        value: register.value(json.Null),
      ),
    ],
    expected: [],
  )
}

// The monitor's DOWN is the proof the process is gone; a kill signal alone
// is only a request that has not necessarily been delivered yet.
fn kill_and_wait(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(within: 1000)
    as "the killed writer must go down"
  Nil
}

/// An unmatched accounting close is recorded and leaves the fence closed.
pub fn accounting_underflow_fails_closed_test() {
  let ctl = control.start()
  control.arm(ctl)

  control.commit_failed(ctl)
  assert !control.seam_quiet(ctl)
    as "an accounting underflow must not report a quiet seam"
  control.commit_started(ctl)
  control.commit_failed(ctl)
  assert !control.seam_quiet(ctl)
    as "an accounting poison must survive later commit lifecycle calls"
  assert control.notes(ctl) == ["commit accounting underflow"]
    as "an accounting underflow must identify the harness violation"
  control.stop(ctl)
}

/// A refused inner commit releases the accounting fence because there is no
/// successful commit and therefore no post-commit seam for a writer to close.
pub fn failed_commit_releases_accounting_fence_test() {
  let ctl = control.start()
  let observed = process.new_subject()
  let #(raw, instrumented) = instrumented_probe(ctl, observed, True)
  control.arm(ctl)

  let assert Error(tx.Faulted(reason: "injected probe failure")) =
    storage.commit(instrumented.store, tx.Tx(writes: [], expected: []))
  let assert Ok(#(quiet_inside_commit, commits_inside_commit)) =
    process.receive(observed, within: 1000)
    as "the probe must observe the accounting fence"
  assert !quiet_inside_commit
    as "the accounting fence must open before the inner commit begins"
  assert commits_inside_commit == 0
    as "a refused commit must not advance the commit ordinal"
  assert control.seam_quiet(ctl)
    as "a failed commit must release its accounting fence"

  let assert Ok(Nil) = session.close(raw) as "the probe session must close"
  control.stop(ctl)
}

/// A simulated intervention's pending entry and its admission marker are one
/// guarded transaction. Retrying the same identity cannot enqueue a second
/// copy, even when it uses a fresh pending-entry key.
pub fn intervention_admission_is_atomic_and_write_once_test() {
  let ctl = control.start()
  let assert Ok(raw) = session.open_memory(clock.fixed(at: 1_700_000_000_000))
    as "the admission session must open"
  let instrumented =
    store.instrument(
      raw,
      ctl,
      fault.none(),
      strand: "main",
      lease_interval_ms: 5,
    )
  let intervention =
    script.FollowUp(trigger: script.DuringTurn(turn: 1), text: "queued")
  let identity = script.intervention_key(intervention)
  let fact_key = script.intervention_fact_key(identity)
  let pending =
    register.value(
      codec.encode_pending_entry(
        operation.PendingMessage(message: UserMessage(
          content: [
            UserText(text: "queued", text_signature: Some(identity)),
          ],
          timestamp: 0,
          origin: None,
        )),
      ),
    )

  let assert Ok(_) =
    storage.commit(
      instrumented.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.PendingEntry,
            key: "main/first",
            value: pending,
          ),
        ],
        expected: [],
      ),
    )
    as "the first admission must commit"
  let assert Ok(Some(storage.Register(value: marker, ..))) =
    storage.get_register(raw.store, register.FactCustom, fact_key)
    as "the admission marker must be durable with the pending entry"
  assert marker.payload == json.Null
    as "the admission marker payload must use the reserved null value"
  control.seam_done(ctl)

  let assert Error(tx.StaleExpectation(failed: tx.Expect(
    ns: register.FactCustom,
    key: failed_key,
    seq: None,
  ))) =
    storage.commit(
      instrumented.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.PendingEntry,
            key: "main/second",
            value: pending,
          ),
        ],
        expected: [],
      ),
    )
    as "a retry of the same identity must lose the absent guard"
  assert failed_key == fact_key
    as "the retry must conflict on the durable admission marker"
  assert storage.get_register(raw.store, register.PendingEntry, "main/second")
    == Ok(None)
    as "a losing retry must not enqueue a duplicate pending entry"

  let assert Ok(Nil) = session.close(raw) as "the admission session must close"
  control.stop(ctl)
}
