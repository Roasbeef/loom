//// One process that holds the configuration a session's tool runs need, so
//// the closures which run tools capture an address instead of the
//// configuration.
////
//// `runtime/effects.Effects` is a record of closures, and a session
//// assembly copies it into every supervisor child specification and actor
//// that holds the session's runtime. The BEAM does not preserve sharing
//// when it copies a term, so a closure that captures `wiring.Config` puts
//// one full copy of the tool registry into each of those holders. The
//// `run` slot is such a closure, and a profiled daemon with one open
//// session held 29 copies of the registry, 27 of them through that slot
//// (`docs/design-notes/daemon-memory.md`, 2026-10-04 addendum).
////
//// This module moves the one copy that is needed into the one process
//// that should own it. The session keeps the configuration here for its
//// lifetime. A tool run asks for it, runs against the answer, and lets the
//// answer go, so the registry is copied once per tool call rather than once
//// per holder of the effects. A tool call already costs a jailed process
//// and a model round trip, and a copy of a few hundred kilobytes is small
//// next to either.
////
//// The module is generic in the configuration so that `client/wiring`, which
//// defines `Config`, can depend on it without a cycle.
////
//// ## Lifetime
////
//// The holder must outlive the runtime, because tools run until the
//// runtime drains. `client/serve` starts it before the runtime opens and
//// hands it to the instance owner as a custody part which cleans up
//// immediately after the runtime's own drain (`instance_owner.ToolConfig`).
//// A fetch against a holder that is gone or does not answer in time is
//// reported as `Unavailable`; the caller turns that into an in-band tool
//// failure and never crashes.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/result
import gleam/string
import runtime/residency
import weft/actor

/// A running holder, and the address of the process behind it.
///
/// The pid is kept beside the subject so a fetch can monitor the holder it
/// sent to: a message to a dead process is silently dropped, and without the
/// monitor the caller would wait out its whole deadline to learn it.
pub opaque type Holder(config) {
  Holder(pid: Pid, requests: Subject(Message(config)))
}

/// Why a holder could not hand back its configuration.
pub type Unavailable {
  /// The holder had exited before or while the request was in flight.
  Gone

  /// The holder was alive but did not answer inside the deadline.
  TimedOut
}

type Message(config) {
  Fetch(reply: Subject(config))
  Stop
}

// How long a caller waits for the holder to retire after asking it to stop.
// The holder does no work beyond answering requests, so this bounds a
// scheduler stall rather than an operation.
const stop_deadline_ms = 5000

/// Starts a holder over `config`, linked to the calling process.
///
/// The link is the caller's to manage. A builder which later hands the
/// holder to a custodian unlinks it once the custodian has acknowledged
/// custody, so that the holder survives the builder; until then a builder
/// that dies takes the holder with it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(holder) = tool_holder.start(config)
/// // tool_holder.fetch(holder, within_ms: 1000) == Ok(config)
/// ```
pub fn start(config: config) -> Result(Holder(config), String) {
  // The configuration is live for the session but the process answers a
  // request only when a tool runs, so it is idle most of the time. Hibernation
  // compacts the heap that the one startup copy left behind.
  let builder =
    actor.new(config)
    |> actor.on_message(handle)
    |> actor.hibernate_after(residency.hibernate_after_ms)

  actor.start(builder)
  |> result.map(fn(started) { Holder(pid: started.pid, requests: started.data) })
  |> result.map_error(string.inspect)
}

/// The process behind the holder, for a custodian that links or monitors it.
///
/// ## Examples
///
/// ```gleam
/// // process.unlink(tool_holder.pid(holder))
/// ```
pub fn pid(holder: Holder(config)) -> Pid {
  holder.pid
}

/// Asks the holder for its configuration, waiting at most `within_ms`.
///
/// A holder that has exited answers `Gone` at once through its monitor. This
/// is the failure the caller must survive without crashing, which is why it
/// does not use `process.call`: that exits its caller on a timeout or a dead
/// callee, and the caller here is a tool effect that owes the runtime an
/// answer.
///
/// A reply which arrives after the deadline stays in the caller's mailbox.
/// The caller is a short-lived effect process, so the stray message is
/// discarded when it exits.
///
/// ## Examples
///
/// ```gleam
/// // case tool_holder.fetch(holder, within_ms: 5000) {
/// //   Ok(config) -> run_against(config)
/// //   Error(_unavailable) -> fail_in_band()
/// // }
/// ```
pub fn fetch(
  holder: Holder(config),
  within_ms within_ms: Int,
) -> Result(config, Unavailable) {
  let reply = process.new_subject()
  let watch = process.monitor(holder.pid)

  // The monitor is created before the send so that a holder dying between
  // the two is still reported as a death, not as a deadline.
  process.send(holder.requests, Fetch(reply))
  let outcome =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Gone) })
    |> process.selector_receive(within_ms)
  process.demonitor_process(watch)
  result.unwrap(outcome, Error(TimedOut))
}

/// Stops the holder and returns once it has exited.
///
/// Success means the process is gone, which is the proof a custody cleanup
/// must give. A holder that was already gone is a success, since stopping it
/// again has nothing left to retire.
///
/// ## Examples
///
/// ```gleam
/// // assert tool_holder.stop(holder) == Ok(Nil)
/// ```
pub fn stop(holder: Holder(config)) -> Result(Nil, String) {
  let watch = process.monitor(holder.pid)
  process.send(holder.requests, Stop)
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(stop_deadline_ms)
  process.demonitor_process(watch)
  result.replace_error(outcome, "the tool configuration holder did not retire")
}

fn handle(
  config: config,
  message: Message(config),
) -> actor.Next(config, Message(config)) {
  case message {
    Fetch(reply:) -> {
      process.send(reply, config)
      actor.continue(config)
    }
    Stop -> actor.stop()
  }
}
