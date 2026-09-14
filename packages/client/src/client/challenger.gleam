//// The harness half of `provider/challenger`: the seam that lets the
//// provider gateway ask an installed extension what to send with a
//// request, and what to send instead when the provider refuses it.
////
//// `provider/challenger.Challenger` is two injected functions and no
//// opinion about what a challenge means. This module supplies them for a
//// served session, and exists because the two ends of that seam sit on
//// opposite sides of a knot. The gateway is built from the catalogue
//// before any session exists; the hook bus is started per session, after
//// the session's `Effects` have been composed. So there is no moment at
//// which a challenger closing over a bus could be constructed — the bus
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
//// extension never attaches, and both functions say so rather than
//// hanging.
////
//// ## There is no cache here, and that is the ruling
////
//// The harness holds no credential. Both functions are a question put
//// to the extension: `headers` asks `provider_request` before every
//// attempt, and `answer` asks `provider_challenge` after the provider
//// has refused one. Whatever comes back is used once and forgotten.
////
//// The party that satisfied a challenge is the only one that knows what
//// it bought, which entry and model it bought it for, and when it stops
//// being worth anything. A copy kept here could only guess at all three,
//// and would go on presenting a dead credential after the answerer had
//// already replaced it. So the durable store is the extension's own —
//// `ext/memory`, in the extension that paid — which is the arrangement
//// pi's paying fetch has, with the harness as middleware around its own
//// request rather than as a keeper of anything.
////
//// The cost is one hook round trip per provider request, bounded by the
//// `provider_request` subscription's own deadline. That is the price of
//// the harness not holding a secret it cannot judge, and it is the price
//// the ruling accepts.
////
//// ## What is deliberately not here
////
//// No parsing. A challenge's grammar belongs to whichever scheme the
//// provider speaks, and the extension is the party that knows which one
//// that is; a reading of it written here would be a second, weaker
//// opinion an author would have to work around.
////
//// No budget, no ceiling, no rate limit either, for the same reason:
//// whatever answering a challenge costs, the extension is the party that
//// paid it and the only one that can bound the spend.

import client/extension/hooks
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/challenger
import weft/actor

/// How long the slot is given to answer before the caller gives up on
/// it.
///
/// Its handler hands back the one value it holds and blocks on nothing,
/// so this bound is only ever reached by a VM in trouble. It exists
/// because the caller is the provider gateway's own pump: a question
/// that waited forever would wedge a request, and one asked with
/// `process.call` would kill it outright.
pub const ask_timeout_ms = 1000

/// The reason `answer` gives when this session has no hook bus to ask.
///
/// A session with no installed extension never attaches a bus, and the
/// honest answer to "satisfy this challenge" is that nobody here can. It
/// reaches the model as `stream.ChallengeUnanswered`, so it is worded for
/// an operator reading a failed request rather than for a log.
pub const no_extension_reason = "no extension is installed to answer a provider's challenge"

/// The reason `answer` gives when the session's slot did not answer.
pub const unavailable_reason = "the session's challenge seam did not answer"

/// The per-session door onto the hook bus, filled once the bus exists.
///
/// Opaque because the subject is the whole of it, and holding an
/// `Option` rather than a bus because "no bus yet" and "no bus ever" are
/// the same state to a question that arrives: both mean there is nobody
/// to ask right now.
pub opaque type Slot {
  Slot(subject: Subject(SlotMessage))
}

type SlotMessage {
  Fill(bus: hooks.Bus)
  Borrow(reply_with: Subject(Option(hooks.Bus)))
}

/// Starts an empty slot, before the session's bus exists.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(slot) = challenger.slot()
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
/// the session is not a request it could not have been asked about a
/// moment earlier.
///
/// ## Examples
///
/// ```gleam
/// // challenger.attach(slot, bus)
/// ```
///
pub fn attach(slot: Slot, bus: hooks.Bus) -> Nil {
  process.send(slot.subject, Fill(bus:))
}

/// The `provider/challenger.Challenger` one session hands its gateway.
///
/// Both functions borrow the session's bus and ask an extension. Neither
/// remembers what came back, because the harness keeps no credential:
/// `headers` puts `provider_request` before every attempt and sends
/// whatever it is told, and `answer` puts `provider_challenge` after a
/// refusal and returns whatever it is told, once.
///
/// `headers` answers `None` for an empty header list as well as for a
/// session with no bus. The two are one fact to the gateway — there is
/// nothing to add to the adapter's own headers — and a provider that
/// wanted something states its terms in the challenge that follows.
///
/// ## Examples
///
/// ```gleam
/// // let seam = challenger.seam(slot, clock)
/// // seam.headers("proxy", "model-a") == option.None
/// ```
///
pub fn seam(slot: Slot, clock: Clock) -> challenger.Challenger {
  challenger.Challenger(
    headers: fn(provider, model_id) { headers(slot, clock, provider, model_id) },
    answer: fn(provider, challenge) { answer(slot, clock, provider, challenge) },
  )
}

// The headers the extensions supply for this attempt, or `None`. A
// session with no bus and a bus that supplied nothing are the same
// answer here, which is why this is an `Option` rather than a `Result`:
// there is no reason to carry, because sending no extra header is an
// ordinary request rather than a failure.
fn headers(
  slot: Slot,
  clock: Clock,
  provider: String,
  model_id: String,
) -> Option(List(#(String, String))) {
  case borrow(slot) {
    Error(_reason) -> None

    Ok(bus) -> {
      let #(now, _clock) = clock.read(clock)
      case hooks.request_headers(bus, provider, model_id, now) {
        [] -> None
        supplied -> Some(supplied)
      }
    }
  }
}

fn answer(
  slot: Slot,
  clock: Clock,
  provider: String,
  challenge: challenger.Challenge,
) -> Result(List(#(String, String)), String) {
  use bus <- result.try(borrow(slot))

  // The clock is read here rather than inside the bus because the
  // session's own clock is the one a simulated session steps, and a hook
  // keeping a ledger of what it has answered needs the same day boundary
  // every other durable decision in the session is made against.
  let #(now, _clock) = clock.read(clock)
  hooks.answer_challenge(bus, provider, challenge, now)
}

// The session's bus, or the reason there is nobody to ask. An absent
// slot and an unanswering one are different facts and stay different
// words: the first is a session with no answering extension, which is an
// ordinary configuration, and the second is a fault.
fn borrow(slot: Slot) -> Result(hooks.Bus, String) {
  case ask(slot.subject, Borrow) {
    Ok(Some(bus)) -> Ok(bus)
    Ok(None) -> Error(no_extension_reason)
    Error(Nil) -> Error(unavailable_reason)
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
