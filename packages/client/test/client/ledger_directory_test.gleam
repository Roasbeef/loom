//// The session directory following the membership ledger across real emulators
//// (protocol-change/086, phase 3): Ra's membership is whatever the ledger seats,
//// and the Ra leader keeps it so.
////
//// What runs for real: `provision` signs a ledger for three nodes that are all
//// directory voters, `install` writes each node's files, and each node is an
//// emulator booted from the configuration and options file `install` wrote,
//// running the daemon's own `ledger_boot` and, over it, the production member
//// actor (`client/directory/member`) with the ledger as its source of members.
//// The operator's `enroll` and `revoke` are the production commands, signing
//// with the kept key. What is relayed is the operator's `ledger.*` requests, as
//// in `ledger_operator_live_test`.
////
//// ## What it proves
////
//// - The three voters form the cluster from the ledger alone: the first creates
////   it, the others join, and each lists three voters. No `[directory]` table
////   exists anywhere.
//// - `enroll --directory learner` of a fourth node, while they run, makes it a
////   non-voting Ra member. It joins by itself, the leader never counts it toward
////   a majority, and every member lists it.
//// - A `revoke` that would leave the directory with two voters is refused, and
////   nothing is signed.
//// - The leader's process ends. The two voters that remain elect another, and a
////   `revoke` of the learner, handed to one of them, is followed by the new
////   leader's reconciler: the learner leaves Ra, and the voters are still three.

import client/daemon/distribution_cli
import client/daemon/ledger_cli
import client/ledger_control
import client/ledger_sync.{type Daemon, Daemon}
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import support/ledger_deployment as deployment

@external(erlang, "client_ledger_operator_fixture_ffi", "boot_member")
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

@external(erlang, "client_ledger_operator_fixture_ffi", "kill")
fn kill(node: Dynamic) -> Result(Nil, String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(a)) -> Int

// The budget of the whole scenario: eunit scales a generator's timeout by ten,
// so the number given is the seconds wanted divided by ten.
const seconds = 600

const scale = 10

fn node_name(label: String, id: Int) -> String {
  "ledger_" <> label <> "_" <> int.to_string(id) <> "@127.0.0.1"
}

// Two orchestrators and an executor, all three voters of the directory. The plan
// states the directory once; the ledger it provisions carries each node's
// standing, and no bundle lists the members.
fn plan(id: Int) -> String {
  "directory = [\"hub\", \"hub2\", \"box\"]

[[node]]
name = \"hub\"
role = \"orchestrator\"
erlang_node = \"" <> node_name("hub", id) <> "\"
executors = [\"box\"]

[[node]]
name = \"hub2\"
role = \"orchestrator\"
erlang_node = \"" <> node_name("hub2", id) <> "\"
executors = [\"box\"]

[[node]]
name = \"box\"
role = \"executor\"
erlang_node = \"" <> node_name("box", id) <> "\"
[node.workspaces]
repo = \"/srv/repo\"
"
}

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

// What Ra should hold, in the words `await_ra` compares: each node with its
// seat.
fn held(id: Int, seats: List(#(String, String))) -> String {
  string.join(
    list.map(seats, fn(seat) { node_name(seat.0, id) <> ":" <> seat.1 }),
    ",",
  )
}

pub fn the_directory_follows_the_ledger_test_() -> EunitTest {
  Timeout(seconds / scale, fn() {
    let id = int.absolute_value(unique_integer([]))
    let deployed = deployment.provision("live-directory", plan(id))

    // The configuration `install` writes has no directory table: the members
    // are the ledger's.
    let hub_home = installed(deployed, "hub", deployed.out <> "/hub.loombundle")
    let hub2_home =
      installed(deployed, "hub2", deployed.out <> "/hub2.loombundle")
    let box_home = installed(deployed, "box", deployed.out <> "/box.loombundle")
    let assert Ok(config) = simplifile.read(hub_home <> "/.loom/loom.toml")
    assert !string.contains(config, "[directory]")

    // The first node creates the cluster, as `loomd directory bootstrap` does,
    // and the others join it by themselves.
    let hub = start(hub_home)
    let hub2 = start(hub2_home)
    let box = start(box_home)
    ok(step(hub, "directory_seed", "DIRECTORY seeded"), "hub creates the store")
    ok(step(hub2, "directory_member", "DIRECTORY started"), "hub2 starts")
    ok(step(box, "directory_member", "DIRECTORY started"), "box starts")
    let voters =
      held(id, [#("box", "voter"), #("hub", "voter"), #("hub2", "voter")])
    ok(step(hub, "await_ra " <> voters, "RA ok"), "hub lists three voters")
    ok(step(hub2, "await_ra " <> voters, "RA ok"), "hub2 lists three voters")
    ok(step(box, "await_ra " <> voters, "RA ok"), "box lists three voters")

    // A fourth node is enrolled as a learner while they run. Its bundle holds
    // the ledger with its own entry, and its seat is in that entry.
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
            "--directory",
            "learner",
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
    let laptop_home =
      installed(
        deployed,
        "laptop",
        deployed.base <> "/bundles/laptop.loombundle",
      )
    let laptop = start(laptop_home)
    ok(
      step(laptop, "directory_member", "DIRECTORY started"),
      "the laptop starts",
    )
    let with_learner =
      held(id, [
        #("box", "voter"),
        #("hub", "voter"),
        #("hub2", "voter"),
        #("laptop", "learner"),
      ])
    ok(step(hub, "await_ra " <> with_learner, "RA ok"), "hub lists the learner")
    ok(
      step(hub2, "await_ra " <> with_learner, "RA ok"),
      "hub2 lists the learner",
    )
    ok(step(box, "await_ra " <> with_learner, "RA ok"), "box lists the learner")

    // A revoke that would leave two voters is refused and signs nothing.
    let before =
      deployment.lines(
        deployment.authority_directory(deployed) <> "/ledger.log",
      )
    let assert Error(refused) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["box", "--wait", "30"],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the revoke of a voter is refused"
    assert string.contains(refused, "left with 2 voters")
    assert string.contains(refused, "Nothing was signed")
    assert deployment.lines(
        deployment.authority_directory(deployed) <> "/ledger.log",
      )
      == before

    // The leader's process ends: hub created the cluster and has led it since.
    // The two voters that remain are a majority and elect another.
    ok(kill(hub), "hub ends")

    // The learner is revoked through a survivor. Whichever of the two is leader
    // now removes it from Ra; the voters are still three, hub included, because
    // nothing revoked it.
    let assert Ok(revoked) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["laptop", "--reason", "lost", "--wait", "30"],
          deployment.signing(deployed),
        ]),
        relay(hub2),
      )
      as "the revoke of the learner succeeds"
    assert string.contains(revoked, "Revoked laptop")
    ok(
      step(hub2, "await_ra " <> voters, "RA ok"),
      "hub2 drops the learner from Ra",
    )
    ok(
      step(box, "await_ra " <> voters, "RA ok"),
      "box drops the learner from Ra",
    )

    ok(stop(laptop), "the laptop stops")
    ok(stop(box), "the box stops")
    ok(stop(hub2), "hub2 stops")
    let _ = simplifile.delete(deployed.base)
    Nil
  })
}

/// The leader removes a member the ledger revoked, and Ra never stops the server
/// it removed. When the same machine is enrolled again, on the same disk, its
/// store still carries the `joined` marker and a server that belongs to no
/// cluster. Nobody touches the marker: the node finds out by asking the leader
/// through a peer, resets, and joins again in the seat its new entry gives it.
pub fn a_revoked_member_enrolled_again_rejoins_by_itself_test_() -> EunitTest {
  Timeout(seconds / scale, fn() {
    let id = int.absolute_value(unique_integer([]))
    let deployed = deployment.provision("live-rejoin", plan(id))
    let hub_home = installed(deployed, "hub", deployed.out <> "/hub.loombundle")
    let hub2_home =
      installed(deployed, "hub2", deployed.out <> "/hub2.loombundle")
    let box_home = installed(deployed, "box", deployed.out <> "/box.loombundle")
    let hub = start(hub_home)
    let hub2 = start(hub2_home)
    let box = start(box_home)
    ok(step(hub, "directory_seed", "DIRECTORY seeded"), "hub creates the store")
    ok(step(hub2, "directory_member", "DIRECTORY started"), "hub2 starts")
    ok(step(box, "directory_member", "DIRECTORY started"), "box starts")
    let voters =
      held(id, [#("box", "voter"), #("hub", "voter"), #("hub2", "voter")])
    ok(step(hub, "await_ra " <> voters, "RA ok"), "hub lists three voters")
    ok(step(hub2, "await_ra " <> voters, "RA ok"), "hub2 lists three voters")
    ok(step(box, "await_ra " <> voters, "RA ok"), "box lists three voters")

    // A learner is enrolled and joins, as in the test above.
    let enroll = fn(out: String) {
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
            "--directory",
            "learner",
            "--out",
            deployed.base <> "/" <> out,
            "--wait",
            "30",
          ],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
    }
    let assert Ok(_) = enroll("bundles") as "the enrollment succeeds"
    let laptop_home =
      installed(
        deployed,
        "laptop",
        deployed.base <> "/bundles/laptop.loombundle",
      )
    let laptop = start(laptop_home)
    ok(
      step(laptop, "directory_member", "DIRECTORY started"),
      "the laptop starts",
    )
    let with_learner =
      held(id, [
        #("box", "voter"),
        #("hub", "voter"),
        #("hub2", "voter"),
        #("laptop", "learner"),
      ])
    ok(step(hub, "await_ra " <> with_learner, "RA ok"), "hub lists the learner")

    // The learner is revoked. The leader removes it from Ra, and the machine
    // ends, as a revoked one is shut down by its operator.
    let assert Ok(_) =
      ledger_cli.run_with(
        "revoke",
        list.flatten([
          ["laptop", "--reason", "reinstalled", "--wait", "30"],
          deployment.signing(deployed),
        ]),
        relay(hub),
      )
      as "the learner is revoked"
    ok(step(hub, "await_ra " <> voters, "RA ok"), "the leader removes it")
    ok(stop(laptop), "the laptop stops")

    // The same machine is enrolled again, on the same disk. The new bundle is
    // installed over the old files, and the directory the node keeps its store
    // in is not among them.
    let assert Ok(_) = enroll("bundles-again") as "the second enrollment"
    let assert Ok(_) =
      distribution_cli.run([
        "install",
        deployed.base <> "/bundles-again/laptop.loombundle",
        "--home",
        laptop_home,
        "--force",
      ])
      as "the new bundle installs over the old one"
    let again = start(laptop_home)
    ok(
      step(again, "directory_member", "DIRECTORY started"),
      "the laptop starts again",
    )

    // Nothing is done to the marker. The node asks, finds the cluster without
    // it, and joins again as a learner, which the other members list. (A learner
    // learns who leads late, so its own view is not what is asked.)
    ok(step(hub, "await_ra " <> with_learner, "RA ok"), "hub lists it again")
    ok(step(box, "await_ra " <> with_learner, "RA ok"), "box lists it again")

    ok(stop(again), "the laptop stops")
    ok(stop(box), "the box stops")
    ok(stop(hub2), "hub2 stops")
    ok(stop(hub), "hub stops")
    let _ = simplifile.delete(deployed.base)
    Nil
  })
}
