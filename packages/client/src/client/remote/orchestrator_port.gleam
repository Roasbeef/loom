//// The orchestrator port: how one orchestrator answers another's question
//// "do you hold this session?" (protocol-change/078, phase 3).
////
//// Two orchestrators each keep their own catalogue, and a session is created
//// on, and owned by, the orchestrator the client was connected to. When a
//// client asks the other orchestrator about that session, the other one has no
//// record, and it asks its configured peers (`client/session_directory`). This
//// module is the answering end. It is a node-level service in the sense
//// `client/remote/host` is: one process per daemon, registered under a fixed
//// name, reached as `{name, node}` (`client/remote/address`).
////
//// It has its own closed message type and its own name, and it does not extend
//// the executor host's `HostMessage`. Every executor answers `HostMessage`, and
//// an executor's ledger actor would then carry a read it has nothing to do with.
//// Phase 4 adds peer-mail delivery as a second constructor of `Message` here,
//// beside `Owns`.
////
//// The answer comes from the daemon's catalogue and from nowhere else. A
//// `reserved` registration counts as held, because a creation retried under its
//// original key must still reach the orchestrator that reserved it, and an
//// archived session counts as held, because it is still that orchestrator's to
//// restore. A catalogue that cannot answer produces no reply at all: the asker's
//// deadline turns silence into "could not tell", which is what it is. Replying
//// `NotOwned` for a failed read would let a transient fault read as proof that
//// the session exists nowhere.
////
//// The port reveals only whether an identity is in this daemon's catalogue, to a
//// peer the operator pinned as a trusted Erlang node. It carries no credential,
//// and a client is never redirected by it: the asking daemon decides what its
//// own client is told.

import client/internal/ffi_remote
import client/remote/address.{type Address}
import gleam/erlang/process.{type Name, type Subject}
import runtime/residency
import weft/actor

/// The registered name every production daemon uses for its port.
pub const default_name = "loom_orchestrator"

/// What the port is asked.
pub type Message {
  /// Whether this daemon's catalogue holds the session. The answer goes to
  /// `reply`, which the asker owns.
  Owns(
    /// The canonical session identity.
    session: String,
    /// Where the answer goes.
    reply: Subject(Ownership),
  )
}

/// What the port answers.
pub type Ownership {
  /// The session is in this daemon's catalogue, in any state.
  Owned

  /// It is not.
  NotOwned
}

/// The production port name, for a daemon to register and for its peers to
/// address.
///
/// ## Examples
///
/// ```gleam
/// // address.Address(node: peer_node, name: orchestrator_port.default())
/// ```
pub fn default() -> Name(Message) {
  ffi_remote.fixed_name(default_name)
}

/// Starts the port under `name`, linked to the caller. `held` reads this
/// daemon's catalogue: `Ok(Owned)` or `Ok(NotOwned)` when it could tell, and
/// `Error(Nil)` when it could not, in which case nothing is sent.
///
/// The start fails, and registers nothing, if the name is taken.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start(orchestrator_port.default(), held)
/// ```
pub fn start(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) { answer(held, state, message) })
  |> actor.named(name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

// One question, answered from the catalogue before the next is read. The
// catalogue read is a call into the registry, so a slow registry delays later
// questions; each asker bounds its own wait and treats a late answer as
// silence, so nothing here needs a queue of its own.
fn answer(
  held: fn(String) -> Result(Ownership, Nil),
  state: Nil,
  message: Message,
) -> actor.Next(Nil, Message) {
  let Owns(session:, reply:) = message
  case held(session) {
    Ok(ownership) -> process.send(reply, ownership)
    Error(Nil) -> Nil
  }
  actor.continue(state)
}

/// Asks the port at `at` whether it holds the session, and waits at most
/// `within_ms` for the answer.
///
/// `Error(Nil)` means no answer: the node is unreachable, no port is registered
/// there, the port did not answer in time, or it could not read its catalogue.
/// The monitor is taken before the request is sent, so a node that is already
/// gone ends the wait at once with its `DOWN` instead of with the deadline.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask(Address(node: peer, name: orchestrator_port.default()), id, 1500)
/// ```
pub fn ask(
  at: Address(Message),
  session: String,
  within_ms: Int,
) -> Result(Ownership, Nil) {
  let reply = process.new_subject()
  let watch = address.watch(at)
  address.deliver(at, Owns(session:, reply:))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(within_ms)

  // Demonitoring flushes a `DOWN` that arrived beside the reply.
  process.demonitor_process(watch)
  case heard {
    Ok(answered) -> answered
    Error(Nil) -> Error(Nil)
  }
}
