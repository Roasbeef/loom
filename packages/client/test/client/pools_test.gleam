//// The `[pools.<name>]` tables are strict, total and absent by default
//// (protocol-change/078). A pool lists configured executors in the order they
//// are tried and may require what their declarations say, and the same
//// refusals reach every reader of the file.

import client/catalog
import client/executors
import client/pools.{type Pool, Pool}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

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
        attach_within_s: None,
      ),
      Pool(
        name: "zulu",
        executors: ["charlie", "alpha"],
        platform: None,
        enforcement: None,
        toolchains: [],
        attach_within_s: None,
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
    "unknown key `weight` in [pools.fast] (allowed: executors, platform, enforcement, toolchains, attach_within_s)",
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

// --- attach_within_s (protocol-change/095) -------------------------------------

pub fn a_pool_may_replace_its_members_wait_test() {
  let text = "\n[pools.big]\nexecutors = [\"alpha\"]\nattach_within_s = 300\n"
  let assert Ok([pool]) = pools.parse(distribution <> text)
  assert pool.attach_within_s == Some(300)
  let plain = "\n[pools.big]\nexecutors = [\"alpha\"]\n"
  let assert Ok([unsized]) = pools.parse(distribution <> plain)
  assert unsized.attach_within_s == None
}

pub fn a_pools_wait_is_bounded_like_an_executors_test() {
  refused(
    "\n[pools.big]\nexecutors = [\"alpha\"]\nattach_within_s = 901\n",
    "pools.big.attach_within_s must be a whole number of seconds from 1 to 900",
  )
}

// --- spreading the sessions a pool places ---------------------------------------

fn boxes(count: Int) -> List(executors.Executor) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_each, number) {
    let name = "e" <> int.to_string(number)
    executors.plain(name, name <> "@10.0.0." <> int.to_string(number + 2))
  })
}

pub fn with_nothing_open_the_candidates_keep_their_order_test() {
  // This is exactly the first-fit order, so a pool nobody has used behaves as
  // it did before sessions were spread.
  assert names(pools.spread(boxes(4), dict.new())) == ["e0", "e1", "e2", "e3"]
  assert names(pools.spread([], dict.from_list([#("e0", 3)]))) == []
}

pub fn the_executor_with_the_fewest_open_scopes_comes_first_test() {
  let open = dict.from_list([#("e0", 2), #("e1", 0), #("e2", 1), #("e3", 1)])

  // An executor the counts do not name holds none, and equal counts keep the
  // pool's order.
  assert names(pools.spread(boxes(5), open)) == ["e1", "e4", "e2", "e3", "e0"]
}

pub fn a_pool_of_one_executor_is_unchanged_test() {
  assert names(pools.spread(boxes(1), dict.from_list([#("e0", 9)]))) == ["e0"]
}

pub fn a_full_or_down_executor_is_ordered_like_any_other_test() {
  // Nothing here says whether an executor is up or has room. The attach learns
  // that and moves on, so a pool whose members are all full still yields every
  // member, and the open ends with the reasons it always gave.
  let full = dict.from_list([#("e0", 16), #("e1", 16), #("e2", 16)])

  assert names(pools.spread(boxes(3), full)) == ["e0", "e1", "e2"]
}

pub fn eight_sessions_placed_in_turn_fill_the_pool_evenly_test() {
  // Place each session on the first candidate, as the open does when the
  // executors have room, and count it before placing the next.
  let placed =
    list.repeat(Nil, 8)
    |> list.fold(dict.new(), fn(open, _session) {
      let assert [first, ..] = pools.spread(boxes(4), open)
      dict.upsert(open, first.name, fn(held) { option.unwrap(held, 0) + 1 })
    })

  assert list.sort(dict.values(placed), int.compare) == [2, 2, 2, 2]
}

// The seed the spreading properties are drawn from, and how many cases each
// checks. The seed is fixed so that a red run is the same red run everywhere.
const spread_seed = 1171

const spread_cases = 200

// A pool of up to six executors and the open scopes held on each, drawn
// together so that a shrink shortens the pool and lowers the counts at once.
fn pool_and_counts() -> qcheck.Generator(#(Int, List(Int))) {
  qcheck.tuple2(
    qcheck.bounded_int(0, 6),
    qcheck.fixed_length_list_from(qcheck.bounded_int(0, 3), 6),
  )
}

fn spread_property(
  check: fn(List(executors.Executor), dict.Dict(String, Int)) -> Nil,
) -> Nil {
  qcheck.default_config()
  |> qcheck.with_test_count(spread_cases)
  |> qcheck.with_seed(qcheck.seed(spread_seed))
  |> qcheck.run(pool_and_counts(), fn(drawn) {
    let #(size, counts) = drawn
    let open =
      list.index_map(counts, fn(held, number) {
        #("e" <> int.to_string(number), held)
      })
      |> dict.from_list
    check(boxes(size), open)
  })
}

fn held_by(
  found: List(executors.Executor),
  open: dict.Dict(String, Int),
) -> List(Int) {
  list.map(found, fn(executor) {
    let assert Ok(held) = dict.get(open, executor.name)
    held
  })
}

pub fn spreading_only_reorders_the_candidates_test() {
  spread_property(fn(pool, open) {
    let found = pools.spread(pool, open)

    assert list.sort(names(found), string.compare)
      == list.sort(names(pool), string.compare)
  })
}

pub fn the_counts_never_decrease_along_the_result_test() {
  spread_property(fn(pool, open) {
    let held = held_by(pools.spread(pool, open), open)

    assert held == list.sort(held, int.compare)
  })
}

pub fn executors_with_equal_counts_keep_the_pools_order_test() {
  spread_property(fn(pool, open) {
    let found = pools.spread(pool, open)

    // For every count, the executors holding it appear in their input order.
    list.each([0, 1, 2, 3], fn(level) {
      let at_level = fn(each: executors.Executor) {
        dict.get(open, each.name) == Ok(level)
      }

      assert names(list.filter(found, at_level))
        == names(list.filter(pool, at_level))
    })
  })
}

pub fn a_pool_with_equal_counts_is_never_reordered_test() {
  spread_property(fn(pool, open) {
    let flat = dict.map_values(open, fn(_name, _held) { 1 })

    assert names(pools.spread(pool, flat)) == names(pool)
  })
}
