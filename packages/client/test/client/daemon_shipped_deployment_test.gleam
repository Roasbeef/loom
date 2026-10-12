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
    until(control, 100, fn(body) {
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
    until(control, 400, fn(body) {
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

// Asks until `settled` holds of the reply body, spending a new command id on
// each ask because the control protocol wants ids that grow.
fn until(
  control: Control,
  first_id: Int,
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
          remote_daemons.command(
            control,
            id,
            "deployment.status",
            json.Object([]),
          )
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
