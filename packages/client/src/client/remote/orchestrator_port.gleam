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
//// beside `Owns`: `PeerCommand` carries one of the four commands a session's
//// peer mail sends to a recipient on another orchestrator
//// (`client/remote/remote_peer` is the sending end).
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
////
//// A `PeerCommand` is served on the same trust. A peer orchestrator is pinned
//// by the operator and can already do anything the distribution connection
//// allows, so the port limits what it forwards for the sake of correctness
//// rather than as an access boundary: the sending orchestrator authenticates
//// its own session and puts that session's identity in the command, and the
//// recipient's grant is still the authority that admits it.

import client/internal/ffi_remote
import client/peer_mail
import client/remote/address.{type Address}
import core/json.{type JsonValue}
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

  /// One peer-mail command for a session this daemon holds, from the
  /// orchestrator whose session is sending to it (protocol-change/078, phase
  /// 4). Only `Allow`, `Revoke`, `Deliver` and `SentReceipt` are served; the
  /// port refuses every other command, because the sending orchestrator never
  /// needs another and each one reads or writes state a remote peer has no
  /// business with. The answer is the local Agency's own, so a repeated
  /// `Deliver` is answered from the stored receipt exactly as it is in one VM.
  PeerCommand(
    /// The canonical identity of the recipient session.
    session: String,
    /// The command, which is plain data and carries no process or closure.
    command: peer_mail.Command,
    /// Where the answer goes. A command that was refused is answered with
    /// `Error`; nothing is sent when the port itself could not run.
    reply: Subject(Result(JsonValue, String)),
  )
}

/// What the port answers.
pub type Ownership {
  /// The session is in this daemon's catalogue, in any state.
  Owned

  /// It is not.
  NotOwned
}

/// What the port does with a peer command once it has accepted the kind: find
/// the session's Agency here and ask it. A refusal that the session is not
/// resident on this daemon is `Error(peers.not_running)`, the text a local send
/// to a session that is not resident gets.
pub type PeerHandler =
  fn(String, peer_mail.Command) -> Result(JsonValue, String)

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
/// A port started this way refuses every peer command, which is what a daemon
/// with nothing to deliver to answers. `start_serving` takes the handler that
/// forwards them.
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
  start_serving(name, held, fn(_session, _command) { Error(peer_unserved) })
}

/// Starts the port as `start` does, and serves peer commands with `peer`.
/// The port decides which kinds of command are served; `peer` is only called
/// for those.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start_serving(orchestrator_port.default(), held, forward)
/// ```
pub fn start_serving(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) { answer(held, peer, state, message) })
  |> actor.named(name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

/// The refusal for a peer command of a kind the port does not serve.
pub const peer_unserved = "that command is not served to a peer orchestrator"

// One question, answered from the catalogue before the next is read. The
// catalogue read is a call into the registry, so a slow registry delays later
// questions; each asker bounds its own wait and treats a late answer as
// silence, so nothing here needs a queue of its own.
//
// A peer command is answered in the same loop. It waits on the session's
// Agency for at most that Agency's holder timeout, so a wedged session delays
// the questions behind it by that long and no longer; a sender whose deadline
// passes first treats the late answer as silence and asks again, and an asked
// `Deliver` that did commit answers its repeat with the stored receipt.
fn answer(
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
  state: Nil,
  message: Message,
) -> actor.Next(Nil, Message) {
  case message {
    Owns(session:, reply:) ->
      case held(session) {
        Ok(ownership) -> process.send(reply, ownership)
        Error(Nil) -> Nil
      }

    PeerCommand(session:, command:, reply:) ->
      case served(command) {
        True -> process.send(reply, peer(session, command))
        False -> process.send(reply, Error(peer_unserved))
      }
  }
  actor.continue(state)
}

// The four commands `client/peers` sends to a recipient. Everything else is
// the recipient's own business or a read of its conversation: `Inbox`,
// `History` and `Received` page what the session holds, `Link` and `Unlink`
// edit the sender's own index, and the `Outbox*` commands belong to the
// sending session. The match names every constructor, so a new command is a
// compile error here until someone decides whether a peer may send it.
fn served(command: peer_mail.Command) -> Bool {
  case command {
    peer_mail.Allow(..)
    | peer_mail.Revoke(..)
    | peer_mail.Deliver(..)
    | peer_mail.SentReceipt(..) -> True

    peer_mail.Link(..)
    | peer_mail.Unlink(..)
    | peer_mail.Links(..)
    | peer_mail.Grants(..)
    | peer_mail.Describe(..)
    | peer_mail.Activity(..)
    | peer_mail.Roster(..)
    | peer_mail.Inbox(..)
    | peer_mail.InboxGet(..)
    | peer_mail.History(..)
    | peer_mail.Received(..)
    | peer_mail.ReceivedGet(..)
    | peer_mail.Overview
    | peer_mail.OutboxClaim(..)
    | peer_mail.OutboxSettle(..)
    | peer_mail.OutboxDue
    | peer_mail.OutboxReceipt(..) -> False
  }
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
