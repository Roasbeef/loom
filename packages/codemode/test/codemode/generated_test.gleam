//// The generated capability modules (issue #106): which of a host's
//// `cap/mcp/<server>` façades reach a build, and where they land.
////
//// Two properties, and they are separable on purpose. `execute` decides
//// *which* modules a build is given — the vetted program's own imports
//// and nothing else, so a configured server a program never names costs
//// it no build time. `build` decides *where* they go — inside the
//// vendored prelude, after the seed clone that would otherwise delete
//// them.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/build
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/satellite
import codemode/seed
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import simplifile

const t = 1_700_000_000_000

// Two servers' worth of generated source. The bodies are not real
// façades — nothing compiles here — but the *names* are the ones the
// vetting allowlist and the import filter both key on.
const alpha_module = "cap/mcp/alpha"

const beta_module = "cap/mcp/beta"

const alpha_source = "// alpha\n"

const beta_source = "// beta\n"

fn table() -> List(#(String, String)) {
  [#(alpha_module, alpha_source), #(beta_module, beta_source)]
}

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 17)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process has a working directory"
  let dir = here <> "/build/cmtest/generated-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the fixture directory must be creatable"
  dir
}

// The two façade modules plus the vocabulary they import, on top of the
// workspace seam — the same widening `client/codemode.seam_allowlist`
// performs on a host with servers configured.
fn allowing_both() -> vet_policy.VetPolicy {
  vet_policy.default()
  |> vet_policy.allow("cap/mcp")
  |> vet_policy.allow(alpha_module)
  |> vet_policy.allow(beta_module)
}

// --- which modules reach the build ----------------------------------------

// A builder that reports the generated table it was handed and then
// fails the build: the filter is upstream of the compiler, so nothing
// here needs a compiler.
fn recording_builder(seen: Subject(List(String))) -> compile.Builder {
  fn(_phase, _root, generated: List(#(String, String))) {
    process.send(seen, list.map(generated, fn(module) { module.0 }))
    compile.Built(
      result: Error(compile.BuildRejected(diagnostics: "not built")),
      enforcement: enforcement.Unreported("no jail ran in this suite"),
    )
  }
}

fn exec_config(dir: String, build: compile.Builder) -> codemode.ExecConfig {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  codemode.ExecConfig(
    vet_policy: allowing_both(),
    compile: compile.CompileConfig(
      build_root: dir <> "/build",
      dependencies: compile.default_dependencies(),
      generated: table(),
      build:,
    ),
    broker: started,
    identity: identity.for_execution(
      op_id: op_id(),
      step_id: "step-1",
      budget: budget.Budget(max_outstanding: 4, deadline_ms: t + 20_000),
    ),
    satellite: satellite.SatelliteConfig(
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [#("PATH", "/usr/bin")],
      cwd: "/work",
      cap_socket_path: dir <> "/sock",
      entropy: token.production_entropy(),
      clock: clock.fixed(at: t),
      write_token_file: satellite.private_token_writer(dir),
      unlink_token_file: satellite.unlink_token_file,
      router: satellite.default_router,
      ceilings: [],
      call_timeout_ms: 3000,
    ),
    // Never called: every program here stops at the build.
    launch: fn(_spec) { Error("no satellite in this suite") },
  )
}

fn given_to_the_build(dir: String, source: String) -> List(String) {
  let seen = process.new_subject()
  let execution =
    codemode.execute(source, exec_config(dir, recording_builder(seen)))
  let assert codemode.CompileFailed(_error) = execution.outcome
    as "the recording builder always fails the build"
  let assert Ok(modules) = process.receive(seen, within: 1000)
    as "the builder ran, so it reported what it was handed"
  modules
}

pub fn a_program_importing_no_generated_module_gets_none_test() {
  let dir = fresh_dir("none")
  let source =
    "import cap/report\n\npub fn main() -> report.Outcome {\n"
    <> "  report.text(\"nothing\")\n}\n"
  assert given_to_the_build(dir, source) == []
}

pub fn a_program_gets_the_server_it_imported_and_no_other_test() {
  let dir = fresh_dir("alpha")
  let source =
    "import cap/mcp/alpha\nimport cap/report\n\n"
    <> "pub fn main() -> report.Outcome {\n  report.text(\"a\")\n}\n"
  let given = given_to_the_build(dir, source)
  assert given == [alpha_module]
  assert !list.contains(given, beta_module)
}

pub fn a_program_importing_both_gets_both_test() {
  let dir = fresh_dir("both")
  let source =
    "import cap/mcp/alpha\nimport cap/mcp/beta\nimport cap/report\n\n"
    <> "pub fn main() -> report.Outcome {\n  report.text(\"ab\")\n}\n"
  assert given_to_the_build(dir, source) == [alpha_module, beta_module]
}

// --- where they land -------------------------------------------------------

pub fn a_generated_module_is_written_inside_the_vendored_prelude_test() {
  assert compile.generated_path("/b", alpha_module)
    == "/b/vendor/cap/src/cap/mcp/alpha.gleam"
}

// The write happens on the far side of the seed clone, which deletes
// `vendor/` wholesale — so this test is the one that would catch the
// modules being written before it.
pub fn the_builder_installs_the_generated_modules_after_the_clone_test() {
  let root = fresh_dir("install-root")
  let seed_root = fresh_dir("install-seed")
  prepare_seed(seed_root)
  let builder = build.builder(build_config(seed_root))
  // The clearance is refused (there is no helper), which is fine: the
  // install runs before the build is dispatched at all.
  let built = builder(build_phase(), root, [#(alpha_module, alpha_source)])
  let assert Error(_refused) = built.result
    as "the idle broker refuses the clearance"

  let assert Ok(written) =
    simplifile.read(compile.generated_path(root, alpha_module))
    as "the imported module is inside the cloned prelude"
  assert written == alpha_source
  // The clone really did happen first: the seed's own vendored file is
  // there beside it.
  assert simplifile.is_file(root <> "/vendor/cap/src/cap/report.gleam")
    == Ok(True)
  // And a module the program did not import was never handed over, so
  // nothing wrote it.
  assert simplifile.is_file(compile.generated_path(root, beta_module))
    != Ok(True)
}

// A seed that satisfies `seed.verify` and has a vendored prelude to
// clone. Nothing is built from it — the clearance never runs.
fn prepare_seed(seed_root: String) -> Nil {
  let assert Ok(Nil) =
    seed.prepare(
      root: seed_root,
      vendored: [],
      dependencies: compile.default_dependencies(),
    )
    as "the seed layout must be writable"
  let assert Ok(Nil) =
    simplifile.create_directory_all(seed_root <> "/vendor/cap/src/cap")
    as "the seed carries a vendored prelude"
  let assert Ok(Nil) =
    simplifile.write(
      to: seed_root <> "/vendor/cap/src/cap/report.gleam",
      contents: "// the seed's own\n",
    )
    as "the vendored prelude has a source file"
  let assert Ok(Nil) =
    simplifile.create_directory_all(seed_root <> "/build/packages")
    as "the seed carries a resolved package cache"
  let assert Ok(Nil) =
    simplifile.write(
      to: seed_root <> "/build/packages/packages.toml",
      contents: "",
    )
    as "the package cache is resolved"
  let assert Ok(Nil) =
    simplifile.write(to: seed_root <> "/manifest.toml", contents: "")
    as "the seed has a resolved manifest"
  Nil
}

fn build_config(seed_root: String) -> build.BuildConfig {
  build.BuildConfig(
    broker: idle_broker(),
    seed_root:,
    gleam_path: "/usr/local/bin/gleam",
    base_policy: policy.workspace_default("/work"),
    toolchain_roots: ["/"],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    dependencies: compile.default_dependencies(),
    timeout_ms: 60_000,
  )
}

fn idle_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

fn build_phase() -> identity.PhaseIdentity {
  identity.for_execution(
    op_id: op_id(),
    step_id: "step-1",
    budget: budget.Budget(max_outstanding: 2, deadline_ms: t + 120_000),
  )
  |> identity.build_phase
}
