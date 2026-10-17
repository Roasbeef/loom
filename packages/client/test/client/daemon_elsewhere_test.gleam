//// The owner's `sessions.elsewhere` command across the real control socket
//// (protocol-change/085). The registry is real, the session assembly is inert,
//// and the connections and the peers' pages are functions the test supplies, so
//// these tests prove what the socket does: who may ask, which orchestrators the
//// daemon connects to, what the reply says of one that answers and of one that
//// does not, how a request names a group's next page, and that the reply stays
//// inside its byte bound. The port that answers a page is
//// `orchestrator_port_test`, and two real daemons are
//// `daemon_shipped_directory_test`.

import client/daemon/limits
import client/daemon/root
import client/daemon_server_test as wire
import client/deployment
import client/listed_sessions.{type Page, Further, Last, Page, Row}
import client/node_report
import client/orchestrators
import client/remote/orchestrator_port
import client/roster
import client/session_directory
import client/session_movers
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/int
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

// What the daemon did, in order: a node it connected to, and a page it asked
// of one. The wire fixture runs its body in a worker and the connections run in
// tasks of their own, and a subject can be read only by its owner, so the record
// is an actor any of them can reach.
type Note {
  Dialled(node: String)
  Asked(node: String, after: String, limit: Int)
  Drain(reply: process.Subject(List(Note)))
}

fn record(told: List(Note), note: Note) -> actor.Next(List(Note), Note) {
  case note {
    Drain(reply:) -> {
      process.send(reply, list.reverse(told))
      actor.continue([])
    }
    Dialled(..) | Asked(..) -> actor.continue([note, ..told])
  }
}

fn recorder() -> process.Subject(Note) {
  let assert Ok(started) =
    actor.new([]) |> actor.on_message(record) |> actor.start
    as "the recorder starts"
  started.data
}

fn told(recorder: process.Subject(Note)) -> List(Note) {
  process.call(recorder, 1000, Drain)
}

fn desk() {
  orchestrators.Orchestrator(
    name: "desk",
    node: "desk@10.0.0.8",
    address: Some("ws://10.0.0.8:7000"),
  )
}

fn laptop() {
  orchestrators.plain("laptop", "laptop@10.0.0.7")
}

fn row(id: String, workspace: String) -> listed_sessions.Row {
  Row(
    session_id: id,
    workspace:,
    name: "named " <> id,
    created_at: 1_756_000_000_000,
    status: listed_sessions.Saved,
    subtitle: None,
    executor: Some("box"),
    pool: None,
    executor_node: Some("box@10.0.0.9"),
  )
}

fn id_of(number: Int) -> String {
  "0198c1aa-0000-7000-8000-" <> string.pad_start(int.to_string(number), 12, "0")
}

// A page of `count` rows whose workspaces are `width` bytes long.
fn rows(count: Int, width: Int) -> Page {
  Page(
    rows: list.repeat(Nil, count)
      |> list.index_map(fn(_, index) {
        row(id_of(index + 1), string.repeat("w", width))
      }),
    more: Further,
  )
}

// A daemon whose orchestrators are `desk` and `laptop`. The connections answer
// from `answers`, by node, and refuse any other as an unreachable host is
// refused. `pages` says what a connected node lists for the request it is asked.
fn listing(
  answers: List(#(String, Result(Nil, deployment.Why))),
  pages: fn(String, String, Int) -> Result(Page, Nil),
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  let notes = recorder()
  let reach =
    deployment.Reach(
      self:,
      dial: fn(node, _within_ms) {
        process.send(notes, Dialled(node))
        case list.key_find(answers, node) {
          Ok(outcome) -> outcome
          Error(Nil) -> Error(deployment.Unreachable)
        }
      },
      ask: fn(_node, _within_ms) { Error(orchestrator_port.PortGone) },
      sessions: fn(node, after, limit, _within_ms) {
        process.send(notes, Asked(node:, after:, limit:))
        pages(node, after, limit)
      },
      own: fn() {
        node_report.bare(self, "0.3.0", "abc123", "e1", 1000, 61_000)
      },
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
    fn(_, ready, port, credential) { run(ready, port, credential, notes) },
  )
}

fn elsewhere(socket, id, body) {
  wire.send(socket, id, "sessions.elsewhere", body, within_ms: 6000)
}

fn both_reachable() -> List(#(String, Result(Nil, deployment.Why))) {
  [#("desk@10.0.0.8", Ok(Nil)), #("laptop@10.0.0.7", Ok(Nil))]
}

pub fn the_owner_reads_every_configured_orchestrator_as_it_answered_test() {
  listing(
    [#("desk@10.0.0.8", Ok(Nil))],
    fn(node, _after, _limit) {
      case node {
        "desk@10.0.0.8" ->
          Ok(Page(rows: [row(id_of(1), "/src/loom")], more: Last))
        _ -> Error(Nil)
      }
    },
    fn(_ready, port, credential, notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply = elsewhere(socket, 1, json.Object([]))
      assert field(reply, "event") == json.String("sessions.elsewhere")
      let assert json.Array([desk, laptop]) =
        field(field(reply, "body"), "orchestrators")

      // The one that answered shows its address and its rows, with the node of
      // the executor each is placed on.
      assert field(desk, "name") == json.String("desk")
      assert field(desk, "node") == json.String("desk@10.0.0.8")
      assert field(desk, "state") == json.String("answered")
      assert field(desk, "address") == json.String("ws://10.0.0.8:7000")
      assert field(desk, "more") == json.Bool(False)
      let assert json.Array([listed]) = field(desk, "sessions")
      assert field(listed, "session_id") == json.String(id_of(1))
      assert field(listed, "workspace") == json.String("/src/loom")
      assert field(listed, "status")
        == json.Object([#("state", json.String("saved"))])
      assert field(listed, "executor_node") == json.String("box@10.0.0.9")

      // The one that did not is a single line: silent, with no rows, and no
      // address because its configuration has none.
      assert field(laptop, "state") == json.String("silent")
      assert field(laptop, "sessions") == json.Array([])
      assert field(laptop, "more") == json.Bool(False)
      assert !has(laptop, "address")
      let _ = ffi_ws.tcp_close(socket)

      // A silent orchestrator was connected to and never asked.
      let notes = told(notes)
      assert list.contains(notes, Dialled("laptop@10.0.0.7"))
      assert !list.any(notes, fn(note) {
        case note {
          Asked(node: "laptop@10.0.0.7", ..) -> True
          Asked(..) | Dialled(..) | Drain(..) -> False
        }
      })
    },
  )
}

pub fn each_orchestrator_is_asked_for_a_first_page_of_twenty_test() {
  listing(
    both_reachable(),
    fn(_node, _after, _limit) { Ok(Page(rows: [], more: Last)) },
    fn(_ready, port, credential, notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body = field(elsewhere(socket, 1, json.Object([])), "body")
      let assert json.Array(groups) = field(body, "orchestrators")
      assert list.map(groups, fn(group) { field(group, "state") })
        == [json.String("answered"), json.String("answered")]
      let _ = ffi_ws.tcp_close(socket)
      let asked =
        list.filter(told(notes), fn(note) {
          case note {
            Asked(..) -> True
            Dialled(..) | Drain(..) -> False
          }
        })
        |> list.sort(fn(a, b) {
          string.compare(string.inspect(a), string.inspect(b))
        })
      assert asked
        == [
          Asked("desk@10.0.0.8", "", 20),
          Asked("laptop@10.0.0.7", "", 20),
        ]
    },
  )
}

pub fn a_key_and_a_cursor_ask_one_orchestrator_for_its_next_page_test() {
  listing(
    both_reachable(),
    fn(_node, _after, _limit) { Ok(Page(rows: [], more: Last)) },
    fn(_ready, port, credential, notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let body =
        field(
          elsewhere(
            socket,
            1,
            json.Object([
              #("orchestrator", json.String("desk")),
              #("after", json.String(id_of(7))),
            ]),
          ),
          "body",
        )
      let assert json.Array([desk]) = field(body, "orchestrators")
      assert field(desk, "name") == json.String("desk")
      let _ = ffi_ws.tcp_close(socket)

      // Only the group named was connected to, and it was asked after the row
      // the client held.
      assert told(notes)
        == [Dialled("desk@10.0.0.8"), Asked("desk@10.0.0.8", id_of(7), 20)]
    },
  )
}

pub fn a_key_that_is_not_configured_is_not_found_and_dials_nobody_test() {
  listing(
    [#("evil@10.0.0.66", Ok(Nil)), ..both_reachable()],
    fn(_node, _after, _limit) { Ok(Page(rows: [], more: Last)) },
    fn(_ready, port, credential, notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let ask = fn(id, key) {
        elsewhere(
          socket,
          id,
          json.Object([#("orchestrator", json.String(key))]),
        )
      }

      // A well-formed key the configuration lacks.
      assert code(ask(1, "ghost")) == json.String("not_found")

      // A node name is not a key, even one the connection function would answer
      // for, and is refused before the configuration is consulted.
      assert code(ask(2, "evil@10.0.0.66")) == json.String("bad_request")
      assert code(ask(3, "desk@10.0.0.8")) == json.String("bad_request")
      let _ = ffi_ws.tcp_close(socket)
      assert told(notes) == []
    },
  )
}

pub fn a_malformed_request_is_refused_before_anything_is_dialled_test() {
  listing(
    both_reachable(),
    fn(_node, _after, _limit) { Ok(Page(rows: [], more: Last)) },
    fn(_ready, port, credential, notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)

      // A cursor follows one group's rows, so it names the group.
      assert code(elsewhere(
          socket,
          1,
          json.Object([#("after", json.String(id_of(1)))]),
        ))
        == json.String("bad_request")

      // A cursor is a session identity, and an arbitrary string is not one.
      assert code(elsewhere(
          socket,
          2,
          json.Object([
            #("orchestrator", json.String("desk")),
            #("after", json.String("not an identity")),
          ]),
        ))
        == json.String("bad_request")
      assert code(elsewhere(
          socket,
          3,
          json.Object([#("orchestrator", json.Int(3))]),
        ))
        == json.String("bad_request")
      let _ = ffi_ws.tcp_close(socket)
      assert told(notes) == []
    },
  )
}

pub fn a_member_may_not_read_the_other_orchestrators_test() {
  listing(
    both_reachable(),
    fn(_node, _after, _limit) { Ok(Page(rows: [], more: Last)) },
    fn(ready, port, _credential, notes) {
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
      assert code(elsewhere(socket, 1, json.Object([])))
        == json.String("forbidden")
      assert code(elsewhere(
          socket,
          2,
          json.Object([#("orchestrator", json.String("desk"))]),
        ))
        == json.String("forbidden")
      let _ = ffi_ws.tcp_close(socket)
      assert catalogue.close(store) == Ok(Nil)
      assert told(notes) == []
    },
  )
}

pub fn the_reply_stays_inside_its_byte_bound_and_says_more_test() {
  listing(
    both_reachable(),
    fn(node, _after, _limit) {
      case node {
        // Twenty rows of 4,000 bytes each is far past the bound.
        "desk@10.0.0.8" -> Ok(rows(20, 4000))
        _ -> Ok(rows(3, 10))
      }
    },
    fn(_ready, port, credential, _notes) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply = elsewhere(socket, 1, json.Object([]))
      let body = field(reply, "body")
      assert string.byte_size(json.to_string(reply)) <= 60_000
      let assert json.Array([desk, laptop]) = field(body, "orchestrators")
      let assert json.Array(shown) = field(desk, "sessions")

      // The group with the long rows was cut and says more follow, and the group
      // with the short rows kept every row it had and was not starved.
      assert list.length(shown) < 20
      assert shown != []
      assert field(desk, "more") == json.Bool(True)
      let assert json.Array(kept) = field(laptop, "sessions")
      assert list.length(kept) == 3

      // The rows that remain are the first ones, so the next page begins after
      // the last of them.
      let assert Ok(last) = list.last(shown)
      assert field(last, "session_id") == json.String(id_of(list.length(shown)))
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

pub fn a_daemon_with_no_peers_lists_no_groups_test() {
  wire.fixture(fn(_, _ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let body = field(elsewhere(socket, 1, json.Object([])), "body")
    assert field(body, "orchestrators") == json.Array([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}
