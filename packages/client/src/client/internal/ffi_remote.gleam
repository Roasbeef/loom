//// FFI confinement (spec §0.2): the three operations remote tool calls need
//// that `gleam_erlang` cannot express, each bound straight to a stock OTP
//// or `gleam_stdlib` function so that no Erlang source is added.
////
//// A `Subject` is a pid and a tag, and a `Name` is only reachable on the
//// node that registered it: `process.send` on a named subject looks the name
//// up with `whereis` on the sending node. The executor's host is reached by
//// its fixed registered name on another node, before the caller holds any
//// pid or `Subject` of it, so the address has to be `{Name, Node}`. These
//// bindings are that address and nothing else; they create no atom from
//// network input, because the only atom they ever make is the fixed name the
//// caller spells out.

import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Monitor, type Name}

type DoNotLeak

// The selector of an `erlang:monitor` call. A nullary constructor compiles
// to the atom `process`, which is the kind OTP asks for.
type MonitorKind {
  Process
}

// OTP `erlang:send/2` with a `{RegisteredName, Node}` destination. The
// message is `{Name, Message}`, the exact shape `process.send` writes to a
// named subject and `process.select` reads from one, so the receiver selects
// it with an ordinary `process.named_subject`. No pure alternative exists:
// `gleam_erlang` has no remote name. A node that is not connected drops the
// message, because distribution never dials on its own here (see
// `client/distribution`), which is the behaviour the callers rely on.
@external(erlang, "erlang", "send")
fn raw_send(
  target: #(Name(message), Node),
  message: #(Name(message), message),
) -> DoNotLeak

// OTP `erlang:monitor(process, {RegisteredName, Node})`. The monitor answers
// `noconnection` when the node is unreachable and `noproc` when the name is
// not registered there, both as an ordinary `DOWN`. The pid field of that
// `DOWN` is the `{Name, Node}` tuple rather than a pid, so a caller must not
// read it.
@external(erlang, "erlang", "monitor")
fn raw_monitor(kind: MonitorKind, target: #(Name(message), Node)) -> Monitor

// `gleam_stdlib:identity/1`, which returns its argument. A `Name` is an atom
// at runtime and `gleam_erlang` mints names only with a unique suffix, so a
// name that two nodes must agree on cannot be made with `new_name`.
@external(erlang, "gleam_stdlib", "identity")
fn name_from_atom(name: atom.Atom) -> Name(message)

/// The name that two nodes agree on, made from fixed text.
///
/// The text must be a literal chosen by the program, never anything read off
/// the network, because the atom table is not garbage collected.
///
/// ## Examples
///
/// ```gleam
/// // ffi_remote.fixed_name("loom_exec_host")
/// ```
pub fn fixed_name(text: String) -> Name(message) {
  name_from_atom(atom.create(text))
}

/// Sends `message` to the process registered as `name` on `node`.
///
/// Nothing is reported when the node is unreachable or the name is not
/// registered there; a caller that needs to know watches the destination
/// with `watch`. A name that is not registered on the local node raises, so
/// this is for peers on other nodes, and for a local host that is known to
/// be up.
///
/// ## Examples
///
/// ```gleam
/// // ffi_remote.send(node, name, message)
/// ```
pub fn send(
  to node: Node,
  name name: Name(message),
  message message: message,
) -> Nil {
  let _sent = raw_send(#(name, node), #(name, message))
  Nil
}

/// Monitors the process registered as `name` on `node`. The `DOWN` arrives at
/// once when the node is unreachable or the name is not registered, with
/// reason `noconnection` or `noproc`.
///
/// ## Examples
///
/// ```gleam
/// // let monitor = ffi_remote.watch(node, name)
/// ```
pub fn watch(on node: Node, name name: Name(message)) -> Monitor {
  raw_monitor(Process, #(name, node))
}
