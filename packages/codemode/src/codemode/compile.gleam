//// The hermetic compile service — the second stop on the code-mode
//// pipeline, between vetting and the satellite (design §6.3, the pipeline
//// diagram in `docs/architecture/code-mode.md`).
////
//// # What this service guarantees
////
//// It compiles a `vet.Vetted` — never a raw `String`, so only source that
//// passed the lint can reach a build — against exactly the pinned prelude
//// and the standard library, inside a kernel jail with the network off,
//// and produces an `Artifact`: a directory of `.beam` files, the entry
//// module's name, and a manifest hash. The harness only ever loads a
//// binary it built itself from source it vetted.
////
//// Two structural defences live here, both invisible to the vetting lint:
////
//// 1. **The submitted program is written under a compile-service-controlled,
////    pinned module name** (`program_module`, e.g. `loom_program`), never a
////    name the source chose. A Gleam module is named by its file path, and
////    the submitted source does not contain its own module name — so the
////    lint structurally cannot see a self-naming or prelude-shadowing
////    attack ("declare my own `cap/fs`"). Pinning the file path closes it:
////    whatever the program calls itself, on disk it is `loom_program`, and
////    the real `cap/fs` is the only `cap/fs` in the build.
////
//// 2. **The generated build pins exactly the vendored prelude and stdlib and
////    nothing else** (design rule 3). The `gleam.toml` this service writes
////    lists only those dependencies, and the build runs offline in the
////    jail, so no other package at any version can enter the build even if
////    the source named one.
////
//// # The generated satellite entry
////
//// The service also generates a tiny entry module (`entry_module`, e.g.
//// `loom_satellite`) that imports the pinned prelude's boot runtime and the
//// program, and hands the program's `main` to `cap/runtime.boot`. The exact
//// `runtime.boot` shape is a `cap/runtime` contract owned by the parallel
//// `packages/cap` agent; until it lands, this generates to the documented
//// shape and the integration build is gated (see the package `CLAUDE.md`).
////
//// # The build seam
////
//// Running `gleam build` is an *effect*, so it is injected as a `Builder`.
//// Production wires it to a network-off `broker.clear_call` that runs the
//// build inside the jail; deterministic tests inject a fake that returns
//// canned products; an e2e on a real kernel wires a genuine offline build.
//// A build or type error is a structured `CompileError` returned in-band —
//// the type checker doubles as the tool-argument validator, so a
//// mistyped capability call is rejected here, cheaply, before any
//// satellite spins up — never a crash.

import codemode/vet.{type Vetted}
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The pinned module name the submitted program is written under. Not a
/// name the source chose — see the module doc, defence 1.
pub const program_module = "loom_program"

/// The generated satellite entry module's name.
pub const entry_module = "loom_satellite"

/// A compiled code-mode program ready to run in a satellite node.
pub type Artifact {
  Artifact(
    /// The build workspace root (where source and `gleam.toml` were
    /// written and the build ran).
    build_root: String,
    /// The directory holding the compiled `.beam` set.
    beam_dir: String,
    /// The satellite entry module's name (`entry_module`).
    entry_module: String,
    /// A hash over the compiled artifact, for auditing and for the durable
    /// entry the orchestrator persists.
    manifest_hash: String,
  )
}

/// Why compilation did not produce an artifact. Every variant is returned
/// in-band; none is a crash.
pub type CompileError {
  /// Preparing the hermetic workspace failed — a temp directory or a
  /// source/manifest file could not be created.
  WorkspaceSetupFailed(reason: String)
  /// The build ran and the compiler rejected the program: a type error or
  /// any other build diagnostic. This doubles as tool-argument
  /// validation, caught before a satellite spins up.
  BuildRejected(diagnostics: String)
  /// The build could not be run at all — the jail refused it, the helper
  /// died, or the injected builder reported the environment unavailable.
  BuildUnavailable(reason: String)
  /// The build claimed success but produced no usable `.beam` set.
  ArtifactIncomplete(reason: String)
}

/// What a successful build produced: where the `.beam` files landed and a
/// hash pinning them. Computed by the `Builder`, which is the only party
/// that sees the real build outputs.
pub type BuildProducts {
  BuildProducts(beam_dir: String, manifest_hash: String)
}

/// The build seam. Given the prepared build root, it runs the offline
/// build and returns the products or a structured error. Production wraps
/// a network-off `broker.clear_call`; tests inject a fake. See the module
/// doc.
pub type Builder =
  fn(String) -> Result(BuildProducts, CompileError)

/// One pinned build dependency. The generated `gleam.toml` lists only
/// these, so the build sees exactly the prelude and stdlib (design rule 3).
pub type Dependency {
  /// A hex dependency pinned by version requirement (e.g. `gleam_stdlib`).
  HexDependency(name: String, requirement: String)
  /// A path dependency (the vendored prelude, `cap`).
  PathDependency(name: String, path: String)
}

/// Everything the compile service needs beyond the vetted source.
pub type CompileConfig {
  CompileConfig(
    /// A fresh, empty directory the caller created for this build.
    build_root: String,
    /// The dependencies to pin — nothing else may enter the build. Use
    /// `default_dependencies` for the production set.
    dependencies: List(Dependency),
    /// The injected build seam.
    build: Builder,
  )
}

/// The production dependency set: the standard library plus the vendored
/// capability prelude at `prelude_path` (usually `packages/cap`), and
/// nothing else.
pub fn default_dependencies(prelude_path: String) -> List(Dependency) {
  [
    HexDependency(name: "gleam_stdlib", requirement: ">= 0.34.0 and < 2.0.0"),
    PathDependency(name: "cap", path: prelude_path),
  ]
}

/// Compiles a vetted program into an `Artifact`.
///
/// Prepares the hermetic workspace — writes the program under the pinned
/// module name, generates the satellite entry, and pins exactly the given
/// dependencies — then runs the injected build. A build/type error comes
/// back as `BuildRejected`; nothing crashes.
pub fn compile(
  vetted: Vetted,
  config: CompileConfig,
) -> Result(Artifact, CompileError) {
  let root = config.build_root
  let src_dir = root <> "/src"
  use _ <- result.try(make_directory(src_dir))
  // Defence 1: the program is written under the pinned name, not one the
  // source chose. A Gleam module is named by its path, so this is the only
  // place the submitted module's name is decided.
  use _ <- result.try(write_source(
    src_dir <> "/" <> program_module <> ".gleam",
    vet.vetted_source(vetted),
  ))
  use _ <- result.try(write_source(
    src_dir <> "/" <> entry_module <> ".gleam",
    entry_source(),
  ))
  // Defence 2: the manifest pins exactly the prelude and stdlib.
  use _ <- result.try(write_source(
    root <> "/gleam.toml",
    gleam_toml(config.dependencies),
  ))
  use products <- result.try(config.build(root))
  Ok(Artifact(
    build_root: root,
    beam_dir: products.beam_dir,
    entry_module: entry_module,
    manifest_hash: products.manifest_hash,
  ))
}

/// The generated satellite entry module source. It imports the pinned
/// prelude's boot runtime (`cap/runtime`) and the program, and hands the
/// program's `main` to `runtime.run`, the production convenience that reads
/// the cap token from `LOOM_CAP_TOKEN_FILE`, connects the cap socket named
/// by `LOOM_CAP_SOCK`, installs the capability channel, runs `main`, and
/// marshals its `cap/report.Outcome` back over the socket as the terminal
/// `outcome` frame (the J3a contract).
///
/// The vetted program module must expose `pub fn main() -> report.Outcome`;
/// the pinned module name (`program_module`) is used in both the import and
/// the call.
pub fn entry_source() -> String {
  "//// Generated by codemode/compile. Do not edit.\n"
  <> "//// The satellite entry: boot the capability runtime, run the program.\n\n"
  <> "import cap/runtime\n"
  <> "import "
  <> program_module
  <> "\n\n"
  <> "pub fn main() -> Nil {\n"
  <> "  runtime.run("
  <> program_module
  <> ".main)\n"
  <> "}\n"
}

// Renders a `gleam.toml` that pins exactly `dependencies` and nothing
// else. The narrow dependency table plus the offline build is the
// pinning mechanism (design rule 3).
fn gleam_toml(dependencies: List(Dependency)) -> String {
  let lines =
    list.map(dependencies, fn(dependency) {
      case dependency {
        HexDependency(name:, requirement:) ->
          name <> " = \"" <> requirement <> "\""
        PathDependency(name:, path:) ->
          name <> " = { path = \"" <> path <> "\" }"
      }
    })
  "name = \"loom_codemode_program\"\n"
  <> "version = \"0.0.0\"\n"
  <> "gleam = \">= 1.11.0\"\n\n"
  <> "[dependencies]\n"
  <> string.join(lines, "\n")
  <> "\n"
}

// --- filesystem helpers, mapping simplifile faults to CompileError -------

fn make_directory(path: String) -> Result(Nil, CompileError) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(error) {
    WorkspaceSetupFailed(
      "could not create " <> path <> ": " <> simplifile.describe_error(error),
    )
  })
}

fn write_source(path: String, contents: String) -> Result(Nil, CompileError) {
  simplifile.write(to: path, contents: contents)
  |> result.map_error(fn(error) {
    WorkspaceSetupFailed(
      "could not write " <> path <> ": " <> simplifile.describe_error(error),
    )
  })
}
