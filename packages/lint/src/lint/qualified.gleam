//// R16, unqualified imports of functions from Loom's own modules (issue #593, 3).
////
//// In a large module the qualifier is the closest thing Gleam has to a method
//// receiver. `approval.project(view)` says which domain the call belongs to
//// and where to look for it; a bare `project(view)` could be a local helper,
//// a sibling, or an import from anywhere, and the reader has to scroll to the
//// import list to find out. Types and constructors are exempt, since they
//// read as nouns and a qualifier on every `Ok`-like constructor is noise.
////
//// The rule is decidable from the import list alone. An import is Loom's own
//// when its first path segment is one of `loom_roots`; each lowercase name in
//// its `{...}` list is a function or constant and is a finding unless
//// `allowed` lists the pair. Standard-library and third-party modules are
//// outside the rule because their qualifiers are not Loom's domains.

import glance
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lint/finding
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// The first path segment of every module this tree defines: one per
/// directory or top-level `.gleam` file under a package's `src/`, so `tui`
/// covers both `tui.gleam` and `tui/`.
///
/// The list is data and a test keeps it honest by reading `packages/` and
/// comparing. It is a list of *roots* rather than of modules because every
/// package puts its modules under one root named for it. The one place a root
/// could collide with a dependency is the MCP SDK, and it does not: the SDK
/// is `gleam_mcp` and its modules live under `gleam_mcp/`, while this tree's
/// `mcp` package owns `mcp/` alone. No other dependency defines a module under
/// any of these roots, so the whole root is listed rather than module paths.
///
/// ## Examples
///
/// ```gleam
/// list.contains(qualified.loom_roots(), "session_view")
/// // -> True
/// ```
pub fn loom_roots() -> List(String) {
  [
    "broker",
    "cap",
    "client",
    "codemode",
    "conformance",
    "core",
    "events",
    "ext",
    "host",
    "lint",
    "machine",
    "mcp",
    "prompt",
    "provider",
    "runtime",
    "session",
    "session_view",
    "storage",
    "telemetry",
    "tools",
    "tui",
    "web_client",
    "web_view",
  ]
}

/// Unqualified value imports from Loom modules that are idiomatic, as
/// `#(module, name)` with the reason beside each. Add a pair only when the
/// bare name reads better than any qualifier would, such as a `use`
/// continuation combinator (`use <- or_fault(...)`).
///
/// The census found no such pair: the tree's only two unqualified Loom value
/// imports are constants (`net_cap`, `max_image_bytes`), which read better
/// with their module in front. The table is empty on purpose, and
/// `findings_allowing` is what lets a test exercise the mechanism.
///
/// ## Examples
///
/// ```gleam
/// qualified.allowed()
/// // -> []
/// ```
pub fn allowed() -> List(#(String, String)) {
  []
}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// qualified.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = #(code, lines, policy, own_path)
  findings_allowing(module, allowed())
}

/// The same judgement with the allow list supplied, so a test can prove an
/// allowed pair is silent and its neighbour is not.
///
/// ## Examples
///
/// ```gleam
/// qualified.findings_allowing(module, [#("tools/tool", "or_outcome")])
/// // -> []
/// ```
pub fn findings_allowing(
  module: glance.Module,
  allow: List(#(String, String)),
) -> List(Raw) {
  list.flat_map(module.imports, fn(def) {
    import_findings(def.definition, allow)
  })
}

/// The findings for one import: nothing unless it is Loom's own, then one per
/// bare function or constant name that is not on the allow list.
fn import_findings(
  import_: glance.Import,
  allow: List(#(String, String)),
) -> List(Raw) {
  case is_loom_module(import_.module) {
    False -> []
    True ->
      import_.unqualified_values
      |> list.filter(fn(value) { is_value_name(value.name) })
      |> list.filter(fn(value) {
        !list.contains(allow, #(import_.module, value.name))
      })
      |> list.map(fn(value) {
        Raw(
          rule: finding.QualifiedDomainCall,
          offset: import_.location.start,
          function: value.name,
          detail: detail(import_, value.name),
        )
      })
  }
}

/// Whether a module path starts at one of this tree's roots.
fn is_loom_module(path: String) -> Bool {
  let root = case string.split_once(path, "/") {
    Ok(#(head, _)) -> head
    Error(Nil) -> path
  }
  list.contains(loom_roots(), root)
}

/// A function or constant name starts lowercase; a type or constructor does
/// not, and `type X` imports are held in a separate list by `glance`.
fn is_value_name(name: String) -> Bool {
  case string.first(name) {
    Ok(first) -> first == string.lowercase(first) && first != "_"
    Error(Nil) -> False
  }
}

/// The advice: which import to qualify and what the call becomes. The
/// qualifier is the alias when the import has one, otherwise the last path
/// segment, which is what the call site will have to spell.
fn detail(import_: glance.Import, name: String) -> String {
  let qualifier = case import_.alias {
    Some(glance.Named(alias)) -> alias
    Some(glance.Discarded(_)) -> last_segment(import_.module)
    None -> last_segment(import_.module)
  }
  "import `"
  <> import_.module
  <> "` and call `"
  <> qualifier
  <> "."
  <> name
  <> "` instead of importing `"
  <> name
  <> "` unqualified"
}

/// The segment after the last `/`.
fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(Nil) -> path
  }
}
