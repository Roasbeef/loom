//// `loom directory status`: the session directory's cluster as the daemon you
//// are connected to sees it, as text (protocol-change/083).
////
//// A daemon that is a directory member answers `directory.status` with its
//// configured members, whether its own store has joined the cluster, Ra's
//// members with their votes, the leader when it can name one, and the last log
//// index it has applied. The launcher cannot import the daemon's types, so the
//// document is decoded here with a decoder of its own. Decoding is total: a
//// reply that is not shaped as expected is an `Error` naming the member, a member
//// this decoder does not know is ignored, and every text and list is bounded.
//// Every string the daemon sent is drawn through `text_hygiene.single_line`.
////
//// The view says what this member knows. A daemon that cannot reach a quorum
//// reports why Ra cannot say, and that reason is drawn in place of the voters
//// and the leader. Whether this member's own copy is current is not part of
//// `directory.status`; `loom deployment status` states it.
////
//// ## Flow
////
//// `decode` → `status_text` → `members_table`
////
//// 1. `decode` reads the document into a `Status`.
//// 2. `status_text` draws the summary line, this node's standing and a table with
////    a row for each member and for each Ra member the configured list lacks.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// The longest text the decoder accepts for any member, in bytes.
const text_limit = 256

/// The most entries the decoder accepts in any list.
const list_limit = 128

/// Whether a member of Ra's cluster votes.
pub type Vote {
  /// It votes.
  Voter

  /// It replicates the log and does not vote, whether it is being promoted or
  /// is meant to stay a follower.
  NonVoter
}

/// A member of Ra's cluster, as the leader or this node lists it.
pub type RaMember {
  RaMember(
    /// The member's node.
    node: String,
    /// Whether it votes.
    vote: Vote,
  )
}

/// Whether this daemon's own store has joined the cluster.
pub type Joining {
  /// It has.
  Joined

  /// It has not, or is rejoining after a reset.
  NotJoined
}

/// The decoded reply.
pub type Status {
  Status(
    /// The members as the daemon lists them: its configured list, or the nodes
    /// its ledger seats.
    members: List(String),
    /// Whether this node's store has joined.
    joining: Joining,
    /// Ra's members and their votes, empty when Ra could not say.
    ra_members: List(RaMember),
    /// The leader's node, when the daemon could name one.
    leader: Option(String),
    /// Why Ra could not say, when it could not.
    unavailable: Option(String),
    /// The last log index this member has applied.
    applied_index: Int,
  )
}

/// Reads a `directory.status` reply body.
///
/// `members`, `joined` and `applied_index` are required. Ra's members, the
/// leader and the reason Ra could not say are read when they are present and
/// well formed and are otherwise left out.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = directory_view.decode(json.Object([]))
/// ```
pub fn decode(document: JsonValue) -> Result(Status, String) {
  use members <- result.try(texts_at(document, "members"))
  use joined <- result.try(field(document, "joined"))
  use joining <- result.try(case joined {
    json.Bool(True) -> Ok(Joined)
    json.Bool(False) -> Ok(NotJoined)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Null -> Error("joined is not a boolean")
  })
  use applied_index <- result.map(count_at(document, "applied_index"))
  Status(
    members:,
    joining:,
    ra_members: optional_list(document, "ra_members", ra_member),
    leader: optional_text(document, "leader"),
    unavailable: optional_text(document, "unavailable"),
    applied_index:,
  )
}

fn ra_member(value: JsonValue) -> Result(RaMember, String) {
  use node <- result.try(text_at(value, "node"))
  use found <- result.try(field(value, "voter"))
  case found {
    json.Bool(True) -> Ok(RaMember(node:, vote: Voter))
    json.Bool(False) -> Ok(RaMember(node:, vote: NonVoter))
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Null -> Error("voter is not a boolean")
  }
}

/// The cluster as text: a summary, this node's standing, and a table of the
/// members with their votes and the leader.
///
/// ## Examples
///
/// ```gleam
/// // directory_view.status_text(status)
/// ```
pub fn status_text(status: Status) -> String {
  let voters =
    list.count(status.ra_members, fn(member) { member.vote == Voter })
  let summary =
    "directory: "
    <> int.to_string(list.length(status.members))
    <> case list.length(status.members) {
      1 -> " member, "
      _ -> " members, "
    }
    <> case status.unavailable {
      Some(why) -> "no cluster view (" <> clean(why) <> ")"
      None ->
        int.to_string(voters)
        <> case voters {
          1 -> " voter, "
          _ -> " voters, "
        }
        <> case status.leader {
          Some(leader) -> "leader " <> clean(leader)
          None -> "no leader"
        }
    }
    <> ", applied index "
    <> int.to_string(status.applied_index)
  let standing = case status.joining {
    Joined -> "this node has joined the cluster"
    NotJoined -> "this node has not joined the cluster"
  }
  string.join([summary, standing, "", members_table(status)], "\n")
}

// A row for each configured member, with its vote when Ra lists it, and then one
// for each Ra member the configured list does not name, so that a cluster that
// differs from the configuration shows the difference.
fn members_table(status: Status) -> String {
  let listed =
    list.map(status.members, fn(node) {
      [
        clean(node),
        vote_word(status, node),
        leader_word(status, node),
        "",
      ]
    })
  let extra =
    list.filter_map(status.ra_members, fn(member) {
      case list.contains(status.members, member.node) {
        True -> Error(Nil)
        False ->
          Ok([
            clean(member.node),
            vote_word(status, member.node),
            leader_word(status, member.node),
            "not in the configured list",
          ])
      }
    })
  aligned([["NODE", "VOTE", "ROLE", "NOTE"], ..list.append(listed, extra)])
}

fn vote_word(status: Status, node: String) -> String {
  case list.find(status.ra_members, fn(member) { member.node == node }) {
    Ok(RaMember(vote: Voter, ..)) -> "voter"
    Ok(RaMember(vote: NonVoter, ..)) -> "non-voter"
    Error(Nil) -> "-"
  }
}

fn leader_word(status: Status, node: String) -> String {
  case status.leader {
    Some(leader) if leader == node -> "leader"
    Some(_) | None -> ""
  }
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(members) ->
      list.key_find(members, key)
      |> result.map_error(fn(_) { "missing " <> key })
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected an object")
  }
}

fn text(value: JsonValue) -> Result(String, String) {
  case value {
    json.String(word) ->
      case word != "" && string.byte_size(word) <= text_limit {
        True -> Ok(word)
        False -> Error("expected nonempty bounded text")
      }
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected text")
  }
}

fn text_at(value: JsonValue, key: String) -> Result(String, String) {
  use found <- result.try(field(value, key))
  text(found) |> result.map_error(fn(reason) { key <> ": " <> reason })
}

fn optional_text(value: JsonValue, key: String) -> Option(String) {
  text_at(value, key) |> option.from_result
}

fn count_at(value: JsonValue, key: String) -> Result(Int, String) {
  use found <- result.try(field(value, key))
  case found {
    json.Int(count) if count >= 0 -> Ok(count)
    _ -> Error(key <> " is not a count")
  }
}

// A list of texts the reply must have, bounded like every list.
fn texts_at(value: JsonValue, key: String) -> Result(List(String), String) {
  use found <- result.try(field(value, key))
  case found {
    json.Array(items) ->
      case list.length(items) <= list_limit {
        True -> list.try_map(items, text)
        False -> Error(key <> " is longer than expected")
      }
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(key <> " is not a list")
  }
}

// A list the reply may leave out. Absent, malformed or oversized reads as none,
// and so does any entry that does not decode.
fn optional_list(
  value: JsonValue,
  key: String,
  read: fn(JsonValue) -> Result(a, String),
) -> List(a) {
  case field(value, key) {
    Ok(json.Array(items)) ->
      items |> list.take(list_limit) |> list.filter_map(read)
    Ok(_) | Error(_) -> []
  }
}

fn clean(word: String) -> String {
  text_hygiene.single_line(word)
}

// Rows with each column as wide as its widest cell, separated by two spaces,
// with no trailing spaces, so the output diffs cleanly.
fn aligned(rows: List(List(String))) -> String {
  let first = list.first(rows) |> result.unwrap([])
  let widths =
    list.index_map(first, fn(_, column) {
      list.fold(rows, 0, fn(widest, row) {
        let cell = row |> list.drop(column) |> list.first |> result.unwrap("")
        int.max(widest, string.length(cell))
      })
    })
  rows
  |> list.map(fn(row) {
    list.zip(row, widths)
    |> list.map(fn(cell) { string.pad_end(cell.0, to: cell.1, with: " ") })
    |> string.join("  ")
    |> string.trim_end
  })
  |> string.join("\n")
}
