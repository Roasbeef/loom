//// Production assembly of a promoted jailed generation.
////
//// One dedicated plane carries offline compilation, the persistent satellite
//// and its nested brokered processes. Its close capability is retained before
//// compilation begins and remains the native retirement witness through every
//// failed preparation and every later activation or rollback.

import broker/broker.{type Broker}
import broker/egress
import broker/exec
import broker/policy
import client/codemode
import client/evolution/candidate
import client/evolution/evaluate
import client/evolution/live
import client/evolution/program
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/extension/archive
import client/extension/dispatch
import client/extension/hooks
import client/extension/hosts
import client/extension/install
import client/extension/memory
import codemode/build
import codemode/codemode as pipeline
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/json
import filepath
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import telemetry/log.{type Logger}
import tools/codemode as codemode_tool
import tools/tool
import weft/registry as address

/// A dedicated effect lane with a mandatory orderly native cleanup witness.
pub type Plane {
  Plane(
    /// The generation's exclusive broker.
    broker: Broker,
    /// Joins executor and helper retirement; a Report cannot satisfy this.
    close: retirement.Task,
    /// Returns the native executor's bounded helper census.
    inventory: fn() -> Result(json.JsonValue, String),
  )
}

/// Immutable native assembly inputs; no candidate can choose these terms.
pub type Config {
  Config(
    /// Session catalogue authority for exact approvals and selections.
    catalogue: store.Store,
    /// Existing code-mode host configuration, reused with the isolated broker.
    host: codemode.Config,
    /// The session's policy, unchanged for capability calls.
    base: policy.SandboxPolicy,
    /// Native hook coordinates for this session.
    at: hosts.Coordinates,
    /// Session-owned durable extension memory.
    memory: memory.Door,
    /// Native credential lookup; secret values remain outside candidate bytes.
    secrets: fn(String) -> Result(String, Nil),
    /// The existing session routing registry.
    namespace: address.Registry,
    /// Build and artifact scratch under the protected runtime root.
    scratch: String,
    /// Allocates exactly two helpers: persistent node plus nested proc.run.
    open: fn(policy.SandboxPolicy) -> Result(Plane, store.Refusal),
    /// Host logger.
    logger: Logger,
  )
}

/// Prepares an approved candidate in a dedicated generation plane.
///
/// ## Examples
///
/// ```gleam
/// // native.stage(config, selection)
/// ```
///
pub fn stage(
  config: Config,
  selection: record.Selection,
) -> Result(live.Generation, store.Refusal) {
  use _ <- result.try(store.approved(config.catalogue, selection))
  let directory =
    config.scratch
    <> "/"
    <> record.id_string(selection.candidate_id)
    <> "-"
    <> int.to_string(selection.generation)
  let base = private_base(config, directory)
  use opened <- result.try(config.open(base))
  let plane = cleaning(opened, directory)
  let host =
    codemode.Config(..config.host, broker: plane.broker, work_root: directory)
  let prepared =
    evaluate.prepare(
      config.catalogue,
      selection.candidate_id,
      directory,
      compiler(config, host, base),
    )
  prepared_generation(config, host, plane, selection, directory, prepared)
}

fn prepared_generation(
  config: Config,
  host: codemode.Config,
  plane: Plane,
  selection: record.Selection,
  directory: String,
  prepared: Result(evaluate.Prepared, store.Refusal),
) -> Result(live.Generation, store.Refusal) {
  case prepared {
    Error(reason) -> failed(plane, reason)
    Ok(prepared) ->
      assemble(config, host, plane, selection, directory, prepared)
  }
}

fn assemble(
  config: Config,
  host: codemode.Config,
  plane: Plane,
  selection: record.Selection,
  directory: String,
  prepared: evaluate.Prepared,
) -> Result(live.Generation, store.Refusal) {
  let name = address.new_address(config.namespace)
  let hosting = hosts.seam(name, clock: host.clock, margin_ms: 20_000)
  let memory =
    scoped_memory(config.memory, record.id_string(selection.candidate_id))
  let dispatch =
    dispatch.Config(
      host:,
      hosts: hosting,
      memory:,
      secrets: config.secrets,
      trust: egress.SystemRoots,
      launch: dispatch.jailed_node,
    )
  let declarations =
    dispatch.tools(
      dispatch,
      prepared.record,
      prepared.manifest,
      prepared.sources,
      prepared.artifact,
    )
  assemble_tools(
    config,
    dispatch,
    hosting,
    plane,
    selection,
    directory,
    prepared,
    name,
    declarations,
  )
}

fn assemble_tools(
  config: Config,
  dispatch: dispatch.Config,
  hosting: hosts.Hosts,
  plane: Plane,
  selection: record.Selection,
  directory: String,
  prepared: evaluate.Prepared,
  name: address.Address(hosts.Message),
  declarations: Result(List(tool.Tool), String),
) -> Result(live.Generation, store.Refusal) {
  case declarations {
    Error(reason) -> failed(plane, store.Unavailable(reason))
    Ok(declarations) -> {
      let recipe =
        dispatch.hosting(
          dispatch,
          prepared.record,
          prepared.manifest,
          prepared.artifact,
        )
      let start = recipe.start
      let recipe =
        hosts.Extension(..recipe, start: fn(at) {
          start(
            hosts.Coordinates(
              ..at,
              base_policy: readonly_node(private_base(config, directory)),
              workspace: directory,
            ),
          )
        })
      let begun = hosts.start(name, config.host.clock, [recipe])
      assembled_hosts(
        config,
        hosting,
        plane,
        selection,
        prepared,
        name,
        declarations,
        begun,
      )
    }
  }
}

fn assembled_hosts(
  config: Config,
  hosting: hosts.Hosts,
  plane: Plane,
  selection: record.Selection,
  prepared: evaluate.Prepared,
  name: address.Address(hosts.Message),
  declarations: List(tool.Tool),
  begun: Result(actor.Started(process.Subject(hosts.Message)), actor.StartError),
) -> Result(live.Generation, store.Refusal) {
  case begun {
    Error(error) -> failed(plane, store.Unavailable(string.inspect(error)))
    Ok(started) -> {
      let subscribed =
        hooks.Extension(
          name: prepared.record.name,
          events: list.map(prepared.manifest.hooks, fn(hook) { hook.event }),
          invoke: hosts.invoker(hosting, at: config.at),
        )
      let bus = hooks.start([subscribed], config.logger)
      assembled_bus(
        config,
        plane,
        selection,
        name,
        started.pid,
        declarations,
        bus,
      )
    }
  }
}

fn assembled_bus(
  config: Config,
  plane: Plane,
  selection: record.Selection,
  name: address.Address(hosts.Message),
  pid: process.Pid,
  declarations: List(tool.Tool),
  bus: Result(hooks.Bus, actor.StartError),
) -> Result(live.Generation, store.Refusal) {
  case bus {
    Error(error) -> {
      process.unlink(pid)
      hosts.stop(name, 20_000)
      process.kill(pid)
      failed(plane, store.Unavailable(string.inspect(error)))
    }
    Ok(bus) ->
      Ok(live.Generation(
        selection:,
        inventory: plane.inventory,
        tools: declarations,
        hooks: Some(bus),
        validate: fn() {
          store.authorized(config.catalogue, selection) |> result.replace(Nil)
        },
        retire: retirement.sequence(
          retirement.repeat(fn() {
            hooks.close(bus)
            process.unlink(pid)
            hosts.stop(name, 20_000)
            process.kill(pid)
            Ok(Nil)
          }),
          plane.close,
        ),
      ))
  }
}

fn compiler(
  config: Config,
  host: codemode.Config,
  base: policy.SandboxPolicy,
) -> install.Build {
  let builder = private_builder(host, base, config.at.demand)
  let #(now, _) = clock.read(host.clock)
  let #(operation, _) = ids.mint_op(ids.generator(host.clock, 807))
  let phase =
    identity.build_phase(identity.for_execution(
      op_id: operation,
      step_id: "evolution-build",
      budget: codemode.pooled_budget(host, now + 60_000),
    ))
  fn(directory) { builder(phase, directory, []) }
}

fn private_base(config: Config, directory: String) -> policy.SandboxPolicy {
  let owned = filepath.directory_name(filepath.directory_name(config.scratch))
  owned_policy(config.base, owned, directory, config.host.host_mounts)
}

/// Narrows a native build and node to its own artifact and trusted toolchain.
/// Broad session reads and writes never survive removal of the artifact mask.
/// Capability effects use their original caller policy through `caller_router`.
///
/// ## Examples
///
/// `owned_policy(base, "/state/evolution", "/state/evolution/run/s/1", mounts)`.
@internal
pub fn owned_policy(
  base: policy.SandboxPolicy,
  owned: String,
  directory: String,
  mounts: List(policy.Mount),
) -> policy.SandboxPolicy {
  let reachable = codemode.reaching_socket(base, owned, directory)

  // These paths provide the native interpreter and platform loader, not
  // operator storage. Every other readable region is a discovered toolchain
  // mount; the candidate and session grants cannot choose any of them.
  let runtime = ["/bin", "/usr/bin", "/usr/lib", "/System/Library"]
  policy.SandboxPolicy(
    ..reachable,
    readable_roots: list.unique(list.append(
      [directory, ..runtime],
      list.map(mounts, fn(mount) { mount.path }),
    )),
    writable_roots: [directory],
    mounts:,
    env_allow: list.unique(["HOME", ..base.env_allow]),
  )
}

/// Removes artifact writes from the satellite after native compilation.
/// The host writes its token before launch; the node only reads retained bytes.
///
/// ## Examples
///
/// `readonly_node(owned_build_policy).writable_roots == []`.
@internal
pub fn readonly_node(base: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(..base, writable_roots: [])
}

/// Keeps capability calls under their real caller's policy and coordinates.
/// Replacing the node's policy must not replace proc.run's clearance base.
///
/// ## Examples
///
/// `caller_router(router, caller_base, caller_workspace, original_run_phase)`.
@internal
pub fn caller_router(
  router: satellite.CapRouter,
  base: policy.SandboxPolicy,
  workspace: String,
  phase: identity.PhaseIdentity,
) -> satellite.CapRouter {
  fn(request) {
    router(
      satellite.CapRequest(
        ..request,
        base_policy: base,
        cwd: workspace,
        identity: phase,
      ),
    )
  }
}

/// Drops caller grants from the native artifact launch identity.
/// Capability clearances restore the original phase through `caller_router`.
///
/// ## Examples
///
/// `identity.grants(identity.run_phase(node_identity(execution))) == []`.
@internal
pub fn node_identity(
  execution: identity.ExecIdentity,
) -> identity.ExecIdentity {
  let phase = identity.run_phase(execution)
  identity.for_execution(
    identity.op_id(phase),
    identity.step_id(phase),
    identity.pooled_budget(phase),
  )
}

fn scoped_memory(door: memory.Door, version: String) -> memory.Door {
  memory.Door(
    remember: fn(cell, value) {
      door.remember(
        memory.Cell(..cell, extension: "evolution-" <> version),
        value,
      )
    },
    recall: fn(cell) {
      door.recall(memory.Cell(..cell, extension: "evolution-" <> version))
    },
  )
}

fn failed(plane: Plane, reason: store.Refusal) -> Result(a, store.Refusal) {
  case retirement.perform(plane.close) {
    Ok(Nil) -> Error(reason)
    Error(cleanup) ->
      Error(store.CleanupUnconfirmed(cleanup.reason, cleanup.retry))
  }
}

/// Runs candidate-owned tests behind the real jail and retirement witness.
///
/// ## Examples
///
/// ```gleam
/// // native.evaluate(config, ctx, catalogue, candidate_id)
/// ```
///
pub fn evaluate_candidate(
  config: Config,
  ctx: tool.Ctx,
  catalogue: store.Store,
  id: record.CandidateId,
) -> Result(record.Evidence, store.Refusal) {
  let directory =
    config.scratch
    <> "/tests-"
    <> record.id_string(id)
    <> "-"
    <> ids.op_id_to_string(ctx.op_id)
    <> "-"
    <> int.to_string(ctx.source_index)
  let base = private_base(config, directory)
  use opened <- result.try(config.open(base))
  let plane = cleaning(opened, directory)
  let host =
    codemode.Config(..config.host, broker: plane.broker, work_root: directory)
  let candidate = store.read_candidate(catalogue, id)
  evaluate_kind(
    config,
    host,
    ctx,
    catalogue,
    id,
    directory,
    base,
    plane,
    candidate,
  )
}

fn evaluate_kind(
  config: Config,
  host: codemode.Config,
  ctx: tool.Ctx,
  catalogue: store.Store,
  id: record.CandidateId,
  directory: String,
  base: policy.SandboxPolicy,
  plane: Plane,
  candidate: Result(record.Candidate, store.Refusal),
) -> Result(record.Evidence, store.Refusal) {
  case candidate {
    Error(error) -> failed(plane, error)
    Ok(candidate) ->
      case candidate.kind {
        record.Program ->
          program.test_with(
            catalogue,
            id,
            fn(source) {
              private_program(config, host, ctx, directory, base, source)
            },
            plane.close,
          )
        record.Prompt ->
          failed(
            plane,
            store.Authority("prompt candidates need independent native rollout"),
          )
        record.Extension ->
          evaluate.extension_owned(
            catalogue,
            id,
            directory,
            compiler(config, host, base),
            fn(artifact) { run_tests(config, host, ctx, directory, artifact) },
            plane.close,
          )
      }
  }
}

fn run_tests(
  config: Config,
  host: codemode.Config,
  ctx: tool.Ctx,
  directory: String,
  artifact: compile.Artifact,
) -> Result(evaluate.Observation, store.Refusal) {
  let request =
    codemode_tool.request(
      codemode.seam(host),
      ctx,
      "",
      Some(60_000),
      codemode_tool.WorkspaceSeam,
    )
  let #(now, _) = clock.read(host.clock)
  let execution =
    codemode.exec_config(host, request, directory, now + 60_000, ctx.grants)
  let sockets = filepath.directory_name(execution.satellite.cap_socket_path)
  use Nil <- result.try(
    codemode.prepare_root(sockets) |> result.map_error(store.Unavailable),
  )
  let satellite =
    satellite.SatelliteConfig(
      ..execution.satellite,
      cwd: directory,
      router: caller_router(
        execution.satellite.router,
        request.base_policy,
        request.workspace,
        identity.run_phase(execution.identity),
      ),
      base_policy: codemode.reaching_socket_of(
        host,
        codemode.execution_policy(
          readonly_node(private_base(config, directory)),
        ),
        sockets,
      ),
    )
  let ran =
    satellite.run(
      artifact,
      identity.run_phase(node_identity(execution.identity)),
      host.broker,
      satellite,
      execution.launch,
    )
  use outcome <- result.try(
    ran.outcome
    |> result.map_error(fn(error) { store.TestFailed(string.inspect(error)) }),
  )
  Ok(evaluate.Observation(
    outcome:,
    detail: json.to_string(
      json.Object([
        #(
          "native_cleanup",
          json.String("executor retirement required before persistence"),
        ),
        #("enforcement", json.String(string.inspect(ran.node))),
      ]),
    ),
  ))
}

/// Borrows a dedicated jail only for bounded source capture and retirement.
///
/// ## Examples
///
/// `native.snapshot(config, ctx, directory)` applies current caller masks.
pub fn snapshot(
  config: Config,
  ctx: tool.Ctx,
  directory: String,
) -> Result(archive.Tree, store.Refusal) {
  use plane <- result.try(config.open(ctx.base_policy))
  candidate.snapshot_owned(ctx, directory, plane.broker, plane.close)
}

// Native retirement precedes removal of immutable staging and worker paths.
// Files left by a failed witness remain available to the custodian's retry.
fn cleaning(plane: Plane, directory: String) -> Plane {
  Plane(
    ..plane,
    close: retirement.sequence(
      plane.close,
      retirement.repeat(fn() {
        simplifile.delete_all([directory])
        |> result.map_error(simplifile.describe_error)
      }),
    ),
  )
}

/// Runs an exact reusable program with immutable private compilation artifacts.
///
/// The generated adapter and build belong to the native host. The capability
/// router is built from the original caller context, so making the compiler's
/// directory reachable grants no filesystem or process authority to the program.
///
/// ## Examples
///
/// `native.invoke_program(config, store, selection, ctx, input)` closes its pool.
pub fn invoke_program(
  config: Config,
  catalogue: store.Store,
  selection: record.Selection,
  ctx: tool.Ctx,
  input: json.JsonValue,
) -> Result(codemode_tool.Execution, store.Refusal) {
  use candidate <- result.try(store.authorized(catalogue, selection))
  use Nil <- result.try(case candidate.kind {
    record.Program -> Ok(Nil)
    record.Extension | record.Prompt -> Error(store.Authority("not a program"))
  })
  use source <- result.try(
    list.key_find(candidate.files, "program.gleam")
    |> result.replace_error(store.Corrupt("program.gleam is absent")),
  )
  let directory =
    config.scratch
    <> "/program-"
    <> record.id_string(candidate.id)
    <> "-"
    <> ids.op_id_to_string(ctx.op_id)
    <> "-"
    <> int.to_string(ctx.source_index)
  let base = private_base(config, directory)
  use opened <- result.try(config.open(base))
  let plane = cleaning(opened, directory)
  let host =
    codemode.Config(..config.host, broker: plane.broker, work_root: directory)
  let ran =
    private_program(
      config,
      host,
      ctx,
      directory,
      base,
      program.adapter(source, json.to_string(json.canonical(input))),
    )

  // A structured satellite report does not establish native helper retirement.
  // The owner receives its retry capability before it can admit another plane.
  use Nil <- result.try(
    retirement.perform(plane.close)
    |> result.map_error(fn(failure) {
      store.CleanupUnconfirmed(failure.reason, failure.retry)
    }),
  )
  ran
}

fn private_program(
  config: Config,
  host: codemode.Config,
  ctx: tool.Ctx,
  directory: String,
  base: policy.SandboxPolicy,
  source: String,
) -> Result(codemode_tool.Execution, store.Refusal) {
  let request =
    codemode_tool.request(
      codemode.seam(host),
      ctx,
      source,
      Some(60_000),
      codemode_tool.WorkspaceSeam,
    )
  let #(now, _) = clock.read(host.clock)
  let original =
    codemode.exec_config(host, request, directory, now + 60_000, ctx.grants)
  let sockets = filepath.directory_name(original.satellite.cap_socket_path)
  use Nil <- result.try(
    codemode.prepare_root(sockets) |> result.map_error(store.Unavailable),
  )
  let builder = private_builder(host, base, ctx.demand)
  let isolated =
    pipeline.ExecConfig(
      ..original,
      identity: node_identity(original.identity),
      compile: compile.CompileConfig(..original.compile, build: builder),
      satellite: satellite.SatelliteConfig(
        ..original.satellite,
        cwd: directory,
        router: caller_router(
          original.satellite.router,
          request.base_policy,
          request.workspace,
          identity.run_phase(original.identity),
        ),
        base_policy: codemode.reaching_socket_of(
          host,
          codemode.execution_policy(
            readonly_node(private_base(config, directory)),
          ),
          sockets,
        ),
      ),
    )
  let execution = pipeline.execute(source, isolated)
  Ok(codemode_tool.Execution(
    result: codemode.translate(execution.outcome),
    enforcement: codemode_tool.Enforcement(
      build: program_report(execution.enforcement.build),
      node: program_report(execution.enforcement.node),
    ),
    refusal: codemode_tool.NothingRefused,
    calls: execution.calls,
  ))
}

fn program_report(report: enforcement.Report) -> codemode_tool.Report {
  case report {
    enforcement.Unreported(reason:) -> codemode_tool.Unreported(reason:)
    enforcement.Reported(entries: _, degraded:) -> {
      let #(applied, skipped) = enforcement.layers(report)
      codemode_tool.Enforced(applied:, skipped:, degraded:)
    }
  }
}

// The compiler gets a deterministic disposable home, after seed preparation.
// Rebar needs HOME even for offline builds; it must never be the operator's.
fn private_builder(
  host: codemode.Config,
  base: policy.SandboxPolicy,
  demand: exec.EnforcementDemand,
) -> compile.Builder {
  fn(phase, directory, generated) {
    let home = directory <> "/.build-home"
    case codemode.prepare_root(home) {
      Error(reason) ->
        compile.Built(
          result: Error(compile.WorkspaceSetupFailed(reason)),
          enforcement: enforcement.Unreported(
            "private compiler HOME could not be prepared",
          ),
        )
      Ok(Nil) ->
        build.builder(build.BuildConfig(
          broker: host.broker,
          seed_root: host.seed_root,
          gleam_path: host.gleam_path,
          base_policy: base,
          toolchain_roots: base.readable_roots,
          demand:,
          env: [#("PATH", host.toolchain_path), #("HOME", home)],
          dependencies: compile.default_dependencies(),
          timeout_ms: 60_000,
          observe: tool.ignore_output(),
        ))(phase, directory, generated)
    }
  }
}
