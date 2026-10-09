//// Where a service on another node lives, and how to speak to it.
////
//// A node-level service (an executor's host, an orchestrator's session-owner
//// port) registers under a fixed local name, and a peer reaches it as
//// `{name, node}`. A `Subject` cannot express that: `gleam_erlang` resolves a
//// named subject on the sending node. So an `Address` is the pair, and
//// `deliver` and `watch` are the two operations on it. Everything after the
//// first exchange (replies, owner-port calls) travels over ordinary subjects,
//// because a request carries the subject the answer goes to.
////
//// An address is typed by the one message vocabulary its service accepts, so
//// the executor host's closed `HostMessage` and the orchestrator port's own
//// closed type share this module without either gaining the other's
//// constructors.
////
//// A name is an atom and the atom table is never collected, so the names
//// production uses are literals (`default_name` here, and the orchestrator
//// port's own), and a test that needs its own service makes a name with
//// `process.new_name`. Nothing builds a name from a peer's input.

import client/internal/ffi_remote
import client/remote/protocol.{type HostMessage}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Monitor, type Name}

/// A service on one node, as seen from another (or from a test in the same VM,
/// where the node is the local one). `message` is the closed vocabulary the
/// service accepts.
pub type Address(message) {
  Address(
    /// The service's node.
    node: Node,
    /// The name the service registered under there.
    name: Name(message),
  )
}

/// The registered name every production executor host uses.
pub const default_name = "loom_exec_host"

/// The production executor host name, for the executor to register and for an
/// orchestrator to address.
///
/// ## Examples
///
/// ```gleam
/// // address.Address(node: peer_node, name: address.default())
/// ```
pub fn default() -> Name(HostMessage(census)) {
  ffi_remote.fixed_name(default_name)
}

/// Sends a request to the service. Nothing is reported when its node is
/// unreachable, and the message is then lost; `watch` is how a caller finds out.
///
/// ## Examples
///
/// ```gleam
/// // address.deliver(host, protocol.Ack(key))
/// ```
pub fn deliver(address: Address(message), message: message) -> Nil {
  ffi_remote.send(to: address.node, name: address.name, message:)
}

/// Monitors the service. The `DOWN` arrives at once, with reason
/// `noconnection`, when its node is unreachable, and with `noproc` when nothing
/// is registered under the name there; it arrives later if either happens while
/// the monitor is held. The `DOWN`'s pid field is not a pid and must not be read.
///
/// ## Examples
///
/// ```gleam
/// // let monitor = address.watch(host)
/// ```
pub fn watch(address: Address(message)) -> Monitor {
  ffi_remote.watch(on: address.node, name: address.name)
}
