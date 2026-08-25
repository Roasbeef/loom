//// Compile-service tests: the deterministic, security-critical workspace
//// preparation (pinned module name, prelude-only manifest, generated
//// entry) with the build execution behind a fake `Builder`. A real
//// hermetic `gleam build` is exercised by `make e2e` on a target kernel;
//// here the seam is faked so the plumbing is proved without a toolchain.

import codemode/compile
import codemode/vet
import codemode/vet/policy
import gleam/result
import gleam/string
import simplifile

fn vetted(source: String) -> vet.Vetted {
  let assert vet.Passed(vetted) = vet.vet(source, policy.default())
  vetted
}

// A fresh, empty build root under the package build dir.
fn fresh_root(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let root = here <> "/build/cmtest/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

fn ok_builder(
  root: String,
) -> Result(compile.BuildProducts, compile.CompileError) {
  Ok(compile.BuildProducts(beam_dir: root <> "/ebin", manifest_hash: "cafef00d"))
}

pub fn compile_writes_program_under_pinned_name_test() {
  let root = fresh_root("pinned")
  let source = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      build: ok_builder,
    )
  let assert Ok(artifact) = compile.compile(vetted(source), config)
  assert artifact.entry_module == compile.entry_module
  assert artifact.manifest_hash == "cafef00d"
  // The submitted source is written under the compile-service-controlled
  // module name, not one the source chose — the structural close on the
  // prelude-shadowing / self-naming attack.
  let assert Ok(written) =
    simplifile.read(root <> "/src/" <> compile.program_module <> ".gleam")
  assert written == source
}

pub fn generated_entry_boots_the_pinned_program_test() {
  let root = fresh_root("entry")
  let source = "pub fn main() { 1 }\n"
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      build: ok_builder,
    )
  let assert Ok(_artifact) = compile.compile(vetted(source), config)
  let assert Ok(entry) =
    simplifile.read(root <> "/src/" <> compile.entry_module <> ".gleam")
  // The entry hands the pinned program's main to the cap boot runtime.
  assert string.contains(entry, "import cap/runtime")
  assert string.contains(entry, "import " <> compile.program_module)
  assert string.contains(
    entry,
    "runtime.run(" <> compile.program_module <> ".main)",
  )
}

pub fn manifest_pins_only_prelude_and_stdlib_test() {
  let root = fresh_root("pins")
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      build: ok_builder,
    )
  let assert Ok(_artifact) =
    compile.compile(vetted("pub fn main() { 1 }\n"), config)
  let assert Ok(toml) = simplifile.read(root <> "/gleam.toml")
  // Exactly the standard library and the vendored prelude are pinned —
  // nothing else can enter the offline build (design rule 3).
  assert string.contains(
    toml,
    "cap = { path = \"" <> compile.prelude_path <> "\" }",
  )
  assert !string.contains(toml, "glance")
  assert !string.contains(toml, "shellout")
  // One exact version, never a range. An offline build cannot resolve a
  // range, so a range here would not be merely loose: it would not build
  // (M4 triage CH-F2).
  assert string.contains(
    toml,
    "gleam_stdlib = \"" <> compile.stdlib_version <> "\"",
  )
  // The whole dependency table, byte for byte: nothing else is in it, and
  // no entry carries a range.
  assert string.contains(
    toml,
    "[dependencies]\ngleam_stdlib = \""
      <> compile.stdlib_version
      <> "\"\ncap = { path = \""
      <> compile.prelude_path
      <> "\" }\n",
  )
}

pub fn the_prelude_is_vendored_at_a_relative_path_test() {
  // Load-bearing, and easy to "tidy" into a bug: Gleam records a local
  // dependency's path in manifest.toml relative to the project root and
  // re-resolves — over the network — when it does not match. A build root
  // is created at whatever depth the session's scratch area lives, so only
  // a path *inside* the root is stable.
  assert !string.starts_with(compile.prelude_path, "/")
  assert !string.starts_with(compile.prelude_path, "..")
}

pub fn build_rejection_is_in_band_test() {
  let root = fresh_root("reject")
  let failing = fn(_root) {
    Error(compile.BuildRejected(diagnostics: "type error: expected Int"))
  }
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      build: failing,
    )
  let result = compile.compile(vetted("pub fn main() { 1 }\n"), config)
  let assert Error(compile.BuildRejected(diagnostics:)) = result
  assert string.contains(diagnostics, "type error")
}

pub fn workspace_setup_failure_is_reported_test() {
  // A build root whose parent cannot exist forces a setup failure rather
  // than a crash.
  let config =
    compile.CompileConfig(
      build_root: "/proc/nonexistent/deny/build-root",
      dependencies: compile.default_dependencies(),
      build: ok_builder,
    )
  let result = compile.compile(vetted("pub fn main() { 1 }\n"), config)
  assert result.is_error(result)
  let assert Error(compile.WorkspaceSetupFailed(_)) = result
}
