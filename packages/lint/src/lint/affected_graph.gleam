//// The package graph `lint/affected` selects over: what each package
//// depends on, and what each package's tests read.
////
//// This is the half of the selector that interprets the tree rather than a
//// change. It reads each package's `gleam.toml` for its path dependencies,
//// and scans tracked sources for the relative path literals a test uses to
//// reach a file outside its package. Both are facts about the tree, derived
//// on every run so no table of edges can drift from what the manifests say.
////
//// Like the selector it is pure: it is handed the text of each manifest, the
//// tracked paths, and a function that returns a tracked file's text, and it
//// never touches the disk. `lint/affected_cli` is the reader.
////
//// # What a literal reads
////
//// A literal is resolved against both the package root, where the test
//// runner's working directory is, and the directory of the file holding it,
//// where an asset tool resolves it. A resolution counts only when it names a
//// package, or a tracked file or directory outside `packages/`; that
//// discards the literals which are inputs to path-escape tests
//// (`"../etc/passwd"`) and build outputs such as `bin/`. A literal naming
//// another package's file counts as a read of that whole package, because
//// the helper binary the real-helper suites run is built from all of it.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/regexp.{type Regexp}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import tom

/// The Go sandbox helper is a package directory without a `gleam.toml`.
/// `scripts/check.sh` accepts it by name and runs its Go vet, build and
/// tests.
const go_packages: List(String) = ["sandbox"]

/// Source extensions scanned for relative path literals.
const scanned_suffixes: List(String) = [
  ".gleam", ".erl", ".mjs", ".js", ".css", ".go",
]

/// A relative path literal: a quote, an optional slash, one or more `../`
/// steps and then a path of plain name characters. The group excludes the
/// quote and the slash, so a literal reads the same however it was written.
const relative_literal: String =
  "\"/?((?:\\.\\./)+[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"

/// A literal the tests append to the repository root they computed, as in
/// `repo <> "/docs/examples/strand_map.gleam"`. The base is not always the
/// repository (`workspace <> "/.claude/skills"` names a scratch workspace),
/// so such a literal counts only when it names a tracked file or a package,
/// never a bare directory, and fixture strings such as `"/etc/passwd"` fall
/// out with the rest.
const rooted_literal: String =
  "\"/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"

/// The two compiled path-literal patterns.
///
/// Compiling a pattern can fail, and `src/` may hold no `let assert`, so the
/// failure is a value the command line reports instead of a crash.
pub opaque type Patterns {
  Patterns(relative: Regexp, rooted: Regexp)
}

/// One `gleam.toml`'s path dependencies.
pub type Manifest {
  Manifest(
    /// Packages named by a path in `[dependencies]`; edges followed
    /// transitively.
    deps: Set(String),
    /// Packages named by a path in `[dev-dependencies]` or
    /// `[dev_dependencies]`, which Gleam accepts under both spellings; edges
    /// followed one step.
    dev: Set(String),
  )
}

/// A directory under `packages/` and the text of its `gleam.toml`, when it
/// has one.
pub type Entry {
  Entry(name: String, manifest: Option(String))
}

/// What a change reads at test time: a repository path prefix and the
/// packages whose sources name it by a relative literal.
pub type Reading {
  Reading(
    /// The repository path prefix that is read.
    prefix: String,
    /// Each reader with the first literal that names the prefix, kept for
    /// the reason the report gives.
    readers: List(#(String, String)),
  )
}

/// The package graph read from the tree.
pub type Graph {
  Graph(
    /// Every package directory, Gleam or Go, in name order.
    packages: List(String),
    /// The packages with a `gleam.toml`, in name order.
    gleam: List(String),
    /// Each Gleam package's `[dependencies]` path edges.
    deps: Dict(String, Set(String)),
    /// Each Gleam package's dev-dependency path edges.
    dev: Dict(String, Set(String)),
    /// The relative-literal reads, in the order they were found.
    reads: List(Reading),
  )
}

/// Compile the path-literal patterns.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(patterns) = affected.patterns()
/// ```
pub fn patterns() -> Result(Patterns, String) {
  use relative <- result.try(compile(relative_literal))
  use rooted <- result.try(compile(rooted_literal))
  Ok(Patterns(relative:, rooted:))
}

/// Read a `gleam.toml`'s path dependencies.
///
/// ## Examples
///
/// ```gleam
/// parse_manifest("[dependencies]\ncore = { path = \"../core\" }\nx = \">= 1.0.0\"")
/// // -> Ok(Manifest(deps: set.from_list(["core"]), dev: set.new()))
/// ```
pub fn parse_manifest(text: String) -> Result(Manifest, String) {
  use parsed <- result.try(
    tom.parse(text) |> result.replace_error("a gleam.toml does not parse"),
  )
  Ok(Manifest(
    deps: path_deps(parsed, "dependencies"),
    dev: set.union(
      path_deps(parsed, "dev-dependencies"),
      path_deps(parsed, "dev_dependencies"),
    ),
  ))
}

/// Build the graph from the package directories, the tracked paths and a
/// reader for tracked files.
///
/// `source` returns a file's text, or `Error(Nil)` for one that cannot be
/// read (a tracked file deleted in the working tree, say), which is skipped
/// rather than failing the selection.
///
/// ## Examples
///
/// ```gleam
/// build_graph(patterns, [Entry("a", Some("name = \"a\""))], ["packages/a/x.gleam"], read)
/// ```
pub fn build_graph(
  patterns: Patterns,
  entries: List(Entry),
  tracked: List(String),
  source: fn(String) -> Result(String, Nil),
) -> Result(Graph, String) {
  let kept =
    entries
    |> list.filter(fn(entry) {
      option.is_some(entry.manifest) || list.contains(go_packages, entry.name)
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let packages = list.map(kept, fn(entry) { entry.name })
  use manifests <- result.try(
    list.try_map(kept, fn(entry) { read_manifest(entry) }),
  )
  let present =
    list.filter_map(manifests, fn(found) { option.to_result(found, Nil) })
  let tracked = tracked |> list.sort(string.compare) |> list.unique
  Ok(Graph(
    packages:,
    gleam: list.map(present, fn(pair) { pair.0 }),
    deps: present
      |> list.map(fn(pair) { #(pair.0, { pair.1 }.deps) })
      |> dict.from_list,
    dev: present
      |> list.map(fn(pair) { #(pair.0, { pair.1 }.dev) })
      |> dict.from_list,
    reads: scan_reads(patterns, tracked, packages, source),
  ))
}

fn compile(pattern: String) -> Result(Regexp, String) {
  regexp.from_string(pattern)
  |> result.replace_error("a path-literal pattern does not compile")
}

fn path_deps(parsed: Dict(String, tom.Toml), table: String) -> Set(String) {
  case tom.get_table(parsed, [table]) {
    Ok(entries) ->
      entries
      |> dict.filter(fn(name, spec) { names_a_path(name, spec) })
      |> dict.keys
      |> set.from_list
    Error(_) -> set.new()
  }
}

// A dependency is a path dependency when its spec is a table with a `path`
// key, whether written inline or as its own `[dependencies.name]` table.
// Wrapping the spec in a one-entry document lets `get_table` accept both
// spellings without matching on every TOML variant.
fn names_a_path(name: String, spec: tom.Toml) -> Bool {
  tom.get_table(dict.from_list([#(name, spec)]), [name])
  |> result.map(dict.has_key(_, "path"))
  |> result.unwrap(False)
}

fn read_manifest(entry: Entry) -> Result(Option(#(String, Manifest)), String) {
  case entry.manifest {
    None -> Ok(None)
    Some(text) -> {
      use manifest <- result.try(
        parse_manifest(text)
        |> result.map_error(fn(why) { why <> ": packages/" <> entry.name }),
      )
      Ok(Some(#(entry.name, manifest)))
    }
  }
}

// What the walk over tracked files has found so far, and the sets every
// resolution is checked against.
type Scan {
  Scan(
    patterns: Patterns,
    tracked: Set(String),
    directories: Set(String),
    packages: List(String),
  )
}

/// Map repository path prefixes to the packages that read them.
///
/// A literal is resolved against both the package root, where the test
/// runner's working directory is, and the directory of the file holding it,
/// where an asset tool resolves it. A resolution counts only when it names a
/// package, or a tracked file or directory outside `packages/`; that
/// discards the literals which are inputs to path-escape tests
/// (`"../etc/passwd"`) and build outputs such as `bin/`. A literal naming
/// another package's file counts as a read of that whole package, because
/// the helper binary the real-helper suites run is built from all of it.
fn scan_reads(
  patterns: Patterns,
  tracked: List(String),
  packages: List(String),
  source: fn(String) -> Result(String, Nil),
) -> List(Reading) {
  let scan =
    Scan(
      patterns:,
      tracked: set.from_list(tracked),
      directories: directories_of(tracked),
      packages:,
    )
  list.fold(tracked, [], fn(reads, path) {
    case scannable(path, packages) {
      Some(reader) ->
        case source(path) {
          Ok(text) ->
            list.fold(candidates(scan, reader, path, text), reads, fn(found, c) {
              record(found, scan, reader, c)
            })
          Error(Nil) -> reads
        }
      None -> reads
    }
  })
}

// Every directory that holds a tracked file, so a literal naming a bare
// directory such as `docs/examples` still resolves.
fn directories_of(tracked: List(String)) -> Set(String) {
  list.fold(tracked, set.new(), fn(found, path) {
    let parts = string.split(path, "/")
    parts
    |> list.take(list.length(parts) - 1)
    |> list.fold(#(found, ""), fn(state, part) {
      let directory = case state.1 {
        "" -> part
        parent -> parent <> "/" <> part
      }
      #(set.insert(state.0, directory), directory)
    })
    |> pair.first
  })
}

// The package whose source this is, when it is a source worth scanning.
fn scannable(path: String, packages: List(String)) -> Option(String) {
  case string.split(path, "/") {
    ["packages", reader, _, ..] ->
      case
        list.contains(packages, reader)
        && list.any(scanned_suffixes, string.ends_with(path, _))
      {
        True -> Some(reader)
        False -> None
      }
    _ -> None
  }
}

// A literal and the repository path it resolves to.
type Candidate {
  Candidate(literal: String, target: String)
}

// Relative literals first, each resolved against the package root and then
// the file's own directory; rooted literals after them. The order decides
// which literal a read is reported with.
fn candidates(
  scan: Scan,
  reader: String,
  path: String,
  text: String,
) -> List(Candidate) {
  let bases = ["packages/" <> reader, dirname(path)]
  let relative =
    list.flat_map(literals(scan.patterns.relative, text), fn(literal) {
      list.map(bases, fn(base) {
        Candidate(literal, normpath(base <> "/" <> literal))
      })
    })
  let rooted =
    literals(scan.patterns.rooted, text)
    |> list.filter(fn(literal) {
      set.contains(scan.tracked, literal)
      || string.starts_with(literal, "packages/")
    })
    |> list.map(fn(literal) { Candidate("/" <> literal, literal) })
  list.append(relative, rooted)
}

// The first group of every non-overlapping match, in order.
fn literals(pattern: Regexp, text: String) -> List(String) {
  regexp.scan(pattern, text)
  |> list.filter_map(fn(found) {
    case found.submatches {
      [Some(literal), ..] -> Ok(literal)
      [None, ..] | [] -> Error(Nil)
    }
  })
}

// Keep the first reader, and the first literal, to name a prefix.
fn record(
  reads: List(Reading),
  scan: Scan,
  reader: String,
  candidate: Candidate,
) -> List(Reading) {
  case read_prefix(candidate.target, reader, scan) {
    None -> reads
    Some(prefix) -> add_reader(reads, prefix, reader, candidate.literal)
  }
}

fn add_reader(
  reads: List(Reading),
  prefix: String,
  reader: String,
  literal: String,
) -> List(Reading) {
  case list.any(reads, fn(reading) { reading.prefix == prefix }) {
    False -> list.append(reads, [Reading(prefix, [#(reader, literal)])])
    True ->
      list.map(reads, fn(reading) {
        case reading.prefix == prefix, list.key_find(reading.readers, reader) {
          True, Error(Nil) ->
            Reading(
              ..reading,
              readers: list.append(reading.readers, [#(reader, literal)]),
            )
          True, Ok(_) | False, _ -> reading
        }
      })
  }
}

// The prefix a resolved literal reads, or nothing. A resolution that leaves
// the repository, or names `packages` itself, reads nothing; one inside
// `packages/` reads that whole other package; anything else counts when it
// is a tracked file or a directory holding one.
fn read_prefix(target: String, reader: String, scan: Scan) -> Option(String) {
  let parts = string.split(target, "/")
  case
    string.starts_with(target, "..") || target == "." || target == "packages"
  {
    True -> None
    False ->
      case parts {
        ["packages", package, ..] ->
          case list.contains(scan.packages, package) && package != reader {
            True -> Some("packages/" <> package)
            False -> None
          }
        _ ->
          case
            set.contains(scan.tracked, target)
            || set.contains(scan.directories, target)
          {
            True -> Some(target)
            False -> None
          }
      }
  }
}

// The directory part of a path with at least one slash.
fn dirname(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> ""
  }
}

/// Collapse `.`, empty and `..` steps of a relative path the way POSIX
/// `normpath` does: a `..` cancels the step before it, and survives at the
/// front where there is nothing to cancel.
///
/// ## Examples
///
/// ```gleam
/// normpath("packages/broker/../sandbox/x")  // -> "packages/sandbox/x"
/// normpath("packages/../../etc")            // -> "../etc"
/// ```
pub fn normpath(path: String) -> String {
  let steps =
    string.split(path, "/")
    |> list.fold([], fn(stack, step) {
      case step, stack {
        "", _ | ".", _ -> stack
        "..", [top, ..rest] if top != ".." -> rest
        _, _ -> [step, ..stack]
      }
    })
  case steps {
    [] -> "."
    _ -> steps |> list.reverse |> string.join("/")
  }
}
