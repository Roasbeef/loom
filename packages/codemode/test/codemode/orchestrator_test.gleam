//// Orchestrator tests: `codemode.execute` threading a program through
//// vet → compile → run, short-circuiting at the first stage that refuses.
//// The compile build seam is faked and the satellite is driven by an
//// in-process peer, so the whole pipeline runs deterministically.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}

const t = 1_700_000_000_000

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 11)
  let #(op, _) = ids.mint_op(generator)
  op
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/orch-" <> name
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

fn exec_config(
  dir: String,
  build: compile.Builder,
  launch: satellite.Launcher,
) {
  let assert Ok(broker) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  codemode.ExecConfig(
    vet_policy: vet_policy.default(),
    compile: compile.CompileConfig(
      build_root: dir <> "/build",
      dependencies: compile.default_dependencies(),
      generated: [],
      build:,
    ),
    broker:,
    identity: identity.for_execution(
      op_id: op_id(),
      step_id: "step-1",
      budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000),
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
      precheck: satellite.no_precheck,
      router: satellite.default_router,
      ceilings: [],
      call_timeout_ms: 3000,
    ),
    launch:,
  )
}

fn ok_builder(
  _phase: identity.PhaseIdentity,
  root: String,
  _generated: List(#(String, String)),
) -> compile.Built {
  compile.Built(
    result: Ok(compile.BuildProducts(
      beam_dir: root <> "/ebin",
      manifest_hash: "beef",
    )),
    enforcement: build_report(),
  )
}

fn build_report() -> enforcement.Report {
  enforcement.Reported(entries: ["bwrap", "seccomp-net"], degraded: False)
}

fn node_report() -> enforcement.Report {
  enforcement.Reported(entries: ["bwrap", "landlock:abi=5"], degraded: False)
}

// A peer launcher standing in for one whose node's helper reported.
fn reporting_peer() -> satellite.Launcher {
  satellite_peer.reporting_launcher(finish_peer, node_report())
}

fn finish_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_outcome(ctx, msgpack.StringValue("orchestrated"))
}

pub fn vetting_rejection_short_circuits_test() {
  let dir = fresh_dir("reject")
  let config =
    exec_config(dir, ok_builder, satellite_peer.launcher(finish_peer))
  // An `@external` never reaches compile or the satellite.
  let source =
    "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n"
  let execution = codemode.execute(source, config)
  let assert codemode.VetRejected(rejections) = execution.outcome
  assert rejections != []
  // Nothing ran, and both stages say so in their own words rather than by
  // being absent from a list.
  let assert enforcement.Unreported(build) = execution.enforcement.build
  let assert enforcement.Unreported(node) = execution.enforcement.node
  assert string.contains(build, "vetting refused")
  assert string.contains(node, "vetting refused")
}

pub fn compile_failure_short_circuits_test() {
  let dir = fresh_dir("compile-fail")
  let failing = fn(_phase, _root, _generated) {
    compile.Built(
      result: Error(compile.BuildRejected(diagnostics: "type error")),
      enforcement: build_report(),
    )
  }
  let config = exec_config(dir, failing, reporting_peer())
  let source = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let execution = codemode.execute(source, config)
  let assert codemode.CompileFailed(compile.BuildRejected(_)) =
    execution.outcome
  // The build ran, so its report is carried; the node never did, and the
  // reason says which — not the same thing as an absent report.
  assert execution.enforcement.build == build_report()
  let assert enforcement.Unreported(node) = execution.enforcement.node
  assert string.contains(node, "did not compile")
}

pub fn full_pipeline_returns_ran_with_persistable_seam_test() {
  let dir = fresh_dir("ran")
  let config = exec_config(dir, ok_builder, reporting_peer())
  let source = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let execution = codemode.execute(source, config)
  let assert codemode.Ran(source: returned, artifact:, outcome:) =
    execution.outcome
  // The source and artifact hash come back for the runtime to persist as a
  // durable entry — the seam `execute` exposes rather than reaching into
  // storage itself.
  assert returned == source
  assert artifact.manifest_hash == "beef"
  assert outcome
    == satellite.Completed(value: msgpack.StringValue("orchestrated"))
  // The point of issue #5: a *healthy* run carries both stages' reports.
  // The node's used to arrive after the outcome had already been reported,
  // so the happy path — the one anyone actually runs — said nothing about
  // the jail the program ran in.
  assert execution.enforcement
    == enforcement.Enforcement(build: build_report(), node: node_report())
}

pub fn a_peer_that_ran_no_node_is_never_read_as_confined_test() {
  // The other half of the claim: honest reporting is not "always say
  // something reassuring". A launcher that jailed nothing must produce an
  // `Unreported`, never a layer list it did not apply.
  let dir = fresh_dir("unjailed")
  let config =
    exec_config(dir, ok_builder, satellite_peer.launcher(finish_peer))
  let source = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let execution = codemode.execute(source, config)
  let assert codemode.Ran(..) = execution.outcome
  let assert enforcement.Unreported(node) = execution.enforcement.node
  assert string.contains(node, "no jailed node")
}

// --- one rewrite for unused imports -----------------------------------------

const unused_int_diagnostics =
  "  Compiling loom_codemode_program
warning: Unused imported module
  ┌─ /b/src/loom_program.gleam:2:1
  │
2 │ import gleam/int
  │ ^^^^^^^^^^^^^^^^ This imported module is never used

Hint: You can safely remove it.

error: 1 warning generated.

Your project was compiled with the `--warnings-as-errors` flag.
Fix the warnings and try again."

const unused_int_source =
  "import cap/fs
import gleam/int
pub fn main() { fs.read(\"x\") }
"

// A builder that records the program it was given on every call and answers
// from a script, one answer per call, so a test can say how many builds ran
// and what each one compiled.
fn scripted_builder(
  answers: List(Result(compile.BuildProducts, compile.CompileError)),
  seen: process.Subject(String),
) -> compile.Builder {
  let remaining = process.new_subject()
  process.send(remaining, answers)
  fn(_phase, root, _generated) {
    let assert Ok(program) = simplifile.read(root <> "/src/loom_program.gleam")
    process.send(seen, program)
    let assert Ok([answer, ..rest]) = process.receive(remaining, 100)
    process.send(remaining, rest)
    compile.Built(result: answer, enforcement: build_report())
  }
}

fn built(hash: String) -> Result(compile.BuildProducts, compile.CompileError) {
  Ok(compile.BuildProducts(beam_dir: "ebin", manifest_hash: hash))
}

fn drain(seen: process.Subject(String)) -> List(String) {
  case process.receive(seen, 0) {
    Ok(program) -> [program, ..drain(seen)]
    Error(Nil) -> []
  }
}

pub fn unused_imports_alone_are_removed_and_rebuilt_once_test() {
  let seen = process.new_subject()
  let builder =
    scripted_builder(
      [
        Error(compile.BuildRejected(diagnostics: unused_int_diagnostics)),
        built("cafe"),
      ],
      seen,
    )
  let config = exec_config(fresh_dir("unused-ok"), builder, reporting_peer())
  let execution = codemode.execute(unused_int_source, config)

  // What ran is the rewritten program: it is what the second build
  // compiled, what the outcome carries as the program, and what the
  // artifact's address was taken over.
  let rewritten = "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
  let assert codemode.Ran(source:, artifact:, outcome: _) = execution.outcome
  assert source == rewritten
  assert artifact.manifest_hash == "cafe"
  assert drain(seen) == [unused_int_source, rewritten]
  assert execution.edits == ["removed unused import gleam/int (line 2)"]
}

pub fn a_rebuild_that_still_fails_reports_the_second_diagnostics_test() {
  let seen = process.new_subject()
  let builder =
    scripted_builder(
      [
        Error(compile.BuildRejected(diagnostics: unused_int_diagnostics)),
        Error(compile.BuildRejected(diagnostics: "type error on line 2")),
      ],
      seen,
    )
  let config = exec_config(fresh_dir("unused-fail"), builder, reporting_peer())
  let execution = codemode.execute(unused_int_source, config)

  // Exactly two builds: the rewrite is never repeated.
  let assert codemode.CompileFailed(compile.BuildRejected(diagnostics:)) =
    execution.outcome
  assert diagnostics == "type error on line 2"
  assert list.length(drain(seen)) == 2
  assert execution.edits == ["removed unused import gleam/int (line 2)"]
}

pub fn any_other_failure_is_not_rewritten_test() {
  let seen = process.new_subject()
  let builder =
    scripted_builder(
      [Error(compile.BuildRejected(diagnostics: "type error"))],
      seen,
    )
  let config = exec_config(fresh_dir("unused-other"), builder, reporting_peer())
  let execution = codemode.execute(unused_int_source, config)
  let assert codemode.CompileFailed(compile.BuildRejected(
    diagnostics: "type error",
  )) = execution.outcome
  assert drain(seen) == [unused_int_source]
  assert execution.edits == []
}

pub fn a_program_that_built_the_first_time_has_no_edits_test() {
  let config = exec_config(fresh_dir("no-edits"), ok_builder, reporting_peer())
  let execution = codemode.execute(unused_int_source, config)
  assert execution.edits == []
}

// An unused lambda argument, as the compiler reported it for this program.
const unused_arg_diagnostics =
  "  Compiling loom_codemode_program
warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:3:42
  │
3 │ pub fn main() { let _ = list.map([1], fn(e) { fs.read(\"x\") }) }
  │                                          ^ This argument is never used

Hint: You can ignore it with an underscore: `_e`.

error: 1 warning generated.

Your project was compiled with the `--warnings-as-errors` flag.
Fix the warnings and try again."

const unused_arg_source =
  "import cap/fs
import gleam/list
pub fn main() { let _ = list.map([1], fn(e) { fs.read(\"x\") }) }
"

pub fn an_unused_argument_is_underscored_and_rebuilt_once_test() {
  let seen = process.new_subject()
  let builder =
    scripted_builder(
      [
        Error(compile.BuildRejected(diagnostics: unused_arg_diagnostics)),
        built("beef"),
      ],
      seen,
    )
  let config = exec_config(fresh_dir("unused-arg"), builder, reporting_peer())
  let execution = codemode.execute(unused_arg_source, config)

  // The second build compiled the program with the argument underscored,
  // that program is what the outcome carries, and the edit is listed.
  let rewritten =
    "import cap/fs
import gleam/list
pub fn main() { let _ = list.map([1], fn(_e) { fs.read(\"x\") }) }
"
  let assert codemode.Ran(source:, artifact:, outcome: _) = execution.outcome
  assert source == rewritten
  assert artifact.manifest_hash == "beef"
  assert drain(seen) == [unused_arg_source, rewritten]
  assert execution.edits == ["renamed unused argument e to _e (line 3)"]
}
