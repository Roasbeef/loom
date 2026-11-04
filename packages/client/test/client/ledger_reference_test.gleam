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
import client/pools
import client/spawners
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
import tom

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

pub fn read_only_launch_validation_refuses_missing_and_corrupt_ledger_test() {
  let text = configuration("loom@laptop.example")
  let assert Ok(document) = tom.parse(text)
  let assert Ok(Some(settings)) = distribution.parse(text)
  let assert Some(path) = distribution.ledger_path(settings)
  let assert Ok(original) = simplifile.read(path)
  let assert Ok(_) = main.validate_launch_distribution(document, "/fixture")
  let assert Ok(ghost) =
    tom.parse(text <> "\n[executors.ghost]\nnode = \"loom@ghost.example\"\n")
  let assert Error(ghost_reason) =
    main.validate_launch_distribution(ghost, "/fixture")
  assert string.contains(ghost_reason, "ghost")
  let unknown =
    string.replace(text, "loom@laptop.example", "loom@unknown.example")
  let assert Ok(unknown_document) = tom.parse(unknown)
  let assert Error(unknown_reason) =
    main.validate_launch_distribution(unknown_document, "/fixture")
  assert string.contains(unknown_reason, "not an active member")
  let other_text = configuration("loom@laptop.example")
  let assert Ok(Some(other_settings)) = distribution.parse(other_text)
  let ca = distribution.credential_files(settings).ca
  let other_ca = distribution.credential_files(other_settings).ca
  let assert Ok(original_ca) = simplifile.read(ca)
  let assert Ok(other_ca_text) = simplifile.read(other_ca)
  assert simplifile.write(ca, other_ca_text) == Ok(Nil)
  let assert Error(_) = main.validate_launch_distribution(document, "/fixture")
  assert simplifile.write(ca, original_ca) == Ok(Nil)
  assert simplifile.write(path, original <> "torn") == Ok(Nil)
  let assert Ok(_) = main.validate_launch_distribution(document, "/fixture")
  assert simplifile.read(path) == Ok(original <> "torn")
  assert simplifile.write(path, original <> "invalid\n") == Ok(Nil)
  let assert Error(_) = main.validate_launch_distribution(document, "/fixture")
  assert simplifile.delete(path) == Ok(Nil)
  let assert Error(_) = main.validate_launch_distribution(document, "/fixture")
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

// --- executor names ----------------------------------------------------------

// The laptop is an orchestrator linked to the box. The desk is an executor it is
// not linked to, `peer` is another orchestrator, and `gone` was an executor
// that was revoked.
fn named_ledger() {
  let history =
    membership.genesis()
    |> membership.enroll("box", [])
    |> membership.enroll("desk", [])
    |> membership.enroll("gone", [])
    |> membership.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("laptop", ["box"]),
        role: distribution_plan.Orchestrator,
      ),
    ))
    |> membership.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("peer", ["laptop"]),
        role: distribution_plan.Orchestrator,
      ),
    ))
    |> membership.revoke("gone")
  history.ledger
}

fn names(keys: List(#(String, String))) -> List(ledger_reference.NameRow) {
  list.map(keys, fn(pair) { ledger_reference.NameRow(pair.0, pair.1) })
}

pub fn audit_names_sorts_references_into_fine_inert_and_refused_test() {
  let ledger = named_ledger()

  // The box is a linked executor and `mine` is a written row: both are fine.
  // The desk is an executor the laptop is not linked to and `gone` was revoked,
  // so both are inert.
  let assert Ok(inert) =
    ledger_reference.audit_names(
      ledger,
      laptop,
      "ledger.log",
      ["mine"],
      names([
        #("pools.builders.executors", "box"),
        #("pools.builders.executors", "mine"),
        #("pools.builders.executors", "desk"),
        #("spawners.guest.executor", "gone"),
      ]),
    )
  assert list.map(inert, fn(found) { found.row.name }) == ["desk", "gone"]
  let assert [unlinked, departed] = inert
  assert string.contains(unlinked.reason, "not linked")
  assert string.contains(departed.reason, "revoked")
}

pub fn audit_names_refuses_a_name_nobody_gave_test() {
  let assert Error(reason) =
    ledger_reference.audit_names(
      named_ledger(),
      laptop,
      "/etc/loom/ledger.log",
      [],
      names([#("pools.builders.executors", "ghost")]),
    )
  assert string.contains(reason, "pools.builders.executors names ghost")
  assert string.contains(reason, "/etc/loom/ledger.log")
  assert string.contains(reason, "loom distribution enroll")
}

pub fn audit_names_refuses_an_orchestrator_named_as_an_executor_test() {
  let assert Error(reason) =
    ledger_reference.audit_names(
      named_ledger(),
      laptop,
      "ledger.log",
      [],
      names([#("spawners.guest.executor", "peer")]),
    )
  assert string.contains(reason, "enrolled as an orchestrator")
}

pub fn a_written_row_is_not_judged_by_the_ledger_by_name_test() {
  // The written row is audited by its node. The name itself may be anything the
  // grammar allows, because the operator chose it.
  let assert Ok([]) =
    ledger_reference.audit_names(
      named_ledger(),
      laptop,
      "ledger.log",
      ["whatever"],
      names([#("pools.builders.executors", "whatever")]),
    )
}

// --- pools and spawners in ledger mode -----------------------------------------

const ledgered =
  "[distribution]
node = \"loom@laptop.example\"
ca = \"/nowhere/ca.pem\"
certificate = \"/nowhere/cert.pem\"
key = \"/nowhere/key.pem\"
cookie = \"/nowhere/cookie\"
ledger = \"/nowhere/ledger.log\"
"

const statically =
  "[distribution]
node = \"loom@laptop.example\"
ca = \"/nowhere/ca.pem\"
certificate = \"/nowhere/cert.pem\"
key = \"/nowhere/key.pem\"
cookie = \"/nowhere/cookie\"

[[distribution.peers]]
node = \"loom@box.example\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"
"

const a_pool =
  "
[pools.builders]
executors = [\"box\"]
"

const a_spawner =
  "
[spawners.guest]
node = \"loom@box.example\"
executor = \"box\"
workspace = \"loom\"
profile = \"cheap\"

[profiles.cheap.roles]
main = [\"fast\"]
"

pub fn a_pool_may_list_an_executor_only_the_ledger_knows_test() {
  let assert Ok([pool]) = pools.parse(ledgered <> a_pool)
  assert pool.executors == ["box"]

  // Static mode is as strict as it was: the member has to be a written row.
  let assert Error(reason) = pools.parse(statically <> a_pool)
  assert string.contains(reason, "which is not an [executors.<name>]")
}

pub fn a_pool_member_still_needs_the_grammar_in_ledger_mode_test() {
  let assert Error(reason) =
    pools.parse(
      ledgered <> "\n[pools.builders]\nexecutors = [\"Not A Name\"]\n",
    )
  assert string.contains(reason, "not an executor name")
}

pub fn a_spawner_may_place_on_an_executor_only_the_ledger_knows_test() {
  let assert Ok([spawner]) = spawners.parse(ledgered <> a_spawner)
  assert spawner.placement
    == spawners.OnExecutor(executor: "box", workspace: "loom")
  let assert Error(reason) = spawners.parse(statically <> a_spawner)
  assert string.contains(reason, "not a configured [executors.<name>]")
}

pub fn the_references_of_a_configuration_are_named_with_their_keys_test() {
  let assert Ok(configured_pools) = pools.parse(ledgered <> a_pool)
  let assert Ok(configured_spawners) = spawners.parse(ledgered <> a_spawner)
  assert main.reference_names(configured_pools, configured_spawners)
    == [
      ledger_reference.NameRow("pools.builders.executors", "box"),
      ledger_reference.NameRow("spawners.guest.executor", "box"),
    ]
}

pub fn a_start_with_a_pool_naming_a_revoked_executor_warns_and_goes_on_test() {
  let started =
    rig.start(
      "reference-names",
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
    main.audit_executor_names(
      started.service,
      "loom@hub.example.net",
      "ledger.log",
      [],
      names([#("pools.builders.executors", "devbox")]),
      logger,
    )
  let assert Ok(warning) = process.receive(records, 1000)
  assert warning.event == "daemon.ledger_name_inert"
  assert string.contains(
    string.inspect(warning.fields),
    "pools.builders.executors",
  )

  // A name nobody gave refuses the start, and logs nothing.
  let assert Error(_) =
    main.audit_executor_names(
      started.service,
      "loom@hub.example.net",
      "ledger.log",
      [],
      names([#("pools.builders.executors", "ghost")]),
      logger,
    )
  assert process.receive(records, 50) == Error(Nil)
}
