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
//// daemon add members to a node without this reading failing. Every text is
//// bounded by `text_limit` and every list by `list_limit`.
////
//// Every string the daemon sent is drawn through `text_hygiene.single_line`,
//// which removes control characters, so a hostile or damaged reply cannot move
//// the cursor or start a second row. Nothing here is a policy about health: the
//// daemon classified each node, and this module prints what it said and puts
//// the daemon's fixed reason words into sentences.
////
//// ## Flow
////
//// `decode` → `status_text` or `executors_text`
////
//// 1. `decode` reads the document into a `Status`: the nodes with what each
////    reported, the edges, the placements, the directory block and the moves.
//// 2. `status_text` draws the verdict, the nodes with their build, scopes and
////    a note, the links, the directory and the moves in flight, and for a
////    daemon that runs from a membership ledger the ledger's head and the head
////    each member has reported (`ledger_text`). A reply for one node
////    (`OneNode`) is followed by that node's long lists (`detail_sections`).
////    `executors_text` draws the executors a session may be placed on and the
////    pools of them.
//// 3. Both end in `table`, which pads each column to its widest cell, so two
////    runs against one deployment print identical rows.
//// 4. `candidates` reads the same document's orchestrators member for
////    `loom sessions move <id>` with no destination, and `candidates_text`
////    prints which of them could take the session and why the others cannot.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/move_candidates
import session_view/text_hygiene

/// The longest text the decoder accepts for any member, in bytes.
const text_limit = 256

/// The most entries the decoder accepts in any list.
const list_limit = 128

/// The most moves a text lists before it counts the rest.
const moves_drawn = 8

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

/// How much of the deployment a reply covers.
pub type Extent {
  /// Every configured node, with the links among them.
  Everything

  /// The one node the request named, with its long lists. The daemon leaves
  /// `edges` out of such a reply.
  OneNode
}

/// A scope on an executor that blocks a reopen.
pub type Unclean {
  Unclean(
    /// The session the scope belongs to.
    session: String,
    /// `closing` or `unknown_cleanup`, as the daemon wrote it.
    state: String,
    /// How many children the host could not prove gone, for `unknown_cleanup`.
    count: Option(Int),
  )
}

/// What an executor reported about its machine and its execution ledger.
pub type ExecutorFacts {
  ExecutorFacts(
    /// Scopes admitting calls.
    open: Int,
    /// Scopes fenced while their live work is cancelled.
    closing: Int,
    /// Scopes closed with every child retired.
    closed_clean: Int,
    /// Scopes closed without proof that every child is gone.
    closed_unknown: Int,
    /// The most scopes it admits that are not cleanly closed.
    scope_limit: Int,
    /// Bytes the ledger holds, when stated.
    ledger_bytes: Option(Int),
    /// The most bytes it admits, when stated.
    ledger_limit: Option(Int),
    /// Results nobody has acknowledged, when stated.
    unacknowledged: Option(Int),
    /// The platform label it reported, when stated.
    platform: Option(String),
    /// The words saying its census contradicts its declaration, when it does.
    contradiction: Option(String),
    /// The registered workspace names. Present only in a reply for one node.
    workspaces: List(String),
    /// The scopes that block a reopen. Present only in a reply for one node.
    unclean: List(Unclean),
  )
}

/// A move this orchestrator has in flight.
pub type Move {
  Move(
    /// The session being moved.
    session: String,
    /// The node or key of the orchestrator it is moving to.
    to: String,
    /// `running` or `waiting`.
    phase: String,
    /// Milliseconds since the stall began, when stalled.
    stalled_ms: Option(Int),
    /// Why the last run stopped, when it did.
    reason: Option(String),
  )
}

/// The sessions an orchestrator has placed on one executor.
pub type Placed {
  Placed(
    /// The executor's node.
    executor_node: String,
    /// Sessions with a usable resident runtime.
    resident: Int,
    /// Sessions that are saved and not resident.
    saved: Int,
  )
}

/// What an orchestrator reported about its capacity and sessions.
pub type OrchestratorFacts {
  OrchestratorFacts(
    /// The most simultaneous runtime reservations.
    capacity: Int,
    /// The reservations held now.
    occupied: Int,
    /// The usable resident sessions.
    resident: Int,
    /// `receiving` or `not_receiving`, when stated.
    imports: Option(String),
    /// How many moves it has in flight.
    moves_in_flight: Int,
    /// Sessions by executor. Present only in a reply for one node.
    placements: List(Placed),
    /// The moves in flight. Present only in a reply for one node.
    moves: List(Move),
  )
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
    /// The fixed words that say why the node is degraded, when it is.
    reasons: List(String),
    /// The node's build commit, when it reported.
    build_commit: Option(String),
    /// The node's build version, when it reported.
    build_version: Option(String),
    /// Milliseconds since the node started, by its own clock, when it
    /// reported.
    uptime_ms: Option(Int),
    /// What it reported as an orchestrator, when it is one.
    orchestrator: Option(OrchestratorFacts),
    /// What it reported as an executor, when it is one.
    executor: Option(ExecutorFacts),
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
    /// The sessions placed, on a `serves` edge.
    sessions: Option(Int),
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
    /// Those of them that could take a session, in the same order.
    eligible: List(String),
  )
}

/// The session directory as the asking daemon sees it.
pub type Directory {
  Directory(
    /// The nodes of the directory's members.
    members: List(String),
    /// How many of Ra's members vote.
    voters: Int,
    /// The leader's node, when the daemon could name one.
    leader: Option(String),
    /// Why Ra could not say, when it could not.
    unavailable: Option(String),
    /// The last log index this member has applied.
    applied_index: Int,
    /// `current` or `unconfirmed`, when stated.
    copy: Option(String),
  )
}

/// One member of the membership ledger, with the newest entry it reported to the
/// asking daemon (protocol-change/086).
pub type LedgerMember {
  LedgerMember(
    /// The member's name in the ledger.
    name: String,
    /// The sequence number of the newest entry it reported, or `None` when it
    /// has not reported to the asking daemon.
    reported: Option(Int),
    /// Milliseconds on the asking daemon's own clock since that report.
    age_ms: Option(Int),
  )
}

/// The last entry the asking daemon refused.
pub type LedgerRefusal {
  LedgerRefusal(
    /// The sequence number the line claimed, when it had one.
    seq: Option(Int),
    /// The step that failed, as the daemon worded it.
    step: String,
  )
}

/// What the asking daemon says of its membership ledger, so that an operator can
/// see whether a change has reached the members.
pub type Ledger {
  Ledger(
    /// The asking daemon's standing: `ok`, `revoked` or `not_enrolled`.
    standing: String,
    /// The sequence number of the newest entry the daemon holds.
    head_seq: Int,
    /// The first eight characters of that entry's identity.
    head_id: String,
    /// The active members, as the daemon lists them.
    members: List(LedgerMember),
    /// The last refusal, when the daemon has refused a line.
    last_refusal: Option(LedgerRefusal),
  )
}

/// The decoded reply.
pub type Status {
  Status(
    /// The asking daemon's node.
    self: String,
    /// The asking daemon's wall clock when it built the reply, in Unix
    /// milliseconds, when stated.
    as_of_ms: Option(Int),
    /// The whole deployment as the daemon judged it: `ok` when every configured
    /// node answered with no reason, `down` when none did, `degraded` between.
    state: NodeState,
    /// The nodes that are not `ok`, each with a fixed reason word.
    reasons: List(#(String, String)),
    /// The nodes, the asking daemon first.
    nodes: List(Node),
    /// How much of the deployment the reply covers.
    extent: Extent,
    /// The relations among them. Empty when the request named one node.
    edges: List(Edge),
    /// The executors a session may be created on. Empty when the request named
    /// one node.
    executors: List(Executor),
    /// The pools a session may be created in. Empty when the request named one
    /// node.
    pools: List(Pool),
    /// The asking daemon's directory, when it is a member and the request named
    /// no node.
    directory: Option(Directory),
    /// The moves in flight on the asking daemon.
    moves: List(Move),
    /// The asking daemon's membership ledger, when it runs from one and the
    /// request named no node.
    ledger: Option(Ledger),
    /// What an overview left out to fit one frame (`moves`, `node_facts`,
    /// `edges` and the like). Empty when it left nothing out.
    omitted: List(String),
    /// The long lists of a reply for one node that were cut to fit one frame.
    more: List(String),
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
    as_of_ms: optional_count(document, "as_of_ms"),
    state:,
    reasons:,
    nodes:,
    extent: case field(document, "orchestrators"), field(document, "edges") {
      Error(_), Error(_) -> OneNode
      Ok(_), _ | _, Ok(_) -> Everything
    },
    edges: optional_list(document, "edges", edge),
    executors: optional_list(placements, "executors", executor),
    pools: optional_list(placements, "pools", pool),
    directory: case field(document, "directory") |> result.try(directory) {
      Ok(found) -> Some(found)
      Error(_) -> None
    },
    moves: optional_list(document, "moves", move),
    ledger: case field(document, "ledger") |> result.try(ledger) {
      Ok(found) -> Some(found)
      Error(_) -> None
    },
    omitted: optional_list(document, "omitted", text),
    more: optional_list(document, "more", text),
  ))
}

// The directory block is optional like the rest of what a later daemon adds, so
// one that does not decode is left out and the rest of the reply is drawn. A
// member that is a voter is counted from Ra's own list, which is the cluster as
// the leader sees it.
fn directory(value: JsonValue) -> Result(Directory, String) {
  use members <- result.try(required_list(value, "members", text))
  use applied_index <- result.map(count_at(value, "applied_index"))
  Directory(
    members:,
    voters: list.count(optional_list(value, "ra_members", voter), fn(is) { is }),
    leader: optional_text(value, "leader"),
    unavailable: optional_text(value, "unavailable"),
    applied_index:,
    copy: optional_text(value, "copy"),
  )
}

// One entry of Ra's members as a vote: whether the entry is a voter. A voter
// is the only entry counted, and an entry that is malformed is skipped like any
// optional one.
fn voter(value: JsonValue) -> Result(Bool, String) {
  use _node <- result.try(text_at(value, "node"))
  use found <- result.try(field(value, "voter"))
  case found {
    json.Bool(is) -> Ok(is)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Null -> Error("voter is not a boolean")
  }
}

fn move(value: JsonValue) -> Result(Move, String) {
  use session <- result.try(text_at(value, "session_id"))
  use to <- result.try(text_at(value, "to"))
  use phase <- result.map(text_at(value, "phase"))
  Move(
    session:,
    to:,
    phase:,
    stalled_ms: optional_count(value, "stalled_ms"),
    reason: optional_text(value, "reason"),
  )
}

// The ledger member is optional like the rest of what a later daemon adds, so a
// ledger that does not decode is left out and the rest of the reply is drawn.
// Its own required parts are the head and the standing; a member entry that is
// malformed is skipped, as an optional list's entries are.
fn ledger(value: JsonValue) -> Result(Ledger, String) {
  use standing <- result.try(text_at(value, "state"))
  use head <- result.try(field(value, "head"))
  use head_seq <- result.try(count_at(head, "seq"))
  use head_id <- result.map(text_at(head, "id"))
  Ledger(
    standing:,
    head_seq:,
    head_id: string.slice(head_id, at_index: 0, length: 8),
    members: optional_list(value, "members", ledger_member),
    last_refusal: case field(value, "last_refusal") {
      Ok(refusal) -> ledger_refusal(refusal) |> option.from_result
      Error(_) -> None
    },
  )
}

fn ledger_member(value: JsonValue) -> Result(LedgerMember, String) {
  use name <- result.map(text_at(value, "name"))
  LedgerMember(
    name:,
    reported: optional_count(value, "reported_seq"),
    age_ms: optional_count(value, "ms_since_report"),
  )
}

fn ledger_refusal(value: JsonValue) -> Result(LedgerRefusal, String) {
  use step <- result.map(text_at(value, "step"))
  LedgerRefusal(seq: optional_count(value, "seq"), step:)
}

fn count_at(value: JsonValue, key: String) -> Result(Int, String) {
  use found <- result.try(field(value, key))
  case found {
    json.Int(count) if count >= 0 -> Ok(count)
    _ -> Error(key <> " is not a count")
  }
}

fn optional_count(value: JsonValue, key: String) -> Option(Int) {
  count_at(value, key) |> option.from_result
}

fn node(value: JsonValue) -> Result(Node, String) {
  use node <- result.try(text_at(value, "node"))
  use name <- result.try(text_at(value, "name"))
  use roles <- result.try(required_list(value, "roles", text))
  use state <- result.map(node_state_at(value, "state"))
  Node(
    node:,
    name:,
    roles:,
    state:,
    reason: optional_text(value, "reason"),
    reasons: optional_list(value, "reasons", text),
    build_commit: optional_text(value, "build_commit"),
    build_version: optional_text(value, "build_version"),
    uptime_ms: optional_count(value, "uptime_ms"),
    orchestrator: case
      field(value, "orchestrator") |> result.try(orchestrator)
    {
      Ok(found) -> Some(found)
      Error(_) -> None
    },
    executor: case field(value, "executor") |> result.try(executor_facts) {
      Ok(found) -> Some(found)
      Error(_) -> None
    },
  )
}

fn orchestrator(value: JsonValue) -> Result(OrchestratorFacts, String) {
  use capacity <- result.try(count_at(value, "capacity"))
  use occupied <- result.try(count_at(value, "occupied"))
  use resident <- result.map(count_at(value, "resident"))
  let moves = optional_list(value, "moves", move)
  OrchestratorFacts(
    capacity:,
    occupied:,
    resident:,
    imports: optional_text(value, "imports"),
    moves_in_flight: case count_at(value, "moves_in_flight") {
      Ok(count) -> count
      Error(_) -> list.length(moves)
    },
    placements: optional_list(value, "placements", placed),
    moves:,
  )
}

fn placed(value: JsonValue) -> Result(Placed, String) {
  use executor_node <- result.try(text_at(value, "executor_node"))
  use resident <- result.try(count_at(value, "resident"))
  use saved <- result.map(count_at(value, "saved"))
  Placed(executor_node:, resident:, saved:)
}

fn executor_facts(value: JsonValue) -> Result(ExecutorFacts, String) {
  use scopes <- result.try(field(value, "scopes"))
  use open <- result.try(count_at(scopes, "open"))
  use closing <- result.try(count_at(scopes, "closing"))
  use closed_clean <- result.try(count_at(scopes, "closed_clean"))
  use closed_unknown <- result.try(count_at(scopes, "closed_unknown"))
  use scope_limit <- result.map(count_at(value, "scope_limit"))
  ExecutorFacts(
    open:,
    closing:,
    closed_clean:,
    closed_unknown:,
    scope_limit:,
    ledger_bytes: optional_count(value, "ledger_bytes"),
    ledger_limit: optional_count(value, "ledger_limit"),
    unacknowledged: optional_count(value, "unacknowledged"),
    platform: optional_text(value, "platform"),
    contradiction: optional_text(value, "contradiction"),
    workspaces: optional_list(value, "workspaces", text),
    unclean: optional_list(value, "unclean", unclean),
  )
}

fn unclean(value: JsonValue) -> Result(Unclean, String) {
  use session <- result.try(text_at(value, "session"))
  use state <- result.map(text_at(value, "state"))
  Unclean(session:, state:, count: optional_count(value, "count"))
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
  Edge(from:, to:, kind:, sessions: optional_count(value, "sessions"), link:)
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

/// The deployment as a verdict, a table of nodes and the links among them, the
/// directory and the moves in flight, and for a reply about one node that node's
/// long lists.
///
/// ## Examples
///
/// ```gleam
/// // deployment_view.status_text(status)
/// ```
pub fn status_text(status: Status) -> String {
  let sections =
    list.flatten([
      [head_text(status), nodes_text(status)],
      case status.edges {
        [] -> []
        edges -> [links(status, edges)]
      },
      case directory_lines(status), move_lines(status) {
        [], [] -> []
        directory, moves -> [string.join(list.append(directory, moves), "\n")]
      },
      case status.extent {
        Everything -> []
        OneNode -> detail_sections(status)
      },
      case status.ledger {
        Some(found) -> [ledger_text(found)]
        None -> []
      },
      cut_text(status),
    ])
  string.join(sections, "\n\n")
}

// A line saying the daemon cut the reply to fit one frame, and how to see the
// rest. An overview that left things out points at the one-node read, which
// carries them; a one-node reply that was cut says which lists.
fn cut_text(status: Status) -> List(String) {
  case status.omitted, status.more {
    [], [] -> []
    omitted, [] -> [
      "left out to fit one frame: "
      <> string.join(list.map(omitted, clean), ", ")
      <> "\nrun with --node <key> for the rest",
    ]
    _, more -> [
      "lists cut to fit one frame: " <> string.join(list.map(more, clean), ", "),
    ]
  }
}

// The verdict: who asked, how many nodes answered, when, and the state with each
// node that is not ok and why.
fn head_text(status: Status) -> String {
  let answered = list.count(status.nodes, fn(node) { node.state != NodeDown })
  "deployment as seen from "
  <> short(named(status.nodes, status.self))
  <> ", "
  <> int.to_string(answered)
  <> " of "
  <> int.to_string(list.length(status.nodes))
  <> " nodes answered"
  <> case status.as_of_ms {
    Some(ms) -> ", " <> clock_text(ms)
    None -> ""
  }
  <> "\nstate: "
  <> verdict(status)
}

// The time of day of a Unix millisecond reading in UTC. The terminal has no
// time zone to draw it in, and a time with no zone would be read as local.
fn clock_text(ms: Int) -> String {
  let seconds = ms / 1000
  let day = seconds % 86_400
  two(day / 3600)
  <> ":"
  <> two(day % 3600 / 60)
  <> ":"
  <> two(day % 60)
  <> " UTC"
}

fn two(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}

fn nodes_text(status: Status) -> String {
  table(
    ["NODE", "ROLE", "STATE", "BUILD", "SCOPES", "NOTE"],
    list.map(status.nodes, fn(node) {
      [
        short(node.name),
        string.join(list.map(node.roles, clean), ", "),
        node_state_word(node.state),
        build_text(node),
        scopes_text(node),
        note_text(status, node),
      ]
    }),
  )
}

// The commit a node reported, cut to eight characters, or a dash for a node
// that did not report.
fn build_text(node: Node) -> String {
  case node.build_commit {
    Some(commit) -> clean(string.slice(commit, at_index: 0, length: 8))
    None -> "-"
  }
}

// Scopes held against the limit: the open ones and the ones that block a reopen,
// which are the ones the limit counts.
fn scopes_text(node: Node) -> String {
  case node.executor {
    Some(facts) ->
      int.to_string(held(facts)) <> "/" <> int.to_string(facts.scope_limit)
    None -> "-"
  }
}

fn held(facts: ExecutorFacts) -> Int {
  facts.open + facts.closing + facts.closed_unknown
}

// What is worth saying about a node beside its row: why it is down, what an
// orchestrator reports of its slots and moves and whether it leads the
// directory, and then the sentence for each reason it is degraded.
fn note_text(status: Status, node: Node) -> String {
  let facts =
    list.flatten([
      case node.state, node.reason {
        NodeDown, Some("silent") -> ["connected, no report"]
        NodeDown, Some(word) -> [clean(word)]
        NodeDown, None -> ["down"]
        NodeOk, _ | NodeDegraded, _ -> []
      },
      case node.orchestrator {
        Some(found) -> orchestrator_words(found)
        None -> []
      },
      case directory_leader(status, node) {
        True -> ["directory leader"]
        False -> []
      },
    ])
  let degraded = case node.state {
    NodeDegraded -> list.map(node.reasons, fn(word) { reason_note(node, word) })
    NodeOk | NodeDown -> []
  }
  string.join(
    list.filter(
      [string.join(facts, ", "), string.join(degraded, "; ")],
      fn(part) { part != "" },
    ),
    "; ",
  )
}

fn orchestrator_words(found: OrchestratorFacts) -> List(String) {
  list.flatten([
    [
      int.to_string(found.capacity)
      <> " slots, "
      <> int.to_string(found.resident)
      <> " resident",
    ],
    case found.moves_in_flight {
      0 -> []
      1 -> ["1 move in flight"]
      many -> [int.to_string(many) <> " moves in flight"]
    },
    case found.imports {
      Some("not_receiving") -> ["not receiving moves"]
      Some(_) | None -> []
    },
  ])
}

fn directory_leader(status: Status, node: Node) -> Bool {
  case status.directory {
    Some(Directory(leader: Some(leader), ..)) -> leader == node.node
    Some(Directory(leader: None, ..)) | None -> False
  }
}

// A node's reason as a phrase for its row. The session of a scope that needs a
// release is named when the reply carries the node's long lists.
fn reason_note(node: Node, word: String) -> String {
  case word {
    "unclean_scope" -> unclean_note(node)
    "full" -> "no free scope"
    "declaration_contradicted" -> "census contradicts its declaration"
    "build_differs" -> "build differs"
    "protocol_differs" -> "protocol differs"
    "directory_no_leader" -> "directory has no leader"
    "directory_copy_unconfirmed" -> "directory copy unconfirmed"
    "directory_quorum_lost" -> "cannot reach a quorum of voters"
    other -> clean(other)
  }
}

fn unclean_note(node: Node) -> String {
  case node.executor {
    Some(ExecutorFacts(unclean: [_, ..] as scopes, ..)) ->
      scopes_phrase(list.length(scopes), " needs release")
      <> ": "
      <> string.join(
        list.map(scopes, fn(scope) { sessions_short(scope.session) }),
        ", ",
      )
    Some(facts) ->
      scopes_phrase(facts.closing + facts.closed_unknown, " needs release")
    None -> "a scope needs release"
  }
}

// "1 scope" or "3 scopes", followed by the words that say what is wrong.
fn scopes_phrase(count: Int, words: String) -> String {
  case count {
    1 -> "1 scope" <> words
    many ->
      int.to_string(many) <> " scopes" <> string.replace(words, "needs", "need")
  }
}

fn sessions_short(session: String) -> String {
  clean(string.slice(session, at_index: 0, length: 8))
}

// "ok", or the state with each node that is not ok and why.
fn verdict(status: Status) -> String {
  case status.reasons {
    [] -> node_state_word(status.state)
    reasons ->
      node_state_word(status.state)
      <> " ("
      <> string.join(
        list.map(reasons, fn(found) { reason_sentence(status, found) }),
        "; ",
      )
      <> ")"
  }
}

// One reason as the verdict words it. A node that is down is "down" and its
// row says why, and a degraded node's reason is a sentence about it.
fn reason_sentence(status: Status, found: #(String, String)) -> String {
  let name = short(named(status.nodes, found.0))
  let node = list.find(status.nodes, fn(each) { each.node == found.0 })
  case node {
    Ok(Node(state: NodeDown, ..)) -> name <> " down"
    Ok(Node(executor: Some(facts), ..)) if found.1 == "unclean_scope" ->
      name
      <> " has "
      <> scopes_phrase(
        facts.closing + facts.closed_unknown,
        " that needs a release",
      )
    Ok(_) | Error(Nil) ->
      case found.1 {
        "unclean_scope" -> name <> " has a scope that needs a release"
        "full" -> name <> " has no free scope"
        "declaration_contradicted" ->
          name <> "'s census contradicts its declaration"
        "build_differs" -> name <> " runs another build"
        "protocol_differs" -> name <> " speaks another protocol"
        "directory_no_leader" -> name <> "'s directory has no leader"
        "directory_copy_unconfirmed" ->
          name <> "'s directory copy is unconfirmed"
        "directory_quorum_lost" ->
          name <> " cannot reach a quorum of directory voters"
        other -> name <> ": " <> clean(other)
      }
  }
}

// The asking daemon's key for a node, or the node name when it has none.
fn named(nodes: List(Node), node: String) -> String {
  list.find(nodes, fn(each) { each.node == node })
  |> result.map(fn(each) { each.name })
  |> result.unwrap(node)
}

// One line per pair of nodes. Edges between the same two nodes are one line
// that names each relation, in the order the daemon wrote them. A link the daemon
// observed is drawn `==` when it is up and `..` when it is not, and a relation it
// cannot observe is drawn `--`, so a reader never takes a relation for a
// connection.
fn links(status: Status, edges: List(Edge)) -> String {
  let asker = short(named(status.nodes, status.self))
  let rows =
    list.map(pairs(edges), fn(pair) {
      let #(from, to, related) = pair
      #(
        short(named(status.nodes, from)),
        link_mark(related),
        short(named(status.nodes, to)),
        string.join(list.map(related, relation_words), ", "),
      )
    })
  let from_width = widest(list.map(rows, fn(row) { row.0 }))
  let to_width = widest(list.map(rows, fn(row) { row.2 }))
  let drawn =
    list.map(rows, fn(row) {
      string.pad_end(row.0, to: from_width, with: " ")
      <> " "
      <> row.1
      <> " "
      <> string.pad_end(row.2, to: to_width, with: " ")
      <> "   "
      <> row.3
      |> string.trim_end
    })
  string.join(
    [
      "LINKS  == connected from "
        <> asker
        <> "   .. not connected from "
        <> asker
        <> "   -- relation, not observable from "
        <> asker,
      ..drawn
    ],
    "\n",
  )
}

fn widest(cells: List(String)) -> Int {
  list.fold(cells, 0, fn(most, cell) { int.max(most, string.length(cell)) })
}

// The edges grouped by the two nodes they join, in either direction, in the
// order each pair first appears.
fn pairs(edges: List(Edge)) -> List(#(String, String, List(Edge))) {
  list.fold(edges, [], fn(found, each) {
    let same = fn(pair: #(String, String, List(Edge))) {
      { pair.0 == each.from && pair.1 == each.to }
      || { pair.0 == each.to && pair.1 == each.from }
    }
    case list.any(found, same) {
      True ->
        list.map(found, fn(pair) {
          case same(pair) {
            True -> #(pair.0, pair.1, list.append(pair.2, [each]))
            False -> pair
          }
        })
      False -> list.append(found, [#(each.from, each.to, [each])])
    }
  })
}

// The mark for a pair: connected if the asking daemon is connected, not
// connected if it tried and is not, and not observable otherwise.
fn link_mark(related: List(Edge)) -> String {
  let links = list.map(related, fn(each) { each.link })
  case list.contains(links, Connected), list.contains(links, NotConnected) {
    True, _ -> "=="
    False, True -> ".."
    False, False -> "--"
  }
}

fn relation_words(edge: Edge) -> String {
  case edge.kind, edge.sessions {
    "serves", Some(count) -> "serves " <> int.to_string(count)
    kind, _ -> clean(kind)
  }
}

// The directory as the asking daemon sees it: how many members and voters, who
// leads, and whether its own copy is current.
fn directory_lines(status: Status) -> List(String) {
  case status.directory {
    None -> []
    Some(found) -> {
      let cluster = case found.unavailable {
        Some(why) -> "no cluster view (" <> clean(why) <> ")"
        None ->
          int.to_string(found.voters)
          <> case found.voters {
            1 -> " voter, "
            _ -> " voters, "
          }
          <> case found.leader {
            Some(leader) -> "leader " <> short(named(status.nodes, leader))
            None -> "no leader"
          }
      }
      [
        "DIRECTORY  "
        <> int.to_string(list.length(found.members))
        <> case list.length(found.members) {
          1 -> " member, "
          _ -> " members, "
        }
        <> cluster
        <> case found.copy {
          Some(word) -> ", this copy " <> clean(word)
          None -> ""
        },
      ]
    }
  }
}

// The moves in flight on the asking daemon. One is drawn on the heading's line
// and several under it, and a list longer than `moves_drawn` counts the rest.
fn move_lines(status: Status) -> List(String) {
  case status.moves {
    [] -> []
    [only] -> ["MOVES      1 in flight: " <> move_text(status, only)]
    many -> {
      let shown = list.take(many, moves_drawn)
      let rest = list.length(many) - list.length(shown)
      list.flatten([
        ["MOVES      " <> int.to_string(list.length(many)) <> " in flight"],
        list.map(shown, fn(each) { "           " <> move_text(status, each) }),
        case rest {
          0 -> []
          more -> ["           and " <> int.to_string(more) <> " more"]
        },
      ])
    }
  }
}

// One move: the session, where it goes from and to, how long it has waited and
// why. The session is cut to eight characters as the scopes' are.
fn move_text(status: Status, move: Move) -> String {
  sessions_short(move.session)
  <> " "
  <> short(named(status.nodes, status.self))
  <> " -> "
  <> short(named(status.nodes, move.to))
  <> ", "
  <> clean(move.phase)
  <> case move.stalled_ms {
    Some(ms) -> " " <> age_text(ms)
    None -> ""
  }
  <> case move.reason {
    Some(words) -> ", " <> clean(words)
    None -> ""
  }
}

// What a reply about one node carries beyond the table: each node's build and
// uptime, its scopes and ledger, its workspaces, each scope that needs a release
// with the command that frees it, an orchestrator's placements and its moves.
fn detail_sections(status: Status) -> List(String) {
  list.filter_map(status.nodes, fn(node) {
    case detail_lines(status, node) {
      [] -> Error(Nil)
      lines ->
        Ok(string.join(
          [short(node.name) <> " (" <> clean(node.node) <> ")", ..lines],
          "\n",
        ))
    }
  })
}

fn detail_lines(status: Status, node: Node) -> List(String) {
  list.flatten([
    case node.build_version, node.build_commit {
      None, None -> []
      version, commit -> [
        "  build "
        <> dash(version)
        <> " "
        <> dash(commit)
        <> case node.uptime_ms {
          Some(ms) -> ", up " <> age_text(ms)
          None -> ""
        },
      ]
    },
    case node.executor {
      Some(facts) -> executor_lines(facts)
      None -> []
    },
    case node.orchestrator {
      Some(facts) -> orchestrator_lines(status, facts)
      None -> []
    },
  ])
}

fn executor_lines(facts: ExecutorFacts) -> List(String) {
  list.flatten([
    [
      "  scopes: "
      <> int.to_string(facts.open)
      <> " open, "
      <> int.to_string(facts.closing)
      <> " closing, "
      <> int.to_string(facts.closed_clean)
      <> " closed clean, "
      <> int.to_string(facts.closed_unknown)
      <> " closed unknown; "
      <> int.to_string(held(facts))
      <> " of "
      <> int.to_string(facts.scope_limit)
      <> " held, "
      <> int.to_string(int.max(0, facts.scope_limit - held(facts)))
      <> " free",
    ],
    case facts.ledger_bytes, facts.ledger_limit {
      Some(held), Some(limit) -> [
        "  ledger: "
        <> bytes_text(held)
        <> " of "
        <> bytes_text(limit)
        <> case facts.unacknowledged {
          Some(count) -> ", " <> int.to_string(count) <> " unacknowledged"
          None -> ""
        },
      ]
      _, _ -> []
    },
    case facts.platform {
      Some(label) -> ["  platform: " <> clean(label)]
      None -> []
    },
    case facts.contradiction {
      Some(words) -> ["  census: " <> clean(words)]
      None -> []
    },
    case facts.workspaces {
      [] -> []
      names -> ["  workspaces: " <> string.join(list.map(names, clean), ", ")]
    },
    list.flat_map(facts.unclean, fn(scope) {
      [
        "  needs release: "
          <> clean(scope.session)
          <> ", "
          <> unclean_words(scope),
        "    run on that executor: loomd executor release "
          <> clean(scope.session),
      ]
    }),
  ])
}

fn unclean_words(scope: Unclean) -> String {
  case scope.state, scope.count {
    "unknown_cleanup", Some(1) -> "1 child not proven gone"
    "unknown_cleanup", Some(count) ->
      int.to_string(count) <> " children not proven gone"
    "closing", _ -> "closing"
    other, _ -> clean(other)
  }
}

fn orchestrator_lines(
  status: Status,
  facts: OrchestratorFacts,
) -> List(String) {
  list.flatten([
    [
      "  slots: "
      <> int.to_string(facts.occupied)
      <> " of "
      <> int.to_string(facts.capacity)
      <> " held, "
      <> int.to_string(facts.resident)
      <> " resident",
    ],
    list.map(facts.placements, fn(each) {
      "  placed on "
      <> short(named(status.nodes, each.executor_node))
      <> ": "
      <> int.to_string(each.resident)
      <> " resident, "
      <> int.to_string(each.saved)
      <> " saved"
    }),
    list.map(list.take(facts.moves, moves_drawn), fn(each) {
      "  move: "
      <> sessions_short(each.session)
      <> " to "
      <> short(named(status.nodes, each.to))
      <> ", "
      <> clean(each.phase)
      <> case each.stalled_ms {
        Some(ms) -> " " <> age_text(ms)
        None -> ""
      }
      <> case each.reason {
        Some(words) -> ", " <> clean(words)
        None -> ""
      }
    }),
  ])
}

// A byte count in the largest unit that keeps it above one.
fn bytes_text(bytes: Int) -> String {
  case bytes {
    n if n >= 1_073_741_824 -> int.to_string(n / 1_073_741_824) <> " GiB"
    n if n >= 1_048_576 -> int.to_string(n / 1_048_576) <> " MiB"
    n if n >= 1024 -> int.to_string(n / 1024) <> " KiB"
    n -> int.to_string(n) <> " B"
  }
}

// The membership ledger as the asking daemon sees it: its head, how many members
// have reported that entry, and for each member the newest entry it reported and
// how long ago. A member that has not reported to this daemon is drawn as such
// and not as behind, because the daemon only knows what it was told. The age is
// the daemon's own clock, so two readings of one deployment never compare ages
// from different machines.
fn ledger_text(found: Ledger) -> String {
  let holding =
    list.count(found.members, fn(member) {
      case member.reported {
        Some(seq) -> seq >= found.head_seq
        None -> False
      }
    })
  let head =
    "LEDGER entry "
    <> int.to_string(found.head_seq)
    <> " ("
    <> clean(found.head_id)
    <> "), "
    <> int.to_string(holding)
    <> " of "
    <> int.to_string(list.length(found.members))
    <> " members hold it"
  let standing = case found.standing {
    "ok" -> []
    other -> ["this daemon is " <> clean(other) <> " in the ledger"]
  }
  let rows = case found.members {
    [] -> []
    members -> [
      table(
        ["MEMBER", "HOLDS", "REPORTED"],
        list.map(members, fn(member) { member_row(found, member) }),
      ),
    ]
  }
  let refusal = case found.last_refusal {
    None -> []
    Some(refused) -> [
      "last refusal: "
      <> case refused.seq {
        Some(seq) -> "entry " <> int.to_string(seq) <> ", "
        None -> ""
      }
      <> "step "
      <> clean(refused.step),
    ]
  }
  string.join(list.flatten([[head], standing, rows, refusal]), "\n")
}

fn member_row(found: Ledger, member: LedgerMember) -> List(String) {
  let #(holds, behind) = case member.reported {
    None -> #("-", "not reported")
    Some(seq) if seq >= found.head_seq -> #(
      "entry " <> int.to_string(seq),
      "current",
    )
    Some(seq) -> #(
      "entry " <> int.to_string(seq),
      "behind by " <> int.to_string(found.head_seq - seq),
    )
  }
  let age = case member.age_ms {
    Some(ms) -> ", " <> age_text(ms) <> " ago"
    None -> ""
  }
  [short(member.name), holds, behind <> age]
}

// An age in the unit a reader reads at a glance.
fn age_text(ms: Int) -> String {
  case ms {
    ms if ms < 60_000 -> int.to_string(ms / 1000) <> "s"
    ms if ms < 3_600_000 -> int.to_string(ms / 60_000) <> "m"
    ms -> int.to_string(ms / 3_600_000) <> "h"
  }
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

// Why the executor is not simply ready: the node's reason when it is down, how
// many scopes it has free when it is full or degraded, then the contradiction
// between its census and its declaration, when it has one.
fn note(status: Status, executor: Executor) -> String {
  let down =
    list.find(status.nodes, fn(node) {
      node.node == executor.node && node.state == NodeDown
    })
    |> result.map(fn(node) { option.unwrap(node.reason, "down") })
    |> option.from_result
  let free = case executor.state, executor.free_scopes {
    PlacementFull, Some(count) | PlacementDegraded, Some(count) ->
      Some(int.to_string(count) <> " scopes free")
    PlacementFull, None
    | PlacementDegraded, None
    | PlacementReady, _
    | PlacementDown, _
    -> None
  }
  let words =
    [down, free, executor.contradiction]
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

/// The orchestrators a session placed on `executor` could move to, read from
/// the `orchestrators` member of a `deployment.status` reply and judged by the
/// rule the web home shares (`session_view/move_candidates`). The reply names an
/// orchestrator, whether the asking daemon reached it (`state`), whether it
/// accepts moved sessions (`imports`) and the executors it serves, by the asking
/// daemon's keys, which is how a session's executor is named too.
///
/// An orchestrator whose reply leaves out `imports` or `serves` gave no report
/// the rule can judge, as does a reply trimmed to fit one frame. A reply with no
/// `orchestrators` member at all comes from a daemon built before the member
/// existed, and is an `Error` so the terminal says so and not that nothing could
/// take the session.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = deployment_view.candidates(json.Object([]), Some("box"))
/// ```
pub fn candidates(
  document: JsonValue,
  executor: Option(String),
) -> Result(List(move_candidates.Candidate), String) {
  use self <- result.try(text_at(document, "self"))
  use found <- result.map(
    required_list(document, "orchestrators", offer(_, self)),
  )
  move_candidates.choose(option.values(found), executor)
}

// One orchestrator of the reply as an offer, or none for the asking daemon: a
// session does not move to the orchestrator it is on. The daemon leaves itself
// out of the member already, so this is the client holding the daemon to it.
fn offer(
  value: JsonValue,
  self: String,
) -> Result(Option(move_candidates.Offer), String) {
  use node <- result.try(text_at(value, "node"))
  case node == self {
    True -> Ok(None)
    False -> offer_of(value) |> result.map(Some)
  }
}

fn offer_of(value: JsonValue) -> Result(move_candidates.Offer, String) {
  use name <- result.try(text_at(value, "name"))
  use state <- result.try(text_at(value, "state"))
  let facts = case
    state,
    optional_text(value, "imports"),
    field(value, "serves")
  {
    "down", _, _ -> move_candidates.Silent
    _, None, _ | _, _, Error(_) -> move_candidates.Unreported
    _, Some(imports), Ok(_) ->
      move_candidates.Reported(
        receives: case imports {
          "receiving" -> move_candidates.Receiving
          _ -> move_candidates.NotReceiving
        },
        serves: optional_list(value, "serves", text),
      )
  }
  Ok(move_candidates.Offer(name, facts))
}

/// The candidates as the lines `loom sessions move <id>` prints when it is given
/// no destination: the command that moves the session to the first orchestrator
/// that could take it, or the words that none could, and then each orchestrator
/// with the reason it cannot when it cannot. Every name is drawn through
/// `text_hygiene.single_line`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment_view.candidates_text("0198", [])
///   == "no orchestrator is configured to move 0198 to"
/// ```
pub fn candidates_text(
  session: String,
  candidates: List(move_candidates.Candidate),
) -> String {
  case candidates {
    [] -> "no orchestrator is configured to move " <> session <> " to"
    _ -> {
      let lead = case move_candidates.eligible(candidates) {
        [] -> move_candidates.none_words()
        [first, ..] ->
          "move with: loom sessions move "
          <> session
          <> " --to "
          <> text_hygiene.single_line(first)
      }
      let lines =
        list.map(candidates, fn(candidate) {
          let name = text_hygiene.single_line(candidate.name)
          case candidate.eligibility {
            move_candidates.Eligible -> "  " <> name <> "  can take it"
            move_candidates.Ineligible(reason:) ->
              "  " <> name <> "  " <> move_candidates.reason_words(reason)
          }
        })
      string.join([lead, "orchestrators:", ..lines], "\n")
    }
  }
}
