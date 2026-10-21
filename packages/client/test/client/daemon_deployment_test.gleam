//// The owner's `deployment.status` command across the real control socket
//// (protocol-change/085). The registry is real, the session assembly is inert
//// and the connections are a function the test supplies, so these tests prove
//// what the socket does: who may ask, which nodes the daemon connects to, what
//// the reply says of a node that answers and of one that does not, and that a
//// key from a request never becomes a connection. Two real daemons are
//// `daemon_shipped_deployment_test`.

import client/daemon/limits
import client/daemon/root
import client/daemon_server_test as wire
import client/deployment
import client/listed_sessions
import client/node_report.{type NodeReport}
import client/orchestrators
import client/remote/orchestrator_port
import client/remote/protocol as remote_protocol
import client/roster
import client/session_directory
import client/session_movers
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import support/internal/ffi_ws
import weft/actor

const self = "alpha@10.0.0.1"

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

fn has(value, key) -> Bool {
  case value {
    json.Object(fields) -> list.key_find(fields, key) != Error(Nil)
    _ -> False
  }
}

fn code(reply) {
  field(field(reply, "body"), "code")
}

// The nodes the daemon connected to, in the order it did. The wire fixture runs
// its body in a worker and the connections run in tasks of their own, and a
// subject can be read only by its owner, so the record is an actor any of them
// can reach.
type Note {
  Dialled(node: String)
  Drain(reply: process.Subject(List(String)))
}

fn record(told: List(String), note: Note) -> actor.Next(List(String), Note) {
  case note {
    Dialled(node:) -> actor.continue([node, ..told])
    Drain(reply:) -> {
      process.send(reply, list.reverse(told))
      actor.continue([])
    }
  }
}

fn recorder() -> process.Subject(Note) {
  let assert Ok(started) =
    actor.new([]) |> actor.on_message(record) |> actor.start
    as "the recorder starts"
  started.data
}

fn dialled(recorder: process.Subject(Note)) -> List(String) {
  process.call(recorder, 1000, Drain)
}

fn desk() {
  orchestrators.plain("desk", "desk@10.0.0.8")
}

fn laptop() {
  orchestrators.plain("laptop", "laptop@10.0.0.7")
}

// What a node says of itself when it says nothing more than who it is. Every
// node of these tests runs one build, so none differs from the daemon's own.
fn bare(node: String) -> NodeReport {
  node_report.bare(node, "0.3.0", "abc123", "e1", 1000, 61_000)
}

// A report of an executor with a scope that blocks a reopen, and the session it
// names, among workspaces it has registered.
fn unclean_executor(node: String, session: String) -> NodeReport {
  node_report.NodeReport(
    ..bare(node),
    executor: Some(node_report.ExecutorFacts(
      protocol: remote_protocol.version,
      scopes: node_report.ScopeCounts(
        open: 2,
        closing: 0,
        closed_clean: 1,
        closed_unknown: 1,
      ),
      scope_limit: 16,
      unclean: [
        node_report.UncleanScope(
          session:,
          state: node_report.UnknownCleanup(count: 2),
        ),
      ],
      ledger_bytes: 4096,
      ledger_limit: 536_870_912,
      unacknowledged: 0,
      platform: "linux/x86_64",
      observed: None,
      workspaces: ["proj", "docs"],
      worktrees: option.None,
    )),
  )
}

// A daemon whose executor `build-box` is on `executor@10.0.0.2` and whose
// orchestrators are `desk` and `laptop`. The connections answer from `answers`,
// by node, and refuse any other node as an unreachable host is refused. Every
// connected node reports only who it is.
fn deploying(
  answers: List(#(String, Result(Nil, deployment.Why))),
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  reporting(answers, fn(node, _within_ms) { Ok(bare(node)) }, run)
}

// The same daemon with the answer to a report ask scripted by node.
fn reporting(
  answers: List(#(String, Result(Nil, deployment.Why))),
  ask: fn(String, Int) -> Result(NodeReport, orchestrator_port.Silence),
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  let told = recorder()
  let reach =
    deployment.Reach(
      self:,
      self_name: self,
      footing: deployment.Distributed,
      host: Some("studio"),
      dial: fn(node, _within_ms) {
        process.send(told, Dialled(node))
        case list.key_find(answers, node) {
          Ok(outcome) -> outcome
          Error(Nil) -> Error(deployment.Unreachable)
        }
      },
      ask:,
      sessions: listed_sessions.unlisted,
      own: fn() { bare(self) },
    )
  let movers =
    session_movers.Control(
      ..session_movers.idle(),
      orchestrators: roster.fixed([desk(), laptop()]),
    )
  wire.fixture_reaching(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    movers,
    reach,
    fn(_, ready, port, credential) { run(ready, port, credential, told) },
  )
}

fn status(socket, id, body) {
  wire.send(socket, id, "deployment.status", body, within_ms: 6000)
}

pub fn the_owner_reads_every_configured_node_as_the_daemon_found_it_test() {
  deploying(
    [
      #("desk@10.0.0.8", Ok(Nil)),
      #("laptop@10.0.0.7", Ok(Nil)),
      #("executor@10.0.0.2", Error(deployment.TimedOut)),
    ],
    fn(_ready, port, credential, told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply = status(socket, 1, json.Object([]))
      assert field(reply, "event") == json.String("deployment.status")
      let body = field(reply, "body")
      assert field(body, "self") == json.String(self)
      assert field(body, "distribution") == json.String("configured")
      assert field(body, "host") == json.String("studio")
      assert field(body, "state") == json.String("degraded")
      assert field(body, "reasons")
        == json.Array([
          json.Object([
            #("node", json.String("executor@10.0.0.2")),
            #("reason", json.String("timeout")),
          ]),
        ])

      // The daemon first, then its orchestrators, then its executors.
      let assert json.Array(nodes) = field(body, "nodes")
      assert list.map(nodes, fn(node) { field(node, "name") })
        == [
          json.String(self),
          json.String("desk"),
          json.String("laptop"),
          json.String("build-box"),
        ]
      assert list.map(nodes, fn(node) { field(node, "state") })
        == [
          json.String("ok"),
          json.String("ok"),
          json.String("ok"),
          json.String("down"),
        ]
      let assert [_, _, _, down] = nodes
      assert field(down, "reason") == json.String("timeout")

      // The asking daemon states itself from its own report, marked as the
      // asker, and a node that is down states no report at all.
      let assert [asking, desk, ..] = nodes
      assert field(asking, "self") == json.Bool(True)
      assert field(asking, "roles") == json.Array([json.String("orchestrator")])
      assert field(asking, "state") == json.String("ok")
      assert field(asking, "build_commit") == json.String("abc123")
      assert field(asking, "uptime_ms") == json.Int(60_000)
      assert field(desk, "build_version") == json.String("0.3.0")
      assert !has(down, "build_commit")

      // The executor and its pool are described for a creation form, and the
      // unreachable executor leaves its pool with nobody eligible.
      let placements = field(body, "placements")
      let assert json.Array([executor]) = field(placements, "executors")
      assert field(executor, "name") == json.String("build-box")
      assert field(executor, "state") == json.String("down")
      assert field(placements, "pools")
        == json.Array([
          json.Object([
            #("name", json.String("builders")),
            #("executors", json.Array([json.String("build-box")])),
            #("eligible", json.Array([])),
          ]),
        ])
      let _ = ffi_ws.tcp_close(socket)
      assert list.sort(dialled(told), string.compare)
        == ["desk@10.0.0.8", "executor@10.0.0.2", "laptop@10.0.0.7"]
    },
  )
}

pub fn a_reachable_executor_is_ready_and_its_pool_has_a_candidate_test() {
  deploying(
    [
      #("desk@10.0.0.8", Ok(Nil)),
      #("laptop@10.0.0.7", Ok(Nil)),
      #("executor@10.0.0.2", Ok(Nil)),
    ],
    fn(_ready, port, credential, _told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body = field(status(socket, 1, json.Object([])), "body")
      assert field(body, "state") == json.String("ok")
      assert field(body, "reasons") == json.Array([])
      let placements = field(body, "placements")
      let assert json.Array([executor]) = field(placements, "executors")
      assert field(executor, "state") == json.String("ready")
      let assert json.Array([pool]) = field(placements, "pools")
      assert field(pool, "eligible") == json.Array([json.String("build-box")])

      // The daemon's relation to each node, with its own link.
      let assert json.Array(edges) = field(body, "edges")
      assert list.map(edges, fn(edge) { field(edge, "link") })
        == [
          json.String("connected"),
          json.String("connected"),
          json.String("connected"),
        ]
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

pub fn a_node_that_refuses_the_connection_is_down_with_the_reason_test() {
  deploying([], fn(_ready, port, credential, _told) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let body = field(status(socket, 1, json.Object([])), "body")

    // Not one configured node answered, so the deployment itself is down.
    assert field(body, "state") == json.String("down")
    let assert json.Array(nodes) = field(body, "nodes")
    let assert [_, desk, ..] = nodes
    assert field(desk, "state") == json.String("down")
    assert field(desk, "reason") == json.String("unreachable")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_key_narrows_the_read_to_the_node_it_names_test() {
  deploying(
    [#("executor@10.0.0.2", Ok(Nil)), #("desk@10.0.0.8", Ok(Nil))],
    fn(_ready, port, credential, told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body =
        field(
          status(socket, 1, json.Object([#("node", json.String("build-box"))])),
          "body",
        )
      let assert json.Array([node]) = field(body, "nodes")
      assert field(node, "name") == json.String("build-box")
      assert field(node, "state") == json.String("ok")
      assert !has(body, "edges")
      assert !has(body, "placements")
      assert !has(body, "orchestrators")
      assert !has(body, "distribution")
      let _ = ffi_ws.tcp_close(socket)
      assert dialled(told) == ["executor@10.0.0.2"]
    },
  )
}

pub fn a_key_that_is_not_configured_is_not_found_and_dials_nobody_test() {
  deploying(
    [#("executor@10.0.0.2", Ok(Nil)), #("evil@10.0.0.66", Ok(Nil))],
    fn(_ready, port, credential, told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let ask = fn(id, node) {
        status(socket, id, json.Object([#("node", json.String(node))]))
      }

      // A well-formed key the configuration lacks.
      assert code(ask(1, "ghost")) == json.String("not_found")

      // A node name is not a key, even one the connection function would answer
      // for, and is refused before the configuration is consulted.
      assert code(ask(2, "evil@10.0.0.66")) == json.String("bad_request")
      assert code(ask(3, "executor@10.0.0.2")) == json.String("bad_request")
      let _ = ffi_ws.tcp_close(socket)
      assert dialled(told) == []
    },
  )
}

pub fn a_member_may_not_read_the_deployment_test() {
  deploying(
    [#("executor@10.0.0.2", Ok(Nil))],
    fn(ready, port, _credential, told) {
      let member_token = string.repeat("4", 64)
      let assert Ok(digest) =
        member_token
        |> bit_array.from_string
        |> bootstrap.sha256
        |> bit_array.base16_encode
        |> string.lowercase
        |> access.credential_digest
        as "member digest is valid"
      let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
        as "fixture administration opens the durable catalogue"
      let assert Ok(_) = access.create_member(store, "reader", "R", digest)
        as "the member exists"
      let #(socket, _) = wire.connect(port, member_token, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)

      // The refusal comes before any connection is made, so a member cannot make
      // the daemon dial anything either.
      assert code(status(socket, 1, json.Object([])))
        == json.String("forbidden")
      assert code(status(
          socket,
          2,
          json.Object([#("node", json.String("desk"))]),
        ))
        == json.String("forbidden")
      let _ = ffi_ws.tcp_close(socket)
      assert catalogue.close(store) == Ok(Nil)
      assert dialled(told) == []
    },
  )
}

pub fn a_daemon_with_no_peers_answers_with_itself_alone_test() {
  wire.fixture(fn(_, _ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // The default fixture lists an executor on a placeholder node and has no
    // distribution, so its one executor is down and the daemon says so, and
    // the reply says the daemon runs without distribution, which is why the
    // Admin page does not draw the name `nonode@nohost`.
    let body = field(status(socket, 1, json.Object([])), "body")
    assert field(body, "self") == json.String("nonode@nohost")
    assert field(body, "distribution") == json.String("none")
    let assert json.Array([asking, executor]) = field(body, "nodes")
    assert field(asking, "state") == json.String("ok")
    assert field(executor, "state") == json.String("down")
    assert field(executor, "reason") == json.String("unavailable")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// A node that answers with a scope that blocks a reopen is `degraded` with the
// reason word, counts as reachable, and leaves the deployment degraded without
// it being down. The overview states the numbers and not the session ids.
pub fn a_node_with_an_unclean_scope_is_degraded_not_down_test() {
  reporting(
    [
      #("desk@10.0.0.8", Ok(Nil)),
      #("laptop@10.0.0.7", Ok(Nil)),
      #("executor@10.0.0.2", Ok(Nil)),
    ],
    fn(node, _within_ms) {
      case node {
        "executor@10.0.0.2" -> Ok(unclean_executor(node, "0198c0de-1"))
        _ -> Ok(bare(node))
      }
    },
    fn(_ready, port, credential, _told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body = field(status(socket, 1, json.Object([])), "body")
      assert field(body, "state") == json.String("degraded")
      assert field(body, "reasons")
        == json.Array([
          json.Object([
            #("node", json.String("executor@10.0.0.2")),
            #("reason", json.String("unclean_scope")),
          ]),
        ])
      let assert json.Array([_, _, _, executor]) = field(body, "nodes")
      assert field(executor, "state") == json.String("degraded")
      assert field(executor, "reasons")
        == json.Array([json.String("unclean_scope")])
      assert !has(field(executor, "executor"), "unclean")

      // The executor card says the executor is degraded and has 13 scopes free
      // (16 less 2 open and 1 that blocks a reopen).
      let assert json.Array([card]) =
        field(field(body, "placements"), "executors")
      assert field(card, "state") == json.String("degraded")
      assert field(card, "free_scopes") == json.Int(13)
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

// The `node` filter returns the long lists the overview leaves out: the names of
// the registered workspaces and each scope that blocks a reopen with its session.
pub fn the_node_filter_returns_the_long_lists_test() {
  reporting(
    [#("executor@10.0.0.2", Ok(Nil))],
    fn(node, _within_ms) { Ok(unclean_executor(node, "0198c0de-1")) },
    fn(_ready, port, credential, _told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body =
        field(
          status(socket, 1, json.Object([#("node", json.String("build-box"))])),
          "body",
        )
      let assert json.Array([node]) = field(body, "nodes")
      let executor = field(node, "executor")
      assert field(executor, "workspaces")
        == json.Array([json.String("proj"), json.String("docs")])
      assert field(executor, "unclean")
        == json.Array([
          json.Object([
            #("session", json.String("0198c0de-1")),
            #("state", json.String("unknown_cleanup")),
            #("count", json.Int(2)),
          ]),
        ])
      assert field(node, "state") == json.String("degraded")
      assert !has(body, "directory")
      assert !has(body, "moves")
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

// A node that connects and does not report within the deadline is down with the
// reason `timeout`, the daemon's own facts and the other nodes' are still
// returned, and the reply comes by the deadline and not when the ask would have
// ended.
pub fn a_node_that_connects_and_reports_late_is_down_test() {
  reporting(
    [
      #("desk@10.0.0.8", Ok(Nil)),
      #("laptop@10.0.0.7", Ok(Nil)),
      #("executor@10.0.0.2", Ok(Nil)),
    ],
    fn(node, _within_ms) {
      case node {
        "laptop@10.0.0.7" -> {
          process.sleep(60_000)
          Error(orchestrator_port.AskTimedOut)
        }
        _ -> Ok(bare(node))
      }
    },
    fn(_ready, port, credential, _told) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body = field(status(socket, 1, json.Object([])), "body")
      assert field(body, "state") == json.String("degraded")
      let assert json.Array([asking, desk, laptop, executor]) =
        field(body, "nodes")
      assert field(asking, "state") == json.String("ok")
      assert field(desk, "state") == json.String("ok")
      assert field(laptop, "state") == json.String("down")
      assert field(laptop, "reason") == json.String("timeout")
      assert !has(laptop, "build_commit")
      assert field(executor, "state") == json.String("ok")
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}
