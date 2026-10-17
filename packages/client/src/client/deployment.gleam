//// What this daemon can say about the machines it is configured to use
//// (protocol-change/085, the `deployment.status` control command).
////
//// An operator who has written `[executors.<name>]`, `[pools.<name>]` and
//// `[orchestrators.<name>]` tables has no way to ask whether any of those
//// machines answers until a session is placed on one and its open fails. This
//// module is the read that answers it before then. It combines the daemon's
//// own configuration with two things the daemon can establish by asking: whether
//// its connection to each configured node succeeded, and what the node says of
//// itself when asked for its report (`client/node_report`).
////
//// ## What a statement means
////
//// Every statement is "as seen from this daemon". A node is `down` when this
//// daemon did not connect to it, or connected and did not receive its report,
//// within the bounds below, and the reply gives a fixed reason word. A node that
//// answered is `ok`, or `degraded` with one or more fixed reason words
//// (`classify`). Nothing is cached and nothing is remembered between asks: a
//// node that did not answer is `down` in this reply and the next ask connects
//// again. A link between two other nodes is not observable from here, so a link
//// state appears only on an edge that touches the asking daemon.
////
//// The deployment as a whole is `ok` when every configured node is, `down` only
//// when none answered, and `degraded` between (`verdict`). One dead executor
//// among several is a degraded deployment, not a dead one, and a node that
//// answered with reasons of its own counts as reachable and not `ok`.
////
//// ## What the daemon says of itself
////
//// The asking daemon is never connected to. It reports itself through the
//// closure `Reach.own`, in the same weft run as the asks, so a slow directory
//// read costs its own facts and never the facts of another node. Its report
//// classifies the other nodes (is their build the same as its own) and supplies
//// the directory block and the moves in flight, which are the asking daemon's
//// and no one else's.
////
//// ## The one rule about names
////
//// The daemon connects only to nodes named in its own configuration. The
//// `node` filter of the command is a key of that configuration, resolved by
//// `only` before anything is dialled, so a name taken from a request body never
//// reaches the connection layer. A filter that names nothing configured
//// connects to nobody. A directory member the daemon does not configure as an
//// orchestrator or an executor is named in the directory block and is not
//// dialled.
////
//// ## The creation panel
////
//// The owner's home page draws a card for each executor and pool when the form
//// for a registered workspace opens (protocol-change/085). `placed` is the read
//// it makes: the same connection attempts and report asks, to the executors
//// alone, and the same placements `status` reports. `for_page` reduces them to
//// what the page may know (`web_view/placements`), which is a state, a free
//// scope count, a contradiction, a declaration and a trial order, and no node
//// name.
////
//// ## Flow
////
//// `status` → `targets` → `only` → `survey` → `fan_out` → `judged` →
//// `overview` or `selected` → `to_json`
////
//// 1. `status` is the whole read. It lists the configured nodes with
////    `targets`, narrows them with `only` when the request named one, and
////    hands them to `survey`.
//// 2. `survey` runs `fan_out`: one weft run in which the asking daemon reports
////    itself and every target is connected to and then asked for its report.
////    Each connection is bounded at one second, each ask at one second after it,
////    and the whole run at three. Outcomes come back in the order of the
////    targets.
//// 3. `judged` gives each answering node the reasons `classify` finds and the
////    asking daemon the directory reason `quorum` finds.
//// 4. `overview` and `selected` are pure: they turn the judged nodes and the
////    configuration into a `Snapshot`, with the edges `edges_of` derives and the
////    placements a session-creation form draws from, and `to_json` renders it.

import client/directory/member
import client/directory/store
import client/distribution
import client/executors.{type Executor}
import client/internal/ffi_khepri
import client/node_report.{type NodeReport}
import client/orchestrators.{type Orchestrator}
import client/pools.{type Pool}
import client/remote/address
import client/remote/orchestrator_port
import client/remote/protocol
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import host/build_identity
import web_view/placements as page
import weft

/// How long one connection attempt may take. A first TLS handshake to a loaded
/// machine can outlast it; the handshake goes on in the background, so the node
/// reads `down` in this reply and `ok` in the next.
pub const connect_ms = 1000

/// How long a node may take to give its report once connected. A node that
/// connected and did not report in time reads `down` with the reason `timeout`.
pub const report_ms = 1000

/// The bound on the whole fan-out. The two inner bounds sum to two seconds, so
/// this is slack for scheduling and for the tasks the deadline abandons rather
/// than a sum.
pub const deadline_ms = 3000

/// Why a configured node is down. The words are fixed so a client can show
/// them without interpreting a diagnostic.
pub type Why {
  /// The connection did not settle within `connect_ms`, or the node connected
  /// and its report did not arrive within `report_ms`.
  TimedOut

  /// The connection was refused or the host could not be reached. A refused
  /// certificate, a wrong pin and a wrong node name all read this way.
  Unreachable

  /// This daemon has no distribution to connect with, or the node is not one
  /// it pinned.
  Unavailable
}

/// The wire word for a reason.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.why_word(deployment.TimedOut) == "timeout"
/// ```
pub fn why_word(why: Why) -> String {
  case why {
    TimedOut -> "timeout"
    Unreachable -> "unreachable"
    Unavailable -> "unavailable"
  }
}

/// How one node is connected to: the node name from this daemon's own
/// configuration and the time to wait. It is the only way the module opens a
/// connection, held as a function so a test can supply the answers.
pub type Dial =
  fn(String, Int) -> Result(Nil, Why)

/// How a connected node is asked for its report: the node name and the time to
/// wait. `Error(Nil)` is silence, as `orchestrator_port.ask_report` defines it.
pub type Ask =
  fn(String, Int) -> Result(NodeReport, Nil)

/// What the daemon asks with: its own node name, which the reply is "as seen
/// from", how it connects, how it asks a connected node for its report, and how
/// it reports itself.
pub type Reach {
  Reach(
    /// The asking daemon's node name.
    self: String,
    /// Connects to a configured node.
    dial: Dial,
    /// Asks a connected node for its report.
    ask: Ask,
    /// Builds the asking daemon's own report. It is not a connection: the
    /// daemon reads its own executor host, movers, catalogue and directory
    /// member through the closure `Reads.report` of the orchestrator port.
    own: fn() -> NodeReport,
  )
}

// The report of a daemon that has been given no way to read itself: who it is
// and which build, with no orchestrator, executor or directory facts.
fn unreported(self: String) -> fn() -> NodeReport {
  fn() {
    let identity = build_identity.current()
    node_report.bare(
      node: self,
      build_version: identity.version,
      build_commit: identity.commit,
      epoch: "",
      started_ms: 0,
      now_ms: 0,
    )
  }
}

/// The reach of a daemon with no distribution: it names itself and connects to
/// nobody, so every configured node it were given would read `down`. A daemon
/// without a `[distribution]` table has no peers, so in practice it is asked
/// about none.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.alone("nonode@nohost").self == "nonode@nohost"
/// ```
pub fn alone(self: String) -> Reach {
  Reach(
    self:,
    dial: fn(_node, _within_ms) { Error(Unavailable) },
    ask: fn(_node, _within_ms) { Error(Nil) },
    own: unreported(self),
  )
}

/// The production reach: the daemon connects to a pinned peer over the
/// distribution it started, with `distribution.connect`'s own bounded wait, and
/// asks the orchestrator port of the connected node for its report. A name the
/// membership does not know cannot be resolved to a node, so it reads
/// `unavailable` and creates nothing. The reach reports only who the daemon is
/// until `reporting` gives it the closure that reads the rest.
///
/// ## Examples
///
/// ```gleam
/// // let reach = deployment.over(membership, "alpha@10.0.0.1")
/// ```
pub fn over(membership: distribution.Membership, self: String) -> Reach {
  Reach(
    self:,
    dial: fn(node, within_ms) {
      use peer <- result.try(
        distribution.peer(membership, node)
        |> result.replace_error(Unavailable),
      )
      distribution.connect(peer, within_ms) |> result.map_error(why_of)
    },
    ask: fn(node, within_ms) {
      use peer <- result.try(
        distribution.peer(membership, node) |> result.replace_error(Nil),
      )
      orchestrator_port.ask_report(
        address.Address(
          node: distribution.node(peer),
          name: orchestrator_port.default(),
        ),
        within_ms,
      )
    },
    own: unreported(self),
  )
}

/// The same reach with the closure that builds the asking daemon's own report.
/// The daemon holds that closure only after its services have started, which is
/// later than the reach is first needed, so it is given here and not to `over`.
///
/// ## Examples
///
/// ```gleam
/// // deployment.reporting(deployment.alone(node), fn() { report })
/// ```
pub fn reporting(reach: Reach, own: fn() -> NodeReport) -> Reach {
  Reach(..reach, own:)
}

// A fault of the connection layer reduced to the three words a client shows.
// Only a late handshake and an unreachable peer are connection outcomes; every
// other fault means this daemon could not try, which is `unavailable`.
fn why_of(fault: distribution.Fault) -> Why {
  case fault {
    distribution.TimedOut -> TimedOut
    distribution.Unavailable -> Unreachable
    distribution.InvalidConfiguration
    | distribution.UnsafeBoot(_)
    | distribution.InvalidCredentials
    | distribution.EpmdUnavailable(_)
    | distribution.StartFailed -> Unavailable
  }
}

/// What a node does for the deployment.
pub type Role {
  /// It owns sessions: the asking daemon, or an `[orchestrators.<name>]`.
  OrchestratorRole

  /// It serves workspaces: an `[executors.<name>]`.
  ExecutorRole

  /// It is a member of the session directory's Khepri cluster.
  MemberRole
}

/// The wire word for a role.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.role_word(deployment.ExecutorRole) == "executor"
/// ```
pub fn role_word(role: Role) -> String {
  case role {
    OrchestratorRole -> "orchestrator"
    ExecutorRole -> "executor"
    MemberRole -> "member"
  }
}

/// Why a node that answered is not simply `ok`. The words are fixed so that a
/// client shows them without interpreting a diagnostic, and there are no
/// near-limit thresholds: scope counts and ledger bytes are reported as numbers
/// and a person reads them.
pub type Reason {
  /// A scope that blocks a reopen exists: closing, or closed with unknown
  /// cleanup. Only an operator's `loomd executor release` frees its slot.
  UncleanScope

  /// The scopes that are not cleanly closed are at the limit, so the next
  /// attach is refused.
  Full

  /// The executor's census disagrees with its `[executors.<name>]` row.
  DeclarationContradicted

  /// The node runs another build than the asking daemon.
  BuildDiffers

  /// The executor speaks another wire protocol version than the asking daemon.
  ProtocolDiffers

  /// A directory member cannot name a leader.
  DirectoryNoLeader

  /// A directory member could not confirm that its own copy is current.
  DirectoryCopyUnconfirmed

  /// Fewer of the directory's voters answered the asking daemon than a
  /// majority.
  DirectoryQuorumLost
}

/// The wire word for a reason.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.reason_word(deployment.UncleanScope) == "unclean_scope"
/// ```
pub fn reason_word(reason: Reason) -> String {
  case reason {
    UncleanScope -> "unclean_scope"
    Full -> "full"
    DeclarationContradicted -> "declaration_contradicted"
    BuildDiffers -> "build_differs"
    ProtocolDiffers -> "protocol_differs"
    DirectoryNoLeader -> "directory_no_leader"
    DirectoryCopyUnconfirmed -> "directory_copy_unconfirmed"
    DirectoryQuorumLost -> "directory_quorum_lost"
  }
}

/// What this daemon found when it asked a node.
pub type Health {
  /// The node answered and no reason applies.
  Reachable

  /// The node answered and one or more reasons apply.
  Impaired(reasons: List(Reason))

  /// The node did not answer, and why.
  Down(why: Why)
}

/// The wire word for a node's state: `ok`, `degraded` or `down`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.state_word(deployment.Reachable) == "ok"
/// ```
pub fn state_word(health: Health) -> String {
  case health {
    Reachable -> "ok"
    Impaired(..) -> "degraded"
    Down(_) -> "down"
  }
}

/// One node of the reply.
pub type Node {
  Node(
    /// The full node name.
    node: String,
    /// The asking daemon's key for the node, such as `box` for
    /// `[executors.box]`, or the node name when the daemon has no key for it,
    /// as for itself.
    name: String,
    /// What the node does. The asking daemon is an orchestrator, and a member
    /// when it is in the directory's cluster.
    roles: List(Role),
    /// What the connection attempt and the report found.
    health: Health,
    /// What the node said of itself, or `None` when it did not say: it is
    /// down, or the asking daemon's own sources did not answer.
    report: Option(NodeReport),
    /// The `[executors.<name>]` row the asking daemon holds for the node, which
    /// a census is compared with. `None` for anything that is not an executor
    /// row.
    declared: Option(Executor),
  )
}

/// Which of the daemon's tables a configured node comes from.
pub type Kind {
  /// An `[orchestrators.<name>]` row.
  OrchestratorRow

  /// An `[executors.<name>]` row.
  ExecutorRow
}

/// A configured node the daemon may connect to: an orchestrator or an executor
/// from its own tables, and the only kind of node it ever dials.
pub type Target {
  Target(
    /// The configuration key.
    name: String,
    /// The node name the key resolves to.
    node: String,
    /// The table the key is in.
    kind: Kind,
    /// The executor row, for an executor.
    declared: Option(Executor),
  )
}

/// The nodes this daemon is configured to use: its orchestrators, then its
/// executors, each in the order its table lists them (by name).
///
/// ## Examples
///
/// ```gleam
/// assert deployment.targets([], []) == []
/// ```
pub fn targets(
  orchestrators: List(Orchestrator),
  executors: List(Executor),
) -> List(Target) {
  list.append(
    list.map(orchestrators, fn(each) {
      Target(
        name: each.name,
        node: each.node,
        kind: OrchestratorRow,
        declared: None,
      )
    }),
    list.map(executors, fn(each) {
      Target(
        name: each.name,
        node: each.node,
        kind: ExecutorRow,
        declared: Some(each),
      )
    }),
  )
}

/// The targets whose configuration key is `key`, or `Error(Nil)` when no table
/// has it. A key is looked up among the configured targets and never turned into
/// a node name, which is what keeps a request from choosing whom the daemon
/// connects to.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.only([], "ghost") == Error(Nil)
/// ```
pub fn only(
  configured: List(Target),
  key: String,
) -> Result(List(Target), Nil) {
  case list.filter(configured, fn(target) { target.name == key }) {
    [] -> Error(Nil)
    found -> Ok(found)
  }
}

/// What the asking daemon learned of one target: the health its connection and
/// ask gave it, before any reason is judged, and the report it received.
pub type Probed {
  Probed(
    /// The configured node asked.
    target: Target,
    /// `Reachable` when the report arrived, and `Down` otherwise.
    health: Health,
    /// The report, when one arrived.
    report: Option(NodeReport),
  )
}

/// Whether the asking daemon's own report is read in the same run.
pub type Reading {
  /// Read the daemon's own report too, for a whole-deployment read.
  WithSelf

  /// Ask the targets and nothing else, as the creation panel does.
  WithoutSelf
}

/// Connects to every target at once, asks each connected one for its report, and
/// returns what each found in the order of the targets.
///
/// The attempts run in one weft run so that a slow node costs the reply at most
/// `deadline_ms`, and the run's deadline kills and joins any attempt still
/// waiting. A task the deadline cut off, one that never started and one whose
/// drain proof was lost told the daemon nothing, and a node nothing was heard
/// from is `down` rather than assumed up.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.probe(deployment.alone("alpha@10.0.0.1"), []) == []
/// ```
pub fn probe(reach: Reach, targets: List(Target)) -> List(Probed) {
  fan_out(reach, targets, WithoutSelf).1
}

// One weft run holding the asking daemon's own report, when it is read, and
// then one connect-and-ask for each target. Putting the daemon's own report
// first lets the outcomes be split without a lookup, and the daemon's slow
// sources then cost only their own facts.
fn fan_out(
  reach: Reach,
  targets: List(Target),
  reading: Reading,
) -> #(Option(NodeReport), List(Probed)) {
  case targets, reading {
    [], WithoutSelf -> #(None, [])
    _, _ -> {
      let asks =
        list.map(targets, fn(target) {
          let node = target.node
          fn() { learn(reach, node) }
        })
      let tasks = case reading {
        WithSelf -> [fn() { Ok(reach.own()) }, ..asks]
        WithoutSelf -> asks
      }
      let outcomes =
        tasks
        |> weft.new
        |> weft.deadline(deadline_ms)
        |> weft.start
      let #(own, rest) = case reading, outcomes {
        WithSelf, [first, ..rest] -> #(report_of(first), rest)
        WithSelf, [] | WithoutSelf, _ -> #(None, outcomes)
      }
      #(
        own,
        list.map2(targets, rest, fn(target, outcome) {
          probed_of(target, outcome)
        }),
      )
    }
  }
}

// A node is connected to, and only then asked. A node that connected and did
// not report in time is as good as down for the asking daemon, which can say
// nothing of it, so the silence reads as a timeout.
fn learn(reach: Reach, node: String) -> Result(NodeReport, Why) {
  use Nil <- result.try(reach.dial(node, connect_ms))
  reach.ask(node, report_ms) |> result.replace_error(TimedOut)
}

fn report_of(outcome: weft.Outcome(NodeReport, Why)) -> Option(NodeReport) {
  case outcome {
    weft.Completed(value:, ..) -> Some(value)
    weft.Failed(..)
    | weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> None
  }
}

// A task that returns `Error(why)` is a `Failed` outcome carrying `why`, so the
// reason a connection gave comes through the run unchanged.
fn probed_of(target: Target, outcome: weft.Outcome(NodeReport, Why)) -> Probed {
  case outcome {
    weft.Completed(value:, ..) ->
      Probed(target:, health: Reachable, report: Some(value))
    weft.Failed(error: why, ..) ->
      Probed(target:, health: Down(why), report: None)
    weft.Crashed(..) -> Probed(target:, health: Down(Unavailable), report: None)
    weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) ->
      Probed(target:, health: Down(TimedOut), report: None)
  }
}

// --- classification ---------------------------------------------------------------

/// The reasons a node that answered is not simply `ok`, as seen from the asking
/// daemon. It is a pure function of the two reports and the executor row, and
/// it runs on the asking daemon so that every client shows one verdict.
///
/// A node with no report has no reasons, because there is nothing to judge. A
/// build is compared only when the asking daemon has a report of its own, and the
/// wire protocol version is compared with the asking daemon's constant, so a
/// daemon that could not read itself still notices an executor on another
/// protocol. The eighth word, `DirectoryQuorumLost`, is a statement about every
/// node at once and comes from `quorum`.
///
/// ## Examples
///
/// ```gleam
/// // deployment.classify(asker, box) == [deployment.UncleanScope]
/// ```
pub fn classify(asker: Node, node: Node) -> List(Reason) {
  list.filter(
    [
      UncleanScope,
      Full,
      DeclarationContradicted,
      BuildDiffers,
      ProtocolDiffers,
      DirectoryNoLeader,
      DirectoryCopyUnconfirmed,
    ],
    fn(reason) { applies(reason, asker, node) },
  )
}

// Whether one reason holds of a node, from its report. `DirectoryQuorumLost`
// never holds of one node alone, so `quorum` states it instead.
fn applies(reason: Reason, asker: Node, node: Node) -> Bool {
  case node.report {
    None -> False
    Some(report) ->
      case reason {
        UncleanScope ->
          executor_holds(report, fn(facts) {
            facts.scopes.closing + facts.scopes.closed_unknown > 0
          })
        Full -> executor_holds(report, fn(facts) { free_scopes(facts) == 0 })
        DeclarationContradicted ->
          executor_holds(report, fn(facts) {
            option.is_some(contradiction_of(node.declared, facts))
          })
        ProtocolDiffers ->
          executor_holds(report, fn(facts) {
            facts.protocol != protocol.version
          })
        BuildDiffers ->
          case asker.report {
            Some(own) ->
              own.build_version != report.build_version
              || own.build_commit != report.build_commit
            None -> False
          }
        DirectoryNoLeader ->
          directory_holds(report, fn(facts) {
            case facts.status.ra {
              Ok(membership) -> option.is_none(membership.leader)
              Error(_) -> True
            }
          })
        DirectoryCopyUnconfirmed ->
          directory_holds(report, fn(facts) {
            facts.copy == node_report.Unconfirmed
          })
        DirectoryQuorumLost -> False
      }
  }
}

fn executor_holds(
  report: NodeReport,
  holds: fn(node_report.ExecutorFacts) -> Bool,
) -> Bool {
  case report.executor {
    Some(facts) -> holds(facts)
    None -> False
  }
}

fn directory_holds(
  report: NodeReport,
  holds: fn(node_report.DirectoryFacts) -> Bool,
) -> Bool {
  case report.directory {
    Some(facts) -> holds(facts)
    None -> False
  }
}

/// How many more scopes an executor admits: its limit less the scopes that are
/// not cleanly closed, which are the open ones and the ones that block a
/// reopen. An open scope holds a slot as an unclean one does.
///
/// ## Examples
///
/// ```gleam
/// // deployment.free_scopes(facts) == 12
/// ```
pub fn free_scopes(facts: node_report.ExecutorFacts) -> Int {
  let held =
    facts.scopes.open + facts.scopes.closing + facts.scopes.closed_unknown
  int.max(0, facts.scope_limit - held)
}

/// Whether the asking daemon, a directory member, reached fewer of the
/// directory's voters than a majority. The asking daemon counts itself, and a
/// voter it has no connect attempt for is counted as reachable, because a voter
/// that was not asked is not one that failed to answer: the reason is stated
/// only when a majority is out of reach even if every unasked voter is up.
///
/// ## Examples
///
/// ```gleam
/// // deployment.quorum(asker, nodes) == [deployment.DirectoryQuorumLost]
/// ```
pub fn quorum(asker: Node, nodes: List(Node)) -> List(Reason) {
  let voters = case
    asker.report |> option.then(fn(report) { report.directory })
  {
    Some(facts) ->
      case facts.status.ra {
        Ok(membership) ->
          list.filter_map(membership.members, fn(entry) {
            case entry.1 {
              ffi_khepri.Voter -> Ok(entry.0)
              ffi_khepri.Promoting | ffi_khepri.NonVoter -> Error(Nil)
            }
          })
        Error(_) -> []
      }
    None -> []
  }
  let lost =
    list.count(voters, fn(voter) {
      case list.find(nodes, fn(each) { each.node == voter }) {
        Ok(Node(health: Down(_), ..)) -> voter != asker.node
        Ok(_) | Error(Nil) -> False
      }
    })
  let majority = list.length(voters) / 2 + 1
  case voters {
    [] -> []
    [_, ..] ->
      case list.length(voters) - lost < majority {
        True -> [DirectoryQuorumLost]
        False -> []
      }
  }
}

// Gives each answering node the reasons `classify` finds, and the asking daemon
// its own: the reasons that concern a directory member, and the quorum, which
// only the asking daemon can state.
fn judged(asker: Node, nodes: List(Node)) -> #(Node, List(Node)) {
  let reasoned = fn(node: Node, extra: List(Reason)) {
    case node.health {
      Down(_) -> node
      Reachable | Impaired(_) ->
        case list.append(classify(asker, node), extra) {
          [] -> Node(..node, health: Reachable)
          reasons -> Node(..node, health: Impaired(reasons:))
        }
    }
  }
  #(
    reasoned(asker, quorum(asker, nodes)),
    list.map(nodes, fn(node) { reasoned(node, []) }),
  )
}

// --- the survey ---------------------------------------------------------------------

// The asking daemon and every target, judged. The directory members are the
// nodes the asking daemon's own cluster view lists and the nodes whose own report
// says they are members.
fn survey(
  reach: Reach,
  roles: List(Role),
  targets: List(Target),
  reading: Reading,
) -> #(Node, List(Node)) {
  let #(own, probed) = fan_out(reach, targets, reading)
  let members = member_nodes(own, probed)
  let asker =
    Node(
      node: reach.self,
      name: reach.self,
      roles:,
      health: Reachable,
      report: own,
      declared: None,
    )
  judged(asker, list.map(probed, fn(found) { node_of(found, members) }))
}

// The nodes known to be directory members: those the asking daemon's cluster
// view lists, and those whose own report carries directory facts.
fn member_nodes(own: Option(NodeReport), probed: List(Probed)) -> List(String) {
  let listed = case own |> option.then(fn(report) { report.directory }) {
    Some(facts) -> facts.status.members
    None -> []
  }
  let reporting =
    list.filter_map(probed, fn(found) {
      case found.report |> option.then(fn(report) { report.directory }) {
        Some(_) -> Ok(found.target.node)
        None -> Error(Nil)
      }
    })
  list.append(listed, reporting)
}

fn node_of(found: Probed, members: List(String)) -> Node {
  let target = found.target
  let member = case list.contains(members, target.node) {
    True -> [MemberRole]
    False -> []
  }
  Node(
    node: target.node,
    name: target.name,
    roles: [role_of(target.kind), ..member],
    health: found.health,
    report: found.report,
    declared: target.declared,
  )
}

fn role_of(kind: Kind) -> Role {
  case kind {
    OrchestratorRow -> OrchestratorRole
    ExecutorRow -> ExecutorRole
  }
}

/// How one node relates to the asking daemon.
pub type Relation {
  /// An orchestrator places sessions on the executor, and `sessions` is how many
  /// of its sessions are placed there, resident or saved.
  Serves(sessions: Int)

  /// The asking daemon and the orchestrator can exchange mail and moves.
  Peers

  /// The node is a member of the session directory's cluster with the asking
  /// daemon, and this is its standing there.
  Member(voter: Vote, leader: Leadership)
}

/// Whether a directory member votes.
pub type Vote {
  /// It is a voter.
  Voting

  /// It replicates the log and does not vote.
  NonVoting
}

/// Whether a directory member is the cluster's leader.
pub type Leadership {
  /// It is the leader.
  Leading

  /// It is not.
  Following
}

/// Whether the asking daemon's connection to the other end exists.
pub type Link {
  /// The connection attempt succeeded.
  Connected

  /// It did not.
  Unlinked
}

/// A relation between two nodes. The link state is present only on an edge that
/// has the asking daemon at one end, because that is the only end whose link it
/// can observe.
pub type Edge {
  Edge(
    /// The node the relation starts at.
    from: String,
    /// The node it ends at.
    to: String,
    /// What the relation is.
    relation: Relation,
    /// The asking daemon's own connection to the other end, when the edge
    /// touches the asking daemon.
    link: Option(Link),
  )
}

/// What a card for an executor shows: the configured row, what the connection
/// found, and what the executor reported.
pub type ExecutorEntry {
  ExecutorEntry(
    /// The configured executor, with its declared platform, enforcement and
    /// toolchains.
    executor: Executor,
    /// What the connection and the report found.
    health: Health,
    /// What the executor reported, when it did.
    report: Option(NodeReport),
  )
}

/// What a card for a pool shows. A pool names executors in a trial order and
/// may require a declaration of them; the daemon does not reorder it by health,
/// so the order here is the order a first open tries.
pub type PoolEntry {
  PoolEntry(
    /// The `[pools.<name>]` key.
    name: String,
    /// The executors the pool admits, in the order `pools.candidates` returns
    /// them. A listed executor whose declaration the pool's requirements
    /// reject is not here.
    executors: List(String),
    /// Those of `executors` that could take a session now, in the same order:
    /// neither down nor full.
    eligible: List(String),
  )
}

/// The places a session may be created, with the state of each.
pub type Placements {
  Placements(executors: List(ExecutorEntry), pools: List(PoolEntry))
}

/// What `status` answers.
pub type Snapshot {
  /// The whole deployment as seen from the asking daemon.
  Overview(
    /// The asking daemon.
    self: Node,
    /// Its configured orchestrators, then its executors.
    others: List(Node),
    /// The asking daemon's relation to each configured node, and what the
    /// orchestrators report of theirs.
    edges: List(Edge),
    /// The executors and pools a session may be placed on.
    placements: Placements,
  )

  /// The nodes one configuration key names, and nothing about the rest. The
  /// asking daemon is not among them.
  Selected(self: String, nodes: List(Node))
}

/// Reads the deployment: connects to every configured node, or to the ones
/// `node` names, asks each for its report, and describes what answered.
///
/// `Error(Nil)` means `node` names nothing in the configuration, and in that case
/// nothing was dialled.
///
/// ## Examples
///
/// ```gleam
/// let reach = deployment.alone("alpha@10.0.0.1")
/// let assert Ok(deployment.Overview(self:, others: [], ..)) =
///   deployment.status(reach, [deployment.OrchestratorRole], [], [], [], None)
/// assert self.node == "alpha@10.0.0.1"
/// ```
///
/// ```gleam
/// let reach = deployment.alone("alpha@10.0.0.1")
/// assert deployment.status(reach, [], [], [], [], Some("ghost")) == Error(Nil)
/// ```
pub fn status(
  reach: Reach,
  roles: List(Role),
  orchestrators: List(Orchestrator),
  executors: List(Executor),
  pools: List(Pool),
  node: Option(String),
) -> Result(Snapshot, Nil) {
  let configured = targets(orchestrators, executors)
  case node {
    None -> {
      let #(asker, nodes) = survey(reach, roles, configured, WithSelf)
      Ok(overview(asker, nodes, executors, pools))
    }
    Some(key) -> {
      use named <- result.map(only(configured, key))
      let #(_asker, nodes) = survey(reach, roles, named, WithSelf)
      selected(reach.self, nodes)
    }
  }
}

/// The overview of a deployment, given the asking daemon and the nodes it
/// judged.
///
/// ## Examples
///
/// ```gleam
/// let asker = deployment.Node("alpha@10.0.0.1", "alpha@10.0.0.1", [], deployment.Reachable, None, None)
/// let assert deployment.Overview(others: [], edges: [], ..) =
///   deployment.overview(asker, [], [], [])
/// ```
pub fn overview(
  asker: Node,
  nodes: List(Node),
  executors: List(Executor),
  pools: List(Pool),
) -> Snapshot {
  Overview(
    self: asker,
    others: nodes,
    edges: edges_of(asker, nodes),
    placements: placements(executors, pools, nodes),
  )
}

/// The reply to a request that named one configuration key.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.selected("alpha@10.0.0.1", [])
///   == deployment.Selected("alpha@10.0.0.1", [])
/// ```
pub fn selected(self: String, nodes: List(Node)) -> Snapshot {
  Selected(self:, nodes:)
}

// The relations of the overview. The asking daemon's own come first, each with
// its link, in the order of the nodes: serves for an executor, peer for an
// orchestrator. Then what each answering orchestrator reports it serves, which
// has no link because the asking daemon cannot observe it, and the asking
// daemon's directory members.
fn edges_of(asker: Node, nodes: List(Node)) -> List(Edge) {
  list.flatten([
    list.map(nodes, fn(node) { own_edge(asker, node) }),
    list.flat_map(nodes, fn(node) { reported_serves(node, nodes) }),
    member_edges(asker, nodes),
  ])
}

fn own_edge(asker: Node, node: Node) -> Edge {
  Edge(
    from: asker.node,
    to: node.node,
    relation: case list.contains(node.roles, ExecutorRole) {
      True -> Serves(sessions: placed_on(asker.report, node.node))
      False -> Peers
    },
    link: Some(case node.health {
      Down(_) -> Unlinked
      Reachable | Impaired(_) -> Connected
    }),
  )
}

// The sessions an orchestrator says it has placed on an executor, resident or
// saved, or none when it says nothing of that executor.
fn placed_on(report: Option(NodeReport), executor: String) -> Int {
  case report |> option.then(fn(found) { found.orchestrator }) {
    Some(facts) ->
      list.find(facts.placements, fn(each) { each.executor_node == executor })
      |> result.map(fn(each) { each.resident + each.saved })
      |> result.unwrap(0)
    None -> 0
  }
}

// What a reachable orchestrator says it serves, for the executors the asking
// daemon also knows. An executor the asking daemon has no node for is not drawn,
// so the picture holds the nodes the reply lists and no others.
fn reported_serves(node: Node, nodes: List(Node)) -> List(Edge) {
  case node.report |> option.then(fn(report) { report.orchestrator }) {
    None -> []
    Some(facts) ->
      list.filter_map(facts.executor_nodes, fn(executor) {
        case list.any(nodes, fn(each) { each.node == executor }) {
          True ->
            Ok(Edge(
              from: node.node,
              to: executor,
              relation: Serves(sessions: placed_on(node.report, executor)),
              link: None,
            ))
          False -> Error(Nil)
        }
      })
  }
}

// The asking daemon's directory members, one edge each from the asking daemon,
// so that the link it observed is the edge's. Only members the reply lists are
// drawn.
fn member_edges(asker: Node, nodes: List(Node)) -> List(Edge) {
  let membership = case asker.report |> option.then(fn(r) { r.directory }) {
    Some(facts) -> option.from_result(facts.status.ra)
    None -> None
  }
  case membership {
    None -> []
    Some(found) ->
      list.filter_map(found.members, fn(entry) {
        case list.find(nodes, fn(each) { each.node == entry.0 }) {
          Error(Nil) -> Error(Nil)
          Ok(node) ->
            Ok(Edge(
              from: asker.node,
              to: node.node,
              relation: Member(
                voter: case entry.1 {
                  ffi_khepri.Voter -> Voting
                  ffi_khepri.Promoting | ffi_khepri.NonVoter -> NonVoting
                },
                leader: case found.leader == Some(entry.0) {
                  True -> Leading
                  False -> Following
                },
              ),
              link: Some(case node.health {
                Down(_) -> Unlinked
                Reachable | Impaired(_) -> Connected
              }),
            ))
        }
      })
  }
}

/// The executors and pools a session may be placed on, with the state of each,
/// without the rest of the deployment: the daemon connects to its executors and
/// to nothing else. This is the read the web page's creation panel makes when it
/// opens, which has no use for the orchestrators and should not wait on them.
///
/// ## Examples
///
/// ```gleam
/// let reach = deployment.alone("alpha@10.0.0.1")
/// assert deployment.placed(reach, [], []) == deployment.Placements([], [])
/// ```
pub fn placed(
  reach: Reach,
  executors: List(Executor),
  pools: List(Pool),
) -> Placements {
  let #(_asker, nodes) =
    survey(reach, [OrchestratorRole], targets([], executors), WithoutSelf)
  placements(executors, pools, nodes)
}

/// Placements as the home page draws them (`web_view/placements`): the page
/// learns each executor's state, its free scope count and any contradiction
/// between its census and its declaration, what its operator declared, each
/// pool's trial order and which of its executors can take a session, and no node
/// name, address or key.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.for_page(deployment.Placements([], []))
///   == page.Placements([], [])
/// ```
pub fn for_page(placed: Placements) -> page.Placements {
  page.Placements(
    executors: list.map(placed.executors, fn(entry) {
      let facts = entry.report |> option.then(fn(report) { report.executor })
      page.Executor(
        name: entry.executor.name,
        report: Some(page.Report(
          state: page_state(entry.health),
          platform: entry.executor.platform,
          enforcement: option.map(
            entry.executor.enforcement,
            executors.enforcement_word,
          ),
          toolchains: entry.executor.toolchains,
          free_scopes: option.map(facts, free_scopes),
          contradiction: option.then(facts, fn(found) {
            contradiction_of(Some(entry.executor), found)
          }),
        )),
      )
    }),
    pools: list.map(placed.pools, fn(entry) {
      page.Pool(
        name: entry.name,
        report: Some(page.PoolReport(
          executors: entry.executors,
          eligible: entry.eligible,
        )),
      )
    }),
  )
}

// The state a card for an executor shows: full when it would refuse the next
// attach, degraded when it answered with any other reason.
fn page_state(health: Health) -> page.State {
  case health {
    Reachable -> page.Ready
    Impaired(reasons:) ->
      case list.contains(reasons, Full) {
        True -> page.Full
        False -> page.Degraded
      }
    Down(_) -> page.Down
  }
}

// The words saying an executor's census contradicts its declaration, if it does.
fn contradiction_of(
  declared: Option(Executor),
  facts: node_report.ExecutorFacts,
) -> Option(String) {
  case declared, facts.observed {
    Some(row), Some(observed) ->
      case executors.contradiction(row, observed) {
        Ok(Nil) -> None
        Error(words) -> Some(words)
      }
    Some(_), None | None, Some(_) | None, None -> None
  }
}

// An executor's entry is that of its own configured node. The key is unique
// among executors, and an overview asks every executor, so a miss cannot happen
// from `status`; a caller that built `nodes` by hand and left one out gets
// `unavailable`, not an invented `ok`.
fn placements(
  executors: List(Executor),
  pools: List(Pool),
  nodes: List(Node),
) -> Placements {
  let found = fn(executor: Executor) {
    list.find(nodes, fn(node) {
      node.name == executor.name && list.contains(node.roles, ExecutorRole)
    })
    |> result.map(fn(node) { #(node.health, node.report) })
    |> result.unwrap(#(Down(Unavailable), None))
  }
  Placements(
    executors: list.map(executors, fn(executor) {
      let #(health, report) = found(executor)
      ExecutorEntry(executor:, health:, report:)
    }),
    pools: list.map(pools, fn(pool) {
      let admitted = pools.candidates(pool, executors)
      PoolEntry(
        name: pool.name,
        executors: list.map(admitted, fn(executor) { executor.name }),
        eligible: list.filter_map(admitted, fn(executor) {
          case found(executor).0 {
            Reachable -> Ok(executor.name)
            Impaired(reasons:) ->
              case list.contains(reasons, Full) {
                True -> Error(Nil)
                False -> Ok(executor.name)
              }
            Down(_) -> Error(Nil)
          }
        }),
      )
    }),
  )
}

/// How the deployment as a whole reads, from the nodes the daemon is configured
/// with. The asking daemon is not among them: it is always reachable, and counting
/// it would make a deployment whose every other node is gone read degraded
/// instead of down.
pub type Verdict {
  /// Every configured node answered with no reason, or there are none to ask.
  Whole

  /// Some configured node did not answer, or answered with reasons, and some
  /// did. One dead executor among several leaves a working deployment, so it is
  /// not a dead one.
  Degraded

  /// No configured node answered.
  Lost
}

/// The wire word for a verdict: `ok`, `degraded` or `down`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.verdict_word(deployment.Degraded) == "degraded"
/// ```
pub fn verdict_word(verdict: Verdict) -> String {
  case verdict {
    Whole -> "ok"
    Degraded -> "degraded"
    Lost -> "down"
  }
}

/// The verdict on the configured nodes: `ok` when all answered with no reason,
/// `down` only when none answered, and `degraded` for anything between. A node
/// that answered with reasons counts as reachable and not `ok`. No nodes is `ok`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.verdict([]) == deployment.Whole
/// ```
pub fn verdict(nodes: List(Node)) -> Verdict {
  let #(down, answered) = list.partition(nodes, is_down)
  let #(ok, impaired) =
    list.partition(answered, fn(node) { node.health == Reachable })
  case ok, impaired, down {
    _, [], [] -> Whole
    [], [], [_, ..] -> Lost
    _, _, _ -> Degraded
  }
}

fn is_down(node: Node) -> Bool {
  case node.health {
    Down(_) -> True
    Reachable | Impaired(_) -> False
  }
}

/// The nodes that are not `ok`, each with the word that says why: one entry for
/// a node that is down, and one for each reason of a node that is degraded.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.reasons([]) == []
/// ```
pub fn reasons(nodes: List(Node)) -> List(#(String, String)) {
  list.flat_map(nodes, fn(node) {
    case node.health {
      Reachable -> []
      Impaired(reasons:) ->
        list.map(reasons, fn(reason) { #(node.node, reason_word(reason)) })
      Down(why) -> [#(node.node, why_word(why))]
    }
  })
}

// --- rendering ------------------------------------------------------------------------

/// How much of a node's report the reply states.
pub type Detail {
  /// The numbers an overview needs.
  Brief

  /// The numbers and the long lists: workspaces, unclean scopes, placements
  /// and moves. Only a read that names one node carries them.
  Long
}

/// Renders a snapshot as the body of the `deployment.status` reply.
///
/// `as_of_ms` is the asking daemon's wall clock when the reply was built. The
/// whole deployment's `state` is the `verdict` on its configured nodes: `ok` when
/// all answered with no reason, `down` when none did and `degraded` otherwise. A
/// request that named a key gets the node with its long lists and no `edges`,
/// `placements`, `orchestrators`, `directory` or `moves`.
///
/// ## Examples
///
/// ```gleam
/// // deployment.to_json(snapshot, 1_760_190_131_000)
/// ```
pub fn to_json(snapshot: Snapshot, as_of_ms: Int) -> JsonValue {
  let #(self, nodes, asked, detail) = case snapshot {
    Overview(self:, others:, ..) -> #(
      self.node,
      [self, ..others],
      others,
      Brief,
    )
    Selected(self:, nodes:) -> #(self, nodes, nodes, Long)
  }
  let head = [
    #("as_of_ms", json.Int(as_of_ms)),
    #("self", json.String(self)),
    #("state", json.String(verdict_word(verdict(asked)))),
    #(
      "reasons",
      json.Array(
        list.map(reasons(nodes), fn(reason) {
          json.Object([
            #("node", json.String(reason.0)),
            #("reason", json.String(reason.1)),
          ])
        }),
      ),
    ),
    #(
      "nodes",
      json.Array(list.map(nodes, fn(node) { node_json(node, self, detail) })),
    ),
  ]
  case snapshot {
    Selected(..) -> json.Object(head)
    Overview(self: asker, others:, edges:, placements:) ->
      json.Object(
        list.flatten([
          head,
          [
            #("edges", json.Array(list.map(edges, edge_json))),
            #("placements", placements_json(placements)),
            #("orchestrators", orchestrators_json(others)),
          ],
          directory_member(asker),
          [#("moves", moves_json(asker, others))],
        ]),
      )
  }
}

fn node_json(node: Node, asker: String, detail: Detail) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("node", json.String(node.node)),
        #("name", json.String(node.name)),
        #(
          "roles",
          json.Array(
            list.map(node.roles, fn(role) { json.String(role_word(role)) }),
          ),
        ),
        #("state", json.String(state_word(node.health))),
      ],
      case node.health {
        Reachable -> []
        Impaired(reasons:) -> [
          #(
            "reasons",
            json.Array(
              list.map(reasons, fn(reason) { json.String(reason_word(reason)) }),
            ),
          ),
        ]
        Down(why) -> [#("reason", json.String(why_word(why)))]
      },
      case node.node == asker {
        True -> [#("self", json.Bool(True))]
        False -> []
      },
      case node.report {
        Some(report) -> report_fields(node, report, detail)
        None -> []
      },
    ]),
  )
}

// What a node said of itself, in the members the reply states. A number is
// stated as the node gave it, and the node's clock is used only for its own
// uptime, the difference of two readings of one clock.
fn report_fields(
  node: Node,
  report: NodeReport,
  detail: Detail,
) -> List(#(String, JsonValue)) {
  list.flatten([
    [
      #("build_version", json.String(report.build_version)),
      #("build_commit", json.String(report.build_commit)),
      #("uptime_ms", json.Int(int.max(0, report.now_ms - report.started_ms))),
    ],
    case report.executor {
      Some(facts) -> [#("protocol", json.Int(facts.protocol))]
      None -> []
    },
    case report.orchestrator {
      Some(facts) -> [#("orchestrator", orchestrator_json(facts, detail))]
      None -> []
    },
    case report.executor {
      Some(facts) -> [#("executor", executor_json(node, facts, detail))]
      None -> []
    },
  ])
}

fn orchestrator_json(
  facts: node_report.OrchestratorFacts,
  detail: Detail,
) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("capacity", json.Int(facts.capacity)),
        #("occupied", json.Int(facts.occupied)),
        #("resident", json.Int(facts.resident)),
        #("imports", json.String(imports_word(facts.imports))),
        #("moves_in_flight", json.Int(list.length(facts.moves))),
      ],
      case detail {
        Brief -> []
        Long -> [
          #(
            "placements",
            json.Array(
              list.map(facts.placements, fn(placement) {
                json.Object([
                  #("executor_node", json.String(placement.executor_node)),
                  #("resident", json.Int(placement.resident)),
                  #("saved", json.Int(placement.saved)),
                ])
              }),
            ),
          ),
          #("moves", json.Array(list.map(facts.moves, node_report.move_json))),
        ]
      },
    ]),
  )
}

fn imports_word(imports: node_report.Imports) -> String {
  case imports {
    node_report.Receiving -> "receiving"
    node_report.NotReceiving -> "not_receiving"
  }
}

fn executor_json(
  node: Node,
  facts: node_report.ExecutorFacts,
  detail: Detail,
) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #(
          "scopes",
          json.Object([
            #("open", json.Int(facts.scopes.open)),
            #("closing", json.Int(facts.scopes.closing)),
            #("closed_clean", json.Int(facts.scopes.closed_clean)),
            #("closed_unknown", json.Int(facts.scopes.closed_unknown)),
          ]),
        ),
        #("scope_limit", json.Int(facts.scope_limit)),
        #("ledger_bytes", json.Int(facts.ledger_bytes)),
        #("ledger_limit", json.Int(facts.ledger_limit)),
        #("unacknowledged", json.Int(facts.unacknowledged)),
        #("platform", json.String(facts.platform)),
      ],
      case facts.observed {
        Some(observed) -> [
          #(
            "enforcement",
            json.String(executors.enforcement_word(observed.enforcement)),
          ),
          #(
            "toolchains",
            json.Array(list.map(observed.toolchains, json.String)),
          ),
        ]
        None -> []
      },
      [
        #("contradiction", case contradiction_of(node.declared, facts) {
          Some(words) -> json.String(words)
          None -> json.Null
        }),
      ],
      case detail {
        Brief -> []
        Long -> [
          #("workspaces", json.Array(list.map(facts.workspaces, json.String))),
          #(
            "unclean",
            json.Array(
              list.map(facts.unclean, fn(scope) {
                json.Object(
                  list.flatten([
                    [#("session", json.String(scope.session))],
                    case scope.state {
                      node_report.Closing -> [
                        #("state", json.String("closing")),
                      ]
                      node_report.UnknownCleanup(count:) -> [
                        #("state", json.String("unknown_cleanup")),
                        #("count", json.Int(count)),
                      ]
                    },
                  ]),
                )
              }),
            ),
          ),
        ]
      },
    ]),
  )
}

fn edge_json(edge: Edge) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("from", json.String(edge.from)),
        #("to", json.String(edge.to)),
      ],
      case edge.relation {
        Serves(sessions:) -> [
          #("kind", json.String("serves")),
          #("sessions", json.Int(sessions)),
        ]
        Peers -> [#("kind", json.String("peer"))]
        Member(voter:, leader:) -> [
          #("kind", json.String("member")),
          #("voter", json.Bool(voter == Voting)),
          #("leader", json.Bool(leader == Leading)),
        ]
      },
      case edge.link {
        Some(Connected) -> [#("link", json.String("connected"))]
        Some(Unlinked) -> [#("link", json.String("none"))]
        None -> []
      },
    ]),
  )
}

// The asking daemon's name for a node: the configured key, or the node itself
// when the daemon has none.
fn name_of(nodes: List(Node), node: String) -> String {
  list.find(nodes, fn(each) { each.node == node })
  |> result.map(fn(each) { each.name })
  |> result.unwrap(node)
}

// The configured orchestrators, in the shape the Admin page lists them: what
// the asking daemon found of each, whether it accepts sessions moved to it, and
// the executors it configures, named as the asking daemon names them.
fn orchestrators_json(others: List(Node)) -> JsonValue {
  json.Array(
    list.filter_map(others, fn(node) {
      case list.contains(node.roles, OrchestratorRole) {
        False -> Error(Nil)
        True ->
          Ok(
            json.Object(
              list.flatten([
                [
                  #("name", json.String(node.name)),
                  #("node", json.String(node.node)),
                  #("state", json.String(state_word(node.health))),
                ],
                case node.report |> option.then(fn(r) { r.orchestrator }) {
                  Some(facts) -> [
                    #("imports", json.String(imports_word(facts.imports))),
                    #(
                      "serves",
                      json.Array(
                        list.map(facts.executor_nodes, fn(executor) {
                          json.String(name_of(others, executor))
                        }),
                      ),
                    ),
                  ]
                  None -> []
                },
              ]),
            ),
          )
      }
    }),
  )
}

fn placements_json(placements: Placements) -> JsonValue {
  json.Object([
    #("executors", json.Array(list.map(placements.executors, executor_entry))),
    #("pools", json.Array(list.map(placements.pools, pool_json))),
  ])
}

// The state an executor's card shows: `ready`, `degraded`, `full` or `down`. An
// executor that answered states its free scope count, and one whose census
// disagrees with its declaration says how.
fn executor_entry(entry: ExecutorEntry) -> JsonValue {
  let executor = entry.executor
  let facts = entry.report |> option.then(fn(report) { report.executor })
  json.Object(
    list.flatten([
      [
        #("name", json.String(executor.name)),
        #("node", json.String(executor.node)),
        #("state", json.String(page.state_words(page_state(entry.health)))),
      ],
      case facts {
        Some(found) -> [#("free_scopes", json.Int(free_scopes(found)))]
        None -> []
      },
      case
        option.then(facts, fn(found) { contradiction_of(Some(executor), found) })
      {
        Some(words) -> [#("contradiction", json.String(words))]
        None -> []
      },
      [#("declared", declared_json(executor))],
    ]),
  )
}

// Only what the operator declared is stated. An executor that declares
// nothing about its machine has an empty `toolchains` list and no other member.
fn declared_json(executor: Executor) -> JsonValue {
  json.Object(
    list.flatten([
      case executor.platform {
        Some(label) -> [#("platform", json.String(label))]
        None -> []
      },
      case executor.enforcement {
        Some(value) -> [
          #("enforcement", json.String(executors.enforcement_word(value))),
        ]
        None -> []
      },
      [
        #("toolchains", json.Array(list.map(executor.toolchains, json.String))),
      ],
    ]),
  )
}

fn pool_json(entry: PoolEntry) -> JsonValue {
  json.Object([
    #("name", json.String(entry.name)),
    #("executors", json.Array(list.map(entry.executors, json.String))),
    #("eligible", json.Array(list.map(entry.eligible, json.String))),
  ])
}

// --- the directory and the moves ---------------------------------------------------------

// The directory block, on a daemon that is a member: the body of
// `directory.status` and whether its own copy is current.
fn directory_member(asker: Node) -> List(#(String, JsonValue)) {
  case asker.report |> option.then(fn(report) { report.directory }) {
    Some(facts) -> [#("directory", directory_json(facts))]
    None -> []
  }
}

/// The body of `directory.status` plus whether the member's own copy is known to
/// be current, as the `directory` member of a `deployment.status` reply states
/// it.
///
/// ## Examples
///
/// ```gleam
/// // deployment.directory_json(DirectoryFacts(status, node_report.Current))
/// ```
pub fn directory_json(facts: node_report.DirectoryFacts) -> JsonValue {
  json.Object(
    list.append(directory_status_fields(facts.status), [
      #(
        "copy",
        json.String(case facts.copy {
          node_report.Current -> "current"
          node_report.Unconfirmed -> "unconfirmed"
        }),
      ),
    ]),
  )
}

/// The body of `directory.status`: the members, whether this node has joined,
/// Ra's members with their votes, the applied index and, when there is one, the
/// leader or the reason Ra cannot say.
///
/// ## Examples
///
/// ```gleam
/// // deployment.directory_status_json(member.status(handle))
/// ```
pub fn directory_status_json(status: member.Status) -> JsonValue {
  json.Object(directory_status_fields(status))
}

fn directory_status_fields(
  status: member.Status,
) -> List(#(String, JsonValue)) {
  let #(ra_members, leader, ra_error) = case status.ra {
    Ok(store.Membership(members:, leader:, ..)) -> #(members, leader, None)
    Error(store.Unavailable(reason:)) -> #([], None, Some(reason))
  }
  list.flatten([
    [
      #("members", json.Array(list.map(status.members, json.String))),
      #(
        "joined",
        json.Bool(case status.joining {
          member.Joined -> True
          member.NotJoined | member.Rejoining -> False
        }),
      ),
      #(
        "ra_members",
        json.Array(
          list.map(ra_members, fn(entry) {
            json.Object([
              #("node", json.String(entry.0)),
              #(
                "voter",
                json.Bool(case entry.1 {
                  ffi_khepri.Voter -> True
                  ffi_khepri.Promoting | ffi_khepri.NonVoter -> False
                }),
              ),
            ])
          }),
        ),
      ),
      #("applied_index", json.Int(status.applied_index)),
    ],
    case leader {
      Some(node) -> [#("leader", json.String(node))]
      None -> []
    },
    case ra_error {
      Some(reason) -> [#("unavailable", json.String(reason))]
      None -> []
    },
  ])
}

// The moves in flight on the asking daemon, with the destination named as the
// asking daemon names it. The reason was cut to a fixed length where the move
// recorded it.
fn moves_json(asker: Node, others: List(Node)) -> JsonValue {
  let moves = case
    asker.report |> option.then(fn(report) { report.orchestrator })
  {
    Some(facts) -> facts.moves
    None -> []
  }
  json.Array(
    list.map(moves, fn(move) {
      json.Object(
        list.flatten([
          [
            #("session_id", json.String(move.session)),
            #("op", json.String(move.op)),
            #("to", json.String(name_of(others, move.to_node))),
            #("phase", json.String(phase_word(move.phase))),
          ],
          case move.stalled_ms {
            Some(ms) -> [#("stalled_ms", json.Int(ms))]
            None -> []
          },
          case move.reason {
            Some(words) -> [#("reason", json.String(words))]
            None -> []
          },
        ]),
      )
    }),
  )
}

fn phase_word(phase: node_report.MovePhase) -> String {
  case phase {
    node_report.Running -> "running"
    node_report.Waiting -> "waiting"
  }
}
