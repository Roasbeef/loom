//// What the membership ledger does to this VM's distribution: the pin table
//// the TLS verify callback reads, the allow list, and the connections that
//// stop being allowed (protocol-change/086, sections 6.4 and 6.5).
////
//// `client/ledger_service` decides which entries a node has applied and tells
//// its observers. This module is the observer that turns that into trust. It
//// is a set of functions and owns no process: the observer runs inside the
//// ledger process, so that process is the one owner of the protected table
//// `loom_dist_pins`, the only writer of it, and the one place that
//// disconnects a node for the ledger's sake. Handling the three observations
//// in one process, in order, is what makes the revoke race a matter of
//// ordering and not of timing.
////
//// ## Flow
////
//// 1. `Loaded` is delivered before the ledger process finishes starting, which
////    is before distribution starts. `observer` creates the table and
////    publishes this node's pins, so the table holds its row before the first
////    handshake can need it.
//// 2. `Extended` follows a durable append. The new table is published first
////    (one insert), then the allow list grows, then `stale` names the
////    connections the new table no longer permits and they are disconnected.
//// 3. `Connected` is a node-up. The node is judged against the ledger as it
////    stands now, and disconnected unless it is a linked active member. A
////    handshake that read the old row and finished after a publish ends here.
//// 4. `allow_members` runs once after distribution starts, because the allow
////    list can only be changed on a distributed node and `Loaded` came first.
//// 5. `dialing` gives an orchestrator the executors it keeps reaching for,
////    through the production connect.
////
//// ## What a disconnect is for
////
//// A pin is checked when a handshake happens, so removing a pin ends nothing
//// that is already connected. The disconnect is what ends it. It is by the
//// node name the peer claimed, which the verify callback does not bind to the
//// certificate; 086 section 6.5 records that limit. A renewed member has a new
//// pin, and its connections made with the old certificate are dropped as well:
//// the old certificate may be the reason for the renewal.
////
//// A node whose own entry is revoked is left with the empty table. It refuses
//// every handshake in both directions and drops every connection. Its
//// `net_kernel` keeps running, but nothing arrives over the network to enroll
//// it again: peers have swept it, it dials nobody, and it accepts nobody. The
//// entry that enrolls it again reaches it only through `import` on its own
//// machine, or through a new bundle and a restart.

import client/distribution
import client/distribution_plan.{Executor, Orchestrator}
import client/internal/ffi_distribution
import client/internal/ffi_nodes
import client/ledger_service.{type Dialing, type Observation, type Observer}
import client/membership_ledger.{type Ledger}
import gleam/erlang/node.{type Node}
import gleam/erlang/process
import gleam/list
import gleam/result
import telemetry/field
import telemetry/log.{type Logger}

/// The observer that applies the ledger to distribution for the node named
/// `local`. It publishes at `Loaded` and `Extended`, grows the allow list at
/// `Extended`, and disconnects at `Extended` and `Connected`.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.configuration(store, ledger, verifier, [ledger_trust.observer(local, logger)], logger)
/// ```
pub fn observer(local: String, logger: Logger) -> Observer {
  fn(observation: Observation) { observe(local, logger, observation) }
}

fn observe(local: String, logger: Logger, observation: Observation) -> Nil {
  case observation {
    ledger_service.Loaded(ledger:) -> publish(ledger, local)

    // The table is published before anything else, so a handshake that starts
    // from here on reads the new one. The disconnects follow, and a handshake
    // that read the old row and is still in flight is caught at its node-up.
    ledger_service.Extended(previous:, ledger:, ..) -> {
      publish(ledger, local)
      let _ = ffi_nodes.allow(member_nodes(ledger, local))
      note_self_revoked(logger, previous, ledger, local)
      disconnect(logger, "entry", stale(previous, ledger, local, connected()))
    }

    // The ledger is the one the node holds when it handles the node-up. The
    // node-up message is behind any publish in this process's mailbox, so the
    // ledger is at least as new as the table the handshake could have read.
    ledger_service.Connected(node:, ledger:) ->
      case membership_ledger.lookup_node(table_of(ledger, local), node) {
        Ok(_) -> Nil
        Error(Nil) -> disconnect(logger, "node_up", [node])
      }
  }
}

/// The most pins a node's table can hold: every active member but the node
/// itself. The ledger's fold allows at most `membership_ledger.max_active`
/// active members, so no entry makes the table larger, and `publish` also stops
/// at this many. The live verify state is the atom `live`, so the options file
/// has no bound of its own, and the allow list grows only by the names of
/// members enrolled, at most `membership_ledger.max_names` over the life of a
/// ledger. The 32-peer bound of `[[distribution.peers]]` does not apply in
/// ledger mode.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_trust.max_peers() == 63
/// ```
pub fn max_peers() -> Int {
  membership_ledger.max_active - 1
}

/// The rows of the table this node publishes: each linked member's pin, paired
/// with the node name it must present. A node that is not an active member has
/// no rows, which refuses every peer.
///
/// ## Examples
///
/// ```gleam
/// ledger_trust.pairs(ledger, "loom@hub.example") // -> [#(pin, "loom@laptop.example")]
/// ```
pub fn pairs(ledger: Ledger, local: String) -> List(#(BitArray, String)) {
  let table = table_of(ledger, local)
  membership_ledger.peers(table)
  |> list.filter_map(fn(peer) {
    membership_ledger.lookup_node(table, peer.node)
    |> result.map(fn(pin) { #(pin, peer.node) })
  })
  |> list.take(max_peers())
}

/// Publishes this node's table, so the next handshake reads it. A node that is
/// not an active member publishes the empty table.
///
/// ## Examples
///
/// ```gleam
/// ledger_trust.publish(ledger, "loom@hub.example")
/// ```
pub fn publish(ledger: Ledger, local: String) -> Nil {
  ffi_distribution.publish_pins(pairs(ledger, local))
}

/// Adds the members this node is linked to to the allow list, once
/// distribution is up. The list only grows (086 section 6.4), so a revoked
/// member stays on it, and the pin is what refuses that member.
///
/// ## Examples
///
/// ```gleam
/// ledger_trust.allow_members(ledger, "loom@hub.example")
/// ```
pub fn allow_members(ledger: Ledger, local: String) -> Result(Nil, Nil) {
  ffi_nodes.allow(member_nodes(ledger, local))
}

fn member_nodes(ledger: Ledger, local: String) -> List(String) {
  membership_ledger.peers(table_of(ledger, local))
  |> list.map(fn(peer) { peer.node })
}

fn table_of(ledger: Ledger, local: String) -> membership_ledger.PinTable {
  membership_ledger.node_table(ledger, local)
}

/// The connected nodes that an entry stops permitting: those the new table no
/// longer lists, and those whose pin the entry replaced. A node that is in
/// both tables with the same pin is left connected.
///
/// ## Examples
///
/// ```gleam
/// ledger_trust.stale(before, after, "loom@hub.example", ["loom@laptop.example"])
/// // -> ["loom@laptop.example"] when the entry revoked the laptop
/// ```
pub fn stale(
  previous: Ledger,
  ledger: Ledger,
  local: String,
  connected: List(String),
) -> List(String) {
  let before = table_of(previous, local)
  let after = table_of(ledger, local)
  list.filter(connected, fn(name) {
    case membership_ledger.lookup_node(after, name) {
      Error(Nil) -> True
      Ok(pin) ->
        case membership_ledger.lookup_node(before, name) {
          Ok(held) -> held != pin
          Error(Nil) -> False
        }
    }
  })
}

fn connected() -> List(String) {
  list.map(ffi_nodes.connected(), ffi_nodes.name)
}

// Ends the connections to these nodes. Only nodes that are connected are
// looked at, so no name from the ledger becomes an atom here.
fn disconnect(logger: Logger, cause: String, names: List(String)) -> Nil {
  ffi_nodes.connected()
  |> list.filter(fn(connected: Node) {
    list.contains(names, ffi_nodes.name(connected))
  })
  |> list.each(fn(connected) {
    log.info(logger, "ledger.disconnected", [
      field.text("node", ffi_nodes.name(connected)),
      field.text("cause", cause),
    ])
    ffi_nodes.disconnect(connected)
  })
}

fn note_self_revoked(
  logger: Logger,
  previous: Ledger,
  ledger: Ledger,
  local: String,
) -> Nil {
  case
    membership_ledger.member_at(previous, local),
    membership_ledger.member_at(ledger, local)
  {
    Ok(_), Error(Nil) ->
      log.warn(logger, "ledger.self_revoked", [field.text("node", local)])
    _, _ -> Nil
  }
}

/// The executors a node keeps trying to reach: those it is linked to when it
/// is an orchestrator, and none when it is an executor or not a member. Only
/// orchestrators dial (protocol-change/078), and only executors are dialed this
/// way, because a laptop connects out when it wakes.
///
/// ## Examples
///
/// ```gleam
/// ledger_trust.executors_to_dial(ledger, "loom@hub.example")
/// // -> ["loom@box.example"]
/// ```
pub fn executors_to_dial(ledger: Ledger, local: String) -> List(String) {
  case membership_ledger.member_at(ledger, local) {
    Ok(own) if own.role == Orchestrator ->
      membership_ledger.peers(table_of(ledger, local))
      |> list.filter(fn(peer) { peer.role == Executor })
      |> list.map(fn(peer) { peer.node })
    _ -> []
  }
}

/// The dialing of a node with the given membership: the executors from
/// `executors_to_dial`, attempted through `distribution.connect` on the
/// schedule of `ledger_service`'s defaults.
///
/// Each attempt runs in a process of its own and is bounded by the deadline
/// inside `distribution.connect`, so a handshake to a machine that is off does
/// not hold up the ledger process. The outcome is not reported: a connection
/// that comes up is a node-up, and a refusal is retried at the next backoff.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.enable_dialing(service, ledger_trust.dialing(membership, local))
/// ```
pub fn dialing(membership: distribution.Membership, local: String) -> Dialing {
  ledger_service.Dialing(
    wanted: executors_to_dial(_, local),
    dial: attempt(membership, _),
    every_ms: ledger_service.default_dial_first_ms,
    first_ms: ledger_service.default_dial_first_ms,
    ceiling_ms: ledger_service.default_dial_ceiling_ms,
  )
}

fn attempt(membership: distribution.Membership, name: String) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      case distribution.peer(membership, name) {
        Ok(peer) -> {
          let _ = distribution.connect(peer, 5000)
          Nil
        }
        Error(_) -> Nil
      }
    })
  Nil
}
