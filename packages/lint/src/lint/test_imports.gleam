//// R20, a test whose import graph reaches a module it must not load (test
//// sources only).
////
//// `packages/web_client` targets JavaScript, and its tests run on whatever
//// runtime the machine has. `lustre/runtime/client/runtime.ffi.mjs` declares
//// `class LustreEvent extends CustomEvent` when it loads, and Node 18 — what
//// the signoff container's apt provides — has no global `CustomEvent`, so a
//// test module that reaches Lustre throws `ReferenceError` before any test
//// runs. The component decisions therefore live in `*_rule` modules that
//// import neither Lustre nor the package's `internal/` DOM bindings, and the
//// tests import only those. Nothing about the split is visible to the
//// compiler: a one-line `import lustre` added to a rule module typechecks and
//// passes every test on a developer's newer Node, and fails only in the
//// container. This rule makes the split a property of the tree.
////
//// The walk is transitive, because the failure is. It starts at every test
//// module of a walled package and follows each import that names one of the
//// package's own modules into its `src/`. An import of a forbidden prefix is
//// a finding at the importing line, in the file that wrote it, with the chain
//// of modules from the test that reached it. A forbidden module is reported
//// and never entered; a module reached twice is read once, so a diamond
//// reports each bad import once rather than once per path.
////
//// The module is pure. `lint/cli` supplies the package's sources as a
//// dictionary keyed by module path, because reading `src/` is I/O and which
//// packages are walled, and what each forbids, is data in
//// `policy.import_walls`.

import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}
import gleam/string
import lint/finding.{type Finding, Finding}
import lint/policy.{type Wall}
import lint/source

/// A source on the walk's frontier: where it is, what it says, and the chain
/// of names (newest first) that led the walk to it.
type Node {
  Node(path: String, code: String, via: List(String))
}

/// What one import means to the walk.
type Step {
  /// An import the wall forbids; reported at its offset.
  Forbidden(module: String, offset: Int)

  /// An import of one of the package's own modules; entered unless seen.
  Descend(module: String)
}

/// Every forbidden import reachable from the given tests.
///
/// `tests` are `#(display path, source)` for each test file of the walled
/// package, and `modules` maps each of the package's own module paths
/// (`web_client/follow_rule`) to its `#(display path, source)`. A module the
/// dictionary does not hold ends that branch of the walk: it is not the
/// package's, or its source was not readable, and neither is this rule's
/// finding.
///
/// ## Examples
///
/// ```gleam
/// test_imports.findings(wall, [#("packages/web_client/test/a_test.gleam", code)], modules)
/// // -> []
/// ```
pub fn findings(
  wall: Wall,
  tests: List(#(String, String)),
  modules: Dict(String, #(String, String)),
) -> List(Finding) {
  let frontier =
    list.map(tests, fn(test_source) {
      Node(path: test_source.0, code: test_source.1, via: [test_source.0])
    })
  walk(wall, frontier, set.new(), modules, [])
}

/// One breadth-first step per source. Breadth-first so the chain reported for
/// a module is the shortest one, which is the one worth reading.
fn walk(
  wall: Wall,
  frontier: List(Node),
  seen: Set(String),
  modules: Dict(String, #(String, String)),
  acc: List(Finding),
) -> List(Finding) {
  // Process frontier nodes until the search queue is empty.
  case frontier {
    [] -> list.reverse(acc)
    [node, ..rest] -> {
      let #(entered, seen, acc) =
        list.fold(steps(wall, node.code), #([], seen, acc), fn(state, step) {
          advance(step, node, modules, state)
        })
      walk(wall, list.append(rest, list.reverse(entered)), seen, modules, acc)
    }
  }
}

/// Apply one import to the walk's state: report it, enter it, or let it go.
fn advance(
  step: Step,
  node: Node,
  modules: Dict(String, #(String, String)),
  state: #(List(Node), Set(String), List(Finding)),
) -> #(List(Node), Set(String), List(Finding)) {
  let #(entered, seen, acc) = state

  // Handle whether the step imports a forbidden module or descends locally.
  case step {
    Forbidden(module:, offset:) -> #(entered, seen, [
      reached(node, module, offset),
      ..acc
    ])
    Descend(module:) ->
      case set.contains(seen, module), dict.get(modules, module) {
        False, Ok(#(path, code)) -> #(
          [Node(path:, code:, via: [module, ..node.via]), ..entered],
          set.insert(seen, module),
          acc,
        )
        _, _ -> #(entered, seen, acc)
      }
  }
}

/// The finding: at the import's own line, naming the chain that reached it.
fn reached(node: Node, module: String, offset: Int) -> Finding {
  let line = source.line_of(source.line_starts(node.code), offset)
  Finding(
    rule: finding.TestImportWall,
    path: node.path,
    line:,
    function: "",
    detail: "imports `"
      <> module
      <> "`, which loads the browser runtime: a test reaches it through "
      <> string.join(list.reverse(node.via), " -> ")
      <> "; Node 18 has no `CustomEvent`, so the suite would throw before "
      <> "any test runs — keep the decision in a module that imports neither",
  )
}

/// The imports of a source that matter to the wall, in source order. A source
/// that will not parse has none: R0 reports it where it is linted.
fn steps(wall: Wall, code: String) -> List(Step) {
  case glance.module(code) {
    Error(_) -> []
    Ok(module) ->
      list.filter_map(module.imports, fn(definition) {
        let import_ = definition.definition

        // Classify whether this import is forbidden, local, or ignored.
        case
          list.any(wall.forbidden, under(_, import_.module)),
          under(wall.package, import_.module)
        {
          True, _ -> Ok(Forbidden(import_.module, import_.location.start))
          False, True -> Ok(Descend(import_.module))
          False, False -> Error(Nil)
        }
      })
  }
}

/// Whether a module path is the prefix itself or sits beneath it as a path
/// segment, so `lustre` covers `lustre/element` and not `lustrous`.
fn under(prefix: String, module: String) -> Bool {
  module == prefix || string.starts_with(module, prefix <> "/")
}
