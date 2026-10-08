//// Where an executor's host lives, and how to speak to it from another node.
////
//// The host registers under a fixed local name, and a peer reaches it as
//// `{name, node}`. A `Subject` cannot express that: `gleam_erlang` resolves a
//// named subject on the sending node. So an `Address` is the pair, and
//// `deliver` and `watch` are the two operations on it. Everything after the
//// first exchange (replies, owner-port calls) travels over ordinary subjects,
//// because a request carries the subject the answer goes to.
////
//// A name is an atom and the atom table is never collected, so the one name
//// production uses is a literal here, and a test that needs its own host makes
//// a name with `process.new_name`. Nothing builds a name from a peer's input.

import client/internal/ffi_remote
import client/remote/protocol.{type HostMessage}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Monitor, type Name}

/// The host of one executor, as seen from an orchestrator (or from a test in
/// the same VM, where the node is the local one).
pub type Address(census) {
  Address(
    /// The executor's node.
    node: Node,
    /// The name its host registered under there.
    name: Name(HostMessage(census)),
  )
}

/// The registered name every production host uses.
pub const default_name = "loom_exec_host"

/// The production host name, for the executor to register and for an
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

/// Sends a request to the host. Nothing is reported when the executor is
/// unreachable, and the message is then lost; `watch` is how a caller finds out.
///
/// ## Examples
///
/// ```gleam
/// // address.deliver(host, protocol.Ack(key))
/// ```
pub fn deliver(address: Address(census), message: HostMessage(census)) -> Nil {
  ffi_remote.send(to: address.node, name: address.name, message:)
}

/// Monitors the host. The `DOWN` arrives at once, with reason `noconnection`,
/// when the executor's node is unreachable, and with `noproc` when no host is
/// registered there; it arrives later if either happens while the monitor is
/// held. The `DOWN`'s pid field is not a pid and must not be read.
///
/// ## Examples
///
/// ```gleam
/// // let monitor = address.watch(host)
/// ```
pub fn watch(address: Address(census)) -> Monitor {
  ffi_remote.watch(on: address.node, name: address.name)
}
