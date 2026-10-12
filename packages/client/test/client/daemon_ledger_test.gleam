//// The owner's `ledger.*` commands across the real control socket
//// (protocol-change/086). The registry is real, the session assembly is inert
//// and the ledger is a fixture-scheme ledger over a real file, so these tests
//// prove what the socket does: that a reply has the shape a client decodes,
//// that a refused line names its step, that a daemon with no ledger says so,
//// and that a request outside the bounds is refused before the ledger sees it.

import client/daemon/ledger_cli
import client/daemon/limits
import client/daemon/root
import client/daemon_server_test as wire
import client/deployment
import client/distribution_plan
import client/ledger_control.{Handle}
import client/ledger_holdings
import client/membership_entry.{Upsert}
import client/remote/orchestrator_port
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
import support/ledger_deployment
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as log

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

fn text(line: BitArray) -> String {
  let assert Ok(line) = bit_array.to_string(line)
  line
}

// Runs `run` against a daemon whose ledger holds genesis and `hub`, with the
// lines of the entries that come next: `laptop` enrolled, then revoked.
fn ledgered(run: fn(Int, String, List(String)) -> Nil) {
  ledgered_ready(fn(_ready, port, credential, lines) {
    run(port, credential, lines)
  })
}

// The same, handing the test the daemon's readiness record, which names the
// state root a member must be created under.
fn ledgered_ready(
  run: fn(root.Ready(String), Int, String, List(String)) -> Nil,
) {
  let history = log.genesis() |> log.enroll("hub", [])
  let started = rig.start("wire", log.lines(history), rig.patient, [])
  let next = history |> log.enroll("laptop", ["hub"]) |> log.revoke("laptop")
  let assert [_, _, laptop, gone] = log.lines(next)
  wire.fixture_with_ledger(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    Some(Handle(
      service: started.service,
      local: "loom@hub.example.net",
      name: "hub",
      asker: ledger_holdings.silent,
    )),
    fn(_, ready, port, credential) {
      run(ready, port, credential, [text(laptop), text(gone)])
    },
  )
}

fn ask(socket, id, command, body) {
  wire.send(socket, id, command, body, within_ms: 6000)
}

pub fn the_owner_appends_reads_and_asks_for_the_status_test() {
  ledgered(fn(port, credential, lines) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    let reply =
      ask(
        socket,
        1,
        "ledger.append",
        json.Object([#("lines", json.Array(list.map(lines, json.String)))]),
      )
    assert field(reply, "event") == json.String("ledger.append")
    let assert Ok(applied) = ledger_control.decode_applied(field(reply, "body"))
    assert applied.applied == 2
    assert applied.head.seq == 3

    let reply =
      ask(
        socket,
        2,
        "ledger.entries",
        json.Object([#("after", json.Int(1)), #("limit", json.Int(64))]),
      )
    assert field(reply, "event") == json.String("ledger.entries")
    let assert Ok(page) = ledger_control.decode_entries(field(reply, "body"))
    assert page.lines == lines
    assert page.head_seq == 3

    let reply = ask(socket, 3, "ledger.status", json.Object([]))
    assert field(reply, "event") == json.String("ledger.status")
    let assert Ok(status) = ledger_control.decode_status(field(reply, "body"))
    assert status.self_name == "hub"
    assert status.head.seq == 3
  })
}

pub fn the_owner_asks_what_the_orchestrators_hold_test() {
  // The hub is the only orchestrator of this ledger, so it is the one asked,
  // and it answers for itself.
  let history =
    log.genesis()
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("hub", []),
        role: distribution_plan.Orchestrator,
      ),
    ))
  let started = rig.start("holdings-wire", log.lines(history), rig.patient, [])
  let asked =
    Handle(
      service: started.service,
      local: "loom@hub.example.net",
      name: "hub",
      asker: fn(_node) { Ok(orchestrator_port.Held(sessions: 0, placed: [])) },
    )
  wire.fixture_with_ledger(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    Some(asked),
    fn(_, _ready, port, credential) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)

      let reply = ask(socket, 1, "ledger.holdings", json.Object([]))
      assert field(reply, "event") == json.String("ledger.holdings")
      let assert Ok(answers) =
        ledger_control.decode_holdings(field(reply, "body"))
      assert answers
        == [
          ledger_control.AnswerView(
            name: "hub",
            node: "loom@hub.example.net",
            held: Some(ledger_control.HeldView(sessions: 0, placed: [])),
          ),
        ]
    },
  )
}

pub fn the_deployment_status_of_a_ledger_daemon_carries_the_ledger_head_test() {
  ledgered(fn(port, credential, _lines) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // The whole read names the ledger as `ledger.status` would: the head, the
    // standing, each member with the head it reported, and the last refusal.
    let reply = ask(socket, 1, "deployment.status", json.Object([]))
    assert field(reply, "event") == json.String("deployment.status")
    let body = field(reply, "body")
    let status = field(body, "ledger")
    let assert Ok(decoded) = ledger_control.decode_status(status)
    assert decoded.head.seq == 1
    assert decoded.self_name == "hub"
    assert list.map(decoded.members, fn(member) { member.name }) == ["hub"]
    assert decoded.last_refusal == None

    // A line the daemon refuses is its last refusal, and the next read shows
    // it. The head is where the daemon stands, which has not moved.
    let _ =
      ask(
        socket,
        2,
        "ledger.append",
        json.Object([#("lines", json.Array([json.String("not a line")]))]),
      )
    let reply = ask(socket, 3, "deployment.status", json.Object([]))
    let assert Ok(after) =
      ledger_control.decode_status(field(field(reply, "body"), "ledger"))
    assert after.head.seq == 1
    let assert Some(refused) = after.last_refusal
    assert refused.step == "malformed"

    // A read that names one node is about that node and nothing else.
    let reply =
      ask(
        socket,
        4,
        "deployment.status",
        json.Object([#("node", json.String("nobody"))]),
      )
    assert field(field(reply, "body"), "code") == json.String("not_found")
  })
}

pub fn a_deployment_status_without_a_ledger_has_no_ledger_member_test() {
  wire.fixture_moving(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    fn(_, _ready, port, credential) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply = ask(socket, 1, "deployment.status", json.Object([]))
      assert field(reply, "event") == json.String("deployment.status")
      let assert json.Object(members) = field(reply, "body")
      assert list.key_find(members, "ledger") == Error(Nil)
    },
  )
}

pub fn a_member_token_is_forbidden_every_ledger_command_test() {
  ledgered_ready(fn(ready, port, credential, lines) {
    let assert [laptop, _] = lines
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
    let #(member, _) = wire.connect(port, member_token, "/v2/control")
    let _hello = wire.frame(member, within_ms: 1000)
    let forbidden = fn(id, command, body) {
      let reply = ask(member, id, command, body)
      assert field(field(reply, "body"), "code") == json.String("forbidden")
    }
    forbidden(
      1,
      "ledger.append",
      json.Object([#("lines", json.Array([json.String(laptop)]))]),
    )
    forbidden(
      2,
      "ledger.entries",
      json.Object([#("after", json.Int(0)), #("limit", json.Int(64))]),
    )
    forbidden(3, "ledger.status", json.Object([]))
    forbidden(4, "ledger.holdings", json.Object([]))
    let _ = ffi_ws.tcp_close(member)
    assert catalogue.close(store) == Ok(Nil)

    // The refusal came before the ledger saw anything: the owner reads the
    // head the fixture started with.
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply = ask(socket, 1, "ledger.status", json.Object([]))
    let assert Ok(status) = ledger_control.decode_status(field(reply, "body"))
    assert status.head.seq == 1
  })
}

pub fn a_refused_line_is_ledger_invalid_and_names_its_step_test() {
  ledgered(fn(port, credential, lines) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let assert [_, gone] = lines

    // The second entry before the first is a gap.
    let reply =
      ask(
        socket,
        1,
        "ledger.append",
        json.Object([#("lines", json.Array([json.String(gone)]))]),
      )
    assert field(reply, "event") == json.String("error")
    let body = field(reply, "body")
    assert field(body, "code") == json.String("ledger_invalid")
    assert field(body, "message") == json.String("gap")

    // The refusal is the connection's own and the daemon goes on serving.
    let reply = ask(socket, 2, "ledger.status", json.Object([]))
    assert field(reply, "event") == json.String("ledger.status")
  })
}

pub fn a_request_outside_the_bounds_never_reaches_the_ledger_test() {
  ledgered(fn(port, credential, _lines) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let refused = fn(id, command, body) {
      let reply = ask(socket, id, command, body)
      assert field(field(reply, "body"), "code") == json.String("bad_request")
    }
    refused(1, "ledger.append", json.Object([#("lines", json.Array([]))]))
    refused(
      2,
      "ledger.append",
      json.Object([
        #("lines", json.Array(list.repeat(json.String("x"), 65))),
      ]),
    )
    refused(
      3,
      "ledger.append",
      json.Object([#("lines", json.Array([json.Int(1)]))]),
    )
    refused(
      4,
      "ledger.entries",
      json.Object([#("after", json.Int(-1)), #("limit", json.Int(1))]),
    )
    refused(
      5,
      "ledger.entries",
      json.Object([#("after", json.Int(0)), #("limit", json.Int(0))]),
    )
    refused(6, "ledger.entries", json.Object([]))
  })
}

// The asker of a daemon whose laptop is asleep: the hub answers for itself, and
// the laptop never answers, however long it is waited for.
fn asleep_laptop(node: String) -> Result(orchestrator_port.Held, Nil) {
  case node == "loom@laptop.example" {
    True -> {
      process.sleep(ledger_holdings.deadline_ms + 4000)
      Ok(orchestrator_port.Held(sessions: 0, placed: []))
    }
    False -> Ok(orchestrator_port.Held(sessions: 0, placed: []))
  }
}

fn owner_token_file(owner: String) -> String {
  let assert Ok(directory) =
    bootstrap.absolute_path(
      "build/ledger-socket-token-" <> int.to_string(int.random(1_000_000_000)),
    )
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let path = directory <> "/owner.token"
  let assert Ok(Nil) = bootstrap.atomic_write_private(path, owner)
  path
}

// The operator's `revoke` of an orchestrator that does not answer, run as the
// CLI runs it: over the control socket, which waits five seconds for any reply
// (`host/access`). The daemon's fan-out has to finish inside that wait, or the
// reply that arrives after it is read as a failure to ask at all, and the
// operator is told the daemon could not be asked and not that the laptop did
// not answer.
pub fn a_silent_orchestrator_is_reported_silent_across_the_socket_test() {
  let deployed =
    ledger_deployment.provision("silent-socket", ledger_deployment.plan_text)
  let served =
    ledger_deployment.serve(deployed, "silent", "hub", "loom@hub.example")
  let handle = Handle(..served, asker: asleep_laptop)
  wire.fixture_with_ledger(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    Some(handle),
    fn(_, _ready, port, credential) {
      let remote = [
        "--addr",
        "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control",
        "--token-file",
        owner_token_file(credential),
      ]
      let signing = ledger_deployment.signing(deployed)

      // A second orchestrator, linked to the hub, so that the hub asks it.
      let assert Ok(_) =
        ledger_cli.run(
          "enroll",
          list.flatten([
            [
              "laptop",
              "--node",
              "loom@laptop.example",
              "--role",
              "orchestrator",
              "--links",
              "hub",
              "--out",
              deployed.base <> "/bundles",
              "--wait",
              "0",
            ],
            signing,
            remote,
          ]),
        )
        as "the laptop is enrolled through the socket"

      let assert Error(refusal) =
        ledger_cli.run(
          "revoke",
          list.flatten([["laptop", "--wait", "0"], signing, remote]),
        )
        as "the revoke is refused"
      assert string.contains(
        refusal,
        "whether laptop holds sessions could not be told: laptop did not answer",
      )
        as refusal
      assert !string.contains(refusal, "could not be asked") as refusal
    },
  )
}

pub fn a_daemon_with_no_ledger_answers_not_found_test() {
  wire.fixture_moving(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    fn(_, _ready, port, credential) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply = ask(socket, 1, "ledger.status", json.Object([]))
      assert field(field(reply, "body"), "code") == json.String("not_found")
      let reply = ask(socket, 3, "ledger.holdings", json.Object([]))
      assert field(field(reply, "body"), "code") == json.String("not_found")
      let reply =
        ask(
          socket,
          2,
          "ledger.append",
          json.Object([#("lines", json.Array([json.String("x")]))]),
        )
      assert field(field(reply, "body"), "code") == json.String("not_found")
    },
  )
}
