//// `loom deployment status` and `loom deployment executors`: what the daemon
//// says of the machines it is configured with, as text (protocol-change/085).
////
//// The daemon answers `deployment.status` with a document, and this module is
//// the terminal's reading of it. The launcher cannot import the daemon's types,
//// so the document is decoded here with a decoder of its own, and decoding is
//// total: a reply that is not shaped as expected is an `Error` with a reason,
//// never a crash, and a member this decoder does not know is ignored. Only the
//// members the protocol marks required are required. Anything else that is
//// absent reads as unknown and is simply not drawn, which is what lets a later
//// daemon add members to a node without this reading failing.
////
//// Every string the daemon sent is drawn through `text_hygiene.single_line`,
//// which removes control characters, so a hostile or damaged reply cannot move
//// the cursor or start a second row. Nothing here is a policy about health: the
//// daemon classified each node, and this module prints what it said.
////
//// ## Flow
////
//// `decode` → `status_text` or `executors_text`
////
//// 1. `decode` reads the document into a `Status`.
//// 2. `status_text` draws the verdict, the nodes and the links, and
////    `executors_text` draws the executors a session may be placed on and the
////    pools of them.
//// 3. Both end in `table`, which pads each column to its widest cell, so two
////    runs against one deployment print identical rows.

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

/// What the daemon found of a node, as it states it.
pub type NodeState {
  /// The daemon reached the node and no reason applies.
  NodeOk

  /// The daemon reached the node, which has a reason of its own to be listed.
  NodeDegraded

  /// The daemon could not reach the node.
  NodeDown
}

/// The state a card for an executor shows.
pub type PlacementState {
  /// A session can be placed on it.
  PlacementReady

  /// A session can be placed on it, with a caveat the node's report states.
  PlacementDegraded

  /// It would refuse the next attach for lack of room.
  PlacementFull

  /// The daemon could not reach it.
  PlacementDown
}

/// Whether the asking daemon's own connection to the other end of an edge
/// exists.
pub type Link {
  /// The asking daemon is connected to it.
  Connected

  /// The asking daemon tried and is not connected.
  NotConnected

  /// The asking daemon cannot observe this edge, because it touches neither of
  /// its ends.
  Unobserved
}

/// One node of the deployment.
pub type Node {
  Node(
    /// The full node name.
    node: String,
    /// The asking daemon's key for the node, or the node name when it has none.
    name: String,
    /// What the node does: `orchestrator`, `executor`, `member`.
    roles: List(String),
    /// What the asking daemon found.
    state: NodeState,
    /// The fixed word that says why the node is down, when it is.
    reason: Option(String),
  )
}

/// A relation between two nodes.
pub type Edge {
  Edge(
    /// The node the relation starts at.
    from: String,
    /// The node it ends at.
    to: String,
    /// `serves`, `peer` or `member`, as the daemon wrote it.
    kind: String,
    /// The asking daemon's own link, where it has one.
    link: Link,
  )
}

/// What an executor's operator declared about its machine.
pub type Declared {
  Declared(
    /// The `<os>/<architecture>` label, when declared.
    platform: Option(String),
    /// `enforced` or `degraded`, when declared.
    enforcement: Option(String),
    /// The toolchains declared, possibly none.
    toolchains: List(String),
  )
}

/// An executor a session may be created on.
pub type Executor {
  Executor(
    /// The `[executors.<name>]` key.
    name: String,
    /// The node it is served by.
    node: String,
    /// The state the daemon gives it for placement.
    state: PlacementState,
    /// How many more scopes it can take, when it reported.
    free_scopes: Option(Int),
    /// The operator's declaration.
    declared: Declared,
    /// The words saying its census contradicts the declaration, when it does.
    contradiction: Option(String),
  )
}

/// A pool a session may be created in.
pub type Pool {
  Pool(
    /// The `[pools.<name>]` key.
    name: String,
    /// The executors the pool admits, in the order a first open tries them.
    executors: List(String),
    /// Those of them the daemon found reachable, in the same order.
    eligible: List(String),
  )
}

/// The decoded reply.
pub type Status {
  Status(
    /// The asking daemon's node.
    self: String,
    /// The whole deployment as the daemon judged it: `ok` when every configured
    /// node answered, `down` when none did, `degraded` between.
    state: NodeState,
    /// The nodes that are not `ok`, each with a fixed reason word.
    reasons: List(#(String, String)),
    /// The nodes, the asking daemon first.
    nodes: List(Node),
    /// The relations among them. Empty when the request named one node.
    edges: List(Edge),
    /// The executors a session may be created on. Empty when the request named
    /// one node.
    executors: List(Executor),
    /// The pools a session may be created in. Empty when the request named one
    /// node.
    pools: List(Pool),
  )
}

/// Reads a `deployment.status` reply body.
///
/// `self`, `state` and `nodes` are required, and each node needs its `node`,
/// `name`, `roles` and `state`. Every other member is read when it is present and
/// well formed and is otherwise left out. A value outside the protocol's words
/// (a state the daemon was never specified to send) is an `Error`, because a
/// client that guessed at it would print a health verdict the daemon did not
/// give.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = deployment_view.decode(json.Object([]))
/// ```
pub fn decode(document: JsonValue) -> Result(Status, String) {
  use self <- result.try(text_at(document, "self"))
  use state <- result.try(node_state_at(document, "state"))
  use nodes <- result.try(required_list(document, "nodes", node))
  let reasons = optional_list(document, "reasons", reason)
  let placements =
    field(document, "placements") |> result.unwrap(json.Object([]))
  Ok(Status(
    self:,
    state:,
    reasons:,
    nodes:,
    edges: optional_list(document, "edges", edge),
    executors: optional_list(placements, "executors", executor),
    pools: optional_list(placements, "pools", pool),
  ))
}

fn node(value: JsonValue) -> Result(Node, String) {
  use node <- result.try(text_at(value, "node"))
  use name <- result.try(text_at(value, "name"))
  use roles <- result.try(required_list(value, "roles", text))
  use state <- result.map(node_state_at(value, "state"))
  Node(node:, name:, roles:, state:, reason: optional_text(value, "reason"))
}

fn reason(value: JsonValue) -> Result(#(String, String), String) {
  use node <- result.try(text_at(value, "node"))
  use word <- result.map(text_at(value, "reason"))
  #(node, word)
}

fn edge(value: JsonValue) -> Result(Edge, String) {
  use from <- result.try(text_at(value, "from"))
  use to <- result.try(text_at(value, "to"))
  use kind <- result.map(text_at(value, "kind"))
  let link = case optional_text(value, "link") {
    Some("connected") -> Connected
    Some("none") -> NotConnected
    Some(_) | None -> Unobserved
  }
  Edge(from:, to:, kind:, link:)
}

fn executor(value: JsonValue) -> Result(Executor, String) {
  use name <- result.try(text_at(value, "name"))
  use node <- result.try(text_at(value, "node"))
  use state <- result.try(text_at(value, "state"))
  use state <- result.map(placement_state(state))
  let declared = field(value, "declared") |> result.unwrap(json.Object([]))
  Executor(
    name:,
    node:,
    state:,
    free_scopes: case field(value, "free_scopes") {
      Ok(json.Int(count)) if count >= 0 -> Some(count)
      Ok(_) | Error(_) -> None
    },
    declared: Declared(
      platform: optional_text(declared, "platform"),
      enforcement: optional_text(declared, "enforcement"),
      toolchains: optional_list(declared, "toolchains", text),
    ),
    contradiction: optional_text(value, "contradiction"),
  )
}

fn pool(value: JsonValue) -> Result(Pool, String) {
  use name <- result.try(text_at(value, "name"))
  use executors <- result.try(required_list(value, "executors", text))
  use eligible <- result.map(required_list(value, "eligible", text))
  Pool(name:, executors:, eligible:)
}

fn node_state_at(value: JsonValue, key: String) -> Result(NodeState, String) {
  use word <- result.try(text_at(value, key))
  case word {
    "ok" -> Ok(NodeOk)
    "degraded" -> Ok(NodeDegraded)
    "down" -> Ok(NodeDown)
    _ -> Error("unknown node state")
  }
}

fn placement_state(word: String) -> Result(PlacementState, String) {
  case word {
    "ready" -> Ok(PlacementReady)
    "degraded" -> Ok(PlacementDegraded)
    "full" -> Ok(PlacementFull)
    "down" -> Ok(PlacementDown)
    _ -> Error("unknown placement state")
  }
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(members) ->
      list.key_find(members, key) |> result.replace_error("missing " <> key)
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

// A list the reply must have. Its entries must each decode, and it may not
// outgrow `list_limit`, because the daemon bounds a reply and a client holds it
// to the bound.
fn required_list(
  value: JsonValue,
  key: String,
  read: fn(JsonValue) -> Result(a, String),
) -> Result(List(a), String) {
  use found <- result.try(field(value, key))
  case found {
    json.Array(items) ->
      case list.length(items) <= list_limit {
        True -> list.try_map(items, read)
        False -> Error(key <> " is longer than expected")
      }
    _ -> Error(key <> " is not a list")
  }
}

// A list the reply may leave out. Absent, malformed or oversized reads as none,
// and so does any entry that does not decode: the optional parts of a reply
// are drawn when they are well formed and skipped when they are not.
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

/// The deployment as a verdict, a table of nodes and the links among them.
///
/// ## Examples
///
/// ```gleam
/// // deployment_view.status_text(status)
/// ```
pub fn status_text(status: Status) -> String {
  let answered = list.count(status.nodes, fn(node) { node.state != NodeDown })
  let head =
    "deployment as seen from "
    <> clean(status.self)
    <> ", "
    <> int.to_string(answered)
    <> " of "
    <> int.to_string(list.length(status.nodes))
    <> " nodes answered\nstate: "
    <> verdict(status)
  let nodes =
    table(
      ["NODE", "ROLE", "STATE", "NOTE"],
      list.map(status.nodes, fn(node) {
        [
          short(node.name),
          string.join(list.map(node.roles, clean), ", "),
          node_state_word(node.state),
          option.map(node.reason, clean) |> option.unwrap(""),
        ]
      }),
    )
  case status.edges {
    [] -> head <> "\n\n" <> nodes
    edges -> head <> "\n\n" <> nodes <> "\n\n" <> links(status, edges)
  }
}

// "ok", or the state with each node that is not ok and why.
fn verdict(status: Status) -> String {
  case status.reasons {
    [] -> node_state_word(status.state)
    reasons ->
      node_state_word(status.state)
      <> " ("
      <> string.join(
        list.map(reasons, fn(found) {
          short(named(status.nodes, found.0)) <> ": " <> clean(found.1)
        }),
        "; ",
      )
      <> ")"
  }
}

// The asking daemon's key for a node, or the node name when it has none.
fn named(nodes: List(Node), node: String) -> String {
  list.find(nodes, fn(each) { each.node == node })
  |> result.map(fn(each) { each.name })
  |> result.unwrap(node)
}

// One line per relation. A link the daemon observed is drawn `==` when it is
// up and `..` when it is not, and a relation it cannot observe is drawn `--`,
// so a reader never takes a relation for a connection.
fn links(status: Status, edges: List(Edge)) -> String {
  let rows =
    list.map(edges, fn(edge) {
      let mark = case edge.link {
        Connected -> "=="
        NotConnected -> ".."
        Unobserved -> "--"
      }
      [
        short(named(status.nodes, edge.from)),
        mark,
        short(named(status.nodes, edge.to)),
        clean(edge.kind),
      ]
    })
  "LINKS (== connected, .. not connected, -- not observable from "
  <> short(named(status.nodes, status.self))
  <> ")\n"
  <> aligned(rows)
}

/// The executors a session may be created on, and the pools of them, each with
/// the state the daemon gives it. A down executor says why when the node list
/// does.
///
/// ## Examples
///
/// ```gleam
/// // deployment_view.executors_text(status)
/// ```
pub fn executors_text(status: Status) -> String {
  case status.executors {
    [] -> "no executors are configured"
    executors -> {
      let rows =
        table(
          [
            "EXECUTOR",
            "NODE",
            "STATE",
            "PLATFORM",
            "ENFORCEMENT",
            "TOOLCHAINS",
            "POOLS",
            "NOTE",
          ],
          list.map(executors, fn(executor) {
            [
              clean(executor.name),
              clean(executor.node),
              placement_word(executor.state),
              dash(executor.declared.platform),
              dash(executor.declared.enforcement),
              case executor.declared.toolchains {
                [] -> "-"
                names -> string.join(list.map(names, clean), ",")
              },
              case pools_of(status.pools, executor.name) {
                [] -> "-"
                names -> string.join(names, ",")
              },
              note(status, executor),
            ]
          }),
        )
      case status.pools {
        [] -> rows
        pools ->
          rows
          <> "\n\n"
          <> table(
            ["POOL", "EXECUTORS (trial order)", "ELIGIBLE"],
            list.map(pools, fn(pool) {
              [
                clean(pool.name),
                string.join(list.map(pool.executors, clean), ", "),
                case pool.eligible {
                  [] -> "-"
                  names -> string.join(list.map(names, clean), ", ")
                },
              ]
            }),
          )
      }
    }
  }
}

// Why the executor is not simply ready: the node's reason when it is down, then
// the contradiction between its census and its declaration, when it has one.
fn note(status: Status, executor: Executor) -> String {
  let down =
    list.find(status.nodes, fn(node) {
      node.node == executor.node && node.state == NodeDown
    })
    |> result.map(fn(node) { option.unwrap(node.reason, "down") })
    |> option.from_result
  let words =
    [down, executor.contradiction]
    |> list.filter_map(option.to_result(_, Nil))
  string.join(list.map(words, clean), "; ")
}

fn pools_of(pools: List(Pool), executor: String) -> List(String) {
  list.filter_map(pools, fn(pool) {
    case list.contains(pool.executors, executor) {
      True -> Ok(clean(pool.name))
      False -> Error(Nil)
    }
  })
}

fn dash(word: Option(String)) -> String {
  option.map(word, clean) |> option.unwrap("-")
}

fn node_state_word(state: NodeState) -> String {
  case state {
    NodeOk -> "ok"
    NodeDegraded -> "degraded"
    NodeDown -> "down"
  }
}

fn placement_word(state: PlacementState) -> String {
  case state {
    PlacementReady -> "ready"
    PlacementDegraded -> "degraded"
    PlacementFull -> "full"
    PlacementDown -> "down"
  }
}

// The text a daemon sent, made safe to print on one row.
fn clean(word: String) -> String {
  text_hygiene.single_line(word)
}

// A node drawn by its key, or by the part of its name before the host, so that
// `alpha@10.0.0.1` is `alpha` where a row has little room. A key never contains
// the at sign, so a configured name is unchanged.
fn short(name: String) -> String {
  case string.split_once(name, "@") {
    Ok(#(before, _host)) -> clean(before)
    Error(Nil) -> clean(name)
  }
}

// Rows under a header, each column as wide as its widest cell and separated by
// two spaces, with no trailing spaces, so the output diffs cleanly.
fn table(header: List(String), rows: List(List(String))) -> String {
  aligned([header, ..rows])
}

// Rows with no header, padded the same way. A row shorter than the first has
// its missing cells drawn empty.
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
