//// What an admission does when the session has been taken from under it.
////
//// The writer lease is the single-writer rule (design §3.5): one process
//// owns a session file, and an opener that finds the lease expired steals
//// it with a bumped fence. The loser learns about it at its next commit,
//// which the backend refuses without applying anything.
////
//// That refusal is a different condition from every other commit
//// failure and has a different remedy — reopen the session, do not
//// retry — so the api must not fold it into an undifferentiated
//// `CommitFailed`. These tests take the lease away from a live runtime
//// and check what each admission path says about it.

import core/clock
import gleam/option.{Some}
import machine/operation.{ReplayNever}
import runtime/api
import runtime/effects
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

// A session nothing is ever asked of: the provider and the tools are
// never reached, because the strand is never woken. Admissions are the
// only thing that commits.
fn idle_effects() -> effects.Effects {
  fake.effects(
    recorder.start(),
    clock.stepping(from: 1_000_000, by: 7),
    [#("read", ReplayNever)],
    fn(_spec) { fake.Reply(fake.answer("unused", 1)) },
    fn(_run) {
      fake.ToolReply(text: "unused", is_error: False, terminate: False)
    },
  )
}

// Opens a SQLite-backed runtime whose strand will not act on its own:
// the checkpoint poll is ten minutes away and every admission below is
// the `_quietly` kind, so nothing rings the doorbell. That keeps the
// only commit under test the one the test makes.
fn open_quiet(name: String) -> #(String, api.Runtime) {
  let path = fresh_path(name)
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 1_000_000, by: 7),
    )
    as "the fresh sqlite session must open"
  let base = api.default_options(harness.configuration())
  let assert Ok(runtime) =
    api.open(
      opened,
      idle_effects(),
      api.Options(..base, poll_interval_ms: 600_000),
    )
    as "the session tree must boot"
  #(path, runtime)
}

// Steals the lease the way a second opener does: a clock far past the
// first lease's expiry, so the claim finds it stale and takes it with a
// bumped fence. The returned session is kept open — a released lease
// would let the original writer back in.
fn steal_lease(path: String) -> session.Session {
  let assert Ok(thief) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 9_000_000, by: 7),
    )
    as "the second opener must steal the expired lease"
  thief
}

/// A steer onto an open run whose session has been stolen must name the
/// theft. `CommitFailed` would leave the caller unable to tell "someone
/// else took the session" from "the disk is full", which are not the
/// same problem and do not have the same fix.
pub fn steer_onto_a_stolen_session_reports_the_theft_test() {
  let #(path, runtime) = open_quiet("lease_theft_steer")
  let assert Ok(_op) = api.accept_quietly(runtime, [fake.user("question")])
    as "acceptance must succeed while the lease is still ours"
  let thief = steal_lease(path)
  let outcome = api.steer_quietly(runtime, fake.user("steered"))
  let _closed = session.close(thief)
  let assert Error(api.SessionStolen(held_by:)) = outcome
    as "a stolen lease must not read as an undifferentiated commit failure"
  assert held_by == Some("writer-2")
}

/// Acceptance takes the same classification: it is the same commit
/// against the same lease.
pub fn accepting_onto_a_stolen_session_reports_the_theft_test() {
  let #(path, runtime) = open_quiet("lease_theft_accept")
  let thief = steal_lease(path)
  let outcome = api.accept_quietly(runtime, [fake.user("question")])
  let _closed = session.close(thief)
  let assert Error(api.SessionStolen(held_by:)) = outcome
    as "a stolen lease must not read as an undifferentiated commit failure"
  assert held_by == Some("writer-2")
}

/// The admission retry ladder exists for a lost seq race, which reloading
/// can win. A stolen lease is not that: every reload would read the same
/// file and every retry would be refused by the same fence, so the loop
/// must stop on the first refusal rather than burn its four attempts and
/// report `RaceLost`, which would name the wrong cause.
pub fn a_stolen_lease_does_not_exhaust_the_retry_ladder_test() {
  let #(path, runtime) = open_quiet("lease_theft_ladder")
  let assert Ok(_op) = api.accept_quietly(runtime, [fake.user("question")])
    as "acceptance must succeed while the lease is still ours"
  let thief = steal_lease(path)
  let outcome = api.steer_quietly(runtime, fake.user("steered"))
  let _closed = session.close(thief)
  assert outcome != Error(api.RaceLost)
  let assert Error(api.SessionStolen(..)) = outcome
    as "the refusal must be reported as itself, not as an exhausted ladder"
  Nil
}
