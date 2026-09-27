//// The web view's ticket and UI-session table: a ticket is redeemed once,
//// even by two redemptions at the same moment; tickets and UI sessions
//// expire on the table's clock; a redemption ends the principal's other UI
//// sessions for the same session; the page key and nonce a redemption hands
//// out are the only ones its UI session admits; and the sweep reclaims what
//// expired.

import client/daemon/ui_sessions
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
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
  grant_for("alice", session)
}

fn grant_for(principal: String, session: String) -> ui_sessions.Grant {
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "the fixture digest is valid"
  ui_sessions.Grant(session, digest, principal, access.Observer)
}

fn looked_up(sessions, cookie) -> Result(ui_sessions.Grant, Nil) {
  ui_sessions.lookup(sessions, cookie)
  |> result.map(ui_sessions.grant)
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
  let assert Ok(redeemed) = ui_sessions.redeem(sessions, ticket, "s1")
    as "the first redemption succeeds"
  assert redeemed.grant == grant("s1")
  assert looked_up(sessions, redeemed.cookie) == Ok(grant("s1"))
  assert ui_sessions.redeem(sessions, ticket, "s1")
    == Error(ui_sessions.UnknownTicket)
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
      process.send(results, ui_sessions.redeem(sessions, ticket, "s1"))
    })
  })
  let outcomes =
    list.repeat(Nil, 20)
    |> list.map(fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
        as "every redemption answers"
      outcome
    })
  assert list.count(outcomes, fn(outcome) {
      outcome != Error(ui_sessions.UnknownTicket)
    })
    == 1
}

pub fn a_ticket_expires_after_a_minute_test() {
  let time = clock()
  let sessions = table(time)
  let ticket = mint(sessions, "s1")
  process.send(time, Advance(60_000))
  assert ui_sessions.redeem(sessions, ticket, "s1")
    == Error(ui_sessions.UnknownTicket)
}

pub fn a_ui_session_expires_after_eight_hours_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, mint(sessions, "s1"), "s1")
    as "the ticket is redeemed"
  process.send(time, Advance(28_800_000 - 1))
  assert looked_up(sessions, redeemed.cookie) == Ok(grant("s1"))
  process.send(time, Advance(1))
  assert looked_up(sessions, redeemed.cookie) == Error(Nil)
}

// Protocol-change/051, the operator addendum: a key-scoped cookie never
// reaches the exchange, so a redemption ends every UI session of the same
// principal for the same session, and leaves another principal's page and
// the principal's page for another session alone.
pub fn a_redemption_ends_the_principals_other_pages_for_the_session_test() {
  let sessions = table(clock())
  let redeem = fn(principal, session) {
    let assert Ok(issued) =
      ui_sessions.mint(sessions, grant_for(principal, session))
      as "a ticket is minted"
    let assert Ok(redeemed) =
      ui_sessions.redeem(sessions, issued.ticket, session)
      as "the ticket is redeemed"
    redeemed.cookie
  }
  let first = redeem("alice", "s1")
  let other_session = redeem("alice", "s2")
  let other_principal = redeem("bob", "s1")
  let second = redeem("alice", "s1")
  assert second != first
  assert looked_up(sessions, first) == Error(Nil)
  assert looked_up(sessions, second) == Ok(grant_for("alice", "s1"))
  assert looked_up(sessions, other_session) == Ok(grant_for("alice", "s2"))
  assert looked_up(sessions, other_principal) == Ok(grant_for("bob", "s1"))
}

// The page key and nonce handed out with a cookie are the only ones its UI
// session admits; another page's are refused.
pub fn a_page_admits_only_its_own_key_and_nonce_test() {
  let sessions = table(clock())
  let assert Ok(one) = ui_sessions.redeem(sessions, mint(sessions, "s1"), "s1")
    as "the first ticket is redeemed"
  let assert Ok(two) = ui_sessions.redeem(sessions, mint(sessions, "s2"), "s2")
    as "the second ticket is redeemed"
  let assert Ok(page) = ui_sessions.lookup(sessions, one.cookie)
    as "the first page is live"
  assert ui_sessions.keyed(page, one.key)
  assert ui_sessions.admits(page, one.nonce)
  assert !ui_sessions.keyed(page, two.key)
  assert !ui_sessions.admits(page, two.nonce)
  assert !ui_sessions.admits(page, one.key)
  assert !ui_sessions.keyed(page, "")
  assert !ui_sessions.admits(page, "")
}

pub fn the_sweep_reclaims_what_expired_test() {
  let time = clock()
  let sessions = table(time)
  let _unredeemed = mint(sessions, "s1")
  let assert Ok(_redeemed) =
    ui_sessions.redeem(sessions, mint(sessions, "s2"), "s2")
    as "a ticket is redeemed"
  assert ui_sessions.sizes(sessions) == Ok(#(1, 1))

  process.send(time, Advance(60_000))
  ui_sessions.sweep(sessions)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 1))

  process.send(time, Advance(28_800_000))
  ui_sessions.sweep(sessions)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 0))
}

pub fn a_refused_redemption_keeps_the_browsers_ui_session_test() {
  let sessions = table(clock())
  let assert Ok(held) = ui_sessions.redeem(sessions, mint(sessions, "s1"), "s1")
    as "the browser holds a UI session"

  // A spent ticket presented with the cookie signs nothing out.
  assert ui_sessions.redeem(sessions, "not-a-ticket", "s1")
    == Error(ui_sessions.UnknownTicket)
  assert looked_up(sessions, held.cookie) == Ok(grant("s1"))
}

pub fn a_ticket_for_another_session_is_spent_and_inserts_nothing_test() {
  let sessions = table(clock())
  let assert Ok(held) = ui_sessions.redeem(sessions, mint(sessions, "s1"), "s1")
    as "the browser holds a UI session"
  let other = mint(sessions, "s2")
  assert ui_sessions.sizes(sessions) == Ok(#(1, 1))

  // Presented on the first session's path, the second session's ticket is
  // refused and spent; no UI session is added and the held one is kept.
  assert ui_sessions.redeem(sessions, other, "s1")
    == Error(ui_sessions.OtherSession)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 1))
  assert looked_up(sessions, held.cookie) == Ok(grant("s1"))
  assert ui_sessions.redeem(sessions, other, "s2")
    == Error(ui_sessions.UnknownTicket)
}
