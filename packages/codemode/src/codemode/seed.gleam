//// The build seed — the pre-resolved package cache a hermetic code-mode
//// build runs against.
////
//// # Why a seed exists at all
////
//// The compile service's second defence is that the build sees exactly the
//// prelude and the standard library, offline, so nothing else can enter it
//// (`codemode/compile`, defence 2). "Offline" is the load-bearing word,
//// and Gleam will not build offline from nothing: given a project root
//// with no `build/packages`, it re-resolves versions, and resolution
//// reaches Hex. A pinned `manifest.toml` alone does not prevent that once
//// a *local* (path) dependency is in play.
////
//// So the packages are seeded rather than fetched. A seed is an ordinary
//// Gleam project — the same `gleam.toml` the compile service generates,
//// the prelude vendored under `vendor/`, a placeholder program — that has
//// been built **once, online**. Its `build/` directory then holds the
//// resolved `manifest.toml`, the extracted Hex packages, and the compiled
//// prelude. Every subsequent build root is a copy of it, and a copy needs
//// no network at all: `make e2e-codemode` proves that by running the build
//// in a network-off jail.
////
//// # Why the preludes are vendored rather than pointed at
////
//// Gleam records a local dependency's path in `manifest.toml` *relative to
//// the project root*, and treats an absolute or mismatched path as a stale
//// manifest — which sends it back to resolution, and to the network. A
//// build root is created fresh per execution, at whatever depth the
//// session's scratch area lives, so no relative path to `packages/cap`
//// could be stable. Vendoring the prelude *inside* the build root at a
//// fixed relative location (`compile.prelude_path`) makes the recorded
//// path depth-independent, and has the pleasant side effect that a build
//// root needs no read access outside itself.
////
//// # Staleness
////
//// A seed is a snapshot of the preludes. Change `packages/cap` or
//// `packages/ext` and the seed is stale until it is rebuilt, and programs
//// will compile against the old one. `make codemode-seed` rebuilds it
//// from scratch; `make
//// e2e-codemode` always does so first. `verify` checks the one thing that
//// silently changes the *meaning* of a build — that the seed's dependency
//// table is byte-identical to the one the compile service generates — and
//// the builder refuses to run against a seed that fails it.

import codemode/compile.{type Dependency}
import gleam/io
import gleam/list
import gleam/result
import simplifile

/// Where `main` writes the seed, relative to the `codemode` package
/// directory (`gleam run -m codemode/seed` is always run from there).
pub const default_root = "../../build/codemode-seed"

/// The packages `main` vendors into the seed, as `#(name, source)` pairs
/// relative to the `codemode` package directory. `cap` is the capability
/// prelude and `ext` the extension prelude; `core` is there because
/// `cap`'s own `gleam.toml` names it as `../core`, which resolves inside
/// `vendor/` once both are there — and `ext` names `../cap` for the same
/// reason.
pub fn default_vendored() -> List(#(String, String)) {
  [#("cap", "../cap"), #("core", "../core"), #("ext", "../ext")]
}

/// The marker `main` prints on success, so a shell script can tell a
/// prepared seed from a failed one without an exit-code FFI.
pub const ready_marker = "LOOM_SEED_LAID_OUT"

/// Lays out a seed project at `root`: the compile service's own
/// `gleam.toml`, the vendored packages, and a placeholder program and
/// entry. An existing `root` is removed first, so a seed is never a
/// half-refreshed mixture of two preludes.
///
/// This only *lays out* the project. Building it — the online step that
/// resolves versions and fills `build/` — is `gleam build` run in the
/// resulting directory, which is what `scripts/codemode_seed.sh` does.
pub fn prepare(
  root root: String,
  vendored vendored: List(#(String, String)),
  dependencies dependencies: List(Dependency),
) -> Result(Nil, String) {
  let _cleared = simplifile.delete(root)
  use _ <- result.try(make_directory(root <> "/src"))
  use _ <- result.try(
    list.try_each(vendored, fn(package) {
      vendor(package.1, root <> "/vendor/" <> package.0)
    }),
  )
  use _ <- result.try(write(
    root <> "/gleam.toml",
    compile.project_toml(dependencies),
  ))
  use _ <- result.try(write(
    root <> "/src/" <> compile.program_module <> ".gleam",
    placeholder_program(),
  ))
  write(
    root <> "/src/" <> compile.entry_module <> ".gleam",
    compile.entry_source(),
  )
}

/// Checks that a seed at `root` is one a hermetic build may use: it was
/// built (so `build/packages` and a resolved `manifest.toml` exist), and
/// its dependency table is byte-identical to the one the compile service
/// generates for `dependencies`.
///
/// The byte comparison is the point. A seed prepared from a different
/// dependency table resolved a different dependency graph, so building
/// against it would produce an artifact pinned to something other than
/// what the compile service says it pinned.
pub fn verify(
  root: String,
  dependencies: List(Dependency),
) -> Result(Nil, String) {
  use present <- result.try(
    simplifile.read(root <> "/gleam.toml")
    |> result.replace_error(
      "no seed at " <> root <> "; run `make codemode-seed`",
    ),
  )
  use _ <- result.try(case present == compile.project_toml(dependencies) {
    True -> Ok(Nil)
    False ->
      Error(
        "the seed at "
        <> root
        <> " was prepared from a different dependency table; run `make "
        <> "codemode-seed`",
      )
  })
  use _ <- result.try(exists(
    root <> "/manifest.toml",
    "the seed has no resolved manifest.toml; run `make codemode-seed`",
  ))
  exists(
    root <> "/build/packages/packages.toml",
    "the seed has no resolved package cache; run `make codemode-seed`",
  )
}

/// Lays out the default seed and reports where. Run as
/// `gleam run -m codemode/seed` from the `codemode` package directory;
/// `scripts/codemode_seed.sh` then builds what this writes.
pub fn main() -> Nil {
  case
    prepare(
      root: default_root,
      vendored: default_vendored(),
      dependencies: compile.default_dependencies(),
    )
  {
    Ok(Nil) -> io.println(ready_marker <> " " <> default_root)
    Error(reason) -> io.println("seed layout failed: " <> reason)
  }
}

// The placeholder the seed is built with. It exists only so the seed's
// build compiles a real program module; every build root overwrites it.
fn placeholder_program() -> String {
  "//// A seed placeholder. Every build root overwrites this.\n\n"
  <> "import cap/report\n\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  report.text(\"seed\")\n"
  <> "}\n"
}

// Vendors one package: its project file and the source trees Gleam reads.
// Deliberately not a whole-directory copy — a package's own `build/` is
// tens of megabytes of artifacts belonging to a different project root.
fn vendor(source: String, destination: String) -> Result(Nil, String) {
  use _ <- result.try(make_directory(destination))
  use _ <- result.try(copy_file(
    source <> "/gleam.toml",
    destination <> "/gleam.toml",
  ))
  use _ <- result.try(copy_tree(source <> "/src", destination <> "/src"))
  use _ <- result.try(copy_optional_tree(
    source <> "/priv",
    destination <> "/priv",
  ))
  copy_optional_tree(source <> "/include", destination <> "/include")
}

fn copy_optional_tree(
  source: String,
  destination: String,
) -> Result(Nil, String) {
  case simplifile.is_directory(source) {
    Ok(True) -> copy_tree(source, destination)
    _ -> Ok(Nil)
  }
}

fn copy_tree(source: String, destination: String) -> Result(Nil, String) {
  simplifile.copy_directory(at: source, to: destination)
  |> describe("copy " <> source)
}

fn copy_file(source: String, destination: String) -> Result(Nil, String) {
  simplifile.copy_file(at: source, to: destination)
  |> describe("copy " <> source)
}

fn make_directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path) |> describe("create " <> path)
}

fn write(path: String, contents: String) -> Result(Nil, String) {
  simplifile.write(to: path, contents: contents) |> describe("write " <> path)
}

fn exists(path: String, complaint: String) -> Result(Nil, String) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    _ -> Error(complaint)
  }
}

fn describe(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(Nil, String) {
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(error) ->
      Error("could not " <> what <> ": " <> simplifile.describe_error(error))
  }
}
