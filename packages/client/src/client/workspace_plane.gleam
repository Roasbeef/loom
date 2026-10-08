//// The workspace half of a session: everything that acts on the checkout,
//// built in two steps from plain data.
////
//// A session has two halves. The owner holds the conversation (the durable
//// store, the writer lease, the escalation records, the messaging plane and
//// every client connection). The workspace holds the checkout: the helper
//// pool and the executor over it, the broker, the tools that run against
//// files, the background jobs, the scratch store and the language servers.
//// `serve.assemble_in` used to build both in one function, which tied the
//// workspace to the owner's VM. This module builds the workspace half alone,
//// and hands the owner a `WorkspacePlane`: a record of functions and plain
//// data which is all the owner holds of it afterwards. A workspace on
//// another node can then return a plane of the same shape whose functions
//// send messages, and the owner does not change.
////
//// ## Two steps, because the owner has a decision in the middle
////
//// `prepare` takes a `WorkspaceSpec` and spawns nothing. It discovers the
//// toolchain, composes the session base, refuses a base the sandbox cannot
//// enforce, makes the directories, builds the tool environment and reads the
//// machine's own facts into a `Census`. The census is plain data. The owner
//// reads it before it commits to anything of its own: whether code mode is
//// available decides whether MCP servers are started, and the owner starts
//// those. Nothing can be spawned before that decision is made, which is why
//// there are two steps and not one.
////
//// `start_local` takes the prepared workspace and an `Attach`, which carries
//// everything the owner contributes: the logger, the address namespace, the
//// custody callback, the `OwnerServices` the workspace calls back through,
//// and the owner's arms of the code-mode configuration. It starts the helper
//// pool, the executor and the broker, recomputes the session base now that
//// the owner's storage is open, builds the workspace's tools and returns the
//// plane. `start` is the same step seen through the interface a remote
//// implementation has to match: it returns only what the interface names.
////
//// ## Why the session base is computed twice
////
//// The owner's index and memory files are masked in the base, and whether a
//// mask is needed can depend on files which exist only after the owner has
//// opened its storage, such as SQLite's WAL and shared-memory files. The
//// first computation, in `prepare`, exists to refuse a bad base before any
//// directory is made or lease taken. The second, in `start_local`, is the
//// one every process afterwards runs under. Both are the same function over
//// the same inputs and differ only in when they look at the disk.
////
//// ## Flow
////
//// `prepare` → `start_local` → `start_effect_plane_in` → `code_mode_host` → `workspace_tools_in` → `plane_over`
////
//// 1. `prepare` composes and checks the session base, creates directories
////    and builds the `Census`. It spawns no process.
//// 2. `start_local` logs what `prepare` found, recomputes the base, and
////    starts the effect plane, then the jobs, scratch and language-server
////    wiring.
//// 3. `start_effect_plane_in` starts the helper pool and the executor
////    service over it, then the broker, publishing each to custody in the
////    order they are torn down in.
//// 4. `code_mode_host` builds the code-mode configuration from the broker
////    and the workspace's doors, then applies the owner's arms last.
//// 5. `workspace_tools_in` builds the workspace's tools over those doors and
////    withdraws the ones the operator deactivated.
//// 6. `plane_over` gathers what the owner may call: running a tool, the
////    broker, the census, the prompt facts, directory resolution, live jobs
////    and close.

import broker/broker.{type Broker}
import broker/exec.{type EnforcementDemand, type Pool}
import broker/executor
import broker/policy
import broker/token
import client/catalog
import client/codemode as codemode_wiring
import client/contributions
import client/directories
import client/extension/installed
import client/extension/record as extension_record
import client/git_identity
import client/gocache
import client/host_git
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/jobs
import client/jobseam
import client/jobtools
import client/lsp/jail as lsp_jail
import client/lsp/leases as lsp_leases
import client/lsp/manager as lsp_manager
import client/lsp/profile
import client/lsp/profiles as lsp_profiles
import client/owner_services.{type OwnerServices}
import client/scratch
import client/system_prompt
import client/wiring
import client/working_directory
import client/workspace_policy
import client/worktree_diff
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import lsp/observation
import lsp/query
import runtime/effects
import telemetry/field
import telemetry/log.{type Logger}
import tools/codemode as codemode_tool
import tools/tool
import weft/registry as address

/// What the workspace half needs to be built, as plain data.
///
/// Nothing here is a function, a process or a handle, so a spec can be sent
/// to the machine the workspace is on. The closures a build also needs (the
/// logger, the custody callback, the owner's services) are in `Attach`.
///
/// `base_policy` is the policy the owner's configuration composed for this
/// workspace, before any of the session's own protections and widenings.
/// For a workspace on another node it would be that node's own default.
pub type WorkspaceSpec {
  WorkspaceSpec(
    /// The absolute workspace root.
    workspace: String,
    /// Where the helpers keep their private scratch. Locally this is
    /// derived from the owner's session path. A workspace elsewhere would
    /// choose its own.
    scratch_dir: String,
    /// The sandbox helper executable.
    helper_path: String,
    /// How many helpers the pool may hold.
    helper_pool_size: Int,
    /// Enforcement strictness for every jailed execution.
    demand: EnforcementDemand,
    /// The policy the session base is composed onto.
    base_policy: policy.SandboxPolicy,
    /// The `[tools]` table.
    tools: catalog.ToolsConfig,
    /// Built-in tool names the operator deactivated.
    deactivated_tools: List(String),
    /// The Go caches, when the machine has a per-user cache directory.
    go_caches: Option(gocache.GoCaches),
    /// The machine's home directory, which holds the Git identity and the
    /// installed extensions.
    home: Option(String),
    /// The prepared code-mode build seed.
    codemode_seed: String,
    /// Where cap sockets are bound, instead of under the workspace.
    codemode_sockets: Option(String),
    /// The `[lsp.<name>]` servers the configuration declares.
    lsp_servers: List(profile.LspServer),
    /// How background jobs are limited.
    jobs_policy: jobs.JobsPolicy,
    /// The owner's files to mask, or `None` when the owner is elsewhere.
    owner_files: Option(workspace_policy.OwnerFiles),
  )
}

/// One finding a build wants logged, as data.
///
/// The census carries these instead of logging them so that an owner on
/// another node can show them to the operator. Every field value is text.
pub type Warning {
  Warning(
    /// The log event name.
    event: String,
    /// The event's fields, in the order they are logged.
    fields: List(#(String, String)),
  )
}

/// What the workspace's machine says about itself, as plain data.
///
/// The owner reads the census to decide its own half: whether code mode is
/// available, which environment and policy hooks and goal checks run under,
/// which Git the diff observations call. `prepare` builds it; `start_local`
/// returns the same value with the session base recomputed and the warnings
/// it found while starting.
pub type Census {
  Census(
    /// The workspace root, opaque to the owner: it names a path on the
    /// workspace's machine and is never opened by the owner.
    workspace: String,
    /// The discovered code-mode toolchain as this session may use it, or
    /// the reason there is none.
    toolchain: Result(codemode_wiring.Toolchain, String),
    /// The language servers the plane will serve, with their roots resolved
    /// against this machine.
    lsp_servers: List(profile.LspServer),
    /// What is installed under the machine's extensions root. Read once
    /// here, because the language-server profiles and the extension tools
    /// must be judged against the same reading.
    extensions: List(installed.Discovered),
    /// The operating system and architecture, for the prompt.
    platform: #(String, String),
    /// The shell every jailed command runs under.
    shell: String,
    /// The session base policy the workspace runs under.
    base_policy: policy.SandboxPolicy,
    /// The environment every jailed child inherits.
    env: List(#(String, String)),
    /// The `[tools] env` names this machine has not set.
    unset_env: List(String),
    /// The Git executable fixed calls name, resolved on this machine.
    git: String,
    /// What the build found that an operator should be told.
    warnings: List(Warning),
  )
}

/// A workspace which has been checked and has directories, and has not
/// started anything.
///
/// Not plain data: it carries the machine's environment reader, which is a
/// function. It exists only to be passed from `prepare` to `start_local` on
/// the machine it was made on.
pub type Prepared {
  Prepared(
    /// The spec it was prepared from.
    spec: WorkspaceSpec,
    /// What `prepare` learned.
    census: Census,
    /// Resolves an environment name against this machine's configuration.
    reading: fn(String) -> Result(String, Nil),
    /// The places a language profile's `~/` and `<cache>/` roots resolve
    /// against, read from this machine's environment once.
    places: profile.Places,
    /// The content-addressed overflow directory under the workspace.
    blob_root: String,
  )
}

/// Publishes one resource to the owner's custody before the next begins.
///
/// Arguments are the part, its cleanup, and the transfer which acknowledges
/// custody (unlinking the resource from the builder).
pub type Retain =
  fn(custody.Part, fn() -> Result(Nil, String), fn() -> Nil) ->
    Result(Nil, String)

/// The owner's arms of the code-mode configuration.
pub type CodeModeAttach {
  CodeModeAttach(
    /// Applies the doors only the owner can serve: the Agency and the
    /// seams offered over it, the scheduling door, the MCP layer and the
    /// peer router. Applied after the workspace's own, so the peer router
    /// wraps the working-directory router as it always has.
    arms: fn(codemode_wiring.Config) -> codemode_wiring.Config,
    /// Builds the `code_mode` tool over the finished configuration. The
    /// owner supplies this because background execution is the owner's.
    tool: fn(codemode_wiring.Config) -> codemode_tool.CodeMode,
  )
}

/// Everything the owner contributes to building the workspace half.
///
/// Closures and handles, so unlike the spec it does not cross to another
/// node. A remote implementation builds its own from what it has there.
pub type Attach {
  Attach(
    /// Where the build logs.
    logger: Logger,
    /// The session's address namespace; the plane mints its names here.
    namespace: address.Registry,
    /// Publishes a started resource to the owner's custody.
    retain: Retain,
    /// What the workspace calls back into the owner through. A local plane
    /// never calls `capability`: it composes the owner's code-mode arms
    /// into the router directly. It is the entry a remote plane's programs
    /// reach those arms through.
    owner: OwnerServices,
    /// The labels the jobs actor files itself under, once the session is
    /// known.
    session_label: fn() -> Result(List(#(String, String)), Nil),
    /// The owner's arms of code mode.
    code_mode: CodeModeAttach,
  )
}

/// Whether the helper this session spawns can confine anything.
pub type HelperHealth {
  /// The helper enforces every layer the demand asks for.
  Healthy

  /// The helper is degraded, or would not start or finish its handshake.
  /// Under full enforcement every jailed execution against it fails.
  Degraded
}

/// What the system prompt needs from the workspace's machine and costs
/// something to learn, read only when a prompt is actually rendered.
pub type PromptFacts {
  PromptFacts(
    /// The workspace's own instruction files.
    guidance: List(system_prompt.GuidanceFile),
    /// A warning for each instruction file which existed and could not be
    /// used.
    guidance_notes: List(String),
    /// Whether the helper enforces; learning it borrows a helper.
    helper: HelperHealth,
  )
}

/// The supervised children a plane contributes to the owner's services
/// tree.
///
/// Three adders and not a list because the owner interleaves them with its
/// own children at fixed positions, and the order the tree starts and
/// stops them in is part of the session's behavior. A restart of any one is
/// independent of the others.
pub type Children {
  Children(
    /// The scratch store `kv.*` reads and writes.
    scratch: fn(sup.Builder) -> sup.Builder,
    /// The background-jobs actor.
    jobs: fn(sup.Builder) -> sup.Builder,
    /// The language-server manager, when there is a plane to run.
    lsp_manager: fn(sup.Builder) -> sup.Builder,
  )
}

/// What the owner holds of the workspace after it starts.
///
/// Each function is the whole of one thing the owner may ask. On one
/// machine they call straight through; on another they send a message.
pub type WorkspacePlane {
  WorkspacePlane(
    /// Runs one cleared tool call on the workspace's machine, under the
    /// authority the owner read from its store.
    run: fn(effects.ToolRun, wiring.Authority) -> effects.ToolOutcome,
    /// The capability broker which clears calls for the owner's own
    /// non-tool work: imported hooks, the goal check, Git observations.
    broker: Broker,
    /// What the machine says about itself.
    census: Census,
    /// What the prompt needs, read when a prompt is rendered.
    prompt_facts: fn() -> Result(PromptFacts, String),
    /// Resolves an operator's directory addition against the workspace's
    /// filesystem. Arguments are the requested path and the mode, `"read"`
    /// or anything else for write.
    resolve_directory: fn(String, String) -> Result(String, String),
    /// The live background jobs of a strand.
    live_jobs: fn(String) -> Result(JsonValue, String),
    /// The roots whose death ends the session, named for the log line.
    fatal: List(#(String, Pid)),
    /// Stops what `close_instance` stops explicitly: the language server,
    /// gracefully and then by its operation.
    close: fn() -> Nil,
  )
}

/// What `start` returns through the interface a remote workspace matches.
pub type Started {
  Started(
    /// What the owner holds.
    plane: WorkspacePlane,
    /// The children to splice into the owner's services tree.
    children: Children,
    /// How the workspace's tools describe themselves, in registration
    /// order.
    decls: List(tool.Described),
  )
}

/// A local start: the interface's `Started` and the handles only a plane
/// in the owner's VM can give.
///
/// The extra handles keep `serve.Instance`'s fields populated for the
/// tests and teardown paths that read them, and let the owner build its
/// registry from the real tools while that registry still dispatches
/// workspace tools itself.
pub type Local {
  Local(
    /// The interface's view.
    started: Started,
    /// The helper pool.
    pool: Pool,
    /// The executor service over the pool.
    executor: executor.Executor,
    /// The language-server plane, when one is configured.
    lsp: Option(LspPlane),
    /// The code-mode configuration, when a toolchain was found.
    code_mode_host: Option(codemode_wiring.Config),
    /// The workspace's tools, with their behavior.
    tools: List(tool.Tool),
  )
}

/// The session's language-server plane: the manager every `cap/lsp`
/// capability and post-write diagnostics block asks through, and what its
/// teardown needs.
///
/// One per session, because the helper pool it leases from is one per
/// session (ADR-015 §1, "Pool pressure").
pub type LspPlane {
  LspPlane(
    /// The handle on the supervised manager, reached through its address
    /// so a replacement is the same manager to every door built over it.
    manager: lsp_manager.Manager,
    /// The session's helper-lease counter, started from the pool size.
    leases: lsp_leases.Leases,
    /// The language servers' attribution operation. Session end aborts it
    /// after the graceful stop, so a server that outlived its grace cannot
    /// outlive the session.
    op_id: OpId,
  )
}

// The plane and the manager's configuration, which the service supervisor
// needs to start the manager under its address.
type LspWiring {
  LspWiring(
    plane: LspPlane,
    name: address.Address(lsp_manager.Msg),
    config: lsp_manager.Config,
  )
}

// What a session's effect plane is made of: the executor service sits
// between the broker and the pool and owns the helpers' checkout, checkin
// and close.
type EffectPlane {
  EffectPlane(pool: Pool, broker: Broker, executor: executor.Executor)
}

/// How long a background job's clearance may wait out a congested helper
/// pool, matching the tool plane's own `broker_timeout_ms`.
pub const jobs_clearance_ms = 30_000

// The bound on the synchronous broker clearance call the tool plane makes.
const broker_timeout_ms = 30_000

// --- prepare ---------------------------------------------------------------

/// Checks the workspace and makes it ready to start, spawning nothing.
///
/// The steps are in the order a failure should be met. The toolchain is
/// discovered and judged against the session base first, since the base has
/// to carry the toolchain's mounts. The base is then refused if the sandbox
/// cannot enforce it, before any directory exists, so a bad policy is a boot
/// failure and not a surprise in the first tool call. Only then are the
/// directories made and the environment built.
///
/// `reading` resolves an environment name against the machine's own
/// configuration. It is what `[tools] env` values and the language servers'
/// environment are read through, and it is a function because the
/// configuration may layer a command's output over the process environment.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(prepared) =
/// //   workspace_plane.prepare(spec, reading: workspace_policy.env_text)
/// // prepared.census.toolchain
/// ```
///
pub fn prepare(
  spec: WorkspaceSpec,
  reading reading: fn(String) -> Result(String, Nil),
) -> Result(Prepared, String) {
  let basis = basis_of(spec)
  let discovered = discovered_extensions(spec.home)
  let places = workspace_policy.lsp_places()
  let #(lsp_servers, lsp_warnings) =
    effective_lsp_servers(spec, discovered, places)
  let toolchain =
    codemode_wiring.discover(spec.codemode_seed)
    |> workspace_policy.session_toolchain(basis, spec.owner_files)
  let base = workspace_policy.session_base(basis, spec.owner_files, toolchain)

  // Before a directory is made or a helper is spawned: a base policy the
  // sandbox cannot enforce is a boot failure, not a surprise waiting in
  // the first tool call. See `base_policy_fault`.
  use Nil <- result.try(workspace_policy.base_policy_fault(base))
  use Nil <- result.try(workspace_policy.go_cache_fault(basis, base))
  let blob_root = spec.workspace <> "/" <> codemode_wiring.blob_directory
  use Nil <- result.try(workspace_policy.prepare_directories(
    None,
    spec.workspace,
    blob_root,
    spec.scratch_dir,
    tool_directories(spec),
  ))

  // The environment is built once the code-mode decision is in, so the
  // shell finds the same `gleam` and `erl` the compiler uses.
  let #(env, unset_env) =
    workspace_policy.tool_environment(
      spec.workspace,
      result.map(toolchain, codemode_wiring.toolchain_path)
        |> option.from_result,
      spec.go_caches,
      spec.tools,
      reading:,
    )
  Ok(Prepared(
    spec:,
    census: Census(
      workspace: spec.workspace,
      toolchain:,
      lsp_servers:,
      extensions: discovered,
      platform: ffi_os.platform(),
      shell: workspace_policy.shell_path,
      base_policy: base,
      env:,
      unset_env:,
      git: host_git.program(),
      warnings: lsp_warnings,
    ),
    reading:,
    places:,
    blob_root:,
  ))
}

// What the session base is composed from, read off the spec.
fn basis_of(spec: WorkspaceSpec) -> workspace_policy.Basis {
  workspace_policy.Basis(
    base_policy: spec.base_policy,
    workspace: spec.workspace,
    tools: spec.tools,
    go_caches: spec.go_caches,
  )
}

// The directories a jailed tool writes: its temporary directory, its home,
// and the Go caches' when there are any.
fn tool_directories(spec: WorkspaceSpec) -> List(String) {
  let go_directories =
    option.map(spec.go_caches, gocache.directories) |> option.unwrap([])
  list.append(
    [
      workspace_policy.tool_tmp_directory(spec.workspace),
      workspace_policy.tool_home_directory(spec.workspace),
    ],
    go_directories,
  )
}

// Discovery, once per prepare. The language-server plane and the owner's
// extension tools both read this one answer, so a profile and a tool cannot
// be judged against two different readings of the extensions root. No home
// is no extensions root, which is the same fact to a booting server as an
// empty one.
fn discovered_extensions(home: Option(String)) -> List(installed.Discovered) {
  case home {
    None -> []
    Some(home) -> installed.discover(extension_record.root_for(home))
  }
}

// The servers the plane will serve: the `loom.toml` tables plus every
// installed profile that survives ADR-016 §4's precedence, and from there
// an installed profile is treated exactly as a table is. A refused profile
// and a server whose roots will not resolve are each one warning, and
// neither refuses the boot, for the reason `mcp.unavailable` does not: a
// session without semantic queries is still a session, and the operator is
// told which table to fix.
fn effective_lsp_servers(
  spec: WorkspaceSpec,
  discovered: List(installed.Discovered),
  places: profile.Places,
) -> #(List(profile.LspServer), List(Warning)) {
  let #(effective, refusals) =
    lsp_profiles.effective_lsp_servers(
      configured: spec.lsp_servers,
      installed: workspace_policy.installed_profiles(discovered),
    )
  let refused =
    list.map(refusals, fn(refusal) {
      Warning(event: "lsp.profile_refused", fields: [
        #("extension", refusal.extension),
        #("server", refusal.server),
        #("other", lsp_profiles.describe_claimant(refusal.other)),
        #("reason", lsp_profiles.describe_conflict(refusal.conflict)),
      ])
    })
  let #(servers, unavailable) =
    list.map(effective, fn(server) {
      workspace_policy.lsp_server_roots(server, places)
      |> result.map_error(fn(reason) {
        Warning(event: "lsp.unavailable", fields: [
          #("server", server.name),
          #("reason", reason),
        ])
      })
    })
    |> result.partition
  #(servers, list.append(refused, unavailable))
}

// --- start -----------------------------------------------------------------

/// Starts the workspace half through the interface a remote workspace
/// matches.
///
/// The same start as `start_local`, returning only what the interface
/// names. A caller which must populate fields that need the pool or the
/// executor itself, as the owner's `Instance` does, uses `start_local`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(workspace_plane.Started(plane:, children:, decls:)) =
/// //   workspace_plane.start(prepared, attach)
/// ```
///
pub fn start(prepared: Prepared, attach: Attach) -> Result(Started, String) {
  start_local(prepared, attach) |> result.map(fn(local) { local.started })
}

/// Starts the workspace half in the owner's VM.
///
/// The helper pool, the executor and the broker are started and published
/// to the owner's custody in teardown order. Then the jobs, scratch and
/// language-server wiring is built, the code-mode configuration is
/// composed, the tools are built over all of it, and the plane is returned.
///
/// The session base is recomputed first, and that is not redundant. The
/// owner has opened its storage since `prepare`, and the masks over its
/// files can depend on files that now exist. Every process from here on
/// runs under this base, so it is this one, and not `prepare`'s, which the
/// returned census carries.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(local) = workspace_plane.start_local(prepared, attach)
/// // local.started.plane.census.base_policy
/// ```
///
pub fn start_local(
  prepared: Prepared,
  attach: Attach,
) -> Result(Local, String) {
  let spec = prepared.spec
  let census = prepared.census
  list.each(census.warnings, log_warning(attach.logger, _))

  // The trim and the sweep of retired caches run beside the session, not
  // before it, so a large cache costs the first prompt nothing. See
  // `client/gocache` for why the retire is a rename.
  let _maintenance =
    option.map(spec.go_caches, gocache.start_maintenance(_, attach.logger))

  // The probes can create or retire SQLite WAL and SHM files. Capture
  // conditional masks after those mutations, once, for every effect
  // consumer. The earlier validation still precedes directory creation and
  // lease custody.
  let base =
    workspace_policy.session_base(
      basis_of(spec),
      spec.owner_files,
      census.toolchain,
    )
  use Nil <- result.try(workspace_policy.base_policy_fault(base))

  // One clock function, therefore one era, across session, broker, tools,
  // and provider — the shared-clock requirement the M2 integration learned
  // live (spec-gaps, M2 item 1). The owner builds its clock from the same
  // function.
  let clock = clock.from_function(ffi_os.system_time_ms)
  let entropy = mixed_entropy()
  use effect <- result.try(start_effect_plane_in(
    spec.helper_path,
    base,
    spec.scratch_dir,
    spec.helper_pool_size,
    clock,
    attach.logger,
    attach.retain,
  ))
  let census = Census(..census, base_policy: base)
  local_over(prepared, census, attach, effect, clock, entropy)
}

// The rest of a local start, once the effect plane is up: the doors the
// tools and code mode share, the code-mode configuration, the tools, the
// Git identity and the plane the owner holds.
fn local_over(
  prepared: Prepared,
  census: Census,
  attach: Attach,
  effect: EffectPlane,
  clock: Clock,
  entropy: fn() -> Int,
) -> Result(Local, String) {
  let spec = prepared.spec

  // The scratch store, the jobs actor and the language-server manager are
  // each reached through a name, so the doors can be built now and the
  // actors started under the owner's service supervisor later.
  let scratch_name = address.new_address(attach.namespace)
  let jobs_name = address.new_address(attach.namespace)
  let lsp =
    lsp_wiring(
      prepared,
      census,
      effect.broker,
      clock,
      entropy(),
      address.new_address(attach.namespace),
      attach.logger,
    )
  let doors = doors_over(clock, scratch_name, jobs_name, lsp)
  let host = code_mode_host(spec, census, effect.broker, clock, doors, attach)
  let tools =
    workspace_tools_in(
      spec,
      attach,
      option.map(host, attach.code_mode.tool),
      doors,
      lsp,
    )
  finish_local(
    Wired(scratch_name:, jobs_name:, lsp:, host:, tools:, clock:),
    prepared,
    census,
    attach,
    effect,
    clock,
    entropy,
  )
}

// What `local_over` built before the Git identity and the plane.
type Wired {
  Wired(
    scratch_name: address.Address(scratch.Message),
    jobs_name: address.Address(jobs.Message),
    lsp: Option(LspWiring),
    host: Option(codemode_wiring.Config),
    tools: List(tool.Tool),
    clock: Clock,
  )
}

// The Git identity is resolved before the runtime can commit, so it is the
// last thing a start does that can fail; then the plane is assembled.
fn finish_local(
  wired: Wired,
  prepared: Prepared,
  census: Census,
  attach: Attach,
  effect: EffectPlane,
  clock: Clock,
  entropy: fn() -> Int,
) -> Result(Local, String) {
  let registry = tool.registry(wired.tools)
  use identity <- result.try(prepare_identity(
    prepared,
    census,
    effect.broker,
    clock,
    entropy,
  ))
  list.each(identity, log_warning(attach.logger, _))
  let census =
    Census(..census, warnings: list.append(census.warnings, identity))
  let jobs_wiring =
    jobs_wiring(prepared, census, attach, effect.broker, clock, entropy)
  Ok(Local(
    started: Started(
      plane: plane_over(prepared, census, attach, effect, registry, wired),
      children: children_over(wired, jobs_wiring),
      decls: list.map(tool.registered(registry), tool.describe),
    ),
    pool: effect.pool,
    executor: effect.executor,
    lsp: option.map(wired.lsp, fn(wiring) { wiring.plane }),
    code_mode_host: wired.host,
    tools: wired.tools,
  ))
}

// The children are specified once, here, and the adders hold only the
// specifications. The owner's services tree keeps them for as long as the
// session lives, to restart a child from, so nothing the build used to make
// them (the spec, the census, the owner's services) may be kept alive by
// them.
fn children_over(wired: Wired, jobs_wiring: jobs.Wiring) -> Children {
  let scratch_child =
    scratch.supervised(wired.scratch_name, scratch.default_bounds())
  let jobs_child = jobs.supervised(wired.jobs_name, jobs_wiring)
  let lsp = wired.lsp
  Children(
    scratch: sup.add(_, scratch_child),
    jobs: sup.add(_, jobs_child),
    lsp_manager: with_lsp_manager(_, lsp),
  )
}

// The doors the workspace's tools and its code-mode programs share: one
// scratch store, one jobs actor and one language-server manager answer
// both surfaces, so a program and a tool call cannot disagree about what
// this session holds.
type Doors {
  Doors(
    scratch: scratch.Scratch,
    jobs: jobseam.Door,
    lsp: Option(query.Door),
    observation: Option(observation.Door),
  )
}

fn doors_over(
  clock: Clock,
  scratch_name: address.Address(scratch.Message),
  jobs_name: address.Address(jobs.Message),
  lsp: Option(LspWiring),
) -> Doors {
  Doors(
    scratch: scratch.seam(scratch_name, timeout_ms: scratch.default_timeout_ms),
    jobs: jobseam.door(jobseam.Wiring(
      name: jobs_name,
      clock:,
      rest: jobseam.real_rest(),
      // The same clearance budget the actor's own wiring reads, so the two
      // bounds on one start cannot disagree.
      clearance_ms: jobs_clearance_ms,
    )),
    lsp: option.map(lsp, fn(wiring) { lsp_manager.door(wiring.plane.manager) }),
    observation: option.map(lsp, fn(wiring) {
      lsp_manager.observation_door(wiring.plane.manager)
    }),
  )
}

// The code-mode configuration, or `None` on a host with no usable
// toolchain: a host without one registers no `code_mode` tool at all.
//
// The workspace's doors are applied first and the owner's arms last. The
// two groups set disjoint fields of the configuration, with one exception
// that decides the order: both wrap the per-execution router, the working
// directory's inside and the peer router outside, as they always have.
fn code_mode_host(
  spec: WorkspaceSpec,
  census: Census,
  broker_actor: Broker,
  clock: Clock,
  doors: Doors,
  attach: Attach,
) -> Option(codemode_wiring.Config) {
  use toolchain <- option.then(option.from_result(census.toolchain))
  codemode_wiring.default_config(
    broker: broker_actor,
    clock:,
    workspace: spec.workspace,
    toolchain:,
  )
  |> codemode_wiring.over_scratch(doors.scratch)
  |> codemode_wiring.over_jobs(Some(doors.jobs))
  |> codemode_wiring.sockets_under(spec.codemode_sockets)
  |> codemode_wiring.over_lsp(doors.lsp)
  |> codemode_wiring.over_lsp_observation(doors.observation)
  |> working_directory.over_code_mode(attach.owner.facts)
  |> attach.code_mode.arms
  |> Some
}

// The workspace's tools over the doors above, in registration order, less
// the ones the operator deactivated. `working_directory` and the shell's
// directory belong to the workspace because the directory lives on its
// filesystem, though the cell that remembers it is the owner's.
fn workspace_tools_in(
  spec: WorkspaceSpec,
  attach: Attach,
  code_mode: Option(codemode_tool.CodeMode),
  doors: Doors,
  lsp: Option(LspWiring),
) -> List(tool.Tool) {
  let jobs = jobtools.seam(doors.jobs)
  contributions.workspace_tools(
    code_mode,
    Some(jobs),
    doors.lsp,
    lsp_hints(lsp),
  )
  |> contributions.directory_tools(
    jobs,
    working_directory.door(attach.owner.facts),
  )
  |> list.filter(fn(each) { !list.contains(spec.deactivated_tools, each.name) })
}

// What the owner is given to hold. Each function closes over only what it
// reads, since the plane is copied into every process which holds the
// instance.
fn plane_over(
  prepared: Prepared,
  census: Census,
  attach: Attach,
  effect: EffectPlane,
  registry: tool.Registry,
  wired: Wired,
) -> WorkspacePlane {
  let spec = prepared.spec
  let workspace = spec.workspace
  let broker_actor = effect.broker
  let jobs_name = wired.jobs_name

  // What `run` needs from this machine, and no more: the same slice of the
  // wiring configuration `wiring.run_tool` hands the workspace half.
  let view =
    wiring.WorkspaceView(
      broker: broker_actor,
      broker_timeout_ms:,
      registry:,
      workspace:,
      blob_root: prepared.blob_root,
      base_policy: census.base_policy,
      demand: spec.demand,
      env: census.env,
      clock: wired.clock,
    )

  // The only owner-side functions the workspace half calls while running a
  // tool, and the language-server handle `close` stops. Each closure below
  // holds one of these values and not the whole build.
  let protected = census.base_policy.protected
  let escalate = attach.owner.escalate
  let output = attach.owner.output
  let lsp_plane = option.map(wired.lsp, fn(wiring) { wiring.plane })
  WorkspacePlane(
    run: fn(run, authority) {
      wiring.run_workspace_tool(view, escalate, output, run, authority)
    },
    broker: broker_actor,
    census:,
    prompt_facts: prompt_facts_of(workspace, effect.pool),
    resolve_directory: fn(requested, mode) {
      directories.resolve_addition(workspace, protected, requested, mode)
    },
    live_jobs: fn(strand) {
      jobs.live_jobs(jobs_name, strand, waiting: 1000)
      |> result.map_error(string.inspect)
    },
    fatal: fatal_roots(effect),
    close: fn() { stop_lsp(lsp_plane, broker_actor) },
  )
}

// The prompt facts, read only when a prompt is rendered. Everything
// expensive lives behind this thunk — the workspace's instruction files
// and the helper spawn the degraded question needs — so a resumed session
// whose prompt is already pinned pays for none of it.
fn prompt_facts_of(
  workspace: String,
  pool: Pool,
) -> fn() -> Result(PromptFacts, String) {
  fn() {
    let #(guidance, guidance_notes) =
      system_prompt.discover_workspace(workspace)
    Ok(
      PromptFacts(
        guidance:,
        guidance_notes:,
        helper: case workspace_policy.degraded(pool) {
          True -> Degraded
          False -> Healthy
        },
      ),
    )
  }
}

// The roots whose death ends the session, in the order the owner has
// always listed them.
fn fatal_roots(effect: EffectPlane) -> List(#(String, Pid)) {
  [
    #("the helper pool", exec.pool_pid(effect.pool)),
    #("the executor service", executor.pid(effect.executor)),
    ..case broker.pid(effect.broker) {
      Ok(pid) -> [#("the capability broker", pid)]
      Error(Nil) -> []
    }
  ]
}

/// The wiring the repository observations of this workspace run under: the
/// session's broker and the census's policy, environment and Git.
///
/// The workspace uses it to prepare the tool Git identity, and the owner
/// builds the same value over `plane.broker` for the diff and baseline
/// observations, so the two cannot be configured differently.
///
/// ## Examples
///
/// ```gleam
/// // workspace_plane.worktree_wiring(plane.census, plane.broker, demand, clock, entropy)
/// ```
///
pub fn worktree_wiring(
  census: Census,
  broker_actor: Broker,
  demand: EnforcementDemand,
  clock: Clock,
  entropy: fn() -> Int,
) -> worktree_diff.Wiring {
  worktree_diff.Wiring(
    workspace: census.workspace,
    broker: broker_actor,
    base_policy: census.base_policy,
    clock:,
    demand:,
    env: census.env,
    entropy:,
    git: census.git,
  )
}

// Resolves identity before the runtime can commit. Only global identity
// defaults cross into the tool home; repository settings retain
// precedence. The warning, when there is one, is a finding and not a
// failure.
fn prepare_identity(
  prepared: Prepared,
  census: Census,
  broker_actor: Broker,
  clock: Clock,
  entropy: fn() -> Int,
) -> Result(List(Warning), String) {
  let spec = prepared.spec
  use warning <- result.map(git_identity.prepare(
    worktree_wiring(census, broker_actor, spec.demand, clock, entropy),
    spec.home,
    helper: spec.helper_path,
    reading: workspace_policy.env_text,
  ))
  case warning {
    None -> []
    Some(reason) -> [
      Warning(event: "tools.git_identity_unavailable", fields: [
        #("reason", reason),
      ]),
    ]
  }
}

fn log_warning(logger: Logger, warning: Warning) -> Nil {
  log.warn(
    logger,
    warning.event,
    list.map(warning.fields, fn(pair) { field.text(key: pair.0, value: pair.1) }),
  )
}

// --- the language-server plane ---------------------------------------------
//
// ADR-015 §§1 and 6: a configured `[lsp.<name>]` server runs in the jail as
// a session lease, under the session's own enforcement demand, and every
// surface reaches it through one manager's door. The start does three
// things and no more: it starts the lease counter from the session's pool
// size; it mints the servers' attribution operation; and it describes the
// manager for the service supervisor. Nothing is spawned here — the first
// query starts a server, after the manager's enforcement probe.

// A start with no `[lsp.<name>]` table and no installed profile builds
// nothing and logs nothing: an unconfigured workspace pays nothing (ADR-015
// §6). A counter that will not start refuses every server, as one warning,
// and does not refuse the boot.
fn lsp_wiring(
  prepared: Prepared,
  census: Census,
  broker_actor: Broker,
  clock: Clock,
  seed: Int,
  name: address.Address(lsp_manager.Msg),
  logger: Logger,
) -> Option(LspWiring) {
  let spec = prepared.spec
  case census.lsp_servers {
    [] -> None
    [_, ..] as servers ->
      case lsp_leases.start(spec.helper_pool_size) {
        Error(error) -> {
          log_warning(
            logger,
            Warning(event: "lsp.unavailable", fields: [
              #(
                "servers",
                string.join(list.map(servers, fn(one) { one.name }), ","),
              ),
              #(
                "reason",
                "the helper-lease counter would not start: "
                  <> string.inspect(error),
              ),
            ]),
          )
          None
        }
        Ok(leases) ->
          Some(lsp_plane_wiring(
            prepared,
            census,
            leases,
            broker_actor,
            clock,
            seed,
            name,
          ))
      }
  }
}

// The manager's configuration over the production backend: every server,
// its probe and every symbol search clear through the session's broker,
// under the session's demand and the plane's own operation.
fn lsp_plane_wiring(
  prepared: Prepared,
  census: Census,
  leases: lsp_leases.Leases,
  broker_actor: Broker,
  clock: Clock,
  seed: Int,
  name: address.Address(lsp_manager.Msg),
) -> LspWiring {
  let spec = prepared.spec
  let op_id = lsp_jail.operation(clock, seed:)
  let timing = lsp_manager.default_timing()
  let backend =
    lsp_manager.jailed(lsp_manager.Jailed(
      workspace: spec.workspace,
      session_base: census.base_policy,
      demand: spec.demand,
      toolchain: option.from_result(census.toolchain),
      places: prepared.places,
      // The same reader the jailed tool environment is built from, so
      // `PATH` and a server's `env` names mean what they mean to `bash`.
      reading: prepared.reading,
      run: tool.broker_runner(
        broker: broker_actor,
        waiting: lsp_jail.clearance_wait_ms,
      ),
      abort_step: fn(step_id) {
        broker.abort_step(broker_actor, op_id, step_id:)
      },
      leases:,
      op_id:,
      clock:,
      exec_ms: timing.exec_ms,
    ))
  let config =
    lsp_manager.Config(
      workspace: spec.workspace,
      servers: census.lsp_servers,
      backend:,
      timing:,
    )
  LspWiring(
    plane: LspPlane(
      manager: lsp_manager.addressed(name, config),
      leases:,
      op_id:,
    ),
    name:,
    config:,
  )
}

// The profile hints of the servers the plane serves, as
// `#(server name, hint)` in name order, for code-mode discovery. They are
// read from the wired servers rather than the whole catalogue, so a server
// refused at boot for roots that would not resolve does not describe a
// language the session cannot ask about.
fn lsp_hints(wiring: Option(LspWiring)) -> List(#(String, String)) {
  case wiring {
    None -> []
    Some(wiring) ->
      list.filter_map(wiring.config.servers, fn(server) {
        option.to_result(server.hint, Nil)
        |> result.map(fn(hint) { #(server.name, hint) })
      })
      |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  }
}

// The manager as a supervised child, when there is a plane to run.
fn with_lsp_manager(
  builder: sup.Builder,
  wiring: Option(LspWiring),
) -> sup.Builder {
  case wiring {
    None -> builder
    Some(wiring) ->
      sup.add(builder, lsp_manager.supervised(wiring.name, wiring.config))
  }
}

// Session end for the plane, in ADR-015 §1's order: the graceful stop
// (`shutdown`, `exit`, stdin EOF, waited for in this process), then the
// abort of the plane's operation as the backstop for a server that
// outlived its grace, then the counter.
fn stop_lsp(plane: Option(LspPlane), broker_actor: Broker) -> Nil {
  case plane {
    None -> Nil
    Some(plane) -> {
      lsp_manager.stop(plane.manager)
      broker.abort(broker_actor, plane.op_id)
      lsp_leases.stop(plane.leases)
    }
  }
}

// How this session runs background jobs.
//
// The broker seam is `tools/tool.broker_runner` — the very closure the
// `bash` tool clears through — so a background job admits under exactly
// the rules a foreground one does: the same requirements, the same
// `RefuseNarrowed`, the same enforcement demand, the same escalation
// path. What differs is where it is called from. A job's runner owns the
// events subject, which is what binds the broker relay's caller-watch to
// the job rather than to the session, and what the actor deliberately does
// not do itself.
//
// The clearance budget is the one the tool plane already uses for the same
// wait, so a job queued behind a full helper pool gives up when a
// foreground call would have. The actor reaches the owner only through
// `attach.owner`, so the same actor runs beside a session or away from it.
fn jobs_wiring(
  prepared: Prepared,
  census: Census,
  attach: Attach,
  broker_actor: Broker,
  clock: Clock,
  entropy: fn() -> Int,
) -> jobs.Wiring {
  let spec = prepared.spec
  jobs.Wiring(
    owner: owner_services.jobs_owner(attach.owner),
    session_path: attach.session_label,
    policy: spec.jobs_policy,
    clock:,
    seed: entropy(),
    workspace: spec.workspace,
    base_policy: census.base_policy,
    demand: spec.demand,
    env: census.env,
    clear_call: tool.broker_runner(
      broker: broker_actor,
      waiting: jobs_clearance_ms,
    ),
    clearance_ms: jobs_clearance_ms,
    spill: jobs.blob_spill(root: prepared.blob_root),
    blob_root: prepared.blob_root,
  )
}

// --- the effect plane ------------------------------------------------------

/// A pool of jailed helpers, the executor service over it and the one
/// broker in front, for the one-shot planes: the extension installer's
/// build and `loom ext check`.
///
/// This is the same execution model a session has, and the only one
/// production has: the broker is started with `broker.start_dispatching`
/// over the executor service's dispatcher, so a build or a check gets the
/// relay, the settlement guarantees and the custody proof a session gets.
/// What differs is the owner. A one-shot plane has no custody instance to
/// publish into, so its caller closes the returned executor itself.
///
/// ## Examples
///
/// ```gleam
/// // workspace_plane.start_effect_plane(helper:, base_policy:, tmp_dir:, size:, clock:)
/// ```
///
pub fn start_effect_plane(
  helper helper: String,
  base_policy base_policy: policy.SandboxPolicy,
  tmp_dir tmp_dir: String,
  size size: Int,
  clock clock: Clock,
) -> Result(#(Pool, Broker, executor.Executor), String) {
  use pool <- result.try(start_helper_pool(helper, base_policy, tmp_dir, size))
  use #(service, broker_actor) <- result.map(start_service_lane(
    pool,
    clock,
    log.discard(),
    no_retention,
  ))
  #(pool, broker_actor, service)
}

// A one-shot plane has no custodian to hand a resource to.
fn no_retention(
  _part: custody.Part,
  _cleanup: fn() -> Result(Nil, String),
  _transfer: fn() -> Nil,
) -> Result(Nil, String) {
  Ok(Nil)
}

/// A pool of helpers spawned lazily over the resolved spawn configuration.
/// Both planes build their pool here, exactly as it always was.
///
/// ## Examples
///
/// ```gleam
/// // workspace_plane.start_helper_pool(helper, base_policy, tmp_dir, size)
/// ```
///
pub fn start_helper_pool(
  helper: String,
  base_policy: policy.SandboxPolicy,
  tmp_dir: String,
  size: Int,
) -> Result(Pool, String) {
  let spawn_config =
    exec.SpawnConfig(
      helper_path: helper,
      shell_path: workspace_policy.shell_path,
      base_policy:,
      // Never an opt-out of enforcement on the caller's behalf: on a
      // platform with no jail the helper refuses to serve, which is the
      // refusal `--allow-unenforced` exists to make deliberate.
      helper_args: [],
      tmp_dir:,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  exec.start_pool(size:, spawn: fn() { exec.prepare_helper(spawn_config) })
  |> result.map_error(fn(error) {
    "the helper pool did not start: " <> string.inspect(error)
  })
}

// A session's effect plane. The owned path publishes parked helper custody
// before the first checkout. The pool is built first and the executor
// service is started over its seams before anything can borrow; the broker
// is then given the service's dispatcher, and is the one door every
// clearance site goes through.
fn start_effect_plane_in(
  helper: String,
  base_policy: policy.SandboxPolicy,
  tmp_dir: String,
  size: Int,
  clock: Clock,
  logger: Logger,
  retain: Retain,
) -> Result(EffectPlane, String) {
  use pool <- result.try(start_helper_pool(helper, base_policy, tmp_dir, size))
  use #(service, broker_actor) <- result.try(start_service_lane(
    pool,
    clock,
    logger,
    retain,
  ))
  use broker_pid <- result.try(
    broker.pid(broker_actor)
    |> result.replace_error("the broker died during startup"),
  )
  use Nil <- result.try(
    retain(
      custody.Broker,
      fn() { stop_broker_owned(broker_actor, broker_pid) },
      fn() { process.unlink(broker_pid) },
    ),
  )
  Ok(EffectPlane(pool:, broker: broker_actor, executor: service))
}

// The service lane: the executor service is started over the pool's seams
// before anything can borrow, its `close` becomes the `Helpers` custody
// step (it drains executions for `executor.drain_ms` and then closes the
// pool with its own `executor.helpers_ms`, whose verdict it returns
// unchanged; custody's cleanup steps have no overall deadline, so the 8 s
// this can take fits), and the broker is given its dispatcher. Custody
// unlinks the service with the pool, since both are fatal children the
// instance monitors instead.
fn start_service_lane(
  pool: Pool,
  session_clock: Clock,
  logger: Logger,
  retain: Retain,
) -> Result(#(executor.Executor, Broker), String) {
  use service <- result.try(
    executor.start(executor.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: 15_000) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(waiting) { exec.close_pool(pool, waiting:) },
      incarnation: clock.read(session_clock).0,
      log: logger,
    ))
    |> result.map_error(fn(error) {
      "the executor service did not start: " <> string.inspect(error)
    }),
  )
  use Nil <- result.try(
    retain(
      custody.Helpers,
      fn() {
        executor.close(
          service,
          draining: executor.drain_ms,
          helpers: executor.helpers_ms,
        )
        |> result.map_error(string.inspect)
      },
      fn() {
        process.unlink(exec.pool_pid(pool))
        process.unlink(executor.pid(service))
      },
    ),
  )
  use broker_actor <- result.map(
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: session_clock,
      dispatcher: executor.dispatcher(service),
    )
    |> result.map_error(fn(error) {
      "the broker did not start: " <> string.inspect(error)
    }),
  )
  #(service, broker_actor)
}

// Capture the original actor before requesting stop; absence is not drain
// proof.
fn stop_broker_owned(broker_actor: Broker, pid: Pid) -> Result(Nil, String) {
  let watch = process.monitor(pid)
  broker.stop(broker_actor)

  // The broker is a leaf: its death forbids further lending. The pool's
  // independent inventory still proves every native helper's retirement.
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
    |> process.selector_receive(5000)
  process.demonitor_process(watch)
  outcome |> result.replace_error("the broker did not retire")
}

/// One entropy seam serves two masters: id seeds must never repeat within a
/// session lifetime (spec-gaps WP-E item 6) and the bearer token must be
/// unguessable. A VM-unique monotonic integer gives the first; 64 bits of
/// `crypto:strong_rand_bytes` in the low limb give the second (the token
/// minter keeps only low bits). The sum is injective in the pair, so
/// uniqueness survives the mixing.
///
/// ## Examples
///
/// ```gleam
/// // let seed = workspace_plane.mixed_entropy()
/// // assert seed() != seed()
/// ```
///
pub fn mixed_entropy() -> fn() -> Int {
  let random_bytes = token.production_entropy()
  fn() {
    let unique = ffi_os.unique_positive_integer()
    case random_bytes(8) {
      <<random:size(64)>> -> unique * 18_446_744_073_709_551_616 + random
      _ -> unique
    }
  }
}
