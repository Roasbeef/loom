//// `deployment.status` against the shipped daemon: an orchestrator and an
//// executor, two real `bin/loomd` processes that trust each other over TLS
//// distribution (protocol-change/085).
////
//// `daemon_deployment_test` proves the command's rules with the connections
//// scripted. This fixture proves the connections themselves, which only a real
//// pair of nodes can: the orchestrator's pinned connection to the executor
//// succeeds while the executor runs and fails once its process is gone, and the
//// reply says `ok` and then `down` from that alone.
////
//// ## What it proves
////
//// `daemon_shipped_deployment_test_`, one pair and no session.
////
//// - With both daemons up, the orchestrator reads its executor `ok`, the executor
////   `ready` for placement and the edge to it `connected`. A first TLS handshake
////   may outlast the read's one second, in which case the node is `down` in that
////   reply and the handshake finishes in the background, so the test asks again
////   until it is `ok` rather than assuming the first answer.
//// - After the executor's process is ended, the next read says `down` with a
////   reason word, the executor not `ready`, the edge `none`, and the verdict
////   `down`. The reads that follow keep saying so, because nothing is cached.
////
//// `daemon_shipped_deployment_scope_test_`, one pair and one session, what the
//// executor says of itself.
////
//// - A session attaches to the executor. The orchestrator's next read says the
////   executor is `ok` and holds one open scope, from the executor's own report.
//// - The executor's process is killed and started again on the same state, under
////   the open session, and the session is then stopped. The restarted executor
////   has no workspace for the scope, so it cannot prove the session's processes
////   are gone, and the scope blocks a reopen.
//// - The orchestrator's next reads say the executor is `degraded` with the
////   reason `unclean_scope`, and a read that names the executor lists the
////   session id.
//// - With the executor stopped, `loomd executor release` frees the scope. The
////   executor is started again and the orchestrator reads it `ok`, with no
////   scope that blocks a reopen.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// bash scripts/test.sh client --match 'client@daemon_shipped_deployment_test:'
//// ```
////
//// Without the shipment, or on a host whose helper cannot enforce a policy, the
//// fixture declines under its label as the other shipped fixtures do.

import client/tui_e2e_test.{type EunitTest}
import core/json.{type JsonValue}
import gleam/list
import gleam/string
import support/internal/ffi_proc
import support/remote_daemons.{type Control}
import support/remote_pair.{type Pair}
import weft/poll

const skip_label = "shipped deployment status"

// How long a read may keep asking before it is called wrong. A first handshake
// settles in the background within OTP's own bound of seven seconds.
const settle_ms = 30_000

/// Starts an orchestrator and an executor from the shipment, reads the
/// deployment while both run, ends the executor, and reads it again.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_deployment_test:'`.
pub fn daemon_shipped_deployment_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], drive)
}

fn drive(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.configure(prepared, keys, remote_pair.plain("http://127.0.0.1:9"))
  let _executor = remote_daemons.start(prepared.executor)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let control = remote_daemons.open_control(orchestrator)

  // Both nodes up: the executor is reachable, and the orchestrator says so in
  // the words the creation form reads.
  let up =
    until(control, 100, json.Object([]), fn(body) {
      node_state(body, remote_pair.executor_name) == "ok"
    })
  assert remote_daemons.field(up, "state") == json.String("ok")
  assert remote_daemons.field(up, "reasons") == json.Array([])
  assert placement_state(up) == "ready"
  assert edge_links(up) == [json.String("connected")]

  // The executor's process ends. The orchestrator's next connection attempt
  // fails, and the read says so and says why.
  remote_daemons.retire(prepared.executor.paths)
  let down =
    until(control, 400, json.Object([]), fn(body) {
      node_state(body, remote_pair.executor_name) == "down"
    })
  assert remote_daemons.field(down, "state") == json.String("down")
  assert placement_state(down) == "down"
  assert edge_links(down) == [json.String("none")]
  let assert json.String(reason) =
    remote_daemons.field(executor_node(down), "reason")
  assert list.contains(["timeout", "unreachable", "unavailable"], reason)
  remote_pair.close_daemons([orchestrator])
}

/// Starts an orchestrator and an executor from the shipment, attaches a session,
/// restarts the executor under it, and reads the scope that blocks a reopen
/// until an operator's release clears it.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_deployment_test:'`.
pub fn daemon_shipped_deployment_scope_test_() -> EunitTest {
  remote_pair.shipped(skip_label <> " scope", [], drive_scope)
}

fn drive_scope(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.configure(prepared, keys, remote_pair.plain("http://127.0.0.1:9"))
  let _executor = remote_daemons.start(prepared.executor)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let control = remote_daemons.open_control(orchestrator)

  // A session attaches to the executor, which holds one open scope for it and
  // says so in its own report.
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      1,
      "deployment-scope",
      remote_pair.executor_name,
      remote_pair.workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  let attached =
    until(control, 1000, json.Object([]), fn(body) {
      node_state(body, remote_pair.executor_name) == "ok"
      && open_scopes(body) == 1
    })
  assert remote_daemons.field(attached, "state") == json.String("ok")

  // The executor's process is killed and started again on the same state, under
  // the open session. The session is then stopped: the restarted executor has no
  // workspace for the scope, so it cannot prove the session's processes are gone.
  remote_daemons.crash(prepared.executor)
  let _restarted = remote_daemons.start(prepared.executor)
  remote_daemons.stop_session(orchestrator, control, 2000, session)

  // The executor is reachable and says why it is not ok.
  let degraded =
    until(control, 3000, json.Object([]), fn(body) {
      node_state(body, remote_pair.executor_name) == "degraded"
    })
  assert remote_daemons.field(degraded, "state") == json.String("degraded")
  assert remote_daemons.field(degraded, "reasons")
    == json.Array([
      json.Object([
        #("node", remote_daemons.field(executor_node(degraded), "node")),
        #("reason", json.String("unclean_scope")),
      ]),
    ])
  assert placement_state(degraded) == "degraded"
  assert edge_links(degraded) == [json.String("connected")]

  // A read that names the executor lists the session that needs the release.
  let named =
    until(
      control,
      4000,
      json.Object([#("node", json.String(remote_pair.executor_name))]),
      fn(body) { node_state(body, remote_pair.executor_name) == "degraded" },
    )
  let facts = remote_daemons.field(executor_node(named), "executor")
  let assert json.Array([scope]) = remote_daemons.field(facts, "unclean")
  assert remote_daemons.field(scope, "session") == json.String(session)
  assert remote_daemons.field(facts, "workspaces")
    == json.Array([json.String(remote_pair.workspace_name)])

  // The operator stops the executor, releases the scope with the command the
  // setup guide names, and starts the executor again. The next read is `ok`.
  remote_daemons.retire(prepared.executor.paths)
  let assert Ok(#(0, released)) =
    ffi_proc.run(
      prepared.executor.launcher,
      [
        "executor",
        "release",
        session,
        "--state-dir",
        prepared.executor.paths.root,
      ],
      prepared.executor.directory,
    )
    as "loomd executor release frees the scope"
  assert string.contains(released, session)
  let _again = remote_daemons.start(prepared.executor)
  let cleared =
    until(control, 5000, json.Object([]), fn(body) {
      node_state(body, remote_pair.executor_name) == "ok"
    })
  assert remote_daemons.field(cleared, "state") == json.String("ok")
  assert remote_daemons.field(cleared, "reasons") == json.Array([])
  assert placement_state(cleared) == "ready"
  remote_pair.close_daemons([orchestrator])
}

// How many scopes the executor says are open.
fn open_scopes(body: JsonValue) -> Int {
  let facts = remote_daemons.field(executor_node(body), "executor")
  let assert json.Int(open) =
    remote_daemons.field(remote_daemons.field(facts, "scopes"), "open")
  open
}

// Asks until `settled` holds of the reply body, spending a new command id on
// each ask because the control protocol wants ids that grow. `request` is the
// body of each ask: empty for the whole deployment, or a `node` key.
fn until(
  control: Control,
  first_id: Int,
  request: JsonValue,
  settled: fn(JsonValue) -> Bool,
) -> JsonValue {
  let assert poll.Answer(body) =
    poll.fold_until(
      clock: poll.monotonic(),
      within: settle_ms,
      every: poll.Fixed(500),
      from: first_id,
      attempt: fn(id) {
        let reply =
          remote_daemons.command(control, id, "deployment.status", request)
        let body = remote_daemons.field(reply, "body")
        case settled(body) {
          True -> poll.Settled(body)
          False -> poll.Pending(id + 1)
        }
      },
    )
    as "the deployment reads as expected within the bound"
  body
}

fn executor_node(body: JsonValue) -> JsonValue {
  let assert json.Array(nodes) = remote_daemons.field(body, "nodes")
  let assert Ok(found) =
    list.find(nodes, fn(node) {
      remote_daemons.field(node, "name")
      == json.String(remote_pair.executor_name)
    })
    as "the executor is among the nodes"
  found
}

fn node_state(body: JsonValue, name: String) -> String {
  let assert json.Array(nodes) = remote_daemons.field(body, "nodes")
  let found =
    list.find(nodes, fn(node) {
      remote_daemons.field(node, "name") == json.String(name)
    })
  case found {
    Ok(node) -> {
      let assert json.String(state) = remote_daemons.field(node, "state")
      state
    }
    Error(Nil) -> "absent"
  }
}

fn placement_state(body: JsonValue) -> String {
  let placements = remote_daemons.field(body, "placements")
  let assert json.Array([executor]) =
    remote_daemons.field(placements, "executors")
  let assert json.String(state) = remote_daemons.field(executor, "state")
  state
}

fn edge_links(body: JsonValue) -> List(JsonValue) {
  let assert json.Array(edges) = remote_daemons.field(body, "edges")
  list.map(edges, fn(edge) { remote_daemons.field(edge, "link") })
}
