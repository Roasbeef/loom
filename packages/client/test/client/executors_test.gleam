//// The `[executors.<name>]` tables are strict, total and absent by default
//// (protocol-change/078). An executor is a pinned distribution peer under a
//// name, so a table that names anything else is refused wherever the file is
//// read.

import client/catalog
import client/executors.{Degraded, Enforced, Executor, Observed}
import gleam/dict
import gleam/option.{Some}
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
      executors.plain("alpha", "spare@10.0.0.3"),
      executors.plain("build-box", "executor@10.0.0.2"),
    ])
  let assert Ok(configured) = executors.parse(text)
  assert executors.find(configured, "build-box")
    == Ok(executors.plain("build-box", "executor@10.0.0.2"))
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

// --- declarations ------------------------------------------------------------

fn executor_with(lines: String) -> String {
  distribution
  <> "\n[executors.build-box]\nnode = \"executor@10.0.0.2\"\n"
  <> lines
}

pub fn a_row_may_declare_its_platform_enforcement_and_toolchains_test() {
  let text =
    executor_with(
      "platform = \"linux/x86_64\"
enforcement = \"enforced\"
toolchains = [\"codemode\", \"gleam_ls\"]
",
    )

  assert executors.parse(text)
    == Ok([
      Executor(
        name: "build-box",
        node: "executor@10.0.0.2",
        platform: Some("linux/x86_64"),
        enforcement: Some(Enforced),
        toolchains: ["codemode", "gleam_ls"],
      ),
    ])
  assert executors.parse(executor_with("enforcement = \"degraded\"\n"))
    == Ok([
      Executor(
        ..executors.plain("build-box", "executor@10.0.0.2"),
        enforcement: Some(Degraded),
      ),
    ])
}

pub fn a_malformed_declaration_is_refused_with_the_key_it_names_test() {
  refused(
    executor_with("platform = 1\n"),
    "executors.build-box.platform must be a string of the form <os>/<architecture>",
  )
  refused(
    executor_with("platform = \"linux\"\n"),
    "executors.build-box.platform must be a string",
  )
  refused(
    executor_with("platform = \"Linux/x86_64\"\n"),
    "executors.build-box.platform must be a string",
  )
  refused(
    executor_with("platform = \"linux/x86/64\"\n"),
    "executors.build-box.platform must be a string",
  )
  refused(
    executor_with("enforcement = \"strict\"\n"),
    "executors.build-box.enforcement must be \"enforced\" or \"degraded\"",
  )
  refused(
    executor_with("enforcement = true\n"),
    "executors.build-box.enforcement must be",
  )
  refused(
    executor_with("toolchains = \"codemode\"\n"),
    "executors.build-box.toolchains must be a list of distinct lowercase names",
  )
  refused(
    executor_with("toolchains = [\"Code Mode\"]\n"),
    "executors.build-box.toolchains must be a list",
  )
  refused(
    executor_with("toolchains = [1]\n"),
    "executors.build-box.toolchains must be a list",
  )
  refused(
    executor_with("toolchains = [\"codemode\", \"codemode\"]\n"),
    "executors.build-box.toolchains must be a list",
  )
  refused(
    executor_with("capacity = 4\n"),
    "unknown key `capacity` in [executors.build-box] (allowed: node, platform, enforcement, toolchains)",
  )
}

fn declared() -> executors.Executor {
  Executor(
    name: "build-box",
    node: "executor@10.0.0.2",
    platform: Some("linux/x86_64"),
    enforcement: Some(Enforced),
    toolchains: ["codemode"],
  )
}

pub fn a_census_that_matches_the_declaration_is_not_contradicted_test() {
  let observed = Observed("linux/x86_64", Enforced, ["codemode", "gleam_ls"])

  // A machine that provides more than it declared is not contradicted, and a
  // row that declares nothing is never contradicted.
  assert executors.contradiction(declared(), observed) == Ok(Nil)
  assert executors.contradiction(
      executors.plain("build-box", "executor@10.0.0.2"),
      Observed("macos/arm64", Degraded, []),
    )
    == Ok(Nil)
}

pub fn a_census_that_contradicts_the_declaration_names_both_values_test() {
  let box = declared()
  assert executors.contradiction(
      box,
      Observed("macos/arm64", Enforced, ["codemode"]),
    )
    == Error(
      "executor build-box declares platform linux/x86_64 but its census reports macos/arm64",
    )
  assert executors.contradiction(
      box,
      Observed("linux/x86_64", Degraded, ["codemode"]),
    )
    == Error(
      "executor build-box declares enforcement enforced but its census reports degraded",
    )
  assert executors.contradiction(box, Observed("linux/x86_64", Enforced, []))
    == Error(
      "executor build-box declares toolchain codemode but its census reports []",
    )
}
