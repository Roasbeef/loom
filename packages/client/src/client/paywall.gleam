//// The harness half of `provider/paywall`: the seam that lets the
//// provider gateway pay for a priced request by asking an installed
//// extension to pay it.
////
//// `provider/paywall.Paywall` is two injected functions and no opinion
//// about where the money comes from. This module supplies them for a
//// served session, and exists because the two ends of that seam sit on
//// opposite sides of a knot. The gateway is built from the catalogue
//// before any session exists; the hook bus is started per session, after
//// the session's `Effects` have been composed. So there is no moment at
//// which a paywall closing over a bus could be constructed — the bus
//// does not exist yet when the gateway's configuration is fixed, and the
//// gateway is already inside that configuration when the bus starts.
////
//// ## The slot is the knot, untied by indirection
////
//// The same shape `client/agency.seam` and `client/scratch.seam` have,
//// and solved the same way: the seam closes over an address rather than
//// over the thing addressed, and the thing is put behind that address
//// later. Here the address is a `Slot`, one tiny actor per session,
//// created before the gateway's configuration is built and filled with
//// `attach` the moment the bus starts. A session that installs no
//// extension never attaches, and its `settle` says so rather than
//// hanging.
////
//// ## The cache is what keeps a session from re-paying every turn
////
//// `credential(provider)` is consulted before **every** attempt on a
//// paywalled entry, and a proxy that has been paid accepts the same
//// credential until the macaroon's caveats expire. So a settled token is
//// kept, keyed on the catalogue entry's name, and handed back until the
//// proxy answers 402 again — at which point the gateway settles once
//// more and the new token replaces the old. Nothing here decides when a
//// token has expired, because nothing here can read a macaroon's
//// caveats: the proxy's next 402 is the expiry signal, and it is exact.
////
//// The cache is an actor rather than a dictionary in a closure because
//// the readers and the writer are different processes — `credential` is
//// read on the gateway's pump and `settle` writes from wherever the
//// terminal was classified — and shared mutable state between processes
//// is what an actor is for.
////
//// ## What is deliberately not here
////
//// No budget, no ceiling, no rate limit. A hook that answers `Paid` has
//// spent money, and the party that can bound that spending is the
//// extension holding the wallet: it knows the balance, the day's total
//// and the operator's intent, and the harness knows none of the three. A
//// ceiling written here would be a second, weaker opinion that an author
//// would have to work around.
////
//// No expiry sweep either. A token is one string per catalogue entry and
//// a daemon serves few entries, so the cache is bounded by the
//// catalogue rather than by anything that has to be reaped.

import client/extension/hooks
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/l402
import provider/paywall
import weft/actor

/// How long either actor here is given to answer before the caller gives
/// up on it.
///
/// Both handlers are a dictionary read or a dictionary write and neither
/// blocks on anything, so this bound is only ever reached by a VM in
/// trouble. It exists because the caller is the provider gateway's own
/// pump: a question that waited forever would wedge a request, and one
/// asked with `process.call` would kill it outright.
pub const ask_timeout_ms = 1000

/// The reason `settle` gives when this session has no hook bus to ask.
///
/// A session with no installed extension never attaches a bus, and the
/// honest answer to "pay this" is that nobody here can. It reaches the
/// model as `stream.PaymentDeclined`, so it is worded for an operator
/// reading a failed request rather than for a log.
pub const no_extension_reason = "no payment extension is installed"

/// The reason `settle` gives when the session's slot did not answer.
pub const unavailable_reason = "the session's payment seam did not answer"

// --- the daemon's credential cache ----------------------------------------

// What the cache is asked. `Store` is a cast: the caller has the token in
// hand and has already decided to use it, so waiting for the cache to
// acknowledge would buy nothing — a lost write costs one extra 402 and
// one extra settle, which is exactly what a cache miss costs anyway.
type CacheMessage {
  Read(provider: String, reply_with: Subject(Option(String)))
  Store(provider: String, token: String)
}

/// The credential cache: one settled token per catalogue entry name.
///
/// Opaque because the subject is the whole of it and handing that out
/// would let a caller send a `Store` for a provider it never settled.
pub opaque type Cache {
  Cache(subject: Subject(CacheMessage))
}

/// The per-session door onto the hook bus, filled once the bus exists.
///
/// Opaque for the same reason, and holding an `Option` rather than a bus
/// because "no bus yet" and "no bus ever" are the same state to a
/// `settle` that arrives: both mean there is nobody to ask right now.
pub opaque type Slot {
  Slot(subject: Subject(SlotMessage))
}

type SlotMessage {
  Fill(bus: hooks.Bus)
  Borrow(reply_with: Subject(Option(hooks.Bus)))
}

/// Starts the credential cache.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(cache) = paywall.start_cache()
/// ```
///
pub fn start_cache() -> Result(Cache, actor.StartError) {
  use started <- result.map(
    actor.new([])
    |> actor.on_message(handle_cache)
    |> actor.start,
  )
  Cache(subject: started.data)
}

/// Starts an empty slot, before the session's bus exists.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(slot) = paywall.slot()
/// ```
///
pub fn slot() -> Result(Slot, actor.StartError) {
  use started <- result.map(
    actor.new(None)
    |> actor.on_message(handle_slot)
    |> actor.start,
  )
  Slot(subject: started.data)
}

/// Puts a started bus behind a session's slot.
///
/// Called once, immediately after the bus starts and before
/// `session_start` fires, so the first thing an extension is told about
/// the session is not a payment challenge it could not have been asked
/// about a moment earlier.
///
/// ## Examples
///
/// ```gleam
/// // paywall.attach(slot, bus)
/// ```
///
pub fn attach(slot: Slot, bus: hooks.Bus) -> Nil {
  process.send(slot.subject, Fill(bus:))
}

/// The `provider/paywall.Paywall` one session hands its gateway.
///
/// `credential` reads the cache and never asks an extension anything: it
/// runs before every attempt, and waking a satellite on each one would
/// spend a hook's deadline per provider request.
///
/// `settle` is the one that costs money. It borrows the session's bus,
/// asks it to pay, and — on a preimage — composes the credential from
/// that preimage and the macaroon **the harness still holds**, which is
/// why the macaroon never crosses the hook. The composed token is cached
/// under the provider's name before it is returned, so the retry the
/// gateway is about to make and every later attempt read one value.
///
/// ## Examples
///
/// ```gleam
/// // let seam = paywall.seam(cache, slot, clock)
/// // seam.credential("proxy") == option.None
/// ```
///
pub fn seam(cache: Cache, slot: Slot, clock: Clock) -> paywall.Paywall {
  paywall.Paywall(
    credential: fn(provider) { cached(cache, provider) },
    settle: fn(provider, challenge) {
      settle(cache, slot, clock, provider, challenge)
    },
  )
}

fn settle(
  cache: Cache,
  slot: Slot,
  clock: Clock,
  provider: String,
  challenge: l402.Challenge,
) -> Result(String, String) {
  use bus <- result.try(borrow(slot))

  // The clock is read here rather than inside the bus because the
  // session's own clock is the one a simulated session steps, and a hook
  // paying from a spend ledger needs the same day boundary every other
  // durable decision in the session is made against.
  let #(now, _clock) = clock.read(clock)
  use preimage <- result.map(hooks.pay(bus, provider, challenge, now))
  let token = l402.authorization(challenge.macaroon, preimage)
  process.send(cache.subject, Store(provider:, token:))
  token
}

// The session's bus, or the reason there is nobody to ask. An absent
// slot and an unanswering one are different facts and stay different
// words: the first is a session with no payment extension, which is an
// ordinary configuration, and the second is a fault.
fn borrow(slot: Slot) -> Result(hooks.Bus, String) {
  case ask(slot.subject, Borrow) {
    Ok(Some(bus)) -> Ok(bus)
    Ok(None) -> Error(no_extension_reason)
    Error(Nil) -> Error(unavailable_reason)
  }
}

// A cache that is gone or wedged is a cache miss, which costs one 402
// and one settle and never a failed request.
fn cached(cache: Cache, provider: String) -> Option(String) {
  case ask(cache.subject, Read(provider, _)) {
    Ok(answer) -> answer
    Error(Nil) -> None
  }
}

// One question, degrading a dead or wedged callee to `Error(Nil)` rather
// than to the caller's death. Sent and selected by hand, watching the
// callee's monitor, for the reason `client/scratch.ask` gives: the
// caller is the provider gateway's pump, and `process.call` exits its
// *caller* on a timeout or a dead callee. `docs/weft.md` names a
// monitored non-panicking call as the one gap weft has been asked for
// and does not have, so this is the house pattern rather than a
// hand-rolled copy of a primitive.
fn ask(
  subject: Subject(message),
  build: fn(Subject(answer)) -> message,
) -> Result(answer, Nil) {
  use pid <- result.try(process.subject_owner(subject))
  let reply = process.new_subject()
  let monitor = process.monitor(pid)

  // The send happens after the monitor is installed, so a callee that
  // dies between the two is reported by the monitor rather than waited
  // out to the timeout.
  process.send(subject, build(reply))
  let answered =
    process.new_selector()
    |> process.select_map(reply, Some)
    |> process.select_specific_monitor(monitor, fn(_down) { None })
    |> process.selector_receive(within: ask_timeout_ms)
  process.demonitor_process(monitor)
  case answered {
    Ok(Some(value)) -> Ok(value)
    Ok(None) | Error(Nil) -> Error(Nil)
  }
}

// --- the two handlers -----------------------------------------------------

// The cache's state is an association list rather than a dict because it
// holds one entry per paywalled catalogue entry — a handful at most —
// and a list keeps the "latest write wins" rule to one prepend.
fn handle_cache(
  state: List(#(String, String)),
  message: CacheMessage,
) -> actor.Next(List(#(String, String)), CacheMessage) {
  case message {
    Read(provider:, reply_with:) -> {
      process.send(reply_with, option.from_result(key_find(state, provider)))
      actor.continue(state)
    }

    // The new token is prepended and the old one is dropped, so a
    // re-settle after the proxy expired a macaroon replaces rather than
    // shadows: nothing here walks past the first match, but a list that
    // grew on every settle would be an unbounded one.
    Store(provider:, token:) ->
      actor.continue([#(provider, token), ..dropping(state, provider)])
  }
}

fn handle_slot(
  state: Option(hooks.Bus),
  message: SlotMessage,
) -> actor.Next(Option(hooks.Bus), SlotMessage) {
  case message {
    // A second attach replaces the first. Nothing does that today — a
    // session starts one bus — and taking the newer one is the arm that
    // stays right if a session ever restarts its extensions.
    Fill(bus:) -> actor.continue(Some(bus))

    Borrow(reply_with:) -> {
      process.send(reply_with, state)
      actor.continue(state)
    }
  }
}

fn key_find(
  entries: List(#(String, String)),
  key: String,
) -> Result(String, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(found, value), ..] if found == key -> Ok(value)
    [_other, ..rest] -> key_find(rest, key)
  }
}

fn dropping(
  entries: List(#(String, String)),
  key: String,
) -> List(#(String, String)) {
  case entries {
    [] -> []
    [#(found, _value), ..rest] if found == key -> dropping(rest, key)
    [kept, ..rest] -> [kept, ..dropping(rest, key)]
  }
}
