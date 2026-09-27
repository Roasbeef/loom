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
//// Each table is a per-key deadline table inside this one actor, which
//// `docs/weft.md` ("Per-key deadline tables stay") allows. Every read checks
//// the deadline itself, so an expired ticket or session is refused the
//// moment it expires; the periodic sweep only reclaims the memory of
//// entries nobody asked about again.

import broker/internal/call
import broker/token
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/access
import weft/actor

/// How long a ticket can be redeemed, in milliseconds.
pub const ticket_ms = 60_000

/// How long a UI session lives from its exchange, in milliseconds: eight
/// hours, a working day. A page left open for a day's work keeps working,
/// and a cookie copied out of a browser stops working the same day.
pub const session_ms = 28_800_000

/// How often the tables are swept, in milliseconds.
pub const sweep_ms = 60_000

/// What a ticket and the UI session it becomes stand for.
pub type Grant {
  Grant(
    /// The principal the ticket was minted for.
    principal_id: String,
    /// The one session the ticket names.
    session_id: String,
    /// The digest of the credential that asked for the ticket. Every later
    /// check re-authenticates it, so revoking that credential ends the UI
    /// session.
    credential: access.Digest,
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

/// A redeemed ticket: the new UI session's cookie and what it grants.
pub type Redeemed {
  Redeemed(cookie: String, grant: Grant)
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
  Mint(grant: Grant, reply: Subject(Issued))
  Redeem(
    ticket: String,
    previous: Option(String),
    reply: Subject(Result(Redeemed, Nil)),
  )
  Lookup(cookie: String, reply: Subject(Result(Grant, Nil)))
  Sizes(reply: Subject(#(Int, Int)))
  Sweep
}

// One live ticket or UI session and the instant it stops being honoured.
type Entry {
  Entry(grant: Grant, expires_at: Int)
}

type State {
  State(
    settings: Settings,
    tickets: Dict(String, Entry),
    sessions: Dict(String, Entry),
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
  actor.new(State(settings, dict.new(), dict.new()))
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
/// // ui_sessions.mint(sessions, Grant(principal, session, digest))
/// ```
pub fn mint(sessions: Sessions, grant: Grant) -> Result(Issued, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Mint(grant, _))
  |> result.replace_error(Nil)
}

/// Redeems `ticket` once. A request that already carried a cookie names it
/// as `previous`, and that UI session is deleted first: a ticket replaces
/// the UI session outright, and nothing carries over from the old one.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.redeem(sessions, ticket, None)
/// ```
pub fn redeem(
  sessions: Sessions,
  ticket: String,
  previous: Option(String),
) -> Result(Redeemed, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Redeem(
    ticket,
    previous,
    _,
  ))
  |> result.unwrap(Error(Nil))
}

/// What a live UI session's cookie grants.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.lookup(sessions, cookie)
/// ```
pub fn lookup(sessions: Sessions, cookie: String) -> Result(Grant, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Lookup(cookie, _))
  |> result.unwrap(Error(Nil))
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
    Mint(grant:, reply:) -> {
      let ticket = secret(state.settings)
      let entry = Entry(grant, now + state.settings.ticket_ms)
      process.send(reply, Issued(ticket, state.settings.ticket_ms))
      actor.continue(
        State(
          ..state,
          tickets: dict.insert(state.tickets, digest(ticket), entry),
        ),
      )
    }

    // The whole redemption happens in this one turn: the old UI session is
    // dropped, the ticket is removed whether or not it was still live, and a
    // live ticket becomes a new UI session. Nothing between those steps can
    // interleave with another redemption.
    Redeem(ticket:, previous:, reply:) -> {
      let sessions = case previous {
        Some(cookie) -> dict.delete(state.sessions, digest(cookie))
        None -> state.sessions
      }
      let key = digest(ticket)
      let found = live(state.tickets, key, now)
      let tickets = dict.delete(state.tickets, key)
      case found {
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(State(..state, tickets:, sessions:))
        }
        Ok(grant) -> {
          let cookie = secret(state.settings)
          let entry = Entry(grant, now + state.settings.session_ms)
          process.send(reply, Ok(Redeemed(cookie, grant)))
          actor.continue(
            State(
              ..state,
              tickets:,
              sessions: dict.insert(sessions, digest(cookie), entry),
            ),
          )
        }
      }
    }

    Lookup(cookie:, reply:) -> {
      process.send(reply, live(state.sessions, digest(cookie), now))
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

// An entry is honoured strictly before its deadline, and the check is made
// on every read, so the sweep is never what enforces expiry.
fn live(table: Dict(String, Entry), key: String, now: Int) {
  case dict.get(table, key) {
    Ok(entry) if entry.expires_at > now -> Ok(entry.grant)
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
