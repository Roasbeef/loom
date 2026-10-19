//// What the Admin page knows of the owner's machines (protocol-change/085, the
//// addendum of 2026-10-16): the vocabulary the daemon and the page agree on, and
//// the total decoder that turns the daemon's `deployment.status` document into it.
////
//// The daemon already builds that document for `loom deployment status`: every
//// node it is configured with, what each said of itself, the links among them,
//// and, on a daemon that runs from a membership ledger, the ledger's members. The
//// Admin page draws a list of machines from it and, for the machine the owner
//// chooses, a page of its own. This module is the page's half. It holds the types
//// both halves use, reads the document without trusting it, and words the facts
//// the views draw.
////
//// ## One list, two sources
////
//// A machine comes from one of two places. A node the daemon is configured to
//// dial is `Dialled`: the document says whether it answered and what it
//// reported. A member of the ledger that the daemon is not linked to has no row
//// in the daemon's configuration, so the daemon never dials it, and the page
//// marks it `NotLinkedFromHere`. It is still on the list, because the ledger is
//// the deployment's membership and an owner who revokes a member needs to see the
//// ones this daemon cannot reach. `decode_overview` merges the two by the node
//// name, which the ledger and the configuration both hold.
////
//// ## What is read, and what is never drawn as anything but text
////
//// Every name, key, node, platform, toolchain, reason and session identity in the
//// document is another daemon's or the operator's configuration. The views draw
//// each as a text node and build no class, attribute or key from it. The classes
//// they use come from the closed types here: a state, a link, a standing. A
//// certificate pin is the lower-case hex digest of a public certificate and is
//// kept only when it is exactly sixty-four such digits.
////
//// ## Decoding is total and bounded
////
//// A document that is not shaped as expected is an `Error` with a reason, never a
//// crash. Only the members the protocol requires are required: `self`, `state`
//// and `nodes`, and for each node its `node`, `name`, `roles` and `state`. Every
//// other member is read when it is present and well formed and left out when it
//// is not, so a later daemon can add members without this reading failing. A text
//// longer than `text_limit` bytes or an empty one is not text, and a list longer
//// than `list_limit` is cut, or refused where the document needs the whole list.
////
//// ## Flow
////
//// `decode_overview` → `decode_detail` → `verdict_words` → `age_words`
////
//// 1. `decode_overview` reads the whole-deployment document into a `Snapshot`.
////    It reads the nodes, merges the ledger's members into the machines, and
////    reads the links, the directory and the moves.
//// 2. `decode_detail` reads the document a read for one node returns, which
////    carries that node's long lists.
//// 3. `verdict_words` is the first line of the Deployment section, and `age_words`
////    words the time since a report.

import core/json.{type JsonValue}
import core/json_wire
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The longest text the decoder accepts for any member, in bytes.
pub const text_limit = 256

/// The most entries the decoder accepts in any list.
pub const list_limit = 128

/// The state of a node as the daemon judged it, and of the deployment as a
/// whole.
pub type State {
  /// The node answered and no reason applies.
  Healthy

  /// The node answered, and one or more reasons apply.
  Degraded

  /// The node did not answer.
  Down
}

/// What a node does for the deployment.
pub type Role {
  /// It owns sessions.
  Orchestrator

  /// It serves workspaces.
  Executor

  /// It is a member of the session directory's cluster.
  Member
}

/// Whether the asking daemon's connection to a node exists.
pub type Link {
  /// The asking daemon is connected to it.
  Linked

  /// The asking daemon tried and is not connected.
  Unlinked

  /// The asking daemon has no connection to observe: the node is the asking
  /// daemon itself, or the document stated no link.
  Unobserved
}

/// Whether a node is the asking daemon.
pub type Whose {
  /// It is the daemon whose Admin page this is.
  This

  /// It is another node.
  Other
}

/// Whether an orchestrator accepts sessions moved to it.
pub type Imports {
  /// It does.
  Receiving

  /// It does not.
  NotReceiving
}

/// Whether a directory member knows its own copy is current.
pub type Copy {
  /// It confirmed the copy.
  Current

  /// It could not confirm the copy.
  Unconfirmed
}

/// The counts of an executor's scopes.
pub type Scopes {
  Scopes(
    /// Scopes admitting calls.
    open: Int,
    /// Scopes fenced while their live work is cancelled.
    closing: Int,
    /// Scopes closed with every child retired.
    closed_clean: Int,
    /// Scopes closed without proof that every child is gone.
    closed_unknown: Int,
  )
}

/// What an executor reported about its machine and its scopes.
pub type ExecutorFacts {
  ExecutorFacts(
    /// The scope counts.
    scopes: Scopes,
    /// The most scopes it admits that are not cleanly closed.
    scope_limit: Int,
    /// The platform label it reported, as `<os>/<architecture>`.
    platform: Option(String),
    /// The sandbox enforcement it observed, `enforced` or `degraded`.
    enforcement: Option(String),
    /// The toolchains it observed.
    toolchains: List(String),
    /// The words saying its census contradicts its operator's declaration.
    contradiction: Option(String),
  )
}

/// What an orchestrator reported about its capacity.
pub type OrchestratorFacts {
  OrchestratorFacts(
    /// The most simultaneous runtime reservations.
    capacity: Int,
    /// The reservations held now.
    occupied: Int,
    /// The usable resident sessions.
    resident: Int,
    /// Whether it accepts sessions moved to it.
    imports: Option(Imports),
    /// How many moves it has in flight.
    moves_in_flight: Int,
  )
}

/// What a dialled node said of itself.
pub type Findings {
  Findings(
    /// The daemon's judgement.
    state: State,
    /// The fixed words that say why a node is degraded.
    reasons: List(String),
    /// The fixed word that says why a node is down.
    why: Option(String),
    /// The build version it reported.
    build_version: Option(String),
    /// The build commit it reported.
    build_commit: Option(String),
    /// Milliseconds since it started, by its own clock.
    uptime_ms: Option(Int),
    /// The wire protocol version an executor speaks.
    protocol: Option(Int),
    /// What it reported as an orchestrator, when it is one.
    orchestrator: Option(OrchestratorFacts),
    /// What it reported as an executor, when it is one.
    executor: Option(ExecutorFacts),
  )
}

/// A node's seat in the session directory, as the ledger records it.
pub type Seat {
  /// It votes.
  Voter

  /// It replicates the directory and does not vote.
  Learner

  /// It is not a directory member.
  NoSeat
}

/// One active member of the membership ledger (protocol-change/086).
pub type Standing {
  Standing(
    /// The member's plan name, which `renew` and `revoke` name it by.
    name: String,
    /// The role the ledger gave it.
    role: Role,
    /// Its seat in the directory.
    seat: Seat,
    /// The sequence number of the newest entry it reported to the asking daemon.
    reported_seq: Option(Int),
    /// Milliseconds on the asking daemon's clock since that report.
    age_ms: Option(Int),
    /// The plan names of the members it is linked to.
    links: List(String),
    /// The hex SHA-256 of its leaf certificate, when the daemon stated it.
    pin: Option(String),
  )
}

/// Where a machine stands in the membership ledger.
pub type Ledgered {
  /// It is an active member.
  Enrolled(standing: Standing)

  /// The daemon runs from a ledger and the node is not an active member of it.
  NotListed

  /// The daemon runs without a ledger, so there is no standing to state.
  Unledgered
}

/// How this daemon knows a machine.
pub type Here {
  /// The daemon is configured to dial it, and this is what it found.
  Dialled(findings: Findings)

  /// The ledger lists it and this daemon's configuration does not, so the daemon
  /// never dials it.
  NotLinkedFromHere
}

/// One machine of the list.
pub type Machine {
  Machine(
    /// The asking daemon's key for the machine, the plan name for a ledger
    /// member the daemon does not hold, or the node name when it has neither.
    name: String,
    /// The full node name.
    node: String,
    /// What the machine does.
    roles: List(Role),
    /// Whether the machine is the asking daemon.
    whose: Whose,
    /// How the daemon knows it.
    here: Here,
    /// The asking daemon's connection to it.
    link: Link,
    /// Its standing in the ledger.
    ledgered: Ledgered,
  )
}

/// A relation between two nodes that the asking daemon reported.
pub type Relation {
  /// An orchestrator places sessions on an executor: how many.
  Serves(sessions: Int)

  /// Two orchestrators exchange mail and moves.
  Peers

  /// Two nodes are members of the session directory's cluster.
  Members
}

/// An edge of the graph of machines.
pub type Edge {
  Edge(
    from: String,
    to: String,
    relation: Relation,
    /// The asking daemon's own connection to the other end, when the edge has
    /// the asking daemon at one end.
    link: Link,
  )
}

/// The phase of a move in flight.
pub type Phase {
  /// It is running.
  Running

  /// It is waiting.
  Waiting
}

/// A move of a session to another orchestrator that is in flight.
pub type Move {
  Move(
    /// The session being moved.
    session: String,
    /// The destination, as the asking daemon names it.
    to: String,
    /// The phase.
    phase: Phase,
    /// Milliseconds since the move stalled, when it has.
    stalled_ms: Option(Int),
    /// Why the last run stopped, when it did.
    reason: Option(String),
  )
}

/// What the asking daemon says of its ledger.
pub type Ledger {
  Ledger(
    /// The sequence number of the newest entry the daemon holds.
    head_seq: Int,
    /// The daemon's own plan name, which a new member's `--links` names.
    self_name: String,
  )
}

/// The session directory as the asking daemon sees it.
pub type Directory {
  Directory(
    /// Whether the daemon's own copy is known to be current.
    copy: Option(Copy),
  )
}

/// What the whole-deployment read gave.
pub type Snapshot {
  Snapshot(
    /// The asking daemon's wall clock when it built the reply, in Unix
    /// milliseconds, when stated.
    as_of_ms: Option(Int),
    /// The deployment as the daemon judged it.
    state: State,
    /// The machines: the asking daemon first, then the nodes it dials, then the
    /// ledger's members it does not.
    machines: List(Machine),
    /// The relations among the dialled nodes.
    edges: List(Edge),
    /// The asking daemon's ledger, when it runs from one.
    ledger: Option(Ledger),
    /// The asking daemon's directory, when it is a member.
    directory: Option(Directory),
    /// The moves the asking daemon has in flight.
    moves: List(Move),
    /// What the daemon left out to fit one frame, by name.
    omitted: List(String),
  )
}

/// A scope on an executor that blocks a reopen.
pub type Unclean {
  Unclean(
    /// The session the scope belongs to.
    session: String,
    /// How the scope is stuck.
    stuck: Stuck,
  )
}

/// How an unclean scope is stuck.
pub type Stuck {
  /// Its close never finished.
  Closing

  /// It closed without proof that every child is gone: how many.
  UnknownCleanup(count: Option(Int))
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

/// What a read for one machine gave: its long lists.
pub type Detail {
  Detail(
    /// The node the read was for.
    node: String,
    /// The registered workspace names, for an executor.
    workspaces: List(String),
    /// The scopes that block a reopen, for an executor.
    unclean: List(Unclean),
    /// The sessions the machine has placed, for an orchestrator.
    placements: List(Placed),
    /// The moves the machine has in flight, for an orchestrator.
    moves: List(Move),
    /// The lists the daemon cut to fit one frame, by name.
    more: List(String),
  )
}

/// What the daemon answers to a read of the deployment.
pub type Reading {
  /// The whole deployment.
  Heard(snapshot: Snapshot)

  /// One machine's long lists.
  HeardOne(detail: Detail)

  /// The daemon could not ask, or what it asked returned a document the page does
  /// not understand. The page keeps what it has.
  Unread
}

/// What the page holds of the deployment.
pub type Held {
  /// No read has answered yet.
  NothingYet

  /// A read answered, and no later read has failed.
  Known(snapshot: Snapshot)

  /// The last read failed, and `kept` is the one before it if there was one.
  Failed(kept: Option(Snapshot))
}

/// What the page holds of the chosen machine's long lists.
pub type Detailed {
  /// The read is out.
  Awaiting

  /// The read answered.
  Detailed(detail: Detail)

  /// The page has none: the read failed, or the machine is the asking daemon or
  /// one it does not dial, whose long lists the daemon does not read.
  Withheld
}

/// The snapshot a held deployment stands on, if it stands on one.
///
/// ## Examples
///
/// ```gleam
/// assert machines.snapshot_of(machines.NothingYet) == None
/// ```
pub fn snapshot_of(held: Held) -> Option(Snapshot) {
  case held {
    NothingYet -> None
    Known(snapshot:) -> Some(snapshot)
    Failed(kept:) -> kept
  }
}

/// The machine a node names in a snapshot.
///
/// ## Examples
///
/// ```gleam
/// assert machines.find(snapshot, "ghost@nowhere") == Error(Nil)
/// ```
pub fn find(snapshot: Snapshot, node: String) -> Result(Machine, Nil) {
  list.find(snapshot.machines, fn(each) { each.node == node })
}

/// The tab a machine's page shows.
pub type Tab {
  /// Health, build and links.
  OverviewTab

  /// The sessions the machine holds or serves.
  SessionsTab

  /// The machine's place in the ledger and the commands that change it.
  AccessTab

  /// Scope counts, unclean scopes and moves.
  ActivityTab
}

/// The word on a tab.
///
/// ## Examples
///
/// ```gleam
/// assert machines.tab_words(machines.AccessTab) == "Access"
/// ```
pub fn tab_words(tab: Tab) -> String {
  case tab {
    OverviewTab -> "Overview"
    SessionsTab -> "Sessions"
    AccessTab -> "Access"
    ActivityTab -> "Activity"
  }
}

/// The tabs in the order they are drawn.
pub const tabs = [OverviewTab, SessionsTab, AccessTab, ActivityTab]

// --- decoding -------------------------------------------------------------------

/// Reads a whole-deployment `deployment.status` document.
///
/// `self`, `state` and `nodes` are required, and each node needs its `node`,
/// `name`, `roles` and `state`. A state outside the protocol's words is an
/// `Error`, because a page that guessed would draw a health verdict the daemon did
/// not give. A ledger that does not decode is left out and the rest is drawn.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = machines.decode_overview(json.Object([]))
/// ```
pub fn decode_overview(document: JsonValue) -> Result(Snapshot, String) {
  use self <- result.try(text_at(document, "self"))
  use state <- result.try(state_at(document, "state"))
  use nodes <- result.try(required_list(document, "nodes", node))
  let edges = optional_list(document, "edges", edge)
  let held = field(document, "ledger") |> option.from_result
  Ok(Snapshot(
    as_of_ms: optional_count(document, "as_of_ms"),
    state:,
    machines: merge(
      self,
      nodes,
      edges,
      option.map(held, optional_list(_, "members", member)),
    ),
    edges:,
    ledger: held
      |> option.then(fn(found) { ledger(found) |> option.from_result }),
    directory: field(document, "directory")
      |> result.try(directory)
      |> option.from_result,
    moves: optional_list(document, "moves", move),
    omitted: optional_list(document, "omitted", text),
  ))
}

/// Reads the document a read for one node returns, from the node it is for.
///
/// The document holds that one node among `nodes`, and its long lists are inside
/// the node's `executor` and `orchestrator` members. A document with no such node
/// is an `Error`.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = machines.decode_detail(json.Object([]))
/// ```
pub fn decode_detail(document: JsonValue) -> Result(Detail, String) {
  use nodes <- result.try(required_list(document, "nodes", raw_node))
  use found <- result.map(
    list.first(nodes) |> result.replace_error("nodes is empty"),
  )
  let executor = field(found.1, "executor") |> result.unwrap(json.Null)
  let orchestrator = field(found.1, "orchestrator") |> result.unwrap(json.Null)
  Detail(
    node: found.0,
    workspaces: optional_list(executor, "workspaces", text),
    unclean: optional_list(executor, "unclean", unclean),
    placements: optional_list(orchestrator, "placements", placed),
    moves: optional_list(orchestrator, "moves", move),
    more: optional_list(document, "more", text),
  )
}

// A node of a one-node reply: its name and the member itself, whose long lists
// the caller reads.
fn raw_node(value: JsonValue) -> Result(#(String, JsonValue), String) {
  use node <- result.map(text_at(value, "node"))
  #(node, value)
}

// The machines: the nodes the daemon dials, with the ledger's standing of each,
// then the ledger's members that no node accounts for. The asking daemon comes
// first, as the document lists it. `members` is `None` for a daemon that runs
// without a ledger.
fn merge(
  self: String,
  nodes: List(Node),
  edges: List(Edge),
  members: Option(List(#(String, Standing))),
) -> List(Machine) {
  let dialled =
    list.map(nodes, fn(each) {
      Machine(
        name: each.name,
        node: each.node,
        roles: each.roles,
        whose: case each.node == self {
          True -> This
          False -> Other
        },
        here: Dialled(findings: each.findings),
        link: link_of(self, each.node, edges),
        ledgered: standing_of(each.node, members),
      )
    })
  let unlinked =
    members
    |> option.unwrap([])
    |> list.filter(fn(held) {
      !list.any(nodes, fn(each) { each.node == held.0 })
    })
    |> list.map(fn(held) {
      Machine(
        name: { held.1 }.name,
        node: held.0,
        roles: [{ held.1 }.role],
        whose: Other,
        here: NotLinkedFromHere,
        link: Unobserved,
        ledgered: Enrolled(standing: held.1),
      )
    })
  list.append(dialled, unlinked)
}

fn standing_of(
  node: String,
  members: Option(List(#(String, Standing))),
) -> Ledgered {
  case members {
    None -> Unledgered
    Some(held) ->
      case list.key_find(held, node) {
        Ok(found) -> Enrolled(standing: found)
        Error(Nil) -> NotListed
      }
  }
}

// The asking daemon's connection to a node: the link on the edge that joins the
// two, which is the only edge whose link the daemon can observe. The asking
// daemon has none to itself.
fn link_of(self: String, node: String, edges: List(Edge)) -> Link {
  let joining =
    list.find(edges, fn(each) {
      each.link != Unobserved
      && {
        { each.from == self && each.to == node }
        || { each.from == node && each.to == self }
      }
    })
  case node == self, joining {
    True, _ | False, Error(Nil) -> Unobserved
    False, Ok(Edge(link:, ..)) -> link
  }
}

fn directory(value: JsonValue) -> Result(Directory, String) {
  use _members <- result.map(required_list(value, "members", text))
  Directory(copy: case optional_text(value, "copy") {
    Some("current") -> Some(Current)
    Some("unconfirmed") -> Some(Unconfirmed)
    Some(_) | None -> None
  })
}

fn ledger(value: JsonValue) -> Result(Ledger, String) {
  use head <- result.try(field(value, "head"))
  use head_seq <- result.try(count_at(head, "seq"))
  use own <- result.try(field(value, "self"))
  use self_name <- result.map(text_at(own, "name"))
  Ledger(head_seq:, self_name:)
}

fn member(value: JsonValue) -> Result(#(String, Standing), String) {
  use name <- result.try(text_at(value, "name"))
  use node <- result.try(text_at(value, "node"))
  use role <- result.try(text_at(value, "role") |> result.try(role_word))
  Ok(#(
    node,
    Standing(
      name:,
      role:,
      seat: case optional_text(value, "directory") {
        Some("voter") -> Voter
        Some("learner") -> Learner
        Some(_) | None -> NoSeat
      },
      reported_seq: optional_count(value, "reported_seq"),
      age_ms: optional_count(value, "ms_since_report"),
      links: optional_list(value, "links", text),
      pin: optional_text(value, "pin") |> option.then(hex_pin),
    ),
  ))
}

// A pin is sixty-four lower-case hexadecimal digits, and nothing else is kept.
fn hex_pin(word: String) -> Option(String) {
  case
    string.drop_start(word, 64) == ""
    && string.drop_start(word, 63) != ""
    && list.all(string.to_graphemes(word), string.contains(
      "0123456789abcdef",
      _,
    ))
  {
    True -> Some(word)
    False -> None
  }
}

// A node of the document before it is merged with the ledger.
type Node {
  Node(node: String, name: String, roles: List(Role), findings: Findings)
}

fn node(value: JsonValue) -> Result(Node, String) {
  use node <- result.try(text_at(value, "node"))
  use name <- result.try(text_at(value, "name"))
  use roles <- result.try(
    required_list(value, "roles", fn(each) {
      text(each) |> result.try(role_word)
    }),
  )
  use state <- result.map(state_at(value, "state"))
  Node(
    node:,
    name:,
    roles:,
    findings: Findings(
      state:,
      reasons: optional_list(value, "reasons", text),
      why: optional_text(value, "reason"),
      build_version: optional_text(value, "build_version"),
      build_commit: optional_text(value, "build_commit"),
      uptime_ms: optional_count(value, "uptime_ms"),
      protocol: optional_count(value, "protocol"),
      orchestrator: field(value, "orchestrator")
        |> result.try(orchestrator_facts)
        |> option.from_result,
      executor: field(value, "executor")
        |> result.try(executor_facts)
        |> option.from_result,
    ),
  )
}

fn orchestrator_facts(value: JsonValue) -> Result(OrchestratorFacts, String) {
  use capacity <- result.try(count_at(value, "capacity"))
  use occupied <- result.try(count_at(value, "occupied"))
  use resident <- result.map(count_at(value, "resident"))
  OrchestratorFacts(
    capacity:,
    occupied:,
    resident:,
    imports: case optional_text(value, "imports") {
      Some("receiving") -> Some(Receiving)
      Some("not_receiving") -> Some(NotReceiving)
      Some(_) | None -> None
    },
    moves_in_flight: optional_count(value, "moves_in_flight")
      |> option.unwrap(0),
  )
}

fn executor_facts(value: JsonValue) -> Result(ExecutorFacts, String) {
  use scopes <- result.try(field(value, "scopes"))
  use open <- result.try(count_at(scopes, "open"))
  use closing <- result.try(count_at(scopes, "closing"))
  use closed_clean <- result.try(count_at(scopes, "closed_clean"))
  use closed_unknown <- result.try(count_at(scopes, "closed_unknown"))
  use scope_limit <- result.map(count_at(value, "scope_limit"))
  ExecutorFacts(
    scopes: Scopes(open:, closing:, closed_clean:, closed_unknown:),
    scope_limit:,
    platform: optional_text(value, "platform"),
    enforcement: optional_text(value, "enforcement"),
    toolchains: optional_list(value, "toolchains", text),
    contradiction: optional_text(value, "contradiction"),
  )
}

fn edge(value: JsonValue) -> Result(Edge, String) {
  use from <- result.try(text_at(value, "from"))
  use to <- result.try(text_at(value, "to"))
  use kind <- result.try(text_at(value, "kind"))
  use relation <- result.map(case kind {
    "serves" ->
      Ok(Serves(sessions: optional_count(value, "sessions") |> option.unwrap(0)))
    "peer" -> Ok(Peers)
    "member" -> Ok(Members)
    _ -> Error("unknown relation")
  })
  Edge(from:, to:, relation:, link: case optional_text(value, "link") {
    Some("connected") -> Linked
    Some("none") -> Unlinked
    Some(_) | None -> Unobserved
  })
}

fn move(value: JsonValue) -> Result(Move, String) {
  use session <- result.try(text_at(value, "session_id"))
  use to <- result.try(text_at(value, "to"))
  use phase <- result.try(text_at(value, "phase"))
  use phase <- result.map(case phase {
    "running" -> Ok(Running)
    "waiting" -> Ok(Waiting)
    _ -> Error("unknown phase")
  })
  Move(
    session:,
    to:,
    phase:,
    stalled_ms: optional_count(value, "stalled_ms"),
    reason: optional_text(value, "reason"),
  )
}

fn unclean(value: JsonValue) -> Result(Unclean, String) {
  use session <- result.try(text_at(value, "session"))
  use state <- result.try(text_at(value, "state"))
  use stuck <- result.map(case state {
    "closing" -> Ok(Closing)
    "unknown_cleanup" ->
      Ok(UnknownCleanup(count: optional_count(value, "count")))
    _ -> Error("unknown scope state")
  })
  Unclean(session:, stuck:)
}

fn placed(value: JsonValue) -> Result(Placed, String) {
  use executor_node <- result.try(text_at(value, "executor_node"))
  use resident <- result.try(count_at(value, "resident"))
  use saved <- result.map(count_at(value, "saved"))
  Placed(executor_node:, resident:, saved:)
}

fn role_word(word: String) -> Result(Role, String) {
  case word {
    "orchestrator" -> Ok(Orchestrator)
    "executor" -> Ok(Executor)
    "member" -> Ok(Member)
    _ -> Error("unknown role")
  }
}

fn state_at(value: JsonValue, key: String) -> Result(State, String) {
  use word <- result.try(text_at(value, key))
  case word {
    "ok" -> Ok(Healthy)
    "degraded" -> Ok(Degraded)
    "down" -> Ok(Down)
    _ -> Error("unknown state")
  }
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  json_wire.field(value, key)
}

fn text(value: JsonValue) -> Result(String, String) {
  json_wire.bounded_text(value, text_limit)
}

fn text_at(value: JsonValue, key: String) -> Result(String, String) {
  json_wire.text_at(value, key, text_limit)
}

fn optional_text(value: JsonValue, key: String) -> Option(String) {
  json_wire.optional_text_at(value, key, text_limit)
}

fn count_at(value: JsonValue, key: String) -> Result(Int, String) {
  json_wire.count_at(value, key)
}

fn optional_count(value: JsonValue, key: String) -> Option(Int) {
  json_wire.optional_count_at(value, key)
}

// A list the document must have. Its entries must each decode, and it may not
// outgrow `list_limit`, because the daemon bounds a reply and the page holds it
// to the bound.
fn required_list(
  value: JsonValue,
  key: String,
  read: fn(JsonValue) -> Result(a, String),
) -> Result(List(a), String) {
  use found <- result.try(field(value, key))
  case found {
    json.Array(items) ->
      case list.drop(items, list_limit) == [] {
        True -> list.try_map(items, read)
        False -> Error(key <> " is longer than expected")
      }
    _ -> Error(key <> " is not a list")
  }
}

// A list the document may leave out. Absent or malformed reads as none, a list
// longer than the limit is cut, and an entry that does not decode is skipped.
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

// --- words ----------------------------------------------------------------------

/// The first line of the Deployment section: how many machines there are and how
/// many of them need a look. A degraded or down machine, and one the daemon does
/// not dial, are counted apart, because each sends the owner to a different
/// place.
///
/// ## Examples
///
/// ```gleam
/// assert machines.verdict_words([]) == "Deployment · no machines"
/// ```
pub fn verdict_words(machines: List(Machine)) -> String {
  let degraded = count_where(machines, is_state(_, Degraded))
  let down = count_where(machines, is_state(_, Down))
  let unlinked = count_where(machines, is_unlinked)
  let counts =
    list.flatten([
      counted(degraded, "degraded"),
      counted(down, "down"),
      counted(unlinked, "not linked from here"),
    ])
  case machines {
    [] -> "Deployment · no machines"
    [_, ..] ->
      "Deployment · "
      <> plural(list.length(machines), "node", "nodes")
      <> " · "
      <> case counts {
        [] -> "all ok"
        _ -> string.join(counts, " · ")
      }
  }
}

fn counted(count: Int, word: String) -> List(String) {
  case count {
    0 -> []
    _ -> [int.to_string(count) <> " " <> word]
  }
}

fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> "1 " <> one
    _ -> int.to_string(count) <> " " <> many
  }
}

fn count_where(machines: List(Machine), keep: fn(Machine) -> Bool) -> Int {
  list.count(machines, keep)
}

fn is_state(machine: Machine, wanted: State) -> Bool {
  case machine.here {
    Dialled(findings: Findings(state:, ..)) -> state == wanted
    NotLinkedFromHere -> False
  }
}

fn is_unlinked(machine: Machine) -> Bool {
  case machine.here {
    NotLinkedFromHere -> True
    Dialled(..) -> False
  }
}

/// The state of a machine for its pill, or none for one the daemon does not dial.
///
/// ## Examples
///
/// ```gleam
/// assert machines.state_of(machine) == Some(machines.Healthy)
/// ```
pub fn state_of(machine: Machine) -> Option(State) {
  case machine.here {
    Dialled(findings: Findings(state:, ..)) -> Some(state)
    NotLinkedFromHere -> None
  }
}

/// The pill tint for a state, from the three the page already has for a
/// connection, so no colour is added.
///
/// ## Examples
///
/// ```gleam
/// assert machines.pill_class(machines.Degraded) == "pending"
/// ```
pub fn pill_class(state: State) -> String {
  case state {
    Healthy -> "online"
    Degraded -> "pending"
    Down -> "ended"
  }
}

/// The word a state is drawn as.
///
/// ## Examples
///
/// ```gleam
/// assert machines.state_words(machines.Down) == "down"
/// ```
pub fn state_words(state: State) -> String {
  case state {
    Healthy -> "ok"
    Degraded -> "degraded"
    Down -> "down"
  }
}

/// The word a role is drawn as.
///
/// ## Examples
///
/// ```gleam
/// assert machines.role_words(machines.Executor) == "executor"
/// ```
pub fn role_words(role: Role) -> String {
  case role {
    Orchestrator -> "orchestrator"
    Executor -> "executor"
    Member -> "directory member"
  }
}

/// A sentence for one of the fixed words the daemon gives as a reason a node is
/// degraded or down. A word this page does not know is drawn as it came, as
/// text, so a later daemon's reason is still shown.
///
/// ## Examples
///
/// ```gleam
/// assert machines.reason_words("timeout") == "did not answer in time"
/// ```
pub fn reason_words(word: String) -> String {
  case word {
    "unclean_scope" ->
      "a scope is stuck closing or closed with unknown cleanup; only an operator's release frees it"
    "full" -> "every scope it admits that is not cleanly closed is held"
    "declaration_contradicted" ->
      "what it reports about its machine disagrees with its configured row"
    "build_differs" -> "it runs another build than this daemon"
    "protocol_differs" -> "it speaks another wire protocol version"
    "directory_no_leader" -> "the directory cannot name a leader"
    "directory_copy_unconfirmed" ->
      "it could not confirm that its copy of the directory is current"
    "directory_quorum_lost" ->
      "fewer of the directory's voters answered than a majority"
    "timeout" -> "did not answer in time"
    "silent" -> "connected, but no orchestrator port answered"
    "unreachable" -> "refused the connection or could not be reached"
    "unavailable" -> "this daemon has no distribution to connect with"
    other -> other
  }
}

/// How long ago something was, from the milliseconds since: seconds under a
/// minute, then minutes, hours and days.
///
/// ## Examples
///
/// ```gleam
/// assert machines.age_words(412_000) == "6 min ago"
/// ```
pub fn age_words(ms: Int) -> String {
  let seconds = int.max(ms, 0) / 1000
  case seconds {
    _ if seconds < 5 -> "just now"
    _ if seconds < 60 -> int.to_string(seconds) <> " s ago"
    _ if seconds < 3600 -> int.to_string(seconds / 60) <> " min ago"
    _ if seconds < 86_400 -> int.to_string(seconds / 3600) <> " h ago"
    _ -> int.to_string(seconds / 86_400) <> " d ago"
  }
}

/// How long a node has been up, from its own clock's uptime in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert machines.uptime_words(90_000_000) == "1 d 1 h"
/// ```
pub fn uptime_words(ms: Int) -> String {
  let minutes = int.max(ms, 0) / 60_000
  case minutes {
    _ if minutes < 1 -> "under a minute"
    _ if minutes < 60 -> int.to_string(minutes) <> " min"
    _ if minutes < 1440 ->
      int.to_string(minutes / 60)
      <> " h "
      <> int.to_string(minutes % 60)
      <> " min"
    _ ->
      int.to_string(minutes / 1440)
      <> " d "
      <> int.to_string(minutes % 1440 / 60)
      <> " h"
  }
}
