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
