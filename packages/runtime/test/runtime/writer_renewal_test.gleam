//// Behavioural coverage for the writer's lease renewal.
////
//// This file replaces a structural test, and the swap is the point. The
//// renewal used to be a `process.send_after` at a subject the writer held
//// only so that the timer would be addressed to a pid rather than to the
//// writer's registered name — because an Erlang timer addressed through a
//// name outlives the process that armed it and reaches whatever
//// replacement later claims that name, so every restart would have added
//// a permanent second renewal cadence. Timing a restart against an old
//// deadline cannot prove that boundary on a slow runner, so the writer
//// exposed its subject constructor with `@internal` and the test asserted
//// the address had one pid owner and no name.
////
//// The tick is now a `weft/actor` periodic timeout, which fires into a
//// subject weft creates inside the actor's own process and never
//// registers. There is no address for a successor to inherit and no
//// constructor to assert on: the hazard is gone rather than guarded, so
//// the guard goes with it.
////
//// What is left is the behaviour the structural test never covered, and
//// which nothing else in the suite did either — that the renewal actually
//// runs on its interval, and that a lost lease stops the writer abnormally
//// rather than skipping a beat. Both are asserted here against a session
//// whose `renew_lease` the test owns.

import core/clock
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/option.{Some}
import runtime/writer
import session/session.{type Session, Session}
import storage/storage
import support/internal/ffi_memory
import support/recorder
import weft/poll
import weft/registry as address

/// A memory session whose lease renewal is the test's own function,
/// renewing every `interval` milliseconds.
///
/// `open_memory` gives a session with no lease at all
/// (`lease_interval_ms: None`), which is exactly the "never arm" case; the
/// override is what turns it into the SQLite-shaped one this file is
/// about.
fn leased_session(
  interval: Int,
  renew: fn() -> Result(Nil, storage.StorageError),
) -> Session {
  let assert Ok(session) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  Session(..session, renew_lease: renew, lease_interval_ms: Some(interval))
}

/// Starts a writer over `session`, unlinked from the test.
///
/// The unlink is not tidiness: a writer that loses its lease exits
/// abnormally, and a linked test process would die of it before it could
/// assert anything.
fn start_writer(
  session: Session,
) -> #(Pid, address.Registry, address.Address(writer.Message)) {
  let assert Ok(namespace) = address.start() as "the namespace must start"
  let name = address.new_address(namespace)
  let assert Ok(started) =
    writer.start(
      writer.Options(
        session:,
        after_commit: fn(_ordinal) { Nil },
        subscribers: [],
      ),
      name,
    )
    as "the writer must start"
  process.unlink(started.pid)
  #(started.pid, namespace, name)
}

pub fn the_writer_renews_its_lease_on_its_own_interval_test() {
  let rec = recorder.start()
  let session =
    leased_session(20, fn() {
      let _renewals = recorder.bump(rec, "renew")
      Ok(Nil)
    })
  let #(pid, namespace, _) = start_writer(session)

  // Repeatedly, not once: a one-shot timer or a re-arm that never happened
  // would leave this at exactly one, which is the failure this count is
  // chosen to separate from.
  process.sleep(300)
  assert recorder.read(rec, "renew") >= 3
  assert process.is_alive(pid)

  process.kill(pid)
  assert address.stop(namespace) == Ok(Nil)
}

pub fn a_session_with_no_lease_renews_nothing_test() {
  // The control, and the case every memory-backed test in this suite runs
  // under: `lease_interval_ms` of `None` is the switch, so nothing is armed
  // and nothing ticks.
  let rec = recorder.start()
  let assert Ok(session) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  let session =
    Session(..session, renew_lease: fn() {
      let _renewals = recorder.bump(rec, "renew")
      Ok(Nil)
    })
  let #(pid, namespace, _) = start_writer(session)

  process.sleep(300)
  assert recorder.read(rec, "renew") == 0
  assert process.is_alive(pid)

  process.kill(pid)
  assert address.stop(namespace) == Ok(Nil)
}

pub fn a_lost_lease_stops_the_writer_test() {
  // Another writer owns the file, so this tree must not keep committing.
  // Stopping abnormally is what makes the supervisor re-run the open path,
  // which re-acquires the lease or refuses loudly; a writer that logged the
  // failure and carried on would commit into a file it no longer owns.
  let rec = recorder.start()
  let session =
    leased_session(20, fn() {
      let _attempts = recorder.bump(rec, "renew")
      Error(storage.BackendFault(reason: "lease stolen"))
    })
  let #(pid, namespace, _) = start_writer(session)

  process.sleep(300)
  assert recorder.read(rec, "renew") == 1
  assert !process.is_alive(pid)
  assert address.stop(namespace) == Ok(Nil)
}

// Inspecting current_function sends no system message, so observing sleep
// cannot wake the writer or keep resetting the receive timeout under test.
fn hibernating(pid: Pid) -> Bool {
  ffi_memory.process_info(pid, atom.create("current_function"))
  == dynamic.array([
    atom.to_dynamic(atom.create("current_function")),
    dynamic.array([
      atom.to_dynamic(atom.create("erlang")),
      atom.to_dynamic(atom.create("hibernate")),
      dynamic.int(3),
    ]),
  ])
}

pub fn idle_writers_sleep_wake_and_keep_lease_custody_test() {
  let rec = recorder.start()
  let session =
    leased_session(500, fn() {
      let _renewals = recorder.bump(rec, "renew")
      case recorder.read(rec, "lost") > 0 {
        True -> Error(storage.BackendFault(reason: "lease stolen"))
        False -> Ok(Nil)
      }
    })
  let #(pid, namespace, name) = start_writer(session)
  let slept = wait_for(fn() { hibernating(pid) })
  let stats = writer.stats(name)
  let before = recorder.read(rec, "renew")
  let renewed_and_slept =
    wait_for(fn() {
      recorder.read(rec, "renew") >= before + 3 && hibernating(pid)
    })

  // Losing the lease after observing a quiet writer must still retire it.
  // Repeated renewal above also rules out resetting or losing the timer on wake.
  let _lost = recorder.bump(rec, "lost")
  let retired = wait_for(fn() { !process.is_alive(pid) })
  process.kill(pid)
  assert address.stop(namespace) == Ok(Nil)

  assert slept == poll.Answered(Nil) as "a leased idle writer must hibernate"
  let assert Ok(_) = stats as "a normal request must wake the writer"
  assert renewed_and_slept == poll.Answered(Nil)
    as "renewals continue and the writer sleeps again between them"
  assert retired == poll.Answered(Nil) as "hibernation cannot hide lease loss"
}

fn wait_for(probe: fn() -> Bool) -> poll.Outcome(Nil, Nil) {
  poll.until(within: 5000, every: 5, attempt: fn() {
    case probe() {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
}
