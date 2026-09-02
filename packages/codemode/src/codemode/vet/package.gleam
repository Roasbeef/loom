//// Vetting a whole *package*, rather than the one-file program
//// `codemode/vet` judges.
////
//// An installed extension is a Gleam package with many modules, a project
//// file, and data files beside them. `vet.vet` answers "may this source
//// run?" for one module; this module answers the three questions a package
//// asks that a single file does not:
////
//// 1. **Which files may be here at all.** Everything under `src/` is
////    compiled, so a `.erl` or `.mjs` sitting there is foreign code the
////    Gleam-source lint never sees — Gleam compiles native modules found
////    in `src/` and links them into the artifact, which is `@external`
////    with the declaration moved out of view. So `src/` admits `.gleam`
////    and nothing else, `test/` is refused outright (it is not installed
////    and its dependencies are not vetted), and the rest of the tree is a
////    short allowlist of things that are read rather than run.
//// 2. **What the project file may name.** The build is generated from
////    `compile.default_dependencies` and the extension's own `gleam.toml`
////    is never handed to the compiler, so a dependency named here would
////    fail the build rather than enter it. Refusing it at vetting is
////    still worth the lines: the author gets "you may not depend on
////    `simplifile`" instead of a type error about a module that is not
////    there, and the refusal is a fact about the *package* an install
////    record can carry.
//// 3. **Which imports are intra-package.** A module in the extension may
////    import a sibling, which the seam allowlist knows nothing about. So
////    each file is judged against the seam policy widened by the
////    package's own module names — and by *exactly* those, so an import
////    of a sibling that does not exist is refused here rather than at the
////    compiler, and a module that shadows an allowlisted one is refused
////    before it can be the `cap/fs` a sibling resolves.
////
//// # Every refusal names its file
////
//// The result carries `#(path, rejection)` pairs and never a bare reason.
//// An extension is somebody else's repository, and "the extension was
//// refused" without a path is a bug report nobody can act on.

import codemode/vet.{type Vetted}
import codemode/vet/policy.{type VetPolicy}
import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import tom

/// The one directory whose contents are compiled.
pub const source_directory = "src/"

/// The dependencies an extension's `gleam.toml` may name. The two
/// preludes and the two pinned hex packages the generated build provides
/// — nothing else exists inside the jail to depend on.
pub const allowed_dependencies = ["gleam_stdlib", "gleam_json", "cap", "ext"]

/// The `gleam.toml` keys an extension may set. `dev_dependencies` is
/// admitted and ignored: an author's own test dependencies are their
/// business, because `test/` is never installed.
pub const allowed_project_keys = [
  "name", "version", "gleam", "description", "licences", "dependencies",
  "dev_dependencies", "target", "internal_modules", "repository", "links",
]

/// Why one file refused the package.
pub type Rejection {
  /// The file's own Gleam source failed the vetting lint.
  SourceRejected(rejection: vet.Rejection)

  /// The file may not appear in an installed extension at all.
  FileNotAllowed(reason: String)

  /// The package's `gleam.toml` did not decode.
  ProjectUnreadable(reason: String)

  /// The package's `gleam.toml` named a dependency the jail does not have.
  DependencyNotAllowed(name: String)
}

/// A package every file of which passed. Opaque for the reason `Vetted`
/// is: there is no constructor but `vet_package`, so a caller holding one
/// holds proof rather than an assertion.
pub opaque type VettedPackage {
  VettedPackage(modules: List(#(String, Vetted)))
}

/// The package's vetted modules as `#(module name, vetted source)`, sorted
/// by module name so a build root is written deterministically.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(vetted) = package.vet_package(files, policy.extension())
/// assert list.length(package.modules(vetted)) == 1
/// ```
///
pub fn modules(vetted: VettedPackage) -> List(#(String, Vetted)) {
  vetted.modules
}

/// The package's module names, in the same order as `modules`.
///
/// ## Examples
///
/// ```gleam
/// assert package.module_names(vetted) == ["weather/forecast"]
/// ```
///
pub fn module_names(vetted: VettedPackage) -> List(String) {
  list.map(vetted.modules, fn(entry) { entry.0 })
}

/// Vets a whole package: its layout, its project file, and every module.
///
/// `files` is the extracted tree as `#(relative path, contents)`. Every
/// failure found is reported, not just the first, for the reason
/// `vet.vet` reports every rule violation at once: an author fixing an
/// extension wants the whole list.
///
/// ## Examples
///
/// ```gleam
/// let files = [
///   #("gleam.toml", "name = \"w\"\n"),
///   #("src/w.gleam", "pub fn run() { 1 }\n"),
/// ]
/// let assert Ok(_) = package.vet_package(files, policy.extension())
/// ```
///
pub fn vet_package(
  files: List(#(String, String)),
  policy: VetPolicy,
) -> Result(VettedPackage, List(#(String, Rejection))) {
  let sources = list.filter(files, fn(file) { is_module(file.0) })
  let widened = widen(policy, list.map(sources, fn(file) { module_of(file.0) }))
  let judged =
    list.map(sources, fn(file) { #(file.0, vet.vet(file.1, widened)) })

  // Three independent sweeps, concatenated rather than short-circuited:
  // an author fixing an extension wants the whole list, not the first
  // thing that stopped the reader.
  let refusals =
    list.flatten([
      list.filter_map(files, layout_refusal),
      project_refusals(files),
      list.flat_map(judged, fn(entry) { source_refusals(entry, policy) }),
    ])
  case refusals {
    [] -> Ok(VettedPackage(modules: passed(judged)))
    [_, ..] -> Error(refusals)
  }
}

/// Renders one rejection for an operator, without the path — the caller
/// holds that and decides how to print it.
///
/// ## Examples
///
/// ```gleam
/// assert package.describe(package.DependencyNotAllowed("simplifile"))
///   == "it depends on simplifile, which the jail does not provide"
/// ```
///
pub fn describe(rejection: Rejection) -> String {
  case rejection {
    SourceRejected(rejection:) -> rejection.detail
    FileNotAllowed(reason:) -> reason
    ProjectUnreadable(reason:) -> reason
    DependencyNotAllowed(name:) ->
      "it depends on " <> name <> ", which the jail does not provide"
  }
}

// --- layout ---------------------------------------------------------------

// One refusal for a path that may not be installed, or `Error(Nil)` for a
// path that may. The order of the arms is the order the reasons are worth
// hearing: `src/` first, because that is the directory whose contents run.
fn layout_refusal(
  file: #(String, String),
) -> Result(#(String, Rejection), Nil) {
  let path = file.0
  case admissible(path) {
    Ok(Nil) -> Error(Nil)
    Error(reason) -> Ok(#(path, FileNotAllowed(reason:)))
  }
}

fn admissible(path: String) -> Result(Nil, String) {
  case classify(path) {
    Module | Data -> Ok(Nil)
    Native ->
      Error(
        "a file under src/ that is not .gleam is compiled into the artifact "
        <> "and linked, which is a foreign interface the source lint cannot "
        <> "see; move it out of src/ or delete it",
      )
    Tests ->
      Error(
        "test/ is not installed and its dependencies are never vetted, so a "
        <> "package carrying one is refused rather than silently ignored",
      )
    Foreign ->
      Error(
        "an installed extension carries only src/, schema/, skills/, "
        <> "extension.toml, gleam.toml, README* and LICENSE*",
      )
  }
}

// What one path in the extracted tree is.
type Kind {
  // A Gleam module under `src/`.
  Module

  // A non-Gleam file under `src/`: compiled and linked, so refused.
  Native

  // A file under `test/`.
  Tests

  // A file that is read rather than run.
  Data

  // Anything else.
  Foreign
}

fn classify(path: String) -> Kind {
  case string.starts_with(path, source_directory) {
    True ->
      case string.ends_with(path, ".gleam") {
        True -> Module
        False -> Native
      }
    False -> classify_outside_source(path)
  }
}

fn classify_outside_source(path: String) -> Kind {
  case string.starts_with(path, "test/") {
    True -> Tests
    False ->
      case is_data(path) {
        True -> Data
        False -> Foreign
      }
  }
}

fn is_data(path: String) -> Bool {
  string.starts_with(path, "schema/")
  || string.starts_with(path, "skills/")
  || path == "extension.toml"
  || path == "gleam.toml"
  || string.starts_with(path, "README")
  || string.starts_with(path, "LICENSE")
}

fn is_module(path: String) -> Bool {
  classify(path) == Module
}

// `src/weather/forecast.gleam` -> `weather/forecast`.
fn module_of(path: String) -> String {
  path
  |> string.drop_start(string.length(source_directory))
  |> string.drop_end(string.length(".gleam"))
}

// --- the project file -----------------------------------------------------

fn project_refusals(
  files: List(#(String, String)),
) -> List(#(String, Rejection)) {
  case list.key_find(files, "gleam.toml") {
    Error(Nil) -> [
      #(
        "gleam.toml",
        ProjectUnreadable(
          reason: "an extension is a Gleam package and needs a gleam.toml",
        ),
      ),
    ]
    Ok(text) ->
      list.map(project_rejections(text), fn(rejection) {
        #("gleam.toml", rejection)
      })
  }
}

fn project_rejections(text: String) -> List(Rejection) {
  case tom.parse(text) {
    Error(error) -> [ProjectUnreadable(reason: parse_reason(error))]
    Ok(document) ->
      list.append(unknown_keys(document), dependency_rejections(document))
  }
}

fn unknown_keys(document: Dict(String, tom.Toml)) -> List(Rejection) {
  dict.keys(document)
  |> list.filter(fn(key) { !list.contains(allowed_project_keys, key) })
  |> list.sort(string.compare)
  |> list.map(fn(key) {
    ProjectUnreadable(
      reason: "gleam.toml sets " <> key <> ", which an extension may not set",
    )
  })
}

// Only `[dependencies]` is judged. `[dev_dependencies]` is an author's own
// business precisely because `test/` never reaches the install.
fn dependency_rejections(document: Dict(String, tom.Toml)) -> List(Rejection) {
  case dict.get(document, "dependencies") {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) ->
      dict.keys(entries)
      |> list.filter(fn(name) { !list.contains(allowed_dependencies, name) })
      |> list.sort(string.compare)
      |> list.map(fn(name) { DependencyNotAllowed(name:) })

    // An absent table is legal (a package may depend on nothing); a
    // present one of the wrong shape is not TOML we can judge.
    Error(Nil) -> []
    Ok(_other) -> [
      ProjectUnreadable(reason: "gleam.toml's [dependencies] is not a table"),
    ]
  }
}

fn parse_reason(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "gleam.toml is not valid toml: expected "
      <> expected
      <> ", got `"
      <> got
      <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "gleam.toml is not valid toml: the key "
      <> string.join(key, ".")
      <> " appears twice"
  }
}

// --- the modules ----------------------------------------------------------

// The seam policy plus the package's own module names, and *only* names
// the package actually ships: an import of a sibling that does not exist
// is refused here, and a module that shadows an allowlisted one is refused
// rather than allowed to become the `cap/fs` a sibling resolves.
fn widen(base: VetPolicy, names: List(String)) -> VetPolicy {
  list.fold(names, base, policy.allow)
}

fn source_refusals(
  judged: #(String, vet.VetResult),
  base: VetPolicy,
) -> List(#(String, Rejection)) {
  let #(path, result) = judged
  let shadowing = shadow_refusals(path, base)
  case result {
    vet.Passed(_vetted) -> shadowing
    vet.Rejected(rejections) ->
      list.append(
        shadowing,
        list.map(rejections, fn(rejection) {
          #(path, SourceRejected(rejection:))
        }),
      )
  }
}

// A module whose name is already on the seam's allowlist would be compiled
// into the extension's own package under that name, and a sibling's
// `import cap/fs` would then resolve to it. Refused by name, before the
// widened policy can make it look legitimate.
fn shadow_refusals(
  path: String,
  base: VetPolicy,
) -> List(#(String, Rejection)) {
  let name = module_of(path)
  case policy.contains(base, name) {
    False -> []
    True -> [
      #(
        path,
        FileNotAllowed(
          reason: "the module name "
          <> name
          <> " is one the seam already allows, so this file would shadow "
          <> "the prelude module a sibling imports",
        ),
      ),
    ]
  }
}

// The vetted tokens, in module-name order so a build root is written
// deterministically. Reached only when nothing was refused, so the
// `Rejected` arm is unreachable rather than lenient.
fn passed(judged: List(#(String, vet.VetResult))) -> List(#(String, Vetted)) {
  judged
  |> list.filter_map(fn(entry) {
    case entry.1 {
      vet.Passed(vetted) -> Ok(#(module_of(entry.0), vetted))
      vet.Rejected(_) -> Error(Nil)
    }
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}
