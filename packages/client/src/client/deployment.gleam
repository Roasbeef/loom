//// What this daemon can say about the machines it is configured to use
//// (protocol-change/085, the `deployment.status` control command).
////
//// An operator who has written `[executors.<name>]`, `[pools.<name>]` and
//// `[orchestrators.<name>]` tables has no way to ask whether any of those
//// machines answers until a session is placed on one and its open fails. This
//// module is the read that answers it before then. It combines the
//// daemon's own configuration with one fact the daemon can establish for itself:
//// whether its own connection attempt to each configured node succeeded.
////
//// ## What a statement means
////
//// Every statement is "as seen from this daemon". A node is `ok` when this
//// daemon connected to it within `connect_ms`, and `down` when it did not, with
//// a fixed reason word. Nothing is cached and nothing is remembered between
//// asks: a node that did not answer is `down` in this reply and the next ask
//// connects again. A link between two other nodes is not observable from here,
//// so every edge in a reply touches the asking daemon. The deployment as a whole
//// is `ok` when every configured node is, `down` only when none is, and
//// `degraded` between (`verdict`): one dead executor among several is a degraded
//// deployment, not a dead one.
////
//// This slice reports reachability only. A reachable node is `ok` with no
//// further members, because what a node itself would say about its capacity or
//// its build needs a question the orchestrator port does not yet carry. Every
//// node member beyond `node`, `name`, `roles` and `state` (and `reason` for a
//// node that is down) is optional on the wire, so a later change adds members
//// and replaces none.
////
//// ## The one rule about names
////
//// The daemon connects only to nodes named in its own configuration. The
//// `node` filter of the command is a key of that configuration, resolved by
//// `only` before anything is dialled, so a name taken from a request body never
//// reaches the connection layer. A filter that names nothing configured
//// connects to nobody.
////
//// ## The creation panel
////
//// The owner's home page draws a card for each executor and pool when the form
//// for a registered workspace opens (protocol-change/085). `placed` is the read
//// it makes: the same connection attempts, to the executors alone, and the same
//// placements `status` reports. `for_page` reduces them to what the page may
//// know (`web_view/placements`), which is a state, a declaration and a trial
//// order and no node name.
////
//// ## Flow
////
//// `status` → `targets` → `only` → `probe` → `overview` or `selected` →
//// `to_json`
////
//// 1. `status` is the whole read. It lists the configured nodes with
////    `targets`, narrows them with `only` when the request named one, and
////    hands them to `probe`.
//// 2. `probe` connects to every target at once in one weft run, each
////    connection bounded at one second and the whole run at three. Outcomes
////    come back in the order of the targets.
//// 3. `overview` and `selected` are pure: they turn the configuration and the
////    outcomes into a `Snapshot`, with the placements a session-creation form
////    draws from, and `to_json` renders it.

import client/distribution
import client/executors.{type Executor}
import client/orchestrators.{type Orchestrator}
import client/pools.{type Pool}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import web_view/placements as page
import weft

/// How long one connection attempt may take. A first TLS handshake to a loaded
/// machine can outlast it; the handshake goes on in the background, so the node
/// reads `down` in this reply and `ok` in the next.
pub const connect_ms = 1000

/// The bound on the whole fan-out. The attempts run at once, so this is slack for
/// scheduling and for the tasks the deadline abandons rather than a sum.
pub const deadline_ms = 3000

/// Why a configured node is down. The words are fixed so a client can show
/// them without interpreting a diagnostic.
pub type Why {
  /// The connection did not settle within `connect_ms`.
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
/// configuration and the time to wait. It is the only operation the module
/// performs on the network, held as a function so a test can supply the
/// answers.
pub type Dial =
  fn(String, Int) -> Result(Nil, Why)

/// What the daemon asks with: its own node name, which the reply is "as seen
/// from", and how it connects.
pub type Reach {
  Reach(
    /// The asking daemon's node name.
    self: String,
    /// Connects to a configured node.
    dial: Dial,
  )
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
  Reach(self:, dial: fn(_node, _within_ms) { Error(Unavailable) })
}

/// The production reach: the daemon connects to a pinned peer over the
/// distribution it started, with `distribution.connect`'s own bounded wait. A
/// name the membership does not know cannot be resolved to a node, so it reads
/// `unavailable` and creates nothing.
///
/// ## Examples
///
/// ```gleam
/// // let reach = deployment.over(membership, "alpha@10.0.0.1")
/// ```
pub fn over(membership: distribution.Membership, self: String) -> Reach {
  Reach(self:, dial: fn(node, within_ms) {
    use peer <- result.try(
      distribution.peer(membership, node)
      |> result.replace_error(Unavailable),
    )
    distribution.connect(peer, within_ms) |> result.map_error(why_of)
  })
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

/// What this daemon found when it connected to a node.
pub type Health {
  /// The connection was made.
  Reachable

  /// The connection was not made, and why.
  Down(why: Why)
}

/// The wire word for a node's state: `ok` or `down`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.state_word(deployment.Reachable) == "ok"
/// ```
pub fn state_word(health: Health) -> String {
  case health {
    Reachable -> "ok"
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
    /// What the connection attempt found.
    health: Health,
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
      Target(name: each.name, node: each.node, kind: OrchestratorRow)
    }),
    list.map(executors, fn(each) {
      Target(name: each.name, node: each.node, kind: ExecutorRow)
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

/// Connects to every target at once and reports what each connection found, in
/// the order of the targets.
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
pub fn probe(reach: Reach, targets: List(Target)) -> List(#(Target, Health)) {
  case targets {
    [] -> []
    _ -> {
      let dial = reach.dial
      let outcomes =
        targets
        |> list.map(fn(target) {
          let node = target.node
          fn() { dial(node, connect_ms) }
        })
        |> weft.new
        |> weft.deadline(deadline_ms)
        |> weft.start
      list.map2(targets, outcomes, fn(target, outcome) {
        #(target, health_of(outcome))
      })
    }
  }
}

// A task that returns `Error(why)` is a `Failed` outcome carrying `why`, so the
// reason a connection gave comes through the run unchanged.
fn health_of(outcome: weft.Outcome(Nil, Why)) -> Health {
  case outcome {
    weft.Completed(..) -> Reachable
    weft.Failed(error: why, ..) -> Down(why)
    weft.Crashed(..) -> Down(Unavailable)
    weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Down(TimedOut)
  }
}

/// How one node relates to the asking daemon.
pub type Relation {
  /// The asking daemon places sessions on the executor.
  Serves

  /// The asking daemon and the orchestrator can exchange mail and moves.
  Peers
}

/// Whether the asking daemon's connection to the other end exists.
pub type Link {
  /// The connection attempt succeeded.
  Connected

  /// It did not.
  Unlinked
}

/// A relation between two nodes. Every edge of this slice has the asking daemon
/// at one end, because that is the only end whose link it can observe.
pub type Edge {
  Edge(
    /// The node the relation starts at.
    from: String,
    /// The node it ends at.
    to: String,
    /// What the relation is.
    relation: Relation,
    /// The asking daemon's own connection to the other end.
    link: Link,
  )
}

/// What a card for an executor shows: the configured row and what the
/// connection found.
pub type ExecutorEntry {
  ExecutorEntry(
    /// The configured executor, with its declared platform, enforcement and
    /// toolchains.
    executor: Executor,
    /// What the connection found.
    health: Health,
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
    /// Those of `executors` that were reachable, in the same order.
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
    /// The asking daemon's relation to each configured node.
    edges: List(Edge),
    /// The executors and pools a session may be placed on.
    placements: Placements,
  )

  /// The nodes one configuration key names, and nothing about the rest. The
  /// asking daemon is not among them.
  Selected(self: String, nodes: List(Node))
}

/// Reads the deployment: connects to every configured node, or to the ones
/// `node` names, and describes what answered.
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
    None ->
      Ok(overview(reach.self, roles, probe(reach, configured), executors, pools))
    Some(key) -> {
      use named <- result.map(only(configured, key))
      selected(reach.self, probe(reach, named))
    }
  }
}

/// The overview of a deployment, given what each connection found.
///
/// ## Examples
///
/// ```gleam
/// let assert deployment.Overview(self:, others: [], edges: [], ..) =
///   deployment.overview("alpha@10.0.0.1", [], [], [], [])
/// assert self.name == "alpha@10.0.0.1"
/// ```
pub fn overview(
  self: String,
  roles: List(Role),
  probed: List(#(Target, Health)),
  executors: List(Executor),
  pools: List(Pool),
) -> Snapshot {
  Overview(
    self: Node(node: self, name: self, roles:, health: Reachable),
    others: list.map(probed, node_of),
    edges: list.map(probed, fn(found) { edge_of(self, found) }),
    placements: placements(executors, pools, probed),
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
pub fn selected(self: String, probed: List(#(Target, Health))) -> Snapshot {
  Selected(self:, nodes: list.map(probed, node_of))
}

fn node_of(found: #(Target, Health)) -> Node {
  let #(target, health) = found
  Node(
    node: target.node,
    name: target.name,
    roles: [role_of(target.kind)],
    health:,
  )
}

fn role_of(kind: Kind) -> Role {
  case kind {
    OrchestratorRow -> OrchestratorRole
    ExecutorRow -> ExecutorRole
  }
}

// Orchestrators are peers and executors are served. The link is the asking
// daemon's own: the connection it just tried.
fn edge_of(self: String, found: #(Target, Health)) -> Edge {
  let #(target, health) = found
  Edge(
    from: self,
    to: target.node,
    relation: case target.kind {
      ExecutorRow -> Serves
      OrchestratorRow -> Peers
    },
    link: case health {
      Reachable -> Connected
      Down(_) -> Unlinked
    },
  )
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
  placements(executors, pools, probe(reach, targets([], executors)))
}

/// Placements as the home page draws them (`web_view/placements`): the page
/// learns each executor's state and what its operator declared, each pool's
/// trial order and which of its executors were reached, and no node name,
/// address or key. The page has no member for a free scope count or a
/// contradiction yet; the slice that produces them adds both.
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
      page.Executor(
        name: entry.executor.name,
        report: Some(page.Report(
          state: case entry.health {
            Reachable -> page.Ready
            Down(_) -> page.Down
          },
          platform: entry.executor.platform,
          enforcement: option.map(
            entry.executor.enforcement,
            executors.enforcement_word,
          ),
          toolchains: entry.executor.toolchains,
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

// An executor's health is that of its own configured target. The key is
// unique among executors, and an overview probes every executor, so a miss
// cannot happen from `status`; a caller that built `probed` by hand and left one
// out gets `unavailable`, not an invented `ok`.
fn placements(
  executors: List(Executor),
  pools: List(Pool),
  probed: List(#(Target, Health)),
) -> Placements {
  let health_of = fn(executor: Executor) {
    list.find(probed, fn(found) {
      found.0.kind == ExecutorRow && found.0.name == executor.name
    })
    |> result.map(fn(found) { found.1 })
    |> result.unwrap(Down(Unavailable))
  }
  Placements(
    executors: list.map(executors, fn(executor) {
      ExecutorEntry(executor:, health: health_of(executor))
    }),
    pools: list.map(pools, fn(pool) {
      let admitted = pools.candidates(pool, executors)
      PoolEntry(
        name: pool.name,
        executors: list.map(admitted, fn(executor) { executor.name }),
        eligible: list.filter_map(admitted, fn(executor) {
          case health_of(executor) {
            Reachable -> Ok(executor.name)
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
  /// Every configured node answered, or there are none to ask.
  Whole

  /// Some configured node did not answer and some did. One dead executor among
  /// several leaves a working deployment, so it is not a dead one.
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

/// The verdict on the configured nodes: `ok` when all answered, `down` only when
/// none did, and `degraded` for anything between. No nodes is `ok`.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.verdict([]) == deployment.Whole
/// ```
pub fn verdict(nodes: List(Node)) -> Verdict {
  let #(up, down) = list.partition(nodes, fn(node) { node.health == Reachable })
  case up, down {
    _, [] -> Whole
    [], [_, ..] -> Lost
    [_, ..], [_, ..] -> Degraded
  }
}

/// The nodes that are not `ok`, each with the word that says why.
///
/// ## Examples
///
/// ```gleam
/// assert deployment.reasons([]) == []
/// ```
pub fn reasons(nodes: List(Node)) -> List(#(String, String)) {
  list.filter_map(nodes, fn(node) {
    case node.health {
      Reachable -> Error(Nil)
      Down(why) -> Ok(#(node.node, why_word(why)))
    }
  })
}

/// Renders a snapshot as the body of the `deployment.status` reply.
///
/// `as_of_ms` is the asking daemon's wall clock when the reply was built. The
/// whole deployment's `state` is the `verdict` on its configured nodes: `ok` when
/// all answered, `down` when none did and `degraded` otherwise. A request that
/// named a key gets no `edges`, `placements` or `orchestrators`.
///
/// ## Examples
///
/// ```gleam
/// // deployment.to_json(snapshot, 1_760_190_131_000)
/// ```
pub fn to_json(snapshot: Snapshot, as_of_ms: Int) -> JsonValue {
  let #(self, nodes, asked) = case snapshot {
    Overview(self:, others:, ..) -> #(self.node, [self, ..others], others)
    Selected(self:, nodes:) -> #(self, nodes, nodes)
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
    #("nodes", json.Array(list.map(nodes, node_json))),
  ]
  case snapshot {
    Selected(..) -> json.Object(head)
    Overview(others:, edges:, placements:, ..) ->
      json.Object(
        list.append(head, [
          #("edges", json.Array(list.map(edges, edge_json))),
          #("placements", placements_json(placements)),
          #("orchestrators", orchestrators_json(others)),
        ]),
      )
  }
}

fn node_json(node: Node) -> JsonValue {
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
        Down(why) -> [#("reason", json.String(why_word(why)))]
      },
    ]),
  )
}

fn edge_json(edge: Edge) -> JsonValue {
  json.Object([
    #("from", json.String(edge.from)),
    #("to", json.String(edge.to)),
    #(
      "kind",
      json.String(case edge.relation {
        Serves -> "serves"
        Peers -> "peer"
      }),
    ),
    #(
      "link",
      json.String(case edge.link {
        Connected -> "connected"
        Unlinked -> "none"
      }),
    ),
  ])
}

// The configured orchestrators, in the shape the Admin page lists them: what
// the asking daemon found of each. Facts only the orchestrator itself could
// report, such as whether it can receive sessions, are added when the node
// reports are.
fn orchestrators_json(others: List(Node)) -> JsonValue {
  json.Array(
    list.filter_map(others, fn(node) {
      case node.roles {
        [OrchestratorRole] ->
          Ok(
            json.Object([
              #("name", json.String(node.name)),
              #("node", json.String(node.node)),
              #("state", json.String(state_word(node.health))),
            ]),
          )
        [ExecutorRole] | [MemberRole] | [] | [_, _, ..] -> Error(Nil)
      }
    }),
  )
}

fn placements_json(placements: Placements) -> JsonValue {
  json.Object([
    #("executors", json.Array(list.map(placements.executors, executor_json))),
    #("pools", json.Array(list.map(placements.pools, pool_json))),
  ])
}

// The state an executor's card shows. `ready` and `down` are the two this
// slice can establish; `degraded` and `full` need the executor's own report.
fn executor_json(entry: ExecutorEntry) -> JsonValue {
  let executor = entry.executor
  json.Object([
    #("name", json.String(executor.name)),
    #("node", json.String(executor.node)),
    #(
      "state",
      json.String(case entry.health {
        Reachable -> "ready"
        Down(_) -> "down"
      }),
    ),
    #("declared", declared_json(executor)),
  ])
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
