//// Which directions of spawning a status reply states for each peer
//// (`client/spawn_pairing`, issue #1137). The spawner tables are parsed from
//// text, as the daemon reads them, and the orchestrator rows are built the way
//// the configuration builds them.

import client/orchestrators.{type Orchestrator}
import client/spawn_pairing.{
  CanSpawnHere, CanSpawnThere, CannotSpawnHere, CannotSpawnThere, Pairing,
}
import client/spawners.{type Spawner, NoSeed, WorkspaceSeed}
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}

// The head of a configuration that pins the peers the tables below name.
const head =
  "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"desk@100.64.0.6\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"

[profiles.review.roles]
main = [\"fast\"]
"

// One `[spawners.<name>]` table, with the seed line as it is written.
fn table(name: String, node: String, seed: String) -> String {
  "\n[spawners."
  <> name
  <> "]\nnode = \""
  <> node
  <> "\"\nprofile = \"review\"\ndirectory = \"/srv/loom/work\"\n"
  <> seed
}

fn parsed(text: String) -> List(Spawner) {
  let assert Ok(found) = spawners.parse(head <> text)
    as "the spawner tables parse"
  found
}

fn laptop() -> Orchestrator {
  orchestrators.plain("laptop", "laptop@100.64.0.5")
}

fn desk() -> Orchestrator {
  orchestrators.plain("desk", "desk@100.64.0.6")
}

pub fn a_peer_with_a_row_and_a_table_is_spawnable_in_both_directions_test() {
  let tables =
    parsed(table("laptop", "laptop@100.64.0.5", "seed = \"workspace\"\n"))
  let found = spawn_pairing.pairings([laptop()], tables)
  assert found
    == [
      Pairing(
        "laptop",
        "laptop@100.64.0.5",
        CanSpawnThere,
        CanSpawnHere(WorkspaceSeed),
      ),
    ]
  let assert [both] = found
  assert spawn_pairing.missing(both) == None
  assert spawn_pairing.to_json(found)
    == json.Array([
      json.Object([
        #("name", json.String("laptop")),
        #("node", json.String("laptop@100.64.0.5")),
        #("to_peer", json.Bool(True)),
        #("from_peer", json.Bool(True)),
        #("seed", json.String("workspace")),
      ]),
    ])
}

pub fn a_row_without_a_table_says_which_table_to_add_here_test() {
  let found = spawn_pairing.pairings([desk()], [])
  assert found
    == [Pairing("desk", "desk@100.64.0.6", CanSpawnThere, CannotSpawnHere)]
  let assert [one_way] = found
  assert spawn_pairing.missing(one_way) == Some("[spawners.desk]")
  assert spawn_pairing.to_json(found)
    == json.Array([
      json.Object([
        #("name", json.String("desk")),
        #("node", json.String("desk@100.64.0.6")),
        #("to_peer", json.Bool(True)),
        #("from_peer", json.Bool(False)),
        #("add", json.String("[spawners.desk]")),
      ]),
    ])
}

pub fn a_table_without_a_row_is_listed_and_names_the_row_to_add_test() {
  let tables = parsed(table("laptop", "laptop@100.64.0.5", ""))
  let found = spawn_pairing.pairings([], tables)
  assert found
    == [
      Pairing(
        "laptop",
        "laptop@100.64.0.5",
        CannotSpawnThere,
        CanSpawnHere(NoSeed),
      ),
    ]
  let assert [one_way] = found
  assert spawn_pairing.missing(one_way) == Some("[orchestrators.laptop]")
  assert spawn_pairing.to_json(found)
    == json.Array([
      json.Object([
        #("name", json.String("laptop")),
        #("node", json.String("laptop@100.64.0.5")),
        #("to_peer", json.Bool(False)),
        #("from_peer", json.Bool(True)),
        #("seed", json.String("none")),
        #("add", json.String("[orchestrators.laptop]")),
      ]),
    ])
}

pub fn a_deployment_with_neither_lists_nothing_test() {
  assert spawn_pairing.pairings([], []) == []
  assert spawn_pairing.to_json([]) == json.Array([])
}

pub fn the_tables_and_rows_join_by_node_and_not_by_key_test() {
  // The peer's table is keyed differently from its row, as two people may
  // write them, and is still the same peer.
  let tables = parsed(table("the-laptop", "laptop@100.64.0.5", ""))
  assert spawn_pairing.pairings([laptop()], tables)
    == [
      Pairing(
        "laptop",
        "laptop@100.64.0.5",
        CanSpawnThere,
        CanSpawnHere(NoSeed),
      ),
    ]
}

pub fn rows_come_first_then_the_tables_no_row_names_test() {
  let tables =
    parsed(
      table("desk", "desk@100.64.0.6", "seed = \"workspace\"\n")
      <> table("laptop", "laptop@100.64.0.5", ""),
    )
  let found = spawn_pairing.pairings([laptop()], tables)
  assert list.map(found, fn(each) { each.name }) == ["laptop", "desk"]
  assert list.map(found, fn(each) { each.there })
    == [CanSpawnThere, CannotSpawnThere]
  assert list.map(found, fn(each) { each.here })
    == [CanSpawnHere(NoSeed), CanSpawnHere(WorkspaceSeed)]
}

pub fn only_the_limit_is_listed_test() {
  let rows =
    list.index_map(list.repeat(Nil, spawn_pairing.limit + 5), fn(_each, n) {
      orchestrators.plain(
        "peer" <> int.to_string(n),
        "peer" <> int.to_string(n) <> "@100.64.1.1",
      )
    })
  assert list.length(spawn_pairing.pairings(rows, [])) == spawn_pairing.limit
}
