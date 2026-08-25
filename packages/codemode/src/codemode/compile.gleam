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
////    jail, so no *third-party* package at any version can enter the build
////    even if the source named one.
////
////    Be precise about the reach of this. `cap` itself depends on
////    `gleam_erlang`, `gleam_otp`, and `core`, so their compiled modules
////    are unavoidably present — `cap` needs them at runtime. What the
////    generated project does is make them **not direct dependencies**, and
////    the production builder compiles with `--warnings-as-errors`, which
////    turns Gleam's "transitive dependency imported" warning into a hard
////    compile error. So `import gleam/erlang/process`, `import
////    gleam/otp/actor`, and `import core/msgpack` are now refused by the
////    *compiler*, not only by vetting (M4 triage CH-F1, closed to the
////    extent a compile-time gate can close it). Two honest limits: the
////    modules remain loadable at run time by a hand-written `.beam`, which
////    is the jail's problem and not the build's; and `gleam_stdlib` is a
////    direct dependency, so `gleam/io` and friends still compile and
////    vetting's allowlist remains their only gate.
////
//// # The generated satellite entry
////
//// The service also generates a tiny entry module (`entry_module`, e.g.
//// `loom_satellite`) that imports the pinned prelude's boot runtime and the
//// program and hands the program's `main` to `cap/runtime.run`. That shape
//// is a `cap/runtime` contract ("Generated entry contract (pin this)"), to
//// be emitted verbatim; a test pins this generator against it.
////
//// # The build seam
////
//// Running `gleam build` is an *effect*, so it is injected as a `Builder`.
//// Production wires it to `codemode/build`, a network-off
//// `broker.clear_call` that runs the build inside the jail against a
//// pre-seeded package cache; deterministic tests inject a fake that
//// returns canned products; `make e2e-codemode` runs the genuine offline
//// build on a real helper.
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

/// The generated project's package name. Fixed, so a builder can find and
/// discard a seed's placeholder artifacts for it before the real build.
pub const package_name = "loom_codemode_program"

/// Where the prelude is vendored inside a build root. Relative on purpose:
/// Gleam records local dependency paths in `manifest.toml` relative to the
/// project root and re-resolves (which needs the network) when they do not
/// match, so a build root that can be prepared at any depth must carry its
/// prelude at a fixed *relative* location rather than point at one
/// elsewhere on the host.
pub const prelude_path = "vendor/cap"

/// The exact standard-library version every code-mode program is built
/// against. A single version, never a range: an offline build cannot
/// resolve a range, and "deterministic" is the whole point of pinning
/// (M4 triage CH-F2).
pub const stdlib_version = "1.0.5"

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

/// The production dependency set: exactly one standard-library version
/// and the prelude vendored inside the build root, and nothing else.
///
/// Both are pinned rather than ranged. A range would need version
/// resolution, resolution needs Hex, and the build runs with the network
/// off — so a range is not merely loose here, it does not build at all.
pub fn default_dependencies() -> List(Dependency) {
  [
    HexDependency(name: "gleam_stdlib", requirement: stdlib_version),
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
    project_toml(config.dependencies),
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

/// Renders the `gleam.toml` that pins exactly `dependencies` and nothing
/// else. The narrow dependency table plus the offline build is the
/// pinning mechanism (design rule 3).
///
/// Public because the package cache a hermetic build runs against has to
/// be prepared from the *same* project file: a seed whose dependency table
/// differs by one byte resolves differently, and the builder compares the
/// two before it will run offline.
pub fn project_toml(dependencies: List(Dependency)) -> String {
  let lines =
    list.map(dependencies, fn(dependency) {
      case dependency {
        HexDependency(name:, requirement:) ->
          name <> " = \"" <> requirement <> "\""
        PathDependency(name:, path:) ->
          name <> " = { path = \"" <> path <> "\" }"
      }
    })
  "name = \""
  <> package_name
  <> "\"\n"
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
