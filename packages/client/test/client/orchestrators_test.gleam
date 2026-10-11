//// The `[orchestrators.<name>]` tables are strict, total and absent by default
//// (protocol-change/078, phase 3). An orchestrator is a pinned distribution
//// peer under a name, with an optional control address, so a table that names
//// anything else is refused wherever the file is read.

import client/catalog
import client/orchestrators.{Orchestrator}
import gleam/dict
import gleam/option.{Some}
import gleam/string

const distribution =
  "[distribution]
node = \"alpha@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"beta@10.0.0.2\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"gamma@10.0.0.3\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"
"

fn refused(text: String, fragment: String) {
  let assert Error(reason) = orchestrators.parse(text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

fn with(table: String) -> String {
  distribution <> "\n" <> table
}

pub fn an_absent_table_configures_no_orchestrator_test() {
  assert orchestrators.parse("") == Ok([])
  assert orchestrators.parse(distribution) == Ok([])
  assert orchestrators.from_document(dict.new()) == Ok([])
}

pub fn each_table_names_one_pinned_peer_and_the_list_is_sorted_test() {
  let text =
    with(
      "[orchestrators.gamma]
node = \"gamma@10.0.0.3\"

[orchestrators.beta]
node = \"beta@10.0.0.2\"
",
    )
  let expected = [
    orchestrators.plain("beta", "beta@10.0.0.2"),
    orchestrators.plain("gamma", "gamma@10.0.0.3"),
  ]
  assert orchestrators.parse(text) == Ok(expected)
  assert orchestrators.find(expected, "gamma")
    == Ok(orchestrators.plain("gamma", "gamma@10.0.0.3"))
  assert orchestrators.find(expected, "alpha") == Error(Nil)
  assert orchestrators.by_node(expected, "beta@10.0.0.2")
    == Ok(orchestrators.plain("beta", "beta@10.0.0.2"))
  assert orchestrators.by_node(expected, "alpha@10.0.0.1") == Error(Nil)
}

pub fn a_row_may_give_the_address_a_client_connects_to_test() {
  let text =
    with(
      "[orchestrators.beta]
node = \"beta@10.0.0.2\"
address = \"wss://beta.example.com:8443/v2/control\"
",
    )
  assert orchestrators.parse(text)
    == Ok([
      Orchestrator(
        name: "beta",
        node: "beta@10.0.0.2",
        address: Some("wss://beta.example.com:8443/v2/control"),
      ),
    ])
  let loopback =
    with(
      "[orchestrators.beta]
node = \"beta@10.0.0.2\"
address = \"ws://127.0.0.1:7000/v2/control\"
",
    )
  let assert Ok([row]) = orchestrators.parse(loopback)
  assert row.address == Some("ws://127.0.0.1:7000/v2/control")
}

pub fn a_node_that_is_not_a_pinned_peer_is_refused_by_name_test() {
  refused(
    with("[orchestrators.beta]\nnode = \"stranger@10.0.0.9\"\n"),
    "orchestrators.beta.node stranger@10.0.0.9 is not a node in [[distribution.peers]]",
  )
}

pub fn orchestrators_without_a_distribution_table_are_refused_test() {
  refused(
    "[orchestrators.beta]\nnode = \"beta@10.0.0.2\"\n",
    "orchestrators needs a [distribution] table naming its peers",
  )
}

pub fn two_names_for_one_node_are_refused_test() {
  refused(
    with(
      "[orchestrators.beta]
node = \"beta@10.0.0.2\"

[orchestrators.zeta]
node = \"beta@10.0.0.2\"
",
    ),
    "orchestrators.zeta.node beta@10.0.0.2 is already the node of orchestrators.beta",
  )
}

pub fn a_malformed_table_is_refused_with_the_key_it_names_test() {
  refused(
    with("[orchestrators.Beta]\nnode = \"beta@10.0.0.2\"\n"),
    "orchestrators.Beta is not an orchestrator name",
  )
  refused(with("[orchestrators.beta]\n"), "orchestrators.beta.node is required")
  refused(
    with("[orchestrators.beta]\nnode = 1\n"),
    "orchestrators.beta.node must be a string",
  )
  refused(
    with("[orchestrators.beta]\nnode = \"beta@10.0.0.2\"\nhost = \"x\"\n"),
    "unknown key `host` in [orchestrators.beta] (allowed: node, address)",
  )
  refused(
    with("[orchestrators]\nbeta = \"beta@10.0.0.2\"\n"),
    "orchestrators.beta must be a table",
  )
  refused("orchestrators = \"beta\"\n", "orchestrators must be a table")
  refused(
    with(
      "[orchestrators."
      <> string.repeat("a", 33)
      <> "]\nnode = \"beta@10.0.0.2\"\n",
    ),
    "is not an orchestrator name",
  )
}

pub fn an_address_a_bearer_could_leak_through_is_refused_test() {
  let row = fn(address: String) {
    with(
      "[orchestrators.beta]\nnode = \"beta@10.0.0.2\"\naddress = "
      <> address
      <> "\n",
    )
  }
  let words = "orchestrators.beta.address must be a control address"
  refused(row("1"), words)
  refused(row("\"beta.example.com\""), words)
  refused(row("\"http://beta.example.com/v2/control\""), words)
  refused(row("\"ws://beta.example.com/v2/control\""), words)
  refused(row("\"wss://user:secret@beta.example.com/v2/control\""), words)
  refused(row("\"wss://beta.example.com/v2/control?token=x\""), words)
  refused(row("\"wss://beta.example.com/other\""), words)
}

pub fn the_catalogue_parser_refuses_what_the_orchestrator_parser_refuses_test() {
  // The catalogue validates the table before it looks for any model, so a typo
  // is refused by every reader of the file and not only at startup.
  let text = with("[orchestrators.beta]\nnode = \"stranger@10.0.0.9\"\n")
  let assert Error(reason) = catalog.parse(text)
  assert string.contains(reason, "orchestrators.beta.node stranger@10.0.0.9")
  let valid = with("[orchestrators.beta]\nnode = \"beta@10.0.0.2\"\n")
  let assert Error(without_models) = catalog.parse(valid)
  assert without_models == "the catalogue needs a [models.<name>] table"
}
