//// Managed native provenance observed at the production broker dispatcher.
//// Real seed preparation and the real Unix launcher must reach clearance;
//// the recording dispatcher refuses physical execution only after observing it.

import broker/broker
import broker/budget
import broker/dispatch
import broker/exec
import broker/policy
import broker/token
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/physical
import codemode/satellite
import codemode/seed
import core/clock
import core/ids
import core/remote_tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/scratch
import tools/tool

const now = 1_700_000_000_000

fn parent(index: Int) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(now), 71)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, _) = ids.mint_entry(generator)
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "original:tools",
      index,
      string.repeat("a", 64),
      entry,
    )
    as "The original managed tool identity validates."
  key
}

fn pooled() -> budget.Budget {
  budget.Budget(max_outstanding: 4, deadline_ms: now + 30_000)
}

fn managed(index: Int) -> identity.ExecIdentity {
  identity.for_managed_execution(parent(index), budget: pooled())
}

fn refusing_owner(seen: Subject(dispatch.Dispatch)) -> broker.Broker {
  let assert Ok(owner) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(now),
      dispatcher: dispatch.Dispatcher(start: fn(call) {
        process.send(seen, call)
        Error(dispatch.NotStarted)
      }),
    )
    as "The real owner broker starts."
  owner
}

fn next(seen: Subject(dispatch.Dispatch)) -> dispatch.Dispatch {
  let assert Ok(call) = process.receive(seen, 2000)
    as "Preparation must reach the actual native dispatcher."
  call
}

fn assert_origin(
  call: dispatch.Dispatch,
  key: remote_tool.ToolKey,
  role: remote_tool.ChildRole,
) {
  let assert Some(origin) = call.context.origin
    as "The physical adapter must preserve managed provenance."
  assert remote_tool.child_tool(origin) == Ok(key)
  assert remote_tool.child_role(origin) == Ok(role)
  assert call.context.operation == remote_tool.operation(key)
  assert call.deadline_ms == pooled().deadline_ms
}

pub fn managed_derivations_preserve_parent_without_an_extra_budget_axis_test() {
  let key = parent(3)
  let short = budget.Budget(max_outstanding: 2, deadline_ms: now + 1000)
  let grant = policy.GrantNetwork(policy.NetworkFull)
  let derived =
    managed(3)
    |> identity.with_own_build_ledger
    |> identity.widened_by(grants: [grant])
    |> identity.under_budget(budget: short)
  let build_phase = identity.build_phase(derived)
  let run_phase = identity.run_phase(derived)
  let assert Ok(Some(build_origin)) = identity.command_origin(build_phase)
    as "The managed build has a native origin."
  let assert Ok(Some(run_origin)) = identity.command_origin(run_phase)
    as "The managed satellite has a distinct native origin."
  assert remote_tool.child_tool(build_origin) == Ok(key)
  assert remote_tool.child_tool(run_origin) == Ok(key)
  assert remote_tool.child_role(build_origin) == Ok(remote_tool.CompileCommand)
  assert remote_tool.child_role(run_origin) == Ok(remote_tool.SatelliteCommand)
  assert identity.grants(build_phase) == []
  assert identity.grants(run_phase) == [grant]
  assert identity.pooled_budget(build_phase) == short
  assert identity.pooled_budget(run_phase) == short
  assert identity.ledger_keys(derived)
    == [
      #(remote_tool.operation(key), "original:tools-build"),
      #(remote_tool.operation(key), "original:tools"),
    ]
  assert identity.ledger_keys(managed(3)) == identity.ledger_keys(managed(4))
}

pub fn local_phases_keep_unmanaged_clearance_test() {
  let local =
    identity.for_execution(
      op_id: remote_tool.operation(parent(0)),
      step_id: "original:tools",
      budget: pooled(),
    )
  assert identity.command_origin(identity.build_phase(local)) == Ok(None)
  assert identity.command_origin(identity.run_phase(local)) == Ok(None)
  let seen = process.new_subject()
  let owner = refusing_owner(seen)
  let config = build_config(owner, "/unused")
  let call = build.build_call(config, identity.build_phase(local), "/work")
  let events = process.new_subject()
  let assert Error(_) = physical.local(owner).clear(None, call, events)
    as "The controlled dispatcher refuses after clearance."
  assert next(seen).context.origin == None
  broker.stop(owner)
}

fn prepared_seed(name: String) -> String {
  let root = scratch.fresh(name)
  let assert Ok(Nil) = seed.prepare(root: root, vendored: [], dependencies: [])
    as "The fixture uses the production seed layout writer."
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/vendor")
    as "Seed cloning requires the vendored directory."
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/build/packages")
    as "Seed verification requires a package cache."
  let assert Ok(Nil) =
    simplifile.write(root <> "/build/packages/packages.toml", "")
    as "The controlled refusal needs layout but no compiler artifacts."
  let assert Ok(Nil) = simplifile.write(root <> "/manifest.toml", "")
    as "The resolved-manifest path exists before real preparation."
  root
}

fn build_config(owner: broker.Broker, seed_root: String) -> build.BuildConfig {
  build.BuildConfig(
    observe: tool.ignore_output(),
    runner: physical.local(owner),
    seed_root:,
    gleam_path: "/usr/bin/gleam",
    base_policy: policy.SandboxPolicy(
      ..policy.workspace_default("/"),
      readable_roots: ["/"],
      network: policy.NetworkFull,
    ),
    toolchain_roots: ["/"],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin"), #("TMPDIR", "/wrong")],
    dependencies: [],
    timeout_ms: 30_000,
  )
}

pub fn real_builder_preserves_original_parent_for_shared_and_split_ledgers_test() {
  let seed_root = prepared_seed("managed-native-seed")
  list.each(
    [managed(3), identity.with_own_build_ledger(managed(3))],
    fn(execution) {
      let seen = process.new_subject()
      let owner = refusing_owner(seen)
      let root =
        scratch.fresh(
          "managed-native-build-"
          <> identity.step_id(identity.build_phase(execution)),
        )
      let phase = identity.build_phase(execution)
      let config = build_config(owner, seed_root)
      let built = build.builder(config)(phase, root, [])
      let assert Error(compile.BuildUnavailable(_)) = built.result
        as "The recording dispatcher refuses the actual build command."
      let call = next(seen)
      assert_origin(call, parent(3), remote_tool.CompileCommand)
      assert call.context.step == identity.step_id(phase)
      let expected = build.build_call(config, phase, root)
      assert call.request.argv == expected.argv
      assert call.request.env == expected.env
      assert call.request.cwd == root
      assert call.request.demand == exec.BestEffort
      assert list.key_find(call.request.env, "TMPDIR") == Ok(root <> "/tmp")
      let assert Some(effective) = call.request.policy
        as "The owner broker composed the physical build policy."
      assert effective.network == policy.NetworkOff
      assert simplifile.is_directory(root <> "/vendor") == Ok(True)
      broker.stop(owner)
    },
  )
}

pub fn real_unix_launcher_preserves_original_satellite_parent_test() {
  let root = scratch.fresh("managed-native-launch")
  let seen = process.new_subject()
  let owner = refusing_owner(seen)
  let phase =
    managed(3)
    |> identity.widened_by(grants: [policy.GrantEnv("EXTRA")])
    |> identity.run_phase
  let spec =
    satellite.LaunchSpec(
      artifact: compile.Artifact(
        build_root: root,
        beam_dir: root <> "/ebin",
        entry_module: compile.entry_module,
        manifest_hash: "controlled-fixture",
      ),
      token_path: root <> "/token/cap-token",
      cap_socket_path: root <> "/sock/cap.sock",
      identity: phase,
      base_policy: policy.SandboxPolicy(
        ..policy.workspace_default(root),
        readable_roots: ["/"],
        env_allow: ["PATH", launch.sock_env, launch.token_env],
      ),
      env: [#("PATH", "/usr/bin"), #("EXTRA", "approved")],
      cwd: root,
      wire: process.new_subject(),
    )
  let config =
    launch.LaunchConfig(
      runner: physical.local(owner),
      clock: clock.fixed(now),
      erl_path: "/usr/bin/erl",
      host_mounts: [],
      demand: exec.BestEffort,
      accept_timeout_ms: 3000,
    )
  let assert Ok(connection) = launch.launcher(config)(spec)
    as "The real Unix listener must start before native clearance."
  let call = next(seen)
  assert_origin(call, parent(3), remote_tool.SatelliteCommand)
  assert call.context.step == "original:tools"
  let assert Ok(argv) = launch.node_argv(config.erl_path, spec.artifact)
    as "The local artifact admits the exact native node argv."
  assert call.request.argv == argv
  assert call.request.env == launch.node_env(spec)
  assert call.request.cwd == root
  let assert Some(effective) = call.request.policy
    as "The owner composed the satellite's physical policy."
  assert list.contains(effective.env_allow, "EXTRA")
  let assert enforcement.Unreported(_) = connection.destroy()
    as "The refused dispatcher cannot report successful kernel enforcement."
  assert simplifile.exists(spec.cap_socket_path, follow_links: False)
    == Ok(False)
  broker.stop(owner)
}

/// The origin-bearing adapter retains both existing cancellation routes.
pub fn managed_clearance_preserves_call_cancel_and_step_abort_test() {
  let seen = process.new_subject()
  let cancelled = process.new_subject()
  let guarantor = process.spawn_unlinked(process.sleep_forever)
  let assert Ok(owner) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(now),
      dispatcher: dispatch.Dispatcher(start: fn(call) {
        process.send(seen, call)
        Ok(
          dispatch.Execution(
            id: dispatch.execution_id(incarnation: 73, seq: call.seq),
            guarantor:,
            cancel: fn() { process.send(cancelled, Nil) },
            stdin: fn(_, _) { Nil },
            release: fn() { Nil },
            abandon: fn() { Nil },
          ),
        )
      }),
    )
    as "The dispatcher supplies an observable existing cancellation handle."
  let phase = identity.build_phase(managed(3))
  let call = build.build_call(build_config(owner, "/unused"), phase, "/work")
  let assert Ok(origin) = identity.command_origin(phase)
    as "The original native build origin is available."
  let runner = physical.local(owner)
  let assert Ok(running) = runner.clear(origin, call, process.new_subject())
    as "The origin-bearing call is cleared by the real owner broker."
  let cleared = next(seen)
  assert_origin(cleared, parent(3), remote_tool.CompileCommand)
  running.cancel()
  assert process.receive(cancelled, 2000) == Ok(Nil)
  runner.abort_step(call.op_id, "unrelated-step")
  assert process.receive(cancelled, 50) == Error(Nil)
  runner.abort_step(call.op_id, call.step_id)
  assert process.receive(cancelled, 2000) == Ok(Nil)

  // Settlement releases custody before the fixture guarantor is retired.
  cleared.settle(dispatch.Failed(exec.ChannelClosed(1)))
  broker.stop(owner)
  process.kill(guarantor)
}
