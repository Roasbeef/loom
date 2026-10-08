//// Test-side FFI for the probe emulator in `support/remote_probe`: the few
//// OTP functions a Gleam role needs and `gleam_erlang` does not wrap.
////
//// The probe is a third distribution member that the two shipped daemons
//// list as a peer, so a test can ask a daemon what it is connected to. A
//// daemon dials nobody on its own yet, so nothing else can observe
//// membership from outside its VM. Every function here is used only inside
//// that throwaway emulator, never in the test VM and never in production.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/node.{type Node}
import gleam/list

/// Asks `origin` to open a hidden connection to `target` and reports whether
/// it did, by running `net_kernel:hidden_connect_node/1` on `origin` with
/// `erpc:call/5`. This is the orchestrator dialling the executor with the
/// orchestrator's own certificate and pins, which is the connection a later
/// slice makes itself. `erpc` is the only way to run code on another node.
@external(erlang, "erpc", "call")
fn erpc_dial(
  origin: Node,
  module: Atom,
  function: Atom,
  arguments: List(Node),
  timeout_ms: Int,
) -> Bool

@external(erlang, "erpc", "call")
fn erpc_nodes(
  origin: Node,
  module: Atom,
  function: Atom,
  arguments: List(Atom),
  timeout_ms: Int,
) -> List(Node)

/// Whether `origin` managed to connect to `target`. A refused certificate or
/// a wrong pin on either side is `False`; an unreachable `origin` raises.
pub fn dial(origin: Node, target: Node, within_ms: Int) -> Bool {
  erpc_dial(
    origin,
    atom.create("net_kernel"),
    atom.create("hidden_connect_node"),
    [target],
    within_ms,
  )
}

/// The hidden nodes `origin` is connected to right now, by running
/// `erlang:nodes(hidden)` on it.
pub fn hidden_nodes(origin: Node, within_ms: Int) -> List(Node) {
  erpc_nodes(
    origin,
    atom.create("erlang"),
    atom.create("nodes"),
    [atom.create("hidden")],
    within_ms,
  )
}

/// The directories on the test emulator's code path, which the probe
/// emulator needs to load the same compiled modules.
@external(erlang, "code", "get_path")
fn code_path() -> List(Charlist)

@external(erlang, "filename", "absname")
fn absolute(path: String) -> String

/// The code path as absolute strings. The test emulator's path holds relative
/// entries, and the probe is started in a different directory, so each entry
/// is resolved against the directory the test emulator runs in.
pub fn code_directories() -> List(String) {
  list.map(code_path(), fn(path) { absolute(charlist.to_string(path)) })
}

/// Ends the emulator with `status` after flushing standard output, so the
/// parent that reads the probe's verdict sees every line.
@external(erlang, "erlang", "halt")
pub fn halt(status: Int) -> a
