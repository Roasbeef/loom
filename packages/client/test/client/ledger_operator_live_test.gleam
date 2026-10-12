//// The operator's workflow across real emulators (protocol-change/086): the
//// commands an operator runs, from `provision` to `revoke`, against nodes that
//// are connected to each other over real TLS distribution.
////
//// What runs for real: `provision` seals an ECDSA authority key and signs a
//// ledger for two nodes, `install` writes each node's files, and each node is
//// an emulator started from the configuration and the options file that
//// `install` wrote, booting the daemon's own `ledger_boot`. The operator's
//// `enroll`, `revoke` and `log` are the production commands, sealing and
//// signing with the kept key.
////
//// What is relayed: the operator's `ledger.*` requests reach a node as a line
//// on its stdin and come back as a line of JSON, served by
//// `client/ledger_control` against the node's own ledger process, which is what
//// the control socket calls. The socket is `daemon_ledger_test`, and the same
//// request loop over it is `ledger_cli_test`.
////
//// ## What it proves
////
//// - A third node is enrolled while the first two run. It is installed from the
////   bundle `enroll` wrote, starts, and connects to both of them with no
////   restart anywhere, and the report of `enroll` says which members held the
////   new head.
//// - A revoke drops the revoked node's connections at both of the others, and
////   its next handshake is refused.
//// - `log` shows every entry: the genesis, the three members and the revoke.

import client/daemon/distribution_cli
import client/daemon/ledger_cli
import client/ledger_control
import client/ledger_sync.{type Daemon, Daemon}
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile
import support/ledger_deployment as deployment

@external(erlang, "client_ledger_operator_fixture_ffi", "boot")
fn boot(home: String, config: String) -> Result(Dynamic, String)

@external(erlang, "client_ledger_operator_fixture_ffi", "step")
fn step(node: Dynamic, command: String, witness: String) -> Result(Nil, String)

@external(erlang, "client_ledger_operator_fixture_ffi", "control")
fn control(
  node: Dynamic,
  command: String,
  body: String,
) -> Result(String, String)

@external(erlang, "client_ledger_operator_fixture_ffi", "stop")
fn stop(node: Dynamic) -> Result(Nil, String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(a)) -> Int

// The budget of the whole scenario: eunit scales a generator's timeout by ten,
// so the number given is the seconds wanted divided by ten.
const seconds = 300

const scale = 10

// A node name the emulators can reach each other by: their certificates carry
// 127.0.0.1 as the host.
fn node_name(label: String, id: Int) -> String {
  "ledger_" <> label <> "_" <> int.to_string(id) <> "@127.0.0.1"
}

fn plan(id: Int) -> String {
  "[[node]]
name = \"hub\"
role = \"orchestrator\"
erlang_node = \"" <> node_name("hub", id) <> "\"
executors = [\"box\"]

[[node]]
name = \"box\"
role = \"executor\"
erlang_node = \"" <> node_name("box", id) <> "\"
[node.workspaces]
repo = \"/srv/repo\"
"
}

// The operator reaches a node through the relay. Each request is a stdin line
// to the emulator and a JSON line back.
fn ask(
  node: Dynamic,
  command: String,
  body: JsonValue,
) -> Result(JsonValue, String) {
  use line <- result.try(control(node, command, json.to_string(body)))
  use reply <- result.try(
    json.parse(line) |> result.replace_error("unreadable reply: " <> line),
  )
  case reply {
    json.Object([#("ok", body)]) -> Ok(body)
    json.Object([#("error", json.String(reason))]) -> Error(reason)
    _ -> Error("unexpected reply: " <> line)
  }
}

fn relay(node: Dynamic) -> fn(a) -> Daemon {
  fn(_) {
    Daemon(
      status: fn() {
        ask(node, "ledger.status", json.Object([]))
        |> result.try(ledger_control.decode_status)
      },
      entries: fn(after, limit) {
        ask(
          node,
          "ledger.entries",
          json.Object([#("after", json.Int(after)), #("limit", json.Int(limit))]),
        )
        |> result.try(ledger_control.decode_entries)
      },
      append: fn(lines) {
        ask(
          node,
          "ledger.append",
          json.Object([#("lines", json.Array(list.map(lines, json.String)))]),
        )
        |> result.try(ledger_control.decode_applied)
      },
      holdings: fn() {
        ask(node, "ledger.holdings", json.Object([]))
        |> result.try(ledger_control.decode_holdings)
      },
    )
  }
}

// A step that must have worked, or the scenario stops saying which and why.
fn ok(result: Result(a, String), why: String) -> a {
  case result {
    Ok(value) -> value
    Error(reason) -> panic as { why <> ": " <> reason }
  }
}

fn installed(
  deployed: deployment.Deployed,
  label: String,
  bundle: String,
) -> String {
  let home = deployed.base <> "/" <> label <> "-home"
  let assert Ok(_) = distribution_cli.run(["install", bundle, "--home", home])
    as "the bundle installs"
  home
}

fn start(home: String) -> Dynamic {
  ok(boot(home, home <> "/.loom/loom.toml"), "the node boots from its install")
}

fn member_names(id: Int, labels: List(String)) -> String {
  string.join(list.map(labels, node_name(_, id)), ",")
}

/// The whole workflow: provision two nodes, run them, enroll a third while
/// they run, revoke it, and read the log.
pub fn the_operator_workflow_changes_membership_of_running_nodes_test_() -> EunitTest {
  Timeout(seconds / scale, fn() {
    let id = int.absolute_value(unique_integer([]))
    let deployed = deployment.provision("live-workflow", plan(id))

    let hub_home = installed(deployed, "hub", deployed.out <> "/hub.loombundle")
    let box_home = installed(deployed, "box", deployed.out <> "/box.loombundle")
    let hub = start(hub_home)
    let box = start(box_home)

    // The orchestrator dials its executor by itself, from the ledger alone.
    ok(
      step(hub, "await_connected " <> member_names(id, ["box"]), "NODES_ARE"),
      "the hub reaches the box",
    )

    // The operator enrolls a laptop through the hub. The bundle it writes is a
    // snapshot of the new head, and the report says which members hold it.
    let assert Ok(report) =
      ledger_cli.run_with(
        "enroll",
        list.flatten([
          [
            "laptop",
            "--node",
            node_name("laptop", id),
            "--role",
            "orchestrator",
            "--links",
            "hub,box",
            "--out",
            deployed.base <> "/bundles",
            "--wait",
            "30",
          ],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the enrollment succeeds"
    assert string.contains(report, "Enrolled laptop")
    assert string.contains(report, "as entry 3")
    assert string.contains(report, "2 of 3 members hold it")
    assert string.contains(
      report,
      string.pad_end("laptop", 16, " ") <> "pending",
    )

    // The box learned it from the hub, with no restart.
    ok(step(box, "await_head 3", "AT 3"), "the box holds the entry")

    // The new node installs its bundle, starts, and connects to both of them.
    let laptop_home =
      installed(
        deployed,
        "laptop",
        deployed.base <> "/bundles/laptop.loombundle",
      )
    let laptop = start(laptop_home)
    ok(
      step(laptop, "connect " <> node_name("hub", id), "CONNECT connected"),
      "the laptop reaches the hub",
    )
    ok(
      step(
        laptop,
        "await_connected " <> member_names(id, ["box", "hub"]),
        "NODES_ARE",
      ),
      "the laptop is connected to both",
    )
    ok(
      step(
        hub,
        "await_connected " <> member_names(id, ["box", "laptop"]),
        "NODES_ARE",
      ),
      "the hub sees the laptop",
    )
    ok(
      step(
        box,
        "await_connected " <> member_names(id, ["hub", "laptop"]),
        "NODES_ARE",
      ),
      "the box sees the laptop",
    )

    // Revoking it drops its connections at both nodes, and the next handshake
    // is refused.
    let assert Ok(revoked) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["laptop", "--reason", "lost", "--wait", "30"],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the revoke succeeds"
    assert string.contains(revoked, "Revoked laptop as entry 4")
    ok(
      step(hub, "await_connected " <> member_names(id, ["box"]), "NODES_ARE"),
      "the hub dropped the laptop",
    )
    ok(
      step(box, "await_connected " <> member_names(id, ["hub"]), "NODES_ARE"),
      "the box dropped the laptop",
    )
    ok(
      step(laptop, "connect " <> node_name("hub", id), "CONNECT refused"),
      "the revoked laptop is refused",
    )

    // The log has the genesis, the three members and the revoke, and says what
    // the hub reports of each member.
    let assert Ok(log) =
      ledger_cli.run_with("log", ["--home", deployed.home], relay(hub))
      as "the log prints"
    assert string.contains(log, "genesis")
    assert string.contains(log, "member   laptop  orchestrator")
    assert string.contains(log, "revoke   laptop  \"lost\"")
    assert string.contains(log, "head entry 4")
    let assert Ok(as_json) =
      ledger_cli.run_with(
        "log",
        ["--json", "--home", deployed.home],
        relay(hub),
      )
      as "the log prints as JSON"
    let assert Ok(json.Object(fields)) = json.parse(as_json)
    let assert Ok(json.Array(entries)) = list.key_find(fields, "entries")
    assert list.length(entries) == 5

    ok(stop(laptop), "the laptop stops")
    ok(stop(box), "the box stops")
    ok(stop(hub), "the hub stops")
    let _ = simplifile.delete(deployed.base)
    Nil
  })
}

// The names of the executors and the orchestrators a node derives from its
// ledger at this moment (`client/ledger_rows`), read through the same rosters
// the daemon builds.
fn derived(node: Dynamic) -> #(List(String), List(String)) {
  let body = ok(ask(node, "test.rows", json.Object([])), "the node lists rows")
  let names = fn(key) {
    let assert json.Object(fields) = body
    let assert Ok(json.Array(items)) = list.key_find(fields, key)
    list.filter_map(items, fn(item) {
      case item {
        json.String(name) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  }
  #(names("executors"), names("orchestrators"))
}

/// A member enrolled while the nodes run is a row the next session can use, and
/// a revoked one stops being offered, with no restart anywhere.
pub fn the_rows_a_node_derives_follow_enrollment_and_revocation_test_() -> EunitTest {
  Timeout(seconds / scale, fn() {
    let id = int.absolute_value(unique_integer([]))
    let deployed = deployment.provision("live-rows", plan(id))
    let hub =
      start(installed(deployed, "hub", deployed.out <> "/hub.loombundle"))
    let box =
      start(installed(deployed, "box", deployed.out <> "/box.loombundle"))
    ok(
      step(hub, "await_connected " <> member_names(id, ["box"]), "NODES_ARE"),
      "the hub reaches the box",
    )

    // The provisioned executor is a row from the start, and the hub has no
    // orchestrator to list. An executor lists neither.
    assert derived(hub) == #(["box"], [])
    assert derived(box) == #([], [])

    // An executor is enrolled. The hub's rows have it the moment the entry is
    // applied, before the new machine exists.
    let assert Ok(_) =
      ledger_cli.run_with(
        "enroll",
        list.flatten([
          [
            "desk",
            "--node",
            node_name("desk", id),
            "--role",
            "executor",
            "--links",
            "hub",
            "--workspace",
            "repo=/srv/repo",
            "--out",
            deployed.base <> "/bundles",
            "--wait",
            "30",
          ],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the executor is enrolled"
    assert derived(hub) == #(["box", "desk"], [])

    // And it is usable: once the machine starts from its bundle, the hub dials
    // it by itself, from the ledger alone.
    let desk =
      start(installed(
        deployed,
        "desk",
        deployed.base <> "/bundles/desk.loombundle",
      ))
    ok(
      step(
        hub,
        "await_connected " <> member_names(id, ["box", "desk"]),
        "NODES_ARE",
      ),
      "the hub reaches the new executor",
    )

    // An orchestrator is enrolled the same way, and appears among the
    // orchestrators and not among the executors.
    let assert Ok(_) =
      ledger_cli.run_with(
        "enroll",
        list.flatten([
          [
            "laptop",
            "--node",
            node_name("laptop", id),
            "--role",
            "orchestrator",
            "--links",
            "hub",
            "--out",
            deployed.base <> "/bundles",
            "--wait",
            "30",
          ],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the orchestrator is enrolled"
    assert derived(hub) == #(["box", "desk"], ["laptop"])

    // The executor is revoked. Nothing was placed on it, so no flag is needed,
    // and the row goes with the entry while its connection is dropped.
    let assert Ok(revoked) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["desk", "--reason", "retired", "--wait", "0"],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the executor is revoked"
    assert string.contains(
      revoked,
      "Checked first: no orchestrator linked to desk has a session placed on it.",
    )
    assert derived(hub) == #(["box"], ["laptop"])
    ok(
      step(hub, "await_connected " <> member_names(id, ["box"]), "NODES_ARE"),
      "the hub dropped the revoked executor",
    )

    // The orchestrator goes the same way.
    let assert Ok(_) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["laptop", "--wait", "0"],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the orchestrator is revoked"
    assert derived(hub) == #(["box"], [])

    ok(stop(desk), "the desk stops")
    ok(stop(box), "the box stops")
    ok(stop(hub), "the hub stops")
    let _ = simplifile.delete(deployed.base)
    Nil
  })
}

/// The operator's question reaches the orchestrators the way the daemon asks
/// it: `ledger.holdings` connects to the pinned peer
/// (`session_directory.reached`), addresses the orchestrator port registered
/// under its default name, and the port answers from a real catalogue
/// (`ledger_holdings.from_catalogue`). Nothing on that path is a stub, so a
/// revoke is refused on the count a catalogue holds.
pub fn the_holdings_a_revoke_reads_cross_real_distribution_test_() -> EunitTest {
  Timeout(seconds / scale, fn() {
    let id = int.absolute_value(unique_integer([]))
    let deployed = deployment.provision("live-holdings", plan(id))
    let hub_home = installed(deployed, "hub", deployed.out <> "/hub.loombundle")
    let box_home = installed(deployed, "box", deployed.out <> "/box.loombundle")
    let hub = start(hub_home)
    let box = start(box_home)
    ok(
      step(hub, "await_connected " <> member_names(id, ["box"]), "NODES_ARE"),
      "the hub reaches the box",
    )

    // A second orchestrator that uses the same executor.
    let assert Ok(_) =
      ledger_cli.run_with(
        "enroll",
        list.flatten([
          [
            "laptop",
            "--node",
            node_name("laptop", id),
            "--role",
            "orchestrator",
            "--links",
            "hub,box",
            "--out",
            deployed.base <> "/bundles",
            "--wait",
            "30",
          ],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the laptop is enrolled"
    let laptop_home =
      installed(
        deployed,
        "laptop",
        deployed.base <> "/bundles/laptop.loombundle",
      )
    let laptop = start(laptop_home)

    // The laptop dials out, as a laptop does; the hub does not dial it.
    ok(
      step(laptop, "connect " <> node_name("hub", id), "CONNECT connected"),
      "the laptop reaches the hub",
    )
    ok(
      step(
        hub,
        "await_connected " <> member_names(id, ["box", "laptop"]),
        "NODES_ARE",
      ),
      "the hub sees the laptop",
    )

    // Each orchestrator runs a port over a catalogue of its own: the hub holds
    // nothing and the laptop holds three sessions placed on the box.
    let box_node = node_name("box", id)
    ok(
      step(hub, "serve_holdings 0 " <> box_node, "HOLDINGS_SERVED"),
      "the hub serves its catalogue",
    )
    ok(
      step(laptop, "serve_holdings 3 " <> box_node, "HOLDINGS_SERVED"),
      "the laptop serves its catalogue",
    )

    // The hub asks both over distribution. It answers for itself through its
    // own port and reaches the laptop through the pinned connection.
    let body = ok(ask(hub, "ledger.holdings", json.Object([])), "the hub asks")
    let assert Ok(answers) = ledger_control.decode_holdings(body)
    assert answers
      == [
        ledger_control.AnswerView(
          name: "hub",
          node: node_name("hub", id),
          held: Some(ledger_control.HeldView(sessions: 0, placed: [])),
        ),
        ledger_control.AnswerView(
          name: "laptop",
          node: node_name("laptop", id),
          held: Some(
            ledger_control.HeldView(sessions: 3, placed: [
              ledger_control.PlacedView(node: box_node, sessions: 3),
            ]),
          ),
        ),
      ]

    // The count is what the operator's refusals are made of.
    let assert Error(owned) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([["laptop", "--wait", "0"], deployment.signing(deployed)]),
        relay(hub),
      )
      as "the laptop owns sessions"
    assert string.contains(owned, "laptop owns 3 sessions")
    let assert Error(placed) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([["box", "--wait", "0"], deployment.signing(deployed)]),
        relay(hub),
      )
      as "sessions are placed on the box"
    assert string.contains(placed, "3 sessions placed on box by laptop")

    ok(stop(laptop), "the laptop stops")
    ok(stop(box), "the box stops")
    ok(stop(hub), "the hub stops")
    let _ = simplifile.delete(deployed.base)
    Nil
  })
}
