//// What a provisioned two-orchestrator plan writes so that a session can move
//// between the orchestrators and a relayed page can start sessions, with no
//// edit after `loom distribution provision` and `install`.
////
//// The assertions read the written configuration with the daemon's own
//// readers (`orchestrators`, `spawners`), because the rows only count if the
//// daemon accepts them, and a move is accepted only from an orchestrator the
//// receiver lists (`daemon.move_refused`: "this orchestrator does not list the
//// node ... as an orchestrator").

import client/distribution
import client/distribution_bundle
import client/distribution_install.{Options}
import client/distribution_plan.{TomlPlan}
import client/distribution_provision.{RefuseExisting}
import client/internal/ffi_os
import client/orchestrators
import client/spawners
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile

fn scratch(label: String) -> String {
  let directory =
    "build/rows-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(absolute) = bootstrap.absolute_path(directory)
  absolute
}

const files =
  distribution.CredentialFiles(
    ca: "/c/ca.pem",
    certificate: "/c/cert.pem",
    key: "/c/key.pem",
    cookie: "/c/.erlang.cookie",
  )

// Two orchestrators and one executor each, as the two-machine drive used them:
// `box` lets `laptop` start sessions on its executor.
fn plan_text(spawners_on_box: String) -> String {
  "[[node]]
name = \"laptop\"
role = \"orchestrator\"
erlang_node = \"loom@laptop.example\"
executors = [\"e1\"]

[[node]]
name = \"box\"
role = \"orchestrator\"
erlang_node = \"loom@box.example\"
executors = [\"e2\"]
" <> spawners_on_box <> "
[[node]]
name = \"e1\"
role = \"executor\"
erlang_node = \"loom@e1.example\"
[node.workspaces]
proj = \"/srv/e1\"

[[node]]
name = \"e2\"
role = \"executor\"
erlang_node = \"loom@e2.example\"
[node.workspaces]
proj = \"/srv/e2\"
"
}

const relay_terms =
  "[node.spawners.laptop]
profile = \"relay\"
executor = \"e2\"
workspace = \"proj\"
"

fn deployment(text: String) -> distribution_provision.Deployment {
  let assert Ok(plan) = distribution_plan.parse(text, TomlPlan)
  let assert Ok(deployment) = distribution_provision.provision(plan)
  deployment
}

fn bundle_named(
  deployment: distribution_provision.Deployment,
  name: String,
) -> distribution_bundle.Bundle {
  let assert Ok(bundle) =
    list.find(deployment.bundles, fn(bundle) { bundle.name == name })
  bundle
}

// Orchestrators that peer with each other list each other, so either can
// receive a move from the other. The node is what the importer compares.
pub fn each_orchestrator_lists_the_other_and_accepts_its_moves_test() {
  let made = deployment(plan_text(""))
  let config = fn(name) {
    distribution_bundle.config_text(bundle_named(made, name), files)
  }

  let assert Ok(on_box) = orchestrators.parse(config("box"))
  assert list.map(on_box, fn(row) { #(row.name, row.node) })
    == [#("laptop", "loom@laptop.example")]
  let assert Ok(on_laptop) = orchestrators.parse(config("laptop"))
  assert list.map(on_laptop, fn(row) { #(row.name, row.node) })
    == [#("box", "loom@box.example")]

  // An executor is not an orchestrator and gets no row, and a plan with no
  // relay terms writes no spawner table.
  assert bundle_named(made, "e1").orchestrators == []
  assert !string.contains(config("box"), "[spawners")
}

// The terms in the plan become the spawner table and its `top_level` table, in
// the shape the daemon's reader accepts once a profile of that name exists.
pub fn a_relay_in_the_plan_writes_the_spawner_and_top_level_tables_test() {
  let made = deployment(plan_text(relay_terms))
  let text =
    distribution_bundle.config_text(bundle_named(made, "box"), files)
    <> "\n[profiles.relay.roles]\nmain = [\"m\"]\n"
  let assert Ok([spawner]) = spawners.parse(text)
    as "the daemon's reader accepts the written tables"
  assert spawner.name == "laptop"
  assert spawner.node == "loom@laptop.example"
  assert spawner.profile == "relay"
  let assert Some(top_level) = spawner.top_level
    as "the relay table lets the page start sessions"
  assert top_level.executors == ["e2"]
  assert top_level.profiles == Some(["relay"])

  // Only the box that admits the laptop writes it.
  assert !string.contains(
    distribution_bundle.config_text(bundle_named(made, "laptop"), files),
    "[spawners",
  )
}

// A bundle with the rows survives its own encoding, and one without them is
// byte for byte what an older provisioner wrote.
pub fn the_rows_survive_the_bundle_encoding_and_are_absent_without_them_test() {
  let made = deployment(plan_text(relay_terms))
  let box = bundle_named(made, "box")
  assert distribution_bundle.decode(distribution_bundle.encode(box)) == Ok(box)
  assert string.contains(distribution_bundle.encode(box), "\"spawners\"")

  let plain = bundle_named(made, "e1")
  assert !string.contains(distribution_bundle.encode(plain), "spawners")
  assert !string.contains(distribution_bundle.encode(plain), "orchestrators")
}

// The install merges the nested tables into a configuration file and reads them
// back, which is what proves they say what the bundle says.
pub fn install_writes_the_rows_into_the_configuration_test() {
  let base = scratch("install")
  let made = deployment(plan_text(relay_terms))
  let assert Ok(_) =
    distribution_provision.write(made, base <> "/out", RefuseExisting)
  let assert Ok(text) = simplifile.read(base <> "/out/box.loombundle")
  let home = base <> "/home"
  let assert Ok(_) =
    distribution_install.install(
      text,
      Options(
        home:,
        config: home <> "/.loom/loom.toml",
        overwrite: RefuseExisting,
      ),
    )
  let assert Ok(config) = simplifile.read(home <> "/.loom/loom.toml")
  assert string.contains(config, "[orchestrators.laptop]")
  assert string.contains(config, "[spawners.laptop.top_level]")
  let assert Ok(Nil) = simplifile.delete(base)
  Nil
}

// A ledger bundle derives the orchestrator rows at start, so it writes none,
// and a spawner is never derived, so it writes the one the plan asks for.
pub fn a_ledger_bundle_writes_the_spawner_and_no_orchestrator_rows_test() {
  let assert Ok(plan) =
    distribution_plan.parse(plan_text(relay_terms), TomlPlan)
  let assert Ok(distribution_provision.Provisioned(deployment: ledger, ..)) =
    distribution_provision.provision_ledger(plan, timestamp.system_time())
  let box = bundle_named(ledger, "box")
  assert box.orchestrators == []
  assert distribution_bundle.decode(distribution_bundle.encode(box)) == Ok(box)
  assert list.map(box.spawners, fn(relay) { relay.spawner.name }) == ["laptop"]
}

pub fn a_relay_that_names_nothing_it_can_use_is_refused_test() {
  let refused = fn(terms: String, fragment: String) {
    let assert Error(reason) =
      distribution_plan.parse(plan_text(terms), TomlPlan)
    assert string.contains(reason, fragment)
  }
  refused(
    "[node.spawners.nobody]\nprofile = \"relay\"\nexecutor = \"e2\"\nworkspace = \"proj\"\n",
    "is not a node",
  )
  refused(
    "[node.spawners.e1]\nprofile = \"relay\"\nexecutor = \"e2\"\nworkspace = \"proj\"\n",
    "is not an orchestrator",
  )
  refused(
    "[node.spawners.box]\nprofile = \"relay\"\nexecutor = \"e2\"\nworkspace = \"proj\"\n",
    "cannot spawn on itself",
  )
  refused(
    "[node.spawners.laptop]\nprofile = \"relay\"\nexecutor = \"e1\"\nworkspace = \"proj\"\n",
    "not one of this node's executors",
  )
  refused(
    "[node.spawners.laptop]\nprofile = \"relay\"\nexecutor = \"e2\"\nworkspace = \"absent\"\n",
    "has no workspace",
  )
  refused(
    "[node.spawners.laptop]\nprofile = \"relay\"\nexecutor = \"e2\"\n",
    "workspace is required",
  )
}
