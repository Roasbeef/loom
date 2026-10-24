//// The machine for a workspace in this VM: production assembly of a promoted
//// jailed generation, and the checks that run beside it.
////
//// This is the module that was `evolution/native`, moved behind
//// `evolution/machine` without being rewritten. `new` wraps its functions in
//// the `machine.Machine` record, and `serve` builds that record for a session
//// whose workspace has a local code-mode host. The functions below keep their
//// own names and behaviour so the jail, retirement and custody rules read as
//// they did before the seam existed.
////
//// One dedicated plane carries offline compilation, the persistent satellite
//// and its nested brokered processes. Its close capability is retained before
//// compilation begins and remains the native retirement witness through every
//// failed preparation and every later activation or rollback.
////
//// The configuration holds no catalogue. Staging, evaluation and program runs
//// receive it per call from the authority half, so this machine can be built
//// before the catalogue is opened with the identity it reports.
////
//// Staging splits the same way. `stage_candidate` takes an approved
//// `record.Candidate` and answers a `staged.Staged`: the plane, the compiled
//// artifact, the satellite host and its declared tools, with no catalogue, no
//// hook bus and no `live` type in it. `generation_of` is the orchestrator's
//// half. It starts the hook bus over the staged value's `invoke`, builds the
//// `live.Generation` whose `validate` and in-place upgrade apply the
//// catalogue's approval and identity checks, and prepends the bus close to the
//// staged value's `retire`. `stage` is the two in order, so a session in this
//// VM behaves as it did when assembly was one function. `open_plane` is the
//// plane opener a machine of this kind needs, moved here from `serve` so it
//// depends on nothing of the daemon's settings.
////
//// The checks themselves hold no catalogue either. `evaluate_candidate` and
//// `invoke_program` are wrappers that read the candidate, confirm its identity
//// (`evaluate.current`), or its approval (`store.approved`, which includes the
//// identity check) and kind, and then call
//// `evaluate_candidate_of` and `invoke_program_of`, which take the
//// `record.Candidate` and nothing else. The wrappers are the orchestrator's
//// half and the `_of` functions are what an executor can run over a candidate
//// it was handed.
////
//// ## Flow
////
//// `new` → `stage` → `stage_candidate` → `assemble` → `generation_of` →
//// `over_bus` → `mode_of`
////
//// 1. `new` builds the `machine.Machine` record over this module's functions.
//// 2. `stage` checks the catalogue's approval, then runs the two halves below
////    in order.
//// 3. `stage_candidate` opens a dedicated plane through `open_plane`,
////    compiles the candidate, and hands the prepared artifact to `assemble`.
//// 4. `assemble` starts the satellite host and declares its tools, and answers
////    a `staged.Staged` whose retirement stops the host and then the plane.
//// 5. `generation_of` starts the hook bus over that value and answers a
////    `live.Generation` through `over_bus`.
//// 6. `over_bus` puts the catalogue's validation and the bus close in front of
////    the value, and `mode_of` does the same for an in-place upgrade.
//// 7. `evaluate_candidate` and `invoke_program` are the wrappers over
////    `evaluate_candidate_of` and `invoke_program_of`, which run checks
////    beside a generation without a catalogue.

import broker/broker.{type Broker}
import broker/egress
import broker/exec
import broker/executor
import broker/policy
import client/codemode
import client/evolution/candidate
import client/evolution/evaluate
import client/evolution/identity as compile_identity
import client/evolution/live
import client/evolution/machine.{type Machine}
import client/evolution/program
import client/evolution/record
import client/evolution/retirement
import client/evolution/staged.{type Staged, Staged}
import client/evolution/stateful
import client/evolution/store
import client/extension/archive
import client/extension/dispatch
import client/extension/hooks
import client/extension/hosts
import client/extension/install
import client/extension/memory
import client/workspace_plane
import codemode/build
import codemode/codemode as pipeline
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/satellite
import core/clock.{type Clock}
import core/ids
import core/json
import filepath
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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

/// Builds the machine for a workspace in this VM over `config`.
///
/// Each field is a function of this module with `config` applied, so the
/// record adds no behaviour of its own: `identity` is
/// `evolution/identity.current` over `config.host`, `snapshot` is `snapshot`,
/// `evaluate` is `evaluate_candidate`, `stage` is `stage`, and `run_program`
/// is `invoke_program`, the wrappers that read the catalogue before the
/// catalogue-free `evaluate_candidate_of` and `invoke_program_of` run.
///
/// ## Examples
///
/// ```gleam
/// // let machine = local.new(config)
/// // machine.stage(catalogue, selection)
/// ```
///
pub fn new(config: Config) -> Machine {
  let host = config.host

  machine.Machine(
    identity: fn() { compile_identity.current(host) },
    snapshot: fn(ctx, directory) { snapshot(config, ctx, directory) },
    evaluate: fn(catalogue, ctx, id) {
      evaluate_candidate(config, ctx, catalogue, id)
    },
    stage: fn(catalogue, selection) { stage(config, catalogue, selection) },
    run_program: fn(catalogue, selection, ctx, input) {
      invoke_program(config, catalogue, selection, ctx, input)
    },
  )
}

/// Prepares an approved candidate in a dedicated generation plane.
///
/// This is `stage_candidate` followed by `generation_of`, the machine's half
/// and the orchestrator's half, behind the catalogue's approval check. A failed
/// stage returns either the original refusal after a confirmed retirement or
/// `CleanupUnconfirmed` carrying the retry. Success hands the witness to the
/// returned generation's `retire`.
///
/// ## Examples
///
/// ```gleam
/// // local.stage(config, catalogue, selection)
/// ```
///
pub fn stage(
  config: Config,
  catalogue: store.Store,
  selection: record.Selection,
) -> Result(live.Generation, store.Refusal) {
  use approved <- result.try(store.approved(catalogue, selection))
  use staged <- result.try(stage_candidate(config, approved, selection))
  generation_of(catalogue, config.logger, staged)
}

/// Prepares a candidate in a dedicated generation plane, reading no catalogue.
///
/// The plane opens first and its close task is the cleanup witness for every
/// later step. From the moment it exists, each refusal retires the plane
/// through `failed`, either via `retiring` or after stopping what the step
/// started. The candidate is the whole input; the caller has already checked
/// that `selection` is approved and that `candidate` is the candidate it names.
///
/// ## Examples
///
/// ```gleam
/// // local.stage_candidate(config, candidate, selection)
/// ```
///
pub fn stage_candidate(
  config: Config,
  candidate: record.Candidate,
  selection: record.Selection,
) -> Result(Staged, store.Refusal) {
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

  use prepared <- result.try(
    evaluate.prepare(candidate, directory, compiler(config, host, base))
    |> retiring(plane),
  )
  assemble(config, host, plane, selection, directory, prepared)
}

// Starts the satellite over a prepared artifact and wraps it, with its
// declarations and the plane, in a staged value whose `retire` closes the host
// before the plane.
//
// The steps are ordered by what each leaves running. Declarations start
// nothing and the host starts one process. Once the staged value exists, its
// own `retire` owns the host and the plane, so an attach refusal retires
// through it. The hook bus is not started here: it belongs to the
// orchestrator's half (`generation_of`), which starts it over the `invoke` this
// value carries and closes it ahead of this value's `retire`.
fn assemble(
  config: Config,
  host: codemode.Config,
  plane: Plane,
  selection: record.Selection,
  directory: String,
  prepared: evaluate.Prepared,
) -> Result(Staged, store.Refusal) {
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

  use declarations <- result.try(
    dispatch.tools(
      dispatch,
      prepared.record,
      prepared.manifest,
      prepared.sources,
      prepared.artifact,
    )
    |> result.map_error(store.Unavailable)
    |> retiring(plane),
  )

  // The satellite launches under the private read-only base, whatever
  // coordinates its caller supplies, because it only reads retained bytes.
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
  use started <- result.try(
    hosts.start(name, config.host.clock, [recipe])
    |> result.map_error(fn(error) { store.Unavailable(string.inspect(error)) })
    |> retiring(plane),
  )

  let invoker = hosts.invoker(hosting, at: config.at)
  let extension = prepared.record.name
  let staged =
    Staged(
      name: prepared.record.name,
      selection:,
      tools: declarations,
      events: list.map(prepared.manifest.hooks, fn(hook) { hook.event }),
      invoke: fn(event, args, within) {
        invoker(extension, event, args, within)
      },
      inventory: plane.inventory,
      retire: retirement.sequence(
        retirement.repeat(fn() {
          stop_host(name, started.pid)
          Ok(Nil)
        }),
        plane.close,
      ),
      upgrade: None,
    )

  // Every later selection owns a fresh execution identity and wall budget.
  let base = private_base(config, prepared.directory)
  let demand = config.at.demand
  let compile = fn(candidate, directory, slot) {
    let build = compiler_for(host, base, demand)
    evaluate.prepare_slot(candidate, directory, build, slot)
  }
  stateful.attach(staged, dispatch, hosting, prepared, compile, config.at)
  |> result.try_recover(fn(reason) {
    failed(Plane(..plane, close: staged.retire), reason)
  })
}

/// Starts the orchestrator's half of a staged generation.
///
/// The hook bus starts over the staged value's `invoke`, and the generation
/// that comes back checks the catalogue where the machine does not. Its
/// `validate` asks `store.authorized` for the selection. Its in-place upgrade,
/// when the staged value has one, asks `store.approved` for the successor's
/// candidate before the machine compiles anything, so no upgrade reaches the
/// compiler unchecked. A successor reuses the predecessor's bus.
///
/// Retirement closes the bus first, then runs the staged value's own `retire`,
/// which stops the host and then closes the plane. A bus that cannot start
/// retires the staged value, host then plane, and surfaces its refusal, so the
/// caller owes no cleanup either way.
///
/// ## Examples
///
/// ```gleam
/// // local.generation_of(catalogue, logger, staged)
/// ```
///
pub fn generation_of(
  catalogue: store.Store,
  logger: Logger,
  staged: Staged,
) -> Result(live.Generation, store.Refusal) {
  let invoke = staged.invoke
  let subscribed =
    hooks.Extension(
      name: staged.name,
      events: staged.events,
      invoke: fn(_name, event, args, within) { invoke(event, args, within) },
    )
  use bus <- result.try(case hooks.start([subscribed], logger) {
    Ok(bus) -> Ok(bus)
    Error(error) ->
      failed_task(staged.retire, store.Unavailable(string.inspect(error)))
  })
  Ok(over_bus(catalogue, bus, staged))
}

// The generation for a staged value over a bus that is already running. An
// upgrade's successor comes back through here with the same bus, which is why
// the bus is a parameter rather than started once per value.
fn over_bus(
  catalogue: store.Store,
  bus: hooks.Bus,
  staged: Staged,
) -> live.Generation {
  let selection = staged.selection
  live.Generation(
    selection:,
    mode: mode_of(catalogue, bus, staged),
    inventory: staged.inventory,
    tools: staged.tools,
    hooks: Some(bus),
    validate: fn() {
      store.authorized(catalogue, selection) |> result.replace(Nil)
    },
    retire: retirement.sequence(
      retirement.repeat(fn() {
        hooks.close(bus)
        Ok(Nil)
      }),
      staged.retire,
    ),
  )
}

// Replacement-only unless the staged value carries an upgrade, in which case
// the successor's approval is read here, before the machine sees it.
fn mode_of(
  catalogue: store.Store,
  bus: hooks.Bus,
  staged: Staged,
) -> live.Mode {
  case staged.upgrade {
    None -> live.ReplacementOnly
    Some(upgrade) -> {
      let prepare = upgrade.prepare
      live.Stateful(prepare: fn(selection) {
        use candidate <- result.try(store.approved(catalogue, selection))
        use prepared <- result.map(prepare(selection, candidate))
        live.PreparedUpgrade(
          generation: over_bus(catalogue, bus, prepared.successor),
          publish: prepared.publish,
          abort: prepared.abort,
        )
      })
    }
  }
}

// The three-step stop of an extension host: detach it from this process so its
// exit is not ours, ask it to stop, and kill what remains. A staged value's
// retirement is the only caller, so a failed attach, a failed bus start and a
// later retirement all stop the host in exactly this order.
fn stop_host(name: address.Address(hosts.Message), pid: process.Pid) -> Nil {
  process.unlink(pid)
  hosts.stop(name, 20_000)
  process.kill(pid)
}

// Retires the plane before surfacing a refusal, once the plane exists.
fn retiring(
  attempt: Result(a, store.Refusal),
  plane: Plane,
) -> Result(a, store.Refusal) {
  result.try_recover(attempt, fn(reason) { failed(plane, reason) })
}

fn compiler(
  config: Config,
  host: codemode.Config,
  base: policy.SandboxPolicy,
) -> install.Build {
  compiler_for(host, base, config.at.demand)
}

fn compiler_for(
  host: codemode.Config,
  base: policy.SandboxPolicy,
  demand: exec.EnforcementDemand,
) -> install.Build {
  let builder = private_builder(host, base, demand)
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
  let remember = door.remember
  let recall = door.recall
  memory.Door(
    remember: fn(cell, value) {
      remember(memory.Cell(..cell, extension: "evolution-" <> version), value)
    },
    recall: fn(cell) {
      recall(memory.Cell(..cell, extension: "evolution-" <> version))
    },
  )
}

fn failed(plane: Plane, reason: store.Refusal) -> Result(a, store.Refusal) {
  failed_task(plane.close, reason)
}

// Performs a cleanup task and surfaces `reason` once it is confirmed, or the
// unconfirmed cleanup with its retry when it is not.
fn failed_task(
  close: retirement.Task,
  reason: store.Refusal,
) -> Result(a, store.Refusal) {
  case retirement.perform(close) {
    Ok(Nil) -> Error(reason)
    Error(cleanup) ->
      Error(store.CleanupUnconfirmed(cleanup.reason, cleanup.retry))
  }
}

/// Opens a dedicated effect plane for one check or generation.
///
/// A native check runs on its own effect plane: a private broker over two
/// helpers (the persistent node and its nested `proc.run`), so a candidate's
/// processes never share a pool with the session's tools. The close task it
/// returns is the only way to retire that plane, and `stage_candidate` keeps it
/// through every failed step.
///
/// ## Examples
///
/// ```gleam
/// // local.open_plane(helper, base, scratch, clock)
/// ```
///
pub fn open_plane(
  helper: String,
  base: policy.SandboxPolicy,
  scratch: String,
  clock: Clock,
) -> Result(Plane, store.Refusal) {
  use #(pool, broker_actor, service) <- result.try(
    workspace_plane.start_effect_plane(
      helper:,
      base_policy: base,
      tmp_dir: scratch,
      size: 2,
      clock:,
    )
    |> result.map_error(store.Unavailable),
  )
  Ok(Plane(
    broker: broker_actor,
    inventory: fn() { plane_census(service) },
    close: workspace_plane.retire_effect_plane(broker_actor, pool, service),
  ))
}

// The bounded helper census of a plane's executor: its capacity, the
// executions in flight and what its pool has spawned, borrowed and retired.
fn plane_census(service: executor.Executor) -> Result(json.JsonValue, String) {
  use snapshot <- result.try(
    executor.snapshot(service, waiting: 1000)
    |> result.map_error(string.inspect),
  )
  use pool_state <- result.try(
    snapshot.pool |> result.map_error(string.inspect),
  )
  Ok(
    json.Object([
      #("capacity", json.Int(pool_state.census.size)),
      #("executions", json.Int(list.length(snapshot.live))),
      #("borrowed", json.Int(pool_state.census.borrowed)),
      #("unconfirmed", json.Int(pool_state.census.unconfirmed)),
      #("spawned", json.Int(pool_state.census.spawned)),
      #("retired", json.Int(pool_state.census.retired)),
      #(
        "helpers",
        json.Array(
          list.map(pool_state.helpers, fn(helper) {
            json.Object([
              #("pid", json.String(string.inspect(helper.pid))),
              #("ordinal", json.Int(helper.ordinal)),
              #("custody", json.String(string.inspect(helper.custody))),
            ])
          }),
        ),
      ),
    ]),
  )
}

/// Reads a candidate from the catalogue and runs its tests behind the jail.
///
/// This is the orchestrator's half of an evaluation. It refuses an unreadable
/// candidate with the store's own refusal, and one admitted under another
/// identity with `Changed`, before any plane is opened. Otherwise it hands the candidate to
/// hands the candidate to `evaluate_candidate_of`.
///
/// ## Examples
///
/// ```gleam
/// // local.evaluate_candidate(config, ctx, catalogue, candidate_id)
/// ```
///
pub fn evaluate_candidate(
  config: Config,
  ctx: tool.Ctx,
  catalogue: store.Store,
  id: record.CandidateId,
) -> Result(evaluate.Report, store.Refusal) {
  use candidate <- result.try(store.read_candidate(catalogue, id))
  use Nil <- result.try(evaluate.current(catalogue, candidate))
  evaluate_candidate_of(config, ctx, candidate)
}

/// Runs candidate-owned tests behind the real jail and retirement witness.
///
/// The candidate is the whole input, and the function reads no catalogue. The
/// plane opens first and its close task retires on every path, including the
/// refusal for a prompt candidate, so the caller needs no cleanup of its own.
///
/// ## Examples
///
/// ```gleam
/// // local.evaluate_candidate_of(config, ctx, candidate)
/// ```
///
pub fn evaluate_candidate_of(
  config: Config,
  ctx: tool.Ctx,
  candidate: record.Candidate,
) -> Result(evaluate.Report, store.Refusal) {
  let directory =
    config.scratch
    <> "/tests-"
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
  case candidate.kind {
    record.Program ->
      program.test_with(
        candidate,
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
        candidate,
        directory,
        compiler(config, host, base),
        fn(artifact) { run_tests(config, host, ctx, directory, artifact) },
        plane.close,
      )
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
/// `local.snapshot(config, ctx, directory)` applies current caller masks.
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
/// `local.invoke_program(config, store, selection, ctx, input)` closes its pool
/// and answers the outcome the model sees.
pub fn invoke_program(
  config: Config,
  catalogue: store.Store,
  selection: record.Selection,
  ctx: tool.Ctx,
  input: json.JsonValue,
) -> Result(tool.ToolOutcome, store.Refusal) {
  use candidate <- result.try(store.authorized(catalogue, selection))
  use Nil <- result.try(case candidate.kind {
    record.Program -> Ok(Nil)
    record.Extension | record.Prompt -> Error(store.Authority("not a program"))
  })
  invoke_program_of(config, candidate, ctx, input)
}

/// Runs an authorized program candidate without reading a catalogue.
///
/// The orchestrator has already checked the selection and that the candidate
/// is a program (`invoke_program`); this function only recompiles the retained
/// source in a fresh pool and answers the outcome.
///
/// ## Examples
///
/// `local.invoke_program_of(config, candidate, ctx, input)` closes its pool
/// and answers the outcome the model sees.
pub fn invoke_program_of(
  config: Config,
  candidate: record.Candidate,
  ctx: tool.Ctx,
  input: json.JsonValue,
) -> Result(tool.ToolOutcome, store.Refusal) {
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
  result.map(ran, program.outcome)
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
    edits: execution.edits,
    last_failure: execution.last_failure,
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
  let broker = host.broker
  let seed_root = host.seed_root
  let gleam_path = host.gleam_path
  let toolchain_path = host.toolchain_path
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
          broker:,
          seed_root:,
          gleam_path:,
          base_policy: base,
          toolchain_roots: base.readable_roots,
          demand:,
          env: [#("PATH", toolchain_path), #("HOME", home)],
          dependencies: compile.default_dependencies(),
          timeout_ms: 60_000,
          observe: tool.ignore_output(),
        ))(phase, directory, generated)
    }
  }
}
