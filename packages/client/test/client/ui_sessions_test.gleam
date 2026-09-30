//// The web view's ticket and UI-session table: a ticket is redeemed once,
//// even by two redemptions at the same moment; tickets and UI sessions
//// expire on the table's clock; a redemption ends no other page, and a
//// principal holds a bounded number of pages per session; the page key and
//// nonce a redemption hands out are the only ones its UI session admits; and
//// the sweep reclaims what expired.

import client/daemon/ui_sessions
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import session_view/transcript_image
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

// A page opened by a ticket another page minted ends at the earlier of that
// page's deadline and its own eight hours, so a chain of switches cannot
// renew a page; a ticket minted with no bound keeps its own eight hours.
pub fn a_switched_page_ends_no_later_than_the_page_it_left_test() {
  let time = clock()
  let sessions = table(time)
  process.send(time, Advance(1000))
  let assert Ok(issued) = ui_sessions.mint_before(sessions, grant("s2"), 5000)
    as "a switch ticket is minted"
  let assert Ok(redeemed) = ui_sessions.redeem(sessions, issued.ticket, "s2")
    as "the ticket is redeemed"
  process.send(time, Advance(3999))
  assert looked_up(sessions, redeemed.cookie) == Ok(grant("s2"))
  process.send(time, Advance(1))
  assert looked_up(sessions, redeemed.cookie) == Error(Nil)

  // A bound past the page's own eight hours does not extend it.
  let assert Ok(far) =
    ui_sessions.mint_before(sessions, grant("s3"), 9_000_000_000)
    as "a switch ticket is minted"
  let assert Ok(page) = ui_sessions.redeem(sessions, far.ticket, "s3")
    as "the ticket is redeemed"
  process.send(time, Advance(28_800_000 - 1))
  assert looked_up(sessions, page.cookie) == Ok(grant("s3"))
  process.send(time, Advance(1))
  assert looked_up(sessions, page.cookie) == Error(Nil)
}

// A switch ticket exchanged after the page that minted it ended opens
// nothing and displaces nothing: it is refused as unknown, and the
// principal's live pages stay.
pub fn a_switch_ticket_outliving_its_source_opens_no_page_test() {
  let time = clock()
  let sessions = table(time)
  let held =
    list.map(list.repeat(Nil, ui_sessions.max_pages), fn(_) {
      let assert Ok(redeemed) =
        ui_sessions.redeem(sessions, mint(sessions, "s4"), "s4")
        as "the ticket is redeemed"
      redeemed
    })
  let assert Ok(issued) = ui_sessions.mint_before(sessions, grant("s4"), 30_000)
    as "a switch ticket is minted"
  process.send(time, Advance(30_000))
  assert ui_sessions.redeem(sessions, issued.ticket, "s4")
    == Error(ui_sessions.UnknownTicket)
  list.each(held, fn(page) {
    assert looked_up(sessions, page.cookie) == Ok(grant("s4"))
  })
}

fn redeem(sessions, principal: String, session: String) {
  let assert Ok(issued) =
    ui_sessions.mint(sessions, grant_for(principal, session))
    as "a ticket is minted"
  ui_sessions.redeem(sessions, issued.ticket, session)
}

// Protocol-change/051, the addendum on several pages: a redemption adds a
// page and ends none, whether the other pages are the principal's own for
// the same session, another principal's, or the principal's for another
// session. Each page keeps its own cookie, key and nonce.
pub fn a_redemption_leaves_every_other_page_open_test() {
  let sessions = table(clock())
  let assert Ok(first) = redeem(sessions, "alice", "s1") as "first page"
  let assert Ok(other_session) = redeem(sessions, "alice", "s2")
    as "page of another session"
  let assert Ok(other_principal) = redeem(sessions, "bob", "s1")
    as "page of another principal"
  let assert Ok(second) = redeem(sessions, "alice", "s1") as "second page"
  assert second.cookie != first.cookie
  assert second.key != first.key
  assert second.nonce != first.nonce
  assert looked_up(sessions, first.cookie) == Ok(grant_for("alice", "s1"))
  assert looked_up(sessions, second.cookie) == Ok(grant_for("alice", "s1"))
  assert looked_up(sessions, other_session.cookie)
    == Ok(grant_for("alice", "s2"))
  assert looked_up(sessions, other_principal.cookie)
    == Ok(grant_for("bob", "s1"))

  // Neither page admits the other's key or nonce, so holding two pages
  // gives a stolen key no reach beyond the page it names.
  let assert Ok(page) = ui_sessions.lookup(sessions, first.cookie)
    as "the first page is live"
  assert ui_sessions.keyed(page, first.key)
  assert !ui_sessions.keyed(page, second.key)
  assert ui_sessions.admits(page, first.nonce)
  assert !ui_sessions.admits(page, second.nonce)
}

// The bound is per principal and session. The redemption at the bound ends
// the oldest page and only that one, so the principal keeps the newest
// `max_pages`. Another principal's and another session's pages neither
// count toward the bound nor are ended by it.
pub fn the_redemption_past_the_cap_ends_only_the_oldest_page_test() {
  let sessions = table(clock())
  let assert Ok(other_session) = redeem(sessions, "alice", "s2")
    as "another session"
  let assert Ok(other_principal) = redeem(sessions, "bob", "s1")
    as "another principal"
  let held =
    list.repeat(Nil, ui_sessions.max_pages)
    |> list.map(fn(_) {
      let assert Ok(redeemed) = redeem(sessions, "alice", "s1")
        as "a page under the cap"
      redeemed.cookie
    })
  assert list.length(held) == ui_sessions.max_pages
  list.each(held, fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(grant("s1"))
  })

  let assert Ok(newest) = redeem(sessions, "alice", "s1") as "the fifth page"
  let assert [oldest, ..rest] = held
  assert looked_up(sessions, oldest) == Error(Nil)
  list.each([newest.cookie, ..rest], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(grant("s1"))
  })
  assert looked_up(sessions, other_session.cookie)
    == Ok(grant_for("alice", "s2"))
  assert looked_up(sessions, other_principal.cookie)
    == Ok(grant_for("bob", "s1"))
  assert ui_sessions.sizes(sessions) == Ok(#(0, ui_sessions.max_pages + 2))

  // The next redemption ends the next oldest, one at a time.
  let assert Ok(_) = redeem(sessions, "alice", "s1") as "the sixth page"
  let assert [second, ..] = rest
  assert looked_up(sessions, second) == Error(Nil)
  assert looked_up(sessions, newest.cookie) == Ok(grant("s1"))
}

// A page that expires ends alone at its deadline and frees its place before
// any sweep, so a redemption after it ends no live page.
pub fn an_expired_page_ends_alone_and_frees_its_place_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(old) = redeem(sessions, "alice", "s1") as "the oldest page"
  process.send(time, Advance(1000))
  let later =
    list.repeat(Nil, ui_sessions.max_pages - 1)
    |> list.map(fn(_) {
      let assert Ok(redeemed) = redeem(sessions, "alice", "s1")
        as "a page under the cap"
      redeemed.cookie
    })

  process.send(time, Advance(28_800_000 - 1000))
  assert looked_up(sessions, old.cookie) == Error(Nil)
  list.each(later, fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(grant("s1"))
  })

  // Three live pages and one expired: the new page takes the free place.
  let assert Ok(fresh) = redeem(sessions, "alice", "s1") as "the freed place"
  list.each([fresh.cookie, ..later], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(grant("s1"))
  })
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

// --- the readers of a page's images ----------------------------------------

// A reader that answers every request with one image, so a test can tell
// which reader it was handed by what it answers.
fn reader(data: String) -> ui_sessions.Images {
  fn(_, _) { Ok(transcript_image.Image("image/png", data)) }
}

fn answer(images: ui_sessions.Images) -> Result(String, Nil) {
  images("1.0", 0) |> result.map(fn(image) { image.data })
}

fn read(sessions, cookie) -> Result(String, Nil) {
  ui_sessions.images(sessions, cookie) |> result.try(answer)
}

fn live_page(sessions, session) -> ui_sessions.Redeemed {
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, mint(sessions, session), session)
    as "a page is live"
  redeemed
}

pub fn a_reader_is_found_through_its_live_page_test() {
  let sessions = table(clock())
  let page = live_page(sessions, "s1")
  assert read(sessions, page.cookie) == Error(Nil)
  ui_sessions.register_images(sessions, page.cookie, reader("one"))
  assert read(sessions, page.cookie) == Ok("one")
  assert read(sessions, "not-a-cookie") == Error(Nil)
}

pub fn each_page_has_its_own_reader_and_a_new_socket_replaces_it_test() {
  let sessions = table(clock())
  let first = live_page(sessions, "s1")
  let second = live_page(sessions, "s1")
  ui_sessions.register_images(sessions, first.cookie, reader("first"))
  ui_sessions.register_images(sessions, second.cookie, reader("second"))
  assert read(sessions, first.cookie) == Ok("first")
  assert read(sessions, second.cookie) == Ok("second")

  // A reload opens a new socket for the same page, which replaces the reader
  // the old socket left and leaves the other page's alone.
  ui_sessions.register_images(sessions, first.cookie, reader("reloaded"))
  assert read(sessions, first.cookie) == Ok("reloaded")
  assert read(sessions, second.cookie) == Ok("second")
}

pub fn a_cookie_that_names_no_live_page_leaves_no_reader_test() {
  let time = clock()
  let sessions = table(time)
  let page = live_page(sessions, "s1")
  ui_sessions.register_images(sessions, "not-a-cookie", reader("stray"))
  assert read(sessions, "not-a-cookie") == Error(Nil)

  // A page that has ended is not read through, and a socket that registers
  // after its page ended leaves nothing behind.
  ui_sessions.register_images(sessions, page.cookie, reader("live"))
  assert read(sessions, page.cookie) == Ok("live")
  process.send(time, Advance(28_800_000))
  assert read(sessions, page.cookie) == Error(Nil)
  ui_sessions.register_images(sessions, page.cookie, reader("late"))
  assert read(sessions, page.cookie) == Error(Nil)
}

pub fn a_sweep_does_not_end_a_live_pages_reader_test() {
  let time = clock()
  let sessions = table(time)
  let page = live_page(sessions, "s1")
  ui_sessions.register_images(sessions, page.cookie, reader("kept"))
  process.send(time, Advance(60_000))
  ui_sessions.sweep(sessions)
  assert read(sessions, page.cookie) == Ok("kept")
}
