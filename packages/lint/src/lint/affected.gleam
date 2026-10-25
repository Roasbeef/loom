//// Select the gates a change can affect.
////
//// The full gate (`make check`, and the signoff built from it) runs every
//// package's suite whatever a change touched. This module reads what a
//// change touched and decides the subset of gates that can observe it: the
//// packages whose build or tests include a changed file, plus a fixed set of
//// cheap whole-tree static gates. `scripts/check_affected.sh` runs the
//// subset and `make check-affected` is its entry point; `make affected`
//// prints the decision and its reasons.
////
//// # What stays outside
////
//// This module is pure. It sees a list of tracked paths, a list of changed
//// paths, the text of each `gleam.toml`, and a function that returns a
//// tracked file's text. Everything that touches git or the disk belongs to
//// the caller: `scripts/check_affected.sh` runs `git ls-files`,
//// `git merge-base` and `git diff` and hands the answers to
//// `lint/affected_cli`, which reads the files. That split is why the
//// dependency closure can be property-tested on graphs nobody wrote down.
////
//// # How a package becomes affected
////
//// Three ways, each derived from the tree rather than written down here:
////
//// 1. Its own files changed.
//// 2. It depends on an affected package. The edges are the path
////    dependencies in every `packages/*/gleam.toml`. A `[dependencies]`
////    edge is transitive: whatever builds against `session_view` builds
////    against `tui` if `tui` depends on it. A `[dev-dependencies]` edge is
////    not, because Gleam compiles a package's dev dependencies only when
////    that package is the root of the build: `client` takes `tui` as a dev
////    dependency, so a `tui` change affects `client`'s tests, but it does not
////    reach `conformance`, which depends on `client` and never compiles
////    `client`'s tests.
//// 3. Its sources or tests name a file outside the package by a relative
////    path literal, such as `"../../protocol/msgpack-fixtures/"` in `core`'s
////    tests or `"/../sandbox/loom-exec"` in the real-helper suites. Those are
////    read at test time rather than compiled, so the edge covers the package
////    itself and not its dependents.
////
//// # What the graph does not decide
////
//// Build and CI machinery (`scripts/`, the `Makefile`, `.github/`, the
//// image, and any package's `gleam.toml` or `manifest.toml`) can change what
//// every gate does, so it selects the full `make check`. So does a change
//// whose affected packages are more than half of the Gleam packages, since
//// the subset would then save little and `core` is the only package that
//// reaches that far today. A path this module does not recognise also
//// selects the full check: an unknown file is not evidence that nothing is
//// affected.
////
//// Separately from the gates, the selection says whether the change still
//// needs the full signoff before it merges. That is the owner's rule of
//// 2026-09-28 in docs/execution.md section 4: a change touching the daemon,
//// the sandbox, or the wire, or one crossing many packages, keeps the
//// signoff.
////
//// # Determinism
////
//// Every list this module walks is sorted first, so the same inputs give the
//// same bytes. Two answers depend on walk order and are fixed here: the
//// reason a package is selected (the first path, in sorted order, that
//// selects it) and the literal a read is reported with (the first one in
//// the first tracked file, in sorted order, that names it).

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lint/affected_graph.{type Graph}

/// The static gates are whole-tree and take about ten seconds together, so
/// they always run rather than being selected by their inputs. Tracking the
/// inputs of the prelude digest (`packages/cap`) and the web asset digest
/// (`packages/web_client` and the `web_view` sources its stylesheet scans)
/// would save two seconds and add a second copy of what those scripts
/// already know. `make lint` runs over every package, not only the affected
/// ones: its gating rules are per file, but a whole-tree run costs seconds
/// and needs no argument about which rules are cross-module.
pub const static_gates: List(String) = [
  "fmt-check", "lint", "doc-check", "prelude-check", "client-check",
]

/// The package order `scripts/check.sh` uses, so a lane runs its packages in
/// the order the full check does. A package missing here is reported by
/// `render` but gets no lane, so a new package must be added to this list and
/// to `scripts/check.sh` together.
pub const check_order: List(String) = [
  "host", "core", "storage", "session", "machine", "prompt", "statem",
  "statem_parallel", "evalstat", "session_view", "web_view", "web_client",
  "web_mermaid", "telemetry", "runtime", "provider", "broker", "executor", "mcp",
  "lsp", "tools", "cap", "ext", "codemode", "events", "harness", "client", "tui",
  "conformance", "eval", "lint", "sandbox",
]

/// Package lanes, taken from `scripts/signoff.sh` so that the packages which
/// run concurrently here are the ones already proven to run concurrently
/// there. Packages in no named lane go to `fast`. `client` and `tui` share a
/// lane in the signoff because the bootstrap fixtures follow them there;
/// keeping them together here costs nothing when only one is selected.
const lane_groups: List(#(String, List(String))) = [
  #("client", ["client", "tui"]),
  #("mid", ["runtime", "storage", "session", "events"]),
  #("conformance", ["conformance", "eval"]),
]

/// Machinery that can change what any gate does. A change here runs the full
/// check, because no smaller set of gates is known to observe it.
const escalate_prefixes: List(String) = ["scripts/", ".github/"]

const escalate_files: List(String) = ["Makefile", "Dockerfile", ".dockerignore"]

const escalate_package_files: List(String) = ["gleam.toml", "manifest.toml"]

/// The wire's golden msgpack fixtures. The Go sandbox's tests read them
/// through `filepath.Join`, which no literal scan sees, and they are the wire
/// contract, so a change here runs the full check.
const wire_prefix: String = "protocol/msgpack-fixtures/"

/// Prose and agent configuration: covered by the static gates alone.
const doc_prefixes: List(String) = [
  "docs/", "protocol-change/", "skills/", ".claude/",
]

const doc_root_files: List(String) = [".gitignore"]

/// The P protocol models, checked by `make model-check`.
const model_prefix: String = "protocol/models/"

/// The daemon, for the signoff rule, is the package `loomd` is exported from
/// (`make server-shipment` runs `gleam export erlang-shipment` in
/// `packages/client`) together with every package it reaches through
/// `[dependencies]` path edges, read from the graph. Two of those are exempt
/// by the owner's ruling of 2026-09-28: `session_view` and `web_view` are
/// the views the terminal and the browser drive, and a change to them is
/// judged by their own gates. The wire files inside `session_view` are still
/// listed in `signoff_prefixes`.
const daemon_root: String = "client"

const daemon_exempt: List(String) = ["session_view", "web_view"]

/// Other paths whose change keeps the full signoff even when the selected
/// gates pass: the kernel sandbox and its helper, and the wire the terminal
/// and the daemon speak. `core` holds the codecs; it is also a daemon
/// package, and a `core` change selects the full check anyway.
const signoff_prefixes: List(#(String, String)) = [
  #("packages/sandbox/", "the sandbox helper"),
  #("protocol/msgpack-fixtures/", "the wire's msgpack fixtures"),
  #(
    "packages/session_view/src/session_view/protocol.gleam",
    "the client wire protocol",
  ),
  #(
    "packages/session_view/src/session_view/session_wire.gleam",
    "the client wire codec",
  ),
]

/// More packages changed directly than this counts as crossing many.
const signoff_package_limit: Int = 2

/// Packages whose suites feature-detect a prerequisite and print SKIP
/// without it, mapped to the make targets that provide it, as
/// `scripts/signoff.sh`'s preparation provides them all. The code-mode seed
/// backs the code-mode suites and the client's live code-mode fixtures; the
/// server shipment is `bin/loomd`, which the client's shipped fixtures and
/// the tui's real-server lifecycle test run against.
const seed_packages: List(String) = ["codemode", "tools", "cap", "client"]

const shipment_packages: List(String) = ["client", "tui"]

/// Whether the full check runs or only the selected gates.
pub type Mode {
  Affected
  Full
}

/// A gate that is neither a package suite nor a static gate.
pub type Gate {
  /// The sandbox helper's `--self-test`.
  Selftest

  /// `make model-check`, the TLA+ and P protocol models.
  ModelCheck
}

/// What a change selects.
pub type Selection {
  Selection(
    mode: Mode,
    /// Why the full check was selected, one line per cause.
    reasons: List(String),
    /// Each selected package with the reason it was selected.
    packages: Dict(String, String),
    /// The non-package gates with their reasons.
    gates: List(#(Gate, String)),
    /// Why the change still needs the full signoff; empty when it does not.
    signoff: List(String),
  )
}

/// One lane to run: a name and the command words.
pub type Lane {
  Lane(name: String, words: List(String))
}

/// The kind of change a path is.
pub type Kind {
  /// Build or CI machinery, which selects the full check.
  Machinery

  /// A package's `gleam.toml` or `manifest.toml`, also the full check.
  PackageManifest

  /// The golden msgpack fixtures, also the full check.
  Wire

  /// One of a package's own files.
  Package

  /// Markdown at a package's root, which no build reads.
  PackageDoc

  /// A P protocol model.
  Model

  /// Prose and agent configuration.
  Doc

  /// A file outside `packages/` that some package's tests read, and nothing
  /// more.
  ReadByTest

  /// A path nothing classifies.
  Unknown
}

/// Decide the gates for a list of changed repository paths.
///
/// Paths are visited in sorted order, once each, so the reasons come out the
/// same however the caller listed them.
///
/// ## Examples
///
/// ```gleam
/// select(["docs/next.md"], graph).packages  // -> dict.new()
/// select(["Makefile"], graph).mode          // -> Full
/// ```
pub fn select(paths: List(String), graph: Graph) -> Selection {
  let daemon = daemon_packages(graph)
  let visited =
    paths
    |> list.sort(string.compare)
    |> list.unique
    |> list.fold(start(), fn(acc, path) { visit(acc, path, graph, daemon) })
  finish(visited, graph)
}

/// Return every package whose build includes a changed package.
///
/// Regular dependency edges are followed transitively; a dev-dependency edge
/// adds the package that declares it and stops there. `changed` is in the
/// order the changes were found, which decides which dependency a package is
/// reported as depending on when it depends on several.
///
/// ## Examples
///
/// ```gleam
/// affected_closure(["tui"], graph)
/// // -> {"tui": "changed", "client": "dev-depends on tui"}
/// ```
pub fn affected_closure(
  changed: List(String),
  graph: Graph,
) -> Dict(String, String) {
  let selected =
    changed
    |> list.map(fn(package) { #(package, "changed") })
    |> dict.from_list

  // The frontier is a stack whose head is the most recently found package,
  // which is the order the reasons were first written down in.
  let regular = spread(list.reverse(changed), selected, graph)
  list.fold(graph.gleam, regular, fn(found, other) {
    add_dev_edge(found, regular, other, graph)
  })
}

/// Return the packages the daemon is built from, less the exempt views.
///
/// ## Examples
///
/// ```gleam
/// set.to_list(daemon_packages(graph))
/// // -> ["broker", "client", "codemode", "core", "events", "host", ...]
/// ```
pub fn daemon_packages(graph: Graph) -> Set(String) {
  // Resolve daemon roots to compute reachable packages.
  let roots = case list.contains(graph.gleam, daemon_root) {
    True -> [daemon_root]
    False -> []
  }

  let reached = reach(roots, set.new(), graph)
  set.drop(reached, daemon_exempt)
}

/// Name the kind of change a path is.
///
/// ## Examples
///
/// ```gleam
/// classify("packages/tui/src/tui.gleam", graph)  // -> Package
/// classify("packages/tui/CLAUDE.md", graph)      // -> PackageDoc
/// classify("Makefile", graph)                    // -> Machinery
/// ```
pub fn classify(path: String, graph: Graph) -> Kind {
  case is_machinery(path) {
    True -> Machinery
    False -> classify_beyond_machinery(path, string.split(path, "/"), graph)
  }
}

/// Return the make targets to build before the lanes start.
///
/// `binaries` builds the helper that the real-helper suites and the self-test
/// run, and the tui shipment; `make check-<pkg>` depends on it. The full
/// check prepares everything, as the signoff does.
///
/// ## Examples
///
/// ```gleam
/// prep(select(["packages/tui/src/tui.gleam"], graph))
/// // -> ["binaries", "server-shipment"]
/// ```
pub fn prep(selection: Selection) -> List(String) {
  // Select prep targets depending on full or affected mode.
  case selection.mode {
    Full -> ["codemode-seed", "binaries", "server-shipment"]
    Affected -> {
      let selected = dict.keys(selection.packages)
      let wants_selftest =
        list.any(selection.gates, fn(gate) { gate.0 == Selftest })
      [
        #("codemode-seed", list.any(selected, list.contains(seed_packages, _))),
        #("binaries", selected != [] || wants_selftest),
        #(
          "server-shipment",
          list.any(selected, list.contains(shipment_packages, _)),
        ),
      ]
      |> list.filter_map(fn(target) {
        case target.1 {
          True -> Ok(target.0)
          False -> Error(Nil)
        }
      })
    }
  }
}

/// Return the lanes to run, in order.
///
/// The static lane comes first and `scripts/check_affected.sh` runs it alone
/// before the others, because `make lint` builds `packages/lint` and a
/// `lint` package lane would build the same tree at the same time.
///
/// ## Examples
///
/// ```gleam
/// lanes(select(["docs/next.md"], graph))
/// // -> [Lane("static", ["make", "fmt-check", ...])]
/// ```
pub fn lanes(selection: Selection) -> List(Lane) {
  let static_lane = Lane("static", ["make", ..static_gates])
  let gate_lanes =
    list.map(selection.gates, fn(gate) {
      Lane(gate_name(gate.0), gate_command(gate.0))
    })

  // Resolve package execution lanes depending on full or affected mode.
  let package_lanes = case selection.mode {
    Full -> [Lane("full", ["bash", "scripts/check.sh"])]
    Affected -> grouped_lanes(selection)
  }

  list.flatten([[static_lane], gate_lanes, package_lanes])
}

/// Render the plan `scripts/check_affected.sh` runs: a `prep` line when
/// there is something to build, then one line per lane.
///
/// ## Examples
///
/// ```gleam
/// render_lanes(select(["docs/next.md"], graph))
/// // -> "static make fmt-check lint doc-check prelude-check client-check"
/// ```
pub fn render_lanes(selection: Selection) -> String {
  // Format prep command line if prep targets were selected.
  let prep_lines = case prep(selection) {
    [] -> []
    targets -> [string.join(["prep", "make", ..targets], " ")]
  }

  let lane_lines =
    list.map(lanes(selection), fn(lane) {
      string.join([lane.name, ..lane.words], " ")
    })
  string.join(list.append(prep_lines, lane_lines), "\n")
}

/// Render the human-readable report: one line per gate with its reason.
///
/// Each line is `<kind> <name>  <reason>`, where kind is `mode`, `gate` or
/// `signoff`, so the output is both readable and parseable by field.
///
/// ## Examples
///
/// ```gleam
/// render(select(["Makefile"], graph))
/// // -> "mode full\nescalate  Makefile is build or CI machinery\n..."
/// ```
pub fn render(selection: Selection) -> String {
  let mode_line = "mode " <> mode_name(selection.mode)
  let escalations =
    list.map(selection.reasons, fn(reason) { "escalate  " <> reason })
  let statics =
    list.map(static_gates, fn(gate) {
      "gate " <> gate <> "  static: always runs over the whole tree"
    })
  let others =
    list.map(selection.gates, fn(gate) {
      "gate " <> gate_name(gate.0) <> "  " <> gate.1
    })

  // Format signoff requirement lines.
  let signoff = case selection.signoff {
    [] -> [
      "signoff not-required  affected gates suffice with a dispositioned review",
    ]
    reasons -> list.map(reasons, fn(reason) { "signoff required  " <> reason })
  }

  [[mode_line], escalations, statics, others, check_lines(selection), signoff]
  |> list.flatten
  |> string.join("\n")
}

/// The name a mode prints as.
pub fn mode_name(mode: Mode) -> String {
  case mode {
    Affected -> "affected"
    Full -> "full"
  }
}

/// The name a non-package gate prints as.
pub fn gate_name(gate: Gate) -> String {
  case gate {
    Selftest -> "selftest"
    ModelCheck -> "model-check"
  }
}

/// The command for each non-package gate. The self-test runs the helper
/// `binaries` already built, as `scripts/signoff.sh`'s enforcement lane does;
/// `make selftest` would rebuild it while the package lanes run it.
fn gate_command(gate: Gate) -> List(String) {
  case gate {
    Selftest -> ["./packages/sandbox/loom-exec", "--self-test"]
    ModelCheck -> ["make", "model-check"]
  }
}

// What the walk over changed paths has decided so far. Lists are kept in the
// order their entries were found, which is the order the report prints them.
type Acc {
  Acc(
    mode: Mode,
    reasons: List(String),
    gates: List(#(Gate, String)),
    changed: List(String),
    readers: List(#(String, String)),
    signoff: List(String),
  )
}

/// Returns the initial empty accumulator for tracking affected paths.
fn start() -> Acc {
  Acc(
    mode: Affected,
    reasons: [],
    gates: [],
    changed: [],
    readers: [],
    signoff: [],
  )
}

// One changed path: what its kind decides, then what it adds to the signoff
// and to the readers. Package Markdown is read by no build, so neither the
// signoff rule nor a test that reads the package's files applies to it.
/// Processes a changed path and updates signoff and reader notes.
fn visit(acc: Acc, path: String, graph: Graph, daemon: Set(String)) -> Acc {
  let kind = classify(path, graph)
  let decided = decide(acc, kind, path)

  // Update signoff and reader records for non-documentation kinds.
  case kind {
    PackageDoc -> decided
    Machinery
    | PackageManifest
    | Wire
    | Package
    | Model
    | Doc
    | ReadByTest
    | Unknown ->
      decided
      |> note_signoff(kind, path, daemon)
      |> note_readers(path, graph)
  }
}

/// Updates accumulator mode or changed package sets based on path kind.
fn decide(acc: Acc, kind: Kind, path: String) -> Acc {
  case kind {
    Machinery -> escalate(acc, path <> " is build or CI machinery")
    Wire ->
      escalate(acc, path <> " is a wire fixture the Go sandbox also reads")
    PackageManifest -> escalate(acc, path <> " changes the dependency graph")
    Unknown -> escalate(acc, path <> " is not a path this script classifies")
    Package -> Acc(..acc, changed: add_once(acc.changed, package_of(path)))
    Model -> add_gate(acc, ModelCheck, model_prefix <> " changed")
    PackageDoc | Doc | ReadByTest -> acc
  }
}

fn escalate(acc: Acc, reason: String) -> Acc {
  Acc(..acc, mode: Full, reasons: list.append(acc.reasons, [reason]))
}

fn add_gate(acc: Acc, gate: Gate, reason: String) -> Acc {
  case list.any(acc.gates, fn(known) { known.0 == gate }) {
    True -> acc
    False -> Acc(..acc, gates: list.append(acc.gates, [#(gate, reason)]))
  }
}

fn add_once(items: List(String), item: String) -> List(String) {
  case list.contains(items, item) {
    True -> items
    False -> list.append(items, [item])
  }
}

fn package_of(path: String) -> String {
  case string.split(path, "/") {
    [_, package, ..] -> package
    [_] | [] -> ""
  }
}

// The signoff notes a path earns, each recorded once: the fixed prefixes
// first, then the daemon rule for a package or manifest of a daemon package.
/// Records signoff requirements based on touched sensitive path prefixes or daemon components.
fn note_signoff(
  acc: Acc,
  kind: Kind,
  path: String,
  daemon: Set(String),
) -> Acc {
  let prefixed =
    signoff_prefixes
    |> list.filter(fn(entry) { under(path, entry.0) })
    |> list.map(fn(entry) { "touches " <> entry.1 })
  let package = package_of(path)

  // Note whether the changed package is part of the daemon build.
  let daemon_note = case kind, set.contains(daemon, package) {
    Package, True | PackageManifest, True -> [
      "touches the daemon (packages/"
      <> package
      <> ", which loomd is built from)",
    ]
    _, _ -> []
  }

  Acc(
    ..acc,
    signoff: list.fold(
      list.append(prefixed, daemon_note),
      acc.signoff,
      add_once,
    ),
  )
}

// A file some package's tests read by relative path selects that package,
// whatever kind of file it is otherwise; `docs/examples` is prose and a
// codemode fixture at once. The first reading to name a reader wins.
/// Records packages that read the changed file in tests or fixtures.
fn note_readers(acc: Acc, path: String, graph: Graph) -> Acc {
  let found =
    graph.reads
    |> list.filter(fn(reading) { under(path, reading.prefix) })
    |> list.flat_map(fn(reading) {
      reading.readers
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(reader) {
        #(reader.0, "reads " <> reading.prefix <> " (\"" <> reader.1 <> "\")")
      })
    })
  Acc(
    ..acc,
    readers: list.fold(found, acc.readers, fn(known, reader) {
      case list.key_find(known, reader.0) {
        Ok(_) -> known
        Error(Nil) -> list.append(known, [reader])
      }
    }),
  )
}

// The dependency closure's reasons win over a read, since a package that
// changed or builds against a change is selected for that first. Then the
// escalations that depend on the final set, and the signoff.
/// Finalizes package selection computing closure, self-test gates, and signoffs.
fn finish(acc: Acc, graph: Graph) -> Selection {
  let packages =
    dict.merge(
      dict.from_list(acc.readers),
      affected_closure(acc.changed, graph),
    )

  // The sandbox self-test is a gate of its own, so it is added before the
  // width rule can turn the whole selection into the full check.
  let with_selftest = case dict.has_key(packages, "sandbox") {
    True ->
      add_gate(
        acc,
        Selftest,
        "the sandbox helper changed; probe its enforcement layers",
      )
    False -> acc
  }

  let escalated = escalate_if_wide(with_selftest, packages, graph)
  let signoff = signoff_reasons(escalated, acc.changed)
  Selection(
    mode: escalated.mode,
    reasons: escalated.reasons,
    packages:,
    gates: escalated.gates,
    signoff:,
  )
}

// More than half of the Gleam packages is where a subset saves little.
/// Escalates to full check mode if more than half of all Gleam packages are affected.
fn escalate_if_wide(
  acc: Acc,
  packages: Dict(String, String),
  graph: Graph,
) -> Acc {
  let reached = list.count(dict.keys(packages), list.contains(graph.gleam, _))
  let total = list.length(graph.gleam)

  // Check whether affected packages exceed half of total packages.
  case 2 * reached > total {
    True ->
      escalate(
        acc,
        int_text(reached)
          <> " of "
          <> int_text(total)
          <> " Gleam packages are affected",
      )
    False -> acc
  }
}

// The reasons the change still needs the full signoff: the ones the paths
// earned, a change that crosses many packages, and the full check itself,
// which is always listed first.
/// Determines signoff requirement explanations for direct package changes or full check mode.
fn signoff_reasons(acc: Acc, changed: List(String)) -> List(String) {
  let directly = list.length(changed)

  // Note if directly changed packages exceed threshold.
  let crossing = case directly > signoff_package_limit {
    True ->
      list.append(acc.signoff, [
        "changes " <> int_text(directly) <> " packages directly",
      ])
    False -> acc.signoff
  }

  // Prepend notice if full check mode was selected.
  case acc.mode {
    Full -> ["the full check was selected", ..crossing]
    Affected -> crossing
  }
}

fn int_text(value: Int) -> String {
  string.inspect(value)
}

// The kinds that need the path's position in the tree, once machinery is
// ruled out.
/// Classifies path kinds for non-machinery files based on position and package context.
fn classify_beyond_machinery(
  path: String,
  parts: List(String),
  graph: Graph,
) -> Kind {
  case string.starts_with(path, wire_prefix), parts {
    True, _ -> Wire
    False, ["packages", package, file] ->
      case list.contains(graph.packages, package) {
        True -> classify_package_root(file)
        False -> classify_outside(path, parts, graph)
      }
    False, ["packages", package, _, ..] ->
      case list.contains(graph.packages, package) {
        True -> Package
        False -> classify_outside(path, parts, graph)
      }
    False, _ -> classify_outside(path, parts, graph)
  }
}

/// Classifies files located directly at a package root.
fn classify_package_root(file: String) -> Kind {
  case list.contains(escalate_package_files, file) {
    True -> PackageManifest
    False ->
      case string.ends_with(file, ".md") {
        True -> PackageDoc
        False -> Package
      }
  }
}

/// Classifies paths located outside recognised package sources.
fn classify_outside(path: String, parts: List(String), graph: Graph) -> Kind {
  // Check if root-level file has markdown extension.
  let root_markdown = case parts {
    [_] -> string.ends_with(path, ".md")
    _ -> False
  }

  // Classify path as model, doc, read-by-test, or unknown.
  case
    string.starts_with(path, model_prefix),
    list.any(doc_prefixes, string.starts_with(path, _))
    || list.contains(doc_root_files, path)
    || root_markdown
  {
    True, _ -> Model
    False, True -> Doc
    False, False ->
      case list.any(graph.reads, fn(reading) { under(path, reading.prefix) }) {
        True -> ReadByTest
        False -> Unknown
      }
  }
}

fn is_machinery(path: String) -> Bool {
  list.any(escalate_prefixes, string.starts_with(path, _))
  || list.contains(escalate_files, path)
}

/// Report whether `path` is `prefix` or lies beneath it.
///
/// ## Examples
///
/// ```gleam
/// under("docs/examples/a.gleam", "docs/examples")  // -> True
/// under("docs/examplesX", "docs/examples")         // -> False
/// ```
pub fn under(path: String, prefix: String) -> Bool {
  // Strip trailing slashes from prefix before path comparison.
  let prefix = case string.ends_with(prefix, "/") {
    True -> under_trim(prefix)
    False -> prefix
  }

  path == prefix || string.starts_with(path, prefix <> "/")
}

// Python's `rstrip("/")`: every trailing slash goes, not just one.
fn under_trim(prefix: String) -> String {
  case string.ends_with(prefix, "/") {
    True -> under_trim(string.drop_end(prefix, 1))
    False -> prefix
  }
}

// The reverse-dependency walk. Each package popped finds the packages that
// list it under `[dependencies]` and have not been selected yet, in package
// name order, and pushes them for their own dependents.
/// Traverses reverse dependencies pushing affected packages onto the selected dictionary.
fn spread(
  frontier: List(String),
  selected: Dict(String, String),
  graph: Graph,
) -> Dict(String, String) {
  // Walk remaining frontier packages collecting dependents.
  case frontier {
    [] -> selected
    [package, ..rest] -> {
      let found =
        list.filter(graph.gleam, fn(other) {
          !dict.has_key(selected, other)
          && set.contains(dependencies_of(graph.deps, other), package)
        })
      let selected =
        list.fold(found, selected, fn(known, other) {
          dict.insert(known, other, "depends on " <> package)
        })
      spread(list.append(list.reverse(found), rest), selected, graph)
    }
  }
}

// A dev-dependency edge adds its declaring package when the dependency was
// selected by the regular walk. It is checked against that set alone, never
// against packages other dev edges added, which is what keeps the edge from
// propagating: a package that merely dev-depends on one of those is not
// reached.
/// Adds a dev-dependency package if one of its declared dev dependencies is affected.
fn add_dev_edge(
  found: Dict(String, String),
  regular: Dict(String, String),
  other: String,
  graph: Graph,
) -> Dict(String, String) {
  // Check whether the package is already marked affected.
  case dict.has_key(regular, other) {
    True -> found
    False -> {
      let hit =
        dependencies_of(graph.dev, other)
        |> set.to_list
        |> list.sort(string.compare)
        |> list.find(dict.has_key(regular, _))

      // Insert edge reason if any dev dependency was affected.
      case hit {
        Ok(package) -> dict.insert(found, other, "dev-depends on " <> package)
        Error(Nil) -> found
      }
    }
  }
}

fn dependencies_of(
  edges: Dict(String, Set(String)),
  package: String,
) -> Set(String) {
  dict.get(edges, package) |> result.lazy_unwrap(set.new)
}

// Depth-first over `[dependencies]` edges from the roots.
/// Collects reachable dependency packages using depth-first search.
fn reach(stack: List(String), found: Set(String), graph: Graph) -> Set(String) {
  case stack {
    [] -> found
    [package, ..rest] ->
      case set.contains(found, package) {
        True -> reach(rest, found, graph)
        False ->
          reach(
            list.append(set.to_list(dependencies_of(graph.deps, package)), rest),
            set.insert(found, package),
            graph,
          )
      }
  }
}

// The package lanes of an `Affected` selection: the named lane groups first,
// then every other selected package, in `check_order`, in one `fast` lane.
/// Groups affected package check commands into named parallel lane buckets.
fn grouped_lanes(selection: Selection) -> List(Lane) {
  let remaining = list.filter(check_order, dict.has_key(selection.packages, _))
  let named =
    list.filter_map(lane_groups, fn(group) {
      case list.filter(group.1, list.contains(remaining, _)) {
        [] -> Error(Nil)
        chosen -> Ok(Lane(group.0, ["bash", "scripts/check.sh", ..chosen]))
      }
    })
  let grouped = list.flat_map(lane_groups, fn(group) { group.1 })
  let rest =
    list.filter(remaining, fn(package) { !list.contains(grouped, package) })

  // Append fast lane for any unbucketed affected packages.
  case rest {
    [] -> named
    _ ->
      list.append(named, [Lane("fast", ["bash", "scripts/check.sh", ..rest])])
  }
}

// One `gate check-<package>` line per selected package, in `check_order`
// and then name order for any the order does not list.
/// Produces human-readable gate lines for each selected affected package.
fn check_lines(selection: Selection) -> List(String) {
  // Render full check notice or individual package check gates.
  case selection.mode {
    Full -> ["gate check  every package (make check)"]
    Affected -> {
      let listed = list.filter(check_order, dict.has_key(selection.packages, _))
      let unlisted =
        dict.keys(selection.packages)
        |> list.filter(fn(package) { !list.contains(check_order, package) })
        |> list.sort(string.compare)
      list.append(listed, unlisted)
      |> list.map(fn(package) {
        "gate check-"
        <> package
        <> "  "
        <> result.unwrap(dict.get(selection.packages, package), "")
      })
    }
  }
}
