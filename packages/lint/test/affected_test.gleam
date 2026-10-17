//// The affected-gate selector (`lint/affected`, `lint/affected_graph`): the
//// cases `scripts/test_affected.py` held, plus properties over generated
//// graphs.
////
//// Two kinds of graph are used. The *real* graph is read from the
//// `gleam.toml` files of the checkout under test, so the expectations about
//// `tui`, `session_view` and the daemon are about the edges the tree
//// declares today; a test that fails after a manifest edit is reporting a
//// changed closure, which is what the selector exists to follow. The *mini*
//// tree is built in memory from manifest text and a table of file contents,
//// so the cases that depend on what a test reads (the sandbox helper, a
//// docs example) do not depend on what the checkout tracks.
////
//// The properties run over graphs drawn from a qcheck generator with a fixed
//// seed. Packages are numbered, and each ordered pair is an edge of one of
//// three kinds, so a graph shrinks toward fewer edges and a changed set
//// toward fewer packages.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lint/affected.{Affected, Full}
import lint/affected_graph.{type Graph, Entry, Graph}
import qcheck
import simplifile

// --- graphs -----------------------------------------------------------------

/// The graph of this checkout, from its manifests alone. Reads are empty
/// because they depend on the tracked files, which the mini tree supplies.
fn real_graph() -> Graph {
  let assert Ok(patterns) = affected_graph.patterns()
    as "the two path-literal patterns are constants"
  let assert Ok(names) = simplifile.read_directory("../../packages")
    as "the tests run from packages/lint"
  let entries =
    names
    |> list.filter(fn(name) {
      simplifile.is_directory("../../packages/" <> name) |> result.unwrap(False)
    })
    |> list.map(fn(name) {
      Entry(
        name:,
        manifest: simplifile.read("../../packages/" <> name <> "/gleam.toml")
          |> option.from_result,
      )
    })
  let assert Ok(graph) =
    affected_graph.build_graph(patterns, entries, [], fn(_) { Error(Nil) })
    as "the checkout's manifests parse"
  graph
}

/// A manifest with the given regular and dev path dependencies.
fn manifest(deps: List(String), dev: List(String)) -> String {
  let table = fn(names) {
    names
    |> list.map(fn(name) { name <> " = { path = \"../" <> name <> "\" }" })
    |> string.join("\n")
  }
  "name = \"x\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0\"\n"
  <> table(deps)
  <> "\n\n[dev_dependencies]\ngleeunit = \">= 1.0.0\"\n"
  <> table(dev)
  <> "\n"
}

/// A small repository: `core` under everything, two hosts over
/// `session_view`, a `client` that takes `tui` as a dev dependency, a
/// `conformance` over `client`, and three packages whose tests read files
/// outside themselves.
fn mini_graph() -> Graph {
  let assert Ok(patterns) = affected_graph.patterns()
    as "the two path-literal patterns are constants"
  let entries = [
    Entry("core", Some(manifest([], []))),
    Entry("session_view", Some(manifest(["core"], []))),
    Entry("tui", Some(manifest(["core", "session_view"], []))),
    Entry("web_view", Some(manifest(["session_view"], []))),
    Entry("client", Some(manifest(["core", "session_view"], ["tui"]))),
    Entry("conformance", Some(manifest(["client"], []))),
    Entry("broker", Some(manifest(["core"], []))),
    Entry("codemode", Some(manifest(["core"], []))),
    Entry("lint", Some(manifest([], []))),
    Entry("cap", Some(manifest([], []))),
    Entry("telemetry", Some(manifest([], []))),
    Entry("sandbox", None),
  ]
  let files = [
    #(
      "packages/broker/test/helper_test.gleam",
      "const helper = \"/../sandbox/loom-exec\"",
    ),
    #(
      "packages/codemode/test/example_test.gleam",
      "const example = \"../../docs/examples/stale_symbol_sweep.gleam\"",
    ),
    #(
      "packages/core/test/fixtures_test.gleam",
      "const fixtures = \"../../protocol/msgpack-fixtures/\"",
    ),
    #(
      "packages/lint/test/escape_test.gleam",
      "const escape = \"../etc/passwd\" <> \"../../bin/output\"",
    ),
    #(
      "packages/core/test/rooted_test.gleam",
      "const tracked = repo <> \"/docs/examples/strand_map.gleam\"",
    ),
  ]
  let tracked =
    list.flatten([
      list.map(files, fn(file) { file.0 }),
      [
        "docs/next.md",
        "docs/examples/stale_symbol_sweep.gleam",
        "docs/examples/strand_map.gleam",
        "protocol/msgpack-fixtures/bin-empty.bin",
        "packages/sandbox/loom-exec",
        "packages/sandbox/internal/policy/policy.go",
      ],
    ])
  let contents = dict.from_list(files)
  let assert Ok(graph) =
    affected_graph.build_graph(patterns, entries, tracked, fn(path) {
      dict.get(contents, path)
    })
    as "the mini tree's manifests parse"
  graph
}

fn packages_of(paths: List(String), graph: Graph) -> Set(String) {
  affected.select(paths, graph).packages |> dict.keys |> set.from_list
}

fn names(packages: List(String)) -> Set(String) {
  set.from_list(packages)
}

// --- the real graph ----------------------------------------------------------

pub fn docs_only_runs_static_gates_test() {
  let selection =
    affected.select(
      [
        "docs/next.md",
        "README.md",
        "protocol-change/001-x.md",
        "packages/tui/CLAUDE.md",
      ],
      real_graph(),
    )
  assert selection.mode == Affected
  assert selection.packages == dict.new()
  assert selection.gates == []
  assert selection.signoff == []
  assert affected.lanes(selection)
    == [affected.Lane("static", ["make", ..affected.static_gates])]
  assert affected.prep(selection) == []
}

pub fn tui_selects_its_dev_dependents_and_stops_test() {
  let selection = affected.select(["packages/tui/src/tui.gleam"], real_graph())
  assert selection.mode == Affected

  // `client` takes `tui` as a dev dependency; `conformance` depends on
  // `client` but never compiles `client`'s tests, so it is not reached.
  assert set.from_list(dict.keys(selection.packages))
    == names(["tui", "client"])
  assert dict.get(selection.packages, "client") == Ok("dev-depends on tui")
  assert selection.signoff == []
  assert list.drop(affected.lanes(selection), 1)
    == [affected.Lane("client", ["bash", "scripts/check.sh", "client", "tui"])]

  // The client's code-mode fixtures need the seed, and both packages'
  // shipped fixtures need `bin/loomd`.
  assert affected.prep(selection)
    == ["codemode-seed", "binaries", "server-shipment"]
}

pub fn session_view_reaches_both_hosts_test() {
  assert packages_of(
      ["packages/session_view/src/session_view/inbox.gleam"],
      real_graph(),
    )
    == names(["session_view", "tui", "web_view", "client", "conformance"])
}

pub fn a_leaf_change_selects_only_itself_test() {
  let selection =
    affected.select(["packages/lint/src/lint/rule.gleam"], real_graph())
  assert selection.mode == Affected
  assert set.from_list(dict.keys(selection.packages)) == names(["lint"])
  assert affected.prep(selection) == ["binaries"]
  assert list.drop(affected.lanes(selection), 1)
    == [affected.Lane("fast", ["bash", "scripts/check.sh", "lint"])]
}

pub fn a_core_change_escalates_to_the_full_check_test() {
  let selection =
    affected.select(["packages/core/src/core/json.gleam"], real_graph())
  assert selection.mode == Full
  let assert [reason, ..] = selection.reasons
  assert string.contains(reason, "Gleam packages are affected")
  assert list.contains(selection.signoff, "the full check was selected")
  assert list.last(affected.lanes(selection))
    == Ok(affected.Lane("full", ["bash", "scripts/check.sh"]))
}

pub fn a_makefile_change_escalates_to_the_full_check_test() {
  let selection = affected.select(["Makefile"], real_graph())
  assert selection.mode == Full
  assert selection.reasons == ["Makefile is build or CI machinery"]
}

pub fn machinery_manifests_and_unknown_paths_escalate_test() {
  let graph = real_graph()
  list.each(
    [
      "scripts/check.sh",
      ".github/workflows/ci.yml",
      "Dockerfile",
      "packages/tui/gleam.toml",
      "packages/tui/manifest.toml",
      "protocol/msgpack-fixtures/bin-empty.bin",
      "unheard-of/file",
      "",
    ],
    fn(path) {
      assert affected.select([path], graph).mode == Full
    },
  )
}

pub fn a_client_change_keeps_the_signoff_test() {
  let selection =
    affected.select(["packages/client/src/client.gleam"], real_graph())
  assert set.from_list(dict.keys(selection.packages))
    == names(["client", "conformance"])
  assert selection.signoff
    == ["touches the daemon (packages/client, which loomd is built from)"]
}

pub fn the_daemon_is_what_loomd_is_built_from_test() {
  let graph = real_graph()

  // `client`'s `[dependencies]` closure, less the two view packages the
  // owner exempted.
  assert affected.daemon_packages(graph)
    == names([
      "client", "host", "core", "storage", "session", "machine", "prompt",
      "events", "runtime", "broker", "provider", "tools", "codemode", "mcp",
      "lsp", "telemetry",
    ])
  list.each(
    [
      "runtime", "session", "storage", "events", "broker", "provider", "mcp",
      "lsp", "host", "tools",
    ],
    fn(package) {
      let selection =
        affected.select(["packages/" <> package <> "/src/x.gleam"], graph)
      assert list.any(selection.signoff, string.contains(
        _,
        "touches the daemon",
      ))
    },
  )
  list.each(
    [
      "packages/tui/src/x.gleam",
      "packages/session_view/src/session_view/x.gleam",
      "packages/web_view/src/x.gleam", "packages/web_client/src/x.gleam",
      "packages/lint/src/x.gleam", "packages/runtime/CLAUDE.md", "docs/next.md",
    ],
    fn(path) {
      assert affected.select([path], graph).signoff == []
    },
  )
}

pub fn the_session_view_wire_files_keep_the_signoff_test() {
  let selection =
    affected.select(
      ["packages/session_view/src/session_view/session_wire.gleam"],
      real_graph(),
    )
  assert selection.signoff == ["touches the client wire codec"]
}

pub fn a_model_change_selects_the_model_check_test() {
  let selection =
    affected.select(
      ["protocol/models/terminal-attachment/PSrc/Channel.p"],
      real_graph(),
    )
  assert selection.packages == dict.new()
  assert selection.gates == [#(affected.ModelCheck, "protocol/models/ changed")]
  assert affected.prep(selection) == []
}

/// `scripts/check.sh` runs packages in its own order and `check_order` is a
/// copy of it. A package missing from the copy is reported but never gets a
/// lane, so the omission would turn a selected package into a silent skip.
pub fn every_package_directory_has_a_place_in_the_check_order_test() {
  let graph = real_graph()
  list.each(graph.packages, fn(package) {
    assert list.contains(affected.check_order, package)
  })
}

// --- the mini tree: what tests read ------------------------------------------

pub fn the_sandbox_selects_the_real_helper_suites_and_the_signoff_test() {
  let selection =
    affected.select(
      ["packages/sandbox/internal/policy/policy.go"],
      mini_graph(),
    )
  assert selection.mode == Affected
  assert set.from_list(dict.keys(selection.packages))
    == names(["sandbox", "broker"])
  assert list.contains(selection.signoff, "touches the sandbox helper")

  // The self-test runs the helper `binaries` built rather than rebuilding it
  // beside the package lanes.
  assert list.contains(
    affected.lanes(selection),
    affected.Lane("selftest", ["./packages/sandbox/loom-exec", "--self-test"]),
  )
}

pub fn an_example_read_by_a_test_selects_its_reader_test() {
  let selection =
    affected.select(["docs/examples/stale_symbol_sweep.gleam"], mini_graph())
  assert set.from_list(dict.keys(selection.packages)) == names(["codemode"])
  assert dict.get(selection.packages, "codemode")
    == Ok(
      "reads docs/examples/stale_symbol_sweep.gleam (\"../../docs/examples/stale_symbol_sweep.gleam\")",
    )
}

pub fn a_rooted_literal_counts_only_for_a_tracked_file_test() {
  let graph = mini_graph()
  assert packages_of(["docs/examples/strand_map.gleam"], graph)
    == names(["core"])
  assert packages_of(["etc/passwd"], graph) == set.new()
}

pub fn a_literal_that_escapes_the_repository_reads_nothing_test() {
  let reads = mini_graph().reads
  assert list.all(reads, fn(reading) {
    !string.contains(reading.prefix, "passwd")
    && !string.starts_with(reading.prefix, "..")
  })
}

/// `broker` both changed and reads the sandbox, and the closure's reason is
/// the one reported, since a package that changed is selected for that
/// first.
pub fn a_package_that_changed_keeps_changed_as_its_reason_test() {
  let selection =
    affected.select(
      ["packages/broker/src/x.gleam", "packages/sandbox/loom-exec"],
      mini_graph(),
    )
  assert dict.get(selection.packages, "broker") == Ok("changed")
}

pub fn the_report_for_one_change_is_exact_test() {
  let selection = affected.select(["packages/tui/src/tui.gleam"], mini_graph())
  assert affected.render(selection) == "mode affected
gate fmt-check  static: always runs over the whole tree
gate lint  static: always runs over the whole tree
gate doc-check  static: always runs over the whole tree
gate prelude-check  static: always runs over the whole tree
gate client-check  static: always runs over the whole tree
gate check-client  dev-depends on tui
gate check-tui  changed
signoff not-required  affected gates suffice with a dispositioned review"
  assert affected.render_lanes(selection)
    == "prep make codemode-seed binaries server-shipment
static make fmt-check lint doc-check prelude-check client-check
client bash scripts/check.sh client tui"
}

pub fn the_selection_does_not_depend_on_how_paths_are_listed_test() {
  let graph = mini_graph()
  let paths = [
    "packages/tui/src/a.gleam",
    "docs/examples/stale_symbol_sweep.gleam",
    "protocol/models/x.p",
    "packages/sandbox/internal/policy/policy.go",
  ]
  let forward = affected.select(paths, graph)
  assert forward == affected.select(list.reverse(paths), graph)
  assert forward == affected.select(list.append(paths, paths), graph)
}

// --- the manifest reader and the path helpers --------------------------------

pub fn both_dev_dependency_spellings_are_read_test() {
  let assert Ok(hyphen) =
    affected_graph.parse_manifest(
      "[dev-dependencies]\nlint = { path = \"../lint\" }\n",
    )
  let assert Ok(underscore) =
    affected_graph.parse_manifest(
      "[dev_dependencies]\ncap = { path = \"../cap\" }\n",
    )
  assert hyphen.dev == set.from_list(["lint"])
  assert underscore.dev == set.from_list(["cap"])
}

pub fn only_a_path_dependency_is_an_edge_test() {
  let assert Ok(parsed) =
    affected_graph.parse_manifest(
      "[dependencies]
core = { path = \"../core\" }
gleam_stdlib = \">= 1.0.0 and < 2.0.0\"
glance = { version = \">= 7.0.0\" }

[dependencies.tui]
path = \"../tui\"
",
    )
  assert parsed.deps == set.from_list(["core", "tui"])
  assert parsed.dev == set.new()
}

pub fn a_manifest_that_does_not_parse_is_an_error_test() {
  assert result.is_error(affected_graph.parse_manifest("[dependencies\nx ="))
}

pub fn normpath_collapses_the_way_posix_does_test() {
  assert affected_graph.normpath("packages/broker/../sandbox/x")
    == "packages/sandbox/x"
  assert affected_graph.normpath("packages/../../etc") == "../etc"
  assert affected_graph.normpath("a//b/./c") == "a/b/c"
  assert affected_graph.normpath("a/..") == "."
  assert affected_graph.normpath("../..") == "../.."
}

pub fn under_matches_whole_path_segments_test() {
  assert affected.under("docs/examples/a.gleam", "docs/examples")
  assert affected.under("docs/examples", "docs/examples/")
  assert !affected.under("docs/examplesX", "docs/examples")
}

// --- properties ---------------------------------------------------------------

/// The number of generated graphs each property is checked over, and the seed
/// they are drawn from. Both are shared, so a failure in one names a graph the
/// others were also run on.
const graph_count: Int = 300

const graph_seed: Int = 593

/// Every generated graph has this many packages, `p0` to `p7`.
const package_count: Int = 8

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(graph_count)
  |> qcheck.with_seed(qcheck.seed(graph_seed))
}

fn indexes() -> List(Int) {
  list.repeat(Nil, package_count) |> list.index_map(fn(_, index) { index })
}

fn package_name(index: Int) -> String {
  "p" <> string.inspect(index)
}

/// A graph over eight packages. Each ordered pair of distinct packages draws
/// one number: 0 and 1 are no edge, 2 a `[dependencies]` edge, 3 a dev edge.
/// The simplest graph, which shrinking moves toward, has no edges at all.
fn graphs() -> qcheck.Generator(Graph) {
  qcheck.fixed_length_list_from(
    qcheck.bounded_int(0, 3),
    package_count * package_count,
  )
  |> qcheck.map(graph_of)
}

fn graph_of(draws: List(Int)) -> Graph {
  let pairs =
    list.index_map(draws, fn(draw, position) {
      #(position / package_count, position % package_count, draw)
    })
    |> list.filter(fn(pair) { pair.0 != pair.1 })
  let edges = fn(kind) {
    indexes()
    |> list.map(fn(from) {
      let targets =
        pairs
        |> list.filter(fn(pair) { pair.0 == from && pair.2 == kind })
        |> list.map(fn(pair) { package_name(pair.1) })
      #(package_name(from), set.from_list(targets))
    })
    |> dict.from_list
  }
  let packages = list.map(indexes(), package_name)
  Graph(packages:, gleam: packages, deps: edges(2), dev: edges(3), reads: [])
}

/// A changed set, as a list in the order the changes were found. Order
/// matters to the reasons but not to the set of packages the properties
/// compare.
fn changes() -> qcheck.Generator(List(String)) {
  qcheck.generic_list(
    qcheck.bounded_int(0, package_count - 1),
    qcheck.bounded_int(0, package_count),
  )
  |> qcheck.map(fn(indexes) { indexes |> list.unique |> list.map(package_name) })
}

fn closure_of(changed: List(String), graph: Graph) -> Set(String) {
  affected.affected_closure(changed, graph) |> dict.keys |> set.from_list
}

/// The packages that build against `changed` through `[dependencies]` edges
/// alone, found the slow way: grow the set until a pass adds nothing.
fn regular_closure(changed: List(String), graph: Graph) -> Set(String) {
  let grown =
    list.fold(graph.gleam, set.from_list(changed), fn(found, other) {
      let needs = dict.get(graph.deps, other) |> result.unwrap(set.new())
      case set.is_disjoint(needs, found) {
        True -> found
        False -> set.insert(found, other)
      }
    })
  case set.size(grown) == set.size(set.from_list(changed)) {
    True -> grown
    False -> regular_closure(set.to_list(grown), graph)
  }
}

/// Growing the changed set never shrinks what is affected: whatever a
/// smaller change selects, a larger one selects too. A selection that
/// dropped a package because more changed would let a test go unrun exactly
/// when the change got bigger.
pub fn the_closure_is_monotone_in_the_changed_set_test() {
  qcheck.run(
    config(),
    qcheck.tuple3(graphs(), changes(), qcheck.bounded_int(0, package_count)),
    fn(case_) {
      let #(graph, larger, keep) = case_
      let smaller = list.take(larger, keep)
      assert set.is_subset(
        closure_of(smaller, graph),
        closure_of(larger, graph),
      )
    },
  )
}

/// A dev-dependency edge adds the package that declares it and goes no
/// further: Gleam compiles a package's dev dependencies only when it is the
/// root of the build, so a package that merely depends on a dev-dependent is
/// not affected through it. The affected set is exactly the regular closure
/// plus the packages that dev-depend on a member of it, computed here
/// independently of the selector's walk.
pub fn dev_dependency_edges_never_propagate_test() {
  qcheck.run(config(), qcheck.tuple2(graphs(), changes()), fn(case_) {
    let #(graph, changed) = case_
    let regular = regular_closure(changed, graph)
    let dev_dependents =
      list.filter(graph.gleam, fn(other) {
        let wanted = dict.get(graph.dev, other) |> result.unwrap(set.new())
        !set.is_disjoint(wanted, regular)
      })
    assert closure_of(changed, graph)
      == set.union(regular, set.from_list(dev_dependents))
  })
}

/// Every reason names a package that is itself selected, and `changed` is
/// the reason for exactly the packages that changed. A reason that named an
/// unselected package would send a reader after a cause that is not there.
pub fn every_reason_names_a_selected_package_test() {
  qcheck.run(config(), qcheck.tuple2(graphs(), changes()), fn(case_) {
    let #(graph, changed) = case_
    let closure = affected.affected_closure(changed, graph)
    dict.each(closure, fn(package, reason) {
      case reason {
        "changed" -> {
          assert list.contains(changed, package)
        }
        _ -> {
          let assert Ok(#(_, cause)) = string.split_once(reason, " on ")
            as "a reason is `depends on`, `dev-depends on` or `changed`"
          assert dict.has_key(closure, cause)
        }
      }
    })
  })
}
