//// The web view's ticket and UI-session table: a ticket is redeemed once,
//// even by two redemptions at the same moment; tickets and UI sessions
//// expire on the table's clock; a redemption ends no other page, and a
//// principal holds a bounded number of pages per session; the page key and
//// nonce a redemption hands out are the only ones its UI session admits; and
//// the sweep reclaims what expired.

import client/daemon/ui_sessions
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import host/bootstrap
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

// The wall clock is far from the table's own, as the real two are: the monotonic
// clock's zero is arbitrary and the wall's is 1970. A login's end is written in
// wall terms, so a table that compared it with the monotonic reading would
// disagree with every test that moves the two by the same amount.
const wall_offset = 1_700_000_000_000

fn table(time: Subject(Clock)) -> ui_sessions.Sessions {
  let counter = counter()
  let assert Ok(sessions) =
    ui_sessions.start(ui_sessions.Settings(
      now: fn() { process.call(time, 1000, Read) },
      wall: fn() { process.call(time, 1000, Read) + wall_offset },
      entropy: fn(size) { distinct_bytes(counter, size) },
      ticket_ms: 60_000,
      device_ms: 600_000,
      session_ms: 28_800_000,
    ))
    as "the table starts"
  sessions
}

// Whether a reservation was refused, whatever instant the refusal names.
fn refused(reservation: Result(Nil, Int)) -> Bool {
  case reservation {
    Error(_) -> True
    Ok(Nil) -> False
  }
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
  ui_sessions.Grant(
    ui_sessions.Session(session),
    digest,
    principal,
    access.Observer,
    ui_sessions.OneSession,
    ui_sessions.Fresh,
    ui_sessions.Forgotten,
  )
}

// A home grant for `principal`, opened from `loom ui` with no session.
fn home_for(principal: String) -> ui_sessions.Grant {
  ui_sessions.Grant(
    ..grant_for(principal, ""),
    scope: ui_sessions.Home,
    reach: ui_sessions.Workspace,
  )
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
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, ticket, ui_sessions.SessionExchange("s1"))
    as "the first redemption succeeds"
  assert redeemed.grant == grant("s1")
  assert looked_up(sessions, redeemed.cookie) == Ok(grant("s1"))
  assert ui_sessions.redeem(sessions, ticket, ui_sessions.SessionExchange("s1"))
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
      process.send(
        results,
        ui_sessions.redeem(sessions, ticket, ui_sessions.SessionExchange("s1")),
      )
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
  assert ui_sessions.redeem(sessions, ticket, ui_sessions.SessionExchange("s1"))
    == Error(ui_sessions.UnknownTicket)
}

pub fn a_ui_session_expires_after_eight_hours_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(redeemed) =
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s1"),
      ui_sessions.SessionExchange("s1"),
    )
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
  let assert Ok(redeemed) =
    ui_sessions.redeem(
      sessions,
      issued.ticket,
      ui_sessions.SessionExchange("s2"),
    )
    as "the ticket is redeemed"
  process.send(time, Advance(3999))
  assert looked_up(sessions, redeemed.cookie) == Ok(grant("s2"))
  process.send(time, Advance(1))
  assert looked_up(sessions, redeemed.cookie) == Error(Nil)

  // A bound past the page's own eight hours does not extend it.
  let assert Ok(far) =
    ui_sessions.mint_before(sessions, grant("s3"), 9_000_000_000)
    as "a switch ticket is minted"
  let assert Ok(page) =
    ui_sessions.redeem(sessions, far.ticket, ui_sessions.SessionExchange("s3"))
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
        ui_sessions.redeem(
          sessions,
          mint(sessions, "s4"),
          ui_sessions.SessionExchange("s4"),
        )
        as "the ticket is redeemed"
      redeemed
    })
  let assert Ok(issued) = ui_sessions.mint_before(sessions, grant("s4"), 30_000)
    as "a switch ticket is minted"
  process.send(time, Advance(30_000))
  assert ui_sessions.redeem(
      sessions,
      issued.ticket,
      ui_sessions.SessionExchange("s4"),
    )
    == Error(ui_sessions.UnknownTicket)
  list.each(held, fn(page) {
    assert looked_up(sessions, page.cookie) == Ok(grant("s4"))
  })
}

fn redeem(sessions, principal: String, session: String) {
  let assert Ok(issued) =
    ui_sessions.mint(sessions, grant_for(principal, session))
    as "a ticket is minted"
  ui_sessions.redeem(
    sessions,
    issued.ticket,
    ui_sessions.SessionExchange(session),
  )
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
  let assert Ok(one) =
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s1"),
      ui_sessions.SessionExchange("s1"),
    )
    as "the first ticket is redeemed"
  let assert Ok(two) =
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s2"),
      ui_sessions.SessionExchange("s2"),
    )
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
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s2"),
      ui_sessions.SessionExchange("s2"),
    )
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
  let assert Ok(held) =
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s1"),
      ui_sessions.SessionExchange("s1"),
    )
    as "the browser holds a UI session"

  // A spent ticket presented with the cookie signs nothing out.
  assert ui_sessions.redeem(
      sessions,
      "not-a-ticket",
      ui_sessions.SessionExchange("s1"),
    )
    == Error(ui_sessions.UnknownTicket)
  assert looked_up(sessions, held.cookie) == Ok(grant("s1"))
}

pub fn a_ticket_for_another_session_is_spent_and_inserts_nothing_test() {
  let sessions = table(clock())
  let assert Ok(held) =
    ui_sessions.redeem(
      sessions,
      mint(sessions, "s1"),
      ui_sessions.SessionExchange("s1"),
    )
    as "the browser holds a UI session"
  let other = mint(sessions, "s2")
  assert ui_sessions.sizes(sessions) == Ok(#(1, 1))

  // Presented on the first session's path, the second session's ticket is
  // refused and spent; no UI session is added and the held one is kept.
  assert ui_sessions.redeem(sessions, other, ui_sessions.SessionExchange("s1"))
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 1))
  assert looked_up(sessions, held.cookie) == Ok(grant("s1"))
  assert ui_sessions.redeem(sessions, other, ui_sessions.SessionExchange("s2"))
    == Error(ui_sessions.UnknownTicket)
}

// --- the home's scope (protocol-change/065) ---------------------------------

fn home_ticket(sessions, principal: String) -> String {
  let assert Ok(issued) = ui_sessions.mint(sessions, home_for(principal))
    as "a home ticket is minted"
  issued.ticket
}

// The scope is part of the redemption. A home ticket redeems at the home and
// keeps what it was minted with, a reach of `Workspace` among it.
pub fn a_home_ticket_redeems_at_the_home_test() {
  let sessions = table(clock())
  let assert Ok(redeemed) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "alice"),
      ui_sessions.HomeExchange,
    )
    as "the home ticket is redeemed"
  assert redeemed.grant == home_for("alice")
  assert redeemed.grant.reach == ui_sessions.Workspace
  assert looked_up(sessions, redeemed.cookie) == Ok(home_for("alice"))
}

// A session's ticket presented at the home exchange, and a home ticket
// presented at a session's, are each refused and each spent, and neither
// adds a page or ends one.
pub fn a_ticket_of_the_other_scope_is_spent_and_inserts_nothing_test() {
  let sessions = table(clock())
  let assert Ok(held) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "alice"),
      ui_sessions.HomeExchange,
    )
    as "the browser holds a home page"
  let session_ticket = mint(sessions, "s1")
  let home = home_ticket(sessions, "alice")
  assert ui_sessions.sizes(sessions) == Ok(#(2, 1))

  assert ui_sessions.redeem(sessions, session_ticket, ui_sessions.HomeExchange)
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.redeem(sessions, home, ui_sessions.SessionExchange("s1"))
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 1))
  assert looked_up(sessions, held.cookie) == Ok(home_for("alice"))

  // Both tickets are spent, so a second try at the right exchange fails too.
  assert ui_sessions.redeem(
      sessions,
      session_ticket,
      ui_sessions.SessionExchange("s1"),
    )
    == Error(ui_sessions.UnknownTicket)
  assert ui_sessions.redeem(sessions, home, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)
}

// The bound is on a principal's homes, counted apart from its session pages:
// a fifth home ends the oldest home and no session page, and a fifth session
// page ends no home. Another principal's homes are not counted.
pub fn the_page_cap_is_counted_per_scope_test() {
  let sessions = table(clock())
  let assert Ok(session_page) = redeem(sessions, "alice", "s1")
    as "a session page"
  let assert Ok(other_principal) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "bob"),
      ui_sessions.HomeExchange,
    )
    as "another principal's home"
  let homes =
    list.repeat(Nil, ui_sessions.max_pages)
    |> list.map(fn(_) {
      let assert Ok(redeemed) =
        ui_sessions.redeem(
          sessions,
          home_ticket(sessions, "alice"),
          ui_sessions.HomeExchange,
        )
        as "a home under the cap"
      redeemed.cookie
    })
  let assert Ok(newest) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "alice"),
      ui_sessions.HomeExchange,
    )
    as "the fifth home"
  let assert [oldest, ..rest] = homes
  assert looked_up(sessions, oldest) == Error(Nil)
  list.each([newest.cookie, ..rest], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(home_for("alice"))
  })
  assert looked_up(sessions, session_page.cookie) == Ok(grant("s1"))
  assert looked_up(sessions, other_principal.cookie) == Ok(home_for("bob"))

  // Session pages up to their own cap leave every home standing.
  list.each(list.repeat(Nil, ui_sessions.max_pages), fn(_) {
    let assert Ok(_) = redeem(sessions, "alice", "s1") as "a session page"
    Nil
  })
  list.each([newest.cookie, ..rest], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(home_for("alice"))
  })
}

// --- the admin page (protocol-change/065, the fifth pull request) -------------

// An admin grant for `principal`: the owner's page, minted to operate, from a
// home.
fn admin_for(principal: String) -> ui_sessions.Grant {
  ui_sessions.Grant(..home_for(principal), scope: ui_sessions.Admin)
}

fn admin_ticket(sessions, principal: String) -> String {
  let assert Ok(issued) = ui_sessions.mint(sessions, admin_for(principal))
    as "an admin ticket is minted"
  issued.ticket
}

// An admin page lives fifteen minutes from its exchange, and a home opened at the
// same moment lives eight hours: the admin page's end leaves the home alone.
pub fn an_admin_page_ends_at_fifteen_minutes_and_the_home_does_not_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(home) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "alice"),
      ui_sessions.HomeExchange,
    )
    as "the home is opened"
  let assert Ok(admin) =
    ui_sessions.redeem(
      sessions,
      admin_ticket(sessions, "alice"),
      ui_sessions.AdminExchange,
    )
    as "the admin page is opened"
  assert admin.grant == admin_for("alice")
  assert ui_sessions.admin_ms == 900_000

  process.send(time, Advance(ui_sessions.admin_ms - 1))
  assert looked_up(sessions, admin.cookie) == Ok(admin_for("alice"))
  process.send(time, Advance(1))
  assert looked_up(sessions, admin.cookie) == Error(Nil)

  // The home that opened beside it is unaffected, up to its own eight hours.
  assert looked_up(sessions, home.cookie) == Ok(home_for("alice"))
  process.send(time, Advance(28_800_000 - ui_sessions.admin_ms - 1))
  assert looked_up(sessions, home.cookie) == Ok(home_for("alice"))
  process.send(time, Advance(1))
  assert looked_up(sessions, home.cookie) == Error(Nil)
}

// The admin page, opened from a home, ends no later than that home, so a chain
// home, admin never outlives the home it began from, and an admin ticket minted in
// the last minute of its home's life opens nothing.
pub fn an_admin_page_ends_no_later_than_the_home_that_opened_it_test() {
  let time = clock()
  let sessions = table(time)
  process.send(time, Advance(1000))
  let assert Ok(issued) =
    ui_sessions.mint_before(sessions, admin_for("alice"), 301_000)
    as "an admin ticket is minted from a home with five minutes left"
  let assert Ok(admin) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.AdminExchange)
    as "the admin page is opened"
  process.send(time, Advance(299_999))
  assert looked_up(sessions, admin.cookie) == Ok(admin_for("alice"))
  process.send(time, Advance(1))
  assert looked_up(sessions, admin.cookie) == Error(Nil)

  // A ticket that outlived its source opens nothing and displaces nothing.
  let assert Ok(late) =
    ui_sessions.mint_before(sessions, admin_for("alice"), 301_500)
    as "an admin ticket is minted"
  process.send(time, Advance(1000))
  assert ui_sessions.redeem(sessions, late.ticket, ui_sessions.AdminExchange)
    == Error(ui_sessions.UnknownTicket)
}

// A table configured with a page lifetime shorter than fifteen minutes shortens
// the admin page's too: it never outlives a page of the table.
pub fn an_admin_page_never_outlives_the_tables_page_lifetime_test() {
  let time = clock()
  let counter = counter()
  let assert Ok(sessions) =
    ui_sessions.start(ui_sessions.Settings(
      now: fn() { process.call(time, 1000, Read) },
      wall: fn() { process.call(time, 1000, Read) },
      entropy: fn(size) { distinct_bytes(counter, size) },
      ticket_ms: 60_000,
      device_ms: 60_000,
      session_ms: 120_000,
    ))
    as "a table with two-minute pages starts"
  let assert Ok(admin) =
    ui_sessions.redeem(
      sessions,
      admin_ticket(sessions, "alice"),
      ui_sessions.AdminExchange,
    )
    as "the admin page is opened"
  process.send(time, Advance(119_999))
  assert looked_up(sessions, admin.cookie) == Ok(admin_for("alice"))
  process.send(time, Advance(1))
  assert looked_up(sessions, admin.cookie) == Error(Nil)
}

// A ticket redeems only at the exchange of its own scope. The admin exchange
// refuses a session's ticket and a home's, and the other two refuse the admin
// ticket, each spent and each adding nothing.
pub fn the_admin_exchange_redeems_only_an_admin_ticket_test() {
  let sessions = table(clock())
  let session_ticket = mint(sessions, "s1")
  let home = home_ticket(sessions, "alice")
  let admin = admin_ticket(sessions, "alice")
  let other_admin = admin_ticket(sessions, "alice")
  assert ui_sessions.sizes(sessions) == Ok(#(4, 0))

  assert ui_sessions.redeem(sessions, session_ticket, ui_sessions.AdminExchange)
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.redeem(sessions, home, ui_sessions.AdminExchange)
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.redeem(sessions, admin, ui_sessions.HomeExchange)
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.redeem(
      sessions,
      other_admin,
      ui_sessions.SessionExchange("s1"),
    )
    == Error(ui_sessions.OtherScope)
  assert ui_sessions.sizes(sessions) == Ok(#(0, 0))

  // Every one is spent, so none opens a page at its own exchange afterwards.
  assert ui_sessions.redeem(sessions, admin, ui_sessions.AdminExchange)
    == Error(ui_sessions.UnknownTicket)
  assert ui_sessions.redeem(sessions, other_admin, ui_sessions.AdminExchange)
    == Error(ui_sessions.UnknownTicket)
  assert ui_sessions.redeem(sessions, home, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)
}

// The admin scope is counted apart from the home's and each session's: a fifth
// admin page ends the oldest admin page and nothing else, and a fifth home ends
// no admin page.
pub fn the_page_cap_counts_the_admin_scope_apart_test() {
  let sessions = table(clock())
  let assert Ok(home) =
    ui_sessions.redeem(
      sessions,
      home_ticket(sessions, "alice"),
      ui_sessions.HomeExchange,
    )
    as "a home"
  let pages =
    list.repeat(Nil, ui_sessions.max_pages)
    |> list.map(fn(_) {
      let assert Ok(redeemed) =
        ui_sessions.redeem(
          sessions,
          admin_ticket(sessions, "alice"),
          ui_sessions.AdminExchange,
        )
        as "an admin page under the cap"
      redeemed.cookie
    })
  let assert Ok(newest) =
    ui_sessions.redeem(
      sessions,
      admin_ticket(sessions, "alice"),
      ui_sessions.AdminExchange,
    )
    as "the fifth admin page"
  let assert [oldest, ..rest] = pages
  assert looked_up(sessions, oldest) == Error(Nil)
  list.each([newest.cookie, ..rest], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(admin_for("alice"))
  })
  assert looked_up(sessions, home.cookie) == Ok(home_for("alice"))

  // Homes up to their own cap leave every admin page standing.
  list.each(list.repeat(Nil, ui_sessions.max_pages + 1), fn(_) {
    let assert Ok(_) =
      ui_sessions.redeem(
        sessions,
        home_ticket(sessions, "alice"),
        ui_sessions.HomeExchange,
      )
      as "a home"
    Nil
  })
  list.each([newest.cookie, ..rest], fn(cookie) {
    assert looked_up(sessions, cookie) == Ok(admin_for("alice"))
  })
}

// One allowance serves every surface that grants. The same credential's
// reservations from any page are counted together, which is what lets the admin
// page's invitations, rotations and raised roles and the session page's
// invitations be held to three an hour between them: they all ask the one
// function.
pub fn every_grant_surface_reserves_from_the_one_allowance_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "a digest"
  list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
    assert ui_sessions.reserve_invite(sessions, digest) == Ok(Nil)
  })
  assert refused(ui_sessions.reserve_invite(sessions, digest))

  // A demotion reserves nothing, so it is not a call here at all; a refused grant
  // gives its place back and the next asks again.
  ui_sessions.release_invite(sessions, digest)
  assert ui_sessions.reserve_invite(sessions, digest) == Ok(Nil)
  assert refused(ui_sessions.reserve_invite(sessions, digest))

  // The place frees an hour after it was taken.
  process.send(time, Advance(ui_sessions.invite_window_ms))
  assert ui_sessions.reserve_invite(sessions, digest) == Ok(Nil)
}

// Worktree reads are counted for the credential across its pages, in a short
// rolling window: the third inside it is refused, and one is free again once
// the window has passed.
pub fn a_credentials_worktree_reads_are_limited_in_a_short_window_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "a digest"
  list.each(list.repeat(Nil, ui_sessions.worktree_read_limit), fn(_) {
    assert ui_sessions.reserve_worktree_read(sessions, digest) == Ok(Nil)
  })
  assert ui_sessions.reserve_worktree_read(sessions, digest) == Error(Nil)

  process.send(time, Advance(ui_sessions.worktree_read_window_ms))
  assert ui_sessions.reserve_worktree_read(sessions, digest) == Ok(Nil)
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
    ui_sessions.redeem(
      sessions,
      mint(sessions, session),
      ui_sessions.SessionExchange(session),
    )
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

// A credential's digest for the allowance's tests, distinct per letter.
fn credential(letter: String) -> access.Digest {
  let assert Ok(digest) = access.credential_digest(string.repeat(letter, 64))
    as "the fixture digest is valid"
  digest
}

// The allowance is counted for a credential: `invite_limit` reservations are
// granted and the next is refused, whichever page asks, and another
// credential's count is its own.
pub fn a_credential_may_reserve_only_the_invite_limit_test() {
  let sessions = table(clock())
  let owner = credential("a")
  list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
    assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  })
  assert refused(ui_sessions.reserve_invite(sessions, owner))
  assert refused(ui_sessions.reserve_invite(sessions, owner))
  assert ui_sessions.reserve_invite(sessions, credential("c")) == Ok(Nil)
}

// The window rolls: a place is free again an hour after it was taken, and not
// a moment before, so a stolen page cannot mint faster than the limit.
pub fn a_reservation_frees_an_hour_after_it_was_taken_test() {
  let time = clock()
  let sessions = table(time)
  let owner = credential("a")
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  process.send(time, Advance(1_800_000))
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  assert refused(ui_sessions.reserve_invite(sessions, owner))

  // The first reservation leaves the window at one hour.
  process.send(time, Advance(1_799_999))
  assert refused(ui_sessions.reserve_invite(sessions, owner))
  process.send(time, Advance(1))
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  assert refused(ui_sessions.reserve_invite(sessions, owner))
}

// A refusal answers the wall-clock time a place frees: an hour after the
// reservation whose leaving makes room, in the wall's terms and not the table's
// own monotonic ones, so a page can say when the next grant is possible.
pub fn a_refusal_answers_the_wall_time_a_place_frees_test() {
  let time = clock()
  let sessions = table(time)
  let owner = credential("a")
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  process.send(time, Advance(600_000))
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)

  // The oldest of the three was taken at zero, so it leaves at one hour.
  let free_at = wall_offset + ui_sessions.invite_window_ms
  assert ui_sessions.reserve_invite(sessions, owner) == Error(free_at)

  // Later, the answer is the same instant, and when it comes a place is free.
  process.send(time, Advance(1_200_000))
  assert ui_sessions.reserve_invite(sessions, owner) == Error(free_at)
  process.send(time, Advance(ui_sessions.invite_window_ms - 1_800_000))
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
}

// An invitation that minted nothing gives its place back.
pub fn a_released_reservation_is_free_again_test() {
  let sessions = table(clock())
  let owner = credential("a")
  list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
    assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  })
  assert refused(ui_sessions.reserve_invite(sessions, owner))
  ui_sessions.release_invite(sessions, owner)
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  assert refused(ui_sessions.reserve_invite(sessions, owner))

  // Releasing a credential that holds nothing is harmless.
  ui_sessions.release_invite(sessions, credential("d"))
  assert ui_sessions.reserve_invite(sessions, credential("d")) == Ok(Nil)
}

// Many pages asking at once cannot take more than the limit between them:
// the count and the taking are one message.
pub fn concurrent_reservations_never_exceed_the_limit_test() {
  let sessions = table(clock())
  let owner = credential("a")
  let results = process.new_subject()
  list.each(list.repeat(Nil, 20), fn(_) {
    process.spawn(fn() {
      process.send(results, ui_sessions.reserve_invite(sessions, owner))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 20), fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
        as "every reservation answers"
      outcome
    })
  assert list.count(outcomes, fn(outcome) { outcome == Ok(Nil) })
    == ui_sessions.invite_limit
}

// The sweep reclaims a credential whose reservations all aged out.
pub fn the_sweep_drops_aged_reservations_test() {
  let time = clock()
  let sessions = table(time)
  let owner = credential("a")
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  process.send(time, Advance(ui_sessions.invite_window_ms + 1))
  ui_sessions.sweep(sessions)
  assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
}

// The creation allowance is counted for a credential: `creation_limit`
// reservations are granted and the next is refused, whichever page asks, and
// another credential's count is its own. The eleventh in an hour is refused.
pub fn a_credential_may_reserve_only_the_creation_limit_test() {
  let sessions = table(clock())
  let owner = credential("a")
  assert ui_sessions.creation_limit == 10
  list.each(list.repeat(Nil, ui_sessions.creation_limit), fn(_) {
    assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  })
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
  assert ui_sessions.reserve_creation(sessions, credential("c")) == Ok(Nil)
}

// The two allowances are counted apart: spending every invitation leaves a
// credential its creations and the reverse.
pub fn creations_and_invitations_are_counted_apart_test() {
  let sessions = table(clock())
  let owner = credential("a")
  list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
    assert ui_sessions.reserve_invite(sessions, owner) == Ok(Nil)
  })
  assert refused(ui_sessions.reserve_invite(sessions, owner))
  assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  list.each(list.repeat(Nil, ui_sessions.creation_limit - 1), fn(_) {
    assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  })
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
  assert refused(ui_sessions.reserve_invite(sessions, owner))
}

// The window rolls: a creation's place is free again an hour after it was
// taken, and not a moment before.
pub fn a_creation_frees_an_hour_after_it_was_taken_test() {
  let time = clock()
  let sessions = table(time)
  let owner = credential("a")
  assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  process.send(time, Advance(1_800_000))
  list.each(list.repeat(Nil, ui_sessions.creation_limit - 1), fn(_) {
    assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  })
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
  process.send(time, Advance(1_799_999))
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
  process.send(time, Advance(1))
  assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  assert ui_sessions.reserve_creation(sessions, owner) == Error(Nil)
}

// Many pages asking at once cannot create more than the limit between them.
pub fn concurrent_creations_never_exceed_the_limit_test() {
  let sessions = table(clock())
  let owner = credential("a")
  let results = process.new_subject()
  list.each(list.repeat(Nil, 30), fn(_) {
    process.spawn(fn() {
      process.send(results, ui_sessions.reserve_creation(sessions, owner))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 30), fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
        as "every reservation answers"
      outcome
    })
  assert list.count(outcomes, fn(outcome) { outcome == Ok(Nil) })
    == ui_sessions.creation_limit
}

// The sweep reclaims a credential whose creations all aged out.
pub fn the_sweep_drops_aged_creations_test() {
  let time = clock()
  let sessions = table(time)
  let owner = credential("a")
  list.each(list.repeat(Nil, ui_sessions.creation_limit), fn(_) {
    assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
  })
  process.send(time, Advance(ui_sessions.creation_window_ms + 1))
  ui_sessions.sweep(sessions)
  assert ui_sessions.reserve_creation(sessions, owner) == Ok(Nil)
}

// --- the browser login (protocol-change/065, PR 8) --------------------------

// A home grant that asks for a login, as `loom ui` mints one.
fn remembered_home(principal: String) -> ui_sessions.Grant {
  ui_sessions.Grant(..home_for(principal), remember: ui_sessions.Remembered)
}

fn issuer(fingerprint: String) -> ui_sessions.Issuer {
  ui_sessions.Issuer(
    fingerprint:,
    expires_at_ms: wall_offset + 2_592_000_000,
    key: string.repeat("a", 32),
  )
}

// A device link's ticket lives ten minutes, not sixty seconds, and redeems
// once. At the instant its ten minutes end it is refused as any expired ticket
// is.
pub fn a_device_ticket_lives_ten_minutes_and_redeems_once_test() {
  let time = clock()
  let sessions = table(time)
  let assert Ok(issued) =
    ui_sessions.mint_device(
      sessions,
      remembered_home("alice"),
      28_800_000,
      None,
    )
    as "a device ticket is minted"
  assert issued.expires_in_ms == 600_000
  assert ui_sessions.device_ms == 600_000

  // A page ticket outlives none of this: it is gone in a minute.
  let assert Ok(brief) = ui_sessions.mint(sessions, remembered_home("alice"))
    as "a page ticket is minted"
  assert brief.expires_in_ms == 60_000
  process.send(time, Advance(60_000))
  assert ui_sessions.redeem(sessions, brief.ticket, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)

  // The device ticket is honoured to the last millisecond before ten minutes,
  // once.
  process.send(time, Advance(600_000 - 60_000 - 1))
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    as "the device ticket redeems inside its ten minutes"
  assert redeemed.grant.remember == ui_sessions.Remembered
  assert ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)

  // Another is refused from the instant its ten minutes end.
  let assert Ok(late) =
    ui_sessions.mint_device(
      sessions,
      remembered_home("alice"),
      28_800_000,
      None,
    )
    as "a second device ticket is minted"
  process.send(time, Advance(600_000))
  assert ui_sessions.redeem(sessions, late.ticket, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)
}

// A ticket carries the login of the page that minted it, so the page it opens
// belongs to the same login and a chain of switches neither loses it nor starts
// another: the redemption hands the caller the login, and the page knows it.
pub fn a_ticket_carries_the_login_of_its_minter_test() {
  let sessions = table(clock())
  let login = issuer("0123456789abcdef")
  let assert Ok(issued) =
    ui_sessions.mint_in(sessions, home_for("alice"), 28_800_000, Some(login))
    as "a switch ticket is minted"
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    as "the ticket redeems"
  assert redeemed.login == Some(login)
  assert ui_sessions.login_of(sessions, redeemed.cookie) == Some(login)

  // A ticket with no login opens a page with none.
  let assert Ok(plain) = ui_sessions.mint(sessions, home_for("alice"))
    as "a plain ticket is minted"
  let assert Ok(plain_page) =
    ui_sessions.redeem(sessions, plain.ticket, ui_sessions.HomeExchange)
    as "the plain ticket redeems"
  assert plain_page.login == None
  assert ui_sessions.login_of(sessions, plain_page.cookie) == None
}

// A page a remembered exchange opened is the browser of the login that exchange
// sets, which is attached once the login's row exists, and only once: a second
// attachment cannot change which login a page is. A cookie that names no live
// page records nothing.
pub fn a_remembered_exchange_attaches_its_login_once_test() {
  let sessions = table(clock())
  let assert Ok(issued) = ui_sessions.mint(sessions, remembered_home("alice"))
    as "a remembered ticket is minted"
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    as "the ticket redeems"
  assert redeemed.login == None
  assert ui_sessions.login_of(sessions, redeemed.cookie) == None

  let first = issuer("1111111111111111")
  ui_sessions.attach_login(sessions, redeemed.cookie, first)
  assert ui_sessions.login_of(sessions, redeemed.cookie) == Some(first)
  ui_sessions.attach_login(
    sessions,
    redeemed.cookie,
    issuer("2222222222222222"),
  )
  assert ui_sessions.login_of(sessions, redeemed.cookie) == Some(first)

  // Attaching does not change what the page grants, so a socket that holds the
  // grant it was admitted under still matches.
  assert looked_up(sessions, redeemed.cookie) == Ok(remembered_home("alice"))
  ui_sessions.attach_login(sessions, "no such cookie", first)
  assert ui_sessions.login_of(sessions, "no such cookie") == None
}

// A page a resumed login minted is the browser of that login and is a resumed
// page, whatever its ticket's lifetime says.
pub fn a_resumed_page_is_the_browser_of_its_login_test() {
  let sessions = table(clock())
  let login = issuer("0123456789abcdef")
  let grant =
    ui_sessions.Grant(..home_for("alice"), origin: ui_sessions.Resumed)
  let assert Ok(issued) = ui_sessions.mint_resumed(sessions, grant, login)
    as "a resume's ticket is minted"
  assert issued.expires_in_ms == 60_000
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    as "the ticket redeems"
  assert redeemed.grant.origin == ui_sessions.Resumed
  assert ui_sessions.login_of(sessions, redeemed.cookie) == Some(login)
  assert looked_up(sessions, redeemed.cookie) == Ok(grant)
}

// A principal's homes are one scope whatever origin reached them: a fifth home
// ends the oldest, a resumed one among them.
pub fn homes_of_every_origin_share_one_cap_test() {
  let sessions = table(clock())
  let resumed =
    ui_sessions.Grant(..home_for("alice"), origin: ui_sessions.Resumed)
  let ticket = fn(grant) {
    let assert Ok(issued) = ui_sessions.mint(sessions, grant)
      as "a ticket is minted"
    let assert Ok(redeemed) =
      ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
      as "the ticket redeems"
    redeemed
  }
  let oldest = ticket(resumed)
  let rest = [
    ticket(home_for("alice")),
    ticket(resumed),
    ticket(home_for("alice")),
  ]
  assert list.all(rest, fn(page) {
    result.is_ok(looked_up(sessions, page.cookie))
  })
  assert result.is_ok(looked_up(sessions, oldest.cookie))
  let _fifth = ticket(resumed)
  assert looked_up(sessions, oldest.cookie) == Error(Nil)
  assert list.all(rest, fn(page) {
    result.is_ok(looked_up(sessions, page.cookie))
  })
}

// --- the claim's pull request: a login that has ended (protocol-change/065, PR 9) ---

// A ticket minted under a login whose time has run out, a device link opened
// after its family's last day, is refused as an unknown ticket before it can
// take a page's place. The owner's homes, a full set of them, all survive the
// attempt; a ticket whose login is still live evicts the oldest as any other
// does.
pub fn a_ticket_of_an_ended_login_evicts_no_page_test() {
  let time = clock()
  let sessions = table(time)
  let ticket = fn(login) {
    let assert Ok(issued) =
      ui_sessions.mint_device(
        sessions,
        remembered_home("alice"),
        28_800_000,
        login,
      )
      as "a device ticket is minted"
    issued.ticket
  }
  let held =
    list.map(list.repeat(Nil, ui_sessions.max_pages), fn(_) {
      let assert Ok(issued) = ui_sessions.mint(sessions, home_for("alice"))
        as "a home ticket is minted"
      let assert Ok(redeemed) =
        ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
        as "the home opens"
      redeemed.cookie
    })
  let ends =
    ui_sessions.Issuer(
      ..issuer("0123456789abcdef"),
      expires_at_ms: wall_offset + 5000,
    )

  // Minted while the login lived, redeemed after it ended.
  let late = ticket(Some(ends))
  process.send(time, Advance(5000))
  assert ui_sessions.redeem(sessions, late, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)
  assert list.all(held, fn(cookie) { result.is_ok(looked_up(sessions, cookie)) })

  // The refusal spent the ticket and opened nothing.
  assert ui_sessions.redeem(sessions, late, ui_sessions.HomeExchange)
    == Error(ui_sessions.UnknownTicket)
  assert ui_sessions.sizes(sessions) == Ok(#(0, ui_sessions.max_pages))

  // A login with time left redeems, and makes room as any redemption does.
  let live =
    ticket(Some(
      ui_sessions.Issuer(..ends, expires_at_ms: wall_offset + 5000 + 600_000),
    ))
  let assert Ok(opened) =
    ui_sessions.redeem(sessions, live, ui_sessions.HomeExchange)
    as "a ticket of a live login redeems"
  assert result.is_ok(looked_up(sessions, opened.cookie))
  let assert [oldest, ..rest] = held
  assert looked_up(sessions, oldest) == Error(Nil)
  assert list.all(rest, fn(cookie) { result.is_ok(looked_up(sessions, cookie)) })
}

// Only a ticket that sets a login is held to its login's end. A switch, the way
// home or an admin press carries the page's login too (`mint_in`), but sets none,
// and the page it comes from keeps working to its own deadline, so one minted
// before the login ended still redeems after.
pub fn a_switch_ticket_of_an_ended_login_still_redeems_test() {
  let time = clock()
  let sessions = table(time)
  let ends =
    ui_sessions.Issuer(
      ..issuer("0123456789abcdef"),
      expires_at_ms: wall_offset + 5000,
    )
  let assert Ok(issued) =
    ui_sessions.mint_in(sessions, home_for("alice"), 28_800_000, Some(ends))
    as "a switch ticket is minted"
  process.send(time, Advance(5000))
  let assert Ok(redeemed) =
    ui_sessions.redeem(sessions, issued.ticket, ui_sessions.HomeExchange)
    as "the switch ticket redeems after the login ended"
  assert redeemed.login == Some(ends)
  assert result.is_ok(looked_up(sessions, redeemed.cookie))
}

// The production table's wall clock is the system's, not the monotonic reading it
// is handed: a login that ended a second ago by the system's clock is ended
// whatever small number the monotonic clock reads, and one with time left is not.
pub fn the_production_table_judges_a_login_by_the_system_clock_test() {
  let time = clock()
  let assert Ok(sessions) =
    ui_sessions.start(
      ui_sessions.production(fn() { process.call(time, 1000, Read) }),
    )
    as "the production table starts"
  let now = bootstrap.system_time_ms()
  let ticket = fn(expires_at_ms) {
    let assert Ok(issued) =
      ui_sessions.mint_device(
        sessions,
        remembered_home("alice"),
        28_800_000,
        Some(ui_sessions.Issuer(..issuer("0123456789abcdef"), expires_at_ms:)),
      )
      as "a device ticket is minted"
    issued.ticket
  }
  assert ui_sessions.redeem(
      sessions,
      ticket(now - 1000),
      ui_sessions.HomeExchange,
    )
    == Error(ui_sessions.UnknownTicket)
  assert result.is_ok(ui_sessions.redeem(
    sessions,
    ticket(now + 600_000),
    ui_sessions.HomeExchange,
  ))
}
