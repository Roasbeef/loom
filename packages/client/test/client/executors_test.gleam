//// The `[executors.<name>]` tables are strict, total and absent by default
//// (protocol-change/078). An executor is a pinned distribution peer under a
//// name, so a table that names anything else is refused wherever the file is
//// read.

import client/catalog
import client/executors.{Executor}
import gleam/dict
import gleam/string

const distribution =
  "[distribution]
node = \"owner@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"executor@10.0.0.2\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"spare@10.0.0.3\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"
"

fn refused(text: String, fragment: String) {
  let assert Error(reason) = executors.parse(text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

pub fn an_absent_table_configures_no_executor_test() {
  assert executors.parse("") == Ok([])
  assert executors.parse(distribution) == Ok([])
  assert executors.from_document(dict.new()) == Ok([])
}

pub fn each_table_names_one_pinned_peer_and_the_list_is_sorted_test() {
  let text = distribution <> "
[executors.build-box]
node = \"executor@10.0.0.2\"

[executors.alpha]
node = \"spare@10.0.0.3\"
"
  assert executors.parse(text)
    == Ok([
      Executor("alpha", "spare@10.0.0.3"),
      Executor("build-box", "executor@10.0.0.2"),
    ])
  let assert Ok(configured) = executors.parse(text)
  assert executors.find(configured, "build-box")
    == Ok(Executor("build-box", "executor@10.0.0.2"))
  assert executors.find(configured, "elsewhere") == Error(Nil)
}

pub fn a_node_that_is_not_a_pinned_peer_is_refused_by_name_test() {
  refused(distribution <> "
[executors.build-box]
node = \"stranger@10.0.0.9\"
", "executors.build-box.node stranger@10.0.0.9 is not a node in [[distribution.peers]]")
}

pub fn executors_without_a_distribution_table_are_refused_test() {
  refused(
    "[executors.build-box]\nnode = \"executor@10.0.0.2\"\n",
    "executors needs a [distribution] table naming its peers",
  )
}

pub fn a_malformed_table_is_refused_with_the_key_it_names_test() {
  let with = fn(table: String) { distribution <> "\n" <> table }
  refused(
    with("[executors.Build]\nnode = \"executor@10.0.0.2\"\n"),
    "executors.Build is not an executor name",
  )
  refused(
    with("[executors.build-box]\n"),
    "executors.build-box.node is required",
  )
  refused(
    with("[executors.build-box]\nnode = 1\n"),
    "executors.build-box.node must be a string",
  )
  refused(
    with("[executors.build-box]\nnode = \"executor@10.0.0.2\"\nhost = \"x\"\n"),
    "unknown key `host` in [executors.build-box]",
  )
  refused(
    with("[executors]\nbuild-box = \"executor@10.0.0.2\"\n"),
    "executors.build-box must be a table",
  )
  refused("executors = \"build-box\"\n", "executors must be a table")
  refused(
    with(
      "[executors."
      <> string.repeat("a", 33)
      <> "]\nnode = \"executor@10.0.0.2\"\n",
    ),
    "is not an executor name",
  )
}

pub fn the_catalogue_parser_refuses_what_the_executor_parser_refuses_test() {
  // The catalogue validates the table before it looks for any model, so a typo
  // is refused by every reader of the file and not only at startup.
  let text =
    distribution <> "\n[executors.build-box]\nnode = \"stranger@10.0.0.9\"\n"
  let assert Error(reason) = catalog.parse(text)
  assert string.contains(reason, "executors.build-box.node stranger@10.0.0.9")
  let valid =
    distribution <> "\n[executors.build-box]\nnode = \"executor@10.0.0.2\"\n"
  let assert Error(without_models) = catalog.parse(valid)
  assert without_models == "the catalogue needs a [models.<name>] table"
}
