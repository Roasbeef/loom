//// The web view's tickets and UI sessions (protocol-change/051), owned by one
//// actor so that every mint, redemption and lookup happens in one mailbox.
////
//// A person's own `loom` asks for a ticket over its control connection
//// (`ui.link`). The browser presents the ticket once, and redeeming it
//// creates a UI session whose cookie the browser keeps. Two tables hold
//// them, and both are keyed by the SHA-256 digest of the secret, so the
//// actor never holds a plaintext ticket or cookie after it has handed one
//// out.
////
//// Redemption is single-use because it is serialized here. Two HTTP
//// handlers that present the same ticket at once reach this actor one after
//// the other: the first removes the ticket and the second finds nothing. A
//// check-then-delete split across two calls would let both succeed, which
//// is why redemption is one message and not a lookup followed by a delete.
////
//// Redeeming a ticket mints three secrets for the UI session it becomes
//// (protocol-change/051, the operator addendum): the cookie, the page key
//// the cookie's path is scoped to, and the page nonce the browser tab keeps
//// in `sessionStorage` and presents on the socket. The table keeps only
//// their digests. A principal may hold several UI sessions for one session
//// at once, an observer's tab beside an operator's, or two devices. Each
//// has its own cookie, key and nonce, so a redemption never touches
//// another page unless the principal already holds `max_pages` of them for
//// the session, and then it ends only the oldest (protocol-change/051, the
//// addendum on several pages).
////
//// Each table is a per-key deadline table inside this one actor, which
//// `docs/weft.md` ("Per-key deadline tables stay") allows. Every read checks
//// the deadline itself, so an expired ticket or session is refused the
//// moment it expires; the periodic sweep only reclaims the memory of
//// entries nobody asked about again.

import broker/internal/call
import broker/internal/ffi_crypto
import broker/token
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import host/bootstrap
import storage/access
import web_view/ending
import weft/actor

/// How long a ticket can be redeemed, in milliseconds.
pub const ticket_ms = 60_000

/// How long a UI session lives from its exchange, in milliseconds: eight
/// hours, a working day. A page left open for a day's work keeps working,
/// and a cookie copied out of a browser stops working the same day.
///
/// The deadline is a ceiling on a chain of pages as well as on one. A page
/// opened by a ticket that another page minted (a session switch,
/// `mint_before`) ends at the earlier of that page's deadline and this long
/// from its own exchange, so switching from page to page never outlives the
/// page the chain started from, and a copied cookie cannot be renewed by
/// switching.
pub const session_ms = 28_800_000

/// The most live UI sessions one principal holds for one session.
///
/// The bound is on pages in this table, and so on the memory they hold: a
/// live page keeps a cookie, a key and a nonce, and while its browser is
/// connected, a socket, a relay process and a lane of up to 300 rows. It does
/// not bound sockets per page: one page's secrets can open several, as
/// before, and those are bounded by the root's admission capacity. A page
/// that is ended, by its deadline or by displacement, has its socket, relay
/// and lane torn down at its next frame, when the gateway revalidates it
/// (`check_binding`). Four covers what a person
/// does with one session: an observer tab, an operator tab, a second device,
/// and one spare.
///
/// A redemption at the bound ends the oldest page and adds the new one; it
/// is not refused. The daemon never learns that a tab was closed, because a
/// reload closes and reopens the same page's socket, so a closed tab's page
/// stays live until its eight hours end. A refusal would therefore lock a
/// person out of a long-running daemon after their fifth `loom ui` of the
/// day, with nothing to close. Ending the oldest keeps the newest four,
/// which are the ones a person can still be using.
pub const max_pages = ending.max_pages

/// How often the tables are swept, in milliseconds.
pub const sweep_ms = 60_000

/// What a ticket and the UI session it becomes stand for.
pub type Grant {
  Grant(
    /// The one session the ticket names.
    session_id: String,
    /// The digest of the credential that asked for the ticket. Every later
    /// check re-authenticates it, so revoking that credential ends the UI
    /// session.
    credential: access.Digest,
    /// The principal that asked. The number of live UI sessions it holds
    /// for one session is bounded by `max_pages`.
    principal: String,
    /// The most the page may do, chosen when the link was minted: observer
    /// unless `loom ui --operate` asked for operator. It caps the
    /// membership role and never grants one (`ui_relay.capped`).
    ceiling: access.Role,
  )
}

/// A live UI session: what it grants, and the digests of the page key its
/// cookie is scoped to and of the nonce its browser tab presents.
pub opaque type Page {
  Page(
    grant: Grant,
    key: String,
    nonce: String,
    /// The order pages were opened in, which is how the oldest is found
    /// when two share a millisecond.
    serial: Int,
  )
}

/// A freshly minted ticket.
pub type Issued {
  Issued(
    /// The ticket's plaintext, which only the caller ever sees.
    ticket: String,
    /// The ticket's remaining lifetime, a duration and not an instant.
    expires_in_ms: Int,
  )
}

/// A redeemed ticket: the new UI session's three secrets, in plaintext for
/// the one response that hands them to the browser, and what it grants.
pub type Redeemed {
  Redeemed(cookie: String, key: String, nonce: String, grant: Grant)
}

/// Why a ticket was not redeemed.
pub type Refusal {
  /// No live ticket has this value: it was never minted, it was already
  /// redeemed, or it expired.
  UnknownTicket

  /// The ticket is live but names another session than the path it was
  /// presented on. It is spent all the same: a ticket presented where it
  /// does not belong has been copied somewhere it should not be, and a
  /// second try must not get another chance at it.
  OtherSession
}

/// The actor's clock and entropy, injected so a test can move time.
pub type Settings {
  Settings(
    /// A millisecond reading that only moves forward.
    now: fn() -> Int,
    /// `n` random bytes.
    entropy: fn(Int) -> BitArray,
    /// A ticket's lifetime.
    ticket_ms: Int,
    /// A UI session's lifetime.
    session_ms: Int,
  )
}

/// The production settings: OTP's `crypto:strong_rand_bytes`, the source
/// invitations use, and the lifetimes above.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.start(ui_sessions.production(clock))
/// ```
pub fn production(now: fn() -> Int) -> Settings {
  Settings(now:, entropy: token.production_entropy(), ticket_ms:, session_ms:)
}

/// A handle on the actor.
pub opaque type Sessions {
  Sessions(subject: Subject(Message))
}

type Message {
  Mint(grant: Grant, until: Option(Int), reply: Subject(Issued))
  Redeem(
    ticket: String,
    session_id: String,
    reply: Subject(Result(Redeemed, Refusal)),
  )
  Lookup(cookie: String, reply: Subject(Result(#(Page, Int), Nil)))
  Sizes(reply: Subject(#(Int, Int)))
  Sweep
}

// A live ticket's grant, and the deadline the page it becomes may not pass
// when another page minted it.
type Ticket {
  Ticket(grant: Grant, until: Option(Int))
}

// One live ticket or UI session and the instant it stops being honoured.
type Entry(value) {
  Entry(value: value, expires_at: Int)
}

type State {
  State(
    settings: Settings,
    tickets: Dict(String, Entry(Ticket)),
    sessions: Dict(String, Entry(Page)),
    /// How many pages this actor has opened, which numbers the next one.
    opened: Int,
  )
}

/// Starts the actor, linked to the caller, sweeping every `sweep_ms`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(sessions) = ui_sessions.start(settings)
/// ```
pub fn start(settings: Settings) -> Result(Sessions, String) {
  actor.new(State(settings, dict.new(), dict.new(), 0))
  |> actor.on_message(handle)
  |> actor.periodic(every: sweep_ms, sending: Sweep)
  |> actor.start
  |> result.map(fn(started) { Sessions(started.data) })
  |> result.replace_error("the web view's session table did not start")
}

/// Mints a ticket for `grant`.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint(sessions, Grant(session, digest))
/// ```
pub fn mint(sessions: Sessions, grant: Grant) -> Result(Issued, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Mint(grant, None, _))
  |> result.replace_error(Nil)
}

/// Mints a ticket for `grant` on behalf of another page whose deadline is
/// `until`, a reading of the table's clock. The page the ticket becomes ends
/// at the earlier of `until` and `session_ms` after its exchange, so a chain
/// of switches never outlives the page it began from.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint_before(sessions, grant, until)
/// ```
pub fn mint_before(
  sessions: Sessions,
  grant: Grant,
  until: Int,
) -> Result(Issued, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Mint(
    grant,
    Some(until),
    _,
  ))
  |> result.replace_error(Nil)
}

/// Redeems `ticket` once, for the page of `session_id`. A successful
/// redemption adds a UI session. The principal's other pages for the
/// session keep their own cookies and stay open until their eight hours run
/// out, except that a principal already holding `max_pages` live ones has
/// its oldest ended to make room. A refused redemption leaves every page
/// alone, so a stale or misdirected link cannot sign a working page out.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.redeem(sessions, ticket, session_id)
/// ```
pub fn redeem(
  sessions: Sessions,
  ticket: String,
  session_id: String,
) -> Result(Redeemed, Refusal) {
  call.try_call(sessions.subject, waiting: 1000, sending: Redeem(
    ticket,
    session_id,
    _,
  ))
  |> result.unwrap(Error(UnknownTicket))
}

/// The live UI session a cookie names.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.lookup(sessions, cookie)
/// ```
pub fn lookup(sessions: Sessions, cookie: String) -> Result(Page, Nil) {
  lookup_until(sessions, cookie) |> result.map(pair.first)
}

// The live UI session a cookie names, with the deadline it ends at.
fn lookup_until(
  sessions: Sessions,
  cookie: String,
) -> Result(#(Page, Int), Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Lookup(cookie, _))
  |> result.unwrap(Error(Nil))
}

/// What a live UI session grants.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.grant(page).session_id
/// ```
pub fn grant(page: Page) -> Grant {
  page.grant
}

/// Whether `key`, from a request's path, is the page key this UI session
/// was given. Compared by digest, in constant time.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.keyed(page, key)
/// ```
pub fn keyed(page: Page, key: String) -> Bool {
  same_digest(page.key, digest(key))
}

/// Whether `nonce`, from a socket's query, is the nonce this UI session
/// handed its browser tab. Compared by digest, in constant time.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.admits(page, nonce)
/// ```
pub fn admits(page: Page, nonce: String) -> Bool {
  same_digest(page.nonce, digest(nonce))
}

// Two digests are base16 SHA-256, the same length whatever they digest, so
// a constant-time comparison of them reveals nothing about the secret.
fn same_digest(stored: String, presented: String) -> Bool {
  ffi_crypto.constant_time_equal(
    bit_array.from_string(stored),
    bit_array.from_string(presented),
  )
}

/// A check that the UI session behind `cookie` still grants `grant`.
///
/// The page's socket runs it with every authorization the gateway asks for,
/// so a UI session that expires ends an open page the way a revoked
/// credential does. A lookup that answers with
/// a different grant counts as ended too.
///
/// ## Examples
///
/// ```gleam
/// // let open = ui_sessions.still_open(sessions, cookie, grant)
/// // open() == Ok(Nil)
/// ```
pub fn still_open(
  sessions: Sessions,
  cookie: String,
  grant: Grant,
) -> fn() -> Result(Nil, Nil) {
  let until = open_until(sessions, cookie, grant)
  fn() { until() |> result.replace(Nil) }
}

/// `still_open`, answering the page's deadline while it is open. The page
/// socket uses the deadline when the page asks to open another session, so the
/// ticket it mints carries it (`mint_before`).
///
/// ## Examples
///
/// ```gleam
/// // let until = ui_sessions.open_until(sessions, cookie, grant)
/// // until() == Ok(deadline)
/// ```
pub fn open_until(
  sessions: Sessions,
  cookie: String,
  grant: Grant,
) -> fn() -> Result(Int, Nil) {
  fn() {
    use #(current, until) <- result.try(lookup_until(sessions, cookie))
    case current.grant == grant {
      True -> Ok(until)
      False -> Error(Nil)
    }
  }
}

/// How many tickets and UI sessions the tables hold, expired or not, for a
/// test that checks the sweep.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.sizes(sessions) == #(0, 1)
/// ```
@internal
pub fn sizes(sessions: Sessions) -> Result(#(Int, Int), Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Sizes)
  |> result.replace_error(Nil)
}

/// Sweeps now rather than at the next period, for a test.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.sweep(sessions)
/// ```
@internal
pub fn sweep(sessions: Sessions) -> Nil {
  process.send(sessions.subject, Sweep)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let now = state.settings.now()
  case message {
    Mint(grant:, until:, reply:) -> {
      let ticket = secret(state.settings)
      let entry =
        Entry(
          value: Ticket(grant, until),
          expires_at: now + state.settings.ticket_ms,
        )
      process.send(reply, Issued(ticket, state.settings.ticket_ms))
      actor.continue(
        State(
          ..state,
          tickets: dict.insert(state.tickets, digest(ticket), entry),
        ),
      )
    }

    // The whole redemption happens in this one turn: the ticket is removed
    // whether or not it was still live, and only a live ticket for this
    // session becomes a new UI session. Making room and inserting in one
    // turn keeps the bound exact: two redemptions at the fourth place reach
    // this actor one after the other, and the second sees the first's page.
    Redeem(ticket:, session_id:, reply:) -> {
      let key = digest(ticket)
      let found = live(state.tickets, key, now)
      let tickets = dict.delete(state.tickets, key)
      case found {
        Error(Nil) -> {
          process.send(reply, Error(UnknownTicket))
          actor.continue(State(..state, tickets:))
        }
        Ok(Ticket(grant:, ..)) if grant.session_id != session_id -> {
          process.send(reply, Error(OtherSession))
          actor.continue(State(..state, tickets:))
        }
        Ok(Ticket(grant:, until:)) -> {
          let ends = case until {
            Some(bound) -> int.min(bound, now + state.settings.session_ms)
            None -> now + state.settings.session_ms
          }
          let cookie = secret(state.settings)
          let key = secret(state.settings)
          let nonce = secret(state.settings)
          let entry =
            Entry(
              value: Page(
                grant:,
                key: digest(key),
                nonce: digest(nonce),
                serial: state.opened,
              ),
              expires_at: ends,
            )
          process.send(reply, Ok(Redeemed(cookie:, key:, nonce:, grant:)))
          actor.continue(
            State(
              ..state,
              tickets:,
              sessions: state.sessions
                |> with_room(grant, now)
                |> dict.insert(digest(cookie), entry),
              opened: state.opened + 1,
            ),
          )
        }
      }
    }

    Lookup(cookie:, reply:) -> {
      process.send(reply, live_until(state.sessions, digest(cookie), now))
      actor.continue(state)
    }

    Sizes(reply:) -> {
      process.send(reply, #(dict.size(state.tickets), dict.size(state.sessions)))
      actor.continue(state)
    }

    Sweep ->
      actor.continue(
        State(
          ..state,
          tickets: dict.filter(state.tickets, fn(_, entry) {
            entry.expires_at > now
          }),
          sessions: dict.filter(state.sessions, fn(_, entry) {
            entry.expires_at > now
          }),
        ),
      )
  }
}

// The table with room for one more of `grant`'s pages: unchanged while the
// principal holds fewer than `max_pages` live ones, and otherwise without the
// oldest, so the new page makes `max_pages`. An expired page is not counted
// even before the sweep removes it, so a place frees at its deadline.
fn with_room(
  sessions: Dict(String, Entry(Page)),
  grant: Grant,
  now: Int,
) -> Dict(String, Entry(Page)) {
  let held =
    sessions
    |> dict.to_list
    |> list.filter(fn(row) {
      let #(_cookie, entry) = row
      let other = entry.value.grant
      entry.expires_at > now
      && other.principal == grant.principal
      && other.session_id == grant.session_id
    })
    |> list.sort(fn(a, b) {
      int.compare({ a.1 }.value.serial, { b.1 }.value.serial)
    })
  let surplus = list.length(held) - max_pages + 1

  // A surplus of zero or less takes nothing, so below the bound this drops
  // no page.
  dict.drop(sessions, list.map(list.take(held, surplus), pair.first))
}

// An entry is honoured strictly before its deadline, and the check is made
// on every read, so the sweep is never what enforces expiry.
fn live(table: Dict(String, Entry(value)), key: String, now: Int) {
  case dict.get(table, key) {
    Ok(entry) if entry.expires_at > now -> Ok(entry.value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

// A live UI session and the instant it ends.
fn live_until(
  table: Dict(String, Entry(Page)),
  key: String,
  now: Int,
) -> Result(#(Page, Int), Nil) {
  case dict.get(table, key) {
    Ok(entry) if entry.expires_at > now -> Ok(#(entry.value, entry.expires_at))
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

fn secret(settings: Settings) -> String {
  settings.entropy(32) |> bit_array.base16_encode |> string.lowercase
}

fn digest(value: String) -> String {
  value
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}
