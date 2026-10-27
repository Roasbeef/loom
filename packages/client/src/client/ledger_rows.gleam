//// The `[executors.<name>]` and `[orchestrators.<name>]` rows that a node in
//// ledger mode gets from the membership ledger, and how they combine with the
//// rows its operator wrote (protocol-change/086, phase 2, and section 12 of
//// the design note).
////
//// An orchestrator used to need a hand-written row for every machine it places
//// sessions on or asks about sessions. In ledger mode the ledger already says
//// which machines exist, what each is for, and which of them this node is linked
//// to, so this module turns that into rows. Enrolling an executor then makes it
//// nameable in `sessions.create` with no edit to the orchestrator's file, and a
//// revoke takes the row away with no restart.
////
//// ## What is derived and what is not
////
//// The ledger carries facts that must be the same on every node: a member's
//// name, its node, its role, its directory standing and its links. A row derives
//// from exactly those. The rest of a row is one daemon's own policy, and the
//// ledger does not carry it: an orchestrator's control `address`, an executor's
//// declared `platform`, `enforcement` and `toolchains`, and which executors sit
//// in which pool. A derived row therefore declares nothing and has no address.
//// A pool that requires a platform skips it, because an executor that declared
//// nothing cannot satisfy a requirement (`client/pools`), which is why a pool
//// still takes one edit to the file. Workspaces are not in the ledger either.
//// The executor registers them, and the orchestrator names one when it creates a
//// session.
////
//// ## Which members become rows
////
//// Only an orchestrator uses executors and asks other orchestrators about
//// sessions, so a node that is not an active orchestrator derives nothing. For an
//// orchestrator, the rows are the members of its pin table, which are the members
//// it is linked to: executors become `[executors.<name>]` rows and orchestrators
//// become `[orchestrators.<name>]` rows. The name is the ledger's name for the
//// member, and the grammar of both tables is the grammar the ledger enforces on a
//// member's name.
////
//// When the orchestrator is itself a member of the session directory, an
//// orchestrator row is derived only for a member that is in the directory too.
//// The rule of protocol-change/083 is that every `[orchestrators.<name>]` node of
//// a member daemon is itself a member, so a laptop that is not in the directory
//// cannot be listed beside one that is.
////
//// ## Combining with written rows
////
//// A row the operator wrote claims its name and its node. A derived row is
//// dropped if a written row has the same name or names the same node, and the
//// written row is the one that stays whole. The same-name rule is the design
//// note's: an explicit row overrides the derived one and adds the address, the
//// declarations and the pool membership. The same-node rule is this module's. An
//// operator who names a machine `box` in the file while the ledger enrolled it as
//// `devbox` chose a name for it, and a second name for one machine would put it
//// twice in every listing and break the rule that an orchestrator's node is
//// unique (`client/orchestrators`). The result is sorted by name, as the tables
//// are when they are parsed.
////
//// ## Flow
////
//// `executors_of` and `orchestrators_of` → `peers_of` → `combine`
////
//// 1. `executors_of` and `orchestrators_of` take the ledger the node holds,
////    its own node name and the written rows.
//// 2. `peers_of` finds the members the node is linked to, if it is an active
////    orchestrator.
//// 3. `combine` drops the derived rows that a written row claims.
//// 4. `executor_roster` and `orchestrator_roster` wrap the two in a
////    `client/roster` that asks the ledger process each time it is read.

import client/distribution_plan.{Executor, Orchestrator}
import client/executors.{type Executor as ExecutorRow}
import client/ledger_service.{type Service}
import client/membership_entry.{NotInDirectory}
import client/membership_ledger.{type Ledger, type Peer}
import client/orchestrators.{type Orchestrator as OrchestratorRow}
import client/roster.{type Roster}
import gleam/list
import gleam/string

/// How long a read of a roster waits for the ledger process. The process
/// answers in microseconds unless it is applying an entry, so a wait this long
/// means it is wedged, and the roster falls back to the rows that were written.
const read_ms = 2000

/// The executors a node uses: the rows its operator wrote, and a row for each
/// executor member the node is linked to that no written row claims.
///
/// ## Examples
///
/// ```gleam
/// ledger_rows.executors_of(ledger, "loom@hub.example", [])
/// // -> [Executor(name: "box", node: "loom@box.example", ..)]
/// ```
pub fn executors_of(
  ledger: Ledger,
  local: String,
  written: List(ExecutorRow),
) -> List(ExecutorRow) {
  peers_of(ledger, local)
  |> list.filter(fn(peer) { peer.role == Executor })
  |> list.map(fn(peer) { executors.plain(peer.name, peer.node) })
  |> combine(written, _, fn(row) { #(row.name, row.node) })
}

/// The orchestrators a node asks and may move sessions to: the rows its
/// operator wrote, and a row for each orchestrator member the node is linked to
/// that no written row claims. A node in the session directory lists only the
/// orchestrators that are in it too.
///
/// ## Examples
///
/// ```gleam
/// ledger_rows.orchestrators_of(ledger, "loom@hub.example", [])
/// // -> [Orchestrator(name: "laptop", node: "loom@laptop.example", address: None)]
/// ```
pub fn orchestrators_of(
  ledger: Ledger,
  local: String,
  written: List(OrchestratorRow),
) -> List(OrchestratorRow) {
  // Determine if the local node is active in the directory.
  let in_directory = case membership_ledger.member_at(ledger, local) {
    Ok(own) -> own.directory != NotInDirectory
    Error(Nil) -> False
  }

  peers_of(ledger, local)
  |> list.filter(fn(peer) {
    peer.role == Orchestrator
    && { !in_directory || peer.directory != NotInDirectory }
  })
  |> list.map(fn(peer) { orchestrators.plain(peer.name, peer.node) })
  |> combine(written, _, fn(row) { #(row.name, row.node) })
}

/// The executors a node uses, read from the ledger process each time the roster
/// is read. A ledger process that does not answer leaves the written rows and
/// nothing derived, which fails closed: an executor that cannot be confirmed is
/// not offered.
///
/// ## Examples
///
/// ```gleam
/// let roster = ledger_rows.executor_roster(service, "loom@hub.example", written)
/// roster.rows(roster)
/// ```
pub fn executor_roster(
  service: Service,
  local: String,
  written: List(ExecutorRow),
) -> Roster(ExecutorRow) {
  roster.reading(fn() {
    case ledger_service.status(service, read_ms) {
      Ok(status) -> executors_of(status.ledger, local, written)
      Error(ledger_service.Unreachable) -> written
    }
  })
}

/// The orchestrators a node asks, read from the ledger process each time the
/// roster is read, with the same fallback as `executor_roster`.
///
/// ## Examples
///
/// ```gleam
/// let roster = ledger_rows.orchestrator_roster(service, "loom@hub.example", written)
/// roster.rows(roster)
/// ```
pub fn orchestrator_roster(
  service: Service,
  local: String,
  written: List(OrchestratorRow),
) -> Roster(OrchestratorRow) {
  roster.reading(fn() {
    case ledger_service.status(service, read_ms) {
      Ok(status) -> orchestrators_of(status.ledger, local, written)
      Error(ledger_service.Unreachable) -> written
    }
  })
}

// The members a node is linked to, when it is an active orchestrator. An
// executor does not place sessions or ask about them, and a node the ledger does
// not list as a member is not trusted by anyone, so neither derives a row.

/// Derives peer connections for a local orchestrator from the membership ledger.
fn peers_of(ledger: Ledger, local: String) -> List(Peer) {
  case membership_ledger.member_at(ledger, local) {
    Ok(own) if own.role == Orchestrator ->
      membership_ledger.node_table(ledger, local) |> membership_ledger.peers
    Ok(_) | Error(Nil) -> []
  }
}

// The written rows, then the derived rows that no written row claims, sorted by
// name. `claim` gives a row's name and node, the two things a written row can
// claim.

/// Merges written rows with unclaimed derived rows and sorts the combined result by name.
fn combine(
  written: List(row),
  derived: List(row),
  claim: fn(row) -> #(String, String),
) -> List(row) {
  let claimed = list.map(written, claim)
  let names = list.map(claimed, fn(pair) { pair.0 })
  let nodes = list.map(claimed, fn(pair) { pair.1 })
  let free =
    list.filter(derived, fn(row) {
      let #(name, node) = claim(row)
      !list.contains(names, name) && !list.contains(nodes, node)
    })
  list.append(written, free)
  |> list.sort(fn(a, b) { string.compare(claim(a).0, claim(b).0) })
}
