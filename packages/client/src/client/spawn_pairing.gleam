//// Which directions of spawning are configured between this machine and each
//// peer orchestrator, for `deployment.status` (issue #1137, "Spawning is
//// one-directional by default").
////
//// Spawning is decided by two tables that live on two machines. A model on one
//// orchestrator, the laptop, starts a child on another, the box, when the laptop
//// holds an `[orchestrators.box]` row for it and the box holds a
//// `[spawners.laptop]` table that admits it. Pairing writes the first row of
//// each direction a person asked for and no more, so a deployment paired from
//// the laptop can spawn from the laptop onto the box and not the reverse, and
//// the reverse needs a table written by hand on the other machine and a restart.
//// Nothing in a status reply said so, and a spawn in the missing direction
//// failed with a refusal that read as a fault.
////
//// This module only reports. It reads the rows and tables this daemon holds,
//// matches them by the peer's pinned distribution node, and says for each peer
//// whether this machine can spawn on it, whether it can spawn here and with
//// what `seed`, and, when exactly one direction exists, which table the operator
//// would add on this machine for the other. It writes nothing and changes who
//// may spawn where; that stays a decision of the owner of each machine.
////
//// ## What a direction means here
////
//// Only this machine's own configuration is visible, so a statement is about it
//// and not about the peer. "This machine can spawn on the peer" is true when an
//// `[orchestrators.<peer>]` row names the peer's node here. Whether the peer
//// admits the spawn is decided by its own `[spawners.<this machine>]`, which this
//// machine cannot read, and the peer's `loom deployment status` shows it from its
//// side. "The peer can spawn here" is true when a `[spawners.<peer>]` table here
//// names the peer's node, and the table's `seed` is stated with it.
////
//// A peer is found by its node and not by the key of its table, because the two
//// tables are written by two people and the keys may differ. A spawner whose node
//// no orchestrator row names is listed as well, since a roaming laptop may spawn
//// here without a row for it (`client/spawners`).
////
//// ## Flow
////
//// `pairings` → `missing` → `to_json`
////
//// 1. `pairings` joins the orchestrator rows with the spawner tables by node and
////    keeps at most 32 of them.
//// 2. `missing` names the table that would complete a pairing with one direction.
//// 3. `to_json` renders them as the member of the reply that carries them.

import client/orchestrators.{type Orchestrator}
import client/spawners.{type Seed, type Spawner}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}

/// The most pairings a reply lists. The reply is limited to one frame, and this
/// member is added after the frame is measured, so its size is bounded here.
pub const limit = 32

/// Whether this machine can spawn on the peer.
pub type Outbound {
  /// An `[orchestrators.<peer>]` row names the peer here.
  CanSpawnThere

  /// No row names the peer, so this machine has nowhere to send a spawn to it.
  CannotSpawnThere
}

/// Whether the peer can spawn on this machine.
pub type Inbound {
  /// A `[spawners.<peer>]` table names the peer here, and its `seed` is the
  /// setting.
  CanSpawnHere(seed: Seed)

  /// No spawner table names the peer, so this machine refuses its spawns.
  CannotSpawnHere
}

/// One peer orchestrator and the directions of spawning configured with it.
pub type Pairing {
  Pairing(
    /// The key of the peer's `[orchestrators.<name>]` row here, or of its
    /// `[spawners.<name>]` table when no row names the peer.
    name: String,
    /// The peer's pinned distribution node, which joins the two tables.
    node: String,
    /// Whether this machine can spawn on the peer.
    there: Outbound,
    /// Whether the peer can spawn on this machine.
    here: Inbound,
  )
}

/// Joins this daemon's orchestrator rows with its spawner tables by node: one
/// pairing for each row, in the order of the rows, then one for each spawner no
/// row names, in the order of the tables. At most `limit` are kept.
///
/// ## Examples
///
/// ```gleam
/// let box = orchestrators.plain("box", "box@10.0.0.2")
/// assert spawn_pairing.pairings([box], [])
///   == [
///     spawn_pairing.Pairing(
///       "box",
///       "box@10.0.0.2",
///       spawn_pairing.CanSpawnThere,
///       spawn_pairing.CannotSpawnHere,
///     ),
///   ]
/// ```
pub fn pairings(
  rows: List(Orchestrator),
  tables: List(Spawner),
) -> List(Pairing) {
  let from_rows =
    list.map(rows, fn(row) {
      Pairing(
        name: row.name,
        node: row.node,
        there: CanSpawnThere,
        here: admitted(tables, row.node),
      )
    })
  let from_tables =
    list.filter_map(tables, fn(table) {
      case list.any(rows, fn(row) { row.node == table.node }) {
        True -> Error(Nil)
        False ->
          Ok(Pairing(
            name: table.name,
            node: table.node,
            there: CannotSpawnThere,
            here: CanSpawnHere(table.seed),
          ))
      }
    })
  list.take(list.append(from_rows, from_tables), limit)
}

/// What this machine's spawner tables say of one peer node.
fn admitted(tables: List(Spawner), node: String) -> Inbound {
  case spawners.by_node(tables, node) {
    Ok(table) -> CanSpawnHere(table.seed)
    Error(Nil) -> CannotSpawnHere
  }
}

/// The table the operator would add on this machine to complete a pairing that
/// has one direction, as it is written in the file: `[spawners.<name>]` when the
/// peer cannot spawn here, `[orchestrators.<name>]` when this machine cannot
/// spawn on the peer. A pairing with both directions, which needs nothing, is
/// `None`. The name is the key the pairing already carries, which the operator
/// may choose differently.
///
/// ## Examples
///
/// ```gleam
/// let one_way =
///   spawn_pairing.Pairing(
///     "box",
///     "box@10.0.0.2",
///     spawn_pairing.CanSpawnThere,
///     spawn_pairing.CannotSpawnHere,
///   )
/// assert spawn_pairing.missing(one_way) == Some("[spawners.box]")
/// ```
pub fn missing(pairing: Pairing) -> Option(String) {
  case pairing.there, pairing.here {
    CanSpawnThere, CannotSpawnHere -> Some("[spawners." <> pairing.name <> "]")
    CannotSpawnThere, CanSpawnHere(..) ->
      Some("[orchestrators." <> pairing.name <> "]")
    CanSpawnThere, CanSpawnHere(..) | CannotSpawnThere, CannotSpawnHere -> None
  }
}

/// The wire word for a `seed` setting.
///
/// ## Examples
///
/// ```gleam
/// assert spawn_pairing.seed_word(spawners.NoSeed) == "none"
/// ```
pub fn seed_word(seed: Seed) -> String {
  case seed {
    spawners.NoSeed -> "none"
    spawners.WorkspaceSeed -> "workspace"
  }
}

/// The `spawning` member of a whole-deployment reply: an array with one object
/// for each pairing. `to_peer` says this machine can spawn on the peer and
/// `from_peer` that the peer can spawn here. `seed` is present with `from_peer`
/// and carries `none` or `workspace`. `add` is present when only one direction
/// exists and holds the table that would complete it, in the form
/// `missing` gives.
///
/// ## Examples
///
/// ```gleam
/// assert spawn_pairing.to_json([]) == json.Array([])
/// ```
pub fn to_json(found: List(Pairing)) -> JsonValue {
  json.Array(list.map(found, entry))
}

/// One pairing as an object. The members that state only what is present are
/// left out when it is not, which is how a client reads the other direction.
fn entry(pairing: Pairing) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("name", json.String(pairing.name)),
        #("node", json.String(pairing.node)),
        #("to_peer", json.Bool(pairing.there == CanSpawnThere)),
        #("from_peer", json.Bool(pairing.here != CannotSpawnHere)),
      ],
      case pairing.here {
        CanSpawnHere(seed) -> [#("seed", json.String(seed_word(seed)))]
        CannotSpawnHere -> []
      },
      case missing(pairing) {
        Some(table) -> [#("add", json.String(table))]
        None -> []
      },
    ]),
  )
}
