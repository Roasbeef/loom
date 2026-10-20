//// `client/deployment`: what a daemon says about the nodes it is configured
//// with. The connections and the report asks are functions the test supplies, so
//// these tests prove the read's rules: which nodes are dialled and asked, what a
//// failed, silent or late node reads as, the reason words a report earns, how
//// the verdict counts a degraded node, how pools and executors are described,
//// and what the reply says. The connection layer itself is `distribution_test`,
//// and two real daemons are `daemon_shipped_deployment_test`.

import client/deployment.{
  Connected, Down, ExecutorRole, Impaired, OrchestratorRole, Reachable, Target,
  TimedOut, Unavailable, Unlinked, Unreachable,
}
import client/directory/member
import client/directory/store
import client/executors
import client/internal/ffi_khepri
import client/listed_sessions
import client/node_report.{type NodeReport}
import client/orchestrators
import client/pools
import client/remote/orchestrator_port
import client/remote/protocol
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/move_candidates.{Eligible, Ineligible}
import web_view/placements as page

const self = "alpha@10.0.0.1"

fn bravo() {
  orchestrators.plain("bravo", "bravo@10.0.0.4")
}

fn box() {
  executors.plain("box", "box@10.0.0.2")
}

fn exec2() {
  executors.Executor(
    name: "exec2",
    node: "exec2@10.0.0.9",
    platform: Some("linux/x86_64"),
    enforcement: Some(executors.Enforced),
    toolchains: ["codemode"],
  )
}

fn builders() {
  pools.Pool(
    name: "builders",
    executors: ["exec2", "box"],
    platform: None,
    enforcement: None,
    toolchains: [],
  )
}

fn linux_only() {
  pools.Pool(
    name: "linux",
    executors: ["box", "exec2"],
    platform: Some("linux/x86_64"),
    enforcement: None,
    toolchains: [],
  )
}

fn box_target() {
  Target("box", "box@10.0.0.2", deployment.ExecutorRow, Some(box()))
}

fn exec2_target() {
  Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow, Some(exec2()))
}

fn bravo_target() {
  Target("bravo", "bravo@10.0.0.4", deployment.OrchestratorRow, None)
}

// --- reports -------------------------------------------------------------------------

// A report that says nothing beyond who the node is and which build it runs.
// Every node of these tests runs the same build, so no build differs unless a
// test makes it.
fn bare(node: String) -> NodeReport {
  node_report.bare(node, "0.3.0", "abc123", "e1", 1000, 61_000)
}

fn scopes(
  open open: Int,
  closing closing: Int,
  unknown unknown: Int,
) -> node_report.ScopeCounts {
  node_report.ScopeCounts(
    open:,
    closing:,
    closed_clean: 5,
    closed_unknown: unknown,
  )
}

fn executor_facts(
  counts: node_report.ScopeCounts,
) -> node_report.ExecutorFacts {
  node_report.ExecutorFacts(
    protocol: protocol.version,
    scopes: counts,
    scope_limit: 16,
    unclean: [],
    ledger_bytes: 2048,
    ledger_limit: 536_870_912,
    unacknowledged: 0,
    platform: "linux/x86_64",
    observed: None,
    workspaces: ["proj"],
  )
}

fn serving(node: String, counts: node_report.ScopeCounts) -> NodeReport {
  node_report.NodeReport(..bare(node), executor: Some(executor_facts(counts)))
}

fn orchestrating(
  node: String,
  executor_nodes: List(String),
  placements: List(node_report.Placement),
  moves: List(node_report.MoveFacts),
) -> NodeReport {
  node_report.NodeReport(
    ..bare(node),
    orchestrator: Some(node_report.OrchestratorFacts(
      capacity: 8,
      occupied: 2,
      resident: 2,
      imports: node_report.Receiving,
      executor_nodes:,
      placements:,
      moves:,
    )),
  )
}

fn directory_of(
  members: List(#(String, ffi_khepri.Voting)),
  leader: Option(String),
  copy: node_report.Copy,
) -> node_report.DirectoryFacts {
  node_report.DirectoryFacts(
    status: member.Status(
      members: list.map(members, fn(entry) { entry.0 }),
      joining: member.Joined,
      ra: Ok(store.Membership(members:, leader:, up: [])),
      applied_index: 412,
    ),
    copy:,
  )
}

// --- a scripted world ------------------------------------------------------------------

// A reach whose connections answer from a table of node to outcome, whose
// report asks answer from a table of node to report, and which tells `asked`
// every node it was asked to connect to. A node the first table does not list is
// refused as an unreachable host is, and one the second does not list is silent.
// The asking daemon reports itself from `own`.
fn reach(
  answers: List(#(String, Result(Nil, deployment.Why))),
  reports: List(#(String, NodeReport)),
  own: NodeReport,
  asked: process.Subject(String),
) {
  deployment.Reach(
    self:,
    self_name: self,
    footing: deployment.Distributed,
    host: None,
    dial: fn(node, _within_ms) {
      process.send(asked, node)
      case list.key_find(answers, node) {
        Ok(outcome) -> outcome
        Error(Nil) -> Error(Unreachable)
      }
    },
    ask: fn(node, _within_ms) {
      list.key_find(reports, node)
      |> result.replace_error(orchestrator_port.PortGone)
    },
    sessions: listed_sessions.unlisted,
    own: fn() { own },
  )
}

// Every node answers its connection and reports only who it is.
fn everyone(
  nodes: List(String),
  asked: process.Subject(String),
) -> deployment.Reach {
  reach(
    list.map(nodes, fn(node) { #(node, Ok(Nil)) }),
    list.map(nodes, fn(node) { #(node, bare(node)) }),
    bare(self),
    asked,
  )
}

fn dialled(asked: process.Subject(String)) -> List(String) {
  case process.receive(asked, 0) {
    Ok(node) -> [node, ..dialled(asked)]
    Error(Nil) -> []
  }
}

fn field(value, key) {
  let assert json.Object(fields) = value as "an object"
  let assert Ok(found) = list.key_find(fields, key) as "the member is present"
  found
}

fn has(value, key) -> Bool {
  case value {
    json.Object(fields) -> list.key_find(fields, key) != Error(Nil)
    _ -> False
  }
}

// A node as the classification reads it.
fn node_with(
  node: String,
  report: Option(NodeReport),
  declared: Option(executors.Executor),
) -> deployment.Node {
  deployment.Node(
    node:,
    name: node,
    roles: [ExecutorRole],
    health: Reachable,
    report:,
    declared:,
  )
}

fn asking(report: Option(NodeReport)) -> deployment.Node {
  deployment.Node(
    node: self,
    name: self,
    roles: [OrchestratorRole],
    health: Reachable,
    report:,
    declared: None,
  )
}

// --- the configuration ----------------------------------------------------------------

pub fn the_configured_nodes_are_orchestrators_then_executors_test() {
  assert deployment.targets([bravo()], [box(), exec2()])
    == [bravo_target(), box_target(), exec2_target()]
}

pub fn a_key_selects_only_the_nodes_configured_under_it_test() {
  let configured = deployment.targets([bravo()], [box(), exec2()])
  assert deployment.only(configured, "box") == Ok([box_target()])

  // A key is matched among the configured targets and is never read as a node
  // name, so the node itself, a prefix and the empty string select nothing.
  assert deployment.only(configured, "box@10.0.0.2") == Error(Nil)
  assert deployment.only(configured, "bo") == Error(Nil)
  assert deployment.only(configured, "") == Error(Nil)
}

// --- connecting and asking ---------------------------------------------------------------

pub fn a_node_that_answers_is_reachable_and_one_that_does_not_is_down_test() {
  let asked = process.new_subject()
  let probed =
    deployment.probe(
      reach(
        [
          #("bravo@10.0.0.4", Ok(Nil)),
          #("box@10.0.0.2", Ok(Nil)),
          #("exec2@10.0.0.9", Error(TimedOut)),
        ],
        [
          #("bravo@10.0.0.4", bare("bravo@10.0.0.4")),
          #("box@10.0.0.2", bare("box@10.0.0.2")),
        ],
        bare(self),
        asked,
      ),
      deployment.targets([bravo()], [box(), exec2()]),
    )
  assert list.map(probed, fn(found) { #(found.target.name, found.health) })
    == [
      #("bravo", Reachable),
      #("box", Reachable),
      #("exec2", Down(TimedOut)),
    ]
  assert list.map(probed, fn(found) { option.is_some(found.report) })
    == [True, True, False]
}

// A node that connected and gave no report is one the daemon can say nothing of,
// so it reads as down rather than as an `ok` with no facts. An ask that failed at
// once (no port is registered, or it ended) is `silent`, and one that waited out
// its bound is a `timeout`.
pub fn a_connected_node_that_gives_no_report_reads_as_silent_test() {
  let asked = process.new_subject()
  let probed =
    deployment.probe(
      reach([#("box@10.0.0.2", Ok(Nil))], [], bare(self), asked),
      deployment.targets([], [box()]),
    )
  assert list.map(probed, fn(found) { found.health })
    == [Down(deployment.Silent)]
  assert dialled(asked) == ["box@10.0.0.2"]
}

pub fn a_connected_node_that_waits_out_its_bound_reads_as_a_timeout_test() {
  let waiting =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: None,
      dial: fn(_node, _within_ms) { Ok(Nil) },
      ask: fn(_node, within_ms) {
        process.sleep(within_ms)
        Error(orchestrator_port.AskTimedOut)
      },
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let probed = deployment.probe(waiting, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.health }) == [Down(TimedOut)]
}

// Targets that never settle must not starve the ones that would answer: every
// task holds a slot of its own, so none waits behind another. There are far more slow
// targets here than any machine has schedulers.
pub fn slow_targets_do_not_starve_the_fast_ones_test() {
  let slow = upto(1, 128)
  let slow_rows =
    list.map(slow, fn(each) {
      executors.plain(
        "slow" <> int.to_string(each),
        "slow" <> int.to_string(each) <> "@10.0.1.1",
      )
    })
  let world =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: None,
      dial: fn(node, _within_ms) {
        case string.starts_with(node, "slow") {
          True -> {
            process.sleep(60_000)
            Ok(Nil)
          }
          False -> Ok(Nil)
        }
      },
      ask: fn(node, _within_ms) { Ok(bare(node)) },
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let probed =
    deployment.probe(
      world,
      deployment.targets([], list.append(slow_rows, [box(), exec2()])),
    )
  let fast =
    list.filter(probed, fn(found) {
      !string.starts_with(found.target.name, "slow")
    })
  assert list.map(fast, fn(found) { found.health }) == [Reachable, Reachable]
  assert list.all(
    list.filter(probed, fn(found) {
      string.starts_with(found.target.name, "slow")
    }),
    fn(found) { found.health == Down(TimedOut) },
  )
}

pub fn a_node_that_is_not_connected_is_not_asked_test() {
  let told = process.new_subject()
  let probed =
    deployment.probe(
      deployment.Reach(
        self:,
        self_name: self,
        footing: deployment.Distributed,
        host: None,
        dial: fn(_node, _within_ms) { Error(Unreachable) },
        ask: fn(node, _within_ms) {
          process.send(told, node)
          Ok(bare(node))
        },
        sessions: listed_sessions.unlisted,
        own: fn() { bare(self) },
      ),
      deployment.targets([], [box()]),
    )
  assert list.map(probed, fn(found) { found.health }) == [Down(Unreachable)]
  assert process.receive(told, 0) == Error(Nil)
}

pub fn a_connection_that_never_settles_reads_as_down_by_the_deadline_test() {
  // The dial sleeps far past `deadline_ms`. The run's deadline cuts it off, and
  // a node nothing was heard from is down, never assumed up.
  let stuck =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: None,
      dial: fn(_node, _within_ms) {
        process.sleep(60_000)
        Ok(Nil)
      },
      ask: fn(_node, _within_ms) { Error(orchestrator_port.PortGone) },
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let probed = deployment.probe(stuck, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.health }) == [Down(TimedOut)]
}

pub fn a_report_that_never_arrives_reads_as_down_by_the_deadline_test() {
  let stuck =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: None,
      dial: fn(_node, _within_ms) { Ok(Nil) },
      ask: fn(_node, _within_ms) {
        process.sleep(60_000)
        Error(orchestrator_port.AskTimedOut)
      },
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let probed = deployment.probe(stuck, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.health }) == [Down(TimedOut)]
}

pub fn a_connection_that_crashes_reads_as_down_test() {
  let crashing =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: None,
      dial: fn(_node, _within_ms) { panic as "boom" },
      ask: fn(_node, _within_ms) { Error(orchestrator_port.PortGone) },
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let probed = deployment.probe(crashing, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.health }) == [Down(Unavailable)]
}

pub fn no_target_is_no_connection_test() {
  let asked = process.new_subject()
  assert deployment.probe(everyone([], asked), []) == []
  assert dialled(asked) == []
}

pub fn a_key_the_configuration_lacks_dials_nobody_test() {
  let asked = process.new_subject()
  let world = everyone(["box@10.0.0.2", "ghost@10.0.0.66"], asked)

  // The key is a name from a request. It is neither configured nor a node, so
  // the answer is `Error(Nil)` and no node, the configured ones included, was
  // dialled.
  assert deployment.status(
      world,
      [OrchestratorRole],
      [bravo()],
      [box()],
      [],
      Some("ghost"),
    )
    == Error(Nil)
  assert deployment.status(
      world,
      [OrchestratorRole],
      [bravo()],
      [box()],
      [],
      Some("ghost@10.0.0.66"),
    )
    == Error(Nil)
  assert dialled(asked) == []
}

pub fn a_key_dials_only_the_nodes_it_names_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Selected(nodes:, ..)) =
    deployment.status(
      everyone(["box@10.0.0.2"], asked),
      [OrchestratorRole],
      [bravo()],
      [box(), exec2()],
      [],
      Some("box"),
    )
  assert list.map(nodes, fn(node) { #(node.name, node.health) })
    == [#("box", Reachable)]
  assert dialled(asked) == ["box@10.0.0.2"]
}

pub fn an_overview_dials_every_configured_node_once_and_never_itself_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(self: asker, others:, ..)) =
    deployment.status(
      everyone([], asked),
      [OrchestratorRole],
      [bravo()],
      [box(), exec2()],
      [],
      None,
    )
  assert list.sort(dialled(asked), string.compare)
    == ["box@10.0.0.2", "bravo@10.0.0.4", "exec2@10.0.0.9"]
  assert asker.node == self
  assert asker.health == Reachable
  assert list.map(others, fn(node) { node.name }) == ["bravo", "box", "exec2"]
}

// The asking daemon states itself from its own closure. It is in the same run
// as the asks, so it is read once per status and never connected to.
pub fn the_asking_daemon_reports_itself_without_a_connection_test() {
  let asked = process.new_subject()
  let own = orchestrating(self, [], [], [])
  let assert Ok(deployment.Overview(self: asker, ..)) =
    deployment.status(
      reach([], [], own, asked),
      [OrchestratorRole],
      [],
      [],
      [],
      None,
    )
  assert asker.report == Some(own)
  assert dialled(asked) == []
}

// --- the eight reasons ---------------------------------------------------------------------

pub fn a_report_with_nothing_to_say_earns_no_reason_test() {
  let report = serving("box@10.0.0.2", scopes(open: 3, closing: 0, unknown: 0))
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", Some(report), Some(box())),
    )
    == []

  // A node the daemon has no report of has nothing to judge.
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", None, Some(box())),
    )
    == []
}

pub fn a_scope_that_blocks_a_reopen_is_an_unclean_scope_test() {
  let closing = serving("box@10.0.0.2", scopes(open: 3, closing: 1, unknown: 0))
  let unknown = serving("box@10.0.0.2", scopes(open: 3, closing: 0, unknown: 2))
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", Some(closing), None),
    )
    == [deployment.UncleanScope]
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", Some(unknown), None),
    )
    == [deployment.UncleanScope]
}

pub fn scopes_at_the_limit_make_an_executor_full_test() {
  // Open scopes hold slots as unclean ones do: 10 open and 6 unknown are 16 of
  // the 16 the executor admits.
  let held = serving("box@10.0.0.2", scopes(open: 10, closing: 0, unknown: 6))
  let assert Some(facts) = held.executor
  assert deployment.free_scopes(facts) == 0
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", Some(held), None),
    )
    == [deployment.UncleanScope, deployment.Full]

  // One short of the limit is not full, and a limit beaten is zero free, not a
  // negative count.
  let room = serving("box@10.0.0.2", scopes(open: 9, closing: 0, unknown: 6))
  let assert Some(room_facts) = room.executor
  assert deployment.free_scopes(room_facts) == 1
  let over = serving("box@10.0.0.2", scopes(open: 20, closing: 0, unknown: 0))
  let assert Some(over_facts) = over.executor
  assert deployment.free_scopes(over_facts) == 0
}

pub fn a_census_that_disagrees_with_the_declaration_is_contradicted_test() {
  let observed =
    executors.Observed(
      platform: "macos/arm64",
      enforcement: executors.Enforced,
      toolchains: ["codemode"],
    )
  let report =
    node_report.NodeReport(
      ..bare("exec2@10.0.0.9"),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 1, closing: 0, unknown: 0)),
          observed: Some(observed),
        ),
      ),
    )

  // `exec2` declares linux/x86_64 and its census says macos/arm64.
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("exec2@10.0.0.9", Some(report), Some(exec2())),
    )
    == [deployment.DeclarationContradicted]

  // An executor that declares nothing is contradicted by nothing, and one with
  // no census yet has nothing to contradict.
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("exec2@10.0.0.9", Some(report), Some(box())),
    )
    == []
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with(
        "exec2@10.0.0.9",
        Some(serving("exec2@10.0.0.9", scopes(open: 1, closing: 0, unknown: 0))),
        Some(exec2()),
      ),
    )
    == []
}

pub fn another_build_than_the_askers_differs_test() {
  let other =
    node_report.NodeReport(..bare("bravo@10.0.0.4"), build_commit: "def456")
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("bravo@10.0.0.4", Some(other), None),
    )
    == [deployment.BuildDiffers]
  let older =
    node_report.NodeReport(..bare("bravo@10.0.0.4"), build_version: "0.2.0")
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("bravo@10.0.0.4", Some(older), None),
    )
    == [deployment.BuildDiffers]

  // A daemon that could not read itself has no build to compare with.
  assert deployment.classify(
      asking(None),
      node_with("bravo@10.0.0.4", Some(other), None),
    )
    == []
}

pub fn another_executor_protocol_than_the_askers_differs_test() {
  let report =
    node_report.NodeReport(
      ..bare("box@10.0.0.2"),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 1, closing: 0, unknown: 0)),
          protocol: protocol.version + 1,
        ),
      ),
    )
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("box@10.0.0.2", Some(report), None),
    )
    == [deployment.ProtocolDiffers]
}

pub fn a_member_that_names_no_leader_is_without_one_test() {
  let headless =
    node_report.NodeReport(
      ..bare("bravo@10.0.0.4"),
      directory: Some(directory_of(
        [#("bravo@10.0.0.4", ffi_khepri.Voter)],
        None,
        node_report.Current,
      )),
    )
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("bravo@10.0.0.4", Some(headless), None),
    )
    == [deployment.DirectoryNoLeader]

  // A member that cannot read its cluster at all cannot name a leader either.
  let blind =
    node_report.NodeReport(
      ..bare("bravo@10.0.0.4"),
      directory: Some(node_report.DirectoryFacts(
        status: member.Status(
          members: [],
          joining: member.NotJoined,
          ra: Error(store.Unavailable("no quorum")),
          applied_index: 0,
        ),
        copy: node_report.Current,
      )),
    )
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("bravo@10.0.0.4", Some(blind), None),
    )
    == [deployment.DirectoryNoLeader]
}

pub fn a_copy_that_could_not_be_confirmed_is_unconfirmed_test() {
  let stale =
    node_report.NodeReport(
      ..bare("bravo@10.0.0.4"),
      directory: Some(directory_of(
        [#("bravo@10.0.0.4", ffi_khepri.Voter)],
        Some("bravo@10.0.0.4"),
        node_report.Unconfirmed,
      )),
    )
  assert deployment.classify(
      asking(Some(bare(self))),
      node_with("bravo@10.0.0.4", Some(stale), None),
    )
    == [deployment.DirectoryCopyUnconfirmed]
}

pub fn fewer_reachable_voters_than_a_majority_lose_the_quorum_test() {
  let voters = [
    #(self, ffi_khepri.Voter),
    #("bravo@10.0.0.4", ffi_khepri.Voter),
    #("box@10.0.0.2", ffi_khepri.Voter),
  ]
  let seated =
    node_report.NodeReport(
      ..bare(self),
      directory: Some(directory_of(voters, Some(self), node_report.Current)),
    )
  let listed = fn(health_of_bravo, health_of_box) {
    [
      deployment.Node(
        ..node_with("bravo@10.0.0.4", None, None),
        health: health_of_bravo,
      ),
      deployment.Node(
        ..node_with("box@10.0.0.2", None, None),
        health: health_of_box,
      ),
    ]
  }
  let asker = asking(Some(seated))

  // The asking daemon counts itself, so one other voter answering is two of
  // three, a majority.
  assert deployment.quorum(asker, listed(Reachable, Down(TimedOut))) == []

  // Neither other voter answered, so one of three is not.
  assert deployment.quorum(asker, listed(Down(TimedOut), Down(Unreachable)))
    == [deployment.DirectoryQuorumLost]

  // A voter the daemon did not ask is not one that failed to answer, so with
  // one down and one not asked, two of three could still be up.
  assert deployment.quorum(asker, [
      deployment.Node(
        ..node_with("bravo@10.0.0.4", None, None),
        health: Down(TimedOut),
      ),
    ])
    == []

  // A node that is not a voter does not count, and a daemon that is not a member
  // has no quorum to lose.
  assert deployment.quorum(
      asking(Some(bare(self))),
      listed(Down(TimedOut), Down(TimedOut)),
    )
    == []
}

pub fn every_reason_has_its_own_word_test() {
  assert list.map(
      [
        deployment.UncleanScope,
        deployment.Full,
        deployment.DeclarationContradicted,
        deployment.BuildDiffers,
        deployment.ProtocolDiffers,
        deployment.DirectoryNoLeader,
        deployment.DirectoryCopyUnconfirmed,
        deployment.DirectoryQuorumLost,
      ],
      deployment.reason_word,
    )
    == [
      "unclean_scope",
      "full",
      "declaration_contradicted",
      "build_differs",
      "protocol_differs",
      "directory_no_leader",
      "directory_copy_unconfirmed",
      "directory_quorum_lost",
    ]
  assert deployment.why_word(TimedOut) == "timeout"
  assert deployment.why_word(deployment.Silent) == "silent"
  assert deployment.why_word(Unreachable) == "unreachable"
  assert deployment.why_word(Unavailable) == "unavailable"
}

// --- judged through a status -----------------------------------------------------------------

pub fn a_node_that_answers_with_a_reason_reads_degraded_test() {
  let asked = process.new_subject()
  let unclean = serving("box@10.0.0.2", scopes(open: 3, closing: 0, unknown: 1))
  let assert Ok(deployment.Overview(others:, ..)) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Ok(Nil))],
        [
          #("box@10.0.0.2", unclean),
          #(
            "exec2@10.0.0.9",
            serving("exec2@10.0.0.9", scopes(open: 1, closing: 0, unknown: 0)),
          ),
        ],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [],
      None,
    )
  assert list.map(others, fn(node) { node.health })
    == [Impaired([deployment.UncleanScope]), Reachable]
}

// --- placements and edges --------------------------------------------------------------------

pub fn an_executor_is_ready_when_reachable_and_down_when_not_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(placements:, ..)) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Error(TimedOut))],
        [#("box@10.0.0.2", bare("box@10.0.0.2"))],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [],
      None,
    )
  assert list.map(placements.executors, fn(entry) { entry.health })
    == [Reachable, Down(TimedOut)]
}

pub fn a_pool_lists_its_candidates_in_trial_order_and_marks_the_reachable_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(placements:, ..)) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Error(Unreachable))],
        [#("box@10.0.0.2", bare("box@10.0.0.2"))],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [builders()],
      None,
    )

  // The pool's own order is kept even though its first executor is down.
  assert placements.pools
    == [
      deployment.PoolEntry(
        name: "builders",
        executors: ["exec2", "box"],
        eligible: ["box"],
      ),
    ]
}

pub fn a_pool_lists_only_the_executors_whose_declaration_it_admits_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(placements:, ..)) =
    deployment.status(
      everyone(["box@10.0.0.2", "exec2@10.0.0.9"], asked),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [linux_only()],
      None,
    )

  // `box` declares nothing, so a pool that requires a platform cannot admit it.
  assert placements.pools
    == [
      deployment.PoolEntry(name: "linux", executors: ["exec2"], eligible: [
        "exec2",
      ]),
    ]
}

pub fn a_pool_with_every_member_down_has_nobody_eligible_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(placements:, ..)) =
    deployment.status(
      reach([], [], bare(self), asked),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [builders()],
      None,
    )
  let assert [deployment.PoolEntry(eligible: [], executors: [_, _], ..)] =
    placements.pools
}

// A full executor is reachable and cannot take the next attach, so a pool does
// not offer it, and a degraded one still can.
pub fn a_full_executor_is_not_eligible_but_a_degraded_one_is_test() {
  let asked = process.new_subject()
  let full = serving("exec2@10.0.0.9", scopes(open: 16, closing: 0, unknown: 0))
  let unclean = serving("box@10.0.0.2", scopes(open: 3, closing: 0, unknown: 1))
  let assert Ok(deployment.Overview(placements:, ..)) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Ok(Nil))],
        [#("box@10.0.0.2", unclean), #("exec2@10.0.0.9", full)],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [],
      [box(), exec2()],
      [builders()],
      None,
    )
  let assert [exec2_entry, box_entry] =
    list.sort(placements.executors, fn(a, b) {
      string.compare(b.executor.name, a.executor.name)
    })
  assert exec2_entry.health == Impaired([deployment.Full])
  assert box_entry.health == Impaired([deployment.UncleanScope])
  let assert [pool] = placements.pools
  assert pool.eligible == ["box"]
}

pub fn the_edges_touch_the_asking_daemon_and_carry_its_own_link_test() {
  let asked = process.new_subject()
  let assert Ok(deployment.Overview(edges:, ..)) =
    deployment.status(
      reach(
        [
          #("bravo@10.0.0.4", Ok(Nil)),
          #("box@10.0.0.2", Ok(Nil)),
          #("exec2@10.0.0.9", Error(TimedOut)),
        ],
        [
          #("bravo@10.0.0.4", bare("bravo@10.0.0.4")),
          #("box@10.0.0.2", bare("box@10.0.0.2")),
        ],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [bravo()],
      [box(), exec2()],
      [],
      None,
    )
  assert edges
    == [
      deployment.Edge(self, "bravo@10.0.0.4", deployment.Peers, Some(Connected)),
      deployment.Edge(
        self,
        "box@10.0.0.2",
        deployment.Serves(0),
        Some(Connected),
      ),
      deployment.Edge(
        self,
        "exec2@10.0.0.9",
        deployment.Serves(0),
        Some(Unlinked),
      ),
    ]
}

// What another orchestrator serves is its `serves` list in `orchestrators` and
// not an edge, so the reply says it once. The sessions of the asking daemon's own
// serves edge are the resident and the saved ones.
pub fn what_an_orchestrator_reports_it_serves_is_said_once_test() {
  let asked = process.new_subject()
  let own =
    orchestrating(
      self,
      ["box@10.0.0.2"],
      [node_report.Placement("box@10.0.0.2", resident: 2, saved: 1)],
      [],
    )
  let bravos =
    orchestrating(
      "bravo@10.0.0.4",
      ["box@10.0.0.2", "unknown@10.0.0.66"],
      [node_report.Placement("box@10.0.0.2", resident: 1, saved: 0)],
      [],
    )
  let assert Ok(snapshot) =
    deployment.status(
      reach(
        [#("bravo@10.0.0.4", Ok(Nil)), #("box@10.0.0.2", Ok(Nil))],
        [
          #("bravo@10.0.0.4", bravos),
          #("box@10.0.0.2", bare("box@10.0.0.2")),
        ],
        own,
        asked,
      ),
      [OrchestratorRole],
      [bravo()],
      [box()],
      [],
      None,
    )
  let assert deployment.Overview(edges:, ..) = snapshot
  assert edges
    == [
      deployment.Edge(self, "bravo@10.0.0.4", deployment.Peers, Some(Connected)),
      deployment.Edge(
        self,
        "box@10.0.0.2",
        deployment.Serves(3),
        Some(Connected),
      ),
    ]

  // The orchestrator entry says whether it accepts moved sessions and which
  // executors it configures, by the names the asking daemon gives them, and the
  // bare node for one the asking daemon has no name for.
  assert field(deployment.to_json(snapshot, 1), "orchestrators")
    == json.Array([
      json.Object([
        #("name", json.String("bravo")),
        #("node", json.String("bravo@10.0.0.4")),
        #("state", json.String("ok")),
        #("imports", json.String("receiving")),
        #(
          "serves",
          json.Array([json.String("box"), json.String("unknown@10.0.0.66")]),
        ),
      ]),
    ])
}

pub fn the_directory_members_are_edges_from_the_asking_daemon_test() {
  let asked = process.new_subject()
  let own =
    node_report.NodeReport(
      ..bare(self),
      directory: Some(directory_of(
        [
          #(self, ffi_khepri.Voter),
          #("bravo@10.0.0.4", ffi_khepri.Voter),
          #("box@10.0.0.2", ffi_khepri.NonVoter),
        ],
        Some("bravo@10.0.0.4"),
        node_report.Current,
      )),
    )
  let assert Ok(deployment.Overview(self: asker, others:, edges:, ..)) =
    deployment.status(
      reach(
        [#("bravo@10.0.0.4", Ok(Nil)), #("box@10.0.0.2", Error(TimedOut))],
        [#("bravo@10.0.0.4", bare("bravo@10.0.0.4"))],
        own,
        asked,
      ),
      [OrchestratorRole, deployment.MemberRole],
      [bravo()],
      [box()],
      [],
      None,
    )

  // The members are named by the cluster view, so they are members.
  assert list.map(others, fn(node) { node.roles })
    == [
      [OrchestratorRole, deployment.MemberRole],
      [ExecutorRole, deployment.MemberRole],
    ]
  assert asker.health == Reachable
  assert list.filter(edges, fn(edge) {
      case edge.relation {
        deployment.Member(..) -> True
        _ -> False
      }
    })
    == [
      deployment.Edge(
        self,
        "bravo@10.0.0.4",
        deployment.Member(deployment.Voting, deployment.Leading),
        Some(Connected),
      ),
      deployment.Edge(
        self,
        "box@10.0.0.2",
        deployment.Member(deployment.NonVoting, deployment.Following),
        Some(Unlinked),
      ),
    ]
}

// --- the verdict -----------------------------------------------------------------------------

pub fn the_deployment_is_down_only_when_no_configured_node_answers_test() {
  let node = fn(health) {
    deployment.Node(
      node: "n@10.0.0.1",
      name: "n",
      roles: [ExecutorRole],
      health:,
      report: None,
      declared: None,
    )
  }

  // Every node answered, or there is none to ask.
  assert deployment.verdict([]) == deployment.Whole
  assert deployment.verdict([node(Reachable), node(Reachable)])
    == deployment.Whole

  // One dead node among several is a degraded deployment, whichever comes first.
  assert deployment.verdict([node(Reachable), node(Down(TimedOut))])
    == deployment.Degraded
  assert deployment.verdict([node(Down(TimedOut)), node(Reachable)])
    == deployment.Degraded

  // Only when none answered is it down, and a single node that did not is none.
  assert deployment.verdict([node(Down(TimedOut)), node(Down(Unreachable))])
    == deployment.Lost
  assert deployment.verdict([node(Down(Unavailable))]) == deployment.Lost
  assert deployment.verdict_word(deployment.Whole) == "ok"
  assert deployment.verdict_word(deployment.Degraded) == "degraded"
  assert deployment.verdict_word(deployment.Lost) == "down"
  assert deployment.reasons([
      node(Reachable),
      deployment.Node(
        node: "x@10.0.0.9",
        name: "x",
        roles: [ExecutorRole],
        health: Down(Unavailable),
        report: None,
        declared: None,
      ),
    ])
    == [#("x@10.0.0.9", "unavailable")]
}

// A node that answered with reasons is reachable and not `ok`. It leaves the
// deployment degraded, whether it stands alone, beside an `ok` node or beside a
// dead one, and it is not the same as down: a deployment whose only node is
// degraded still answers.
pub fn a_degraded_node_is_reachable_but_not_ok_test() {
  let node = fn(health) {
    deployment.Node(
      node: "n@10.0.0.1",
      name: "n",
      roles: [ExecutorRole],
      health:,
      report: None,
      declared: None,
    )
  }
  let sick = Impaired([deployment.UncleanScope])
  assert deployment.verdict([node(sick)]) == deployment.Degraded
  assert deployment.verdict([node(Reachable), node(sick)])
    == deployment.Degraded
  assert deployment.verdict([node(sick), node(Down(TimedOut))])
    == deployment.Degraded
  assert deployment.verdict([node(Down(TimedOut)), node(Down(TimedOut))])
    == deployment.Lost
  assert deployment.state_word(sick) == "degraded"

  // One entry for each reason, in the order the node earned them.
  assert deployment.reasons([
      node(Impaired([deployment.UncleanScope, deployment.Full])),
    ])
    == [#("n@10.0.0.1", "unclean_scope"), #("n@10.0.0.1", "full")]
}

// --- the reply -------------------------------------------------------------------------------

pub fn the_reply_states_each_node_its_edges_and_its_placements_test() {
  let asked = process.new_subject()
  let body =
    deployment.status(
      reach(
        [#("bravo@10.0.0.4", Ok(Nil)), #("exec2@10.0.0.9", Error(TimedOut))],
        [#("bravo@10.0.0.4", bare("bravo@10.0.0.4"))],
        bare(self),
        asked,
      ),
      [OrchestratorRole, deployment.MemberRole],
      [bravo()],
      [exec2()],
      [builders_of_exec2()],
      None,
    )
  let assert Ok(snapshot) = body
  let body = deployment.to_json(snapshot, 1_760_190_131_000)
  assert field(body, "as_of_ms") == json.Int(1_760_190_131_000)
  assert field(body, "self") == json.String(self)
  assert field(body, "state") == json.String("degraded")
  assert field(body, "reasons")
    == json.Array([
      json.Object([
        #("node", json.String("exec2@10.0.0.9")),
        #("reason", json.String("timeout")),
      ]),
    ])
  let assert json.Array([asker, peer, down]) = field(body, "nodes")
  assert field(asker, "self") == json.Bool(True)
  assert field(asker, "roles")
    == json.Array([json.String("orchestrator"), json.String("member")])
  assert field(asker, "build_commit") == json.String("abc123")
  assert field(asker, "uptime_ms") == json.Int(60_000)
  assert !has(peer, "self")
  assert field(peer, "state") == json.String("ok")
  assert field(down, "state") == json.String("down")
  assert field(down, "reason") == json.String("timeout")
  assert !has(down, "build_commit")
  assert field(body, "edges")
    == json.Array([
      json.Object([
        #("from", json.String(self)),
        #("to", json.String("bravo@10.0.0.4")),
        #("kind", json.String("peer")),
        #("link", json.String("connected")),
      ]),
      json.Object([
        #("from", json.String(self)),
        #("to", json.String("exec2@10.0.0.9")),
        #("kind", json.String("serves")),
        #("sessions", json.Int(0)),
        #("link", json.String("none")),
      ]),
    ])
  assert field(body, "moves") == json.Array([])
  assert !has(body, "directory")
  assert field(field(body, "placements"), "pools")
    == json.Array([
      json.Object([
        #("name", json.String("only-exec2")),
        #("executors", json.Array([json.String("exec2")])),
        #("eligible", json.Array([])),
      ]),
    ])
  let assert json.Array([executor]) =
    field(field(body, "placements"), "executors")
  assert field(executor, "state") == json.String("down")
  assert !has(executor, "free_scopes")
  assert field(executor, "declared")
    == json.Object([
      #("platform", json.String("linux/x86_64")),
      #("enforcement", json.String("enforced")),
      #("toolchains", json.Array([json.String("codemode")])),
    ])
  assert field(body, "orchestrators")
    == json.Array([
      json.Object([
        #("name", json.String("bravo")),
        #("node", json.String("bravo@10.0.0.4")),
        #("state", json.String("ok")),
      ]),
    ])
}

fn builders_of_exec2() {
  pools.Pool(
    name: "only-exec2",
    executors: ["exec2"],
    platform: None,
    enforcement: None,
    toolchains: [],
  )
}

// The orchestrator, executor, directory and moves members, as the daemon states
// them in an overview: numbers, and none of the long lists.
pub fn an_overview_states_numbers_and_none_of_the_long_lists_test() {
  let asked = process.new_subject()
  let move =
    node_report.MoveFacts(
      session: "0198c0de-0000-7000-8000-000000000001",
      op: "0198c0de-0000-7000-8000-000000000a01",
      to_node: "bravo@10.0.0.4",
      phase: node_report.Waiting,
      stalled_ms: Some(240_000),
      reason: Some("the receiver did not answer"),
    )
  let own =
    node_report.NodeReport(
      ..orchestrating(
        self,
        ["box@10.0.0.2"],
        [node_report.Placement("box@10.0.0.2", resident: 3, saved: 0)],
        [move],
      ),
      directory: Some(directory_of(
        [#(self, ffi_khepri.Voter), #("bravo@10.0.0.4", ffi_khepri.Voter)],
        Some("bravo@10.0.0.4"),
        node_report.Unconfirmed,
      )),
    )
  let unclean = serving("box@10.0.0.2", scopes(open: 3, closing: 0, unknown: 1))
  let box_report =
    node_report.NodeReport(
      ..unclean,
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 3, closing: 0, unknown: 1)),
          unclean: [
            node_report.UncleanScope(
              session: "s-lost",
              state: node_report.UnknownCleanup(count: 2),
            ),
          ],
        ),
      ),
    )
  let assert Ok(snapshot) =
    deployment.status(
      reach(
        [#("bravo@10.0.0.4", Ok(Nil)), #("box@10.0.0.2", Ok(Nil))],
        [
          #("bravo@10.0.0.4", bare("bravo@10.0.0.4")),
          #("box@10.0.0.2", box_report),
        ],
        own,
        asked,
      ),
      [OrchestratorRole, deployment.MemberRole],
      [bravo()],
      [box()],
      [],
      None,
    )
  let body = deployment.to_json(snapshot, 7)

  // The asking daemon first: its numbers, and the moves in flight as a count.
  let assert json.Array([asker, _, box_node]) = field(body, "nodes")
  let orchestrator = field(asker, "orchestrator")
  assert field(orchestrator, "capacity") == json.Int(8)
  assert field(orchestrator, "imports") == json.String("receiving")
  assert field(orchestrator, "moves_in_flight") == json.Int(1)
  assert !has(orchestrator, "placements")
  assert !has(orchestrator, "moves")
  assert field(asker, "state") == json.String("degraded")
  assert field(asker, "reasons")
    == json.Array([json.String("directory_copy_unconfirmed")])

  // The executor: scope counts, limits and the contradiction as null, and not
  // the workspace names or the unclean scopes.
  assert field(box_node, "state") == json.String("degraded")
  assert field(box_node, "reasons")
    == json.Array([json.String("unclean_scope")])
  assert field(box_node, "protocol") == json.Int(protocol.version)
  let executor = field(box_node, "executor")
  assert field(executor, "scopes")
    == json.Object([
      #("open", json.Int(3)),
      #("closing", json.Int(0)),
      #("closed_clean", json.Int(5)),
      #("closed_unknown", json.Int(1)),
    ])
  assert field(executor, "scope_limit") == json.Int(16)
  assert field(executor, "contradiction") == json.Null
  assert !has(executor, "workspaces")
  assert !has(executor, "unclean")

  // The directory is the body of `directory.status` and whether the copy is
  // current, and the moves name their destination as the daemon does.
  let directory = field(body, "directory")
  assert field(directory, "leader") == json.String("bravo@10.0.0.4")
  assert field(directory, "applied_index") == json.Int(412)
  assert field(directory, "copy") == json.String("unconfirmed")
  assert field(directory, "joined") == json.Bool(True)
  assert field(body, "moves")
    == json.Array([
      json.Object([
        #("session_id", json.String("0198c0de-0000-7000-8000-000000000001")),
        #("op", json.String("0198c0de-0000-7000-8000-000000000a01")),
        #("to", json.String("bravo")),
        #("phase", json.String("waiting")),
        #("stalled_ms", json.Int(240_000)),
        #("reason", json.String("the receiver did not answer")),
      ]),
    ])

  // The free scope count of the executor's card: 16 less 3 open and 1 unknown.
  let assert json.Array([card]) = field(field(body, "placements"), "executors")
  assert field(card, "free_scopes") == json.Int(12)
  assert field(card, "state") == json.String("degraded")
}

pub fn an_executor_that_declares_nothing_states_an_empty_toolchain_list_test() {
  let asked = process.new_subject()
  let assert Ok(snapshot) =
    deployment.status(
      everyone(["box@10.0.0.2"], asked),
      [OrchestratorRole],
      [],
      [box()],
      [],
      None,
    )
  let body = deployment.to_json(snapshot, 1)
  let assert json.Object(members) = body
  let assert Ok(json.Object(placements)) = list.key_find(members, "placements")
  let assert Ok(json.Array([json.Object(entry)])) =
    list.key_find(placements, "executors")
  assert list.key_find(entry, "state") == Ok(json.String("ready"))
  assert list.key_find(entry, "declared")
    == Ok(json.Object([#("toolchains", json.Array([]))]))
}

// A request that named a key gets the node with its long lists and none of the
// whole-deployment members.
pub fn a_selected_reply_holds_the_named_node_and_its_long_lists_test() {
  let asked = process.new_subject()
  let unclean =
    node_report.NodeReport(
      ..bare("box@10.0.0.2"),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 3, closing: 1, unknown: 1)),
          unclean: [
            node_report.UncleanScope(
              session: "s-closing",
              state: node_report.Closing,
            ),
            node_report.UncleanScope(
              session: "s-lost",
              state: node_report.UnknownCleanup(count: 2),
            ),
          ],
        ),
      ),
    )
  let assert Ok(snapshot) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil))],
        [#("box@10.0.0.2", unclean)],
        bare(self),
        asked,
      ),
      [OrchestratorRole],
      [],
      [box()],
      [],
      Some("box"),
    )
  let body = deployment.to_json(snapshot, 5)
  let assert json.Object(members) = body
  assert list.map(members, fn(member) { member.0 })
    == ["as_of_ms", "self", "state", "reasons", "nodes"]
  assert field(body, "state") == json.String("degraded")
  let assert json.Array([node]) = field(body, "nodes")
  let executor = field(node, "executor")
  assert field(executor, "workspaces") == json.Array([json.String("proj")])
  assert field(executor, "unclean")
    == json.Array([
      json.Object([
        #("session", json.String("s-closing")),
        #("state", json.String("closing")),
      ]),
      json.Object([
        #("session", json.String("s-lost")),
        #("state", json.String("unknown_cleanup")),
        #("count", json.Int(2)),
      ]),
    ])
}

pub fn a_selected_reply_for_a_node_that_is_down_states_the_reason_test() {
  let asked = process.new_subject()
  let assert Ok(snapshot) =
    deployment.status(
      reach([], [], bare(self), asked),
      [OrchestratorRole],
      [],
      [box()],
      [],
      Some("box"),
    )
  let body = deployment.to_json(snapshot, 5)
  assert field(body, "state") == json.String("down")
  let assert json.Array([node]) = field(body, "nodes")
  assert field(node, "reason") == json.String("unreachable")
}

pub fn a_daemon_without_distribution_names_itself_and_connects_to_nobody_test() {
  let alone = deployment.alone("nonode@nohost")
  assert alone.self == "nonode@nohost"
  assert alone.dial("anywhere@10.0.0.1", 1000) == Error(Unavailable)
  assert alone.ask("anywhere@10.0.0.1", 1000)
    == Error(orchestrator_port.PortGone)
  let assert Ok(deployment.Overview(self: asker, others: [], edges: [], ..)) =
    deployment.status(alone, [OrchestratorRole], [], [], [], None)
  assert asker.node == "nonode@nohost"
  assert option.is_some(asker.report)
}

// A daemon is titled the way its peers are: by the name its ledger gives it, with
// the node string beside it. Without a ledger the node string is all there is.
pub fn the_asking_daemon_is_titled_by_its_ledger_name_test() {
  let alone = deployment.alone("alpha@10.0.0.1")
  let assert Ok(deployment.Overview(self: unnamed, ..)) =
    deployment.status(alone, [OrchestratorRole], [], [], [], None)
  assert unnamed.name == "alpha@10.0.0.1"
  let assert Ok(deployment.Overview(self: named, ..)) =
    deployment.status(
      deployment.named(alone, "hub"),
      [OrchestratorRole],
      [],
      [],
      [],
      None,
    )
  assert named.name == "hub"
  assert named.node == "alpha@10.0.0.1"
}

// The creation panel's read connects to the executors and to nothing else: the
// orchestrators are not its business, and a slow one must not delay the cards.
pub fn the_creation_panel_reads_the_executors_alone_test() {
  let asked = process.new_subject()
  let placed =
    deployment.placed(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Error(TimedOut))],
        [#("box@10.0.0.2", bare("box@10.0.0.2"))],
        bare(self),
        asked,
      ),
      [box(), exec2()],
      [builders()],
    )
  assert list.sort(dialled(asked), string.compare)
    == ["box@10.0.0.2", "exec2@10.0.0.9"]
  assert list.map(placed.executors, fn(entry) { entry.health })
    == [Reachable, Down(TimedOut)]
  assert placed.pools
    == [
      deployment.PoolEntry(
        name: "builders",
        executors: ["exec2", "box"],
        eligible: ["box"],
      ),
    ]
}

// What the page is told: each executor's state, free scopes and contradiction
// and what its operator declared, each pool's trial order and members that can
// take a session, and no node name, address or key.
pub fn the_page_is_told_states_declarations_and_no_node_test() {
  let observed =
    executors.Observed(
      platform: "macos/arm64",
      enforcement: executors.Enforced,
      toolchains: [],
    )
  let contradicted =
    node_report.NodeReport(
      ..bare("exec2@10.0.0.9"),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 4, closing: 0, unknown: 0)),
          observed: Some(observed),
        ),
      ),
    )
  let placed =
    deployment.Placements(
      executors: [
        deployment.ExecutorEntry(box(), Reachable, Some(bare("box@10.0.0.2"))),
        deployment.ExecutorEntry(
          exec2(),
          Impaired([deployment.DeclarationContradicted]),
          Some(contradicted),
        ),
      ],
      pools: [
        deployment.PoolEntry(
          name: "builders",
          executors: ["exec2", "box"],
          eligible: ["box"],
        ),
      ],
    )
  let assert page.Placements(executors: [box_card, exec2_card], pools: [pool]) =
    deployment.for_page(placed)
  assert box_card
    == page.Executor(
      "box",
      Some(page.Report(
        state: page.Ready,
        platform: None,
        enforcement: None,
        toolchains: [],
        free_scopes: None,
        workspaces: [],
        contradiction: None,
      )),
    )
  let assert Some(report) = exec2_card.report
  assert report.workspaces == ["proj"]
  assert report.state == page.Degraded
  assert report.free_scopes == Some(12)
  assert report.platform == Some("linux/x86_64")
  assert report.toolchains == ["codemode"]
  let assert Some(words) = report.contradiction
  assert string.contains(words, "macos/arm64")
  assert pool
    == page.Pool(
      "builders",
      Some(
        page.PoolReport(
          executors: ["exec2", "box"],
          eligible: ["box"],
          workspaces: [],
        ),
      ),
    )
}

// A pool offers the workspace names every executor that could take the session
// registered, because a first open can land on any of them. An executor that is
// down is not asked, and a pool with none reachable offers nothing.
pub fn a_pool_is_told_the_workspaces_all_its_reachable_executors_share_test() {
  let facts = fn(name, workspaces) {
    Some(
      node_report.NodeReport(
        ..bare(name),
        executor: Some(
          node_report.ExecutorFacts(
            ..executor_facts(scopes(open: 4, closing: 0, unknown: 0)),
            workspaces:,
          ),
        ),
      ),
    )
  }
  let pool = fn(eligible) {
    deployment.PoolEntry(
      name: "builders",
      executors: ["exec2", "box"],
      eligible:,
    )
  }
  let told = fn(eligible) {
    let assert page.Placements(pools: [card], ..) =
      deployment.for_page(
        deployment.Placements(
          executors: [
            deployment.ExecutorEntry(
              box(),
              Reachable,
              facts("box@10.0.0.2", ["app", "tools", "docs"]),
            ),
            deployment.ExecutorEntry(
              exec2(),
              Reachable,
              facts("exec2@10.0.0.9", ["tools", "app"]),
            ),
          ],
          pools: [pool(eligible)],
        ),
      )
    let assert Some(report) = card.report
    report.workspaces
  }
  assert told(["exec2", "box"]) == ["app", "tools"]
  assert told(["box"]) == ["app", "tools", "docs"]
  assert told([]) == []
}

pub fn a_down_or_full_executor_is_drawn_with_that_state_test() {
  let entry = fn(health, report) {
    let assert page.Placements(executors: [card], ..) =
      deployment.for_page(
        deployment.Placements(
          executors: [deployment.ExecutorEntry(box(), health, report)],
          pools: [],
        ),
      )
    let assert Some(found) = card.report
    found
  }
  let full = serving("box@10.0.0.2", scopes(open: 16, closing: 0, unknown: 0))
  assert entry(Down(Unreachable), None).state == page.Down
  assert entry(Impaired([deployment.Full]), Some(full)).state == page.Full
  assert entry(Impaired([deployment.Full]), Some(full)).free_scopes == Some(0)

  // Full outranks the other reasons, which the card does not list.
  assert entry(Impaired([deployment.UncleanScope, deployment.Full]), Some(full)).state
    == page.Full
}

// The reply's `state` is the verdict on the configured nodes, and the asking
// daemon, which is always reachable, is not one of them: with every other node
// gone the deployment reads down and not degraded.
pub fn the_replys_state_follows_the_verdict_on_the_configured_nodes_test() {
  let state = fn(answers, reports) {
    let asked = process.new_subject()
    let assert Ok(snapshot) =
      deployment.status(
        reach(answers, reports, bare(self), asked),
        [OrchestratorRole],
        [],
        [box(), exec2()],
        [],
        None,
      )
    field(deployment.to_json(snapshot, 1), "state")
  }
  let ok = fn(node) { #(node, Ok(Nil)) }
  let both = [
    #("box@10.0.0.2", bare("box@10.0.0.2")),
    #("exec2@10.0.0.9", bare("exec2@10.0.0.9")),
  ]
  assert state([ok("box@10.0.0.2"), ok("exec2@10.0.0.9")], both)
    == json.String("ok")
  assert state([ok("box@10.0.0.2"), #("exec2@10.0.0.9", Error(TimedOut))], both)
    == json.String("degraded")
  assert state([], both) == json.String("down")

  // A node that answers with a reason leaves the deployment degraded even
  // though every node answered.
  assert state([ok("box@10.0.0.2"), ok("exec2@10.0.0.9")], [
      #(
        "box@10.0.0.2",
        serving("box@10.0.0.2", scopes(open: 1, closing: 1, unknown: 0)),
      ),
      #("exec2@10.0.0.9", bare("exec2@10.0.0.9")),
    ])
    == json.String("degraded")
}

// --- the asking daemon in the verdict ------------------------------------------------

// The asking daemon is not one of the nodes the verdict counts, but a reason of
// its own is in `reasons`, so an impaired asker must not read `ok`.
pub fn an_impaired_asking_daemon_makes_an_ok_deployment_degraded_test() {
  let headless =
    node_report.NodeReport(
      ..bare(self),
      directory: Some(directory_of(
        [#(self, ffi_khepri.Voter)],
        None,
        node_report.Current,
      )),
    )
  let asked = process.new_subject()
  let assert Ok(snapshot) =
    deployment.status(
      reach(
        [#("box@10.0.0.2", Ok(Nil))],
        [#("box@10.0.0.2", bare("box@10.0.0.2"))],
        headless,
        asked,
      ),
      [OrchestratorRole, deployment.MemberRole],
      [],
      [box()],
      [],
      None,
    )
  let body = deployment.to_json(snapshot, 1)
  assert field(body, "state") == json.String("degraded")
  assert field(body, "reasons")
    == json.Array([
      json.Object([
        #("node", json.String(self)),
        #("reason", json.String("directory_no_leader")),
      ]),
    ])
}

// --- the size of a reply -----------------------------------------------------------------

// The integers from `first` to `last`, both included.
fn upto(first: Int, last: Int) -> List(Int) {
  case first > last {
    True -> []
    False -> [first, ..upto(first + 1, last)]
  }
}

fn padded(prefix: String, number: Int) -> String {
  prefix <> string.pad_start(int.to_string(number), to: 2, with: "0")
}

fn long_host(prefix: String, number: Int) -> String {
  padded(prefix, number) <> "@" <> padded(prefix, number) <> ".prod.example.com"
}

// A deployment at the node cap: four orchestrators and sixty executors with
// names a real fleet would give them, a directory of all of them, sixty-four
// moves in flight, workspaces and unclean scopes on each executor, and pools that
// admit every executor.
fn fleet() -> deployment.Snapshot {
  let executor_rows =
    list.map(upto(1, 60), fn(each) {
      executors.Executor(
        name: padded("executor-build-farm-", each),
        node: long_host("executor-build-farm-", each),
        platform: Some("linux/x86_64"),
        enforcement: Some(executors.Enforced),
        toolchains: ["codemode", "gleam", "rust-analyzer"],
      )
    })
  let executor_nodes = list.map(executor_rows, fn(row) { row.node })
  let moves =
    list.map(upto(1, 64), fn(each) {
      node_report.MoveFacts(
        session: "0198c0de-0000-7000-8000-0000000000" <> padded("", each),
        op: "0198c0de-0000-7000-8000-000000000a" <> padded("", each),
        to_node: long_host("orchestrator-prod-", 2),
        phase: node_report.Waiting,
        stalled_ms: Some(240_000),
        reason: Some("the receiver did not answer after the last four retries"),
      )
    })
  let placements =
    list.map(executor_nodes, fn(node) {
      node_report.Placement(node, resident: 3, saved: 12)
    })
  let orchestrator_report = fn(node) {
    node_report.NodeReport(
      ..orchestrating(node, executor_nodes, placements, moves),
      directory: Some(directory_of(
        list.map(
          list.append(
            list.map(upto(1, 4), long_host("orchestrator-prod-", _)),
            executor_nodes,
          ),
          fn(each) { #(each, ffi_khepri.Voter) },
        ),
        Some(long_host("orchestrator-prod-", 2)),
        node_report.Current,
      )),
    )
  }
  let executor_report = fn(node) {
    node_report.NodeReport(
      ..bare(node),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 3, closing: 0, unknown: 1)),
          observed: Some(
            executors.Observed(
              platform: "linux/x86_64",
              enforcement: executors.Enforced,
              toolchains: ["codemode", "gleam", "rust-analyzer"],
            ),
          ),
          workspaces: list.map(upto(1, 64), padded("workspace-", _)),
        ),
      ),
    )
  }
  let node_of = fn(row: executors.Executor) {
    deployment.Node(
      node: row.node,
      name: row.name,
      roles: [ExecutorRole, deployment.MemberRole],
      health: Impaired([deployment.UncleanScope]),
      report: Some(executor_report(row.node)),
      declared: Some(row),
    )
  }
  let orchestrator = fn(number) {
    let node = long_host("orchestrator-prod-", number)
    deployment.Node(
      node:,
      name: padded("orchestrator-prod-", number),
      roles: [OrchestratorRole, deployment.MemberRole],
      health: Reachable,
      report: Some(orchestrator_report(node)),
      declared: None,
    )
  }
  let pool_rows =
    list.map(upto(1, 4), fn(each) {
      pools.Pool(
        name: padded("pool-for-builds-", each),
        executors: list.map(executor_rows, fn(row) { row.name }),
        platform: None,
        enforcement: None,
        toolchains: [],
      )
    })
  deployment.overview(
    deployment.Node(..orchestrator(1), roles: [
      OrchestratorRole,
      deployment.MemberRole,
    ]),
    list.append(
      list.map(upto(2, 4), orchestrator),
      list.map(executor_rows, node_of),
    ),
    executor_rows,
    pool_rows,
  )
}

fn encoded_size(body: json.JsonValue) -> Int {
  string.byte_size(json.to_string(body))
}

// The terminal refuses a frame over 64 KiB, so the daemon measures the reply and
// drops detail until it fits: first the moves, then the per-node facts and the
// declarations. It says what it dropped, so a client knows to ask for one node.
pub fn an_overview_at_the_node_cap_fits_a_frame_and_says_what_it_dropped_test() {
  let body = deployment.to_json(fleet(), 1_760_191_331_000)
  assert encoded_size(body) <= deployment.max_reply_bytes
  let assert json.Array(omitted) = field(body, "omitted")
  assert list.contains(omitted, json.String("moves"))
  assert !has(body, "moves")

  // What is kept: every node with its name, role, health, reasons, scope counts
  // and build, and the directory.
  let assert json.Array(nodes) = field(body, "nodes")
  assert list.length(nodes) == 64
  let assert [_, _, _, _, executor, ..] = nodes
  assert field(executor, "state") == json.String("degraded")
  assert field(executor, "reasons")
    == json.Array([json.String("unclean_scope")])
  assert has(executor, "build_commit")
  assert has(field(executor, "executor"), "scopes")
  assert has(body, "directory")
  assert has(body, "orchestrators")

  // The fleet is too large for any lower level to keep its edges.
  assert list.contains(omitted, json.String("edges"))
  assert !has(body, "edges")
}

// A deployment that fits says nothing was dropped.
pub fn an_overview_that_fits_drops_nothing_test() {
  let asked = process.new_subject()
  let assert Ok(snapshot) =
    deployment.status(
      everyone(["box@10.0.0.2"], asked),
      [OrchestratorRole],
      [],
      [box()],
      [],
      None,
    )
  let body = deployment.to_json(snapshot, 1)
  assert !has(body, "omitted")
  assert has(body, "moves")
}

// A reply for one node with long names and full lists cuts its lists, and names
// them in `more`, to fit.
pub fn a_node_reply_with_long_lists_is_cut_to_fit_and_says_so_test() {
  let long = fn(prefix, number) {
    string.repeat(prefix, 20) <> string.pad_start(int.to_string(number), 3, "0")
  }
  let node = "box@10.0.0.2"
  let report =
    node_report.NodeReport(
      ..bare(node),
      orchestrator: Some(node_report.OrchestratorFacts(
        capacity: 8,
        occupied: 2,
        resident: 2,
        imports: node_report.Receiving,
        executor_nodes: [],
        placements: list.map(upto(1, 64), fn(each) {
          node_report.Placement(long("executor.node.", each), 1, 1)
        }),
        moves: list.map(upto(1, 64), fn(each) {
          node_report.MoveFacts(
            session: "0198c0de-0000-7000-8000-000000000001",
            op: "0198c0de-0000-7000-8000-000000000a01",
            to_node: long("orchestrator.", each),
            phase: node_report.Waiting,
            stalled_ms: Some(1),
            reason: Some(string.repeat("r", 200)),
          )
        }),
      )),
      executor: Some(
        node_report.ExecutorFacts(
          ..executor_facts(scopes(open: 1, closing: 0, unknown: 0)),
          workspaces: list.map(upto(1, 64), fn(each) {
            long("workspace.name.", each)
          }),
        ),
      ),
    )
  let snapshot =
    deployment.selected(self, [
      deployment.Node(
        node:,
        name: "box",
        roles: [ExecutorRole, OrchestratorRole],
        health: Reachable,
        report: Some(report),
        declared: None,
      ),
    ])
  let body = deployment.to_json(snapshot, 1)
  assert encoded_size(body) <= deployment.max_reply_bytes
  let assert json.Array(more) = field(body, "more")
  assert list.contains(more, json.String("moves"))
  assert list.contains(more, json.String("workspaces"))
  let assert json.Array([found]) = field(body, "nodes")
  let assert json.Array(kept) = field(field(found, "orchestrator"), "moves")
  assert list.length(kept) == deployment.trimmed_entries

  // The same node with short lists is complete and says nothing is more.
  let small =
    deployment.selected(self, [
      deployment.Node(
        node:,
        name: "box",
        roles: [ExecutorRole],
        health: Reachable,
        report: Some(serving(node, scopes(open: 1, closing: 0, unknown: 0))),
        declared: None,
      ),
    ])
  assert !has(deployment.to_json(small, 1), "more")
}

// A move is spelled one way, whether the overview or the orchestrator's own list
// states it.
pub fn a_move_is_spelled_one_way_test() {
  let move =
    node_report.MoveFacts(
      session: "s",
      op: "o",
      to_node: "bravo@10.0.0.4",
      phase: node_report.Running,
      stalled_ms: None,
      reason: None,
    )
  let own = orchestrating(self, [], [], [move])
  let asker =
    deployment.Node(
      node: self,
      name: self,
      roles: [OrchestratorRole],
      health: Reachable,
      report: Some(own),
      declared: None,
    )
  let expected =
    json.Object([
      #("session_id", json.String("s")),
      #("op", json.String("o")),
      #("to", json.String("bravo@10.0.0.4")),
      #("phase", json.String("running")),
    ])
  let overview = deployment.to_json(deployment.overview(asker, [], [], []), 1)
  assert field(overview, "moves") == json.Array([expected])
  let one = deployment.to_json(deployment.selected(self, [asker]), 1)
  let assert json.Array([node]) = field(one, "nodes")
  assert field(field(node, "orchestrator"), "moves") == json.Array([expected])
}

// --- move candidates -----------------------------------------------------------------

fn orchestrator_node(
  name: String,
  node: String,
  health: deployment.Health,
  report: Option(NodeReport),
) -> deployment.Node {
  deployment.Node(
    node:,
    name:,
    roles: [OrchestratorRole],
    health:,
    report:,
    declared: None,
  )
}

fn accepting(
  node: String,
  imports: node_report.Imports,
  serves: List(String),
) -> NodeReport {
  let base = orchestrating(node, serves, [], [])
  case base.orchestrator {
    Some(facts) ->
      node_report.NodeReport(
        ..base,
        orchestrator: Some(node_report.OrchestratorFacts(..facts, imports:)),
      )
    None -> base
  }
}

fn move_candidate(name: String, eligibility: move_candidates.Eligibility) {
  move_candidates.Candidate(name, eligibility)
}

pub fn a_receiving_orchestrator_that_serves_the_executor_is_a_candidate_test() {
  let nodes = [
    orchestrator_node(
      "bravo",
      "bravo@10.0.0.4",
      Reachable,
      Some(
        accepting("bravo@10.0.0.4", node_report.Receiving, [
          "box@10.0.0.2",
        ]),
      ),
    ),
  ]
  assert deployment.candidates(nodes, self, Some("box@10.0.0.2"))
    == [move_candidate("bravo", Eligible)]
}

pub fn an_unreachable_closed_or_unserving_orchestrator_is_listed_with_its_reason_test() {
  let nodes = [
    orchestrator_node("down", "down@10.0.0.5", Down(Unreachable), None),
    orchestrator_node(
      "closed",
      "closed@10.0.0.6",
      Reachable,
      Some(
        accepting("closed@10.0.0.6", node_report.NotReceiving, [
          "box@10.0.0.2",
        ]),
      ),
    ),
    orchestrator_node(
      "elsewhere",
      "elsewhere@10.0.0.7",
      Impaired([deployment.BuildDiffers]),
      Some(
        accepting("elsewhere@10.0.0.7", node_report.Receiving, [
          "exec2@10.0.0.9",
        ]),
      ),
    ),
    orchestrator_node(
      "old",
      "old@10.0.0.8",
      Reachable,
      Some(bare("old@10.0.0.8")),
    ),
  ]
  assert deployment.candidates(nodes, self, Some("box@10.0.0.2"))
    == [
      move_candidate("down", Ineligible(move_candidates.Unreachable)),
      move_candidate("closed", Ineligible(move_candidates.NotAccepting)),
      move_candidate("elsewhere", Ineligible(move_candidates.NotServing)),
      move_candidate("old", Ineligible(move_candidates.NoReport)),
    ]
}

pub fn the_asking_daemon_and_executors_are_never_candidates_test() {
  let nodes = [
    orchestrator_node(
      "alpha",
      self,
      Reachable,
      Some(accepting(self, node_report.Receiving, ["box@10.0.0.2"])),
    ),
    deployment.Node(
      node: "box@10.0.0.2",
      name: "box",
      roles: [ExecutorRole],
      health: Reachable,
      report: None,
      declared: Some(box()),
    ),
  ]
  assert deployment.candidates(nodes, self, Some("box@10.0.0.2")) == []
}
