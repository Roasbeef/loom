//// The executor's workspace plane factory: what turns an orchestrator's attach
//// into a running workspace on this machine (protocol-change/078).
////
//// `client/remote/host` admits, runs and records tool calls but knows nothing
//// about checkouts. It asks a `PlaneFactory` for a plane when a session's scope
//// needs one, and this module is that factory for a real executor. It builds
//// the same workspace half a local session builds, through the same two calls
//// (`workspace_plane.prepare`, then `workspace_plane.start`), so the placement
//// of a workspace cannot change what its tools do. What differs is where the
//// inputs come from. A local session reads its machine configuration through
//// `serve.Settings`, which also demands a model catalogue and a session file.
//// An executor has neither, so `Machine` holds only the settings that name
//// paths and limits on this machine, read from this machine's own `loom.toml`.
////
//// ## Whose configuration it is
////
//// The rule behind the design (section 3 of the distributed-runtime note) is
//// that configuration naming a path on a machine lives on that machine. The
//// toolchain and code-mode seed are discovered here, the `[tools]`, `[lsp]`,
//// `[workspace]`, `[jobs]` and `[secrets]` tables come from this machine's
//// file, and the checkout is the `root` of a `[workspaces.<name>]` row. The
//// orchestrator sends a workspace name and nothing else about the machine.
////
//// ## What one scope owns
////
//// A scope's per-session state lives under `<state root>/scopes/<session>`: the
//// helpers' private scratch, and nothing the orchestrator can name. The code
//// mode cap sockets are bound under `<state root>/run` as for any managed
//// session. The scope directory is created fresh at attach and removed at
//// close, and a directory left by a previous VM is replaced, not reused.
////
//// ## Why the build collects its cleanups
////
//// `workspace_plane.start` hands each started resource to a `Retain` function
//// together with the cleanup that stops it. A local session gives those to its
//// custody actor. The factory runs inside a short-lived weft run, so it keeps
//// them itself: the retain function files each cleanup in the build process and
//// releases the build's link to the resource, and the plane's `close` runs the
//// filed cleanups in shutdown order. The helper pool's own retirement result,
//// returned by the `Helpers` cleanup, is the only witness that reports a scope
//// closed. A scope without that result is `UnknownCleanup`, whatever else went
//// well.
////
//// ## Flow
////
//// `machine` → `factory` → `build` → `plane_over` → `retire`
////
//// 1. `machine` reads this executor's own settings once, at daemon start.
//// 2. `factory` closes over the machine and the configured workspaces.
//// 3. `build` resolves the workspace name, makes the scope directory, and runs
////    `prepare` and `start`.
//// 4. `plane_over` reads the prompt facts once and wraps the started plane as the
////    host's `Plane`, with the census as plain data.
//// 5. `retire` closes a scope: language servers, children, broker, then helpers,
////    and reports `AllRetired` only on the helper witness.

import broker/broker
import broker/exec.{type EnforcementDemand}
import broker/policy
import client/catalog
import client/codemode as codemode_wiring
import client/gocache
import client/install
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/jobs
import client/lsp/profile
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{RemoteCensus}
import client/secrets
import client/serve
import client/workspace_plane
import client/workspace_policy
import client/workspaces.{type Workspace}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/secret
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import weft/registry

/// Everything the factory needs that names a path or a limit on this machine.
pub type Machine {
  Machine(
    /// The daemon's private state directory. Scope directories and cap sockets
    /// live under it, and the policy masks it from jailed children.
    state_root: String,
    /// The `loom-exec` sandbox helper.
    helper_path: String,
    /// How many helpers each scope's pool may hold.
    helper_pool_size: Int,
    /// Enforcement strictness for every jailed execution.
    demand: EnforcementDemand,
    /// Read scope and extra mounts from `[workspace]`.
    workspace: catalog.WorkspaceConfig,
    /// The `[tools]` table, with a `--network` flag already applied.
    tools: catalog.ToolsConfig,
    /// Built-in tools the operator deactivated with `LOOM_DISABLE_TOOLS`.
    deactivated_tools: List(String),
    /// The `[lsp.<name>]` servers.
    lsp_servers: List(profile.LspServer),
    /// The `[jobs]` policy.
    jobs_policy: jobs.JobsPolicy,
    /// An explicit `--codemode-seed`, else the ladder runs per workspace.
    codemode_seed: Option(String),
    /// The credential seam `[tools] env` is read through, answering from the
    /// resolved `[secrets]` table first and the process environment second.
    secrets: secret.SecretStore,
    /// The operator's home directory on this machine.
    home: Option(String),
    /// Where builds and closes report.
    logger: Logger,
  )
}

// The parts of the daemon's flags an executor honours. The rest of the flags
// belong to sessions (`--codemode-seams`, `--read-scope` and `--network` are
// the exceptions, folded into the tables they override).
type Flags {
  Flags(
    helper: Option(String),
    codemode_seed: Option(String),
    demand: Option(EnforcementDemand),
    read_scope: Option(catalog.ReadScope),
    network: Option(catalog.ToolNetwork),
  )
}

// A cleanup the plane's start filed: the part it belongs to, and the function
// that stops it and reports whether it is gone.
type Cleanup =
  #(custody.Part, fn() -> Result(Nil, String))

/// Reads this executor's settings from the daemon's own flags and `loom.toml`.
///
/// `arguments` are the daemon's session-default flags (`--helper`, `--config`,
/// `--codemode-seed`, `--best-effort`, `--full-enforcement`, `--read-scope`,
/// `--network`); any other flag is ignored here. `configuration` is the path
/// the `--config` flag named, or empty when there was none, in which case every
/// table takes its default. Failures name the file.
///
/// ## Examples
///
/// ```gleam
/// // executor_plane.machine(["--config", "/etc/loom/loom.toml"], "/etc/loom/loom.toml", state, logger)
/// ```
pub fn machine(
  arguments: List(String),
  configuration: String,
  state_root: String,
  logger: Logger,
) -> Result(Machine, String) {
  let flags = read_flags(arguments, Flags(None, None, None, None, None))
  use text <- result.try(read_configuration(configuration))
  let named = fn(reason) { configuration <> ": " <> reason }
  use tools <- result.try(catalog.parse_tools(text) |> result.map_error(named))
  use workspace <- result.try(
    catalog.parse_workspace(text) |> result.map_error(named),
  )
  use lsp_servers <- result.try(
    catalog.parse_lsp(text) |> result.map_error(named),
  )
  use jobs_policy <- result.try(
    jobs.parse_policy(text) |> result.map_error(named),
  )
  use entries <- result.try(secrets.parse(text) |> result.map_error(named))
  use helper_path <- result.try(find_helper(flags.helper))

  // Each failed entry is one warned line, never a refused start: a credential
  // this machine's tools may never need must not stop the executor.
  let #(resolved, failures) =
    secrets.resolve(
      entries,
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )
  list.each(failures, fn(failure) {
    log.warn(logger, "secrets.unresolved", [
      field.ident(key: "name", value: failure.name),
      field.text(key: "reason", value: failure.reason),
    ])
  })
  Ok(Machine(
    state_root:,
    helper_path:,
    helper_pool_size: pool_size(),
    demand: option.unwrap(flags.demand, exec.PlatformEnforcement),
    workspace: catalog.WorkspaceConfig(
      ..workspace,
      read_scope: option.unwrap(flags.read_scope, workspace.read_scope),
    ),
    tools: catalog.ToolsConfig(
      ..tools,
      network: option.unwrap(flags.network, tools.network),
    ),
    deactivated_tools: named_tools(result.unwrap(
      workspace_policy.env_text("LOOM_DISABLE_TOOLS"),
      "",
    )),
    lsp_servers:,
    jobs_policy:,
    codemode_seed: flags.codemode_seed,
    secrets: secrets.store(resolved, beneath: secret.env()),
    home: workspace_policy.home_directory(),
    logger:,
  ))
}

/// The factory the executor host builds planes with.
///
/// A name that is not in `configured` is refused with a reason an operator can
/// act on, before anything is made. Every other failure is the reason
/// `workspace_plane` gave, and leaves nothing running: whatever the build had
/// started is stopped before the error returns.
///
/// ## Examples
///
/// ```gleam
/// // host.Config(.., factory: executor_plane.factory(machine, workspaces))
/// ```
pub fn factory(
  machine: Machine,
  configured: List(Workspace),
) -> host.PlaneFactory(remote_census.RemoteCensus) {
  fn(spec: host.AttachSpec) { build(machine, configured, spec) }
}

fn build(
  machine: Machine,
  configured: List(Workspace),
  spec: host.AttachSpec,
) -> Result(host.Plane(remote_census.RemoteCensus), String) {
  use workspace <- result.try(
    workspaces.find(configured, spec.workspace)
    |> result.replace_error(
      "this executor serves no workspace named `" <> spec.workspace <> "`",
    ),
  )
  use root <- result.try(
    bootstrap.canonical_directory(workspace.root)
    |> result.map_error(fn(reason) {
      "the workspace `"
      <> workspace.name
      <> "` is not a directory on this executor: "
      <> reason
    }),
  )
  use scope <- result.try(scope_directory(machine.state_root, spec.session))
  let outcome = start(machine, root, scope, spec)
  case outcome {
    Ok(plane) -> Ok(plane)
    Error(reason) -> {
      remove_scope(machine.logger, scope)
      Error(reason)
    }
  }
}

// The scope's directory, created fresh and private. A directory left by an
// earlier VM held another build's scratch, so it is replaced and not adopted.
fn scope_directory(
  state_root: String,
  session: String,
) -> Result(String, String) {
  use Nil <- result.try(case safe_component(session) {
    True -> Ok(Nil)
    False -> Error("the session name is not usable as a directory name")
  })
  let scopes = state_root <> "/scopes"
  let scope = scopes <> "/" <> session
  let _removed = simplifile.delete(scope)
  use Nil <- result.try(bootstrap.ensure_private_directory(scopes))
  use Nil <- result.try(bootstrap.ensure_private_directory(scope))
  Ok(scope)
}

// A session name arrives from a peer, so it is judged before it names a path.
fn safe_component(name: String) -> Bool {
  let graphemes = string.to_graphemes(name)
  name != ""
  && string.byte_size(name) <= 128
  && !string.starts_with(name, ".")
  && list.all(graphemes, fn(each) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
      each,
    )
  })
}

// Prepares and starts the workspace half, filing every cleanup the start hands
// out. A start that fails after resources exist stops them before returning.
fn start(
  machine: Machine,
  root: String,
  scope: String,
  spec: host.AttachSpec,
) -> Result(host.Plane(remote_census.RemoteCensus), String) {
  let base =
    workspace_policy.base_policy_for(root, machine.workspace.read_scope)
    |> workspace_policy.admitting_config_mounts(machine.workspace.mounts)
    |> workspace_policy.protecting_state_root(machine.state_root)
  use prepared <- result.try(
    workspace_plane.prepare(
      workspace_spec(machine, root, scope, base),
      reading: fn(name) { secret.lookup(machine.secrets, name) },
    ),
  )
  use namespace <- result.try(registry.start())

  // The registry is linked to this short-lived build process, and its names
  // must outlive it.
  process.unlink(registry.owner(namespace))
  let filed = process.new_subject()
  let attach = attach_of(machine, spec, namespace, filed)
  case workspace_plane.start(prepared, attach) {
    Ok(started) -> {
      let cleanups = [
        #(custody.Namespace, fn() { registry.stop(namespace) }),
        ..drain(filed, [])
      ]
      plane_over(machine, scope, started, cleanups)
    }
    Error(reason) -> {
      let _outcome = retire_all(drain(filed, []))
      let _stopped = registry.stop(namespace)
      Error(reason)
    }
  }
}

fn workspace_spec(
  machine: Machine,
  root: String,
  scope: String,
  base: policy.SandboxPolicy,
) -> workspace_plane.WorkspaceSpec {
  workspace_plane.WorkspaceSpec(
    workspace: root,
    scratch_dir: scope <> "/tmp",
    helper_path: machine.helper_path,
    helper_pool_size: machine.helper_pool_size,
    demand: machine.demand,
    base_policy: base,
    tools: machine.tools,
    deactivated_tools: machine.deactivated_tools,
    go_caches: gocache_of(machine, root),
    home: machine.home,
    codemode_seed: seed_of(machine, root),
    codemode_sockets: serve.codemode_socket_root(base, machine.state_root),
    lsp_servers: machine.lsp_servers,
    jobs_policy: machine.jobs_policy,
    owner_files: None,
  )
}

// What the owner contributes to a start, on an executor: the owner services
// the host built for this scope, no owner-bound code-mode arms yet, and a
// retain function that files each cleanup in the build process.
fn attach_of(
  machine: Machine,
  spec: host.AttachSpec,
  namespace: registry.Registry,
  filed: Subject(Cleanup),
) -> workspace_plane.Attach {
  workspace_plane.Attach(
    logger: machine.logger,
    namespace:,
    retain: fn(part, cleanup, transfer) {
      process.send(filed, #(part, cleanup))

      // Filing comes first: the resource is on the books before the build's
      // link to it is released.
      transfer()
      Ok(Nil)
    },
    owner: spec.owner,
    session_label: fn() { Ok([#("session", spec.session)]) },
    code_mode: workspace_plane.CodeModeAttach(
      arms: fn(config) { config },
      tool: codemode_wiring.seam,
    ),
  )
}

// Every cleanup filed so far. They are filed from the build's own process, so
// this reads its own mailbox and never waits.
fn drain(filed: Subject(Cleanup), found: List(Cleanup)) -> List(Cleanup) {
  case process.receive(filed, 0) {
    Ok(cleanup) -> drain(filed, [cleanup, ..found])
    Error(Nil) -> found
  }
}

// The host's view of a started plane. The prompt facts are read once, here,
// beside the helpers: a local plane reads them when a prompt is rendered, but
// that read borrows a helper, and a remote attach pays for it once.
fn plane_over(
  machine: Machine,
  scope: String,
  started: workspace_plane.Started,
  cleanups: List(Cleanup),
) -> Result(host.Plane(remote_census.RemoteCensus), String) {
  let plane = started.plane
  case plane.prompt_facts() {
    Error(reason) -> {
      let _outcome = retire_all(cleanups)
      Error(reason)
    }
    Ok(facts) -> {
      let children = started.children
      Ok(
        host.Plane(
          run: plane.run,
          census: RemoteCensus(
            census: plane.census,
            tools: started.decls,
            prompt: facts,
            broker: broker.subject(plane.broker),
            executor_now_ms: ffi_os.system_time_ms(),
          ),
          children: fn(builder) {
            builder
            |> children.scratch
            |> children.jobs
            |> children.lsp_manager
          },
          close: fn(retire_children) {
            let outcome = retire(plane.close, retire_children, cleanups)
            settle_scope(machine.logger, scope, outcome)
            outcome
          },
        ),
      )
    }
  }
}

// A scope that proved its cleanup has no further use for its directory. One
// that did not keeps it, because a child that may still be running could be
// writing there, and the log says which scope to look at.
fn settle_scope(
  logger: Logger,
  scope: String,
  outcome: protocol.CloseOutcome,
) -> Nil {
  case outcome {
    protocol.AllRetired -> remove_scope(logger, scope)
    protocol.UnknownCleanup(count:) ->
      log.warn(logger, "executor.scope_cleanup_unproven", [
        field.count(key: "unproven", value: count),
      ])
  }
}

fn remove_scope(logger: Logger, scope: String) -> Nil {
  case simplifile.delete(scope) {
    Ok(Nil) -> Nil
    Error(error) ->
      log.warn(logger, "executor.scope_directory_kept", [
        field.text(key: "reason", value: simplifile.describe_error(error)),
      ])
  }
}

/// Retires a scope's plane and reports how that ended.
///
/// The language servers are stopped first, while their manager can still hear
/// the request. The scope's supervised children go next, then the filed
/// cleanups in the order custody defines (broker, then helpers, then the
/// namespace). A failure at one step does not skip the rest, since stopping the
/// helpers is the safe direction whatever happened before. The outcome is
/// `AllRetired` only when nothing failed and the helper pool's own retirement
/// result is among the cleanups that succeeded. A scope that filed no helper
/// cleanup has no witness, so it is `UnknownCleanup` however clean the rest was.
///
/// ## Examples
///
/// ```gleam
/// // executor_plane.retire(fn() { Nil }, fn() { Ok(Nil) }, cleanups)
/// ```
@internal
pub fn retire(
  stop_servers: fn() -> Nil,
  stop_children: fn() -> Result(Nil, String),
  cleanups: List(Cleanup),
) -> protocol.CloseOutcome {
  stop_servers()
  let children = stop_children()
  let ran =
    list.sort(cleanups, fn(left, right) {
      int.compare(rank(left.0), rank(right.0))
    })
    |> list.map(fn(cleanup) { #(cleanup.0, { cleanup.1 }()) })
  let failed =
    list.count(ran, fn(each) { result.is_error(each.1) })
    + case children {
      Ok(Nil) -> 0
      Error(_) -> 1
    }
  let witnessed =
    list.any(ran, fn(each) { each.0 == custody.Helpers && each.1 == Ok(Nil) })
  case failed, witnessed {
    0, True -> protocol.AllRetired
    _, _ -> protocol.UnknownCleanup(count: int.max(1, failed))
  }
}

// A build that failed part way: stop whatever it started.
fn retire_all(cleanups: List(Cleanup)) -> protocol.CloseOutcome {
  retire(fn() { Nil }, fn() { Ok(Nil) }, cleanups)
}

// Shutdown order, as `instance_owner.Part` documents it. Only some of the parts
// are ever filed by a workspace plane.
fn rank(part: custody.Part) -> Int {
  case part {
    custody.Runtime -> 0
    custody.ToolConfig -> 1
    custody.Services -> 2
    custody.Broker -> 3
    custody.Helpers -> 4
    custody.Mcp -> 5
    custody.Storage -> 6
    custody.Namespace -> 7
  }
}

// --- the machine's own settings ------------------------------------------------

fn read_flags(arguments: List(String), flags: Flags) -> Flags {
  case arguments {
    [] -> flags
    ["--helper", value, ..rest] ->
      read_flags(rest, Flags(..flags, helper: Some(value)))
    ["--codemode-seed", value, ..rest] ->
      read_flags(rest, Flags(..flags, codemode_seed: Some(value)))
    ["--best-effort", ..rest] ->
      read_flags(rest, Flags(..flags, demand: Some(exec.BestEffort)))
    ["--full-enforcement", ..rest] ->
      read_flags(rest, Flags(..flags, demand: Some(exec.FullEnforcement)))

    // The daemon validated these two before it got here.
    ["--read-scope", value, ..rest] ->
      read_flags(
        rest,
        Flags(
          ..flags,
          read_scope: option.from_result(catalog.parse_read_scope(value)),
        ),
      )
    ["--network", value, ..rest] ->
      read_flags(
        rest,
        Flags(
          ..flags,
          network: option.from_result(catalog.parse_tool_network(value)),
        ),
      )

    // Flags whose value must not be mistaken for a flag.
    ["--config", _path, ..rest] | ["--codemode-seams", _seams, ..rest] ->
      read_flags(rest, flags)
    [_other, ..rest] -> read_flags(rest, flags)
  }
}

fn read_configuration(path: String) -> Result(String, String) {
  case path {
    "" -> Ok("")
    _ ->
      simplifile.read(path)
      |> result.map_error(fn(error) {
        "the config file "
        <> path
        <> " is unreadable: "
        <> simplifile.describe_error(error)
      })
  }
}

// The same ladder a local session uses: the flag, the helper beside this
// server, `PATH`, then `./bin`. A helper that does not exist is a start
// failure, because the pool spawns lazily and the first tool call would
// otherwise be where the operator learns of it.
fn find_helper(flag: Option(String)) -> Result(String, String) {
  let found =
    serve.helper_ladder(
      flag,
      beside: install.bundled_helper,
      on_path: fn() { ffi_os.find_executable(install.helper_name) },
      in_bin: fn() { install.existing_file("./bin/" <> install.helper_name) },
    )
  case found {
    Error(Nil) ->
      Error(
        "no "
        <> install.helper_name
        <> " sandbox helper found; supply one with --helper <path>",
      )
    Ok(path) ->
      install.existing_file(path)
      |> result.map_error(fn(_nil) {
        "the helper binary does not exist: " <> path
      })
  }
}

// The override is clamped to the range the derived default is, for the reason
// `serve` gives: a pool of one cannot run code mode, and each slot is a jail.
fn pool_size() -> Int {
  workspace_policy.env_text("LOOM_HELPER_POOL")
  |> result.try(int.parse)
  |> result.unwrap(exec.default_pool_size())
  |> int.clamp(min: exec.min_pool_size, max: exec.max_pool_size)
}

fn named_tools(value: String) -> List(String) {
  string.split(value, ",")
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
}

fn gocache_of(machine: Machine, root: String) -> Option(gocache.GoCaches) {
  gocache.locate(
    workspace_policy.lsp_places().cache,
    root,
    machine.workspace.go_module_mirror,
    machine.workspace.go_cache_limit_mib,
  )
}

// The code-mode seed: an explicit flag, else the checkout's own, else the one
// bundled with this release.
fn seed_of(machine: Machine, root: String) -> String {
  let in_workspace = root <> "/" <> serve.default_seed_directory
  serve.seed_ladder(
    machine.codemode_seed,
    in_workspace: fn() { install.existing_directory(in_workspace) },
    bundled: install.bundled_seed,
    otherwise: in_workspace,
  )
}
