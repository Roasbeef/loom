//// Compile-service tests: the deterministic, security-critical workspace
//// preparation (pinned module name, prelude-only manifest, generated
//// entry) with the build execution behind a fake `Builder`. A real
//// hermetic `gleam build` is exercised by `make e2e` on a target kernel;
//// here the seam is faked so the plumbing is proved without a toolchain.

import broker/budget
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/vet
import codemode/vet/policy
import core/clock
import core/ids
import gleam/result
import gleam/string
import simplifile

// The build phase the compile service is handed. It is derived from an
// execution identity rather than assembled here, because that is the only
// way to obtain one.
fn build_phase() -> identity.PhaseIdentity {
  identity.for_execution(
    op_id: op_id(),
    step_id: "step-1",
    budget: budget.Budget(max_outstanding: 2, deadline_ms: 1_700_000_120_000),
  )
  |> identity.build_phase
}

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 5)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

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
  _phase: identity.PhaseIdentity,
  root: String,
  _generated: List(#(String, String)),
) -> compile.Built {
  compile.Built(
    result: Ok(compile.BuildProducts(
      beam_dir: root <> "/ebin",
      manifest_hash: "cafef00d",
    )),
    enforcement: enforcement.Reported(entries: ["bwrap"], degraded: False),
  )
}

pub fn compile_writes_program_under_pinned_name_test() {
  let root = fresh_root("pinned")
  let source = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      generated: [],
      build: ok_builder,
    )
  let compiled = compile.compile(vetted(source), config, build_phase())
  let assert Ok(artifact) = compiled.result
  assert compile.artifact_entry(artifact) == compile.entry_module
  assert compile.artifact_hash(artifact) == "cafef00d"
  // The build's jail travels with its products: a caller holding the
  // artifact holds what confined the build that made it.
  assert compiled.enforcement
    == enforcement.Reported(entries: ["bwrap"], degraded: False)
  // The submitted source is written under the compile-service-controlled
  // module name, not one the source chose — the structural close on the
  // prelude-shadowing / self-naming attack.
  let assert Ok(written) =
    simplifile.read(root <> "/src/" <> compile.program_module <> ".gleam")
  assert written == source
}

pub fn compile_prepares_a_writable_temporary_directory_test() {
  let root = fresh_root("tmpdir")
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      generated: [],
      build: ok_builder,
    )
  let assert Ok(_artifact) =
    compile.compile(vetted("pub fn main() { 1 }\n"), config, build_phase()).result
  assert simplifile.is_directory(root <> "/tmp") == Ok(True)
}

pub fn generated_entry_boots_the_pinned_program_test() {
  let root = fresh_root("entry")
  let source = "pub fn main() { 1 }\n"
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      generated: [],
      build: ok_builder,
    )
  let assert Ok(_artifact) =
    compile.compile(vetted(source), config, build_phase()).result
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
      generated: [],
      build: ok_builder,
    )
  let assert Ok(_artifact) =
    compile.compile(vetted("pub fn main() { 1 }\n"), config, build_phase()).result
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
  // no entry carries a range. The extension prelude and `gleam_json` are
  // in it too — one table serves every seam, because `seed.verify`
  // compares this rendering against the seed's byte for byte and a second
  // table would be a second seed (see `compile.default_dependencies`).
  assert string.contains(
    toml,
    "[dependencies]\ngleam_stdlib = \""
      <> compile.stdlib_version
      <> "\"\ngleam_json = \""
      <> compile.json_version
      <> "\"\ncap = { path = \""
      <> compile.prelude_path
      <> "\" }\next = { path = \""
      <> compile.ext_path
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
  assert !string.starts_with(compile.ext_path, "/")
  assert !string.starts_with(compile.ext_path, "..")
}

pub fn build_rejection_is_in_band_test() {
  let root = fresh_root("reject")
  let failing = fn(_phase, _root, _generated) {
    compile.Built(
      result: Error(compile.BuildRejected(
        diagnostics: "type error: expected Int",
      )),
      enforcement: enforcement.Reported(entries: ["bwrap"], degraded: False),
    )
  }
  let config =
    compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      generated: [],
      build: failing,
    )
  let compiled =
    compile.compile(vetted("pub fn main() { 1 }\n"), config, build_phase())
  let assert Error(compile.BuildRejected(diagnostics:)) = compiled.result
  assert string.contains(diagnostics, "type error")
  // A program the compiler refused still ran a real jailed build, and the
  // report says so.
  assert compiled.enforcement
    == enforcement.Reported(entries: ["bwrap"], degraded: False)
}

pub fn workspace_setup_failure_is_reported_test() {
  // A build root whose parent cannot exist forces a setup failure rather
  // than a crash.
  let config =
    compile.CompileConfig(
      build_root: "/proc/nonexistent/deny/build-root",
      dependencies: compile.default_dependencies(),
      generated: [],
      build: ok_builder,
    )
  let compiled =
    compile.compile(vetted("pub fn main() { 1 }\n"), config, build_phase())
  assert result.is_error(compiled.result)
  let assert Error(compile.WorkspaceSetupFailed(_)) = compiled.result
  // The builder was never reached, so nothing is claimed about a jail.
  let assert enforcement.Unreported(why) = compiled.enforcement
  assert string.contains(why, "never dispatched")
}

pub fn the_local_service_prepares_before_the_existing_builder_test() {
  let root = fresh_root("local-service")
  let source = "import cap/report\npub fn main() { report.text(\"local\") }\n"
  let generated = [#("cap/mcp/selected", "generated source")]
  let configured =
    compile.local_service(
      compile.CompileConfig(
        build_root: root,
        dependencies: compile.default_dependencies(),
        generated:,
        build: fn(phase, prepared, modules) {
          assert phase == build_phase()
          assert prepared == root
          assert modules == generated
          assert simplifile.read(
              root <> "/src/" <> compile.program_module <> ".gleam",
            )
            == Ok(source)
          assert simplifile.read(
              root <> "/src/" <> compile.entry_module <> ".gleam",
            )
            == Ok(compile.entry_source())
          assert simplifile.read(root <> "/gleam.toml")
            == Ok(compile.project_toml(compile.default_dependencies()))
          ok_builder(phase, prepared, modules)
        },
      ),
    )
  let compiled =
    configured.compile(compile.CompileRequest(
      vetted: vetted(source),
      dependencies: configured.dependencies,
      generated: configured.generated,
      identity: build_phase(),
    ))
  let assert Ok(compile.Artifact(build_root:, beam_dir:, ..)) = compiled.result
    as "the local service must return local build products"
  assert build_root == root
  assert beam_dir == root <> "/ebin"
  assert compiled.enforcement
    == enforcement.Reported(entries: ["bwrap"], degraded: False)
}

pub fn workspace_preparation_has_no_builder_or_phase_authority_test() {
  let root = fresh_root("physical-workspace")
  let source =
    "import cap/report\npub fn main() { report.text(\"prepared\") }\n"
  let dependencies = compile.default_dependencies()
  let assert Ok(prepared) =
    compile.prepare_workspace(vetted(source), root, dependencies)
    as "fixed source preparation must need no Builder or PhaseIdentity"
  assert prepared == root
  assert simplifile.read(root <> "/src/loom_program.gleam") == Ok(source)
  assert simplifile.read(root <> "/src/loom_satellite.gleam")
    == Ok(compile.entry_source())
  assert simplifile.read(root <> "/gleam.toml")
    == Ok(compile.project_toml(dependencies))
  assert simplifile.is_directory(root <> "/tmp") == Ok(True)
  assert simplifile.is_directory(root <> "/ebin") == Ok(False)
}
