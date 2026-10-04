//// Whole-service regressions: owner vetting precedes any physical request,
//// import selection and build identity survive the seam, and executor
//// artifacts remain references throughout owner orchestration.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/physical
import codemode/satellite
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/msgpack
import core/workspace
import gleam/erlang/process
import gleam/list
import gleam/string
import simplifile
import support/satellite_peer

const t = 1_700_000_000_000

const source =
  "import cap/report\nimport cap/mcp/alpha\npub fn main() { report.text(\"ok\") }\n"

fn execution_identity() -> identity.ExecIdentity {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(t), seed: 71))
  identity.for_execution(
    operation,
    "service-step",
    budget.Budget(max_outstanding: 4, deadline_ms: t + 30_000),
  )
  |> identity.with_own_build_ledger
  |> identity.widened_by([policy.GrantEnv("APPROVED")])
}

fn config(service: compile.CompileService) -> codemode.ExecConfig {
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(t),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the owner broker must start"
  codemode.ExecConfig(
    vet_policy: vet_policy.default() |> vet_policy.allow("cap/mcp/alpha"),
    compile: service,
    broker: owner,
    identity: execution_identity(),
    satellite: satellite.SatelliteConfig(
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [],
      cwd: "/work",
      cap_socket_path: "/work/cap.sock",
      entropy: token.production_entropy(),
      clock: clock.fixed(t),
      write_token_file: fn(_token) { Error("no physical token requested") },
      unlink_token_file: fn(_path) { Nil },
      router: satellite.default_router,
      ceilings: [],
      call_timeout_ms: 1000,
    ),
    launch: fn(_spec) { Error("no node requested") },
  )
}

fn service(run: fn(compile.CompileRequest) -> compile.Compiled) {
  compile.CompileService(
    dependencies: compile.default_dependencies(),
    generated: [#("cap/mcp/alpha", "alpha"), #("cap/mcp/beta", "beta")],
    compile: run,
  )
}

fn build_report() -> enforcement.Report {
  enforcement.Reported(entries: ["bwrap", "seccomp-net"], degraded: False)
}

fn remote_artifact(phase: identity.PhaseIdentity) -> compile.Artifact {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "the fixture session must be valid"
  let assert Ok(selected) = workspace.selector("executor-a", "project")
    as "the fixture registration must be valid"
  let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
    as "the fixture authority epochs must be valid"
  let assert Ok(step) = workspace.step(identity.step_id(phase))
    as "the generated step must be bounded"
  compile.ExecutorArtifact(
    scope: workspace.scope(session, bound),
    operation: identity.op_id(phase),
    step:,
    request_id: "00000000-0000-7000-8000-000000000002",
    request_digest: "compile-content",
    artifact_id: "issued-build-1",
    contract_digest: "seed-contract",
    entry_module: compile.entry_module,
    manifest_hash: "sha256-physical-build",
  )
}

pub fn rejected_source_never_invokes_the_physical_service_test() {
  let seen = process.new_subject()
  let configured =
    config(
      service(fn(_request) {
        process.send(seen, Nil)
        compile.Compiled(
          Error(compile.BuildUnavailable("unexpected")),
          build_report(),
        )
      }),
    )
  let execution =
    codemode.execute(
      "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n",
      configured,
    )
  let assert codemode.VetRejected(..) = execution.outcome
    as "the owner must reject foreign functions before requesting resources"
  assert process.receive(seen, 0) == Error(Nil)
  broker.stop(configured.broker)
}

pub fn valid_source_calls_the_whole_service_with_selected_imports_and_phase_test() {
  let seen = process.new_subject()
  let configured =
    config(
      service(fn(request) {
        process.send(seen, request)
        compile.Compiled(Ok(remote_artifact(request.identity)), build_report())
      }),
    )
  let executed = codemode.execute(source, configured)
  let assert Ok(request) = process.receive(seen, 1000)
    as "the whole physical service must be invoked"
  assert vet.vetted_source(request.vetted) == source
  assert request.dependencies == compile.default_dependencies()
  assert request.generated == [#("cap/mcp/alpha", "alpha")]
  assert request.identity == identity.build_phase(configured.identity)
  assert identity.grants(request.identity) == []
  assert identity.grants(identity.run_phase(configured.identity))
    == [policy.GrantEnv("APPROVED")]
  assert executed.enforcement.build == build_report()
  let assert codemode.RunFailed(satellite.TokenFileFailed(..)) =
    executed.outcome
    as "the fake service must reach the owner satellite without local compile preparation"
  broker.stop(configured.broker)
}

pub fn executor_artifact_crosses_owner_pipeline_without_local_source_writes_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture has a working directory"
  let root = here <> "/build/service-no-owner-preparation"
  let _ = simplifile.delete(root)
  let seen = process.new_subject()
  let original =
    config(
      service(fn(request) {
        compile.Compiled(Ok(remote_artifact(request.identity)), build_report())
      }),
    )
  let configured =
    codemode.ExecConfig(
      ..original,
      satellite: satellite.SatelliteConfig(
        ..original.satellite,
        write_token_file: satellite.private_token_writer(root <> "/token"),
        unlink_token_file: satellite.unlink_token_file,
      ),
      launch: fn(spec: satellite.LaunchSpec) {
        process.send(seen, #(spec.artifact, spec.identity))
        satellite_peer.launcher(fn(peer) {
          satellite_peer.send_outcome(
            peer,
            msgpack.StringValue("service complete"),
          )
        })(spec)
      },
    )
  let executed = codemode.execute(source, configured)
  let assert codemode.Ran(artifact:, ..) = executed.outcome
    as "the owner must carry an executor artifact without resolving it locally"
  let assert compile.ExecutorArtifact(..) = artifact
    as "the issued artifact reference must survive the owner pipeline"
  let assert Ok(#(launched_artifact, phase)) = process.receive(seen, 1000)
    as "the launch seam must receive the original artifact and run phase"
  assert launched_artifact == artifact
  assert phase == identity.run_phase(configured.identity)
  assert compile.artifact_hash(artifact) == "sha256-physical-build"
  assert !list.any(["/src", "/gleam.toml", "/manifest.toml"], fn(path) {
    case simplifile.exists(root <> path, follow_links: False) {
      Ok(present) -> present
      Error(_) -> False
    }
  })
  broker.stop(configured.broker)
}

pub fn local_launcher_refuses_an_executor_reference_before_any_resources_test() {
  let seen = process.new_subject()
  let phase = identity.run_phase(execution_identity())
  let artifact = remote_artifact(phase)
  let launched =
    satellite.LaunchSpec(
      artifact:,
      token_path: "/path-never-created/token",
      cap_socket_path: "/path-never-created/socket",
      identity: phase,
      base_policy: policy.workspace_default("/work"),
      env: [],
      cwd: "/work",
      wire: process.new_subject(),
    )
  let configured =
    launch.LaunchConfig(
      runner: physical.Runner(
        clear: fn(_call, _events) {
          process.send(seen, Nil)
          Error(broker.BrokerUnavailable)
        },
        abort_step: fn(_operation, _step) { process.send(seen, Nil) },
      ),
      clock: clock.fixed(t),
      erl_path: "/usr/bin/erl",
      host_mounts: [],
      demand: exec.BestEffort,
      accept_timeout_ms: 1000,
    )
  let assert Error(reason) = launch.launcher(configured)(launched)
    as "a local launcher must never interpret executor artifact identity as a pathname"
  assert string.contains(reason, "executor artifact")
  assert launch.node_argv("/usr/bin/erl", artifact) == Error(reason)
  assert launch.node_requirements(launched, [], t) == Error(reason)
  assert launch.node_call(configured, launched, launched.base_policy)
    == Error(reason)
  assert process.receive(seen, 0) == Error(Nil)
}
