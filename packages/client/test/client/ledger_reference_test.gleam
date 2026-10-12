//// The tables that name a peer, read against a node's ledger
//// (protocol-change/086). In static mode `[executors.<name>]` and its siblings
//// check their node against `[[distribution.peers]]` when they are parsed. In
//// ledger mode parsing checks a row's shape and never opens the ledger, because
//// a session parses these tables on every create and open and a ledger changes
//// while a daemon runs. The daemon compares the rows with the ledger once, at
//// start: a node no entry ever named refuses the start, and a node that was a
//// member and no longer is logs a warning and stays as an inert row.

import client/catalog
import client/daemon/ledger_cli
import client/daemon/main
import client/distribution
import client/distribution_plan.{TomlPlan}
import client/distribution_provision
import client/executors
import client/ledger_reference.{Row}
import client/membership_entry.{Upsert}
import client/orchestrators
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import support/ledger_deployment as deployment
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as membership
import support/remote_fixtures
import telemetry/level
import telemetry/log
import telemetry/record

const plan_text =
  "[[node]]
name = \"laptop\"
role = \"orchestrator\"
erlang_node = \"loom@laptop.example\"
executors = [\"devbox\"]

[[node]]
name = \"desk\"
role = \"orchestrator\"
erlang_node = \"loom@desk.example\"
executors = [\"buildbox\"]

[[node]]
name = \"devbox\"
role = \"executor\"
erlang_node = \"loom@devbox.example\"
[node.workspaces]
repo = \"/home/me/src/loom\"

[[node]]
name = \"buildbox\"
role = \"executor\"
erlang_node = \"loom@buildbox.example\"
[node.workspaces]
repo = \"/srv/repo\"
"

// A node's `[distribution]` table over the ledger that `provision` signed for
// the plan, with the files in a scratch directory.
fn configuration(node: String) -> String {
  let assert Ok(plan) = distribution_plan.parse(plan_text, TomlPlan)
  let assert Ok(made) =
    distribution_provision.provision_ledger(
      plan,
      timestamp.from_unix_seconds(1_760_000_000),
    )
  let assert Ok(directory) =
    bootstrap.absolute_path(remote_fixtures.scratch("reference"))
  let assert Ok(Nil) =
    simplifile.write(directory <> "/ca.pem", made.authority.certificate)
  let assert Ok(Nil) = simplifile.write(directory <> "/ledger.log", made.ledger)
  distribution_table(node, directory <> "/ca.pem", directory <> "/ledger.log")
}

fn distribution_table(node: String, ca: String, ledger: String) -> String {
  "[distribution]\nnode = \""
  <> node
  <> "\"\nca = \""
  <> ca
  <> "\"\ncertificate = \"/nowhere/cert.pem\"\nkey = \"/nowhere/key.pem\""
  <> "\ncookie = \"/nowhere/cookie\"\nledger = \""
  <> ledger
  <> "\"\n"
}

// The ledger a daemon of the node `node` runs on, opened as its start opens it.
fn loaded(text: String, node: String) -> ledger_reference.Loaded {
  let assert Ok(Some(settings)) = distribution.parse(text)
  let assert Some(path) = distribution.ledger_path(settings)
  let assert Ok(opened) =
    ledger_reference.load(
      path,
      distribution.credential_files(settings).ca,
      node,
    )
  opened
}

const minimal =
  "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"

pub fn an_executor_row_may_name_a_member_the_node_is_linked_to_test() {
  let text =
    configuration("loom@laptop.example")
    <> "\n[executors.devbox]\nnode = \"loom@devbox.example\"\n"
  assert executors.parse(text)
    == Ok([executors.plain("devbox", "loom@devbox.example")])
  let opened = loaded(text, "loom@laptop.example")
  assert ledger_reference.audit(opened.ledger, "loom@laptop.example", "ledger", [
      Row("executors.devbox.node", "loom@devbox.example"),
    ])
    == Ok([])
}

pub fn a_row_may_name_another_orchestrator_the_node_is_linked_to_test() {
  let text =
    configuration("loom@laptop.example")
    <> "\n[orchestrators.desk]\nnode = \"loom@desk.example\"\n"
  let assert Ok([desk]) = orchestrators.parse(text)
  assert desk.node == "loom@desk.example"
}

pub fn parsing_a_ledger_table_checks_the_shape_and_never_opens_the_file_test() {
  // The ledger and the `ca` file do not exist. If parsing read them it would be
  // refused for that, and a node no entry names would be refused for the node.
  let text =
    distribution_table("loom@laptop.example", "/nowhere/ca.pem", "/nowhere/l")
    <> "\n[executors.ghost]\nnode = \"loom@ghost.example\"\n"
  assert executors.parse(text)
    == Ok([executors.plain("ghost", "loom@ghost.example")])

  // The shape is still checked: a key the table does not know is refused.
  let assert Error(reason) = executors.parse(text <> "colour = \"red\"\n")
  assert string.contains(reason, "colour")
}

// A hub whose devbox has been revoked, over the real commands: a sealed
// authority key, real certificates, and the operator's copy of the ledger
// holding the revoke. The returned configuration is the hub's, with a row that
// still names the devbox.
fn hub_config_after_a_revoke() -> String {
  let deployed = deployment.provision("reference-revoked", deployment.plan_text)
  let handle = deployment.serve(deployed, "hub", "hub", "loom@hub.example")
  let assert Ok(_) =
    ledger_cli.run_with(
      "revoke",
      ["devbox", "--force", "--wait", "0", ..deployment.signing(deployed)],
      fn(_) { deployment.daemon_over(handle) },
    )
  let authority = deployment.authority_directory(deployed)
  distribution_table(
    "loom@hub.example",
    authority <> "/ca.pem",
    authority <> "/ledger.log",
  )
  <> minimal
  <> "\n[executors.devbox]\nnode = \"loom@devbox.example\"\n"
}

pub fn a_revoke_does_not_stop_the_catalogue_from_parsing_test() {
  // The regression this guards: parsing the catalogue opened the ledger and
  // refused a row that names a member who is no longer active, so after one
  // `revoke` every session create, open and profile switch on the daemon failed
  // until the operator edited the file.
  let text = hub_config_after_a_revoke()
  let assert Ok(parsed) = catalog.parse(text)
  assert list.length(parsed.models) == 1
  assert executors.parse(text)
    == Ok([executors.plain("devbox", "loom@devbox.example")])
}

fn capture() -> #(log.Logger, process.Subject(record.Record)) {
  let records = process.new_subject()
  #(log.new(sink: log.to_subject(records), threshold: level.Warning), records)
}

pub fn the_real_revoked_ledger_marks_the_devbox_row_inert_test() {
  let text = hub_config_after_a_revoke()
  let assert Ok(configured) = executors.parse(text)
  let opened = loaded(text, "loom@hub.example")
  let assert Ok([found]) =
    ledger_reference.audit(
      opened.ledger,
      "loom@hub.example",
      "ledger.log",
      main.reference_rows(configured, [], []),
    )
  assert found.row == Row("executors.devbox.node", "loom@devbox.example")
  assert string.contains(found.reason, "no longer an active member")
}

pub fn a_start_with_a_row_naming_a_revoked_member_warns_and_goes_on_test() {
  let started =
    rig.start(
      "reference-start",
      membership.lines(
        membership.genesis()
        |> membership.enroll("hub", [])
        |> membership.enroll("devbox", ["hub"])
        |> membership.revoke("devbox"),
      ),
      rig.patient,
      [],
    )
  let #(logger, records) = capture()
  let assert Ok(Nil) =
    main.audit_references(
      started.service,
      "loom@hub.example.net",
      "ledger.log",
      [Row("executors.devbox.node", "loom@devbox.example.net")],
      logger,
    )
  let assert Ok(warning) = process.receive(records, 1000)
  assert warning.event == "daemon.ledger_row_inert"
  assert string.contains(
    string.inspect(warning.fields),
    "executors.devbox.node",
  )
}

pub fn a_start_with_a_row_naming_a_node_no_entry_named_is_refused_test() {
  let started =
    rig.start(
      "reference-refused",
      membership.lines(
        membership.genesis()
        |> membership.enroll("hub", [])
        |> membership.enroll("devbox", ["hub"]),
      ),
      rig.patient,
      [],
    )
  let #(logger, records) = capture()
  let assert Error(reason) =
    main.audit_references(
      started.service,
      "loom@hub.example.net",
      "/etc/loom/ledger.log",
      [
        Row("executors.devbox.node", "loom@devbox.example.net"),
        Row("executors.ghost.node", "loom@ghost.example.net"),
      ],
      logger,
    )
  assert string.contains(reason, "executors.ghost.node loom@ghost.example.net")
  assert string.contains(reason, "/etc/loom/ledger.log")
  assert string.contains(reason, "loom distribution enroll")

  // A refusal is the whole outcome: nothing was logged for the row before it.
  assert process.receive(records, 50) == Error(Nil)
}

// The fixture ledger: the laptop uses the hub, the desk is enrolled with no
// link to either, and the gone member was enrolled and revoked.
fn fixture_ledger() {
  let history =
    membership.genesis()
    |> membership.enroll("hub", [])
    |> membership.enroll("laptop", ["hub"])
    |> membership.enroll("desk", [])
    |> membership.enroll("gone", ["hub"])
    |> membership.revoke("gone")
  history.ledger
}

const laptop = "loom@laptop.example.net"

pub fn audit_sorts_rows_into_linked_inert_and_refused_test() {
  let ledger = fixture_ledger()
  let linked = Row("executors.hub.node", "loom@hub.example.net")
  let unlinked = Row("orchestrators.desk.node", "loom@desk.example.net")
  let departed = Row("spawners.gone.node", "loom@gone.example.net")

  let assert Ok(inert) =
    ledger_reference.audit(ledger, laptop, "ledger.log", [
      linked,
      unlinked,
      departed,
    ])
  assert list.map(inert, fn(found) { found.row }) == [unlinked, departed]
  let assert [first, second] = inert
  assert string.contains(first.reason, "not linked")
  assert string.contains(second.reason, "no longer an active member")
}

pub fn audit_refuses_a_node_no_entry_named_and_the_node_itself_test() {
  let ledger = fixture_ledger()
  let assert Error(reason) =
    ledger_reference.audit(ledger, laptop, "ledger.log", [
      Row("executors.ghost.node", "loom@ghost.example.net"),
    ])
  assert string.contains(reason, "executors.ghost.node loom@ghost.example.net")
  assert string.contains(reason, "ledger.log")
  let assert Error(reason) =
    ledger_reference.audit(ledger, laptop, "ledger.log", [
      Row("executors.me.node", laptop),
    ])
  assert string.contains(reason, "this node itself")
}

pub fn a_node_the_ledger_names_only_in_a_replaced_entry_is_inert_not_unknown_test() {
  // The member `hub` moves to another node by a later entry. The old node is
  // not active, and it was named, so a stale row is inert and not a typo.
  let history =
    membership.genesis()
    |> membership.enroll("hub", [])
    |> membership.enroll("laptop", ["hub"])
    |> membership.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("hub", []),
        node: "loom@hub-new.example.net",
      ),
    ))
  let assert Ok([found]) =
    ledger_reference.audit(history.ledger, laptop, "ledger.log", [
      Row("executors.hub.node", "loom@hub.example.net"),
    ])
  assert string.contains(found.reason, "no longer an active member")
}
