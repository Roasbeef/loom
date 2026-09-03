//// The TCB freeze (#33), proved as a standing property of the tree.
////
//// Design §7's hard rule: "The trusted computing base is not
//// runtime-extensible. Storage, state machine, broker, sandbox drivers
//// never change at runtime. Self-improvement grows the tool and hook
//// surface only." Nothing in the tree crosses that line today, because
//// every extension body — tool and hook alike — runs in a jailed
//// satellite and reaches the harness only through the capability
//// channel. The freeze is therefore satisfied by construction, and the
//// danger is not that it is false but that it stops being true quietly:
//// one `path` dependency added to `packages/ext`, one import added to a
//// prelude module, one seam widened by a name that looks harmless.
////
//// So the freeze is written down as tests rather than as prose. #33 asks
//// for two mechanisms and says "both, not either"; both are here, and
//// both are phrased so that a future refactor which opens a path fails
//// rather than merely being unattested.
////
//// # Mechanism one: compile-time visibility
////
//// `packages/ext` is the package an extension's source compiles against.
//// It names exactly one loom package, `cap`; `cap` names exactly one,
//// `core`; and `core` names none. That chain is checked from the
//// `gleam.toml` files themselves, from `ext`'s resolved `manifest.toml`,
//// and from `codemode/seed`, which is the list of packages actually
//// vendored into the offline build root an extension is compiled in. No
//// module under `packages/ext/src` or `packages/cap/src` imports any
//// module of a TCB package, and that is checked by walking both source
//// trees at test time, so a new import fails here without anybody
//// remembering to update a list.
////
//// # Mechanism two: runtime name checks
////
//// Every extension body runs jailed today, so "runtime" means the seam a
//// body is *admitted* under. Vetting's allowlist is closed, and it is
//// disjoint from the module names the TCB packages ship — checked
//// against the trees rather than against a snapshot, again so that a new
//// TCB module is covered the day it lands. Both the jailed seam
//// (`policy.extension()`) and the resident seam (`policy.resident()`)
//// are held to it.
////
//// The resident seam is the seam a harness-resident hook body *would* be
//// judged under if a loader were ever built. There is none: #32 is
//// deferred, because a survey of the pi extension corpus found none that
//// needs in-VM residency, and what the vocabulary is missing is not a
//// tier. The seam exists so that the allowlist is frozen before a loader
//// can invent one, which is the moment somebody is most tempted to be
//// permissive.
////
//// # What the compiler emits, and why a loader could rest on it
////
//// A future loader's runtime half would check a compiled module's beam
//// import table before loading it. That check is only worth building if
//// the import table is the complete call graph, so the claim was
//// measured rather than assumed: `packages/ext` was built with the
//// toolchain and each `.beam` read with `beam_lib:chunks/2`.
////
//// - `ext@runtime.beam` imports `cap@report`, `cap@runtime`, `ext@hook`,
////   `gleam@json`, `gleam@list`, `gleam@result`, `gleam@string`, and
////   `erlang`.
//// - `ext.beam` imports `gleam@dynamic@decode`, `gleam@list`,
////   `gleam@result`, `gleam@string`, and `erlang`.
//// - `ext@hook.beam` imports `gleam@dynamic@decode`, `gleam@json`,
////   `gleam@result`, `erlang`, and `maps`.
////
//// Three things follow, and the third is the one a loader has to answer.
//// First, the table is a *subset* of the source imports: `ext@runtime`
//// imports `ext` in source and not in the table, because it uses only
//// that module's constructors and never calls into it. So an
//// import-table check can never over-report, and with FFI refused by
//// vetting and no dynamic module dispatch in Gleam — no `apply/3`, no
//// `Module:f()` — the table is the complete set of modules a body can
//// reach. Second, module names are the Gleam names with `/` rewritten to
//// `@`, so the check is over the same namespace vetting already reasons
//// about. Third, the compiler emits native Erlang modules that no
//// allowlist names: `erlang` and `maps` here, and `lists` in other
//// modules. A module-level check would therefore have to admit `erlang`,
//// which is `erlang:open_port/2` and every other escape hatch in one
//// name. **The check has to be per-MFA, not per-module.** The MFAs
//// actually emitted across `packages/ext`'s three source modules are
//// `erlang:element/2`, `erlang:get_module_info/1`,
//// `erlang:get_module_info/2` and `maps:to_list/1` — a small, boring set
//// that a loader can allowlist by triple. Recorded here because the
//// argument, not the number, is what #32 would inherit.

import codemode/seed
import codemode/vet.{type VetResult, ImportNotAllowed, NoForeignInterface}
import codemode/vet/package
import codemode/vet/policy
import gleam/dict
import gleam/list
import gleam/string
import simplifile
import tom

// --- What the freeze is about ----------------------------------------------

/// The packages that make up the trusted computing base: the durability
/// plane, the state machine, the broker and its sandbox drivers, the
/// session tree, and the harness-side halves of code mode and the client.
///
/// `core` is deliberately absent. It is the pure shared vocabulary —
/// msgpack, corruption reports, the domain types — with no I/O and no
/// process machinery, and `cap` depends on it precisely because a
/// satellite and the harness have to agree on the wire. A package that
/// can be linked into the jail is not part of the base being frozen.
const trusted_computing_base = [
  "storage", "broker", "runtime", "machine", "sandbox", "session", "codemode",
  "client", "provider", "tools",
]

/// The base's packages that ship Gleam, and so contribute module names an
/// import could name. Every entry of `trusted_computing_base` but
/// `sandbox`, which is the Go jail helper and has no `src/` at all — a
/// fact `the_sandbox_helper_ships_no_gleam_module_test` pins, so a day on
/// which it gains Gleam source fails here rather than quietly narrowing
/// the walk.
const gleam_trusted_packages = [
  "storage", "broker", "runtime", "machine", "session", "codemode", "client",
  "provider", "tools",
]

/// The loom packages an extension's build root may contain: the
/// capability prelude, the extension prelude, and the shared vocabulary
/// `cap` itself depends on. This is the whole of the compile-time
/// surface an extension author can name.
const extension_facing_packages = ["cap", "core", "ext"]

// --- Mechanism one: the package graph --------------------------------------

/// `packages/ext` names exactly one loom package, and it is `cap`.
///
/// This is the narrowest statement of the compile-time half: the package
/// an extension compiles against cannot see a TCB package because it does
/// not depend on one. Only `[dependencies]` is judged. An author's
/// `[dev_dependencies]` are their own business and reach no installed
/// tree, because `test/` is pruned before an extension is ever built
/// (`vet/package`), and `packages/ext`'s own dev dependencies exist to
/// test the prelude here rather than to ship with it.
pub fn the_extension_prelude_names_one_loom_dependency_test() {
  assert loom_dependencies_of("ext") == ["cap"]
}

/// And `cap` names exactly one, and it is `core`, which names none.
///
/// The chain matters more than either link. `packages/ext` naming only
/// `cap` would buy nothing if `cap` in turn reached the broker's own
/// modules, so the walk continues until it reaches a package with no
/// loom dependency at all.
pub fn the_capability_prelude_bottoms_out_in_the_vocabulary_test() {
  assert loom_dependencies_of("cap") == ["core"]
  assert loom_dependencies_of("core") == []
}

/// The resolved lock file agrees with the declarations.
///
/// `gleam.toml` is what an author writes; `manifest.toml` is what the
/// compiler resolved, transitive dependencies included. Checking both
/// closes the case where a dependency arrives through a package that
/// declared it rather than through `packages/ext` directly.
pub fn the_resolved_manifest_holds_no_trusted_package_test() {
  let local = local_packages_of_manifest("ext")
  assert list.all(local, fn(name) {
    list.contains(extension_facing_packages, name)
  })

  // Non-vacuous: the manifest really does resolve local packages, so an
  // empty answer would be a parse failure rather than a clean bill.
  assert list.contains(local, "cap")
}

/// The build root an extension is actually compiled in holds the same
/// three packages and no fourth.
///
/// `codemode/seed` is the offline seed the jailed toolchain builds
/// against: whatever is vendored there is what an extension's source can
/// resolve an import to, whatever any `gleam.toml` claims. So it is the
/// last word on the compile-time surface, and it is pinned as an exact
/// set rather than as a containment.
pub fn the_offline_build_root_vendors_three_packages_test() {
  let vendored = list.map(seed.default_vendored(), fn(pair) { pair.0 })
  assert list.sort(vendored, string.compare)
    == list.sort(extension_facing_packages, string.compare)
}

/// A third-party extension's own `gleam.toml` may name none of it.
///
/// The three checks above are about the packages loom ships. This one is
/// about the package an author ships: `vet/package` refuses an install
/// whose project file names a dependency the jail does not have, and the
/// allowed set has to stay clear of the base for the same reason the
/// prelude does.
pub fn an_extension_may_not_declare_a_trusted_dependency_test() {
  assert list.all(package.allowed_dependencies, fn(name) {
    !list.contains(trusted_computing_base, name)
  })
}

/// The sandbox drivers ship no Gleam module, so no import can name one.
///
/// `packages/sandbox` is the Go jail helper — §7 names the sandbox
/// drivers in the same breath as storage and the broker, and the reason
/// nothing imports them is stronger than an allowlist: there is no Gleam
/// module to import. That is a property of the tree rather than of a
/// list, so it is asserted rather than assumed, and the day it stops
/// being true this test says so and `gleam_trusted_packages` has to grow.
pub fn the_sandbox_helper_ships_no_gleam_module_test() {
  assert !directory_exists(repository_root() <> "/packages/sandbox/src")
  assert simplifile.is_file(repository_root() <> "/packages/sandbox/go.mod")
    == Ok(True)

  // And the split between the two lists is exactly that one package.
  let missing =
    list.filter(trusted_computing_base, fn(name) {
      !list.contains(gleam_trusted_packages, name)
    })
  assert missing == ["sandbox"]
}

/// No module of either prelude imports a module of the base.
///
/// The dependency graph above is a claim about packages; this is the
/// claim about source, and it is the one that survives a refactor. Both
/// trees are walked at test time, so a module added tomorrow is covered
/// tonight, and an import added to an existing module fails here rather
/// than passing because a list somewhere was not updated.
pub fn no_prelude_module_imports_the_trusted_computing_base_test() {
  let modules = trusted_modules()
  let imports = list.append(source_imports_of("ext"), source_imports_of("cap"))
  assert list.all(imports, fn(name) { !list.contains(modules, name) })

  // Non-vacuous on both sides: the walk found real imports and a real
  // base to compare them against.
  assert list.contains(imports, "cap/report")
  assert list.contains(modules, "runtime/writer")
  assert list.contains(modules, "storage/storage")
}

// --- Mechanism two: the seam a body is admitted under ----------------------

/// Neither seam admits a single module of the base.
///
/// Checked against the module names the TCB packages ship rather than
/// against a written list of forbidden names, so a new module under
/// `storage/` or `broker/` is covered the moment it is committed. The
/// jailed seam and the resident seam are both held to it: the jailed one
/// because it is what runs today, the resident one because it is what a
/// loader would start from.
pub fn no_seam_admits_a_module_of_the_base_test() {
  let modules = trusted_modules()
  let seams = [policy.extension(), policy.resident()]
  assert list.all(seams, fn(seam) {
    list.all(policy.allowed_imports(seam), fn(name) {
      !list.contains(modules, name)
    })
  })

  // The base is large enough for that to have meant something.
  assert list.length(modules) > 100
}

/// A body reaching into the base is refused under both seams, and the
/// refusal names the module it refused.
///
/// The disjointness above is a statement about two lists; this is the
/// same statement made about the code that consumes them, which is what
/// a reader actually cares about. Naming the module is part of the
/// contract: an author who cannot see which import was refused cannot
/// repair it.
pub fn a_body_reaching_into_the_base_is_refused_test() {
  let reaching = [
    #("runtime/writer", "import runtime/writer\npub fn run() { 1 }\n"),
    #("broker/broker", "import broker/broker\npub fn run() { 1 }\n"),
    #("gleam/erlang", "import gleam/erlang\npub fn run() { 1 }\n"),
    #("session/session", "import session/session\npub fn run() { 1 }\n"),
  ]
  assert list.all(reaching, fn(one) {
    list.all([policy.extension(), policy.resident()], fn(seam) {
      refused_naming(vet.vet(one.1, seam), ImportNotAllowed, one.0)
    })
  })
}

/// A body declaring foreign code is refused under both seams.
///
/// The import allowlist is only sound while `@external` is impossible:
/// one foreign declaration reaches anything the VM can reach, whatever
/// the import list says. This is vetting's own rule and not new here,
/// but the freeze rests on it, so it is asserted where the freeze is
/// argued rather than only where the lint is tested.
pub fn a_body_declaring_foreign_code_is_refused_test() {
  let source =
    "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n"
  assert list.all([policy.extension(), policy.resident()], fn(seam) {
    has_rule(vet.vet(source, seam), NoForeignInterface)
  })
}

/// The resident seam's allowlist, pinned as an exact set.
///
/// A containment test would pass while the seam grew, which is the whole
/// failure this file exists to catch, so the difference is taken in both
/// directions against a literal written out here. Changing the seam
/// means changing this literal, which is the point: the freeze is a
/// decision somebody has to make on purpose.
pub fn the_resident_allowlist_is_pinned_test() {
  let expected = [
    "ext", "ext/hook", "gleam/bit_array", "gleam/bool", "gleam/dict",
    "gleam/dynamic", "gleam/dynamic/decode", "gleam/float", "gleam/function",
    "gleam/int", "gleam/json", "gleam/list", "gleam/option", "gleam/order",
    "gleam/pair", "gleam/result", "gleam/set", "gleam/string",
    "gleam/string_tree", "gleam/uri",
  ]
  assert both_differences(policy.allowed_imports(policy.resident()), expected)
    == #([], [])
}

/// The jailed seam's allowlist, pinned the same way.
///
/// This is the seam every extension in the tree actually runs under, so
/// it is the one a widening would reach first. It differs from the
/// resident list by the capability modules and nothing else, which the
/// policy module's own tests assert as a relation; here the names are
/// simply written down.
pub fn the_extension_allowlist_is_pinned_test() {
  let expected = [
    "cap/actor", "cap/fs", "cap/git", "cap/kv", "cap/lsp", "cap/net", "cap/proc",
    "cap/report", "cap/schedule", "cap/task", "ext", "ext/hook",
    "gleam/bit_array", "gleam/bool", "gleam/dict", "gleam/dynamic",
    "gleam/dynamic/decode", "gleam/float", "gleam/function", "gleam/int",
    "gleam/json", "gleam/list", "gleam/option", "gleam/order", "gleam/pair",
    "gleam/result", "gleam/set", "gleam/string", "gleam/string_tree",
    "gleam/uri",
  ]
  assert both_differences(policy.allowed_imports(policy.extension()), expected)
    == #([], [])
}

// --- Reading the tree ------------------------------------------------------

/// The repository root, from the `packages/client` directory the test
/// runner starts in. The whole file is a claim about the tree, so the
/// tree is what it reads.
fn repository_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  here <> "/../.."
}

/// Every `.gleam` module name under a package's `src/`, as the name an
/// import would use: the path below `src/` with `.gleam` removed.
fn modules_of(package_name: String) -> List(String) {
  let root = repository_root() <> "/packages/" <> package_name <> "/src"
  let assert Ok(files) = simplifile.get_files(root)
    as { "package " <> package_name <> " must have a readable src/" }

  files
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.map(fn(path) {
    path
    |> string.replace(root <> "/", "")
    |> string.replace(".gleam", "")
  })
}

/// Every module name the trusted computing base ships, across all of its
/// packages. Derived from the tree so that a module added to the base is
/// covered without this file changing.
fn trusted_modules() -> List(String) {
  list.flat_map(gleam_trusted_packages, modules_of)
}

/// Every module name imported by any source file of a package.
///
/// A deliberately syntactic reading: a line beginning `import ` names a
/// module up to the first `.` or space, which is exactly Gleam's import
/// grammar and needs no parser. The prelude packages are small enough
/// that a reader can check this by eye, and a reading that erred would
/// err towards reporting *more* imports than exist, which fails closed.
fn source_imports_of(package_name: String) -> List(String) {
  let root = repository_root() <> "/packages/" <> package_name <> "/src"
  let assert Ok(files) = simplifile.get_files(root)
    as { "package " <> package_name <> " must have a readable src/" }

  files
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.flat_map(imports_in_file)
}

/// The module names imported by one source file.
fn imports_in_file(path: String) -> List(String) {
  let assert Ok(source) = simplifile.read(path)
    as { path <> " must be readable" }

  source
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(line, "import ") {
      True -> Ok(module_name_of_import(line))
      False -> Error(Nil)
    }
  })
}

/// The module name in an `import ...` line: the token after `import`, cut
/// at the first `.` so that an unqualified list (`import ext.{type Ctx}`)
/// and an alias (`import cap/fs as files`) both reduce to the module.
fn module_name_of_import(line: String) -> String {
  let rest = string.replace(line, "import ", "")
  case string.split(rest, " ") {
    [] -> ""
    [first, ..] ->
      case string.split(first, ".") {
        [] -> ""
        [name, ..] -> name
      }
  }
}

// --- Reading the project files ---------------------------------------------

/// The loom packages a package's `gleam.toml` names under
/// `[dependencies]`, sorted. A dependency is a loom package when
/// `packages/<name>` exists, so a package added to the tree is
/// classified without this file learning its name.
fn loom_dependencies_of(package_name: String) -> List(String) {
  let path = repository_root() <> "/packages/" <> package_name <> "/gleam.toml"
  let assert Ok(parsed) = tom.parse(read_file(path))
    as { path <> " must parse as TOML" }
  let assert Ok(dependencies) = tom.get_table(parsed, ["dependencies"])
    as { path <> " must declare dependencies" }

  dependencies
  |> dict.keys
  |> list.filter(is_loom_package)
  |> list.sort(string.compare)
}

/// Whether `name` is a package in this tree rather than a hex package.
fn is_loom_package(name: String) -> Bool {
  directory_exists(repository_root() <> "/packages/" <> name)
}

/// Whether a directory is present. An unreadable path is reported absent,
/// which is the fail-closed direction for every caller here: a package
/// that cannot be seen is not a dependency, and a `src/` that cannot be
/// seen is not a source of modules.
fn directory_exists(path: String) -> Bool {
  case simplifile.is_directory(path) {
    Ok(present) -> present
    Error(_unreadable) -> False
  }
}

/// The names of the path-sourced packages in a package's resolved
/// `manifest.toml`, sorted. These are the loom packages the compiler
/// actually linked, transitive ones included.
fn local_packages_of_manifest(package_name: String) -> List(String) {
  let path =
    repository_root() <> "/packages/" <> package_name <> "/manifest.toml"
  let assert Ok(parsed) = tom.parse(read_file(path))
    as { path <> " must parse as TOML" }
  let assert Ok(entries) = tom.get_array(parsed, ["packages"])
    as { path <> " must hold a packages array" }

  entries
  |> list.filter_map(local_package_name)
  |> list.sort(string.compare)
}

/// The name of one manifest entry, if that entry is a local package.
fn local_package_name(entry: tom.Toml) -> Result(String, Nil) {
  case entry {
    tom.InlineTable(fields) ->
      case dict.get(fields, "source"), dict.get(fields, "name") {
        Ok(tom.String("local")), Ok(tom.String(name)) -> Ok(name)
        _, _ -> Error(Nil)
      }
    _other -> Error(Nil)
  }
}

/// A file's contents, or a failure that names the file. Every path here
/// is a committed part of the tree, so an unreadable one is a broken
/// checkout rather than a condition to handle.
fn read_file(path: String) -> String {
  let assert Ok(contents) = simplifile.read(path)
    as { path <> " must be readable" }
  contents
}

// --- Assertions ------------------------------------------------------------

/// The two directions of a set difference: what the actual list holds and
/// the expected one does not, then the reverse. `#([], [])` is equality,
/// and a failure shows which way the set moved.
fn both_differences(
  actual: List(String),
  expected: List(String),
) -> #(List(String), List(String)) {
  let extra = list.filter(actual, fn(name) { !list.contains(expected, name) })
  let missing = list.filter(expected, fn(name) { !list.contains(actual, name) })
  #(list.sort(extra, string.compare), list.sort(missing, string.compare))
}

/// Whether a vet result was rejected for `rule`.
fn has_rule(result: VetResult, rule: vet.Rule) -> Bool {
  case result {
    vet.Passed(_) -> False
    vet.Rejected(rejections) ->
      list.any(rejections, fn(rejection) { rejection.rule == rule })
  }
}

/// Whether a vet result was rejected for `rule` with `needle` named in
/// the detail, which is what an author reads to repair the source.
fn refused_naming(result: VetResult, rule: vet.Rule, needle: String) -> Bool {
  case result {
    vet.Passed(_) -> False
    vet.Rejected(rejections) ->
      list.any(rejections, fn(rejection) {
        rejection.rule == rule && string.contains(rejection.detail, needle)
      })
  }
}
