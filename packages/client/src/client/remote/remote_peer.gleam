//// A recipient session's `peer_mail.Endpoint` on another orchestrator
//// (protocol-change/078, phase 4).
////
//// Peer mail was written against an `Endpoint`: a session identity and one
//// function that takes a command and answers. Every operation in
//// `client/peers` (link, send, unlink, the receipt lookup) reaches its
//// recipient only through that function, so a recipient on another node needs
//// a different function and nothing else. This module builds it. Its `call`
//// sends the command to the owner's orchestrator port
//// (`client/remote/orchestrator_port.PeerCommand`) and waits for the answer
//// the owner's own Agency gave.
////
//// ## Four outcomes
////
//// A call ends in one of four ways, and the sender's outbox depends on telling
//// them apart:
////
//// | What happened | The call returns |
//// | --- | --- |
//// | The owner's Agency answered | `Ok(value)` |
//// | The owner answered with a refusal, or its port refused the command | `Error(Refused(reason))` |
//// | The owner holds the session saved and not resident | `Error(NotOpen)` |
//// | The node is gone (`noconnection`), no port is registered, or no answer arrived in time | `Error(Unreachable)` |
////
//// The monitor is taken before the request is sent, as `orchestrator_port.ask`
//// does, so a node that is already unreachable ends the wait at once with its
//// `DOWN` instead of with the deadline. A reply that arrives after the
//// deadline reaches nobody. That is the lost-reply case the outbox expects: the
//// recipient may have committed, the sender is told `Unreachable`, and the
//// repeat gets the stored receipt (`peer_mail.deliver`).
////
//// ## Reaching a configured peer
////
//// `over_distribution` builds the endpoints a daemon uses. It connects to the
//// pinned peer before the first send, because a node that is not yet connected
//// loses the message silently, and it resolves the node through the membership
//// so that nothing a peer sends is turned into an atom.

import client/distribution.{type Membership}
import client/orchestrators.{type Orchestrator}
import client/peer_mail
import client/remote/address.{type Address}
import client/remote/orchestrator_port
import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/result

/// How long a call waits for the owner's answer. The owner's Agency bounds its
/// own work at five seconds (`agency.Config.holder_timeout_ms`), so this leaves
/// room for the round trip beyond it.
pub const call_ms = 7000

/// How long a read for a listing waits (`Roster`), once connected. A listing
/// asks once for every link, so a slow owner is shown as unavailable rather
/// than holding the rest of the listing for the seven seconds a delivery may.
pub const read_ms = 2000

// The bound on connecting to a peer that is not connected yet. It is shorter
// than the call so that an unreachable host costs the sender little.
const connect_ms = 1500

/// How long a call to the owner waits for the answer to `command`: `read_ms`
/// for the `Roster` read a listing makes, and `call_ms` for every command that
/// changes or admits something.
///
/// ## Examples
///
/// ```gleam
/// assert remote_peer.wait_ms(peer_mail.Roster("s", "main")) == remote_peer.read_ms
/// ```
pub fn wait_ms(command: peer_mail.Command) -> Int {
  case command {
    peer_mail.Roster(..) -> read_ms
    _ -> call_ms
  }
}

/// The endpoint for `session` on the orchestrator port at `at`, waiting at most
/// `within_ms` for each answer.
///
/// ## Examples
///
/// ```gleam
/// // remote_peer.at(Address(node: peer, name: orchestrator_port.default()), session, 7000)
/// ```
pub fn at(
  address: Address(orchestrator_port.Message),
  session: String,
  within_ms: Int,
) -> peer_mail.Endpoint {
  peer_mail.Endpoint(session:, call: fn(command) {
    ask(address, session, command, within_ms)
  })
}

/// The production endpoints: for a session owned by `orchestrator`, an endpoint
/// that connects to the pinned peer if it is not connected and then asks its
/// port. A peer the membership does not know and a refused handshake are
/// `Unreachable`. A call waits `wait_ms` for its answer.
///
/// ## Examples
///
/// ```gleam
/// // let reach = remote_peer.over_distribution(membership)
/// // reach(orchestrator, session_id)
/// ```
pub fn over_distribution(
  membership: Membership,
) -> fn(Orchestrator, String) -> peer_mail.Endpoint {
  fn(orchestrator: Orchestrator, session: String) {
    peer_mail.Endpoint(session:, call: fn(command) {
      use peer <- result.try(
        distribution.peer(membership, orchestrator.node)
        |> result.replace_error(peer_mail.Unreachable),
      )
      use Nil <- result.try(
        distribution.connect(peer, connect_ms)
        |> result.replace_error(peer_mail.Unreachable),
      )
      ask(
        address.Address(
          node: distribution.node(peer),
          name: orchestrator_port.default(),
        ),
        session,
        command,
        wait_ms(command),
      )
    })
  }
}

// One monitored exchange with the port. The reply subject is made here and
// travels in the message, so the answer returns over the same connection. The
// selector ends on whichever comes first: the answer, the `DOWN` of the
// service, or the deadline. Demonitoring flushes a `DOWN` that arrived beside
// the reply.
fn ask(
  at: Address(orchestrator_port.Message),
  session: String,
  command: peer_mail.Command,
  within_ms: Int,
) -> Result(JsonValue, peer_mail.Failure) {
  let reply = process.new_subject()
  let watch = address.watch(at)
  address.deliver(at, orchestrator_port.PeerCommand(session:, command:, reply:))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(within_ms)
  process.demonitor_process(watch)
  case heard {
    Ok(Ok(answer)) -> result.map_error(answer, failure_of)
    Ok(Error(Nil)) | Error(Nil) -> Error(peer_mail.Unreachable)
  }
}

// The owner's refusal text as a failure. The one text that is not a refusal is
// the owner's answer that it holds the session and has not opened it
// (`peer_mail.not_open_reason`); it is a text because the port's reply type
// carries one, and this is the only place it is turned back into a variant.
fn failure_of(text: String) -> peer_mail.Failure {
  case text == peer_mail.not_open_reason {
    True -> peer_mail.NotOpen
    False -> peer_mail.Refused(text)
  }
}
