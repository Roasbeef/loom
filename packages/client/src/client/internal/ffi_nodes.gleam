//// The node set of this VM, as the membership ledger's anti-entropy needs it:
//// which nodes are connected now, a notice when one connects or drops, and the
//// node a process lives on.
////
//// FFI confinement (spec §0.2): `gleam_erlang` exposes only the visible nodes,
//// and distribution here is hidden between orchestrators and executors, so it
//// cannot list the nodes this VM is connected to. It has no node-up
//// subscription at all. Each operation is bound straight to a stock OTP
//// function and no Erlang source is added. No operation creates an atom from
//// network input: every node handled here is an atom the VM already holds,
//// because distribution made it when the connection came up.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Selector}
import gleam/list
import gleam/result

// The selector of `erlang:nodes/1`. A nullary constructor compiles to the
// atom of its name in lower case, which is the kind OTP asks for.
type NodeFilter {
  Connected
}

// OTP `erlang:nodes/1`. `nodes(connected)` lists every connected node, hidden
// or not, where `nodes()` lists the visible ones only.
@external(erlang, "erlang", "nodes")
fn nodes_matching(filter: NodeFilter) -> List(Node)

/// The nodes this VM is connected to, hidden ones included. Empty on a VM
/// that is not distributed.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.connected() // -> []
/// ```
pub fn connected() -> List(Node) {
  nodes_matching(Connected)
}

// The option tuple `{node_type, all}` of `net_kernel:monitor_nodes/2`. A
// constructor with one field compiles to a tagged tuple, so `NodeType(All)`
// is exactly that term.
type MonitorOption {
  NodeType(Kinds)
}

type Kinds {
  All
}

// OTP `net_kernel:monitor_nodes/2`. It answers `ok`, or an error term, which
// is read below with a decoder because the success is a bare atom and not a
// Gleam `Result`. Its first argument is the atom `true` or `false`, so the
// parameter is a `Bool` by the function's own definition.
@external(erlang, "net_kernel", "monitor_nodes")
fn monitor_nodes(on: Bool, options: List(MonitorOption)) -> Dynamic

/// Asks the VM to send the calling process a `nodeup` or `nodedown` message
/// for every node, hidden or visible, from now on. `select_changes` is how a
/// process receives them.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = ffi_nodes.watch()
/// ```
pub fn watch() -> Result(Nil, Nil) {
  let answer = decode.run(monitor_nodes(True, [NodeType(All)]), atom.decoder())

  // Inspect the monitor registration result atom to confirm subscription.
  case answer {
    Ok(word) ->
      case atom.to_string(word) {
        "ok" -> Ok(Nil)
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

/// A change in the node set, as `watch` reports it.
pub type Change {
  /// A node connected.
  Joined(node: Node)

  /// A node dropped, or was disconnected.
  Parted(node: Node)

  /// A message of the right tag that did not have the right shape. It is
  /// reported so a receiver can ignore it knowingly.
  Garbled
}

/// Adds the `nodeup` and `nodedown` messages of `watch` to a selector.
///
/// Each message is `{nodeup, Node, Info}` or `{nodedown, Node, Info}`. The
/// decoder reads only the node and ignores the information list, and a
/// message of another shape becomes `Garbled` and not a crash.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.select_changes(process.new_selector(), Changed)
/// ```
pub fn select_changes(
  selector: Selector(message),
  wrap: fn(Change) -> message,
) -> Selector(message) {
  selector
  |> process.select_record(atom.create("nodeup"), 2, fn(event) {
    wrap(read(event, Joined))
  })
  |> process.select_record(atom.create("nodedown"), 2, fn(event) {
    wrap(read(event, Parted))
  })
}

fn read(event: Dynamic, make: fn(Node) -> Change) -> Change {
  decode.run(event, decode.at([1], atom.decoder()))
  |> result.map(fn(name) { make(node_of_atom(name)) })
  |> result.unwrap(Garbled)
}

// `gleam_stdlib:identity/1`. A node is an atom at runtime, and `gleam_erlang`
// converts one to its atom with `node.name` but not back. The atom came from
// the VM's own message, so this makes no atom.
@external(erlang, "gleam_stdlib", "identity")
fn node_of_atom(name: Atom) -> Node

// OTP `erlang:node/1`, the node a process lives on. Total on any pid.
@external(erlang, "erlang", "node")
fn node_of_pid(pid: Pid) -> Node

/// The full name of the node a process lives on, such as `laptop@100.64.0.5`.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.owner_name(process.self()) == ffi_nodes.name(node.self())
/// ```
pub fn owner_name(pid: Pid) -> String {
  name(node_of_pid(pid))
}

// OTP `net_kernel:allow/1`. It answers `ok` or `error`, atoms, and takes only
// atoms, which is why the names are turned into them below.
@external(erlang, "net_kernel", "allow")
fn net_kernel_allow(nodes: List(Atom)) -> Dynamic

// OTP `erlang:is_alive/0`: whether this VM is a distributed node.
@external(erlang, "erlang", "is_alive")
fn is_alive() -> Bool

/// Adds these node names to the allow list of `net_kernel`, which can only
/// grow (protocol-change/086). It does nothing and answers `Ok` on a VM that is
/// not distributed yet, because there is no list to grow, and the caller
/// allows the members once distribution is up.
///
/// This is the one place a node name from a ledger becomes an atom. The names
/// reach it only from entries whose signature verified, that passed the
/// grammar of `distribution.check_node_name`, and that are within the
/// ledger's bound of 10,000 entries: the atom is the member's `node`, and
/// re-upserting a name with a new node is legal, so the number of distinct
/// node atoms is bounded by the entries and not by the 256 names.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.allow(["loom@hub.example"]) // -> Ok(Nil)
/// ```
pub fn allow(names: List(String)) -> Result(Nil, Nil) {
  // Check distributed node availability and whitelist emptiness before modifying kernel rules.
  case is_alive(), names {
    False, _ | _, [] -> Ok(Nil)
    True, _ -> {
      let answer =
        decode.run(
          net_kernel_allow(list.map(names, atom.create)),
          atom.decoder(),
        )

      // Verify that net_kernel accepted the node allowlist configuration.
      case result.map(answer, atom.to_string) {
        Ok("ok") -> Ok(Nil)
        _ -> Error(Nil)
      }
    }
  }
}

// OTP `erlang:disconnect_node/1`, which answers whether a connection ended.
@external(erlang, "erlang", "disconnect_node")
fn disconnect_node(node: Node) -> Bool

/// Ends the connection to a node, as `erlang:disconnect_node/1` does. A node
/// that is not connected is left alone.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.disconnect(node)
/// ```
pub fn disconnect(node: Node) -> Nil {
  let _ = disconnect_node(node)
  Nil
}

/// The full name of a node.
///
/// ## Examples
///
/// ```gleam
/// ffi_nodes.name(node.self()) // -> "nonode@nohost"
/// ```
pub fn name(node: Node) -> String {
  atom.to_string(node.name(node))
}
