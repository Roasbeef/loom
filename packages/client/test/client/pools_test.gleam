//// The `[pools.<name>]` tables are strict, total and absent by default
//// (protocol-change/078). A pool lists configured executors in the order they
//// are tried and may require what their declarations say, and the same
//// refusals reach every reader of the file.

import client/catalog
import client/executors
import client/pools.{type Pool, Pool}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const distribution =
  "[distribution]
node = \"owner@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"a@10.0.0.2\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"b@10.0.0.3\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"

[[distribution.peers]]
node = \"c@10.0.0.4\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"

[executors.alpha]
node = \"a@10.0.0.2\"
platform = \"linux/x86_64\"
enforcement = \"enforced\"
toolchains = [\"codemode\"]

[executors.bravo]
node = \"b@10.0.0.3\"
platform = \"macos/arm64\"
enforcement = \"enforced\"

[executors.charlie]
node = \"c@10.0.0.4\"
"

fn refused(text: String, fragment: String) {
  let assert Error(reason) = pools.parse(distribution <> text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

fn configured() -> List(executors.Executor) {
  let assert Ok(found) = executors.parse(distribution)
  found
}

fn pool(text: String) -> Pool {
  let assert Ok([found]) = pools.parse(distribution <> text)
  found
}

pub fn an_absent_table_configures_no_pool_test() {
  assert pools.parse("") == Ok([])
  assert pools.parse(distribution) == Ok([])
  assert pools.from_document(dict.new()) == Ok([])
}

pub fn a_pool_lists_executors_in_order_and_the_list_is_sorted_by_name_test() {
  let text =
    "
[pools.zulu]
executors = [\"charlie\", \"alpha\"]

[pools.builders]
executors = [\"bravo\"]
platform = \"macos/arm64\"
enforcement = \"enforced\"
toolchains = [\"codemode\"]
"

  assert pools.parse(distribution <> text)
    == Ok([
      Pool(
        name: "builders",
        executors: ["bravo"],
        platform: Some("macos/arm64"),
        enforcement: Some(executors.Enforced),
        toolchains: ["codemode"],
      ),
      Pool(
        name: "zulu",
        executors: ["charlie", "alpha"],
        platform: None,
        enforcement: None,
        toolchains: [],
      ),
    ])
  let assert Ok(all) = pools.parse(distribution <> text)
  assert pools.find(all, "zulu") == Ok(pool_named(all, "zulu"))
  assert pools.find(all, "elsewhere") == Error(Nil)
}

fn pool_named(all: List(Pool), name: String) -> Pool {
  let assert [found] = list.filter(all, fn(each) { each.name == name })
  found
}

pub fn a_malformed_pool_is_refused_with_the_key_it_names_test() {
  refused(
    "\n[pools.Fast]\nexecutors = [\"alpha\"]\n",
    "pools.Fast is not a pool name",
  )
  refused("\n[pools.fast]\n", "pools.fast.executors is required")
  refused(
    "\n[pools.fast]\nexecutors = []\n",
    "pools.fast.executors must name at least one executor",
  )
  refused(
    "\n[pools.fast]\nexecutors = \"alpha\"\n",
    "pools.fast.executors must be a list of executor names",
  )
  refused(
    "\n[pools.fast]\nexecutors = [1]\n",
    "pools.fast.executors must be a list of executor names",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\", \"alpha\"]\n",
    "pools.fast.executors names an executor twice",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\", \"nowhere\"]\n",
    "pools.fast.executors names nowhere, which is not an [executors.<name>]",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\"]\nweight = 2\n",
    "unknown key `weight` in [pools.fast] (allowed: executors, platform, enforcement, toolchains)",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\"]\nplatform = \"linux\"\n",
    "pools.fast.platform must be a string of the form <os>/<architecture>",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\"]\nenforcement = \"on\"\n",
    "pools.fast.enforcement must be \"enforced\" or \"degraded\"",
  )
  refused(
    "\n[pools.fast]\nexecutors = [\"alpha\"]\ntoolchains = [\"Big\"]\n",
    "pools.fast.toolchains must be a list of distinct lowercase names",
  )
  refused("\n[pools]\nfast = [\"alpha\"]\n", "pools.fast must be a table")
  let assert Error(reason) = pools.parse("pools = \"fast\"\n")
  assert string.contains(reason, "pools must be a table")
  refused(
    "\n[pools." <> string.repeat("a", 33) <> "]\nexecutors = [\"alpha\"]\n",
    "is not a pool name",
  )
}

pub fn a_pool_without_configured_executors_is_refused_test() {
  let assert Error(reason) =
    pools.parse("[pools.fast]\nexecutors = [\"alpha\"]\n")
  assert string.contains(reason, "executors")
}

pub fn the_candidates_follow_the_declared_order_test() {
  let fast =
    pool("\n[pools.fast]\nexecutors = [\"charlie\", \"alpha\", \"bravo\"]\n")

  assert names(pools.candidates(fast, configured()))
    == ["charlie", "alpha", "bravo"]
}

pub fn a_requirement_keeps_only_executors_that_declared_it_test() {
  let on_linux =
    pool(
      "\n[pools.linux]\nexecutors = [\"charlie\", \"bravo\", \"alpha\"]\nplatform = \"linux/x86_64\"\n",
    )
  let enforced =
    pool(
      "\n[pools.safe]\nexecutors = [\"alpha\", \"bravo\", \"charlie\"]\nenforcement = \"enforced\"\n",
    )
  let with_codemode =
    pool(
      "\n[pools.cm]\nexecutors = [\"bravo\", \"alpha\"]\ntoolchains = [\"codemode\"]\n",
    )
  let everything =
    pool(
      "\n[pools.all]\nexecutors = [\"alpha\", \"bravo\"]\nplatform = \"linux/x86_64\"\nenforcement = \"enforced\"\ntoolchains = [\"codemode\"]\n",
    )

  // An executor that declared nothing (charlie) cannot satisfy a requirement.
  assert names(pools.candidates(on_linux, configured())) == ["alpha"]
  assert names(pools.candidates(enforced, configured())) == ["alpha", "bravo"]
  assert names(pools.candidates(with_codemode, configured())) == ["alpha"]
  assert names(pools.candidates(everything, configured())) == ["alpha"]
}

pub fn a_pool_that_no_executor_satisfies_has_no_candidates_test() {
  let none =
    pool(
      "\n[pools.windows]\nexecutors = [\"alpha\", \"bravo\"]\nplatform = \"windows/x86_64\"\n",
    )

  assert pools.candidates(none, configured()) == []
  assert pools.requirements(none) == "platform windows/x86_64"
}

pub fn requirements_are_worded_for_the_refusal_test() {
  let plain = pool("\n[pools.p]\nexecutors = [\"alpha\"]\n")
  let all =
    pool(
      "\n[pools.q]\nexecutors = [\"alpha\"]\nplatform = \"linux/x86_64\"\nenforcement = \"degraded\"\ntoolchains = [\"codemode\", \"gleam_ls\"]\n",
    )

  assert pools.requirements(plain) == "no requirements"
  assert pools.requirements(all)
    == "platform linux/x86_64, enforcement degraded, toolchains codemode, gleam_ls"
}

pub fn the_catalogue_parser_refuses_what_the_pool_parser_refuses_test() {
  // The catalogue validates the table before it looks for any model, so a typo
  // is refused by every reader of the file and not only at startup.
  let text = distribution <> "\n[pools.fast]\nexecutors = [\"nowhere\"]\n"
  let assert Error(reason) = catalog.parse(text)
  assert string.contains(reason, "pools.fast.executors names nowhere")
  let valid = distribution <> "\n[pools.fast]\nexecutors = [\"alpha\"]\n"
  let assert Error(without_models) = catalog.parse(valid)
  assert without_models == "the catalogue needs a [models.<name>] table"
}

fn names(found: List(executors.Executor)) -> List(String) {
  list.map(found, fn(executor) { executor.name })
}
