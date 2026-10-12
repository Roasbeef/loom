//// The tables that name a peer, read against a node's ledger
//// (protocol-change/086). In static mode `[executors.<name>]` and its siblings
//// check their node against `[[distribution.peers]]`; in ledger mode there are
//// no such rows, and the check is against the nodes this node's pin table
//// holds. The ledger is the one `provision` signs for a plan, so the
//// signatures and certificates are real.

import client/distribution_plan.{TomlPlan}
import client/distribution_provision
import client/executors
import client/orchestrators
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import support/remote_fixtures

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
  "[distribution]\nnode = \""
  <> node
  <> "\"\nca = \""
  <> directory
  <> "/ca.pem\"\ncertificate = \""
  <> directory
  <> "/cert.pem\"\nkey = \""
  <> directory
  <> "/key.pem\"\ncookie = \""
  <> directory
  <> "/cookie\"\nledger = \""
  <> directory
  <> "/ledger.log\"\n"
}

pub fn an_executor_row_may_name_a_member_the_node_is_linked_to_test() {
  let text =
    configuration("loom@laptop.example")
    <> "\n[executors.devbox]\nnode = \"loom@devbox.example\"\n"
  assert executors.parse(text)
    == Ok([executors.plain("devbox", "loom@devbox.example")])
}

pub fn a_row_may_name_another_orchestrator_the_node_is_linked_to_test() {
  let text =
    configuration("loom@laptop.example")
    <> "\n[orchestrators.desk]\nnode = \"loom@desk.example\"\n"
  let assert Ok([desk]) = orchestrators.parse(text)
  assert desk.node == "loom@desk.example"
}

pub fn a_member_the_node_is_not_linked_to_is_refused_test() {
  // The laptop uses the devbox only. The buildbox is a member of the ledger
  // and is not in the laptop's pin table, as it would not be in a static list.
  let text =
    configuration("loom@laptop.example")
    <> "\n[executors.buildbox]\nnode = \"loom@buildbox.example\"\n"
  let assert Error(reason) = executors.parse(text)
  assert string.contains(
    reason,
    "executors.buildbox.node loom@buildbox.example is not a peer of this node",
  )
}

pub fn a_node_the_ledger_never_enrolled_is_refused_test() {
  let text =
    configuration("loom@laptop.example")
    <> "\n[executors.ghost]\nnode = \"loom@ghost.example\"\n"
  let assert Error(reason) = executors.parse(text)
  assert string.contains(
    reason,
    "loom@ghost.example is not a peer of this node",
  )
}

pub fn a_node_that_is_not_in_the_ledger_is_refused_with_its_remedy_test() {
  let text =
    configuration("loom@nobody.example")
    <> "\n[executors.devbox]\nnode = \"loom@devbox.example\"\n"
  let assert Error(reason) = executors.parse(text)
  assert string.contains(
    reason,
    "distribution.node loom@nobody.example is not an active member",
  )
  assert string.contains(reason, "loom distribution enroll")
}
