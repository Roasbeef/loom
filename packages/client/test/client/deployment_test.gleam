//// `client/deployment`: what a daemon says about the nodes it is configured
//// with. The connections are a function the test supplies, so these tests
//// prove the read's rules: which nodes are dialled, what a failed or late
//// connection reads as, how pools and executors are described, and what the
//// reply says. The connection layer itself is `distribution_test`, and two real
//// daemons are `daemon_shipped_deployment_test`.

import client/deployment.{
  Connected, Down, ExecutorRole, OrchestratorRole, Reachable, Target, TimedOut,
  Unavailable, Unlinked, Unreachable,
}
import client/executors
import client/orchestrators
import client/pools
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

// A reach whose connections answer from a table of node to outcome, and report
// every node it was asked to connect to on `asked`. A node the table does not
// list is refused as an unreachable host is.
fn reach(
  answers: List(#(String, Result(Nil, deployment.Why))),
  asked: process.Subject(String),
) {
  deployment.Reach(self:, dial: fn(node, _within_ms) {
    process.send(asked, node)
    case list.key_find(answers, node) {
      Ok(outcome) -> outcome
      Error(Nil) -> Error(Unreachable)
    }
  })
}

fn dialled(asked: process.Subject(String)) -> List(String) {
  case process.receive(asked, 0) {
    Ok(node) -> [node, ..dialled(asked)]
    Error(Nil) -> []
  }
}

pub fn the_configured_nodes_are_orchestrators_then_executors_test() {
  assert deployment.targets([bravo()], [box(), exec2()])
    == [
      Target("bravo", "bravo@10.0.0.4", deployment.OrchestratorRow),
      Target("box", "box@10.0.0.2", deployment.ExecutorRow),
      Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow),
    ]
}

pub fn a_key_selects_only_the_nodes_configured_under_it_test() {
  let configured = deployment.targets([bravo()], [box(), exec2()])
  assert deployment.only(configured, "box")
    == Ok([Target("box", "box@10.0.0.2", deployment.ExecutorRow)])

  // A key is matched among the configured targets and is never read as a node
  // name, so the node itself, a prefix and the empty string select nothing.
  assert deployment.only(configured, "box@10.0.0.2") == Error(Nil)
  assert deployment.only(configured, "bo") == Error(Nil)
  assert deployment.only(configured, "") == Error(Nil)
}

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
        asked,
      ),
      deployment.targets([bravo()], [box(), exec2()]),
    )
  assert list.map(probed, fn(found) { #(found.0.name, found.1) })
    == [
      #("bravo", Reachable),
      #("box", Reachable),
      #("exec2", Down(TimedOut)),
    ]
}

pub fn a_connection_that_never_settles_reads_as_down_by_the_deadline_test() {
  // The dial sleeps far past `deadline_ms`. The run's deadline cuts it off, and
  // a node nothing was heard from is down, never assumed up.
  let stuck =
    deployment.Reach(self:, dial: fn(_node, _within_ms) {
      process.sleep(60_000)
      Ok(Nil)
    })
  let probed = deployment.probe(stuck, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.1 }) == [Down(TimedOut)]
}

pub fn a_connection_that_crashes_reads_as_down_test() {
  let crashing =
    deployment.Reach(self:, dial: fn(_node, _within_ms) { panic as "boom" })
  let probed = deployment.probe(crashing, deployment.targets([], [box()]))
  assert list.map(probed, fn(found) { found.1 }) == [Down(Unavailable)]
}

pub fn no_target_is_no_connection_test() {
  let asked = process.new_subject()
  assert deployment.probe(reach([], asked), []) == []
  assert dialled(asked) == []
}

pub fn a_key_the_configuration_lacks_dials_nobody_test() {
  let asked = process.new_subject()
  let answers = [#("box@10.0.0.2", Ok(Nil)), #("ghost@10.0.0.66", Ok(Nil))]

  // The key is a name from a request. It is neither configured nor a node, so
  // the answer is `Error(Nil)` and no node, the configured ones included, was
  // dialled.
  assert deployment.status(
      reach(answers, asked),
      [OrchestratorRole],
      [bravo()],
      [box()],
      [],
      Some("ghost"),
    )
    == Error(Nil)
  assert deployment.status(
      reach(answers, asked),
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
      reach([#("box@10.0.0.2", Ok(Nil))], asked),
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
  let assert Ok(deployment.Overview(self: asking, others:, ..)) =
    deployment.status(
      reach([], asked),
      [OrchestratorRole],
      [bravo()],
      [box(), exec2()],
      [],
      None,
    )
  assert list.sort(dialled(asked), string.compare)
    == ["box@10.0.0.2", "bravo@10.0.0.4", "exec2@10.0.0.9"]
  assert asking.node == self
  assert asking.health == Reachable
  assert list.map(others, fn(node) { node.name }) == ["bravo", "box", "exec2"]
}

pub fn an_executor_is_ready_when_reachable_and_down_when_not_test() {
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Reachable),
    #(Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow), Down(TimedOut)),
  ]
  let assert deployment.Overview(placements:, ..) =
    deployment.overview(self, [OrchestratorRole], probed, [box(), exec2()], [])
  assert placements.executors
    == [
      deployment.ExecutorEntry(box(), Reachable),
      deployment.ExecutorEntry(exec2(), Down(TimedOut)),
    ]
}

pub fn a_pool_lists_its_candidates_in_trial_order_and_marks_the_reachable_test() {
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Reachable),
    #(
      Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow),
      Down(Unreachable),
    ),
  ]
  let assert deployment.Overview(placements:, ..) =
    deployment.overview(self, [OrchestratorRole], probed, [box(), exec2()], [
      builders(),
    ])

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
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Reachable),
    #(Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow), Reachable),
  ]
  let assert deployment.Overview(placements:, ..) =
    deployment.overview(self, [OrchestratorRole], probed, [box(), exec2()], [
      linux_only(),
    ])

  // `box` declares nothing, so a pool that requires a platform cannot admit it.
  assert placements.pools
    == [
      deployment.PoolEntry(name: "linux", executors: ["exec2"], eligible: [
        "exec2",
      ]),
    ]
}

pub fn a_pool_with_every_member_down_has_nobody_eligible_test() {
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Down(TimedOut)),
    #(Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow), Down(TimedOut)),
  ]
  let assert deployment.Overview(placements:, ..) =
    deployment.overview(self, [OrchestratorRole], probed, [box(), exec2()], [
      builders(),
    ])
  let assert [deployment.PoolEntry(eligible: [], executors: [_, _], ..)] =
    placements.pools
}

pub fn the_edges_touch_the_asking_daemon_and_carry_its_own_link_test() {
  let probed = [
    #(Target("bravo", "bravo@10.0.0.4", deployment.OrchestratorRow), Reachable),
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Reachable),
    #(Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow), Down(TimedOut)),
  ]
  let assert deployment.Overview(edges:, ..) =
    deployment.overview(self, [OrchestratorRole], probed, [box(), exec2()], [])
  assert edges
    == [
      deployment.Edge(self, "bravo@10.0.0.4", deployment.Peers, Connected),
      deployment.Edge(self, "box@10.0.0.2", deployment.Serves, Connected),
      deployment.Edge(self, "exec2@10.0.0.9", deployment.Serves, Unlinked),
    ]
}

pub fn the_deployment_is_down_only_when_no_configured_node_answers_test() {
  let node = fn(health) {
    deployment.Node("n@10.0.0.1", "n", [ExecutorRole], health)
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
      deployment.Node("x@10.0.0.9", "x", [ExecutorRole], Down(Unavailable)),
    ])
    == [#("x@10.0.0.9", "unavailable")]
}

pub fn the_reply_states_each_node_its_edges_and_its_placements_test() {
  let probed = [
    #(Target("bravo", "bravo@10.0.0.4", deployment.OrchestratorRow), Reachable),
    #(Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow), Down(TimedOut)),
  ]
  let body =
    deployment.overview(
      self,
      [OrchestratorRole, deployment.MemberRole],
      probed,
      [exec2()],
      [builders_of_exec2()],
    )
    |> deployment.to_json(1_760_190_131_000)
  assert body
    == json.Object([
      #("as_of_ms", json.Int(1_760_190_131_000)),
      #("self", json.String(self)),
      #("state", json.String("degraded")),
      #(
        "reasons",
        json.Array([
          json.Object([
            #("node", json.String("exec2@10.0.0.9")),
            #("reason", json.String("timeout")),
          ]),
        ]),
      ),
      #(
        "nodes",
        json.Array([
          json.Object([
            #("node", json.String(self)),
            #("name", json.String(self)),
            #(
              "roles",
              json.Array([json.String("orchestrator"), json.String("member")]),
            ),
            #("state", json.String("ok")),
          ]),
          json.Object([
            #("node", json.String("bravo@10.0.0.4")),
            #("name", json.String("bravo")),
            #("roles", json.Array([json.String("orchestrator")])),
            #("state", json.String("ok")),
          ]),
          json.Object([
            #("node", json.String("exec2@10.0.0.9")),
            #("name", json.String("exec2")),
            #("roles", json.Array([json.String("executor")])),
            #("state", json.String("down")),
            #("reason", json.String("timeout")),
          ]),
        ]),
      ),
      #(
        "edges",
        json.Array([
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
            #("link", json.String("none")),
          ]),
        ]),
      ),
      #(
        "placements",
        json.Object([
          #(
            "executors",
            json.Array([
              json.Object([
                #("name", json.String("exec2")),
                #("node", json.String("exec2@10.0.0.9")),
                #("state", json.String("down")),
                #(
                  "declared",
                  json.Object([
                    #("platform", json.String("linux/x86_64")),
                    #("enforcement", json.String("enforced")),
                    #("toolchains", json.Array([json.String("codemode")])),
                  ]),
                ),
              ]),
            ]),
          ),
          #(
            "pools",
            json.Array([
              json.Object([
                #("name", json.String("only-exec2")),
                #("executors", json.Array([json.String("exec2")])),
                #("eligible", json.Array([])),
              ]),
            ]),
          ),
        ]),
      ),
      #(
        "orchestrators",
        json.Array([
          json.Object([
            #("name", json.String("bravo")),
            #("node", json.String("bravo@10.0.0.4")),
            #("state", json.String("ok")),
          ]),
        ]),
      ),
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

pub fn an_executor_that_declares_nothing_states_an_empty_toolchain_list_test() {
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Reachable),
  ]
  let body =
    deployment.overview(self, [OrchestratorRole], probed, [box()], [])
    |> deployment.to_json(1)
  let assert json.Object(members) = body
  let assert Ok(json.Object(placements)) = list.key_find(members, "placements")
  let assert Ok(json.Array([json.Object(entry)])) =
    list.key_find(placements, "executors")
  assert list.key_find(entry, "state") == Ok(json.String("ready"))
  assert list.key_find(entry, "declared")
    == Ok(json.Object([#("toolchains", json.Array([]))]))
}

pub fn a_selected_reply_holds_only_the_named_nodes_test() {
  let probed = [
    #(Target("box", "box@10.0.0.2", deployment.ExecutorRow), Down(Unreachable)),
  ]
  let body = deployment.selected(self, probed) |> deployment.to_json(5)
  let assert json.Object(members) = body
  assert list.map(members, fn(member) { member.0 })
    == ["as_of_ms", "self", "state", "reasons", "nodes"]
  assert list.key_find(members, "state") == Ok(json.String("down"))
}

pub fn every_reason_has_its_own_word_test() {
  assert deployment.why_word(TimedOut) == "timeout"
  assert deployment.why_word(Unreachable) == "unreachable"
  assert deployment.why_word(Unavailable) == "unavailable"
}

pub fn a_daemon_without_distribution_names_itself_and_connects_to_nobody_test() {
  let alone = deployment.alone("nonode@nohost")
  assert alone.self == "nonode@nohost"
  assert alone.dial("anywhere@10.0.0.1", 1000) == Error(Unavailable)
  let assert Ok(deployment.Overview(self: asking, others: [], edges: [], ..)) =
    deployment.status(alone, [OrchestratorRole], [], [], [], None)
  assert asking.node == "nonode@nohost"
}

// The creation panel's read connects to the executors and to nothing else: the
// orchestrators are not its business, and a slow one must not delay the cards.
pub fn the_creation_panel_reads_the_executors_alone_test() {
  let asked = process.new_subject()
  let placed =
    deployment.placed(
      reach(
        [#("box@10.0.0.2", Ok(Nil)), #("exec2@10.0.0.9", Error(TimedOut))],
        asked,
      ),
      [box(), exec2()],
      [builders()],
    )
  assert list.sort(dialled(asked), string.compare)
    == ["box@10.0.0.2", "exec2@10.0.0.9"]
  assert placed.executors
    == [
      deployment.ExecutorEntry(box(), Reachable),
      deployment.ExecutorEntry(exec2(), Down(TimedOut)),
    ]
  assert placed.pools
    == [
      deployment.PoolEntry(
        name: "builders",
        executors: ["exec2", "box"],
        eligible: ["box"],
      ),
    ]
}

// What the page is told: each executor's state and what its operator declared,
// each pool's trial order and reachable members, and no node name, address or
// key. The report has nothing for a free scope count or a contradiction yet.
pub fn the_page_is_told_states_and_declarations_and_no_node_test() {
  let placed =
    deployment.Placements(
      executors: [
        deployment.ExecutorEntry(box(), Reachable),
        deployment.ExecutorEntry(exec2(), Down(Unreachable)),
      ],
      pools: [
        deployment.PoolEntry(
          name: "builders",
          executors: ["exec2", "box"],
          eligible: ["box"],
        ),
      ],
    )
  assert deployment.for_page(placed)
    == page.Placements(
      executors: [
        page.Executor(
          "box",
          Some(page.Report(
            state: page.Ready,
            free_scopes: None,
            platform: None,
            enforcement: None,
            toolchains: [],
            contradiction: None,
          )),
        ),
        page.Executor(
          "exec2",
          Some(page.Report(
            state: page.Down,
            free_scopes: None,
            platform: Some("linux/x86_64"),
            enforcement: Some("enforced"),
            toolchains: ["codemode"],
            contradiction: None,
          )),
        ),
      ],
      pools: [
        page.Pool(
          "builders",
          Some(page.PoolReport(executors: ["exec2", "box"], eligible: ["box"])),
        ),
      ],
    )
}

// The reply's `state` is the verdict on the configured nodes, and the asking
// daemon, which is always reachable, is not one of them: with every other node
// gone the deployment reads down and not degraded.
pub fn the_replys_state_follows_the_verdict_on_the_configured_nodes_test() {
  let state = fn(probed) {
    let assert json.Object(members) =
      deployment.overview(
        self,
        [OrchestratorRole],
        probed,
        [box(), exec2()],
        [],
      )
      |> deployment.to_json(1)
    let assert Ok(found) = list.key_find(members, "state")
    found
  }
  let box_row = Target("box", "box@10.0.0.2", deployment.ExecutorRow)
  let exec_row = Target("exec2", "exec2@10.0.0.9", deployment.ExecutorRow)

  // No configured node at all, so nothing is wrong.
  assert state([]) == json.String("ok")
  assert state([#(box_row, Reachable), #(exec_row, Reachable)])
    == json.String("ok")
  assert state([#(box_row, Reachable), #(exec_row, Down(TimedOut))])
    == json.String("degraded")
  assert state([#(box_row, Down(Unreachable)), #(exec_row, Down(TimedOut))])
    == json.String("down")
}
