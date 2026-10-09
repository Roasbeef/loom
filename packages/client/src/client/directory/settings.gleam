//// The `[directory]` table: whether this daemon is a member of the session
//// directory's Khepri cluster, and who the members are (protocol-change/081).
////
//// A deployment that writes `[directory]` on its daemons has one Khepri store
//// holding the owner record of every remote session. `members` lists the
//// cluster's voting members by distribution node name: the orchestrators and
//// the executors. A daemon without the table is not a member, and everything
//// about it stays as it was before the directory existed.
////
//// The checks here are the ones a cluster cannot work without. Every member
//// must be a pinned peer, because any member may become Raft's leader and the
//// leader must reach every follower. The daemon's own node must be listed,
//// because a member that does not count itself would join a cluster it does not
//// expect. And every orchestrator this daemon lists must be a member, so that a
//// move never runs between a daemon that decides by the record and one that
//// decides by its catalogue rows.

import client/distribution
import client/orchestrators.{type Orchestrator}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// The fewest members a directory may have. With fewer than three, losing one
/// member stops every write.
pub const minimum_members = 3

/// The most members a directory may have. Every write waits for a majority,
/// and every member pins every other.
pub const maximum_members = 7

/// A validated `[directory]` table.
pub type Settings {
  Settings(
    /// Every member's node name, this daemon's included, in the order the file
    /// lists them. The order means nothing to the cluster.
    members: List(String),
  )
}

/// Reads the `[directory]` table of a configuration document, or `None` when
/// the document has none.
///
/// The table needs `[distribution]`. `members` is a list of three to seven
/// distinct node names, one of them this daemon's own `[distribution] node`
/// and every other one a `[[distribution.peers]]` node. Every
/// `[orchestrators.<name>]` node must be a member. Each refusal names the key.
///
/// ## Examples
///
/// ```gleam
/// assert settings.from_document(dict.new()) == Ok(None)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Option(Settings), String) {
  case dict.get(document, "directory") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(fields)) -> table(fields, document) |> result.map(Some)
    Ok(_) -> Error("directory must be a [directory] table")
  }
}

/// Reads the table from configuration text, for callers that hold no parsed
/// document.
///
/// ## Examples
///
/// ```gleam
/// assert settings.parse("") == Ok(None)
/// ```
pub fn parse(text: String) -> Result(Option(Settings), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// The membership `client/distribution` starts a node with: a `Member` when the
/// table is present, `NotMember` otherwise.
///
/// ## Examples
///
/// ```gleam
/// assert settings.cluster(None) == distribution.NotMember
/// ```
pub fn cluster(settings: Option(Settings)) -> distribution.Cluster {
  case settings {
    None -> distribution.NotMember
    Some(Settings(members:)) -> distribution.Member(members:)
  }
}

/// Whether the member count is even. An even count adds a member without
/// letting the cluster survive one more failure, so the daemon warns about it.
///
/// ## Examples
///
/// ```gleam
/// assert settings.even(Settings(["a@h.x", "b@h.x", "c@h.x", "d@h.x"]))
/// ```
pub fn even(settings: Settings) -> Bool {
  int.is_even(list.length(settings.members))
}

/// The members other than this node.
///
/// ## Examples
///
/// ```gleam
/// assert settings.others(Settings(["a@h.x", "b@h.x", "c@h.x"]), "a@h.x")
///   == ["b@h.x", "c@h.x"]
/// ```
pub fn others(settings: Settings, local: String) -> List(String) {
  list.filter(settings.members, fn(member) { member != local })
}

fn table(
  fields: Dict(String, tom.Toml),
  document: Dict(String, tom.Toml),
) -> Result(Settings, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["members"],
    "[directory]",
  ))
  use found <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { "directory needs " <> reason }),
  )
  use config <- result.try(case found {
    Some(config) -> Ok(config)
    None -> Error("directory needs a [distribution] table naming its members")
  })
  use members <- result.try(member_names(fields))
  use Nil <- result.try(counted(members))
  use Nil <- result.try(distinct(members))
  let local = distribution.local_node(config)
  use Nil <- result.try(case list.contains(members, local) {
    True -> Ok(Nil)
    False ->
      Error("directory.members must include this daemon's own node " <> local)
  })
  let peers = distribution.peer_nodes(config)
  use Nil <- result.try(
    list.try_each(members, fn(member) {
      case member == local || list.contains(peers, member) {
        True -> Ok(Nil)
        False ->
          Error(
            "directory.members names "
            <> member
            <> ", which is not a node in [[distribution.peers]]",
          )
      }
    }),
  )
  use listed <- result.try(orchestrators.from_document(document))
  use Nil <- result.map(orchestrators_are_members(listed, members))
  Settings(members:)
}

fn member_names(
  fields: Dict(String, tom.Toml),
) -> Result(List(String), String) {
  case dict.get(fields, "members") {
    Error(Nil) -> Error("directory.members is required")
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(name) ->
            distribution.check_node_name("directory.members", name)
            |> result.replace(name)
          _ -> Error("directory.members must be a list of node names")
        }
      })
    Ok(_) -> Error("directory.members must be a list of node names")
  }
}

fn counted(members: List(String)) -> Result(Nil, String) {
  let count = list.length(members)
  case count >= minimum_members && count <= maximum_members {
    True -> Ok(Nil)
    False ->
      Error(
        "directory.members must list between "
        <> int.to_string(minimum_members)
        <> " and "
        <> int.to_string(maximum_members)
        <> " nodes, not "
        <> int.to_string(count),
      )
  }
}

fn distinct(members: List(String)) -> Result(Nil, String) {
  case members {
    [] -> Ok(Nil)
    [first, ..rest] ->
      case list.contains(rest, first) {
        True -> Error("directory.members lists " <> first <> " twice")
        False -> distinct(rest)
      }
  }
}

// A daemon in a directory moves sessions by the record, and one outside moves
// them by its catalogue rows; a move between the two would have no single rule.
fn orchestrators_are_members(
  listed: List(Orchestrator),
  members: List(String),
) -> Result(Nil, String) {
  list.try_each(listed, fn(orchestrator) {
    case list.contains(members, orchestrator.node) {
      True -> Ok(Nil)
      False ->
        Error(
          "orchestrators."
          <> orchestrator.name
          <> ".node "
          <> orchestrator.node
          <> " must be one of directory.members",
        )
    }
  })
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}
