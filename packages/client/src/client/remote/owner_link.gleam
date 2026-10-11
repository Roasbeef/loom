//// The executor's half of the owner port: an `OwnerServices` whose every
//// function is a message to the orchestrator.
////
//// A workspace plane built on the executor asks its owner for a handful of
//// things while a tool runs: a decision on a policy refusal, a reserved fact,
//// a completion notice, a capability whose state lives with the
//// conversation. Locally those are direct calls (`owner_services.local`).
//// Here they are `OwnerMessage`s to the session's owner port, and the plane
//// cannot tell which it was given.
////
//// ## Waiting without trusting the other side to answer
////
//// Every request is a monitored call (`broker/internal/call.try_call`, never
//// `process.call`, which exits its caller when the callee is gone). If the
//// owner port dies, the node disconnects, or no reply comes inside the
//// budget, the function returns the in-band failure that fits its type, so the
//// tool run that asked reaches a terminal outcome instead of waiting on a
//// reply nobody will send:
////
//// | Function | When the owner is unavailable |
//// | --- | --- |
//// | `escalate` | `Settle`: the refusal stands, as with no escalation plane |
//// | fact operations | `Failed("owner unavailable")` |
//// | `capability` | a denial with code `owner_unavailable` |
//// | `holds` | `AgencyUnavailable` |
//// | `notify`, `strand_activity`, `wake` | an error naming the owner |
//// | `output` | the tail is dropped, as any lost tail is |
////
//// An escalation can legitimately wait the length of a human decision, so its
//// budget is the call's own remaining time, taken from the refusal's deadline
//// on this machine's clock, plus a small slack for the round trip. Only the
//// remaining duration crosses the wire, never the deadline itself, because the
//// two machines' clocks differ.
////
//// ## A link that can be re-pointed
////
//// A runtime incarnation that attaches again to a scope that stayed open has a
//// new owner port, and the workspace plane built for the first one must not be
//// rebuilt. So the plane holds a `Link`, a one-cell process that names the
//// current owner port, and `services` reads the cell on every call. Replacing
//// the cell changes where every later call goes. A call already waiting on the
//// old port ends through its monitor when that port dies, which it does with
//// the runtime that owned it.

import broker/internal/call
import client/escalate
import client/owner_services.{type OwnerServices, OwnerServices}
import client/remote/protocol.{type OwnerMessage}
import codemode/satellite
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/result
import gleam/string
import runtime/effects
import tools/agent
import tools/tool
import weft/actor

/// The cell that names the current owner port.
pub opaque type Link {
  Link(cell: Subject(Message))
}

type Message {
  Current(reply: Subject(Subject(OwnerMessage)))
  Replace(port: Subject(OwnerMessage))
  Stop
}

/// The sentence every unavailable fact operation carries.
pub const unavailable_text = "owner unavailable"

/// The code of the capability denial an unavailable owner produces.
pub const unavailable_code = "owner_unavailable"

// How long a call may wait for the cell itself, which only answers a read.
const cell_wait_ms = 1000

// The round trip an escalation is given beyond the call's remaining time.
const escalate_slack_ms = 2000

// Budgets for requests that read or write one record or one strand.
const record_wait_ms = 15_000

// A capability can run a spawn or a note write on the owner, so it gets far
// longer than a record read.
const capability_wait_ms = 120_000

/// Starts a link naming `port`, linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(link) = owner_link.start(port)
/// ```
pub fn start(port: Subject(OwnerMessage)) -> Result(Link, String) {
  actor.new(port)
  |> actor.on_message(hold)
  |> actor.start
  |> result.map(fn(started) { Link(cell: started.data) })
  |> result.map_error(string.inspect)
}

/// Points every later call at a new owner port.
///
/// ## Examples
///
/// ```gleam
/// // owner_link.replace(link, next_port)
/// ```
pub fn replace(link: Link, port: Subject(OwnerMessage)) -> Nil {
  process.send(link.cell, Replace(port))
}

/// Ends the link's process. Calls made afterwards find no owner.
///
/// ## Examples
///
/// ```gleam
/// // owner_link.stop(link)
/// ```
pub fn stop(link: Link) -> Nil {
  process.send(link.cell, Stop)
}

/// The workspace's `OwnerServices`, backed by messages to whichever owner port
/// the link currently names.
///
/// `clock` is the executor's clock, the one the plane's budgets and the
/// refusals' deadlines are read from. Building the plane on any other clock
/// makes an escalation's remaining time meaningless.
///
/// ## Examples
///
/// ```gleam
/// // owner_link.services(link, clock)
/// ```
pub fn services(link: Link, clock: Clock) -> OwnerServices {
  OwnerServices(
    escalate: fn(refused) { decide(link, clock, refused) },
    facts: owner_services.FactAccess(
      cell: fn(key) {
        ask(link, record_wait_ms, protocol.FactGet(key, _))
        |> fact_answer
      },
      put: fn(key, value, expected) {
        ask(link, record_wait_ms, protocol.FactPut(key, value, expected, _))
        |> fact_answer
      },
      put_blind: fn(key, value) {
        ask(link, record_wait_ms, protocol.FactPutBlind(key, value, _))
        |> fact_answer
      },
      delete: fn(key) {
        ask(link, record_wait_ms, protocol.FactDelete(key, _))
        |> fact_answer
      },
      list: fn(prefix) {
        ask(link, record_wait_ms, protocol.FactList(prefix, _))
        |> fact_answer
      },
    ),
    output: fn(run) { tail_to(link, run) },
    capability: fn(call) {
      ask(link, capability_wait_ms, protocol.Capability(call, _))
      |> result.lazy_unwrap(fn() { Error(denial()) })
    },
    holds: fn(caller, name) {
      ask(link, record_wait_ms, protocol.Holds(caller, name, _))
      |> result.lazy_unwrap(fn() { Error(agent.AgencyUnavailable) })
    },
    notify: fn(strand, work, text) {
      ask(link, record_wait_ms, protocol.Notify(strand, work, text, _))
      |> result.lazy_unwrap(fn() { Error(unavailable_text) })
    },
    strand_activity: fn(strand) {
      ask(link, record_wait_ms, protocol.StrandActivity(strand, _))
      |> result.lazy_unwrap(fn() { Error(unavailable_text) })
    },
    wake: fn(strand, text) {
      ask(link, record_wait_ms, protocol.Wake(strand, text, _))
      |> result.lazy_unwrap(fn() { Error(unavailable_text) })
    },
  )
}

// Asks the owner to decide a refusal, giving it the call's remaining time.
fn decide(
  link: Link,
  clock: Clock,
  refused: escalate.Refused,
) -> escalate.Decision {
  let #(now, _clock) = clock.read(clock)
  let remaining = int.max(0, refused.deadline_ms - now)

  // A decision arriving after the call's own deadline cannot be used, since the
  // re-clearance would be refused by the budget, so the wait ends with it.
  ask(link, remaining + escalate_slack_ms, protocol.Escalate(
    refused,
    remaining,
    _,
  ))
  |> result.lazy_unwrap(fn() { escalate.Settle })
}

// The tail observer for one run. The owner port is read once, as
// `OwnerServices.output` documents, and a tail is a cast that a dead port or a
// dropped connection loses without a word.
fn tail_to(link: Link, run: effects.ToolRun) -> fn(tool.OutputTail) -> Nil {
  case current(link) {
    Ok(port) -> fn(tail) { process.send(port, protocol.Tail(run, tail)) }
    Error(call.CalleeGone) | Error(call.NoReply) -> fn(_tail) { Nil }
  }
}

fn denial() -> satellite.CapDenial {
  satellite.CapDenial(
    code: unavailable_code,
    message: "the session's owner could not be reached for this capability",
  )
}

// A fact operation's answer, or the fault an unreachable owner stands for.
fn fact_answer(
  asked: Result(Result(a, owner_services.FactFault), call.CallFault),
) -> Result(a, owner_services.FactFault) {
  result.lazy_unwrap(asked, fn() {
    Error(owner_services.Failed(detail: unavailable_text))
  })
}

// One monitored request to the current owner port.
fn ask(
  link: Link,
  waiting: Int,
  sending: fn(Subject(reply)) -> OwnerMessage,
) -> Result(reply, call.CallFault) {
  use port <- result.try(current(link))
  call.try_call(port, waiting:, sending:)
}

fn current(link: Link) -> Result(Subject(OwnerMessage), call.CallFault) {
  call.try_call(link.cell, waiting: cell_wait_ms, sending: Current)
}

fn hold(
  port: Subject(OwnerMessage),
  message: Message,
) -> actor.Next(Subject(OwnerMessage), Message) {
  case message {
    Current(reply:) -> {
      process.send(reply, port)
      actor.continue(port)
    }
    Replace(port: next) -> actor.continue(next)
    Stop -> actor.stop()
  }
}
