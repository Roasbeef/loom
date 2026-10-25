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
//// ## Where the blobs live, and why not in the scope
////
//// A remote session's content-addressed blobs (the overflow of a large tool
//// result, and the artifacts a code-mode program emits) are written on the
//// executor, and the session's transcript names them by path. They live in
//// `<state root>/blobs/<session>`, outside the scope directory and outside
//// the checkout. The scope directory is removed when a scope retires
//// cleanly, and a reopened session must still read what its transcript
//// references, so the store has to outlive a close. It is never removed here:
//// an operator who retires a session for good removes its directory. The
//// store is kept out of the checkout for the reason the daemon keeps its own
//// out of the workspace, and every jail on the executor masks it
//// (`workspace_policy.protecting_blobs`), so only the harness writes it.
////
//// Legacy adoption (`client/blobs.adopt_legacy`) is not applied. It copies a
//// store an earlier release left inside a workspace so that an older
//// transcript's references resolve, and no release ever wrote a remote
//// session's store into a checkout: registered sessions exist only from this
//// design on, and a session's placement is fixed when it is created.
////
//// ## A worktree for each session
////
//// A workspace configured with `mode = "worktree"` does not run its sessions in
//// `root`. The build first asks `client/worktrees` for the session's own Git
//// worktree and builds the plane over that directory, so the tools, the
//// sandbox's writable root, the language servers and the code-mode work
//// directory are all the tree's and `root` is not writable to the session. The
//// ask is part of the build, which runs in a task of its own, so a long
//// checkout delays only the session that asked and the host answers the others'
//// attaches meanwhile. When the scope retires cleanly the close removes a clean
//// tree and leaves one with changes (protocol-change/095).
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
//// ## The evolution plane
////
//// A scope with code mode also starts an evolution actor (`client/executor_evolution`),
//// which stages, runs and retires the generations of a promoted extension for
//// the orchestrator's session. The actor is built from this machine's own
//// inputs and none of the orchestrator's: the helper pool and policy are the
//// scope's, extension memory goes back through the owner's fact access under
//// the reserved `ext/` prefix, and extension secrets come from this machine's
//// `[secrets]` table and environment, the same store MCP and the workspace
//// plane read. The candidates' scratch is `<state root>/evolution/run/<session>`,
//// and `<state root>/evolution` is masked from every jail, so a build cannot see
//// another scope's scratch.
////
//// The actor is filed under `custody.Evolution`, so a close retires it before
//// the broker and the helpers it runs on. The census carries the compile
//// identity, computed once at attach. A scope with no code mode, or whose
//// identity cannot be observed, starts no actor, files nothing and reports
//// `Uncompiled` with the reason.
////
//// ## Flow
////
//// `machine` → `worktrees_of` → `factory` → `build` → `evolution_of` → `plane_over` → `retire`
////
//// 1. `machine` reads this executor's own settings once, at daemon start.
//// 2. `worktrees_of` starts the sandboxed Git and the gates of the worktree
////    workspaces.
//// 3. `factory` closes over the machine, the configured workspaces and those
////    worktrees.
//// 4. `build` resolves the workspace name, opens the session's tree when the
////    workspace has one, makes the scope directory, and starts the workspace
////    half.
//// 5. `evolution_of` starts the scope's evolution actor when code mode is
////    available, and says in the census whether this machine compiles
////    (`uncompiled` is the answer for a scope that cannot).
//// 6. `plane_over` reads the prompt facts once and wraps the started plane as the
////    host's plane, with the census as plain data.
//// 7. `retire` closes a scope: language servers, children, evolution, broker,
////    then helpers, and reports a clean close only on the helper witness. A
////    clean close then settles the session's tree.

import broker/broker
import broker/exec.{type EnforcementDemand}
import broker/policy
import client/catalog
import client/codemode as codemode_wiring
import client/evolution/machine/local
import client/executor_evolution
import client/extension/memory as extension_memory
import client/gocache
import client/install
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/jobs
import client/lsp/profile
import client/mcp as mcp_wiring
import client/owner_codemode
import client/owner_services
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{RemoteCensus}
import client/secrets
import client/serve
import client/workspace_plane
import client/workspace_policy
import client/workspaces.{type Workspace}
import client/worktrees.{type Worktrees}
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mcp/codegen
import provider/secret
import simplifile
import storage/exec_ledger
import telemetry/field
import telemetry/log.{type Logger}
import tools/codemode as codemode_tool
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
    /// The `[mcp.<name>]` servers this executor can run. A session's attach
    /// names the ones its orchestrator expects here, and only those start.
    mcp_servers: List(catalog.McpServer),
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
  use mcp_servers <- result.try(
    catalog.parse_mcp(text) |> result.map_error(named),
  )
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
    mcp_servers:,
    logger:,
  ))
}

/// Starts what the configured worktree workspaces need: the sandboxed Git and a
/// gate for each. A configuration with none starts nothing. A worktree
/// workspace whose root is not the top of a primary Git checkout is refused
/// here, so the daemon does not start.
///
/// The processes are linked to the caller, which is the process that starts the
/// executor host and lives as long as the daemon.
///
/// ## Examples
///
/// ```gleam
/// // executor_plane.worktrees_of(machine, workspaces)
/// ```
pub fn worktrees_of(
  machine: Machine,
  configured: List(Workspace),
) -> Result(Worktrees, String) {
  worktrees.start(
    worktrees.Config(
      state_root: machine.state_root,
      ledger_path: ledger_path(machine.state_root),
      helper_path: machine.helper_path,
      demand: machine.demand,
      logger: machine.logger,
    ),
    configured,
  )
}

/// Where the executor's execution ledger lives under its state root.
///
/// ## Examples
///
/// ```gleam
/// assert executor_plane.ledger_path("/s") == "/s/exec-ledger.db"
/// ```
pub fn ledger_path(state_root: String) -> String {
  state_root <> "/exec-ledger.db"
}

/// The factory the executor host builds planes with.
///
/// A name that is not in `configured` is refused with a reason an operator can
/// act on, before anything is made. Every other failure is the reason
/// `workspace_plane` gave, and leaves nothing running: whatever the build had
/// started is stopped before the error returns. A worktree workspace's session
/// first gets its tree from `trees`, and a tree that cannot be made is refused
/// as `WorktreeNotMade` with Git's message.
///
/// ## Examples
///
/// ```gleam
/// // host.Config(.., factory: executor_plane.factory(machine, workspaces, trees))
/// ```
pub fn factory(
  machine: Machine,
  configured: List(Workspace),
  trees: Worktrees,
) -> host.PlaneFactory(remote_census.RemoteCensus) {
  fn(spec: host.AttachSpec) { build(machine, configured, trees, spec) }
}

/// Builds a workspace execution plane from configured parameters and attach spec.
fn build(
  machine: Machine,
  configured: List(Workspace),
  trees: Worktrees,
  spec: host.AttachSpec,
) -> Result(host.Plane(remote_census.RemoteCensus), host.PlaneFailure) {
  use workspace <- result.try(
    workspaces.find(configured, spec.workspace)
    |> result.map_error(fn(_missing) {
      host.NoPlaneBuilt(
        "this executor serves no workspace named `" <> spec.workspace <> "`",
      )
    }),
  )
  use root <- result.try(
    bootstrap.canonical_directory(workspace.root)
    |> result.map_error(fn(reason) {
      host.NoPlaneBuilt(
        "the workspace `"
        <> workspace.name
        <> "` is not a directory on this executor: "
        <> reason,
      )
    }),
  )

  // Determine build strategy based on workspace shared or worktree mode.
  case workspace.mode {
    workspaces.Shared -> build_in(machine, root, None, spec)
    workspaces.Worktree(..) -> {
      use tree <- result.try(
        worktrees.open(trees, workspace, spec.session)
        |> result.map_error(host.WorktreeNotMade),
      )
      let custody = Some(Custody(trees:, workspace:, branch: tree.branch))

      // The tree exists from here on, so a build that fails must settle it:
      // a tree that nothing uses and nothing holds changes in is removed, and
      // one that holds changes stays for the next attach to adopt.
      case build_in(machine, tree.path, custody, spec) {
        Ok(plane) -> Ok(plane)
        Error(failure) -> {
          let _closed = worktrees.close(trees, workspace, spec.session)
          Error(failure)
        }
      }
    }
  }
}

// The checkout a scope's tree belongs to, held by the plane so that its close
// can settle the tree.
type Custody {
  Custody(trees: Worktrees, workspace: Workspace, branch: String)
}

// The part of a build that is the same for both modes: the blob store, the
// scope directory and the workspace half, over `directory`, which is `root` for
// a shared workspace and the session's tree for a worktree one.
/// Sets up directories and starts common workspace plane components.
fn build_in(
  machine: Machine,
  directory: String,
  custody: Option(Custody),
  spec: host.AttachSpec,
) -> Result(host.Plane(remote_census.RemoteCensus), host.PlaneFailure) {
  let built = {
    use blob_root <- result.try(blob_directory(machine.state_root, spec.session))
    use scope <- result.try(scope_directory(machine.state_root, spec.session))

    // The evolution directories exist before the base policy that masks them
    // is built, so the mask is applied and not filtered out as a missing path.
    case evolution_scratch(machine.state_root, spec.session) {
      Error(reason) -> {
        remove_scope(machine.logger, scope)
        Error(reason)
      }
      Ok(scratch) ->
        // Attempt to start workspace plane with prepared scopes.
        case start(machine, directory, scope, blob_root, custody, spec) {
          Ok(plane) -> Ok(plane)
          Error(reason) -> {
            remove_scope(machine.logger, scope)
            remove_evolution_scratch(machine.logger, scratch)
            Error(reason)
          }
        }
    }
  }
  result.map_error(built, host.NoPlaneBuilt)
}

// The session's blob store, created if it is not there and private. Unlike
// the scope it is adopted when it exists: a reopened session reads what its
// transcript names, so nothing here is cleared at attach or removed at
// close.
/// Ensures the per-session private blob storage directory exists.
fn blob_directory(
  state_root: String,
  session: String,
) -> Result(String, String) {
  use Nil <- result.try(usable_session(session))
  let blobs = state_root <> "/" <> blob_directory_name
  let store = blobs <> "/" <> session
  use Nil <- result.try(bootstrap.ensure_private_directory(blobs))
  use Nil <- result.try(bootstrap.ensure_private_directory(store))
  Ok(store)
}

// The state root's directory of per-session blob stores.
const blob_directory_name = "blobs"

// The scope's directory, created fresh and private. A directory left by an
// earlier VM held another build's scratch, so it is replaced and not adopted.
/// Creates a clean private scratch directory for session scope isolation.
fn scope_directory(
  state_root: String,
  session: String,
) -> Result(String, String) {
  use Nil <- result.try(usable_session(session))
  let scopes = state_root <> "/scopes"
  let scope = scopes <> "/" <> session
  let _removed = simplifile.delete(scope)
  use Nil <- result.try(bootstrap.ensure_private_directory(scopes))
  use Nil <- result.try(bootstrap.ensure_private_directory(scope))
  Ok(scope)
}

// The evolution plane's directory under the state root. Every scope's candidate
// scratch lives beneath it, and the session's own jails mask it
// (`workspace_policy.protecting_evolution`).
fn evolution_root(state_root: String) -> String {
  state_root <> "/evolution"
}

// One scope's candidate scratch. The session name has been judged by
// `usable_session` wherever this path is made for a use that writes.
fn evolution_run(state_root: String, session: String) -> String {
  evolution_root(state_root) <> "/run/" <> session
}

// The scope's candidate scratch, created private and fresh. A directory left by
// an earlier VM held another build's artifacts, so it is replaced and not
// adopted. It is made for every scope, whether or not code mode starts, so that
// the evolution root the policy masks always exists when the policy is built.
/// Creates the scope's evolution scratch directory and returns its path.
fn evolution_scratch(
  state_root: String,
  session: String,
) -> Result(String, String) {
  use Nil <- result.try(usable_session(session))
  let scratch = evolution_run(state_root, session)
  let _removed = simplifile.delete(scratch)
  use Nil <- result.try(bootstrap.ensure_private_directory(scratch))
  Ok(scratch)
}

// A session name arrives from a peer, so it is judged before it names a path.
fn usable_session(session: String) -> Result(Nil, String) {
  case safe_component(session) {
    True -> Ok(Nil)
    False -> Error("the session name is not usable as a directory name")
  }
}

fn safe_component(name: String) -> Bool {
  worktrees.safe_component(name)
}

// Masks the scopes directory from a worktree session's jail. It sits under the
// state root, which the jail reads on the default host-wide read scope, and
// holds every session's scratch. The whole directory is masked, and it persists,
// so the mask cannot go stale when a sibling closes: a mask over a path that
// has since been deleted is a policy the Linux helper refuses for every later
// call. The same cannot be done for the sibling trees. A mask over all of
// `worktrees/` would hide this session's own tree, and a mask on each sibling
// would name a directory that its close deletes. Trees are therefore not masked
// from one another, which is why protocol-change/095 describes worktree mode as
// protection against accidents and not against a hostile model.
/// Protects sibling worktree scratch scopes from mutual visibility.
fn protecting_siblings(
  base: policy.SandboxPolicy,
  state_root: String,
  custody: Option(Custody),
) -> policy.SandboxPolicy {
  case custody {
    Some(_) -> masking_scopes(base, state_root)
    None -> base
  }
}

/// Adds state root scopes directory to policy protected paths.
fn masking_scopes(
  base: policy.SandboxPolicy,
  state_root: String,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    protected: list.append(base.protected, [state_root <> "/scopes"]),
  )
}

// Prepares and starts the workspace half, filing every cleanup the start hands
// out. A start that fails after resources exist stops them before returning.
/// Initializes base policies, registry namespace, and workspace plane instance.
fn start(
  machine: Machine,
  root: String,
  scope: String,
  blob_root: String,
  custody: Option(Custody),
  spec: host.AttachSpec,
) -> Result(host.Plane(remote_census.RemoteCensus), String) {
  // The store is in the state root but in no directory the state-root masks
  // name, so it takes its own entry. It exists by now, which is all the
  // unconditional entry waits for.
  let base =
    workspace_policy.base_policy_for(root, machine.workspace.read_scope)
    |> workspace_policy.admitting_config_mounts(machine.workspace.mounts)
    |> workspace_policy.protecting_state_root(machine.state_root)
    |> workspace_policy.protecting_blobs(blob_root)
    |> protecting_siblings(machine.state_root, custody)
    |> workspace_policy.protecting_evolution(evolution_root(machine.state_root))
  use prepared <- result.try(
    workspace_plane.prepare(
      workspace_spec(machine, root, scope, blob_root, base),
      reading: fn(name) { secret.lookup(machine.secrets, name) },
    ),
  )
  use namespace <- result.try(registry.start())

  // The registry is linked to this short-lived build process, and its names
  // must outlive it.
  process.unlink(registry.owner(namespace))
  let filed = process.new_subject()
  let mcp = start_mcp(machine, spec.mcp, namespace, filed)
  let configs = process.new_subject()
  let attach = attach_of(machine, spec, namespace, filed, mcp.layer, configs)

  // Start workspace execution plane with prepared attach specs.
  case workspace_plane.start(prepared, attach) {
    Ok(started) -> {
      let cleanups = [
        #(custody.Namespace, fn() { registry.stop(namespace) }),
        ..drain(filed, [])
      ]
      let code_mode = process.receive(configs, 0) |> option.from_result

      // The evolution plane starts last, after everything it runs on exists, so
      // a failure to start it stops the cleanups filed so far and nothing else.
      case
        evolution_of(
          machine,
          spec,
          root,
          started,
          code_mode,
          prepared.census.toolchain,
          namespace,
        )
      {
        Error(reason) -> {
          let _outcome = retire_all(cleanups)
          Error(reason)
        }
        Ok(evolving) ->
          plane_over(
            Built(
              machine:,
              root:,
              scope:,
              custody:,
              session: spec.session,
              started:,
              code_mode:,
              mcp: mcp.statuses,
              evolving:,
            ),
            list.append(cleanups, evolving.cleanups),
          )
      }
    }

    Error(reason) -> {
      let _outcome = retire_all(drain(filed, []))
      let _stopped = registry.stop(namespace)
      Error(reason)
    }
  }
}

// What a scope's evolution plane adds to its plane: the door the host serves
// evolution messages through, the census line the orchestrator reads, and the
// cleanup that retires it.
type Evolving {
  Evolving(
    door: Option(host.Evolution),
    census: remote_census.EvolutionCensus,
    cleanups: List(Cleanup),
  )
}

// Starts the scope's evolution actor when this machine can compile candidates.
//
// The identity is computed once, here, and is the census line: a rebound attach
// reuses the plane and so the line. A machine that cannot compile, because
// code mode found no toolchain or the identity could not be observed, starts no
// actor and files nothing, and the census says why, so an orchestrator opens no
// catalogue against it. Only a failure to start the actor itself is an error,
// and the caller then stops everything the build had started.
//
// The actor is filed under `custody.Evolution`, which ranks before the broker
// and the helpers: it retires its generations while the machinery they run on
// is still up. The memory door and the secrets lookup are this executor's own.
// Memory writes go back through the owner's fact access under the reserved
// `ext/` prefix, and secrets come from this machine's `[secrets]` table and
// environment, the store MCP and the workspace plane read, never from the
// orchestrator's. An extension that needs a secret this machine does not hold
// meets the same missing-secret refusal it would meet anywhere else.
/// Starts the evolution plane for a scope when code mode is available.
fn evolution_of(
  machine: Machine,
  spec: host.AttachSpec,
  root: String,
  started: workspace_plane.Started,
  code_mode: Option(codemode_wiring.Config),
  toolchain: Result(codemode_wiring.Toolchain, String),
  namespace: registry.Registry,
) -> Result(Evolving, String) {
  // Without a code-mode configuration there is no compiler to stage a
  // candidate with, so the scope compiles nothing and says why.
  case code_mode {
    None -> Ok(uncompiled(toolchain_reason(toolchain)))
    Some(host_config) -> {
      let census = started.plane.census
      let clock = host_config.clock
      let scratch = evolution_run(machine.state_root, spec.session)
      let secrets = machine.secrets
      let config =
        local.Config(
          host: codemode_wiring.without_evolution(host_config),
          base: census.base_policy,
          at: serve.hook_coordinates_at(
            root,
            census.base_policy,
            machine.demand,
            census.env,
            workspace_plane.mixed_entropy()(),
            clock,
          ),
          memory: extension_memory.over_facts(spec.owner.facts),
          secrets: fn(name) { secret.lookup(secrets, name) },
          namespace:,
          scratch:,
          logger: machine.logger,
          open: local.open_plane(machine.helper_path, _, scratch, clock),
        )

      // Without an identity there is nothing a candidate could be stamped with.
      case executor_evolution.identity(config) {
        Error(reason) -> Ok(uncompiled(reason))
        Ok(identity) -> {
          use actor <- result.map(
            executor_evolution.start(executor_evolution.Config(
              local: config,
              view: started.view,
              refused: spec.owner.escalate,
              logger: machine.logger,
            )),
          )
          Evolving(
            door: Some(executor_evolution.plane(actor)),
            census: remote_census.Compiles(identity),
            cleanups: [
              #(custody.Evolution, fn() { executor_evolution.retire_all(actor) }),
            ],
          )
        }
      }
    }
  }
}

// An evolving line for a scope that cannot compile: no door, no cleanup.
fn uncompiled(reason: String) -> Evolving {
  Evolving(door: None, census: remote_census.Uncompiled(reason), cleanups: [])
}

// A toolchain that was found but whose configuration never reached the build is
// reported as that, since the discovery has no reason to give.
/// Why code mode is absent, in the words the toolchain discovery used.
fn toolchain_reason(
  toolchain: Result(codemode_wiring.Toolchain, String),
) -> String {
  case toolchain {
    Error(reason) -> reason
    Ok(_) -> "code mode did not start on this executor"
  }
}

/// Constructs workspace specification record for plane preparation.
fn workspace_spec(
  machine: Machine,
  root: String,
  scope: String,
  blob_root: String,
  base: policy.SandboxPolicy,
) -> workspace_plane.WorkspaceSpec {
  workspace_plane.WorkspaceSpec(
    workspace: root,
    blob_root:,
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

// --- MCP servers ----------------------------------------------------------------

// The MCP side of one scope: the layer its code mode is built over, and how
// each server the orchestrator expected here fared.
type Mcp {
  Mcp(layer: mcp_wiring.Layer, statuses: List(remote_census.McpStatus))
}

// How long a scope's close waits for its MCP servers to exit after their kill
// is requested.
const mcp_close_ms = 5000

// Starts the servers the orchestrator expects this executor to run, from this
// executor's own `[mcp.<name>]` tables, and adds the façades of the servers the
// orchestrator runs itself. A server this file does not declare is not started
// and is reported, which is how a missing table is found at attach. A server
// this file declares and the orchestrator does not expect is not started.
//
// The clients are owned by the namespace registry's process, which outlives
// this build and is stopped last when the scope closes, so a client lives as
// long as the plane. Their cleanup is filed under `Mcp` and never fails: the
// transport has already sent the server its kill, and a server that does not
// exit in time is a process leak the operator is told about, not a reason to
// refuse the scope a clean close, because an MCP server is neither jailed nor
// a helper child.
/// Starts prepared MCP servers and registers cleanup callbacks.
fn start_mcp(
  machine: Machine,
  plan: protocol.McpPlan,
  namespace: registry.Registry,
  filed: Subject(Cleanup),
) -> Mcp {
  let declared =
    list.filter(machine.mcp_servers, fn(server) {
      list.contains(plan.expected, server.name)
    })
  let options =
    mcp_wiring.Options(..mcp_wiring.default_options(), secrets: machine.secrets)
  let prepared =
    mcp_wiring.prepare_owned(
      declared,
      options,
      custodian: registry.owner(namespace),
    )
  let logger = machine.logger
  process.send(
    filed,
    #(custody.Mcp, fn() {
      // Close prepared MCP servers within timeout bound.

      // The start outcome determines whether the MCP host can be reported as ready.
      case mcp_wiring.close_prepared(prepared, within: mcp_close_ms) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warn(logger, "executor.mcp_retirement_unconfirmed", [
            field.text(key: "reason", value: reason),
          ])
      }

      Ok(Nil)
    }),
  )

  // Start prepared servers and map facades to external endpoints.
  let #(layer, refusals) = mcp_wiring.start_prepared(prepared)
  let facades =
    list.map(plan.served, fn(facade) {
      mcp_wiring.Elsewhere(
        server: facade.server,
        generated: codegen.Generated(
          module_name: facade.module_name,
          source: facade.source,
          surface: facade.surface,
        ),
      )
    })
  Mcp(
    layer: mcp_wiring.answered_elsewhere(layer, facades),
    statuses: list.map(plan.expected, status_of(_, declared, layer, refusals)),
  )
}

// How one expected server fared, worded for the orchestrator's log line.
/// Computes reported census status for an individual MCP server.
fn status_of(
  name: String,
  declared: List(catalog.McpServer),
  layer: mcp_wiring.Layer,
  refusals: List(mcp_wiring.Refusal),
) -> remote_census.McpStatus {
  let listed = list.key_find(mcp_wiring.listings(layer), name)
  let refused =
    list.find(refusals, fn(refusal) { refusal.server == name })
    |> result.map(fn(refusal) { refusal.reason })
  let present = list.any(declared, fn(server) { server.name == name })

  // Classify server status based on listings, refusals, and declarations.
  case listed, refused, present {
    Ok(tools), _, _ -> remote_census.McpReady(server: name, tools:)
    Error(Nil), Ok(reason), _ -> remote_census.McpRefused(server: name, reason:)
    Error(Nil), Error(Nil), False ->
      remote_census.McpRefused(
        server: name,
        reason: "this executor declares no [mcp." <> name <> "] table",
      )
    Error(Nil), Error(Nil), True ->
      remote_census.McpRefused(server: name, reason: "it did not start")
  }
}

// What the owner contributes to a start, on an executor: the owner services
// the host built for this scope, a code mode whose owner-bound capabilities
// are sent back through them, and a retain function that files each cleanup in
// the build process. The finished code-mode configuration is sent to
// `configs`, because a background program the host starts later runs under it.
/// Assembles workspace plane attach structure with owner services and code mode.
fn attach_of(
  machine: Machine,
  spec: host.AttachSpec,
  namespace: registry.Registry,
  filed: Subject(Cleanup),
  layer: mcp_wiring.Layer,
  configs: Subject(codemode_wiring.Config),
) -> workspace_plane.Attach {
  let owner = spec.owner
  let session = spec.session
  let answered_here = mcp_wiring.answered_here(layer)
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
    owner:,
    session_label: fn() { Ok([#("session", session)]) },
    code_mode: workspace_plane.CodeModeAttach(
      arms: fn(config) {
        config
        |> codemode_wiring.over_mcp(layer)
        |> owner_codemode.over_owner_serving(owner, answered_here:)
      },
      tool: fn(config) {
        process.send(configs, config)
        codemode_wiring.seam(config)
        |> backgrounded(owner)
        |> owner_codemode.advertising_peers
      },
    ),
  )
}

// The `code_mode` tool's background modes on an executor. The record of an
// execution is the owner's, so a launch is a claim sent to the owner and an
// interaction a question to it; the owner then asks this executor's host to
// run the program (`execute`).
/// Wraps code mode with background execution capability delegates.
fn backgrounded(
  mode: codemode_tool.CodeMode,
  owner: owner_services.OwnerServices,
) -> codemode_tool.CodeMode {
  let launch = owner.launch_execution
  codemode_tool.CodeMode(
    ..mode,
    background: Some(codemode_tool.Background(
      launch: fn(request) { launch(terms_of(request)) },
      interact: owner.interact_execution,
    )),
  )
}

// What a launch captured, as the owner is sent it. The parts that name this
// machine (the workspace, the base policy, the demand and the environment) are
// rebuilt here when the program starts, so they never cross the wire.
/// Extracts serializable execution terms for remote background execution launch.
fn terms_of(request: codemode_tool.Request) -> owner_services.ExecutionTerms {
  owner_services.ExecutionTerms(
    strand: request.strand,
    op_id: request.op_id,
    launch_step: request.step_id,
    source_index: request.source_index,
    source: request.source,
    seam: codemode_tool.seam_name(request.seam),
    within_ms: request.within_ms,
    access: request.directory_access,
    grants: request.grants,
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

// What a successful start leaves for `plane_over`.
type Built {
  Built(
    machine: Machine,
    root: String,
    scope: String,
    custody: Option(Custody),
    session: String,
    started: workspace_plane.Started,
    code_mode: Option(codemode_wiring.Config),
    mcp: List(remote_census.McpStatus),
    evolving: Evolving,
  )
}

// The host's view of a started plane. The prompt facts are read once, here,
// beside the helpers: a local plane reads them when a prompt is rendered, but
// that read borrows a helper, and a remote attach pays for it once.
/// Wraps started workspace plane into remote host plane interface.
fn plane_over(
  built: Built,
  cleanups: List(Cleanup),
) -> Result(host.Plane(remote_census.RemoteCensus), String) {
  let plane = built.started.plane
  let machine = built.machine
  let scope = built.scope

  // Verify prompt facts can be queried from started plane.
  case plane.prompt_facts() {
    Error(reason) -> {
      let _outcome = retire_all(cleanups)
      Error(reason)
    }
    Ok(facts) -> {
      let children = built.started.children
      let broker_actor = plane.broker
      let close_plane = plane.close

      // What the close settles after the cleanups have run.
      let logger = machine.logger
      let custody = built.custody
      let session = built.session
      let state_root = machine.state_root
      Ok(
        host.Plane(
          run: plane.run,
          execute: executing(built),
          abort_step: fn(operation, step) {
            case ids.parse_op_id(operation) {
              Ok(op) -> broker.abort_step(broker_actor, op, step)
              Error(_report) -> Nil
            }
          },
          census: RemoteCensus(
            census: plane.census,
            tools: built.started.decls,
            prompt: facts,
            broker: broker.subject(broker_actor),
            mcp: built.mcp,
            branch: option.map(built.custody, fn(held) { held.branch }),
            evolution: built.evolving.census,
          ),
          evolution: built.evolving.door,
          children: fn(builder) {
            builder
            |> children.scratch
            |> children.jobs
            |> children.lsp_manager
          },
          close: fn(retire_children) {
            let outcome = retire(close_plane, retire_children, cleanups)
            settle_scope(logger, scope, outcome)
            settle_evolution(logger, state_root, session, outcome)
            settle_tree(custody, session, outcome)
            outcome
          },
        ),
      )
    }
  }
}

// How the host runs one background program on this plane. The request is
// rebuilt here from what the launch captured and what this plane knows about
// its own machine, and the deadline is the time the orchestrator says is left,
// laid on this machine's clock. A plane with no code-mode toolchain answers an
// errored value, which the record then holds.
/// Reconstructs execution environment and invokes code mode for background request.
fn executing(built: Built) -> fn(host.ExecutionStart) -> json.JsonValue {
  let census = built.started.plane.census
  let base_policy = census.base_policy
  let env = census.env
  let root = built.root
  let demand = built.machine.demand
  let code_mode = built.code_mode
  fn(start: host.ExecutionStart) {
    // Verify that code mode is available to execute request.
    case code_mode {
      None ->
        json.Object([
          #("status", json.String("errored")),
          #(
            "message",
            json.String("this executor offers no code mode to run the program"),
          ),
          #("details", json.Null),
        ])
      Some(config) -> {
        let terms = start.terms
        let #(now, _) = clock.read(config.clock)
        let request =
          codemode_tool.Request(
            source: terms.source,
            seam: seam_of(terms.seam),
            strand: terms.strand,
            op_id: terms.op_id,
            step_id: start.step,
            source_index: terms.source_index,
            workspace: root,
            base_policy:,
            directory_access: terms.access,
            demand:,
            env:,
            within_ms: start.remaining_ms,
            grants: terms.grants,
            observe_output: fn(_tail) { Nil },
          )
        codemode_wiring.Config(
          ..config,
          fixed_deadline: Some(now + start.remaining_ms),
        )
        |> codemode_wiring.execute(request)
        |> codemode_tool.execution_value
      }
    }
  }
}

// The program mode a launch named. The owner built the record from the same
// name and its decoder admits only these two, so anything else is the default.
fn seam_of(name: String) -> codemode_tool.Seam {
  case name {
    "orchestration" -> codemode_tool.OrchestrationSeam
    _ -> codemode_tool.WorkspaceSeam
  }
}

// A scope that proved its cleanup has no further use for its directory. One
// that did not keeps it, because a child that may still be running could be
// writing there, and the log says which scope to look at.
/// Removes session scratch directory if clean shutdown was witnessed.
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

// The candidate scratch follows the scope directory's rule: a scope that proved
// its cleanup has no candidate process left writing there, and one that did not
// keeps the directory for the operator.
/// Removes the scope's evolution scratch when the close was witnessed clean.
fn settle_evolution(
  logger: Logger,
  state_root: String,
  session: String,
  outcome: protocol.CloseOutcome,
) -> Nil {
  case outcome {
    protocol.AllRetired ->
      remove_evolution_scratch(logger, evolution_run(state_root, session))
    protocol.UnknownCleanup(..) -> Nil
  }
}

/// Deletes the evolution scratch directory, logging a warning if that fails.
fn remove_evolution_scratch(logger: Logger, scratch: String) -> Nil {
  case simplifile.delete(scratch) {
    Ok(Nil) -> Nil
    Error(error) ->
      log.warn(logger, "executor.evolution_scratch_kept", [
        field.text(key: "reason", value: simplifile.describe_error(error)),
      ])
  }
}

// A scope that proved its cleanup has no process left in its tree, so the tree
// can be settled: removed when clean, left when it holds changes. A scope that
// did not prove it leaves the tree and its record alone, as it leaves the scope
// directory, for the operator's release to handle.
/// Settles worktree branch and directory after clean retirement.
fn settle_tree(
  custody: Option(Custody),
  session: String,
  outcome: protocol.CloseOutcome,
) -> Nil {
  // Only close worktree when all children cleanly retired.
  case custody, outcome {
    Some(held), protocol.AllRetired -> {
      let _closed = worktrees.close(held.trees, held.workspace, session)
      Nil
    }
    Some(_), protocol.UnknownCleanup(..) | None, _ -> Nil
  }
}

/// Deletes scope directory logging warning if removal fails.
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

  // Determine overall retirement outcome based on failures and witnesses.
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
/// Returns integer ordering rank for plane cleanup parts.
fn rank(part: custody.Part) -> Int {
  case part {
    custody.Runtime -> 0
    custody.ToolConfig -> 1
    custody.Evolution -> 2
    custody.Services -> 3
    custody.Broker -> 4
    custody.Helpers -> 5
    custody.Workspace -> 6
    custody.Mcp -> 7
    custody.Storage -> 8
    custody.Namespace -> 9
  }
}

// --- the machine's own settings ------------------------------------------------

/// Parses command line argument tokens into executor plane flags.
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

/// Reads configuration file content from filesystem path.
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
/// Resolves path to sandbox helper executable across search ladder.
fn find_helper(flag: Option(String)) -> Result(String, String) {
  let found =
    serve.helper_ladder(
      flag,
      beside: install.bundled_helper,
      on_path: fn() { ffi_os.find_executable(install.helper_name) },
      in_bin: fn() { install.existing_file("./bin/" <> install.helper_name) },
    )

  // Verify helper executable exists and is accessible.
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

/// The ledger limits this executor runs under: the defaults, with the number of
/// scopes that are not cleanly closed taken from `LOOM_EXECUTOR_MAX_SCOPES`
/// when it is set to a positive integer.
///
/// An executor at its limit refuses a further session's attach with
/// `CapacityExhausted`, which is what an orchestrator's pool moves past, so an
/// operator who wants a small machine to take fewer sessions than the default
/// of sixteen lowers it.
///
/// ## Examples
///
/// ```gleam
/// assert executor_plane.scope_limits().max_unclean_scopes >= 1
/// ```
pub fn scope_limits() -> exec_ledger.Limits {
  scope_limits_from(workspace_policy.env_text("LOOM_EXECUTOR_MAX_SCOPES"))
}

/// `scope_limits` over a setting already read. A value that is not a positive
/// integer is ignored, as `LOOM_HELPER_POOL` ignores one that does not parse.
///
/// ## Examples
///
/// ```gleam
/// assert executor_plane.scope_limits_from(Ok("2")).max_unclean_scopes == 2
/// assert executor_plane.scope_limits_from(Ok("0")).max_unclean_scopes == 16
/// ```
pub fn scope_limits_from(setting: Result(String, Nil)) -> exec_ledger.Limits {
  let defaults = exec_ledger.default_limits()

  // Parse positive integer override for maximum unclean scopes.
  case result.try(setting, int.parse) {
    Ok(limit) if limit >= 1 ->
      exec_ledger.Limits(..defaults, max_unclean_scopes: limit)
    _ -> defaults
  }
}

// The override is clamped to the range the derived default is, for the reason
// `serve` gives: a pool of one cannot run code mode, and each slot is a jail.
fn pool_size() -> Int {
  workspace_policy.env_text("LOOM_HELPER_POOL")
  |> result.try(int.parse)
  |> result.lazy_unwrap(exec.default_pool_size)
  |> int.clamp(min: exec.min_pool_size, max: exec.max_pool_size)
}

fn named_tools(value: String) -> List(String) {
  string.split(value, ",")
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
}

/// Locates Go module cache and build cache directories for workspace.
fn gocache_of(machine: Machine, root: String) -> Option(gocache.GoCaches) {
  gocache.locate(
    workspace_policy.lsp_places().cache,
    root,
    machine.workspace.go_module_mirror,
    machine.workspace.go_cache_limit_mib,
  )
}

// The code-mode seed: an explicit flag, else the checkout's own when it
// verifies (the same rung a local daemon takes), else the one bundled with
// this release.
/// Resolves code mode seed archive directory path across ladder.
fn seed_of(machine: Machine, root: String) -> String {
  let in_workspace = root <> "/" <> serve.default_seed_directory
  serve.seed_ladder(
    machine.codemode_seed,
    in_workspace: fn() { serve.usable_seed(in_workspace) },
    bundled: install.bundled_seed,
    otherwise: in_workspace,
  )
}
