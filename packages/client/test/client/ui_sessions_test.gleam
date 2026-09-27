//// The web view's ticket and UI-session table: a ticket is redeemed once,
//// even by two redemptions at the same moment; tickets and UI sessions
//// expire on the table's clock; a new ticket replaces the UI session a
//// browser held; and the sweep reclaims what expired.

import client/daemon/ui_sessions
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import storage/access

type Clock {
  Read(reply: Subject(Int))
  Advance(by: Int)
}

// A clock the test moves by hand. The table asks it from its own process,
// so it lives in an actor.
fn clock() -> Subject(Clock) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        Read(reply) -> {
          process.send(reply, now)
          actor.continue(now)
        }
        Advance(by) -> actor.continue(now + by)
      }
    })
    |> actor.start
    as "the test clock starts"
  started.data
}

fn table(time: Subject(Clock)) -> ui_sessions.Sessions {
  let counter = counter()
  let assert Ok(sessions) =
    ui_sessions.start(ui_sessions.Settings(
      now: fn() { process.call(time, 1000, Read) },
      entropy: fn(size) { distinct_bytes(counter, size) },
      ticket_ms: 60_000,
      session_ms: 28_800_000,
    ))
    as "the table starts"
  sessions
}

type Count {
  Next(reply: Subject(Int))
}

fn counter() -> Subject(Count) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      let Next(reply) = message
      process.send(reply, count + 1)
      actor.continue(count + 1)
    })
    |> actor.start
    as "the entropy counter starts"
  started.data
}

// Distinct bytes per call, so every ticket and cookie differs, without
// depending on the system's entropy in a test.
fn distinct_bytes(counter: Subject(Count), size: Int) -> BitArray {
  let n = process.call(counter, 1000, Next)
  <<n:size({ size * 8 })>>
}

fn grant(session: String) -> ui_sessions.Grant {
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "the fixture digest is valid"
  ui_sessions.Grant("alice", session, digest)
}

fn mint(sessions, session) -> String {
  let assert Ok(issued) = ui_sessions.mint(sessions, grant(session))
    as "a ticket is minted"
  assert issued.expires_in_ms == 60_000
  issued.ticket
}

pub fn a_ticket_is_redeemed_once_test() {
  let sessions = table(clock())
  let ticket = mint(sessions, "s1")
  let assert Ok(redeemed) = ui_sessions.redeem(sessions, ticket, None)
    as "the first redemption succeeds"
  assert redeemed.grant == grant("s1")
  assert ui_sessions.lookup(sessions, redeemed.cookie) == Ok(grant("s1"))
  assert ui_sessions.redeem(sessions, ticket, None) == Error(Nil)
}

pub fn two_redemptions_at_once_succeed_once_test() {
  let sessions = table(clock())
  let ticket = mint(sessions, "s1")
  let results = process.new_subject()

  // Twenty handlers present the same ticket at the same moment. The table
  // serializes them, so exactly one gets a UI session.
  list.repeat(Nil, 20)
  |> list.each(fn(_) {
    process.spawn(fn() {
      process.send(results, ui_sessions.redeem(sessions, ticket, None))
    })
  })
  let outcomes =
    list.repeat(Nil, 20)
    |> list.map(fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
        as "every redemption answers"
      outcome
    })
  assert list.count(outcomes, fn(outcome) { outcome != Error(Nil) }) == 1
}

pub fn a_ticket_expires_after_a_minute_test() {
  let time = clock()
  let sessions = table(time)
  let ticket = mint(sessions, "s1")
  process.send(time, Advance(60_000))
  assert ui_sessions.redeem(sessions, ticket, None) == Error(Nil)
}

pub fn a_ui_session_expires_after_eight_hours_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, mint(sessions, "s1"), None)
    as "the ticket is redeemed"
  process.send(time, Advance(28_800_000 - 1))
  assert ui_sessions.lookup(sessions, redeemed.cookie) == Ok(grant("s1"))
  process.send(time, Advance(1))
  assert ui_sessions.lookup(sessions, redeemed.cookie) == Error(Nil)
}

pub fn a_new_ticket_replaces_the_ui_session_outright_test() {
  let sessions = table(clock())
  let assert Ok(first) =
    ui_sessions.redeem(sessions, mint(sessions, "s1"), None)
    as "the first ticket is redeemed"

  // The browser presents a ticket for another session while holding the
  // first cookie. The old UI session is gone, and the new one grants only
  // the new ticket's session: nothing is merged.
  let assert Ok(second) =
    ui_sessions.redeem(sessions, mint(sessions, "s2"), Some(first.cookie))
    as "the second ticket is redeemed"
  assert second.cookie != first.cookie
  assert ui_sessions.lookup(sessions, first.cookie) == Error(Nil)
  assert ui_sessions.lookup(sessions, second.cookie) == Ok(grant("s2"))
}

pub fn the_sweep_reclaims_what_expired_test() {
  let time = clock()
  let sessions = table(time)
  let _unredeemed = mint(sessions, "s1")
  let assert Ok(_redeemed) =
    ui_sessions.redeem(sessions, mint(sessions, "s2"), None)
    as "a ticket is redeemed"
  assert ui_sessions.sizes(sessions) == Ok(#(1, 1))

  process.send(time, Advance(60_000))
  ui_sessions.sweep(sessions)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 1))

  process.send(time, Advance(28_800_000))
  ui_sessions.sweep(sessions)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 0))
}
