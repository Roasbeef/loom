//// Session assembly under either daemon custody or an embedded test host.
////
//// The default binary enters client/daemon/main. This module resolves one
//// admitted registration and assembles its durable writer, runtime, broker,
//// helper pool, composition services, and gateway. assemble_owned neither binds
//// a listener nor creates a bearer token; all sessions use the daemon listener.
////
//// The daemon invokes resolve_managed only on explicit create/open. It reloads
//// the saved configuration reference and uses the saved canonical workspace,
//// never the daemon's working directory. Model configuration and helper lookup
//// reuse the same resolver as the embedded host. Credentials remain environment
//// references in configuration and are read only at provider dispatch.
////
//// domain_paths preserves the exact catalogue-selected memory and index paths,
//// including session-only and imported mappings. None retains beside-session
//// files for embedded hosts. Shared coordinator ownership is an additional
//// daemon composition requirement, not a consequence of selecting these paths.
////
//// Resources are published before effects begin. assemble_owned transfers
//// runtime, service, helper, MCP, and storage retirement capabilities to the
//// surviving instance custodian. Failed construction keeps those capabilities
//// retained; it cannot release storage before earlier effects prove retirement.
////
//// A registration that names an executor is assembled by assemble_registered.
//// It runs the same construction, but its workspace half is attached on the
//// executor (client/remote/workspace) instead of prepared and started here, so
//// nothing in it names the registered workspace on this machine's disk.
////
//// boot and open_instance remain internal host/test seams. They are not CLI
//// compatibility modes: invoking this module's main refuses per-session serving.
////
//// ## Flow
////
//// `assemble_owned` → `assemble_owned_with` → `assemble_in` → `open_session_file` → `wiring.build_effects` → `api.open_published` → `close_instance`
////
//// 1. `assemble_owned` (or `assemble_in_domain`, which also hands over the
////    daemon's shared services) enters `assemble_owned_with`, which starts the
////    instance's address namespace and registers it with the custodian.
//// 2. `assemble_in` is the whole construction, in order. It resolves the
////    memory and index paths, then `open_session_file` takes the session's
////    write lease.
//// 3. It names and builds the services: `memory_seam`, `summary_route` and the
////    other per-session actors, then the tool registry. When code mode is
////    present, `open_evolution` first opens the governed-evolution plane
////    (catalogue, live owner, transition queue and their doors), and the
////    registry takes its tools.
//// 4. `system_prompt.pinned_for` reads the pinned prompt before the open, and
////    `wiring.build_effects` assembles the effect record the runtime runs on.
//// 5. `api.open_published` stands the runtime up, `system_prompt.pin_for`
////    writes the prompt back, and the service supervisor then starts.
//// 6. A failure at any step unwinds what earlier steps retained rather than
////    releasing storage early. `boot` adds a listener through `assemble`
////    for host and test seams.
//// 7. `close_instance` drains the hub, closes the runtime, then calls
////    `stop_services` and stops the namespace. `instance_retirement_body`
////    joins the independent retirements, among them `close_evolution`, which
////    closes the transition queue before the live owner.

import broker/broker.{type Broker}
import broker/egress
import broker/exec.{type EnforcementDemand, type Pool}
import broker/executor
import broker/policy
import broker/token
import client/advisor
import client/agency
import client/approval_ceiling
import client/async_codemode
import client/async_runs
import client/blobs
import client/blocksummary
import client/blocksummarybook
import client/btw
import client/catalog
import client/checkpoint
import client/codemode as codemode_wiring
import client/codex/transport as codex_transport
import client/config_watch
import client/context_view
import client/contributions
import client/daemon/domain as domain_service
import client/delegate_drain
import client/delegate_outbox
import client/directories
import client/effect_abort
import client/escalate
import client/evolution
import client/evolution/capability as evolution_capability
import client/evolution/control as evolution_control
import client/evolution/evaluate as evolution_evaluate
import client/evolution/fixture as evolution_fixture
import client/evolution/hook as evolution_hook
import client/evolution/live as evolution_live
import client/evolution/machine as evolution_machine
import client/evolution/machine/local as evolution_machine_local
import client/evolution/machine/remote as evolution_machine_remote
import client/evolution/model_door as evolution_model_door
import client/evolution/prompt as evolution_prompt
import client/evolution/queue as evolution_queue
import client/evolution/record as evolution_record
import client/evolution/retirement as evolution_retirement
import client/evolution/rollout as evolution_rollout
import client/evolution/rollout_host as evolution_rollout_host
import client/evolution/store as evolution_store
import client/evolution/tasks as evolution_tasks
import client/evolution/trace as evolution_trace
import client/extension/dispatch as extension_dispatch
import client/extension/hooks as extension_hooks
import client/extension/hosts as extension_hosts
import client/extension/installed
import client/extension/manifest as extension_manifest
import client/extension/memory as extension_memory
import client/extension/record as extension_record
import client/gateway as hub
import client/git_identity
import client/glance
import client/glancepace
import client/goalcheck
import client/goalcommand
import client/goalloop
import client/gocache
import client/history
import client/hookcompat
import client/hookrunner
import client/hookserve
import client/hookwire
import client/host
import client/install
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/internal/session_owner
import client/internal/shared_history
import client/jobs
import client/mcp as mcp_wiring
import client/memory
import client/memory_config
import client/memory_overview
import client/notes
import client/owner_codemode
import client/owner_services
import client/peer_mail
import client/peer_outbox_drain
import client/peers
import client/permissions
import client/profile_switch
import client/proposals
import client/relayed_session
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census
import client/remote/workspace as remote_workspace
import client/remote_child
import client/remote_drain
import client/remote_reach
import client/remote_top
import client/retryconf
import client/rules
import client/rulescan
import client/schedule
import client/scheduleadmin
import client/schedulescan
import client/scheduleseam
import client/scratch
import client/secrets
import client/server
import client/session_git
import client/skill_tool
import client/system_prompt
import client/tool_holder
import client/upgrade/control as upgrade_control
import client/wiring
import client/workspace_plane
import client/workspace_policy
import client/worktree_diff
import codemode/compile
import codemode/evolution as codemode_evolution
import codemode/seed
import core/clock.{type Clock}
import core/entry as evolution_entry
import core/glance as diagnostic
import core/ids.{type OpId}
import core/json
import core/message
import events/bus
import filepath
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import gleam/result
import gleam/string
import host/bootstrap
import host/skill
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/adapter/gemini
import provider/adapter/openai
import provider/adapter/responses
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/profile as evolution_profile
import provider/secret
import provider/stream
import runtime/api
import runtime/async_execution
import runtime/effects
import runtime/supervisor as runtime_supervisor
import runtime/writer
import session/session
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import storage/snapshot as storage_snapshot
import storage/sqlite
import storage/storage.{type StorageError}
import telemetry/context
import telemetry/field
import telemetry/log.{type Logger}
import tools/advise
import tools/agent.{type Agency}
import tools/codemode as codemode_tool
import tools/evolution as evolution_tool
import tools/history as history_tool
import tools/remember
import tools/tool
import weft/actor as owned_actor
import weft/poll
import weft/registry as address

// The imported-hook layer: load this session's Claude-compatible
// sources, keep the trusted ones, and compose their gates. Loading is
// best-effort with a logged line per skipped source — one broken
// source never takes the session's hooks down with it, and a session
// with no sources composes nothing, which is the same as before this
// existed. The runner context reuses the harness-side coordinates
// the extension bus already clears under, so an imported hook's
// process is attributed the same way a native hook satellite's is.
//
// The workspace's own settings files arrive in the plane's census, read
// where the workspace is, and the operator's file is read here. Whether any
// of them is trusted is decided here from the bytes, against the owner's
// trust record, whichever machine the files were on. The hooks run through
// the plane's broker under the census's policy and environment.

/// Establishes with imported hooks for the caller, keeping its validation and result policy at this boundary.
fn with_imported_hooks(
  built: effects.Effects,
  opened: session.Session,
  settings: Settings,
  clock: Clock,
  plane: workspace_plane.WorkspacePlane,
  call_clock: Clock,
  logger: Logger,
  entropy: fn() -> Int,
) -> effects.Effects {
  let census = plane.census
  let environment = census.env
  let base_policy = census.base_policy
  let located = hookserve.locations(settings.home, census.workspace)
  let trust_root = option.map(settings.home, fn(home) { home <> "/hooktrust" })

  // Construct hook wiring and runner execution context.
  let wiring =
    hookwire.Wiring(
      config: hookcompat.Config(
        entries: [],
        source: hookcompat.Source(label: "none", origin: hookcompat.LoomInline),
      ),
      session_id: settings.session_id,
      transcript_path: settings.session_path,
      workspace: census.workspace,
    )
  let coordinates =
    hook_coordinates(settings, base_policy, entropy(), clock, environment)
  let runner =
    hookrunner.Context(
      broker: plane.broker,
      base_policy: base_policy,
      op_id: coordinates.op_id,
      step_id: "imported-hooks",
      workspace: census.workspace,
      env: hook_environment(environment, settings.home, census.workspace),
      demand: settings.demand,
      // The deadline of a hook's command is absolute and the broker compares
      // it with its own clock, so a hook reads the broker's timebase.
      clock: call_clock,
      session_id: settings.session_id,
      transcript_path: settings.session_path,
    )
  let serving =
    hookserve.load_from(
      hookserve.gather(located, census.hook_files),
      trust_root,
      wiring,
      runner,
    )
  list.each(serving.skipped, fn(skipped) {
    log.warn(logger, "hooks.source_skipped", [
      field.ident(key: "path", value: skipped.path),
      field.text(key: "reason", value: skipped.reason),
    ])
  })

  // The load-time findings of the sources that did load: handler kinds
  // this build parses but does not run, `once` declarations it
  // ignores, events with no moment. One line each, at boot, is the
  // whole of the visible-diagnostics story for a collection that loads
  // without edits — an operator otherwise learns which of their
  // entries never fire by watching for something that does not happen.
  list.each(serving.notes, fn(note) {
    log.info(logger, "hooks.note", [
      field.ident(key: "source", value: note.source_label),
      field.text(key: "what", value: note.what),
    ])
  })

  // Decide how to handle serving.wiring.config.entries {.
  case serving.wiring.config.entries {
    [] -> built
    _ -> {
      // Imported `Stop` hooks are asked at the primary's run ends only;
      // the advisor and every subagent finish their runs without them.
      let stops = fn(operation) {
        notes.strand_of(opened, operation) == Ok(advisor.primary)
      }

      // Decide how to handle hookserve.wire(built, serving, clock, stops) {.
      case hookserve.wire(built, serving, clock, stops) {
        Ok(composed) -> composed
        Error(reason) -> {
          log.warn(logger, "hooks.unavailable", [
            field.text(key: "reason", value: reason),
          ])
          built
        }
      }
    }
  }
}

/// The environment one imported hook's process runs under: the
/// session's own, with `HOME` pointed at the operator's home, plus
/// `CLAUDE_PROJECT_DIR` naming the workspace.
///
/// A jailed *tool* gets a workspace-local `HOME`
/// (`tool_home_directory`) so that what a toolchain writes to its home
/// stays out of the operator's checkout. An imported hook is the
/// opposite case. Ten of the sixteen entries in the reference
/// collection are `~/.claude/hooks/...`, and under Claude that `~` is
/// the operator's home; a hook whose `HOME` was the jail's would look
/// for its own script in a directory that has never held one. Moving
/// the name is also why nothing rewrites the command string: `sh`
/// expands `~` against whatever `HOME` says, in every position it
/// expands it, and a rewriter would have agreed with the shell only in
/// the one position its parser looked at.
///
/// `None` is a daemon started with `HOME` unset — `resolve` records
/// that rather than guessing. There is no home to point at, so the jail
/// home stands and `~` means it.
///
/// `HOME` and `CLAUDE_PROJECT_DIR` are both granted on the session base
/// (`allowing_imported_hook_env` adds the second; `policy.workspace_default`
/// already carries the first), because `hookrunner.call_spec` asks for
/// exactly these keys and `RefuseNarrowed` refuses the whole call over a
/// name the base withholds.
///
/// ## Examples
///
/// ```gleam
/// // serve.hook_environment(env, Some("/Users/o"), "/work")
/// //   // -> [.., #("HOME", "/Users/o"), #("CLAUDE_PROJECT_DIR", "/work")]
/// ```
///
@internal
pub fn hook_environment(
  environment: List(#(String, String)),
  home: Option(String),
  workspace: String,
) -> List(#(String, String)) {
  // Decide how to handle let based =  home {.
  let based = case home {
    Some(operator) ->
      environment
      |> list.filter(fn(pair) { pair.0 != git_identity.environment_name })
      |> list.key_set("HOME", operator)
    None -> environment
  }

  list.key_set(based, "CLAUDE_PROJECT_DIR", workspace)
}

/// Exact domain paths, independent of session filename or admission order.
pub type DomainPaths {
  DomainPaths(
    /// The exact persisted memory database path, including imported filenames.
    memory: String,
    /// The exact persisted history index path, possibly in another directory.
    index: String,
  )
}

/// Which side of a prompt-profile evaluation a session is on. The two sides
/// differ in authority, not only in data: the source session governs the
/// evolution catalogue and a trial is a throwaway session that only runs a
/// candidate against a fixture. Naming the role keeps that authority from
/// riding on whether an optional list happens to be present.
pub type EvolutionRole {
  /// The operator's session. It owns the evolution catalogue, masks the
  /// evolution directories from its jail, offers the evolution tools and
  /// pins whichever profiles the catalogue currently selects.
  Source

  /// A trial session spawned by a source to evaluate one candidate. It
  /// runs exactly `profiles` (empty for a baseline) and holds no
  /// evolution authority: no catalogue, no evolution tools and no upgrade
  /// controller.
  Trial(profiles: List(evolution_profile.Profile))
}

/// Everything a boot needs, resolved: flags parsed, defaults filled,
/// the provider gateway built. `main` assembles this from the command
/// line and the environment; the smoke test assembles it directly with
/// a scripted gateway, which is the injection seam that keeps `boot`
/// testable without the network.
///
/// Constructor invariants: paths are as given (relative paths resolve
/// against the working directory); `bind_port` may be `0` for an
/// ephemeral port; `catalog` is the catalogue `gateway` was built from
/// (the hub serves it and resolves name switches against it); `model`
/// names the identity the configured main route resolves, and
/// `context_window` / `max_output_tokens` are its positive fallback
/// facts (`client/wiring`'s config doc).
pub type Settings {
  Settings(
    /// The SQLite session file, created if absent.
    session_path: String,
    /// The listen interface (`mist` accepts `"localhost"` or an IP).
    bind_host: String,
    /// The listen port; `0` takes an ephemeral one.
    bind_port: Int,
    /// Where the minted bearer token is written, mode `0600`.
    token_path: String,
    /// The agent's workspace root.
    workspace: String,
    /// Exact catalogue-selected memory and index paths. None is the internal
    /// embedded-host layout beside the session, not a managed-domain fallback.
    domain_paths: Option(DomainPaths),
    /// Resident-only peer lookups supplied by the owning daemon.
    peer_directory: Option(peers.Directory),
    /// The daemon's policy and eligibility check for default peer links
    /// (protocol-change/077). `None` links nothing implicitly: an embedded
    /// host, and a daemon whose `[peers]` table is absent.
    peer_defaults: Option(peer_mail.Defaults),
    /// How the session reaches the other orchestrators it may start children on
    /// (protocol-change/084). `None` reaches none, for an embedded host and for a
    /// daemon with no `[orchestrators]` table, and `agent_spawn` then offers no
    /// `on`.
    remote_reach: Option(remote_reach.Reach),
    /// How often the Agency reaps children past their deadlines when nobody is
    /// waiting on them, in milliseconds. `None` reaps only on observation, and
    /// the daemon sets it for a delegate session alone, whose children belong
    /// to a spawner that may never return (protocol-change/084).
    deadline_tick_ms: Option(Int),
    /// The deepest spawn the Agency admits, counting the strand a human talks
    /// to as depth 0, or `None` for the Agency's default of one. The daemon sets
    /// it for a delegate session alone, to its spawner's `max_depth`, so a child
    /// there may start children of its own as the policy allows
    /// (protocol-change/084, phase 4).
    depth_cap: Option(Int),
    /// What a delegate session reports about its children's spend and the
    /// budget it enforces on one child (protocol-change/084, phase 2). `None`
    /// for every session but the delegate session of a metered spawner.
    metering: Option(agency.Metering),
    /// Where a delegate session's parent is, and how the session reaches it
    /// (protocol-change/084, phase 2): the link names the parent session and the
    /// spawner's node, the laptop is the sender that never dials. Both are `None`
    /// for every session but a delegate session, which then runs no instance of
    /// the drainer that sends its children's mail and progress.
    spawner: Option(delegate_outbox.SpawnerLink),
    laptop: Option(delegate_outbox.Laptop),
    /// Told the first human prompt the session accepts on its main strand,
    /// once, so the daemon can seed the catalogue's subtitle
    /// (`protocol-change/067`). `None` for a host with no catalogue.
    first_prompt: Option(fn(String) -> Nil),
    /// What the session's hub needs from the daemon to read and switch its
    /// model profile (`protocol-change/082`): the names, a loader for the
    /// catalogue a profile would route by, the registration write and the
    /// restart. `None` for a host with no daemon, whose hub then answers the
    /// profile commands as unsupported.
    profile_desk: Option(profile_switch.Desk),
    /// Where code-mode cap sockets are bound: `<state root>/run` for a
    /// daemon-managed session, `None` to bind them under the workspace's
    /// `.codemode`. A field because only the daemon knows its state root,
    /// and a socket under the workspace fails in any deep workspace
    /// (issue #611).
    codemode_sockets: Option(String),
    /// The session's base policy — the ceiling every tool call is
    /// composed against, and the thing an escalation widens. `main`
    /// fills it with `workspace_policy.base_policy(workspace)`; it is a field rather than
    /// a call inside `boot` so that a host — or a test — can serve a
    /// narrower base without editing this module. Nothing else about the
    /// boot reads it, so a base that refuses a shipped tool is a
    /// deliberate, in-band posture rather than a broken server.
    base_policy: policy.SandboxPolicy,
    /// The `loom-exec` helper binary.
    helper_path: String,
    /// How many `loom-exec` helpers may run at once. This is the real
    /// ceiling on parallel tool execution: every helper is an OS process
    /// running bwrap and a jail, so the number is a resource budget, not
    /// a policy dial — and it is distinct from the broker's pooled
    /// `max_outstanding`, which exists to refuse amplification rather
    /// than to describe what the host can afford. `resolve` fills it
    /// from `LOOM_HELPER_POOL` or `exec.default_pool_size()`; a host
    /// embedding the server may name its own.
    helper_pool_size: Int,
    /// The name clients subscribe with (derived from the session file).
    session_id: String,
    /// Sandbox enforcement demanded of the helper.
    demand: EnforcementDemand,
    /// The provider gateway, fully routed.
    gateway: provider_gateway.Gateway,
    /// Whether this is the operator's session or an evaluation trial.
    evolution_role: EvolutionRole,
    /// The model catalogue behind the gateway's registry.
    catalog: catalog.Catalog,
    /// The one credential seam this session reads every named secret
    /// through: a model's `api_key_env`, an MCP server's, an
    /// extension's bound egress secret, and each `[tools] env` name. It
    /// answers from the resolved `[secrets]` table first and the
    /// process environment second, so a host that configured no table
    /// gets exactly the environment store it always had. A field rather
    /// than a call inside `boot` for the reason `base_policy` is one: a
    /// test must be able to stand a server up whose credentials are a
    /// fixture rather than the machine's.
    secrets: secret.SecretStore,
    /// The `[secrets]` entries that did not resolve, each with the
    /// reason. `boot` warns one line per entry; nothing else reads it,
    /// and no value ever appears in it.
    secret_failures: List(secrets.Failure),
    /// An explicit `LOOM_SYSTEM_PROMPT` override, which bypasses the
    /// prompt pack entirely. `None` — the ordinary case — leaves `boot`
    /// to use the session's pinned prompt or render the pack.
    system: Option(String),
    /// The operator's home directory, where the global `AGENTS.md`
    /// default is looked for when the workspace has none of its own.
    /// `resolve` fills it from `HOME`, and `None` records that `HOME`
    /// was unset. It is a field rather than an environment read inside
    /// the render for the same reason `base_policy` is one: a host — or
    /// a test — must be able to stand a server up that does not consult
    /// the machine's real home.
    home: Option(String),
    /// The identity new strands are configured with.
    model: machine_strand.ModelIdentity,
    /// Fallback context window for the wiring config.
    context_window: Int,
    /// Fallback output ceiling for the wiring config.
    max_output_tokens: Int,
    /// The adapter api the main route's endpoint speaks, from its
    /// catalogue dialect. Captured durably into every generation intent
    /// (`client/wiring.Config.api`).
    api: String,
    /// Compaction settings for this session's runs and hooks.
    compaction: operation.CompactionSettings,
    /// Where the prepared code-mode build seed lives. A host without one
    /// registers no `code_mode` tool.
    codemode_seed: String,
    /// Which code-mode seams this server offers. A setting rather than a
    /// value `boot` derives, for the same reason `base_policy` is one:
    /// the choice belongs to whoever stands the server up, and the
    /// `Agency` the orchestration seam needs does not exist until `boot`
    /// has built one. The default is `BothSeams`; each submission selects
    /// one of the two isolated capability surfaces.
    codemode_seams: codemode_wiring.Seams,
    /// The triggered project rules from the same `loom.toml`, in file
    /// order. Empty — the ordinary case — starts no scanner at all, so
    /// a server nobody configured rules for runs exactly the processes
    /// it ran before rules existed.
    rules: List(rules.Rule),
    /// The scheduled heartbeats from the same `loom.toml`, in file order.
    /// Empty — the ordinary case — starts no scanner at all, the same
    /// posture `rules` takes, unless `schedule_policy` opens the
    /// model-facing door and gives the scanner something to watch for.
    schedules: List(schedule.Schedule),
    /// Whether the model may create schedules of its own, from the
    /// `[schedules]` table. Defaults to `schedule.default_policy`, which
    /// registers the tools and caps `wake` — see `client/schedule.Policy`
    /// for why waking is an opt-in. Only `ModelSchedulesOff` registers no
    /// schedule tool at all, the way an absent memory plane registers no
    /// `remember`.
    schedule_policy: schedule.Policy,
    /// The `[jobs]` table: the ceiling a background job's wall is clamped
    /// to. Defaults to `client/jobs.default_policy`, an hour, which is
    /// what every session that never mentions jobs gets. Unlike the
    /// scheduling policy this opens no door of its own — the jobs actor
    /// starts either way, because a session that ran jobs before a
    /// restart still has records to sweep.
    jobs_policy: jobs.JobsPolicy,
    /// The `[retry]` table: the provider retry ladder every run on this
    /// session uses. Defaults to `runtime/api.default_retry_policy`,
    /// which never gives up on a retryable failure, so an operator who
    /// wants a run to fail rather than long-poll a refusing provider
    /// sets a bounded `attempts` here.
    retry_policy: operation.NormalizedRetryPolicy,
    /// Built-in tools the operator deactivated, from
    /// `LOOM_DISABLE_TOOLS`. Empty is the ordinary case and the whole
    /// registry stands.
    ///
    /// The list exists so that an extension may stand in for a built-in
    /// without ever overriding one: a deactivated built-in leaves its
    /// name unclaimed, and `contributions.registry` then admits an
    /// extension's tool of that name instead of refusing the boot over
    /// a collision. `client/contributions` has the ruling. Naming a tool
    /// this host does not build is not an error.
    deactivated_tools: List(String),
    /// The `[memory]` table: what each run starts with. Defaults to
    /// `client/memory_config.default_options`, which attaches the notes
    /// index.
    memory: memory_config.Options,
    /// The `[tools]` table: whether jailed tool shells reach the network,
    /// and what else their environment carries. Defaults to
    /// `catalog.default_tools()` — full network and no extra environment
    /// names, paths or literals — which is the jail every session has
    /// until an operator writes otherwise, and is what the
    /// environment-shaped configuration path takes.
    tools: catalog.ToolsConfig,
    /// The advisor strand's resolved identity and policy, or `None` when
    /// the catalogue routes no `advisor` role. `None` is the ordinary
    /// case and starts no advisor at all, the posture `rules` and
    /// `schedules` take: a server nobody configured an advisor for runs
    /// exactly the strands it ran before advisors existed.
    advisor: Option(advisor.Settings),
    /// The workspace's private Go caches (`client/gocache`), or `None`
    /// when the daemon has no per-user cache directory to hold them. Go
    /// then keeps writing under the tool `HOME`, as it did before.
    go_caches: Option(gocache.GoCaches),
  )
}

/// A listener and the session it currently serves. Session assembly itself
/// neither binds a port nor creates a token file.
pub type Booted {
  Booted(
    /// The database, runtime and services behind this listener.
    instance: Instance,
    /// The public transport, stopped before the session closes.
    served: server.Server,
    /// The credential file published for this listener.
    token_path: String,
    /// The interface reported in the startup banner.
    bind_host: String,
    /// The process that owns this stack's teardown; `shutdown` asks it.
    host: host.Host,
  )
}

/// One resident session, independent of any public listener.
///
/// `services` supervises the restartable composition layer. `namespace`
/// belongs to this session, spans those restarts, and is retired on close.
/// Only the process that called `open_instance` or `boot` can receive `stops`.
pub type Instance {
  Instance(
    /// Small communication endpoint projected into the daemon registry.
    peer: peer_mail.Endpoint,
    /// The questions another orchestrator's subagent messages put to this
    /// session's Agency, projected into the daemon registry the same way.
    spawns: agency.DelegateEndpoint,
    /// The questions another orchestrator's children put to this session's
    /// Agency about the mail and progress they send their parent
    /// (protocol-change/084, phase 2), projected the same way.
    inbox: agency.ChildInbox,
    /// The questions the page of a spawner that started this session puts to
    /// it (protocol-change/094), projected into the daemon registry the same
    /// way. A session no spawner started answers each as not relayed.
    relay: relayed_session.Endpoint,
    /// The sole conversation writer and its supervised strands.
    runtime: api.Runtime,
    /// The original storage actor, monitored before another writer call.
    storage_owner: Pid,
    /// The capability broker the session's non-tool callers clear through.
    /// For a workspace on an executor it is a handle on the executor's.
    broker: Broker,
    /// The holder of the configuration tool runs fetch. Kept so the legacy
    /// teardown can stop it after the runtime drains; an owned session
    /// retires it through custody instead, and stopping it twice is a no-op.
    tools: tool_holder.Holder(wiring.Config),
    /// The helper pool, or `None` for a workspace on an executor, whose
    /// helpers are the executor's.
    pool: Option(Pool),
    /// The executor service. It sits between the broker and the pool, so
    /// teardown closes it and it closes the pool, and its death is as fatal
    /// as the pool's. `None` exactly when `pool` is.
    executor: Option(executor.Executor),
    /// Native evolution retirement, including the bounded transition queue.
    evolution_retire: evolution_retirement.Task,
    /// The name the evolution doors are borrowed under, or `None` without an
    /// evolution plane. Exposed so a test can prove `evolution_retire` stops
    /// the cell, which no custody owner does on the legacy path.
    evolution_cell: Option(address.Address(evolution_capability.Message)),
    /// The legacy host owns teardown; daemon instances instead use custody.
    legacy_host: Option(host.Host),
    /// The hub's stable address. Everything that talks to the hub — the
    /// listener, the commit forwarder, the provider tap — holds this
    /// name rather than a pid, which is what lets the hub be restarted
    /// under it.
    gateway: hub.Gateway,
    /// The session's bounded observation of its own Git working tree: the
    /// closure the gateway's `worktree_diff` read runs, kept here as well so
    /// the web view's page can read it under its own admission
    /// (`ui_socket.worktree_answer`) without the gateway's owner-only one
    /// being widened. It closes over the session's workspace and base commit,
    /// takes nothing from a caller, and blocks for up to the observation's own
    /// deadline, so a caller runs it in a task.
    worktree: fn() -> Result(json.JsonValue, String),
    services: Pid,
    /// Reclaimable addresses shared by this session's composition services.
    namespace: address.Registry,
    stops: Subject(host.Stop),
    session_id: String,
    prompt: system_prompt.Assembled,
    /// The `loom-exec` this boot's ladder settled on. Carried so the
    /// listening line can name it: it is the binary that enforces every
    /// jail this session builds, and the ladder that chose it has four
    /// rungs.
    helper_path: String,
    /// The MCP servers this boot started, held so `shutdown` can stop
    /// them. Each owns a child OS process, and nothing else in the tree
    /// has a handle on one: the client actors are deliberately unlinked
    /// (`client/mcp`), so this record is the only way they are reached.
    mcp: mcp_wiring.Layer,
    /// The triggered-rule scanner's name, or `None` on a boot that
    /// configured no rules and therefore started no scanner. A name
    /// rather than a pid, because the scanner is a restartable service
    /// and a pid would go stale the first time it was replaced.
    rulescan: Option(address.Address(writer.Event)),
    /// The scheduled-heartbeat scanner's name, or `None` on a boot that
    /// configured no schedules and therefore started no scanner. Not a
    /// writer subscriber — it is driven by its own injected timer, never
    /// by a commit hint — so its name has nothing to do with
    /// `subscribers:` the way `rulescan`'s does.
    schedulescan: Option(address.Address(schedulescan.Message)),
    /// The operator's goal commands over the advisor actor, or `None` on
    /// a boot that routes no advisor — the same gate the gateway's
    /// `goal_control` seam answers `unsupported` through. Carried so a
    /// host fixture can drive the goal the way the gateway does without
    /// booting the listener, and so the daemon's attach path can fill
    /// the gateway's option from the one place the wiring exists.
    goal: Option(goalcommand.Seam),
    /// The advisor's abort notice, or `None` on a boot that routes no
    /// advisor. The gateway's abort handler casts it for the TUI's abort
    /// command; a host with its own abort door holds the same notice so
    /// its runtime-level aborts reach the goal loop the same way.
    goal_abort: Option(fn(OpId) -> Nil),
    /// The session's language-server plane, or `None` on a boot whose
    /// catalogue configures no `[lsp.<name>]` server, or whose every
    /// server was refused at load. Held so `close_instance` can stop the
    /// server gracefully and then abort the plane's operation, the
    /// backstop ADR-015 §1 assigns to session end.
    lsp: Option(workspace_plane.LspPlane),
    /// What this assembly holds of the workspace half: the functions and
    /// data the owner asks of it, the same shape a workspace on another
    /// node would return. The fields above are the local handles the
    /// teardown paths and the tests read.
    plane: workspace_plane.WorkspacePlane,
  )
}

/// Refuses the removed per-session entrypoint without creating any resource.
/// Use the package entrypoint for the daemon or the explicit embedded host API.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m client -- --state-dir /private/loom
/// ```
pub fn main() -> Nil {
  io.println_error(
    "loomd: use the client entrypoint; per-session server mode was removed",
  )
  ffi_os.halt(1)
}

// — and it must not grow a second copy of any of it, because a divergence
// between the two would mean an extension built under a policy no session
// would have granted.

/// A pool of jailed helpers, the executor service over it and the one broker
/// in front, for the one-shot planes: the extension installer's build and
/// `loom ext check`.
///
/// This is the same execution model a session has, and the only one
/// production has: the broker is started with `broker.start_dispatching`
/// over the executor service's dispatcher, so a build or a check gets the
/// relay, the settlement guarantees and the custody proof a session gets. What
/// differs is the owner. A one-shot plane has no custody instance to publish
/// into, so its caller closes the returned executor itself, with
/// `executor.close` and the same drain and helpers budgets
/// (`stop_build_plane` and `stop_check_plane` do exactly that). Tests and the
/// demo reach the same service through `broker.start`, over a pool's seams.
///
/// ## Examples
///
/// ```gleam
/// // serve.start_effect_plane(helper:, base_policy:, tmp_dir:, size:, clock:)
/// ```
///
pub fn start_effect_plane(
  helper helper: String,
  base_policy base_policy: policy.SandboxPolicy,
  tmp_dir tmp_dir: String,
  size size: Int,
  clock clock: Clock,
) -> Result(#(Pool, Broker, executor.Executor), String) {
  workspace_plane.start_effect_plane(
    helper:,
    base_policy:,
    tmp_dir:,
    size:,
    clock:,
  )
}

// Tears a one-shot plane down: no new calls, then the executor's close, which
// drains what is running and returns the pool's own native-exit verdict. That
// verdict is the only proof of cleanup, so a close that errs is not reported
// as one, and the caller sees the same `Nil` it always did.
//
// The fallback is not a second `StopPool`, which `executor.close` already sent
// through `close_pool`. What `stop_pool` adds is the `ForgetPool` behind it.
// After a close that timed out the pool is still `Closing`, and it parks that
// message until a late exit proves the last helper retired, then stops itself.
// Without it a pool whose proof arrives after the window would outlive the
// plane, which for a plane inside the daemon is a process nobody owns.

/// Establishes stop one shot for the caller, keeping its validation and result policy at this boundary.
fn stop_one_shot(
  broker_actor: Broker,
  service: executor.Executor,
  pool: Pool,
) -> Nil {
  broker.stop(broker_actor)

  // Decide how to handle the branch input.
  case
    executor.close(
      service,
      draining: executor.drain_ms,
      helpers: executor.helpers_ms,
    )
  {
    Ok(Nil) -> Nil
    Error(_unconfirmed) -> exec.stop_pool(pool)
  }
}

/// Everything a jailed offline build needs, and nothing a session does.
pub type BuildPlane {
  BuildPlane(
    /// The broker every clearance goes through.
    broker: Broker,
    /// The pool behind it, held so the plane can be stopped.
    pool: Pool,
    /// The executor service between the two, closed to stop the plane.
    executor: executor.Executor,
    /// The verified `gleam`, `erl` and build seed.
    toolchain: codemode_wiring.Toolchain,
    /// The policy a build's requirements are met against.
    base_policy: policy.SandboxPolicy,
  )
}

/// Runs the helper ladder, starts the effect plane, discovers the
/// toolchain and verifies the seed — the four steps a boot takes before
/// it can build anything, in the order it takes them.
///
/// The one caller besides the boot is `loom ext install`, which is why
/// this exists: an extension is compiled by the same jailed build a
/// code-mode program is, against the same seed, under the same base
/// policy, found by the same ladders. A second implementation would be a
/// second answer to "may this build run", and the whole point of the
/// hermetic build is that there is one.
///
/// The caller owns the returned plane and must `stop_build_plane` it.
///
/// ## Examples
///
/// ```gleam
/// // serve.start_build_plane(helper: None, seed: None, workspace: ".",
/// //   writable: staging, state_root: home <> "/.loom", tmp_dir: staging,
/// //   clock:)
/// ```
///
pub fn start_build_plane(
  helper helper: Option(String),
  seed seed: Option(String),
  workspace workspace: String,
  writable writable: String,
  state_root state_root: String,
  tmp_dir tmp_dir: String,
  clock clock: Clock,
) -> Result(BuildPlane, String) {
  use helper_path <- result.try(find_helper(helper))

  // `workspace` and `writable` are two different questions and a boot
  // only ever asks them of one directory, which is why they were one
  // parameter until now. The seed ladder looks in the *checkout* a
  // contributor ran `make codemode-seed` in; the jail may write only
  // where the build root is, which for an install is under the
  // extensions root and nowhere near the checkout. The policy is the
  // build plane's own rather than a session's for the reason
  // `build_plane_policy` gives: an install has no blob store to mask,
  // and it does have the daemon's credentials one directory up.

  // Discovery runs before the base is built, not after the plane is
  // started, because the base has to carry the toolchain's mounts: under
  // `protocol-change/020` a compile that reaches a region the base does
  // not name is refused by the meet. Asking first also means a host
  // without a toolchain never spawns a pool it would immediately tear
  // down. The toolchain is admitted against the build root it would
  // share a jail with, because a prefix covering that root would leave
  // every compile unable to write its own output.
  let unmounted = workspace_policy.build_plane_policy(writable, state_root)
  use toolchain <- result.try(
    codemode_wiring.discover(seed_root(seed, workspace))
    |> workspace_policy.admissible_toolchain(unmounted),
  )
  let base =
    unmounted
    |> workspace_policy.admitting_codemode(Ok(toolchain))
    |> workspace_policy.merging_mounts

  // The same refusal the boot makes, in the same place in the order: a
  // base policy the sandbox cannot enforce is a failure now, not a
  // surprise inside the build.
  use Nil <- result.try(workspace_policy.base_policy_fault(base))
  use #(pool, broker_actor, service) <- result.try(start_effect_plane(
    helper: helper_path,
    base_policy: base,
    tmp_dir:,
    size: exec.min_pool_size,
    clock:,
  ))
  Ok(BuildPlane(
    broker: broker_actor,
    pool:,
    executor: service,
    toolchain:,
    base_policy: base,
  ))
}

/// A helper pool and broker for proving one language profile, and the
/// base policy both were started under.
pub type CheckPlane {
  CheckPlane(
    /// The broker every clearance goes through: the probe, the server's
    /// lease and every bare-name search.
    broker: Broker,
    /// The pool behind it, held so the plane can be stopped.
    pool: Pool,
    /// The executor service between the two, closed to stop the plane.
    executor: executor.Executor,
    /// The base a server's lease is composed from, as a session's is.
    base_policy: policy.SandboxPolicy,
    /// How many helpers the pool holds, which the lease counter's cap is
    /// derived from (`client/lsp/leases.cap_for`).
    size: Int,
  )
}

/// Starts the effect plane `loom ext check` runs a profile's server on:
/// the helper ladder a boot runs, then a pool and broker over a base that
/// covers the check's scratch workspace and masks the daemon's state
/// root.
///
/// The base is the build plane's (`build_plane_policy`) for the reason
/// that function gives: the scratch workspace sits under the extensions
/// root, one directory below the state root whose credentials no jail
/// may read, and it has no blob store to mask. What differs from a build
/// plane is only what is *not* needed: no code-mode toolchain is
/// discovered, because a profile's server is located on the daemon's
/// `PATH` and a check must run on a host with no build seed, as a profile
/// install does. The pool is the smallest a session may have, which
/// leaves one lease for the one server a check starts at a time.
///
/// The caller owns the plane and must `stop_check_plane` it.
///
/// ## Examples
///
/// ```gleam
/// // serve.start_check_plane(helper: None, workspace: scratch <> "/work",
/// //   state_root: home <> "/.loom", tmp_dir: scratch <> "/tmp", clock:)
/// ```
///
pub fn start_check_plane(
  helper helper: Option(String),
  workspace workspace: String,
  state_root state_root: String,
  tmp_dir tmp_dir: String,
  clock clock: Clock,
) -> Result(CheckPlane, String) {
  use helper_path <- result.try(find_helper(helper))
  let base =
    workspace_policy.build_plane_policy(workspace, state_root)
    |> workspace_policy.merging_mounts

  // Refused before anything is spawned, as a boot refuses: a base the
  // sandbox cannot enforce is a failure of the check's setup, not a
  // server that later fails to start for reasons nobody can read.
  use Nil <- result.try(workspace_policy.base_policy_fault(base))
  use #(pool, broker_actor, service) <- result.try(start_effect_plane(
    helper: helper_path,
    base_policy: base,
    tmp_dir:,
    size: exec.min_pool_size,
    clock:,
  ))
  Ok(CheckPlane(
    broker: broker_actor,
    pool:,
    executor: service,
    base_policy: base,
    size: exec.min_pool_size,
  ))
}

/// Tears a check plane down.
///
/// ## Examples
///
/// ```gleam
/// // serve.stop_check_plane(plane)
/// ```
///
pub fn stop_check_plane(plane: CheckPlane) -> Nil {
  stop_one_shot(plane.broker, plane.executor, plane.pool)
}

/// The `PATH` a build plane's jailed compiler runs with: exactly the two
/// toolchain directories plus the system ones.
///
/// Here rather than at the call site because `BuildPlane` is what holds
/// the toolchain, and a caller assembling its own `PATH` would be a
/// second answer to which `gleam` a build uses.
///
/// ## Examples
///
/// ```gleam
/// // serve.toolchain_path_of(plane) == "/usr/local/bin:/usr/bin:/bin"
/// ```
///
pub fn toolchain_path_of(plane: BuildPlane) -> String {
  codemode_wiring.toolchain_path(plane.toolchain)
}

/// Tears a build plane down. Idempotent enough to sit on every path out
/// of an install, which is where it is called from.
///
/// ## Examples
///
/// ```gleam
/// // serve.stop_build_plane(plane)
/// ```
///
pub fn stop_build_plane(plane: BuildPlane) -> Nil {
  stop_one_shot(plane.broker, plane.executor, plane.pool)
}

// --- the command line ------------------------------------------------------

// The raw flag values, before defaults. Absence is data here so that
// `resolve` owns every default in one place.
type Flags {
  Flags(
    session: Option(String),
    bind: Option(String),
    token_file: Option(String),
    workspace: Option(String),
    helper: Option(String),
    config: Option(String),
    // The model profile the session routes its roles by. It is not a command
    // line flag: only a managed session has one, from its registration, so
    // `resolve_managed` is the one place that sets it.
    profile: Option(String),
    // The model the session's `main` role is pinned to, for the same reason and
    // from the same place (protocol-change/080).
    model: Option(String),
    codemode_seed: Option(String),
    codemode_seams: Option(String),
    demand: Option(EnforcementDemand),
    read_scope: Option(catalog.ReadScope),
    network: Option(catalog.ToolNetwork),
  )
}

/// Establishes parse for the caller, keeping its validation and result policy at this boundary.
fn parse(arguments: List(String)) -> Result(Flags, String) {
  parse_loop(
    arguments,
    Flags(
      session: None,
      bind: None,
      token_file: None,
      workspace: None,
      helper: None,
      config: None,
      profile: None,
      model: None,
      codemode_seed: None,
      codemode_seams: None,
      demand: None,
      read_scope: None,
      network: None,
    ),
  )
}

/// Resolves one durable registration when explicit admission starts its builder.
/// Host defaults contain only helper/configuration/enforcement flags; this seam
/// reuses the ordinary provider/configuration resolver without boot-time opens.
///
/// ## Examples
///
/// ```gleam
/// // serve.resolve_managed(defaults, registration, selected_domain, canonical_state_root)
/// ```
@internal
pub fn resolve_managed(
  defaults: List(String),
  registration: catalogue.Registration,
  selected: domain.Domain,
  state_root: String,
) -> Result(Settings, String) {
  // A registered workspace is a name on another machine. It is carried as
  // given and never canonicalized, and the helper and the Go caches, which are
  // the executor's, are not looked for here.
  let placement = case registration.executor {
    "" -> LocalWorkspace
    _ -> RegisteredWorkspace
  }

  use flags <- result.try(parse(defaults))

  // Decide how to handle let configuration =  registration.configuration {.
  let configuration = case registration.configuration {
    "" -> flags.config
    path -> Some(path)
  }

  use settings <- result.try(resolve(
    Flags(
      ..flags,
      session: Some(registration.path),
      workspace: Some(registration.workspace),
      config: configuration,
      profile: registration.profile,
      model: registration.model,
    ),
    placement,
  ))
  use Nil <- result.try(
    bootstrap.ensure_private_directory(filepath.directory_name(
      selected.memory_path,
    )),
  )
  use Nil <- result.try(
    bootstrap.ensure_private_directory(filepath.directory_name(
      selected.index_path,
    )),
  )
  Ok(
    Settings(
      ..settings,
      session_id: registration.id,
      domain_paths: Some(DomainPaths(selected.memory_path, selected.index_path)),
      codemode_sockets: codemode_socket_root(settings.base_policy, state_root),
      // The daemon's secrets, not the daemon's directory. Masking the
      // whole state root also masked a workspace an operator had every
      // right to open on it; see `state_root_mask_candidates` for the grain and
      // the reason for each entry.
      base_policy: workspace_policy.protecting_state_root(
        settings.base_policy,
        state_root,
      ),
    ),
  )
}

/// Where a managed session binds its code-mode cap sockets: the daemon's
/// `<state root>/run`, unless the session's own writable roots cover it.
///
/// The covered case is a session opened on a directory above the state
/// root, such as the operator's home directory. A jailed process that can
/// write the parent of `run` could replace the directory before a
/// satellite's socket is bound in it. So that session binds under its own
/// work root instead, as every session did before issue #611, and keeps
/// the mask; its socket path is then as long as its workspace makes it,
/// and a workspace too deep is refused in band.
///
/// ## Examples
///
/// ```gleam
/// // serve.codemode_socket_root(workspace_policy.base_policy("/work"), "/home/o/.loom")
/// //   == Some("/home/o/.loom/run")
/// ```
///
@internal
pub fn codemode_socket_root(
  base: policy.SandboxPolicy,
  state_root: String,
) -> Option(String) {
  let root = state_root <> "/" <> codemode_wiring.runtime_directory

  // Decide how to handle the branch input.
  case
    list.any(base.writable_roots, fn(writable) {
      policy.covers(root: writable, path: root)
    })
  {
    True -> None
    False -> Some(root)
  }
}

/// Builds the services a domain's sessions share: the recall index over the
/// domain's own sources. Session provider and tool settings never choose this
/// shared owner's configuration.
///
/// The stored configuration is still loaded and discarded, so a file no
/// session could open under refuses the domain at admission, in the file's own
/// words, rather than failing each session after the domain is built.
///
/// ## Examples
///
/// ```gleam
/// // serve.build_domain(selected, sources, owner)
/// ```
@internal
pub fn build_domain(
  selected: domain.Domain,
  sources: fn() -> Result(List(shared_history.Source), String),
  owner: custody.Owner,
) -> Result(domain_service.Services, String) {
  // Decide how to handle let configuration =  selected.configuration {.
  let configuration = case selected.configuration {
    "" -> None
    path -> Some(path)
  }

  use _loaded <- result.try(load_config(configuration, None, None))
  use Nil <- result.try(
    bootstrap.ensure_private_directory(filepath.directory_name(
      selected.memory_path,
    )),
  )
  use Nil <- result.try(
    bootstrap.ensure_private_directory(filepath.directory_name(
      selected.index_path,
    )),
  )
  domain_service.build(
    domain_service.Config(history: history.SharedConfig(
      index_path: selected.index_path,
      sources: with_memory_source(sources, selected.memory_path),
      timeout_ms: history.default_timeout_ms,
      batch_entries: 100,
    )),
    owner,
  )
}

/// Adds the domain's memory store to the sources its history owner refreshes.
///
/// The store is a session file like the conversations beside it, and its
/// `memory/note` entries are what `history_search kind=note` returns, so the
/// owner indexes it by the route every other source takes. A store that does
/// not exist yet, or has no identity yet, contributes nothing and the next
/// refresh asks again, because the resolver runs afresh for every job.
///
/// ## Examples
///
/// ```gleam
/// // serve.with_memory_source(sources, "/d/loom-memory.db")()
/// ```
@internal
pub fn with_memory_source(
  sources: fn() -> Result(List(shared_history.Source), String),
  memory_path: String,
) -> fn() -> Result(List(shared_history.Source), String) {
  fn() {
    use found <- result.map(sources())

    // Decide how to handle memory_source(memory_path) {.
    case memory_source(memory_path) {
      Ok(source) -> list.append(found, [source])
      Error(Nil) -> found
    }
  }
}

// The memory store's identity is read without its writer lease, so a
// `remember` call holding it never delays a search.

/// Establishes memory source for the caller, keeping its validation and result policy at this boundary.
fn memory_source(path: String) -> Result(shared_history.Source, Nil) {
  use #(identity, _parent) <- result.try(
    sqlite.identity(path:) |> result.replace_error(Nil),
  )
  use text <- result.try(option.to_result(identity, Nil))
  use session <- result.map(
    ids.parse_session_id(text) |> result.replace_error(Nil),
  )
  shared_history.Source(session:, path:)
}

/// Derives one stable workspace domain, independent of session filename and cwd.
/// This separates paths; ownership of simultaneous workspace writers remains a
/// daemon composition responsibility rather than a property of the hash.
///
/// ## Examples
///
/// ```gleam
/// // serve.workspace_data_root("/private/loom", "/work/project")
/// ```
@internal
pub fn workspace_data_root(
  state_root: String,
  canonical_workspace: String,
) -> String {
  state_root
  <> "/workspaces/"
  <> {
    canonical_workspace
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
  }
}

/// Establishes parse loop for the caller, keeping its validation and result policy at this boundary.
fn parse_loop(arguments: List(String), flags: Flags) -> Result(Flags, String) {
  // Decide how to handle arguments {.
  case arguments {
    [] -> Ok(flags)
    ["--session", value, ..rest] ->
      parse_loop(rest, Flags(..flags, session: Some(value)))
    ["--bind", value, ..rest] ->
      parse_loop(rest, Flags(..flags, bind: Some(value)))
    ["--token-file", value, ..rest] ->
      parse_loop(rest, Flags(..flags, token_file: Some(value)))
    ["--workspace", value, ..rest] ->
      parse_loop(rest, Flags(..flags, workspace: Some(value)))
    ["--helper", value, ..rest] ->
      parse_loop(rest, Flags(..flags, helper: Some(value)))
    ["--config", value, ..rest] ->
      parse_loop(rest, Flags(..flags, config: Some(value)))
    ["--codemode-seed", value, ..rest] ->
      parse_loop(rest, Flags(..flags, codemode_seed: Some(value)))
    ["--codemode-seams", value, ..rest] ->
      parse_loop(rest, Flags(..flags, codemode_seams: Some(value)))
    ["--read-scope", value, ..rest] -> {
      use scope <- result.try(catalog.parse_read_scope(value))
      parse_loop(rest, Flags(..flags, read_scope: Some(scope)))
    }
    ["--network", value, ..rest] -> {
      use network <- result.try(catalog.parse_tool_network(value))
      parse_loop(rest, Flags(..flags, network: Some(network)))
    }
    ["--best-effort", ..rest] ->
      set_demand(rest, flags, exec.BestEffort, "--best-effort")
    ["--full-enforcement", ..rest] ->
      set_demand(rest, flags, exec.FullEnforcement, "--full-enforcement")
    [unknown, ..] -> Error("unknown argument `" <> unknown <> "`\n" <> usage)
  }
}

const usage =
  "usage: loomd --session <path.db>
  [--bind <host:port>]     listen interface (default 127.0.0.1:0)
  [--token-file <path>]    bearer token file (default <session>.token)
  [--workspace <dir>]      workspace root (default the current directory)
  [--helper <path>]        loom-exec binary (default: beside this server, then PATH, then ./bin)
  [--config <loom.toml>]   model catalogue file (default: LOOM_* env vars)
  [--read-scope <scope>]   host (default) or workspace; protected paths remain masked
  [--network <mode>]       full (default) or off for jailed tools
  [--codemode-seed <dir>]  code-mode build seed (default <workspace>/build/codemode-seed, then the bundled one)
  [--codemode-seams <s>]   code-mode seams: workspace, orchestration, both (default both)
  [--full-enforcement]     require every requested resource and lifecycle layer
  [--best-effort]          accept any degraded sandbox helper"

/// Establishes set demand for the caller, keeping its validation and result policy at this boundary.
fn set_demand(
  rest: List(String),
  flags: Flags,
  demand: EnforcementDemand,
  flag: String,
) -> Result(Flags, String) {
  case flags.demand {
    None -> parse_loop(rest, Flags(..flags, demand: Some(demand)))
    Some(_) ->
      Error(
        "`"
        <> flag
        <> "` cannot be combined with another enforcement flag\n"
        <> usage,
      )
  }
}

// Where the workspace a session is resolved for lives. A registered workspace
// is a name that only its executor can resolve, so resolving one must not look
// for anything on this machine's disk on its behalf.
type Placement {
  LocalWorkspace
  RegisteredWorkspace
}

// Fills every default and builds the provider gateway from the model
// catalogue — the `--config` file when given, the environment-shaped
// one-entry catalogue otherwise — turning Flags into a bootable
// Settings. The new-strand identity and the wiring's fallback model
// facts all come from the main route's head entry, so one catalogue is
// the single source for everything model-shaped.

/// Establishes resolve for the caller, keeping its validation and result policy at this boundary.
fn resolve(flags: Flags, placement: Placement) -> Result(Settings, String) {
  // Decide how to handle use session_path <- result.try( flags.session {.
  use session_path <- result.try(case flags.session {
    Some(path) -> Ok(path)
    None -> Error("--session is required\n" <> usage)
  })

  use #(bind_host, bind_port) <- result.try(
    split_bind(option.unwrap(flags.bind, "127.0.0.1:0")),
  )

  // Decide how to handle use workspace <- result.try( flags.workspace {.
  use workspace <- result.try(case flags.workspace {
    Some(dir) -> Ok(dir)
    None ->
      simplifile.current_directory()
      |> result.map_error(fn(error) {
        "the working directory is unreadable: " <> string.inspect(error)
      })
  })

  // Decide how to handle use helper_path <- result.try( placement {.
  use helper_path <- result.try(case placement {
    LocalWorkspace -> find_helper(flags.helper)
    RegisteredWorkspace -> Ok("")
  })

  // The override is clamped to the same range the derived default is,
  // and both ends are load-bearing. A pool must hold at least two
  // helpers or code mode cannot run at all: a satellite holds one for
  // the node itself while the program's capability calls ask for
  // another, so a one-slot pool would make every cap call wait out its
  // whole budget against a helper that is never coming back, then
  // refuse. `min_pool_size` is well above that. At the other end each
  // slot is a live bwrap jail, so an operator's typo must not be able
  // to ask the host for ten thousand of them.
  let helper_pool_size =
    env_int_or("LOOM_HELPER_POOL", exec.default_pool_size())
    |> int.clamp(min: exec.min_pool_size, max: exec.max_pool_size)
  use
    #(
      catalogue,
      rule_list,
      schedule_list,
      schedule_policy,
      jobs_policy,
      retry_policy,
      memory,
      tools,
      secret_entries,
      workspace_config,
      advisor_config,
    )
  <- result.try(load_config(flags.config, flags.profile, flags.model))

  // parse guarantees a routed, resolvable main chain, and the env
  // catalogue routes one by construction; the check stays for
  // directly-constructed catalogues.
  use main_entry <- result.try(
    catalog.main_model(catalogue)
    |> result.replace_error("the catalogue routes no usable main model"),
  )
  use codemode_seams <- result.try(parse_codemode_seams(flags.codemode_seams))

  // Every `[secrets]` entry run here, because the gateway built a few
  // lines down closes over the store and every later reader of a
  // credential name reads the same one. `resolve` has no logger of its
  // own, so the failures ride along in `Settings` and `boot` warns about
  // them beside the `[tools] env` names it could not find — one place,
  // one moment, for both kinds of missing credential.
  //
  // This runs on each session create and open, not once per daemon,
  // because `resolve_managed` reaches it every time. A rotated token is
  // therefore picked up without restarting the daemon; the cost is that
  // an open pays for every entry serially, bounded by
  // `secrets.default_timeout_ms` each.
  let #(resolved, secret_failures) =
    secrets.resolve(
      secret_entries,
      running: secrets.host_runner(),
      within: secrets.default_timeout_ms,
    )
  let secret_store = secrets.store(resolved, beneath: secret.env())
  let clock = clock.from_function(ffi_os.system_time_ms)

  // The gateway is named rather than built inside the literal below,
  // because the advisor route is resolved through it: the advisor takes
  // the same fallback walk every other role does, so a chain whose head
  // names an unregistered provider falls through to the next usable
  // entry exactly as `main` would.
  let gateway =
    catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret_store,
      clock:,
    )
    |> provider_gateway.with_codex_transport(codex_transport.transport())

  Ok(
    Settings(
      session_path:,
      bind_host:,
      bind_port:,
      token_path: option.lazy_unwrap(flags.token_file, fn() {
        session_path <> ".token"
      }),
      workspace:,
      domain_paths: None,
      peer_directory: None,
      peer_defaults: None,
      remote_reach: None,
      deadline_tick_ms: None,
      depth_cap: None,
      metering: None,
      spawner: None,
      laptop: None,
      first_prompt: None,
      profile_desk: None,
      codemode_sockets: None,
      base_policy: workspace_policy.admitting_config_mounts(
        workspace_policy.base_policy_for(
          workspace,
          option.unwrap(flags.read_scope, workspace_config.read_scope),
        ),
        workspace_config.mounts,
      ),
      helper_path:,
      helper_pool_size:,
      session_id: session_id_of(session_path),
      demand: option.unwrap(flags.demand, exec.PlatformEnforcement),
      gateway:,
      evolution_role: Source,
      catalog: catalogue,
      secrets: secret_store,
      secret_failures:,
      system: option.from_result(workspace_policy.env_text(
        system_prompt.override_variable,
      )),
      home: workspace_policy.home_directory(),
      model: machine_strand.ModelIdentity(
        provider: main_entry.name,
        model_id: main_entry.model_id,
      ),
      context_window: main_entry.context_window,
      max_output_tokens: main_entry.max_output_tokens,
      api: adapter_api(main_entry.dialect),
      compaction: compaction_settings(main_entry.context_window),
      codemode_seed: seed_root(flags.codemode_seed, workspace),
      codemode_seams:,
      rules: rule_list,
      schedules: schedule_list,
      schedule_policy:,
      jobs_policy:,
      retry_policy:,
      deactivated_tools: named_tools(env_text_or("LOOM_DISABLE_TOOLS", "")),
      memory:,
      tools: catalog.ToolsConfig(
        ..tools,
        network: option.unwrap(flags.network, tools.network),
      ),
      advisor: advisor_settings(gateway, advisor_config),
      go_caches: case placement {
        LocalWorkspace ->
          gocache.locate(
            workspace_policy.lsp_places().cache,
            workspace,
            workspace_config.go_module_mirror,
            workspace_config.go_cache_limit_mib,
          )
        RegisteredWorkspace -> None
      },
    ),
  )
}

// The advisor strand's identity and policy, or `None` when the catalogue
// routes no `advisor` role. An unrouted role is the ordinary case rather
// than a failure, so `MissingIdentity` becomes absence here instead of
// halting a boot over a strand the operator never asked for.
//
// The error is discarded because it carries nothing a caller could act
// on: `resolve` answers `MissingIdentity` and nothing else, and the one
// case worth a word — a catalogue that routes the role to models this
// gateway cannot serve — is a question about the catalogue rather than
// about the error. `advisor_unresolved` asks it where there is a logger.

/// Establishes advisor settings for the caller, keeping its validation and result policy at this boundary.
fn advisor_settings(
  gateway: provider_gateway.Gateway,
  config: catalog.AdvisorConfig,
) -> Option(advisor.Settings) {
  provider_gateway.resolve(gateway, catalog.advisor_role)
  |> result.map(fn(resolved) {
    advisor.Settings(
      model: machine_strand.ModelIdentity(
        provider: resolved.provider,
        model_id: resolved.model_id,
      ),
      thinking: wiring.strand_thinking_level(resolved.thinking),
      tools: config.tools,
      feed_every_steps: config.feed_every_steps,
      block_cooldown_reviews: config.block_cooldown_reviews,
    )
  })
  |> option.from_result
}

/// Whether the catalogue routes an advisor that resolved to nothing.
///
/// `boot` warns on this and starts no advisor. It separates the two
/// silences an operator cannot otherwise tell apart: a catalogue with no
/// `[roles] advisor` line, which is the ordinary posture and deserves no
/// output, and one that routes the role to a chain the gateway cannot
/// serve, which is a configuration mistake whose only symptom is a
/// reviewer that never says anything.
///
/// The question is asked of the catalogue rather than of the gateway's
/// error because `resolve` reports only that an identity is missing,
/// which is the same answer for both cases.
///
/// ## Examples
///
/// ```gleam
/// // serve.advisor_unresolved(catalogue, settings.advisor)
/// ```
///
@internal
pub fn advisor_unresolved(
  catalogue: catalog.Catalog,
  settings: Option(advisor.Settings),
) -> Bool {
  option.is_none(settings)
  && result.is_ok(list.key_find(catalogue.roles, catalog.advisor_role))
}

// A comma-separated tool list from the environment. Blank entries are
// dropped so that a trailing comma, or an empty variable, names nothing
// rather than naming the empty tool.
fn named_tools(value: String) -> List(String) {
  string.split(value, on: ",")
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
}

/// Resolves the server's offered seams, defaulting to both isolated surfaces.
/// Unknown names are usage errors rather than silently choosing a default.
///
/// ## Examples
///
/// ```gleam
/// parse_codemode_seams(None) == Ok(codemode_wiring.BothSeams)
/// ```
@internal
pub fn parse_codemode_seams(
  named: Option(String),
) -> Result(codemode_wiring.Seams, String) {
  case named {
    None -> Ok(codemode_wiring.BothSeams)
    Some("workspace") -> Ok(codemode_wiring.WorkspaceOnly)
    Some("orchestration") -> Ok(codemode_wiring.OrchestrationOnly)
    Some("both") -> Ok(codemode_wiring.BothSeams)
    Some(other) ->
      Error(
        "--codemode-seams must be workspace, orchestration or both, not `"
        <> other
        <> "`\n"
        <> usage,
      )
  }
}

/// pi's compaction defaults, and the only place they are stated.
/// `reserve_tokens` is the headroom a turn's output and the next user
/// message need below the window; `keep_recent_tokens` is how much of
/// the newest conversation survives a compaction verbatim.
pub const default_reserve_tokens = 16_384

/// See `default_reserve_tokens`.
pub const default_keep_recent_tokens = 20_000

// Compaction settings from the environment, clamped against the window
// they will be compared to. Settings that cannot describe a working
// compaction — a non-positive keep-recent, or a reserve that leaves no
// room above the tail — disable compaction rather than firing a
// threshold on every checkpoint and preparing nothing; spec §3.2 wants
// these validated at set time, and this is the only set point there is
// today.

/// Establishes compaction settings for the caller, keeping its validation and result policy at this boundary.
fn compaction_settings(context_window: Int) -> operation.CompactionSettings {
  let reserve = env_int_or("LOOM_COMPACTION_RESERVE", default_reserve_tokens)
  let keep_recent =
    env_int_or("LOOM_COMPACTION_KEEP_RECENT", default_keep_recent_tokens)
  let enabled =
    env_text_or("LOOM_COMPACTION", "on") != "off"
    && reserve > 0
    && keep_recent > 0
    && keep_recent + reserve < context_window
  operation.CompactionSettings(
    enabled:,
    reserve_tokens: reserve,
    keep_recent_tokens: keep_recent,
  )
}

// The wiring's model-facts source: an identity's own catalogue entry.
//
// The lookup is by the identity's *provider* half, because a catalogue
// entry's name is its provider name and therefore the durable handle
// (`docs/architecture/models.md`, "The name is the durable handle"). An
// identity naming no entry — a session written against a catalogue this
// boot no longer has — falls through to the wiring's fallback counts
// rather than refusing, which is what keeps such a session running.

/// Establishes catalogue facts for the caller, keeping its validation and result policy at this boundary.
fn catalogue_facts(
  catalogue: catalog.Catalog,
) -> fn(machine_strand.ModelIdentity) ->
  Result(#(model.ResolvedModel, String, catalog.ImageReading), Nil) {
  // Facts travel through several provider and hook closures in every runtime.
  // Only model entries belong there; profile routes and server configuration
  // remain with the catalogue's owners rather than multiplying on each copy.
  let models = catalogue.models
  fn(identity: machine_strand.ModelIdentity) {
    use entry <- result.map(
      list.find(models, fn(entry) { entry.name == identity.provider }),
    )
    #(catalog.resolved(entry), adapter_api(entry.dialect), entry.vision)
  }
}

// The per-turn thinking level a freshly seeded strand starts at: the
// declared `thinking` of the catalogue entry the configured identity
// names, lifted onto the machine's seven-point scale.
//
// This is the one place a route's static thinking configuration takes
// effect, and it is *creation* — the same rule `client/gateway`'s
// fork/create_strand seeding and `client/agency`'s child seeding follow,
// so all three creation points agree. Dispatch never consults it: the
// per-turn level is the strand's own and absolute there
// (`client/wiring.request_target`), because a turn that raised its
// reasoning budget must reach the provider with exactly that budget. An
// identity the catalogue does not know starts at off, which is where
// every strand started before the field was read at all.
fn seed_thinking(settings: Settings) -> machine_strand.ThinkingLevel {
  case catalog.find(settings.catalog, settings.model.provider) {
    Ok(entry) -> wiring.strand_thinking_level(entry.thinking)
    Error(Nil) -> machine_strand.ThinkingOff
  }
}

// Which adapter a catalogue dialect dispatches through. The api name is
// captured durably into every generation intent, so it must be the
// adapter's own constant rather than a word chosen here.

/// Establishes adapter api for the caller, keeping its validation and result policy at this boundary.
fn adapter_api(dialect: catalog.Dialect) -> String {
  case dialect {
    catalog.Anthropic -> anthropic.api_name
    catalog.OpenAiCompatible -> openai.api_name
    catalog.OpenAiResponses -> responses.api_name
    catalog.CodexSubscription(profile: _) -> responses.subscription_api_name
    catalog.Gemini -> gemini.api_name
  }
}

// Everything one configuration load yields, in the order the tables are read.
type Loaded =
  #(
    catalog.Catalog,
    List(rules.Rule),
    List(schedule.Schedule),
    schedule.Policy,
    jobs.JobsPolicy,
    operation.NormalizedRetryPolicy,
    memory_config.Options,
    catalog.ToolsConfig,
    List(secrets.Entry),
    catalog.WorkspaceConfig,
    catalog.AdvisorConfig,
  )

// The configuration ladder: an explicit file must load and validate or
// the boot refuses (a typoed config silently ignored would serve the
// wrong model); no file falls back to the environment surface, which
// defines no rules and no schedules — both are a deliberate act, and
// there is no environment variable that could be one by accident.
//
// Each load reads and parses the file once. The catalogue still owns the
// top-level check and validates first, then the profile and model are chosen,
// then each table owner decodes the same document in the original error order.
// Standalone text parsers retain their own worded TOML errors. No document or
// resolved secret survives into another load: domain validation and every
// session open still read the file independently.

/// Establishes load config for the caller, keeping its validation and result policy at this boundary.
fn load_config(
  flag: Option(String),
  profile: Option(String),
  model: Option(String),
) -> Result(Loaded, String) {
  // Decide how to handle flag {.
  case flag {
    None -> {
      // The environment surface defines no profiles and no model keys, so a
      // session that was created under either cannot be served without the
      // file that names it.
      use catalogue <- result.try(case profile, model {
        None, None -> Ok(env_catalog())
        Some(name), _ ->
          Error(
            "profile \""
            <> name
            <> "\" needs a config file with a [profiles."
            <> name
            <> ".roles] table, and this host has none",
          )
        None, Some(key) ->
          Error(
            "model \""
            <> key
            <> "\" needs a config file with a [models."
            <> key
            <> "] table, and this host has none",
          )
      })

      Ok(#(
        catalogue,
        [],
        [],
        schedule.default_policy,
        jobs.default_policy,
        retryconf.default_policy,
        memory_config.default_options(),
        catalog.default_tools(),
        [],
        catalog.default_workspace(),
        catalog.default_advisor(),
      ))
    }
    Some(path) -> {
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(error) {
          "the config file "
          <> path
          <> " is unreadable: "
          <> string.inspect(error)
        }),
      )
      parse_config(path, text, profile, model)
    }
  }
}

/// Whether `text`, as the configuration at `path`, would open a session created
/// with `profile` and `model`: the same parse and the same table readers, in the
/// same order, as every session open. Nothing is resolved and no secret command
/// runs. A configuration watcher asks it before a changed file may reopen a
/// session (`client/config_watch`), and the proposal queue before a
/// configuration edit is queued or written (`client/proposals`), so a file that
/// would fail the open is never the reason a session stops.
///
/// ## Examples
///
/// ```gleam
/// // serve.check_config("/home/o/.loom/loom.toml", text, None, None)
/// ```
///
@internal
pub fn check_config(
  path: String,
  text: String,
  profile: Option(String),
  model: Option(String),
) -> Result(Nil, String) {
  parse_config(path, text, profile, model) |> result.replace(Nil)
}

/// Establishes parse config for the caller, keeping its validation and result policy at this boundary.
fn parse_config(
  path: String,
  text: String,
  profile: Option(String),
  model: Option(String),
) -> Result(Loaded, String) {
  let named = fn(reason) { path <> ": " <> reason }
  use #(parsed, document) <- result.try(
    catalog.parse_with_document(text) |> result.map_error(named),
  )

  // The profile and the model are resolved on every load, never remembered
  // from an earlier one, so a resume reads the file as it stands. One the
  // file no longer defines refuses here, in the file's own words, where
  // the alternative is opening a session on roles it was not created with.
  use catalogue <- result.try(
    with_choice(parsed, profile, model) |> result.map_error(named),
  )
  use rule_list <- result.try(
    rules.from_document(document) |> result.map_error(named),
  )
  use schedule_list <- result.try(
    schedule.from_document(document) |> result.map_error(named),
  )
  use schedule_policy <- result.try(
    schedule.policy_from_document(document) |> result.map_error(named),
  )
  use jobs_policy <- result.try(
    jobs.policy_from_document(document) |> result.map_error(named),
  )
  use retry_policy <- result.try(
    retryconf.policy_from_document(document) |> result.map_error(named),
  )
  use memory <- result.try(
    memory_config.from_document(document) |> result.map_error(named),
  )
  use tools <- result.try(
    catalog.tools_from_document(document) |> result.map_error(named),
  )
  use secret_entries <- result.try(
    secrets.from_document(document) |> result.map_error(named),
  )
  use workspace_config <- result.try(
    catalog.workspace_from_document(document) |> result.map_error(named),
  )
  use advisor_config <- result.try(
    catalog.advisor_from_document(document) |> result.map_error(named),
  )
  Ok(#(
    catalogue,
    rule_list,
    schedule_list,
    schedule_policy,
    jobs_policy,
    retry_policy,
    memory,
    tools,
    secret_entries,
    workspace_config,
    advisor_config,
  ))
}

// The catalogue a session routes by: the default one, or the one carrying the
// named profile's roles, with `main` then pinned to the named model. The profile
// goes first because the model is laid over whatever role set results
// (protocol-change/080).

/// Establishes with choice for the caller, keeping its validation and result policy at this boundary.
fn with_choice(
  catalogue: catalog.Catalog,
  profile: Option(String),
  model: Option(String),
) -> Result(catalog.Catalog, String) {
  // Decide how to handle use profiled <- result.try( profile {.
  use profiled <- result.try(case profile {
    None -> Ok(catalogue)
    Some(name) -> catalog.select_profile(catalogue, name)
  })

  // Decide how to handle model {.
  case model {
    None -> Ok(profiled)
    Some(key) -> catalog.select_model(profiled, key)
  }
}

// Splits `host:port` on the *last* colon, because IPv6 hosts carry
// colons of their own.

/// Establishes split bind for the caller, keeping its validation and result policy at this boundary.
fn split_bind(bind: String) -> Result(#(String, Int), String) {
  case list.reverse(string.split(bind, ":")) {
    [port_text, first, ..rest] ->
      case int.parse(port_text) {
        Ok(port) -> Ok(#(string.join(list.reverse([first, ..rest]), ":"), port))
        Error(Nil) -> Error("--bind port is not a number: " <> port_text)
      }
    _ -> Error("--bind takes host:port, got `" <> bind <> "`")
  }
}

/// The helper lookup ladder, as an order rather than as a lookup: the
/// explicit flag, then the helper shipped beside this server, then
/// `PATH`, then the repo's conventional `./bin`.
///
/// Each rung is a thunk so the order is the only thing stated here and a
/// test can supply its own rungs — precedence is the whole of what this
/// decides, and precedence is what a host-dependent lookup cannot show.
///
/// **The flag stays first**, because that is how an operator points at a
/// helper they built or audited themselves, and it is deliberately *not*
/// checked for existence by this function: a flag naming a missing file
/// must fail saying so rather than falling through to a helper the
/// operator did not choose.
///
/// **Beside the server outranks `PATH`**, and `client/install`'s module
/// doc is honest about what that is worth: a release's own `bin/` is
/// already at the front of the in-VM `PATH`, because OTP's `erl` script
/// puts it there, so this rung changes no release's answer. What it
/// changes is why the answer is right — the tree is asked because it is
/// the tree, not because a start script happened to rewrite an
/// environment variable — and it is what lets the refusal below name a
/// path rather than say "not on PATH" about a component that ships in
/// the tarball.
///
/// `./bin` stays last and stays in: it is where `make binaries` writes,
/// which is the whole of its job. Promoting it above `PATH` was
/// considered and rejected — it is relative to the working directory,
/// and a working-directory executable outranking `PATH` is a hazard of
/// its own, not a repair.
///
/// ## Examples
///
/// ```gleam
/// // serve.helper_ladder(Some("/audited/loom-exec"), ..) == Ok("/audited/loom-exec")
/// ```
///
pub fn helper_ladder(
  flag: Option(String),
  beside beside: fn() -> Result(String, Nil),
  on_path on_path: fn() -> Result(String, Nil),
  in_bin in_bin: fn() -> Result(String, Nil),
) -> Result(String, Nil) {
  install.first_of([
    fn() { option.to_result(flag, Nil) },
    beside,
    on_path,
    in_bin,
  ])
}

// The ladder run against this host, with the boot's insistence on a real
// file on the end of it. Only existence is checked, and it is checked
// eagerly: the pool spawns helpers lazily, so a missing binary would
// otherwise first surface at a tool call, as a confusing in-band
// failure, long after the person who mistyped the path had walked away.

/// Establishes find helper for the caller, keeping its validation and result policy at this boundary.
fn find_helper(flag: Option(String)) -> Result(String, String) {
  let found =
    helper_ladder(
      flag,
      beside: install.bundled_helper,
      on_path: fn() { ffi_os.find_executable(install.helper_name) },
      in_bin: fn() { install.existing_file(repo_helper) },
    )

  // Decide how to handle found {.
  case found {
    Error(Nil) -> Error(no_helper_anywhere())
    Ok(path) ->
      // map_error, not replace_error: the message concatenates, and an
      // eager argument would build it on every successful boot.
      install.existing_file(path)
      |> result.map_error(fn(_nil) {
        "the helper binary does not exist: " <> path
      })
  }
}

// Where `make binaries` writes the helper, relative to a repository
// checkout's own root.
const repo_helper = "./bin/loom-exec"

// Named, and lazy at its one call site, because it interpolates the
// installation root: a message built on every successful boot to be
// thrown away is the eager-argument hazard in miniature.

/// Establishes no helper anywhere for the caller, keeping its validation and result policy at this boundary.
fn no_helper_anywhere() -> String {
  "no "
  <> install.helper_name
  <> " sandbox helper found. Looked beside this server at "
  <> install.helper()
  <> ", then on PATH, then at "
  <> repo_helper
  <> ". Supply one with --helper <path>, build one from a checkout with "
  <> "`make binaries`, or run the `bin/loomd` of an unpacked release, "
  <> "which ships its own."
}

// The subscribe name for a session file: its base name without the
// extension (`/data/review.db` serves session `review`).

/// Establishes session id of for the caller, keeping its validation and result policy at this boundary.
fn session_id_of(path: String) -> String {
  // Decide how to handle let base =  list.last(string.split(path, "/")) {.
  let base = case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }

  // Decide how to handle string.split(base, ".") {.
  case string.split(base, ".") {
    [name, ..] if name != "" -> name
    _ -> base
  }
}

// --- the environment -------------------------------------------------------

/// The default model identity when `LOOM_MODEL` is unset.
pub const default_model = "claude-opus-5"

// One warned line per entry that did not resolve, naming the variable
// and why. The reason is built from an exit status or the deadline and
// never from the command's output, so nothing a credential helper
// printed can reach a log through here.

/// Establishes log secret failures for the caller, keeping its validation and result policy at this boundary.
fn log_secret_failures(failures: List(secrets.Failure), logger: Logger) -> Nil {
  list.each(failures, fn(failure) {
    log.warn(logger, "secrets.unresolved", [
      field.ident(key: "name", value: failure.name),
      field.text(key: "reason", value: failure.reason),
    ])
  })
}

fn env_text_or(name: String, fallback: String) -> String {
  result.unwrap(workspace_policy.env_text(name), fallback)
}

fn env_int_or(name: String, fallback: Int) -> Int {
  workspace_policy.env_text(name)
  |> result.try(int.parse)
  |> result.unwrap(fallback)
}

// The zero-config surface as a one-entry catalogue: one Anthropic
// entry named `anthropic` (so pre-catalogue durable identities keep
// resolving) shaped by the LOOM_* variables, routed as main. The API
// key is *named* here and read only at dispatch, so a keyless
// environment boots fine and fails in-band per request.

/// Establishes env catalog for the caller, keeping its validation and result policy at this boundary.
fn env_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "anthropic",
        dialect: catalog.Anthropic,
        base_url: env_text_or("LOOM_BASE_URL", "https://api.anthropic.com"),
        api_key_env: "ANTHROPIC_API_KEY",
        model_id: env_text_or("LOOM_MODEL", default_model),
        context_window: env_int_or("LOOM_CONTEXT_WINDOW", 1_000_000),
        max_output_tokens: env_int_or("LOOM_MAX_OUTPUT_TOKENS", 32_000),
        thinking: model.ThinkingOff,
        pricing: None,
        // The environment fallback is a real hosted model, so it
        // reads images; a catalogue entry gets its say from its own
        // `vision` key.
        vision: catalog.ReadsImages,
        max_images: 8,
        cyber_access: None,
        service_tier: None,
      ),
    ],
    roles: [#(model.Main, ["anthropic"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

// --- boot ------------------------------------------------------------------

/// Boots the full stack over one session file: directories, session
/// open (acquiring the writer lease), helper pool, broker, runtime
/// with the production wiring, the service supervisor, websocket
/// server. Returns the running pieces or the first failure, already
/// worded for a person.
///
/// The stack is raised on a host process of its own (`client/host`), so
/// the links every `actor.start` forms land on a process that traps
/// exits rather than on the caller. A fatal death is therefore an
/// orderly shutdown followed by a `host.Faulted` on `Booted.stops`, not
/// a link that fells whoever called this.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(booted) = serve.boot(settings)
/// // ... booted.served.port is bound, booted.instance.runtime is live ...
/// // serve.shutdown(booted)
/// ```
///
/// Internal to this package. The listener it raises is `client/server`'s,
/// which attaches anonymously — one shared bearer, no principal, no role — and
/// there is no v2 adapter behind it. Production serving is the daemon
/// (`client/daemon/main`), and `main` above refuses this entry point outright;
/// keeping the boot out of the package's public surface makes the
/// unauthenticated attachment unreachable rather than merely unused.
@internal
pub fn boot(settings: Settings) -> Result(Booted, String) {
  boot_with(settings, logger: log.discard())
}

/// `boot` with an injected logger — what the entry point calls once it
/// has installed a handler. The logger is a capability, not a setting
/// (§0.2): it is passed rather than parsed, so a test boots a whole
/// server and captures its records without a handler existing at all.
///
/// ## Examples
///
/// ```gleam
/// // serve.boot_with(settings, logger: handler.install(level.Info))
/// ```
///
/// Internal to this package, for the reason `boot` is.
@internal
pub fn boot_with(
  settings: Settings,
  logger logger: Logger,
) -> Result(Booted, String) {
  host.adopt(
    boot: fn(stops, owner) { assemble(settings, logger, stops, owner) },
    fatal: fatal_children,
    teardown: tear_down,
  )
}

/// Opens the session assembly without a listener or transport credential.
///
/// Each call creates its own runtime, gateway and reclaimable service
/// namespace. It installs no signal handler and does not choose a daemon
/// singleton. The caller must close the returned instance.
///
/// The instance host is the sole teardown owner. `close_instance` requests
/// that owner's orderly stop; `retire_instance` additionally receives the
/// explicit runtime drain and native executor retirement result before exit.
/// Neither caller runs teardown beside the host.
///
/// This is an assembly seam, not daemon admission: the host still lacks
/// partial-boot and owner-death custody. A manager must not use it until
/// those lifetimes have an independent cleanup owner.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(instance) = serve.open_instance(settings, log.discard())
/// // serve.close_instance(instance)
/// ```
@internal
pub fn open_instance(
  settings: Settings,
  logger: Logger,
) -> Result(Instance, String) {
  host.adopt_task(
    boot: fn(stops, owner) {
      assemble_instance(settings, logger, stops)
      |> result.map(fn(instance) {
        Instance(..instance, legacy_host: Some(owner))
      })
    },
    fatal: instance_children,
    teardown: instance_retirement_body,
  )
}

/// The deaths that end the server, named for the log line, and the
/// three that must be *monitored* because they unlink from their
/// starter by design — the session tree, the `mist` listener, and the
/// service supervisor. Everything else the boot started is still linked
/// to the host and reaches it through the exit trap.
///
/// This is the fatal half of the per-child policy. Each of these is
/// captured **by value** into closures built during the boot — the
/// broker into the wiring effects and the code-mode seam, the pool into
/// the broker's checkout, the sink into `wiring.Config` — so a
/// replacement process would be unreachable by everything already
/// holding the old handle: restarting one would leave a server that
/// looks alive and refuses every call. Failing closed is also the
/// posture the effect plane wants; a harness that cannot broker
/// capabilities or jail a helper must not keep serving. The pieces that
/// *can* be replaced in place are under `Booted.services` instead, and
/// only that supervisor's own death — its restart budget spent —
/// reaches this list.
fn fatal_children(booted: Booted) -> List(#(String, Pid)) {
  [
    #("the websocket listener", booted.served.supervisor),
    ..instance_children(booted.instance)
  ]
}

/// Lists the original fatal roots, whose handles cannot be replaced in place.
///
/// ## Examples
///
/// ```gleam
/// // instance_host.prepare(build:, fatal: serve.instance_children, ..)
/// ```
@internal
pub fn instance_children(instance: Instance) -> List(#(String, Pid)) {
  [
    #("the session tree", instance.runtime.tree.supervisor),
    #("the service supervisor", instance.services),
    #("the session storage", instance.storage_owner),
    ..instance.plane.fatal
  ]
}

/// Returns this instance's hub-held prompts to their submitters, unsent.
///
/// The graceful-drain hook the root calls on every resident session before
/// it kills the sockets those returns travel over, and the same hook a
/// per-session close runs on itself. Both are safe: the hub empties its
/// queues on the first call, so the second finds nothing to return.
///
/// ## Examples
///
/// ```gleam
/// // serve.drain_instance(instance)
/// ```
@internal
pub fn drain_instance(instance: Instance, within_ms: Int) -> Nil {
  drain_resident(resident(instance), within_ms)
}

/// What the daemon's session manager holds for one resident session, and what
/// it answers an attaching socket with.
///
/// The manager is generic in its resident value, and this is the value the
/// daemon instantiates it with. It exists because the whole `Instance` is far
/// wider than anything either holder reads. An `Instance` carries an
/// `api.Runtime`, which carries the session's `Effects`: megabytes of closures
/// over its tool registry. The manager keeps one resident value per admitted
/// session in its own state, and replies with one on every websocket upgrade,
/// so each of those was paying for a full copy of that graph while reading, at
/// most, a gateway name and a drain.
///
/// Nothing here is duplicated per session: a gateway is a registered name, the
/// children are pids, and `api.Drain` is two handles. All three are fixed for
/// the life of the instance they were projected from — the fatal roots are
/// precisely the handles that cannot be replaced in place, and neither the
/// tree nor the session store behind a drain is ever swapped under a resident
/// session — so the projection cannot go stale.
pub type Resident {
  Resident(
    /// Address-only peer service; no runtime graph crosses the registry.
    peer: peer_mail.Endpoint,
    /// Address-only delegate questions for a parent on another orchestrator:
    /// closures over the Agency holder's name and a trimmed configuration.
    spawns: agency.DelegateEndpoint,
    /// Address-only questions about what this session's children on other
    /// orchestrators send it: closures over the Agency holder's name.
    inbox: agency.ChildInbox,
    /// The questions the page of a spawner that started this session puts to
    /// it (protocol-change/094), closures over the Agency holder's name and the
    /// hub's address.
    relay: relayed_session.Endpoint,
    /// The hub's stable address, which is all an attaching socket reads.
    gateway: hub.Gateway,
    /// The session's worktree observation (`Instance.worktree`), for the web
    /// view's page. A closure over a workspace path and a few handles, not the
    /// runtime graph.
    worktree: fn() -> Result(json.JsonValue, String),
    /// The fatal roots, named for the log line. Read once, immediately after
    /// publication, by the assembly host that monitors them.
    children: List(#(String, Pid)),
    /// The tree and session a graceful drain reaches strands through.
    drain: api.Drain,
    /// Immutable-record reads without retaining the runtime effect graph.
    result_reader: storage_snapshot.Reader,
  )
}

/// Projects one published instance to what the daemon's registry holds.
///
/// ## Examples
///
/// ```gleam
/// // build: fn(..) { serve.assemble_in_domain(..) |> result.map(serve.resident) }
/// ```
@internal
pub fn resident(instance: Instance) -> Resident {
  Resident(
    peer: instance.peer,
    spawns: instance.spawns,
    inbox: instance.inbox,
    relay: instance.relay,
    gateway: instance.gateway,
    worktree: instance.worktree,
    children: instance_children(instance),
    drain: api.draining(instance.runtime),
    result_reader: instance.runtime.session.snapshot_reader,
  )
}

/// Lists the fatal roots a resident was projected with.
///
/// ## Examples
///
/// ```gleam
/// // manager.Assembly(fatal: serve.resident_children, ..)
/// ```
@internal
pub fn resident_children(resident: Resident) -> List(#(String, Pid)) {
  resident.children
}

/// Returns this session's hub-held prompts to their submitters, unsent.
///
/// The graceful-drain hook the root calls on every resident session before
/// it kills the sockets those returns travel over, and the same hook a
/// per-session close runs on itself. Both are safe: the hub empties its
/// queues on the first call, so the second finds nothing to return.
///
/// ## Examples
///
/// ```gleam
/// // manager.Assembly(drain: serve.drain_resident, ..)
/// ```
@internal
pub fn drain_resident(resident: Resident, within_ms: Int) -> Nil {
  let deadline = bootstrap.monotonic_time_ms() + int.max(within_ms, 0)

  // The gateway owns the admission fence. Fence and return held input before
  // aborting, so a terminal hint cannot admit it into a successor during drain.
  hub.drain_held_within(resident.gateway, int.max(within_ms, 0))

  // Cancellation retains the existing durable Aborted path. Socket flushes
  // and runtime settlement spend the same remaining instance budget.
  api.drain_within(
    resident.drain,
    within_ms: int.max(deadline - bootstrap.monotonic_time_ms(), 0),
  )
}

/// Composes the peer router after the existing per-execution host wrapper.
/// Only that wrapper is retained: unrelated code-mode configuration belongs
/// to execution and must not be duplicated inside its own router callback.
///
/// ## Examples
///
/// ```gleam
/// // serve.with_code_mode_peers(config, peer_wiring)
/// ```
@internal
pub fn with_code_mode_peers(
  config: codemode_wiring.Config,
  peer_wiring: peers.Wiring,
) -> codemode_wiring.Config {
  let wrap_router = config.wrap_router
  codemode_wiring.Config(
    ..config,
    wrap_router: fn(request: codemode_tool.Request, router) {
      peers.router(peer_wiring, request.strand, wrap_router(request, router))
    },
  )
}

// The label the jobs actor files itself under for the ownership inspector,
// which is the session's canonical id. A function because the id is known
// only once the runtime is open, and over the supplier rather than the
// Agency's whole configuration so that the actor's copy of it holds only a
// name and a timeout.
fn session_label(
  borrow_runtime: fn() -> Result(api.Runtime, Nil),
) -> fn() -> Result(List(#(String, String)), Nil) {
  fn() { borrow_runtime() |> result.map(session_owner.path) }
}

/// What the workspace half of a session is built from, read off the
/// settings.
///
/// Plain data, so a workspace on another node could be built from the same
/// value. The helper scratch directory is derived from the session path
/// here, which keeps it beside the session file a local owner already
/// cleans up; a workspace elsewhere would choose its own.
///
/// `blob_root` is the store `session_blob_root` computed, passed in so that
/// the plane, the tool context and code mode name one directory. A store
/// outside the daemon's state root is protected in the spec's base policy
/// (`protecting_standalone_blobs`), so the plane's own base composition
/// carries the entry.
///
/// ## Examples
///
/// ```gleam
/// // workspace_plane.prepare(serve.workspace_spec(settings, option.None, blob_root), reading: env)
/// ```
pub fn workspace_spec(
  settings: Settings,
  files: Option(workspace_policy.OwnerFiles),
  blob_root: String,
) -> workspace_plane.WorkspaceSpec {
  workspace_plane.WorkspaceSpec(
    workspace: settings.workspace,
    blob_root:,
    scratch_dir: settings.session_path <> ".tmp",
    helper_path: settings.helper_path,
    helper_pool_size: settings.helper_pool_size,
    demand: settings.demand,
    base_policy: protecting_standalone_blobs(
      settings.base_policy,
      settings,
      blob_root,
    ),
    tools: settings.tools,
    deactivated_tools: settings.deactivated_tools,
    go_caches: settings.go_caches,
    home: settings.home,
    codemode_seed: settings.codemode_seed,
    codemode_sockets: settings.codemode_sockets,
    lsp_servers: settings.catalog.lsp_servers,
    jobs_policy: settings.jobs_policy,
    owner_files: files,
  )
}

// Code mode, and the MCP servers it reaches — one decision, because the
// second is unreachable without the first.
//
// A host without a toolchain or a prepared build seed registers no
// `code_mode` tool at all (`codemode_wiring.discover` says which is
// missing and how to supply it), and on such a host **configured MCP
// servers are not started**: MCP reaches a model through code mode and
// through nothing else, so spawning third-party server processes that
// nothing could ever call would be cost and attack surface bought for
// no capability. One line says so, because an operator who configured a
// server and sees nothing would otherwise have only the absent
// `code_mode` line to reason from.

/// Establishes code mode mcp for the caller, keeping its validation and result policy at this boundary.
fn code_mode_mcp(
  settings: Settings,
  discovered: Result(codemode_wiring.Toolchain, String),
  logger: Logger,
  owner: Option(custody.Owner),
) -> Result(mcp_wiring.Layer, String) {
  // Decide how to handle discovered {.
  case discovered {
    Error(reason) -> {
      log.warn(logger, "codemode.unavailable", [
        field.text(key: "reason", value: reason),
      ])
      skipped_mcp(
        settings.catalog.mcp_servers,
        logger,
        "MCP servers are reached from code-mode programs only, and this "
          <> "host registers no code_mode tool, so none was started",
      )
      Ok(mcp_wiring.none())
    }
    Ok(toolchain) -> {
      // Which `gleam`, which `erl`, which seed — because the ladder now
      // has more than one rung and "code mode is on" is a much less
      // useful thing to know than which toolchain it will build with.
      log.info(logger, "codemode.ready", [
        field.text(key: "gleam", value: toolchain.gleam_path),
        field.text(key: "erl", value: toolchain.erl_path),
        field.text(key: "seed", value: toolchain.seed_root),
      ])
      started_mcp(settings.catalog.mcp_servers, settings.secrets, logger, owner)
    }
  }
}

/// The reserved name that `LOOM_DISABLE_TOOLS` (`settings.deactivated_tools`)
/// reads as the evolution switch.
///
/// Evolution has no tool of its own to deactivate, so the operator's knob for
/// withholding it names the module instead. With this name listed, a source
/// session is not offered `cap/evolution`: the import, the type surface, the
/// six names and the router arm are all absent, exactly as on a trial.
pub const evolution_switch = "evolution"

/// The evolution builder a session's code mode is configured with, or `None`.
///
/// A source session is offered it unless the operator listed
/// `evolution_switch` in `LOOM_DISABLE_TOOLS`. A trial is never offered it.
///
/// ## Examples
///
/// ```gleam
/// // serve.evolution_offer(settings, name) == option.None
/// // for a trial, or when `deactivated_tools` holds "evolution"
/// ```
///
@internal
pub fn evolution_offer(
  settings: Settings,
  name: address.Address(evolution_capability.Message),
) -> Option(fn(tool.Ctx) -> codemode_evolution.Door) {
  case settings.evolution_role {
    Source ->
      case list.contains(settings.deactivated_tools, evolution_switch) {
        True -> None
        False -> Some(evolution_capability.door_over(name))
      }
    Trial(_) -> None
  }
}

// The owner's arms of the code-mode configuration: the doors only the
// session's owner can serve. The workspace applies them after its own, so
// the peer router wraps the working-directory router as it always has.

/// Establishes code mode arms for the caller, keeping its validation and result policy at this boundary.
fn code_mode_arms(
  settings: Settings,
  agency_seam: Agency,
  schedule_door: Option(scheduleseam.Door),
  layer: mcp_wiring.Layer,
  peer_wiring: peers.Wiring,
  evolution_name: address.Address(evolution_capability.Message),
) -> fn(codemode_wiring.Config) -> codemode_wiring.Config {
  let seams = settings.codemode_seams
  fn(config) {
    config
    // Which seams this server offers is the operator's decision, and the
    // Agency the orchestration one routes onto is the same seam the
    // `agent_*` tools call — one messaging plane, reached two ways.
    |> codemode_wiring.serving(seams, over: agency_seam)
    // `schedule.*` is answered by the same door the `schedule_*` tools
    // call, so a program and a tool call cannot disagree about what this
    // session's schedules are. A shut door leaves the capabilities
    // unrouted rather than always-refusing.
    |> codemode_wiring.over_schedules(schedule_door)
    // The MCP layer widens both installed modes' allowlists, their
    // description and its router together; an empty layer widens nothing,
    // so this is unconditional.
    |> codemode_wiring.over_mcp(layer)
    // `cap/evolution` is the one route to governed evolution, offered to a
    // source session only: a trial is judged by its source and is handed no
    // door over the source's catalogue. The plane is opened after this
    // configuration exists (it takes the configuration as its candidates'
    // host), so the builder holds the cell's name and the cell is registered
    // under it by `open_evolution`.
    |> codemode_wiring.over_evolution(evolution_offer(settings, evolution_name))
    |> with_code_mode_peers(peer_wiring)
  }
}

// The `code_mode` tool over a finished configuration: background execution
// is the session's, so the owner supplies the seam, and the peer
// capabilities join the serviced list of every offer.

/// Establishes code mode tool for the caller, keeping its validation and result policy at this boundary.
fn code_mode_tool(
  config: codemode_wiring.Config,
  async_name: address.Address(async_runs.Message),
  agency_config: agency.Config,
) -> codemode_tool.CodeMode {
  async_codemode.seam(config, async_name, agency_config)
  |> owner_codemode.advertising_peers
}

// One installed extension, registered: the tools it contributes to the
// registry, its subscription on the hook bus, and the recipe the
// session's satellite registry launches its node from. All three travel
// together because discovery is the expensive half — it re-derives four
// content addresses per extension — and doing it three times would let
// the tool side, the hook side and the host disagree about what is
// installed.
type Registration {
  Registration(
    contribution: contributions.Contribution,
    subscription: Option(extension_hooks.Extension),
    hosting: extension_hosts.Extension,
  )
}

/// Establishes extension registrations for the caller, keeping its validation and result policy at this boundary.
fn extension_registrations(
  settings: Settings,
  discovered: List(installed.Discovered),
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> #(List(Registration), List(String)) {
  case settings.home {
    // No home is no extensions root, which is the same fact to a booting
    // server as an empty one: there is nothing installed and nothing to
    // warn about.
    None -> #([], [])

    Some(home) -> {
      let root = extension_record.root_for(home)
      let checked =
        list.map(discovered, fn(found) {
          extension_contribution(
            root,
            found,
            settings.secrets,
            logger,
            hosts,
            hooking,
            host,
            memory,
          )
        })
      let registered =
        list.filter_map(checked, fn(item) {
          case item {
            Ok(Some(registration)) -> Ok(registration)
            Ok(None) -> Error(Nil)
            Error(_) -> Error(Nil)
          }
        })

      // Collect registration notices and truncate excessive refusals.
      let refused =
        list.filter_map(checked, fn(item) {
          case item {
            Ok(_) -> Error(Nil)
            Error(reason) -> Ok(reason)
          }
        })

      // Decide how to handle let notices =  list.drop(refused, 32) {.
      let notices = case list.drop(refused, 32) {
        [] -> refused
        _ ->
          list.append(list.take(refused, 31), [
            "More extensions were refused; run `loom ext list` for the complete list.",
          ])
      }

      #(registered, notices)
    }
  }
}

/// Establishes extension contribution for the caller, keeping its validation and result policy at this boundary.
fn extension_contribution(
  root: extension_record.Root,
  found: installed.Discovered,
  store: secret.SecretStore,
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> Result(Option(Registration), String) {
  // Decide how to handle found {.
  case found {
    installed.Refused(name:, reason:) -> {
      log.warn(logger, "extension.refused", [
        field.text(key: "name", value: name),
        field.text(key: "reason", value: reason),
      ])
      Error(extension_refusal(name, reason))
    }

    installed.Ready(record: written, manifest: decoded, artifact:) ->
      case written.tier {
        extension_manifest.Jailed ->
          extension_registered(
            root,
            written,
            decoded,
            artifact,
            store,
            logger,
            hosts,
            hooking,
            host,
            memory,
          )
          |> result.map(Some)

        // A profile extension runs nothing, so it has no tool to register,
        // no hook to subscribe and no satellite to host. Its servers reach
        // the session through `lsp_wiring`. It is not a refusal either, so
        // it adds no notice for the operator.
        extension_manifest.Profile -> Ok(None)
      }
  }
}

/// Establishes extension registered for the caller, keeping its validation and result policy at this boundary.
fn extension_registered(
  root: extension_record.Root,
  written: extension_record.Record,
  decoded: extension_manifest.Manifest,
  artifact: String,
  store: secret.SecretStore,
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> Result(Registration, String) {
  // Decide how to handle host {.
  case host {
    None -> {
      log.warn(logger, "extension.unavailable", [
        field.text(key: "name", value: written.name),
        field.text(
          key: "reason",
          value: "this host registers no code_mode tool, so it has no "
            <> "toolchain to boot an extension satellite with",
        ),
      ])
      Error(extension_refusal(
        written.name,
        "this host registers no code_mode tool, so it has no toolchain to boot an extension satellite with",
      ))
    }

    Some(config) -> {
      let dispatch_config =
        extension_dispatch.Config(
          host: config,
          // The session's satellite registry, reached by name: it starts
          // under the service supervisor further down, after this
          // registry is assembled.
          hosts:,
          // The session's durable memory, borrowed through the Agency's
          // holder for the reason the scheduling plane is: the runtime
          // does not exist until `api.open` has returned the registry
          // being assembled here.
          memory:,
          // The session's credential seam, the same store `api_key_env`
          // reads. The value never reaches a `Tool`, a frame or a log:
          // this function is handed to `broker/egress`, which reads it
          // after the origin and method are judged and puts the result
          // straight on the wire.
          secrets: fn(name) { secret.lookup(store, name) },
          // The platform trust store. A pinned root is a test-only
          // shape, and there is no operator surface for one.
          trust: egress.SystemRoots,
          launch: extension_dispatch.jailed_node,
        )

      // Decide how to handle the branch input.
      case
        extension_dispatch.tools(
          dispatch_config,
          written,
          decoded,
          sources: extension_record.sources(root, written.name),
          artifact:,
        )
      {
        Error(reason) -> {
          log.warn(logger, "extension.refused", [
            field.text(key: "name", value: written.name),
            field.text(key: "reason", value: reason),
          ])
          Error(extension_refusal(written.name, reason))
        }

        Ok(tools) -> {
          // What was registered and what it may reach, in one line, so
          // that an operator reading a boot log can see an extension's
          // egress policy without opening its manifest. The secret
          // bindings are counted, never named with a value.
          log.info(logger, "extension.registered", [
            field.text(
              key: "detail",
              value: extension_dispatch.summary(written, decoded),
            ),
          ])
          Ok(Registration(
            contribution: contributions.Contribution(
              origin: contributions.Extension(name: written.name),
              tools:,
            ),
            subscription: extension_subscription(written, logger, hooking),
            hosting: extension_dispatch.hosting(
              dispatch_config,
              written,
              decoded,
              artifact:,
            ),
          ))
        }
      }
    }
  }
}

// The command keeps the existing remove-then-install policy. A refused record
// may not contain a readable source, so guidance never invents one from it.

/// Establishes extension refusal for the caller, keeping its validation and result policy at this boundary.
fn extension_refusal(name: String, reason: String) -> String {
  "Extension "
  <> name
  <> " refused: "
  <> diagnostic.clip(reason, 1024)
  <> ". To reinstall, run `loom ext remove "
  <> name
  <> "` then `loom ext install <source>`."
}

// The bus subscription an extension's `[[hook]]` declarations become,
// or nothing when it declares none. Two events are deliberately not
// subscriptions: `context` and `tool_result` are chained transforms
// folded over the same list rather than fanned out, and they are carried
// on the same `Extension` value, so the declared list here is the whole
// of what the extension asked for and the bus decides which plane each
// name belongs to.
//
// The list comes from the **record** rather than from the manifest
// beside it. Both say the same thing on a tree that has not been
// tampered with — discovery re-derives the digest over the whole tree,
// `extension.toml` included, and refuses the extension when it moved —
// but the record is the operator's approval, and authority over the
// harness's own timeline should be read from the yes rather than from
// the file the yes was about.

/// Establishes extension subscription for the caller, keeping its validation and result policy at this boundary.
fn extension_subscription(
  written: extension_record.Record,
  logger: Logger,
  hooking: extension_hooks.Invoker,
) -> Option(extension_hooks.Extension) {
  // Decide how to handle list.map(written.hooks, fn(hook) { hook.0 }) {.
  case list.map(written.hooks, fn(hook) { hook.0 }) {
    [] -> None
    events -> {
      inert_hooks(written.name, events, logger)

      // Every subscription shares one invoker, and it is the session's
      // satellite registry: `hosts.invoker` closes over the registry's
      // name and the coordinates a hook's effects clear under, and takes
      // the extension's name per call. So the bus asks the same door a
      // tool call asks, and an extension whose satellite is gone answers
      // `Gone` here for the same reason it does there.
      Some(extension_hooks.Extension(
        name: written.name,
        events:,
        invoke: hooking,
      ))
    }
  }
}

// A declared event with no producer in the harness. `agent_settled` is
// the only one: nothing signals "the run and every follow-up it queued
// are done", so an extension subscribing to it would wait forever
// without being told. Said once, at boot, where an operator reads it.

/// Establishes inert hooks for the caller, keeping its validation and result policy at this boundary.
fn inert_hooks(name: String, events: List(String), logger: Logger) -> Nil {
  case list.contains(events, extension_manifest.agent_settled_event) {
    False -> Nil
    True ->
      log.warn(logger, "extension.hook.inert", [
        field.ident(key: "name", value: name),
        field.ident(key: "event", value: extension_manifest.agent_settled_event),
        field.text(
          key: "reason",
          value: "the harness has no signal for a run and every follow-up it "
            <> "queued being done, so this hook never fires",
        ),
      ])
  }
}

// The hook bus, started over every subscribed extension and composed
// into the session's effects. A bus that will not start is logged and
// skipped: extensions are an addition to a session, never a
// precondition for one, so a boot that cannot fan hooks out still
// serves.

/// Establishes with extension hooks for the caller, keeping its validation and result policy at this boundary.
fn with_extension_hooks(
  built: effects.Effects,
  registrations: List(Registration),
  session: session.Session,
  clock: Clock,
  logger: Logger,
) -> effects.Effects {
  case list.filter_map(registrations, subscription_of) {
    [] -> built
    subscribed ->
      case extension_hooks.start(subscribed, logger) {
        Error(_reason) -> {
          log.warn(logger, "extension.hooks.unavailable", [
            field.text(
              key: "reason",
              value: "the hook bus would not start; extension hooks are off "
                <> "for this session",
            ),
          ])
          built
        }

        Ok(bus) -> {
          // The first event, sent once the bus exists and before the
          // runtime opens: `session_start` means "the session server
          // booted the extension", and that is now.
          extension_hooks.session_start(bus)
          extension_hooks.wire(built, bus, session, clock)
        }
      }
  }
}

fn subscription_of(
  registration: Registration,
) -> Result(extension_hooks.Extension, Nil) {
  option.to_result(registration.subscription, Nil)
}

// One `mcp.unavailable` line naming every server that was configured and
// not started, and why. Worded as the layer's own refusals are: a
// skipped server has no module, so a program importing it is refused by
// vetting with no word about the absence, and this line is the only
// thing an operator will ever see about it.

/// Establishes skipped mcp for the caller, keeping its validation and result policy at this boundary.
fn skipped_mcp(
  servers: List(catalog.McpServer),
  logger: Logger,
  reason: String,
) -> Nil {
  case servers {
    [] -> Nil
    configured ->
      log.warn(logger, "mcp.unavailable", [
        field.text(
          key: "servers",
          value: string.join(
            list.map(configured, fn(server) { server.name }),
            ",",
          ),
        ),
        field.text(key: "reason", value: reason),
      ])
  }
}

// Every configured server is started when code mode is installed, and one
// line reports each success or failure.
//
// `mcp.ready` names the servers that answered and how many tools each
// listed, because "how many" is the number that decides what the
// description costs. `mcp.unavailable` names one server and its reason
// — a missing executable, a refused handshake, an unset `api_key_env`,
// a listing this generator will not accept — and is the only thing
// anybody will ever see about it: a refused server has no module, so a
// program importing it is refused by vetting with no word about why the
// module is absent.

/// Establishes started mcp for the caller, keeping its validation and result policy at this boundary.
fn started_mcp(
  servers: List(catalog.McpServer),
  store: secret.SecretStore,
  logger: Logger,
  owner: Option(custody.Owner),
) -> Result(mcp_wiring.Layer, String) {
  // The session's own store, not the process environment: an MCP
  // server's `api_key_env` names a credential the same way a model's
  // does, so a `[secrets]` entry has to reach it or the table would
  // cover some of its readers and not others.
  let options =
    mcp_wiring.Options(..mcp_wiring.default_options(), secrets: store)

  // Decide how to handle let prepared =  owner {.
  let prepared = case owner {
    None -> mcp_wiring.prepare(servers, options)
    Some(owner) ->
      mcp_wiring.prepare_owned(
        servers,
        options,
        custodian: custody.owner(owner),
      )
  }

  use Nil <- result.try(
    retain(
      owner,
      custody.Mcp,
      fn() { mcp_wiring.close_prepared(prepared, within: 5000) },
      fn() { Nil },
    ),
  )
  let #(layer, refusals) = mcp_wiring.start_prepared(prepared)
  list.each(refusals, fn(refusal) {
    log.warn(logger, "mcp.unavailable", [
      field.text(key: "server", value: refusal.server),
      field.text(key: "reason", value: refusal.reason),
    ])
  })

  // Decide how to handle mcp_wiring.listings(layer) {.
  case mcp_wiring.listings(layer) {
    [] -> Nil
    listings ->
      log.info(logger, "mcp.ready", [
        field.text(
          key: "servers",
          value: string.join(
            list.map(listings, fn(listing) {
              listing.0 <> "=" <> int.to_string(listing.1)
            }),
            ",",
          ),
        ),
      ])
  }

  Ok(layer)
}

/// Establishes assemble for the caller, keeping its validation and result policy at this boundary.
fn assemble(
  settings: Settings,
  logger: Logger,
  stops: Subject(host.Stop),
  owner: host.Host,
) -> Result(Booted, String) {
  use instance <- result.try(assemble_instance(settings, logger, stops))
  use served <- result.try(
    start_listener(settings, instance.gateway)
    |> result.map_error(fn(error) {
      close_instance(instance)
      error
    }),
  )
  Ok(Booted(
    instance:,
    served:,
    token_path: settings.token_path,
    bind_host: settings.bind_host,
    host: owner,
  ))
}

// Token setup follows session validation, so an invalid policy leaves no
// directories. It is still outside session-only assembly, and any failure
// returns to the completed instance's cleanup path above.

/// Establishes start listener for the caller, keeping its validation and result policy at this boundary.
fn start_listener(
  settings: Settings,
  gateway: hub.Gateway,
) -> Result(server.Server, String) {
  use Nil <- result.try(
    workspace_policy.create_directories(
      option.values([workspace_policy.parent_directory(settings.token_path)]),
    ),
  )
  server.serve(server.Config(
    gateway:,
    bind: settings.bind_host,
    port: settings.bind_port,
    auth: server.LocalAuth(token_path: settings.token_path),
    entropy: workspace_plane.mixed_entropy(),
  ))
  |> result.map_error(fn(error) {
    "the websocket server did not start: " <> string.inspect(error)
  })
}

/// Establishes assemble instance for the caller, keeping its validation and result policy at this boundary.
fn assemble_instance(
  settings: Settings,
  logger: Logger,
  stops: Subject(host.Stop),
) -> Result(Instance, String) {
  use namespace <- result.try(address.start())
  assemble_in(settings, logger, stops, namespace, None, None, None)
  |> result.map_error(fn(error) {
    let _stopped = address.stop(namespace)
    error
  })
}

/// Assembles one reserved session under the manager's existing custody owner.
///
/// The manager prepares and monitors its instance host before invoking this
/// function on that host. Each effect boundary is published before work begins;
/// failures leave cleanup and the writer lease with the surviving custodian.
/// This function neither binds a listener nor confirms catalogue initialization.
///
/// ## Examples
///
/// ```gleam
/// // serve.assemble_owned(settings, reserved_id, logger, owner)
/// ```
@internal
pub fn assemble_owned(
  settings: Settings,
  reserved: ids.SessionId,
  logger: Logger,
  owner: custody.Owner,
) -> Result(Instance, String) {
  assemble_owned_with(settings, reserved, logger, owner, None, None)
}

/// Assembles one session using already-published shared domain capabilities.
/// The session owns forwarding only; it cannot close shared stores.
///
/// ## Examples
///
/// ```gleam
/// // serve.assemble_in_domain(settings, id, logger, owner, services)
/// ```
@internal
pub fn assemble_in_domain(
  settings: Settings,
  reserved: ids.SessionId,
  logger: Logger,
  owner: custody.Owner,
  services: domain_service.Services,
) -> Result(Instance, String) {
  assemble_owned_with(settings, reserved, logger, owner, Some(services), None)
}

/// Assembles one reserved session whose workspace is registered on an executor.
///
/// The conversation half is built here exactly as `assemble_in_domain` builds
/// it. The workspace half is the executor's, chosen and reached through
/// `placement`: the registered name in `settings.workspace` is carried to the
/// executor and never opened, created or canonicalized on this machine. A
/// connection or attach that fails fails the assembly with a reason beginning
/// `executor_unavailable:`.
///
/// ## Examples
///
/// ```gleam
/// // serve.assemble_registered(settings, id, logger, owner, services, placement)
/// ```
@internal
pub fn assemble_registered(
  settings: Settings,
  reserved: ids.SessionId,
  logger: Logger,
  owner: custody.Owner,
  services: Option(domain_service.Services),
  placement: remote_workspace.Placement,
) -> Result(Instance, String) {
  assemble_owned_with(
    settings,
    reserved,
    logger,
    owner,
    services,
    Some(placement),
  )
}

/// Establishes assemble owned with for the caller, keeping its validation and result policy at this boundary.
fn assemble_owned_with(
  settings,
  reserved,
  logger,
  owner,
  services,
  registered,
) {
  use namespace <- result.try(address.start())
  use Nil <- result.try(
    retain(
      Some(owner),
      custody.Namespace,
      fn() { address.stop(namespace) },
      fn() { process.unlink(address.owner(namespace)) },
    ),
  )
  assemble_in(
    settings,
    logger,
    process.new_subject(),
    namespace,
    Some(#(owner, reserved)),
    services,
    registered,
  )
}

// Opens the session file under this incarnation's lease. A holder that is
// still alive renews its lease, so a refusal is final and the caller says who
// holds it.

/// Establishes open session file for the caller, keeping its validation and result policy at this boundary.
fn open_session_file(
  path: String,
  owner: String,
  clock: Clock,
) -> Result(
  #(
    session.Session,
    fn() -> Result(Nil, StorageError),
    fn() -> Result(Pid, StorageError),
  ),
  session.OpenError,
) {
  session.open_sqlite_custody(path:, owner:, lease_ttl_ms: 60_000, clock:)
}

/// Renders a storage open refusal as the message the daemon classifier reads.
///
/// The one storage refusal an operator can act on is a writer lease that is
/// still unexpired. A SIGKILL cannot run the release, so the row survives in
/// the file with the expiry the dead writer last renewed, and the very next
/// boot is refused by its own predecessor. That refusal heals by itself once
/// the instant passes, which makes the instant the whole of the answer: this
/// message names it so `main.start_class` can put it in the daemon log and
/// the operator can see how long the wait is rather than guessing.
///
/// Every other refusal keeps the original opaque wording, and the wording is
/// what the classifier reads. The full reason travels to the requesting
/// terminal but never into a log record, because a corrupt-file report or an
/// open failure can carry the session path inside it.
///
/// ## Examples
///
/// ```gleam
/// // serve.storage_open_refusal(session.SqliteOpenFailed(sqlite.LeaseHeld(
/// //   owner: "loomd-a1", expires_at_ms: 42)))
/// // == "another writer holds this session's lease until epoch ms 42"
/// ```
@internal
pub fn storage_open_refusal(error: session.OpenError) -> String {
  case error {
    session.SqliteOpenFailed(sqlite.LeaseHeld(owner: _, expires_at_ms:)) ->
      "another writer holds this session's lease until epoch ms "
      <> int.to_string(expires_at_ms)

    session.SqliteOpenFailed(sqlite.AdmissionBusy)
    | session.SqliteOpenFailed(sqlite.CorruptSession(..))
    | session.SqliteOpenFailed(sqlite.UnsupportedVersion(..))
    | session.SqliteOpenFailed(sqlite.OpenFailed(..))
    | session.MemoryOpenFailed(..) ->
      "the session did not open (held lease? bad path?): "
      <> string.inspect(error)
  }
}

// Where the workspace half of the session in this assembly is, once chosen.
type Home {
  Here(prepared: workspace_plane.Prepared)
  There(placement: remote_workspace.Placement)
}

// What the rest of the assembly reads of the workspace half, whichever machine
// it is on. The local fields are `None` for a workspace on an executor.
type Half {
  Half(
    plane: workspace_plane.WorkspacePlane,
    decls: List(tool.Described),
    children: workspace_plane.Children,
    pool: Option(Pool),
    executor: Option(executor.Executor),
    lsp: Option(workspace_plane.LspPlane),
    code_mode_host: Option(codemode_wiring.Config),
    /// The scratch store a local plane started, which the core upgrade
    /// controller migrates; `None` for a workspace on an executor.
    scratch_name: Option(address.Address(scratch.Message)),
    blob_root: String,
    call_clock: Clock,
    recover: Option(fn(effects.ToolRun) -> effects.Recovery),
    /// How the execution service stops and recovers a background execution
    /// whose program runs on an executor; `None` for a local workspace, whose
    /// programs run in this VM.
    executions: Option(RemoteExecutions),
    /// The way to the executor's evolution plane, when the executor's census
    /// says it compiles candidates; `None` for a local workspace and for an
    /// executor that cannot compile.
    evolution_link: Option(evolution_machine_remote.Link),
  )
}

// The two things the execution service needs from a workspace on an executor:
// the stop it sends when a record closes, and the read recovery makes before it
// marks a live record lost.
type RemoteExecutions {
  RemoteExecutions(
    stop: fn(ids.OpId, String) -> Nil,
    lookup: fn(ids.OpId, String) -> Result(protocol.Lookup, String),
  )
}

// A workspace started in this VM.

/// Establishes here for the caller, keeping its validation and result policy at this boundary.
fn here(
  prepared: workspace_plane.Prepared,
  clock: Clock,
  local: workspace_plane.Local,
) -> Half {
  Half(
    plane: local.started.plane,
    decls: local.started.decls,
    children: local.started.children,
    pool: Some(local.pool),
    executor: Some(local.executor),
    lsp: local.lsp,
    code_mode_host: local.code_mode_host,
    scratch_name: Some(local.scratch_name),
    blob_root: prepared.spec.blob_root,
    call_clock: clock,
    recover: None,
    executions: None,
    evolution_link: None,
  )
}

// A workspace attached on an executor. Its scope is closed and its owner port
// ended by one custody part, published before anything can call it.

/// Establishes there for the caller, keeping its validation and result policy at this boundary.
fn there(
  registered: remote_workspace.Registered,
  owner: Option(custody.Owner),
  logger: Logger,
) -> Result(Half, String) {
  use hands <- result.try(remote_workspace.attach(registered))
  log_remote_mcp(hands.mcp, logger)
  use Nil <- result.map(retain(
    owner,
    custody.Workspace,
    fn() {
      hands.plane.close()
      Ok(Nil)
    },
    hands.transfer,
  ))
  Half(
    plane: hands.plane,
    decls: hands.tools,
    children: workspace_plane.Children(
      scratch: fn(builder) { builder },
      jobs: fn(builder) { builder },
      lsp_manager: fn(builder) { builder },
    ),
    pool: None,
    executor: None,
    lsp: None,
    code_mode_host: None,
    scratch_name: None,
    blob_root: hands.plane.census.blob_root,
    call_clock: hands.clock,
    recover: Some(hands.recover),
    executions: Some(RemoteExecutions(
      stop: hands.stop_execution,
      lookup: hands.execution_lookup,
    )),
    evolution_link: hands.evolution,
  )
}

// How the MCP servers this session expected the executor to run fared, in the
// lines an operator already reads for a local server: `mcp.ready` for those
// that started and `mcp.unavailable` for each that did not, both marked with
// the placement so the two machines' lines are not confused.

/// Establishes log remote mcp for the caller, keeping its validation and result policy at this boundary.
fn log_remote_mcp(
  statuses: List(remote_census.McpStatus),
  logger: Logger,
) -> Nil {
  list.each(statuses, fn(status) {
    case status {
      remote_census.McpReady(server:, tools:) ->
        log.info(logger, "mcp.ready", [
          field.text(key: "server", value: server),
          field.count(key: "tools", value: tools),
          field.text(key: "placement", value: "executor"),
        ])
      remote_census.McpRefused(server:, reason:) ->
        log.warn(logger, "mcp.unavailable", [
          field.text(key: "server", value: server),
          field.text(key: "reason", value: reason),
          field.text(key: "placement", value: "executor"),
        ])
    }
  })
}

// The configured servers a remote session starts on this daemon.

/// Establishes orchestrator placed for the caller, keeping its validation and result policy at this boundary.
fn orchestrator_placed(
  servers: List(catalog.McpServer),
) -> List(catalog.McpServer) {
  list.filter(servers, fn(server) {
    server.runs_on == catalog.RunsOnOrchestrator
  })
}

// The names of the configured servers a remote session expects its executor to
// run.

/// Establishes executor placed for the caller, keeping its validation and result policy at this boundary.
fn executor_placed(servers: List(catalog.McpServer)) -> List(String) {
  list.filter_map(servers, fn(server) {
    case server.runs_on {
      catalog.RunsOnExecutor -> Ok(server.name)
      catalog.RunsOnOrchestrator -> Error(Nil)
    }
  })
}

/// One notice for each extension installed on the executor, because none of
/// them registers a tool for a workspace there. A profile extension runs
/// nothing and so gets none.
///
/// ## Examples
///
/// ```gleam
/// assert serve.remote_extension_refusals([]) == []
/// ```
@internal
pub fn remote_extension_refusals(
  found: List(installed.Discovered),
) -> List(String) {
  list.filter_map(found, fn(each) {
    case each {
      installed.Refused(name:, ..) -> Ok(name)
      installed.Ready(record:, ..) ->
        case record.tier {
          extension_manifest.Jailed -> Ok(record.name)
          extension_manifest.Profile -> Error(Nil)
        }
    }
  })
  |> list.map(fn(name) {
    "Extension "
    <> name
    <> " is installed on the executor, and its tools are not available to a "
    <> "workspace on an executor yet."
  })
}

// One namespace spans the composition services' restarts, but never a second
// session. Boot failure retires routing; full partial-boot custody is separate.

/// Establishes assemble in for the caller, keeping its validation and result policy at this boundary.
fn assemble_in(
  settings: Settings,
  logger: Logger,
  stops: Subject(host.Stop),
  namespace: address.Registry,
  ownership: Option(#(custody.Owner, ids.SessionId)),
  services: Option(domain_service.Services),
  registered: Option(remote_workspace.Placement),
) -> Result(Instance, String) {
  // Extract ownership custody and self reference.
  let owner = option.map(ownership, fn(pair) { pair.0 })
  let builder = process.self()

  // The search index is protected before the policy is validated,
  // because it is part of the policy this server refuses to boot
  // without. See `protecting_index` for why a model-writable index is a
  // security property rather than a tidiness one.
  use index_path <- result.try(index_path(settings))

  // Memory is protected on the same argument one step along: the notes
  // index sidecar is text this server injects into every run's context, and
  // the store behind it is what the index is rendered from. See
  // `protecting_memory`.
  use memory_store <- result.try(beside_session(settings, memory.memory_file))

  // Protect session memory notes sidecar.
  use memory_notes <- result.try(beside_session(settings, memory.notes_file))

  // Protect the approved rules file to prevent unconfined model mutations.

  // The approved-rules file is protected on the same argument, one step
  // further: the prompt carries it whole at the start of every new session,
  // so a file a jailed process could write would be a standing instruction
  // channel. Only `client/proposals` writes it, one approval at a time.
  use rules_path <- result.try(beside_session(settings, proposals.rules_file))

  // The workspace half is prepared here, before anything of the owner's is
  // opened and before any lease is taken: the toolchain is located and
  // judged against the session base (a base built before the toolchain is
  // known could not name its mounts, and a launch requiring a mount the
  // base does not carry is refused by the meet), a base the sandbox cannot
  // enforce is a boot failure and not a surprise waiting in the first tool
  // call, and the workspace's directories are made. Nothing is spawned.
  // The census it returns is plain data the rest of this assembly reads.
  //
  // A workspace registered on an executor has nothing to prepare here: the
  // executor judges its own base, makes its own directories and answers for
  // its own toolchain when the scope attaches. Nothing in this branch names
  // the registered workspace on this machine's disk.
  use home <- result.try(case registered {
    Some(placement) -> Ok(There(placement))
    None -> {
      // The blob store is computed once, here, and the spec hands the same
      // string to the tool context, the code-mode emitter and the jobs
      // spill. See `session_blob_root` for where it is and why.
      use blob_root <- result.try(session_blob_root(settings))

      // Prepare local workspace plane specifications and policy files.
      use prepared <- result.try(
        workspace_plane.prepare(
          workspace_spec(
            settings,
            Some(workspace_policy.OwnerFiles(
              index: index_path,
              memory_store:,
              rules: rules_path,
              memory_notes:,
              evolution: evolution_masks(settings),
            )),
            blob_root,
          ),
          reading: fn(name) { secret.lookup(settings.secrets, name) },
        ),
      )

      // The evolution plane is local-only, like an extension: its catalogue,
      // run scratch and trial workspaces live beside this session. They are
      // made only after `prepare` accepted the policy, so a refused boot
      // leaves nothing behind. The masks above name them without needing them
      // to exist, and the jail asks for them only when a jailed call runs,
      // which is after this assembly has spawned anything.
      use Nil <- result.try(
        list.try_each(evolution_directories(settings), fn(directory) {
          bootstrap.ensure_private_directory(directory)
        }),
      )

      // A workspace used before the store moved still holds the artifacts
      // its transcript names. They are copied once the new store exists
      // (`prepare` made it) and before any tool can run, so an id from an
      // old session resolves on the first prompt. The pass stops at its own
      // deadline rather than holding the boot. It belongs to the local
      // placement: a registered workspace has no earlier release's
      // directory to adopt.
      blobs.adopt_legacy(
        workspace: settings.workspace,
        into: blob_root,
        logger:,
      )
      Ok(Here(prepared))
    }
  })

  use Nil <- result.try(
    workspace_policy.create_directories(
      option.values([workspace_policy.parent_directory(settings.session_path)]),
    ),
  )

  // One clock function, therefore one era, across session, broker,
  // tools, and provider — the shared-clock requirement the M2
  // integration learned live (spec-gaps, M2 item 1).
  let clock = clock.from_function(ffi_os.system_time_ms)
  let entropy = workspace_plane.mixed_entropy()

  // Clean close deletes the lease row, so a later open starts again at
  // fence one. A fresh owner prevents an older, expired connection with that
  // fence from regaining authority after another incarnation opens and closes.
  let random_bytes = token.production_entropy()
  let lease_owner = "loomd-" <> bit_array.base16_encode(random_bytes(32))
  use #(opened, retire, transfer) <- result.try(
    open_session_file(settings.session_path, lease_owner, clock)
    |> result.map_error(storage_open_refusal),
  )
  use Nil <- result.try(
    retain(
      owner,
      custody.Storage,
      fn() { retire() |> result.map_error(string.inspect) },
      fn() { Nil },
    ),
  )

  // Link storage owner process or bind to reserved session identifier.
  use storage_owner <- result.try(
    transfer() |> result.map_error(string.inspect),
  )

  // Decide how to handle use Nil <- result.try( ownership {.
  use Nil <- result.try(case ownership {
    None -> {
      process.link(storage_owner)
      Ok(Nil)
    }
    Some(#(_custodian, reserved)) -> {
      session.ensure_reserved_id(opened, reserved)
      |> result.replace(Nil)
      |> result.map_error(string.inspect)
    }
  })

  // Recall, on the same two-name pattern and gated the same way: the
  // holder that owns the index cannot exist until the runtime has been
  // opened (its canonical session id is what a scoped query and every
  // hit from this session are named by), so the tool seam closes over
  // the name now and the holder starts under it further down. An index
  // that will not open registers no tool at all.
  let history_name = address.new_address(namespace)
  let history_pulls = address.new_address(namespace)

  // Decide how to handle use history_seam <- result.try( services, ownership {.
  use history_seam <- result.try(case services, ownership {
    None, _ -> Ok(history_seam(index_path, history_name, logger))
    Some(shared), Some(#(_, identity)) ->
      Ok(
        option.map(domain_service.history(shared), fn(shared) {
          history.seam_for_with_logger(shared, identity, logger:)
        }),
      )
    Some(_), None ->
      Error("shared domain assembly requires owned session identity")
  })

  // The memory door, gated the same way and for the same reason: a
  // `remember` definition renders into the provider's cached byte prefix
  // and is paid for on every request, so a host whose memory plane will
  // not open registers no tool and says so once.
  let memory_seam =
    memory_seam(
      memory_store,
      memory_notes,
      settings.memory.inject,
      clock,
      entropy,
      logger,
    )

  // Durable *records* stay credit-driven: a client asks for a cut and the
  // bounded reader answers it. What the hub now also does is push a notice
  // when it learns of a commit (`protocol-change/018`), which is what makes
  // a second terminal render an answer without waiting for its idle refresh.
  let name = address.new_address(namespace)

  // The hint source that makes the hub learn of a commit at all. Minted
  // here, beside the hub's own name and before `api.open` below, for the
  // reason `client/agency`'s module doc gives: the forwarder closes over
  // the hub's *name*, so it can be subscribed to a writer that does not
  // exist yet and started under a hub that does not exist yet. A hint sent
  // while either is absent is lost by design — it cannot interrupt a
  // commit, and the next catch-up recovers.
  let forwarder_name = address.new_address(namespace)

  // The triggered-rule scanner is a named writer subscriber. A name is minted
  // whether or not any rule is configured — an unregistered name is a
  // subscriber the writer skips, which costs the commit path nothing —
  // so the branch that matters is the one that decides whether to start
  // anything under it.
  let rulescan_name = address.new_address(namespace)

  // The scheduled-heartbeat scanner is not a writer subscriber — it is
  // driven by its own injected timer, never by a commit hint, so its
  // name is minted for exactly one reason: the restartable-service tier
  // below needs an address that survives the scanner being replaced.
  let schedulescan_name = address.new_address(namespace)

  // The peer outbox drainer is reached by name. The Agency's config rings it
  // when a message is left undelivered, before any drainer exists, and the
  // restartable tier below needs an address that survives the drainer being
  // replaced.
  let outbox_drain_name = address.new_address(namespace)

  // The second drainer instance, over the records of this session's children
  // on other orchestrators, is reached by name for the same reason: the Agency
  // rings it when it leaves a record pending, before any drainer exists.
  let remote_drain_name = address.new_address(namespace)

  // The delegate session's instance, over what its children send their parent,
  // is reached by name for the same reason: the Agency rings it when a child
  // writes mail, before any drainer exists.
  let upward_drain_name = address.new_address(namespace)

  // The Agency's holder cannot exist yet: `api.open` takes the effects
  // and returns the runtime, and the runtime contains the effects, so a
  // closure over the live runtime is a value cycle rather than an
  // ordering problem. The seam closes over a *name* instead — the same
  // indirection `hub.commit_forwarder` uses four lines above — and the
  // holder is started under that name once the open has returned.
  let agency_name = address.new_address(namespace)

  // The reap's route to the broker, bound by name for the same reason: the
  // broker is built inside the plane, after this config, and the plane
  // consumes the config. `client/effect_abort` explains the join; the actor
  // behind the name is added to the services tier beside the async service.
  let effect_abort_name = address.new_address(namespace)

  // The role resolver outlives assembly and needs only the gateway, so its
  // environment must not retain the remaining session settings.
  let subagent_gateway = settings.gateway

  // A delegate session's depth cap is its spawner's `max_depth`; every other
  let agency_base = agency.default_config(agency_name, clock)
  let agency_config =
    agency.Config(
      ..agency_base,
      depth_cap: option.unwrap(settings.depth_cap, agency_base.depth_cap),
      peer_defaults: option.unwrap(
        settings.peer_defaults,
        peer_mail.no_defaults,
      ),
      outbox_queued: fn() { peer_outbox_drain.poke(outbox_drain_name) },
      remote: option.lazy_unwrap(settings.remote_reach, fn() {
        remote_reach.none(settings.session_id)
      }),
      remote_queued: fn() { peer_outbox_drain.poke(remote_drain_name) },
      deadline_tick_ms: settings.deadline_tick_ms,
      abort_effects: effect_abort.abort(effect_abort_name),
      claim: option.then(settings.metering, fn(metering) { metering.claim }),
      spawner: settings.spawner,
      upward_queued: fn() { peer_outbox_drain.ring(upward_drain_name) },
      models: list.map(settings.catalog.models, fn(entry) {
        #(
          machine_strand.ModelIdentity(
            provider: entry.name,
            model_id: entry.model_id,
          ),
          wiring.strand_thinking_level(entry.thinking),
        )
      }),
      // Role follows identity: a spawned child is seeded from the
      // `subagent` route when the catalogue routes one, and inherits its
      // parent when it does not. Resolved at spawn from the gateway built
      // at boot, so the answer is a function of durable configuration.
      subagent_model: fn() {
        use resolved <- result.map(
          provider_gateway.resolve(subagent_gateway, model.Subagent)
          |> result.replace_error(Nil),
        )
        #(
          machine_strand.ModelIdentity(
            provider: resolved.provider,
            model_id: resolved.model_id,
          ),
          wiring.strand_thinking_level(resolved.thinking),
        )
      },
    )

  // Construct agency seam and peer discovery wiring.
  let agency_seam = agency.seam(agency_config)
  let peer_endpoint = agency.peer_endpoint(agency_config, settings.session_id)
  let peer_wiring =
    peers.Wiring(
      own: peer_endpoint,
      metadata: json.Object([
        #("id", json.String(settings.session_id)),
        #("workspace", json.String(settings.workspace)),
      ]),
      directory: settings.peer_directory,
    )

  // The escalation plane has the same knot and the same answer: a name
  // now, a holder under it after the open. `interactive` is a question
  // rather than a flag because the answer changes while a call is
  // parked — a session serves whoever is attached, and a refusal must
  // not hold a call open for a decision from a client that has gone.
  // Asking the hub by name (not by handle) keeps that true across a hub
  // restart.
  let escalate_name = address.new_address(namespace)

  // A delegate session whose spawner sets an approval ceiling has a second
  // party to ask (protocol-change/089): the operator on the spawning
  // orchestrator, who can answer for as long as that orchestrator's node is
  // connected. The connection is read, never made, because the box does not dial
  // its spawner. A raised request is announced as a row in the session's outbox,
  // which the delegate drainer sends on.
  let spawner = settings.spawner
  let laptop = settings.laptop
  let escalate_config =
    escalate.Config(
      ..escalate.default_config(escalate_name, clock),
      interactive: fn() {
        hub.attached(hub.Gateway(name:)) > 0
        || delegate_outbox.answers(spawner, laptop)
      },
      parked: fn(opened_runtime, id, until) {
        announce_to_spawner(
          spawner,
          opened_runtime,
          id,
          until,
          upward_drain_name,
          logger,
        )
      },
    )

  // The scheduling plane is decided once, here, and reached two ways:
  // the `schedule_*` tools and the `schedule.*` code-mode capabilities.
  // One `Wiring` behind both is what stops a program and a tool call
  // disagreeing about what this session's schedules are. It needs the
  // live runtime, and the runtime does not exist until `api.open`
  // returns the registry being built for it — so it borrows through the
  // Agency's holder by name rather than standing up a second actor to
  // hold one value.
  let schedule_wiring =
    schedule_wiring(settings, agency_config, schedulescan_name)
  let schedule_door = option.map(schedule_wiring, scheduleseam.door)

  // The operator's half of the same plane, over the same wiring: the hub
  // lists what the tables and the strands hold and cancels what the
  // strands wrote. A host with no scheduling plane gets no admin, and
  // the hub then answers an empty listing and an unsupported cancel.
  let schedule_admin = option.map(schedule_wiring, scheduleadmin.admin)

  // The deferred background code-mode actor is the owner's, on the same
  // two-name pattern: its address is minted now so the `code_mode` tool
  // can close over it, and the actor starts under the service supervisor
  // below.
  let async_name = address.new_address(namespace)

  // The event bus is the node-global `pg` scope, and `bus.start` is the
  // idempotent way onto it: one daemon assembles many sessions, and the
  // second one must find the scope running rather than fail to start it
  // (`docs/architecture/events.md` on why `start` and `supervised` do
  // not compose). Sessions are kept apart by key, not by scope. Its one
  // production traffic today is the rolling tail of a running tool call,
  // published by the observer below and relayed by the hub as pushed
  // `tool_output` frames (`protocol-change/031`).
  let event_bus = bus.start()

  // The proposal queue: the `propose` tool and the operator's two commands
  // are doors over this one wiring. The queue lives in the domain's memory
  // store beside the rules file it edits, so it needs no runtime and every
  // session of the domain reaches the same one.
  let proposal_wiring =
    proposals.Wiring(
      store_path: memory_store,
      rules_path:,
      session: settings.session_id,
      clock:,
      entropy:,
      bus: event_bus,
      logger:,
      // The file this session loaded, from the daemon's desk: a session with
      // no daemon, or no file, refuses configuration proposals.
      config: settings.profile_desk
        |> option.then(fn(desk) { desk.watch })
        |> option.map(fn(source) {
          proposals.ConfigFile(path: source.path, check: source.check)
        }),
    )

  // Code mode, and the MCP servers it reaches, are one decision made on
  // the census: the second is unreachable without the first. The owner
  // starts the servers, so this happens between the workspace's two steps.
  //
  // A workspace on an executor starts here only the servers placed on the
  // orchestrator (`runs_on`), with the keys this daemon holds, before the
  // attach that carries their façades. The servers placed on the executor
  // run there from its own tables; the attach names them and nothing else.
  // This side does not yet know whether the executor offers code mode, so a
  // server started for an executor that does not is an accepted waste.
  use mcp_layer <- result.try(case home {
    Here(prepared) ->
      code_mode_mcp(settings, prepared.census.toolchain, logger, owner)
    There(_) ->
      started_mcp(
        orchestrator_placed(settings.catalog.mcp_servers),
        settings.secrets,
        logger,
        owner,
      )
  })

  let mcp_plan =
    protocol.McpPlan(
      served: list.map(mcp_wiring.facades(mcp_layer), fn(facade) {
        protocol.Facade(
          server: facade.server,
          module_name: facade.generated.module_name,
          source: facade.generated.source,
          surface: facade.generated.surface,
        )
      }),
      expected: executor_placed(settings.catalog.mcp_servers),
    )

  // Everything the workspace half reaches back to the session for, as one
  // record of plain functions. Locally each is the call it replaced: the
  // escalation seam, the bus observer, the Agency's holder and its tool-list
  // check. A local workspace never calls `capability`, since the owner's
  // code-mode arms are composed straight into its router below. A workspace
  // on an executor sends every owner-bound call here instead, and the
  // answer is composed from this session's own doors: the Agency, the
  // scheduling door and the peer mailbox it would have been given locally.

  // The name the evolution cell is registered under once the plane is open.
  // The code-mode configuration below is built first and holds only the name.
  let evolution_name = address.new_address(namespace)
  let owner_api =
    owner_services.local(
      handle: agency.fact_supplier(agency_config),
      runtime: agency.runtime_supplier(agency_config),
      escalate: escalate.seam(escalate_config).refused,
      output: hub.tool_output_observer(event_bus, opened),
      capability: case home {
        Here(_) -> owner_services.no_capability
        There(_) -> {
          // The owner's side over a given Agency: the operator's seams, the
          // scheduling door and the servers this daemon runs. A foreground
          // program is answered over the session's Agency, and a background
          // one over the Agency bound to its execution's custody.
          let seams = settings.codemode_seams
          let side_over = fn(over: Agency) {
            codemode_wiring.OwnerSide(
              ..codemode_wiring.owner_serving(
                seams,
                over:,
                schedules: schedule_door,
              ),
              mcp: mcp_layer,
            )
          }
          owner_codemode.answering_executions(
            side_over(agency_seam),
            peers: peer_wiring,
            background: owner_codemode.Background(
              service: async_name,
              agents: agency_config,
              runtime: agency.runtime_supplier(agency_config),
              side_over:,
            ),
          )
        }
      },
      holds: agency_seam.holds,
    )

  // The workspace half starts: the helper pool, the executor and the
  // broker are published to custody, the session base is recomputed now
  // that storage is open, and the workspace's tools are built over its own
  // doors. The owner contributes the arms of code mode which only it can
  // serve. See `workspace_plane` for why the base is computed twice.
  use half <- result.try(case home {
    Here(prepared) ->
      workspace_plane.start_local(
        prepared,
        workspace_plane.Attach(
          logger:,
          namespace:,
          retain: fn(part, cleanup, transfer) {
            retain(owner, part, cleanup, transfer)
          },
          owner: owner_api,
          session_label: session_label(agency.runtime_supplier(agency_config)),
          code_mode: workspace_plane.CodeModeAttach(
            arms: code_mode_arms(
              settings,
              agency_seam,
              schedule_door,
              mcp_layer,
              peer_wiring,
              evolution_name,
            ),
            tool: code_mode_tool(_, async_name, agency_config),
          ),
        ),
      )
      |> result.map(here(prepared, clock, _))
    There(placement) ->
      there(
        remote_workspace.Registered(
          placement:,
          session: settings.session_id,
          workspace: settings.workspace,
          opened:,
          owner: owner_api,
          clock:,
          reconcile_every_ms: owner_port.default_reconcile_every_ms,
          executions: async_codemode.remote(
            async_name,
            runtime: agency.runtime_supplier(agency_config),
            clock:,
            session: settings.session_id,
          ),
          mcp: mcp_plan,
          logger:,
        ),
        owner,
        logger,
      )
  })

  let plane = half.plane
  let broker_actor = plane.broker
  let blob_root = half.blob_root
  let toolchain = plane.census.toolchain

  // The clock every caller that builds an absolute deadline for the broker
  // reads: this session's own for a local workspace, and the executor's
  // timebase for one that is not.
  let call_clock = half.call_clock
  let code_mode_host = half.code_mode_host

  // Decide how to handle let discovered =  home {.
  let discovered = case home {
    Here(_) -> plane.census.extensions
    There(_) -> []
  }

  // Inspect sandboxing policy, environment variables, and log configuration warnings.
  let base_policy = plane.census.base_policy
  let environment = plane.census.env
  let unset_names = plane.census.unset_env

  // A `[secrets]` entry the host could not run is the same class of
  // event as a `[tools] env` name the host has not set, so it is
  // reported the same way and at the same moment: the name and why, and
  // never the command's output.
  log_secret_failures(settings.secret_failures, logger)

  // A retired `[memory]` key is accepted so a file that loaded before the
  // distillation pass was removed still loads; the warning is how the
  // operator learns the line does nothing.
  list.each(settings.memory.retired, fn(key) {
    log.warn(logger, "memory.config_retired_key", [
      field.ident(key: "key", value: key),
    ])
  })

  // Logged once per session, after storage has accepted the identity, so a
  // refused assembly stays silent.
  case settings.go_caches {
    Some(_) -> Nil
    None ->
      log.info(logger, "go_cache.disabled", [
        field.text(
          key: "reason",
          value: "no per-user cache directory, or the workspace contains it;"
            <> " Go caches stay under the tool HOME",
        ),
      ])
  }

  // A routed advisor the gateway could not resolve is the same class of
  // event, and the same treatment: one warned line, and a session that
  // runs without a reviewer rather than a boot that refuses.
  case advisor_unresolved(settings.catalog, settings.advisor) {
    False -> Nil
    True ->
      log.warn(logger, "advisor.unresolved", [
        field.text(
          key: "reason",
          value: "the [roles] advisor chain names no model this host can"
            <> " serve; the session runs with no advisor",
        ),
      ])
  }

  // A configured name the host has not set is one warned line and not a
  // boot failure: the operator learns it here, and the tool that wanted
  // it says so in band when it runs.
  list.each(unset_names, fn(name) {
    log.warn(logger, "tools.env_unset", [field.ident(key: "name", value: name)])
  })

  // One registry serves two masters: the effect wiring dispatches
  // through it, and the hub validates `set_config active_tools` against
  // it. They must be the same registry or the check means nothing.
  // The tool half of the scheduling plane decided above, over the same
  // wiring the code-mode half already holds.
  let schedule_seam = option.map(schedule_wiring, scheduleseam.seam)

  // A collision refuses the boot rather than resolving itself, because
  // every resolution silently changes what one of the two names means;
  // no built-in host can produce one, and an extension that would is
  // exactly the install an operator has to be told about.
  // The session's satellite registry, on the same two-name pattern as the
  // scratch store: the seam closes over the name now, and the actor that
  // answers it starts under the service supervisor below, because the
  // registry has to exist before the tools that reach it are built.
  //
  // Discovery, which happened once above, then answers three more
  // questions of each jailed extension: which tools it contributes, which
  // hook events it subscribed to, and how its node is launched. The hook half is used
  // further down, after the effects record exists to compose it into.
  let hosts_name = address.new_address(namespace)
  let hosts_seam =
    extension_hosts.seam(
      hosts_name,
      clock:,
      margin_ms: extension_host_margin_ms,
    )

  // An extension's tool is not placed on either side of the workspace
  // boundary, and running it here would act on this machine rather than the
  // checkout the model believes it is in. A workspace on an executor
  // therefore registers none, and says so once for each extension installed
  // on the executor.
  let #(extensions, extension_refusals) = case home {
    Here(_) ->
      extension_registrations(
        settings,
        discovered,
        logger,
        hosts_seam,
        extension_hosts.invoker(
          hosts_seam,
          at: hook_coordinates(
            settings,
            base_policy,
            entropy(),
            clock,
            environment,
          ),
        ),
        code_mode_host,
        extension_memory.for_session(agency_config),
      )
    There(_) -> #([], remote_extension_refusals(plane.census.extensions))
  }

  // The model's own door onto the compaction arithmetic. It reads the
  // strand's window the way the threshold will — the strand's own
  // catalogue entry, else the configured fallback — so what the model is
  // told and what it is compacted on are one number. Project the fallback
  // before retaining this callback so it does not keep all session settings.
  let facts = catalogue_facts(settings.catalog)
  let fallback_context_window = settings.context_window
  let context_seam =
    checkpoint.remaining_seam(opened, settings.compaction, fn(strand) {
      wiring.strand_window(
        opened,
        facts,
        strand,
        fallback: fallback_context_window,
      )
    })

  // The advisor, on the same two-name pattern as the scratch store and
  // the satellite registry: the address is minted now so the `advise`
  // seam and the hook wrapper can close over it, and the actor that
  // answers it starts under the service supervisor below. A catalogue
  // that routes no `advisor` role produces no wiring, and then nothing
  // downstream — no tool, no hook, no strand, no actor — exists at all.
  let advisor_name = address.new_address(namespace)
  let advisor_wiring =
    option.map(settings.advisor, fn(advisor_settings) {
      advisor.Wiring(
        session: opened,
        // Borrowed through the Agency's holder rather than held, for the
        // reason `schedule_wiring` borrows: `api.open` takes the effects
        // record this wiring is composed into and returns the runtime,
        // so a captured runtime would be a value cycle.
        runtime: fn() { agency.borrow_runtime(agency_config) },
        settings: advisor_settings,
        check: goal_check_wiring(settings, plane, clock, call_clock, entropy()),
        clock:,
        logger:,
        name: advisor_name,
      )
    })

  // The glance loop, on the advisor's two-name pattern: the hook below
  // casts to this address, and the machine that answers it starts under
  // the service supervisor. Its summarizer falls back from `summarize` to
  // `subagent` to `main`, so a catalogue that routes any model at all gets
  // a working glance with no configuration; only a catalogue that routes
  // nothing produces no wiring, and then no hook and no machine exist.
  let btw_name = address.new_address(namespace)

  // Initialize background glance and summary routing endpoints.
  let glance_name = address.new_address(namespace)
  let glance_wiring =
    glance_wiring(settings, opened, agency_config, clock, logger, glance_name)

  // The block summarizer takes two names: the provider tap casts reasoning
  // fragments to the first, and the writer sends commit hints to the
  // second, which the machine binds for itself. Both exist before the
  // runtime does, for the reason the forwarder's name does. Its route is
  // the `summarize` role alone, with no fallback to `main`, so a catalogue
  // that routes none gets no tap and no machine, and its terminals keep
  // the first-line digest (protocol 050).
  let summary_name = address.new_address(namespace)
  let summary_commits = address.new_address(namespace)
  let summary_route = summary_route(settings, logger)

  let skills = skill.discover(skill.directories(settings.home))
  list.each(skill.warnings(skills), fn(warning) {
    log.warn(logger, "skill.warning", [
      field.text(key: "detail", value: warning),
    ])
  })

  // The core upgrade controller migrates the scratch store in place, so it
  // exists only beside a local workspace, whose plane owns that store.
  let upgrade_name = address.new_address(namespace)
  let core_control = upgrade_control.seam(upgrade_name)

  // Only the source session governs evolution. A trial inherits the source's
  // code-mode host and socket root, so `open_evolution` would resolve the
  // source's own catalogue and hand the trial's model the doors over it.
  //
  // The machine is the placement's. A workspace with a local code-mode host
  // compiles and runs candidates in this VM, under the session's own scratch.
  // A workspace on an executor whose census says it compiles sends them there,
  // and has no scratch here because nothing is built on this machine. Anything
  // else has no evolution plane, as before.
  use evolution_wiring <- result.try(
    // Decide how to handle settings.evolution_role, code_mode_host {.
    case settings.evolution_role, code_mode_host, half.evolution_link {
      Trial(_), _, _ -> Ok(None)
      Source, None, None -> Ok(None)
      Source, Some(host), _ ->
        open_evolution(
          settings,
          local_evolution_machine(
            settings,
            host,
            base_policy,
            agency_config,
            namespace,
            environment,
            clock,
            logger,
          ),
          LocalScope,
          Some(evolution_scratch(settings)),
          agency_config,
          clock,
          owner,
          evolution_name,
        )
        |> result.map(Some)
      Source, None, Some(link) ->
        open_evolution(
          settings,
          evolution_machine_remote.new(link),
          ExecutorScope(
            label: "executor:" <> link.executor <> "/" <> settings.workspace,
          ),
          None,
          agency_config,
          clock,
          owner,
          evolution_name,
        )
        |> result.map(Some)
    },
  )

  use tool_registry <- result.try(
    list.append(
      [
        contributions.Contribution(
          contributions.BuiltIn,
          contributions.compose(
            contributions.described_tools(half.decls),
            contributions.owner_tools(
              Some(agency_seam),
              history_seam,
              memory_seam,
              schedule_seam,
              Some(context_seam),
            ),
          ),
        ),
      ],
      // After the built-ins, always. `contributions.registry` refuses a
      // repeated name whichever order it meets one in, so the order is
      // not what makes an extension unable to shadow `bash` — but the
      // collision message names the *second* claimant as the thing to
      // remove, and the newcomer is the extension.
      [
        contributions.Contribution(
          contributions.BuiltIn,
          list.append(skill_tool.tools(skills), peers.tools(peer_wiring)),
        ),
        // `advise` is registered for the whole session because a registry
        // is per session rather than per strand; `configuration` below
        // withholds it from the primary's active list, and
        // `advisor.ensure_strand` grants it to the advisor alone. The
        // seam refuses a call from any other strand in any case, by the
        // caller's durable name.
        // `propose` files a suggestion in the queue above and never blocks,
        // so it is registered unconditionally, like the skill and peer tools.
        contributions.Contribution(
          contributions.BuiltIn,
          contributions.proposal_tools(proposals.seam(proposal_wiring)),
        ),
        contributions.Contribution(contributions.BuiltIn, case advisor_wiring {
          None -> []
          Some(wiring) -> [advise.tool(advisor.seam(wiring))]
        }),
        ..list.map(extensions, fn(registration) { registration.contribution })
      ],
    )
    // The operator's deactivations, applied to the built-ins before the
    // names are claimed. This is the whole of how an extension's tool
    // comes to stand in for a built-in one: the built-in is gone, so
    // there is no collision to refuse and no override to perform.
    |> contributions.deactivate(settings.deactivated_tools)
    |> contributions.registry
    |> result.map_error(contributions.collision_message),
  )

  // Naming the registered tools here is what lets a release smoke assert
  // on registration rather than on a proxy for it: which tools this
  // server actually offers is decided by the planes above rather than by
  // the flags, so no flag dump answers the question.
  log.info(logger, "server.tools", [
    field.text(key: "names", value: string.join(tool.names(tool_registry), ",")),
  ])

  // The first activation records HEAD before recovered or new model work can
  // commit. The boot owner still holds the store alone; the runtime writer is
  // started below. Later activations reuse this exact durable baseline.
  let worktree_wiring =
    workspace_plane.worktree_wiring(
      plane.census,
      broker_actor,
      settings.demand,
      call_clock,
      entropy,
    )
  use git_start <- result.try(
    session_git.prepare(
      opened,
      settings.session_id,
      plane.census.workspace,
      fn() { worktree_diff.starting_revision(worktree_wiring) },
    ),
  )

  // The one observation of the session's tree. The gateway runs it for an
  // owner's terminal, and the instance keeps it for the web view's page, whose
  // admission is its own (`ui_socket.worktree_answer`).
  let observe_worktree = fn() {
    worktree_diff.capture_since(worktree_wiring, git_start)
    |> result.map(worktree_diff.to_json)
    |> result.map_error(worktree_diff.error_message)
  }

  // The system prompt, before the open, because `wiring.Config` needs
  // the string and `api.open` is what stands the writer up. The pinned
  // cells are therefore read straight off the store here — legal, nothing
  // owns them yet — and written back through the writer after the open.
  // The enforcement identity participates in that read: a changed or
  // legacy identity returns no reusable pin and deliberately buys one
  // truthful render.
  use pinned <- result.try(system_prompt.pinned_for(opened, settings.demand))
  use assembled <- result.try(
    system_prompt.assemble(pinned:, override: settings.system, render: fn() {
      render_prompt(
        settings,
        plane,
        rules_path,
        // The prompt is one string for every strand, so the advisor's
        // own tool is left out of the index the primary reads; the
        // advisor is told about it by its brief instead.
        list.filter(tool.names(tool_registry), fn(name) { name != advise.name }),
        tool.snippets(tool_registry),
      )
    }),
  )
  list.each(assembled.warnings, fn(warning) {
    log.warn(logger, "prompt.warning", [
      field.text(key: "detail", value: warning),
    ])
  })

  let configuration =
    machine_strand.StrandConfiguration(
      model: settings.model,
      thinking_level: seed_thinking(settings),
      // `tool.names` is sorted, which is what a durable active list must
      // be: the render order of the tool array is the provider cache's
      // byte prefix (see `gateway.canonical_tool_names`). Dropping
      // `advise` preserves that order, and it is the primary's half of
      // the one-way channel: the advisor may reach the primary, and the
      // primary cannot answer back.
      active_tool_names: list.filter(tool.names(tool_registry), fn(name) {
        name != advise.name
      }),
    )

  use chosen_profiles <- result.try(evolution_profiles(
    settings,
    opened,
    evolution_wiring,
  ))
  let running_profiles = option.unwrap(chosen_profiles, [])

  // A session that pinned no profile has nothing to attribute. Attaching the
  // observer anyway would make every provider request pay a durable write,
  // and a failed write would refuse inference that no profile touched.
  use gateway <- result.try(case running_profiles {
    [] -> Ok(settings.gateway)
    [_, ..] ->
      provider_gateway.with_profiles(
        settings.gateway,
        running_profiles,
        evolution_prompt.fingerprint,
        fn(attempt) { evolution_attempt(agency_config, attempt) },
      )
  })

  let wiring_config =
    wiring.Config(
      observe_output: owner_api.output,
      gateway:,
      role: model.Main,
      facts: catalogue_facts(settings.catalog),
      system: Some(assembled.text),
      api: settings.api,
      fallback_context_window: settings.context_window,
      fallback_max_output_tokens: settings.max_output_tokens,
      provider_timeout_ms: 300_000,
      session: opened,
      compaction: settings.compaction,
      broker: broker_actor,
      broker_timeout_ms: 30_000,
      registry: tool_registry,
      workspace: plane.census.workspace,
      blob_root:,
      base_policy:,
      escalations: escalate.Escalations(refused: owner_api.escalate),
      demand: settings.demand,
      env: environment,
      clock:,
      entropy:,
    )

  // Tool runs fetch their configuration from this holder instead of every
  // copy of the effects record carrying it. The `run` closure is copied into
  // each supervisor child specification and actor that holds the runtime, and
  // a closure over `wiring_config` put the whole tool registry into each one:
  // 29 copies in a one-session daemon, 27 of them through this slot.
  //
  // The holder must be published before `api.open_published`, because the
  // runtime may run a tool as soon as it opens, and it must retire after the
  // runtime's drain, because a tool runs until that drain finishes. Custody
  // sorts it directly behind `Runtime` (see `instance_owner.ToolConfig`), so
  // publishing it here, ahead of the runtime's own publication, changes
  // nothing about when the lease is released or when any other part retires.
  // The holder starts linked to this builder and is unlinked once custody
  // has acknowledged it, the same hand-off the broker and executor use.
  //
  // The workspace's run is held the same way and for the same reason: for a
  // local plane it closes over the workspace's tool registry, and the routed
  // tool surface below is copied exactly as the record the registry hung off
  // was. The two holders retire together, since both serve tools that run
  // until the runtime has drained.
  use holders <- result.try(start_holders(wiring_config, plane.run))
  let #(holder, run_holder) = holders
  use Nil <- result.try(
    retain(
      owner,
      custody.ToolConfig,
      fn() { stop_holders(holder, run_holder) },
      fn() {
        process.unlink(tool_holder.pid(holder))
        process.unlink(tool_holder.pid(run_holder))
      },
    ),
  )

  // A call is routed by the tool's name to the half that runs it. Owner-side
  // tools and extensions take the path every call took before the halves were
  // separate; a workspace-side tool reads its stored authority and runs on
  // the plane. The record's other slots are untouched.
  let held = wiring.build_effects_held(wiring_config, holder)
  let built =
    effects.Effects(
      ..held,
      tools: effects.ToolSurface(
        ..held.tools,
        run: wiring.run_placed(held.tools.run, run_holder, opened, clock),
        // A workspace on an executor keeps a record of the calls it ran, which
        // the runtime asks about an orphaned one. A local workspace has none.
        recover: half.recover,
      ),
    )
  let effects_record =
    effects.Effects(
      ..built,
      // Two taps, nested. The inner one feeds the bounded snapshot preview,
      // which stays the catch-up fallback for a terminal that reconnects
      // mid-answer; the outer one tees every delta to the hub as a
      // `ProviderDelta`, which is what `broadcast_delta` pushes to peers
      // (`protocol-change/018`). Without the outer tap the push path is
      // unreachable from the shipped daemon, which the live-delivery
      // fixture is what measured.
      //
      // The outer tap also feeds the block summarizer's live labels. It
      // rides the hub's relay rather than adding a third, so a reasoning
      // stream costs one more callback and no more processes.
      provider: hub.tap_provider_with(
        hub.tap_preview_provider(built.provider, to: name),
        to: name,
        also: side_and_summary_tap(
          btw_name,
          opened,
          wiring.request_builder(wiring_config),
          summary_tap(
            summary_route,
            settings.catalog,
            summary_name,
            wiring_config,
          ),
        ),
      ),
      // The only work this adds on the driver process is one
        // `process.spawn_unlinked`; everything a reap actually does
        // happens on that spawned process. See `client/agency`. The notes
        // digest wraps the result rather than replacing a slot, so the
        // two compose instead of one silently dropping the other.
        hooks: agency.reaping_hooks(built.hooks, agency_config)
        // A second reap on the same hook, and the two are independent:
        // the Agency's ends a run's undetached children, this one ends
        // the schedules keyed to a strand whose own run just finished.
        // Both wrap rather than replace, so composing them keeps both.
        // A host that shut the scheduling door has no wiring and adds
        // no hook at all.
        |> schedule_reaping(schedule_wiring)
        |> notes.digest_hooks(opened, clock)
        // The notes index is read at every run start rather than once here,
        // because a `remember` call in any session rewrites it, and an index
        // captured at assembly would hold every session one note behind.
        // It is a read of bytes and never an open, so a note landing
        // mid-session costs the next run one file read and nothing else. The
        // reader carries the logger because a sidecar too large to be an
        // index is refused, and a silent refusal looks exactly like a
        // repository with no notes. `[memory] inject = "off"` installs no
        // reader at all, and a repository with no notes has no file to read
        // and costs no tokens.
        |> with_memory_context(
          settings.memory.inject,
          memory.notes_reader(memory_notes, logger),
          clock,
        )
        // The advisor's three slots go on after the harness's own
        // digests and before the extension bus, so that its standing
        // instructions lead the advisor's request and an extension's
        // `context` fold still gets the last word on the primary's.
        //
        // Its run-end cast is *first* rather than last, and deliberately
        // so: the slot casts and then calls the inner one, because the
        // driver must not wait on a review and a cast placed after the
        // inner call would still not wait for it. So the advisor's
        // notification can overtake a later layer's follow-up. Nothing
        // rests on the ordering — the cast carries only an operation id,
        // the actor reads the branch itself, and a follow-up appended by
        // a later layer is picked up by the next feed, one run boundary
        // behind.
        |> with_advisor(advisor_wiring)
        // The glance cast rides the same usage slot as the advisor's step
        // counter and composes the same way: it casts and then calls the
        // inner slot, and it captures only the loop's name.
        |> with_glance(glance_wiring)
        // A metered spawner's delegate session reports each request's tokens and
        // judges the child against its budget, on a process the slot spawns, so
        // the driver waits on neither the registry nor the holder.
        |> with_metering(agency_config, settings.metering),
    )

  // The extension hook bus goes on last, over the composed record, so an
  // extension's `before_agent_start` injection lands after the harness's
  // own digests and its `context` fold is the final thing to touch a
  // request's messages. Wrapping rather than replacing is what lets the
  // two layers coexist at all.
  let effects_record =
    with_extension_hooks(effects_record, extensions, opened, clock, logger)

  // The imported-hook compatibility layer goes on last of all, over
  // the bus-composed record, for the same reason the bus goes on
  // last over the harness's own slots: a source's Stop hook is asked
  // after every native follow-up, and its PreToolUse verdict after
  // the harness's own clearance and any native gate — the ordering
  // that keeps one authority story. A session with no imported
  // sources composes nothing, which is the same as before this
  // existed.
  let effects_record =
    with_imported_hooks(
      effects_record,
      opened,
      settings,
      clock,
      plane,
      call_clock,
      logger,
      entropy,
    )

  // Decide how to handle let effects_record =  evolution_wiring {.
  let effects_record = case evolution_wiring {
    None -> effects_record
    Some(wiring) -> evolution_hook.wire(effects_record, wiring.live)
  }

  let options = api.default_options(configuration)
  use runtime <- result.try(
    api.open_published(
      opened,
      effects_record,
      api.Options(
        ..options,
        // The operator's `[retry]` table, or the runtime default when
        // the configuration has none.
        retry_policy: settings.retry_policy,
        // The run-settings snapshot every accepted run captures. This is
        // what gates step 3 of a checkpoint; the hooks carry their own
        // copy for the arithmetic.
        settings: operation.RunSettings(
          ..options.settings,
          compaction: settings.compaction,
        ),
        // The rule scanner, the optional search index and — since
        // `protocol-change/018` — the gateway are all commit-driven. Each
        // subscriber is a hint and never a payload: it pulls from its own
        // durable cursor, so a hint lost while it restarts costs latency,
        // never a row, a fire, or an event.
        //
        // The block summarizer's name is subscribed whether or not a route
        // started a machine under it: an unbound name is one the writer
        // skips, at no cost to the commit.
        subscribers: [
          writer.Routed(rulescan_name),
          writer.Routed(forwarder_name),
          writer.Routed(summary_commits),
          ..history_subscribers(history_seam, history_pulls)
        ],
        // Every strand of this session logs under the session's own
        // context; the driver narrows it to its strand, and each
        // dispatched effect narrows it again to `{op, step}`.
        logger:,
        // Model-spawned strands run under the tree's second strand
        // factory, so a subagent crash loop cannot spend the restart
        // budget protecting `main`.
        subagent: agency.is_subagent,
      ),
      fn(runtime) {
        // A drain needs the supervision tree and nothing else, so it is
        // handed the tree rather than the runtime it hangs off. This
        // closure is not called here: `custody.publish` sends it to the
        // instance owner, which holds it in `cleanups` for the life of the
        // session. A closure over `runtime` therefore put a whole
        // `Effects` graph into that owner's heap, one per session.
        let tree = runtime.tree

        retain(
          owner,
          custody.Runtime,
          fn() {
            runtime_supervisor.shutdown(tree, grace_ms: service_grace_ms)
            |> result.replace_error("runtime drain was not confirmed")
          },
          fn() { process.unlink(builder) },
        )
      },
    )
    |> result.map_error(fn(error) {
      "the runtime did not open: " <> string.inspect(error)
    }),
  )

  // Peer discovery reports a timestamped activation observation. Repository
  // similarity never confers a messaging grant or filesystem authority.
  use _ <- result.try(
    api.put_reserved_fact(
      runtime,
      "client/peers/git-observation",
      worktree_diff.peer_observation(worktree_wiring),
    )
    |> result.map_error(string.inspect),
  )

  // The writer exists now, so the other half of the pin can land: the
  // bytes every strand of this session will send and the enforcement
  // demand they describe, recorded durably so an unchanged next boot reads
  // them rather than deriving them again from inputs that may have moved.
  use Nil <- result.try(system_prompt.pin_for(
    runtime,
    assembled,
    settings.demand,
  ))

  // Only a session that made a choice pins one. A session with no evolution
  // wiring chose nothing, and pinning its empty list would stop it adopting a
  // profile at any later boot that has wiring.
  use Nil <- result.try(case chosen_profiles {
    Some(profiles) -> system_prompt.pin_profiles(runtime, profiles)
    None -> Ok(Nil)
  })

  // Decide how to handle use Nil <- result.try( evolution_wiring {.
  use Nil <- result.try(case evolution_wiring {
    None -> Ok(Nil)
    Some(wiring) ->
      evolution_live.recover(wiring.live, 120_000)
      |> result.map_error(fn(error) {
        // Recovery already retains its failed native continuation before
        // replying. Rendering that refusal must not add another owner.
        evolution_store.describe(error)
      })
  })

  // The advisor strand is seeded here, once the writer that claims its
  // three registers exists. A failure is one warned line rather than a
  // refused boot: a session whose advisor could not be created runs
  // exactly the strands it ran before advisors existed, and an operator
  // who configured one deserves to be told which reason stopped it.
  seed_advisor(runtime, advisor_wiring, tool_registry, logger)

  // Context observations need the immutable tool descriptions, while the hub's
  // execution surface owns the registry. Build the reader before retaining the
  // service start callback so observations carry neither executors nor Settings.
  let context_window = settings.context_window
  let context_reader =
    context_view.reader(
      opened,
      assembled.text,
      tool_registry,
      fn(identity) {
        facts(identity)
        |> result.map(fn(pair) { pair.0.context_window })
        |> result.unwrap(context_window)
      },
      settings.compaction,
    )

  // Restart specifications remain in the supervisor after initialization. Each
  // worker captures the fields it needs before its closure is constructed, so a
  // heartbeat or hub restart does not add a path through the whole Settings
  // record. The runtime and executor registry keep their intended owners.
  let async_heartbeat_ms = settings.jobs_policy.heartbeat_ms
  let hub_session_id = settings.session_id
  let btw_gateway = gateway
  let hub_catalog = settings.catalog
  let child_history_reach = settings.remote_reach
  let first_prompt = settings.first_prompt

  // Project profile, spawner, remote reach, and memory settings for the hub.
  let profile_desk = settings.profile_desk
  let spawner_link = settings.spawner
  let hub_remote_reach = agency_config.remote
  let memory_settings = settings.memory

  // The two things the hub asks the workspace for, projected before the
  // hub's child specification closes over them: the plane itself holds the
  // workspace's tool registry, and a specification the supervisor keeps for
  // restarts must not.
  let live_jobs = plane.live_jobs
  let resolve_directory = plane.resolve_directory

  // Directory mutation owns only the restartable writer capability. The hub
  // still receives Runtime for execution, but its admin supplier does not add
  // another executable-effects graph to the initialized gateway State.
  let directory_facts = api.fact_handle(runtime)

  // Decide how to handle let code_mode_issue =  toolchain {.
  let code_mode_issue = case toolchain {
    Error(reason) -> Some(reason)
    Ok(_) ->
      case list.contains(settings.deactivated_tools, "code_mode") {
        True -> Some("disabled in the host tool configuration")
        False -> None
      }
  }

  // Everything below the runtime that an operation's abort must also stop:
  // the async service stops admitting launches under it, and the broker
  // cancels its executions and signals their process groups. The operator's
  // abort calls this through the gateway, and the Agency's reaps reach the
  // same closure through `effect_abort`, so there is one definition of what
  // aborting an operation cancels below the runtime.
  let abort_op_effects = fn(op) {
    let _fenced = async_runs.abort_operation(async_name, op)
    broker.abort(broker_actor, op)
  }

  // How the execution service stops a background program and what recovery
  // may still learn about one. A local program runs under this session's own
  // broker, so stopping it aborts its step, and its value died with the
  // service. A program on an executor is stopped by a message the executor's
  // ledger records, and a value it committed before a restart is read back
  // from that ledger instead of being called lost.
  let #(async_abort, async_surviving) = case half.executions {
    None -> #(async_codemode.abort(broker_actor), async_runs.NothingSurvives)
    Some(remote) -> {
      let lookup = remote.lookup
      #(
        remote.stop,
        async_runs.AskWhere(fn(record: async_execution.Execution) {
          case lookup(record.operation, record.step) {
            Ok(protocol.Executed(value:)) -> Ok(value)
            Ok(protocol.Missing)
            | Ok(protocol.Admitted)
            | Ok(protocol.Terminal(..))
            | Ok(protocol.Unknown)
            | Ok(protocol.Fenced)
            | Error(_) -> Error(Nil)
          }
        }),
      )
    }
  }

  // The restartable half of the per-child policy. These children hold
  // no state a restart cannot rebuild and — crucially — none of them is
  // addressed by pid: each registers under a name and every caller
  // reaches it through that name, so a replacement is the same address,
  // and a crash here costs a moment of hints, an evicted cache, or the
  // sockets attached to the old hub rather than the server. One-for-one
  // because they are independent: nothing here reaches a sibling except
  // through a name.
  let services_tree =
    sup.new(sup.OneForOne)
    |> with_service_custody(owner, builder)
    |> sup.restart_tolerance(
      intensity: service_restart_intensity,
      period: service_restart_period,
    )
    // Before the Agency's holder, so a reap it runs at start finds the name bound.
    |> sup.add(effect_abort.supervised(effect_abort_name, abort_op_effects))
    |> sup.add(
      supervision.worker(fn() { agency.start(agency_config, runtime) }),
    )
    |> sup.add(
      supervision.worker(fn() { escalate.start(escalate_config, runtime) }),
    )
    |> sup.add(
      supervision.worker(fn() {
        async_runs.start(
          async_name,
          async_runs.Wiring(
            runtime:,
            clock:,
            abort: async_abort,
            abort_children: effect_abort.abort(effect_abort_name),
            heartbeat_ms: async_heartbeat_ms,
            surviving_value: async_surviving,
          ),
        )
      }),
    )
    // The scratch store is here rather than among the fatal children
    // because it is addressed by *name* and holds nothing a restart
    // cannot do without: `cap/kv` requires every caller to tolerate a
    // vanished value, so an emptied store costs a running program a
    // cache miss it was already written to handle.
    |> half.children.scratch
    // Accepted upgrades belong to this session service, so a disconnected CLI
    // cannot strand the scratch actor while its callbacks are suspended.
    |> fn(builder) {
      case half.scratch_name {
        Some(scratch_name) ->
          sup.add(
            builder,
            upgrade_control.supervised(upgrade_name, scratch_name),
          )
        None -> builder
      }
    }
    // The satellite registry is in this tier because a restart costs
    // exactly what a satellite crash costs, which extensions are already
    // written to meet: every host it held is `Gone` to its next caller,
    // the tools stay registered, and each lost node is reaped by the
    // launcher's own janitor when the registry that owned it dies.
    |> sup.add(extension_hosts.supervised(
      hosts_name,
      clock,
      list.map(extensions, fn(registration) { registration.hosting }),
    ))
    // The background jobs actor is in this tier for exactly the reason
    // the satellite registry above it is, and the price is the same
    // shape: a restart kills every runner it owned, the broker's relays
    // see their callers die and climb the cancel ladder, and the
    // replacement's first act — before it serves one request — is to
    // sweep `job/*` and record every live job as `Lost`. The model
    // learns on its next poll. Losing a session because a job's
    // bookkeeping crashed would be the worse trade.
    |> half.children.jobs
    // The advisor actor is in this tier because everything it holds is
    // durable: the guard and the feed cursor are two `fact.custom`
    // cells, and a replacement reads both on its first message. A crash
    // costs at most one skipped review, which the next run end offers
    // again.
    |> with_advisor_actor(advisor_wiring)
    // The glance loop is in this tier because everything it would lose is
    // either durable or offered again: titles live in their cells, and the
    // next step on each strand books it afresh.
    |> with_glance_loop(glance_wiring)
    |> sup.add(
      supervision.worker(fn() { btw.start(btw_name, btw_gateway, opened) }),
    )
    // The block summarizer is in this tier because what it would lose is
    // either stored or not worth keeping: a settled label is in its cell,
    // and a live one is replaced by the next or by the settled label.
    |> with_block_summarizer(
      summary_route,
      settings.catalog,
      opened,
      runtime,
      event_bus,
      logger,
      summary_name,
      summary_commits,
    )
    // The language-server manager is in this tier because a replacement
    // loses nothing a query cannot rebuild: the dead manager's keepers
    // stop their servers when it goes, and the next query starts one
    // again, cold, and says so.
    |> half.children.lsp_manager
    |> with_rule_scanner(settings, runtime, rulescan_name, logger)
    |> with_schedule_scanner(settings, runtime, schedulescan_name, logger)
    // The peer outbox drainer is in this tier because everything it owes is
    // a pending row in the session's own store: a replacement begins with a
    // pass that reads them again, and a message sent while it restarts is
    // picked up by that pass.
    |> with_peer_outbox_drain(peer_wiring, runtime, outbox_drain_name, logger)
    // The remote drainer is in this tier for the same reason: the stubs and
    // run-end rows it resends are facts in the session's own store, so a
    // replacement begins with a pass that reads them again.
    |> with_remote_drain(agency_config, runtime, remote_drain_name, logger)
    // A delegate session's instance for what its children send their parent is
    // in this tier for the same reason: the mail rows it sends are facts in the
    // session's own store, so a replacement begins with a pass that reads them
    // again.
    |> with_upward_drain(
      settings,
      agency_config,
      runtime,
      upward_drain_name,
      logger,
    )
    // The commit forwarder is in this tier for the reason everything else
    // here is: it is reached by name and holds nothing. It carries no
    // state at all, in fact — one writer publication in, one hub hint out
    // — so a restart costs whichever hints landed in the gap, and the
    // hub's next pull covers them.
    |> sup.add(
      supervision.worker(fn() {
        hub.commit_forwarder(to: name, as_name: forwarder_name)
      }),
    )
    |> with_config_watch(profile_desk, name, logger)
    |> sup.add(
      supervision.worker(fn() {
        hub.start(
          hub.default_options(hub_session_id, runtime)
            |> hub.with_directories(directories.admin_over(
              opened,
              fn() { Ok(directory_facts) },
              resolve_directory,
            ))
            |> hub.with_bus(event_bus)
            |> with_summary_demand(summary_route, summary_name)
            |> hub.with_worktree_diff(observe_worktree)
            |> hub.with_context(context_reader)
            |> hub.with_btw(btw_name)
            |> hub.with_live_jobs(live_jobs)
            |> with_child_history(child_history_reach, runtime)
            |> hub.with_catalog(hub_catalog)
            |> with_first_prompt(first_prompt)
            |> with_profile_desk(profile_desk)
            |> with_spawner_link(spawner_link)
            |> hub.with_remote_reach(hub_remote_reach)
            |> hub.with_registry(tool_registry)
            |> hub.with_extension_refusals(extension_refusals)
            |> hub.with_skills(skills)
            |> with_evolution_control(evolution_wiring, core_control)
            |> hub.with_code_mode_issue(code_mode_issue)
            // The operator's abort reaches the effect plane here, and
            // this is the only place it can: the runtime stops the
            // strand's live effects, but a background job runs under a
            // sibling step of the same operation and is nobody's live
            // effect, and `runtime` may not depend on `broker` to go
            // looking for it. The host owns both halves, so the host
            // joins them.
            |> hub.with_effect_abort(abort_op_effects)
            // The operator's abort reaches the advisor's goal loop the
            // same way it reaches the effect plane: the gateway is the
            // one place an abort enters, and an aborted run never fires
            // the run-end hook the advisor listens on. The cast is
            // dropped if the actor is absent, which is the same loss the
            // advisor's own run-end casts already tolerate.
            |> with_goal_abort(advisor_wiring)
            // The operator's five goal commands, over the same wiring
            // the abort notice rides. Without this the gateway holds no
            // seam and every goal mutation answers `code_unsupported` —
            // a session with a routed advisor telling its operator it
            // has no reviewer.
            |> with_goal_control(advisor_wiring)
            |> with_schedule_admin(schedule_admin)
            |> hub.with_proposals(proposals.admin(proposal_wiring))
            |> hub.with_memory_overview(
              memory_overview.admin(
                memory_overview.Wiring(
                  store_path: memory_store,
                  notes_path: memory_notes,
                  rules_path:,
                  memory: memory_settings,
                  pending: fn() {
                    proposals.listing(proposal_wiring)
                    |> result.map(fn(held) { held.pending })
                  },
                ),
              ),
            ),
          name,
        )
      }),
    )

  // The index holder is in this tier for the same reason the scratch
  // store is: it is addressed by name, and everything it holds is one
  // connection to a rebuildable projection that a restart reopens. Its
  // canonical session id comes from the runtime, which is why it is
  // added here rather than in the pipeline above.
  use started_services <- result.try(
    services_tree
    |> with_instance_history(
      services,
      history_seam,
      history.over_session(
        name: history_name,
        path: index_path,
        session: api.session_id(runtime),
        store: opened.store,
        generation: history.sqlite_generation(settings.session_path),
        timeout_ms: history.default_timeout_ms,
      )
        |> history.with_source(settings.session_path),
      history_pulls,
    )
    |> sup.start
    |> result.map_error(fn(error) {
      "the service supervisor did not start: " <> string.inspect(error)
    }),
  )

  // A delegate session remembers what its spawner's operator approved for the
  // session, and the owner of this machine may have narrowed the spawner's
  // approval ceiling since. The grants that are outside the ceiling as it is now
  // are withdrawn here, before the session serves a child (protocol-change/089).
  withdraw_outside_the_ceiling(settings, runtime, logger)

  // The host owns this supervisor through the record and a monitor, not
  // through the start link, so that its death is a fault the host
  // *handles* rather than a signal that fells the host mid-teardown.
  process.unlink(started_services.pid)

  // Build the initialized session instance record.
  Ok(Instance(
    peer: peer_endpoint,
    spawns: agency.DelegateEndpoint(
      ..agency.delegate_endpoint(agency_config),
      resolve: fn(
        parent,
        _child,
        escalation_id,
        decision,
        expected_seq,
        decider,
      ) {
        Ok(hub.decide(
          hub.Gateway(name:),
          parent,
          escalation_id,
          decision,
          expected_seq,
          decider,
        ))
      },
    ),
    inbox: agency.child_inbox(agency_config),
    relay: relayed_session.endpoint(
      agency.runtime_supplier(agency_config),
      fn() {
        hub.stop_relayed(hub.Gateway(name:))
        |> result.replace_error(remote_top.StoreFailure(
          reason: "the session's hub did not answer",
        ))
      },
      fn(terms, escalation_id, decision, expected_seq, decider) {
        Ok(hub.decide_relayed(
          hub.Gateway(name:),
          terms.spawner,
          terms.ceiling,
          escalation_id,
          decision,
          expected_seq,
          decider,
        ))
      },
    ),
    runtime:,
    storage_owner:,
    broker: broker_actor,
    tools: holder,
    pool: half.pool,
    executor: half.executor,
    evolution_retire: close_evolution(evolution_wiring),
    evolution_cell: option.map(evolution_wiring, fn(wiring) { wiring.cell }),
    legacy_host: None,
    plane:,
    gateway: hub.Gateway(name:),
    worktree: observe_worktree,
    goal: option.map(advisor_wiring, goalcommand.seam),
    goal_abort: option.map(advisor_wiring, advisor.abort_notice),
    services: started_services.pid,
    namespace:,
    stops:,
    session_id: settings.session_id,
    prompt: assembled,
    helper_path: settings.helper_path,
    mcp: mcp_layer,
    lsp: half.lsp,
    rulescan: case settings.rules {
      [] -> None
      _configured -> Some(rulescan_name)
    },
    // The same two questions `with_schedule_scanner` starts one on, in
    // the same order. Deriving this from `schedules` alone was wrong the
    // moment the model-facing door could start a scanner with no
    // operator schedules configured: the field said `None` while a
    // scanner was running under that very name.
    schedulescan: case
      settings.schedules,
      schedule.policy_opens_the_door(settings.schedule_policy)
    {
      [], False -> None
      _configured, _door -> Some(schedulescan_name)
    },
  ))
}

// Starts the two holders a session's tool runs fetch from: the owner's
// configuration and the workspace's run. A failure to start the second
// retires the first, which is linked to the builder and would otherwise
// outlive an assembly that never published it.

/// Establishes start holders for the caller, keeping its validation and result policy at this boundary.
fn start_holders(
  config: wiring.Config,
  workspace_run: wiring.WorkspaceRun,
) -> Result(
  #(tool_holder.Holder(wiring.Config), tool_holder.Holder(wiring.WorkspaceRun)),
  String,
) {
  use holder <- result.try(tool_holder.start(config))

  // Decide how to handle tool_holder.start(workspace_run) {.
  case tool_holder.start(workspace_run) {
    Ok(run_holder) -> Ok(#(holder, run_holder))
    Error(reason) -> {
      let _retired = tool_holder.stop(holder)
      Error(reason)
    }
  }
}

// Retires both holders, the workspace's run first. Success is the proof
// custody needs that neither process remains.

/// Establishes stop holders for the caller, keeping its validation and result policy at this boundary.
fn stop_holders(
  holder: tool_holder.Holder(wiring.Config),
  run_holder: tool_holder.Holder(wiring.WorkspaceRun),
) -> Result(Nil, String) {
  use Nil <- result.try(tool_holder.stop(run_holder))
  tool_holder.stop(holder)
}

// Acknowledgement transfers startup custody before any resource can begin work.
// Legacy assembly keeps its original links until the listener path is migrated.

/// Establishes retain for the caller, keeping its validation and result policy at this boundary.
fn retain(
  owner: Option(custody.Owner),
  part: custody.Part,
  cleanup: fn() -> Result(Nil, String),
  transfer: fn() -> Nil,
) -> Result(Nil, String) {
  // Decide how to handle owner {.
  case owner {
    None -> Ok(Nil)
    Some(owner) -> {
      use Nil <- result.map(custody.publish(owner, part, cleanup))
      transfer()
    }
  }
}

// A temporary first child publishes the services root exactly once. Wrapping
// the permanent forwarder would repeat publication every time it restarted.

/// Establishes with service custody for the caller, keeping its validation and result policy at this boundary.
fn with_service_custody(
  tree: sup.Builder,
  owner: Option(custody.Owner),
  builder: Pid,
) -> sup.Builder {
  // Decide how to handle owner {.
  case owner {
    None -> tree
    Some(owner) -> {
      let publication =
        supervision.worker(fn() {
          let root = process.self()
          use Nil <- result.try(
            custody.publish(owner, custody.Services, fn() {
              stop_services_owned(root)
            })
            |> result.map_error(actor.InitFailed),
          )
          process.unlink(builder)

          // This child owns no effects or mutable state. The supervisor retains
          // it solely to make its one-time publication precede all service starts.
          owned_actor.new(Nil)
          |> owned_actor.on_message(fn(state, _message: Nil) {
            owned_actor.continue(state)
          })
          |> owned_actor.start
        })
        |> supervision.restart(supervision.Temporary)
      sup.add(tree, publication)
    }
  }
}

/// Establishes stop services owned for the caller, keeping its validation and result policy at this boundary.
fn stop_services_owned(pid: Pid) -> Result(Nil, String) {
  // A late monitor cannot recover a transitive root's original exit verdict.
  // Missing or killed services therefore retain custody, even if descendants
  // later disappear; this seam does not promise recovery after that proof loss.
  let watch = process.monitor(pid)
  let requested = ffi_os.terminate_supervisor(pid, service_grace_ms)

  // Decide how to handle requested {.
  case requested {
    Ok(Nil) -> owned_retirement(watch, service_grace_ms)
    Error(Nil) -> {
      process.demonitor_process(watch)
      Error("service shutdown did not acknowledge complete retirement")
    }
  }
}

/// Establishes owned retirement for the caller, keeping its validation and result policy at this boundary.
fn owned_retirement(
  watch: process.Monitor,
  within: Int,
) -> Result(Nil, String) {
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      // Decide how to handle down.reason {.
      case down.reason {
        process.Normal -> Ok(Nil)
        process.Abnormal(reason) -> {
          use reason <- result.try(
            decode.run(reason, atom.decoder())
            |> result.replace_error("resource retirement was abnormal"),
          )

          // Decide how to handle atom.to_string(reason) == "shutdown" {.
          case atom.to_string(reason) == "shutdown" {
            True -> Ok(Nil)
            False -> Error("resource retirement was abnormal")
          }
        }
        other ->
          Error("resource retirement was not normal: " <> string.inspect(other))
      }
    })
    |> process.selector_receive(within)
  process.demonitor_process(watch)
  outcome
  |> result.replace_error("resource retirement timed out")
  |> result.flatten
}

/// Takes a booted server apart and returns once it is gone, with the
/// session lease released or deliberately retained.
///
/// The teardown itself runs on the boot's host process (`tear_down`
/// below), and this only asks for it and waits. Running it here as well
/// would make two teardowns: the listener's death starts the host's, and
/// only one of the two can hold the drain witness that authorizes the
/// lease release. The loser used to return before the winner had
/// released, so an immediate reopen found the old incarnation's lease.
///
/// Idempotent and callable from any process. After a fault the host has
/// already torn down and exited, so this returns at once.
///
/// ## Examples
///
/// ```gleam
/// // serve.shutdown(booted)
/// ```
///
pub fn shutdown(booted: Booted) -> Nil {
  host.retire(booted.host)
}

// The teardown the host runs, front to back: the listener first so no new
// client arrives mid-teardown, then the runtime — whose close stops the
// strand drivers before the writer they commit through and releases the
// session lease while its drain witness is still observable — then the
// service supervisor and finally the effect plane, broker before pool
// because the broker is what holds helpers out on loan. An error closing
// the session is swallowed deliberately: it means the lease release did not
// commit, which only the TTL can now mop up, and there is nothing left to
// abandon.
fn tear_down(booted: Booted) -> Nil {
  server.stop(booted.served)
  close_instance(booted.instance)
}

/// Closes one session without touching any public listener or other session.
///
/// An instance opened through `open_instance` is retired by its host, which
/// is the only process that runs the teardown; any other instance runs the
/// same retirement here. Either way the order is `instance_retirement_body`'s:
/// the hub's held prompts are returned before the runtime closes, the
/// runtime before its tools, evolution plane, broker and helpers, and the
/// MCP clients last.
///
/// ## Examples
///
/// ```gleam
/// // serve.close_instance(instance)
/// ```
@internal
pub fn close_instance(instance: Instance) -> Nil {
  // Decide how to handle instance.legacy_host {.
  case instance.legacy_host {
    Some(owner) -> host.retire(owner)
    None -> {
      let _outcome = retire_instance_body(instance)
      Nil
    }
  }
}

// The triggered-rule scanner, and the decision not to start one.
//
// A server with no `[[rule]]` in its configuration starts no scanner at
// all — not a scanner with an empty list — and says so in one line. This
// is the `codemode.unavailable` posture: a plane nobody configured
// should cost a host a process and a subscription of exactly nothing,
// and an operator who *did* configure rules and sees no effect deserves
// a line naming how many were loaded rather than silence to reason
// from.

/// Establishes with rule scanner for the caller, keeping its validation and result policy at this boundary.
fn with_rule_scanner(
  builder: sup.Builder,
  settings: Settings,
  runtime: api.Runtime,
  name: address.Address(writer.Event),
  logger: Logger,
) -> sup.Builder {
  // Decide how to handle settings.rules {.
  case settings.rules {
    [] -> {
      log.info(logger, "rules.none", [])
      builder
    }
    configured -> {
      log.info(logger, "rules.loaded", [
        field.count(key: "rules", value: list.length(configured)),
        field.text(
          key: "names",
          value: configured
            |> list.map(fn(rule) { rule.name })
            |> string.join(","),
        ),
      ])
      sup.add(
        builder,
        rulescan.supervised(
          rulescan.default_options(configured)
            |> rulescan.with_logger(logger),
          runtime,
          name,
        ),
      )
    }
  }
}

// The peer outbox drainer. Unlike the scanners it is always started: whether a
// session will ever owe a peer message is not known at boot, and an idle
// drainer holds no timer.

/// Establishes with peer outbox drain for the caller, keeping its validation and result policy at this boundary.
fn with_peer_outbox_drain(
  builder: sup.Builder,
  wiring: peers.Wiring,
  runtime: api.Runtime,
  name: address.Address(peer_outbox_drain.Message),
  logger: Logger,
) -> sup.Builder {
  sup.add(
    builder,
    peer_outbox_drain.supervised(
      peer_outbox_drain.over(
        peer_outbox_drain.peer_pass(wiring, logger),
        runtime.effects.timers.after,
      ),
      name,
    ),
  )
}

// The second drainer instance, over this session's children on other
// orchestrators (protocol-change/084). Like the peer-mail one it is always
// started: whether a session will ever start a child elsewhere is not known at
// boot, and an idle drainer holds no timer. Its first pass at session open is
// what resends a spawn that was owed when the daemon last stopped.

/// Establishes with remote drain for the caller, keeping its validation and result policy at this boundary.
fn with_remote_drain(
  builder: sup.Builder,
  agency_config: agency.Config,
  runtime: api.Runtime,
  name: address.Address(peer_outbox_drain.Message),
  logger: Logger,
) -> sup.Builder {
  sup.add(
    builder,
    peer_outbox_drain.supervised(
      peer_outbox_drain.over(
        remote_drain.pass(
          agency.runtime_supplier(agency_config),
          agency_config.remote,
          agency_config.clock,
          logger,
        ),
        runtime.effects.timers.after,
      ),
      name,
    ),
  )
}

// The instance that sends what a delegate session's children owe their parent
// (protocol-change/084, phase 2). Only a delegate session has a spawner link, so
// every other session starts none. Its first pass at session open is what sends
// a message that was owed when the daemon last stopped.

/// Establishes with upward drain for the caller, keeping its validation and result policy at this boundary.
fn with_upward_drain(
  builder: sup.Builder,
  settings: Settings,
  agency_config: agency.Config,
  runtime: api.Runtime,
  name: address.Address(peer_outbox_drain.Message),
  logger: Logger,
) -> sup.Builder {
  case settings.spawner {
    None -> builder
    Some(link) ->
      sup.add(
        builder,
        peer_outbox_drain.supervised(
          peer_outbox_drain.over(
            delegate_drain.pass(
              agency.runtime_supplier(agency_config),
              fn() {
                agency.delegate_occupancy(agency_config) == agency.Occupied
              },
              fn() {
                let #(now, _clock) = clock.read(agency_config.clock)
                now
              },
              link,
              option.lazy_unwrap(settings.laptop, delegate_outbox.absent),
              logger,
            ),
            runtime.effects.timers.after,
          ),
          name,
        ),
      )
  }
}

// The watcher of the configuration file the session loaded, when the daemon
// named one. It is in this tier because all it holds is the fingerprint of the
// text the session has: a replacement starts again from the baseline read
// before the open, and at worst reopens the session once more than it needed.

/// Establishes with config watch for the caller, keeping its validation and result policy at this boundary.
fn with_config_watch(
  builder: sup.Builder,
  desk: Option(profile_switch.Desk),
  hub_name: address.Address(hub.Message),
  logger: Logger,
) -> sup.Builder {
  case option.then(desk, fn(desk) { desk.watch }) {
    None -> builder
    Some(source) ->
      sup.add(
        builder,
        supervision.worker(fn() {
          config_watch.start(
            source,
            fn() { hub.configuration_changed(hub_name) },
            logger,
          )
        }),
      )
  }
}

// The scheduled-heartbeat scanner, and the decision not to start one —
// the same `codemode.unavailable` posture `with_rule_scanner` takes, for
// the same reason: a plane nobody configured should cost a host a
// process of exactly nothing.

/// Establishes with schedule scanner for the caller, keeping its validation and result policy at this boundary.
fn with_schedule_scanner(
  builder: sup.Builder,
  settings: Settings,
  runtime: api.Runtime,
  name: address.Address(schedulescan.Message),
  logger: Logger,
) -> sup.Builder {
  let door_open = schedule.policy_opens_the_door(settings.schedule_policy)

  // Decide how to handle settings.schedules, door_open {.
  case settings.schedules, door_open {
    // Nothing configured and no door: the plane costs a host exactly
    // nothing, which is the posture `with_rule_scanner` takes.
    [], False -> {
      log.info(logger, "schedules.none", [])
      builder
    }

    // An open door with no operator schedules still needs the scanner,
    // because the model may create one at any moment and a scanner that
    // was never started could not fire it.
    configured, _ -> {
      log.info(logger, "schedules.loaded", [
        field.count(key: "schedules", value: list.length(configured)),
        field.text(
          key: "names",
          value: configured
            |> list.map(fn(sched) { sched.name })
            |> string.join(","),
        ),
        field.text(
          key: "model_created",
          value: policy_label(settings.schedule_policy),
        ),
      ])
      sup.add(
        builder,
        schedulescan.supervised(
          schedulescan.default_options(configured)
            |> with_model_door(settings.schedule_policy)
            |> schedulescan.with_logger(logger),
          runtime,
          name,
        ),
      )
    }
  }
}

// The scanner has to keep rescanning exactly when a schedule may appear
// without anything in its own state changing, which is the policy's own
// question rather than a second one. Asking the policy here rather than
// threading the answer down as a flag keeps that decision and the
// decision to start the scanner at all reading off one source.

/// Establishes with model door for the caller, keeping its validation and result policy at this boundary.
fn with_model_door(
  options: schedulescan.Options,
  policy: schedule.Policy,
) -> schedulescan.Options {
  case schedule.policy_opens_the_door(policy) {
    True -> schedulescan.with_model_door_open(options)
    False -> options
  }
}

/// Establishes policy label for the caller, keeping its validation and result policy at this boundary.
fn policy_label(policy: schedule.Policy) -> String {
  case policy {
    schedule.ModelSchedulesOff -> "off"
    schedule.ModelSchedulesSteer -> "steer"
    schedule.ModelSchedulesWake -> "wake"
  }
}

// The coordinates every hook invocation in this session runs under.
//
// The bus's `Invoker` carries none, which is right: a hook fires on the
// harness's own timeline rather than inside a model-made tool call, so
// there is no run whose `{op_id, step_id}` it could borrow. One operation
// is minted here for the session's hooks instead, and it is what a hook's
// capability token is bound to and what its effects clear against — so a
// hook's reads are attributable to "the extension hooks", never to
// whichever run happened to be in flight.
//
// The base policy is a parameter rather than a read of
// `settings.base_policy`, because the two are not the same value: the
// session base is the settings' policy after the index, memory,
// worktree and code-mode passes have widened and masked it, and only
// that assembled base carries the toolchain mounts an extension node
// requires. A hook handed the settings' policy would meet an empty
// mount list against three required mounts and every hook-fired launch
// would be refused.

/// Returns hook coordinates according to the client contract.
@internal
pub fn hook_coordinates(
  settings: Settings,
  base_policy: policy.SandboxPolicy,
  seed: Int,
  clock: Clock,
  environment: List(#(String, String)),
) -> extension_hosts.Coordinates {
  hook_coordinates_at(
    settings.workspace,
    base_policy,
    settings.demand,
    environment,
    seed,
    clock,
  )
}

/// `hook_coordinates` over the plain values it reads from `Settings`.
///
/// An executor builds hook coordinates for a scope it has no `Settings` for,
/// so the builder takes the workspace, the assembled base policy, the
/// enforcement demand and the environment directly. `hook_coordinates` is this
/// function with the session's settings read out.
///
/// ## Examples
///
/// ```gleam
/// // serve.hook_coordinates_at(workspace, base, demand, env, seed, clock)
/// ```
///
pub fn hook_coordinates_at(
  workspace: String,
  base_policy: policy.SandboxPolicy,
  demand: exec.EnforcementDemand,
  environment: List(#(String, String)),
  seed: Int,
  clock: Clock,
) -> extension_hosts.Coordinates {
  let #(op_id, _generator) = ids.mint_op(ids.generator(clock, seed:))
  extension_hosts.Coordinates(
    // What makes this operation attribution-only also makes it the
    // wrong owner for a background job: nobody sees it as a running
    // step, so nobody can abort it. `dispatch.bridge` reads this and
    // serves a hook a workspace with no jobs plane.
    origin: extension_hosts.HookEvent,
    op_id:,
    step_id: hook_step_id,
    // Attribution only: `hosts.Coordinates.strand` names the workspace
    // seam's reads, and a hook's are the session's rather than any one
    // strand's. The session's root strand is the honest name for that.
    strand: root_strand,
    workspace:,
    base_policy:,
    demand:,
    env: environment,
  )
}

/// The strand a hook's harness-side reads are attributed to.
///
/// Defined in `client/advisor` rather than here because that module
/// needs the same name — it is the strand the advisor reviews — and it
/// cannot import this one without a cycle.
const root_strand = advisor.primary

/// The step every hook invocation clears under. One name, because the
/// hooks of a session are one long-running step rather than a sequence of
/// them, and the pooled budget follows the pair.
const hook_step_id = "extension-hooks"

/// Slack over an invocation's own deadline before a caller gives up on the
/// satellite registry.
///
/// Derived rather than picked. The registry performs the invocation on
/// its own timeline and `codemode/satellite.invoke` waits fifteen seconds
/// past the invocation's deadline before it gives up on a wedged host, so
/// a caller that gave up sooner would report a wedged registry for an
/// invocation that was merely being timed out properly. Five seconds on
/// top is this actor's own answer travelling.
///
/// It is deliberately *not* large enough to hide an extension's first
/// use, which launches a jailed node before the invocation begins:
/// `hosts.seam` states that bound as `deadline + margin + one launch`
/// rather than absorbing it, because a margin that hid a launch would
/// also hide a wedged registry for the same number of seconds on every
/// later call.
const extension_host_margin_ms = 20_000

/// How many restarts the service supervisor allows within
/// `service_restart_period` seconds before it gives up and the host
/// treats the composition layer as fatal. Three is loose enough to ride
/// out a transient — a hub that crashed decoding one bad frame — and
/// tight enough that a deterministic fault surfaces as a dead server
/// with a released lease rather than a restart storm.
pub const service_restart_intensity = 3

/// The window `service_restart_intensity` is counted over, in seconds.
pub const service_restart_period = 5

/// How long the service supervisor is given to stop before it is
/// killed. Its children are plain actors that die on the shutdown
/// signal at once, so this is headroom, not an expected wait.
pub const service_grace_ms = 5000

// Stops the service supervisor the way OTP stops one: children
// terminated in reverse start order with reason `shutdown`. A
// supervisor that will not answer, or outruns its grace, is killed —
// the next act is releasing the writer lease, and nothing may hold that
// up.

/// Establishes stop services for the caller, keeping its validation and result policy at this boundary.
fn stop_services(services: Pid) -> Nil {
  // Decide how to handle process.is_alive(services) {.
  case process.is_alive(services) {
    False -> Nil
    True -> {
      // Decide how to handle ffi_os.terminate_supervisor(services, service_grace_ms) {.
      case ffi_os.terminate_supervisor(services, service_grace_ms) {
        Ok(Nil) -> Nil
        Error(Nil) -> process.kill(services)
      }

      await_death(services, service_grace_ms)
    }
  }
}

// A foreground poll on liveness, bounded by the grace: nothing may hold up
// releasing the writer lease, so a supervisor still alive when the grace
// runs out is killed rather than waited for any longer.

/// Establishes await death for the caller, keeping its validation and result policy at this boundary.
fn await_death(pid: Pid, remaining_ms: Int) -> Nil {
  let outcome: poll.Outcome(Nil, Nil) =
    poll.until(within: remaining_ms, every: 5, attempt: fn() {
      case process.is_alive(pid) {
        False -> poll.Done(Nil)
        True -> poll.Retry
      }
    })

  // Decide how to handle outcome {.
  case outcome {
    poll.Answered(Nil) -> Nil
    poll.Expired -> process.kill(pid)

    // The probe never fails outright; the arm is exhaustiveness.
    poll.Failed(Nil) -> Nil
  }
}

// The index file beside this session's, as an absolute path.
//
// Absolute is not cosmetic: the path goes into `base_policy.protected`,
// and a relative protected entry is refused by the jail and covers
// nothing in the harness's own path checks — `base_policy_fault` would
// turn `--session loom.db` into a boot failure. So a session path with
// no directory of its own is resolved against the working directory,
// which is the directory it would have been created in anyway.
fn index_path(settings: Settings) -> Result(String, String) {
  beside_session(settings, history.index_file)
}

// The absolute path of `file` beside this session's own, for the reason
// `index_path` gives: every one of these joins `base_policy.protected`,
// and a relative protected entry is refused by the jail and covers
// nothing in the harness's own path checks.

/// Establishes beside session for the caller, keeping its validation and result policy at this boundary.
fn beside_session(settings: Settings, file: String) -> Result(String, String) {
  case settings.domain_paths, file {
    Some(paths), file if file == memory.memory_file -> Ok(paths.memory)
    Some(paths), file if file == history.index_file -> Ok(paths.index)
    Some(paths), other ->
      Ok(filepath.directory_name(paths.memory) <> "/" <> other)
    None, file -> beside_session_file(settings, file)
  }
}

/// Establishes beside session file for the caller, keeping its validation and result policy at this boundary.
fn beside_session_file(
  settings: Settings,
  file: String,
) -> Result(String, String) {
  let directory = workspace_policy.parent_directory(settings.session_path)

  // Decide how to handle let path =  directory {.
  let path = case directory {
    Some(directory) -> directory <> "/" <> file
    None -> file
  }

  // Decide how to handle string.starts_with(path, "/") {.
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(here) { here <> "/" <> path })
      |> result.map_error(fn(error) {
        "the working directory is unreadable, so "
        <> file
        <> " has no absolute path: "
        <> string.inspect(error)
      })
  }
}

/// Where this session keeps its content-addressed blobs: an absolute
/// directory named `blobs` in the session's own state directory, never in
/// the workspace.
///
/// Under the daemon the state directory is the session's domain
/// (`resolve_managed`): `<state root>/workspaces/<digest of the canonical
/// workspace path>` for a workspace-private domain, so every session on a
/// workspace shares one store and no other workspace can resolve its ids,
/// or `<state root>/domains/sessions/<id>` for a session-only domain. Both
/// sit under entries `state_root_mask_candidates` names, so no jail can
/// read or write the store, and the base policy needs no entry for it. A
/// host with no domain (`domain_paths` is `None`) keeps it beside the
/// session file, like its memory and index.
///
/// The one function computes the root for every reader (the tool context,
/// code-mode `report.emit`, the jobs spill), so they cannot name different
/// stores. The store used to be `<workspace>/.blobs`, which had to be
/// masked from every jail: on macOS the mask made the directory
/// unreachable, so `ls` in the workspace exited 1 and `git status` warned,
/// and on Linux it left an empty mount in the user's checkout.
///
/// ## Examples
///
/// ```gleam
/// // With domain paths under "/state/workspaces/ab12":
/// // serve.session_blob_root(settings) == Ok("/state/workspaces/ab12/blobs")
/// ```
///
pub fn session_blob_root(settings: Settings) -> Result(String, String) {
  beside_session(settings, codemode_wiring.blob_directory)
}

/// The base policy with a standalone host's blob store protected where a
/// jail could write it.
///
/// Under the daemon the store sits in the state root, whose masks already
/// keep every jail out, and this adds nothing. A host with no domain keeps
/// the store beside its session file, outside any state root, so it takes
/// `workspace_policy.protecting_blobs`, which says why the entry is
/// unconditional.
///
/// If the session file sits inside the workspace, the store is protected
/// there too, with the cost the daemon avoids by keeping it out: a jail
/// cannot reach `<workspace>/blobs`, so `ls` reports it on macOS. That shape
/// is a test fixture's, not the daemon's, and
/// `workspace_policy.prepare_directories` still writes the ignore file into
/// the directory.
///
/// ## Examples
///
/// ```gleam
/// // serve.protecting_standalone_blobs(base, settings, "/s/blobs").protected
/// ```
///
@internal
pub fn protecting_standalone_blobs(
  base: policy.SandboxPolicy,
  settings: Settings,
  blob_root: String,
) -> policy.SandboxPolicy {
  case settings.domain_paths {
    Some(_) -> base
    None -> workspace_policy.protecting_blobs(base, blob_root)
  }
}

// The recall seam, or nothing and one line saying why.
//
// An index that will not open is not a boot failure: recall is a
// convenience over a rebuildable projection, and a session that cannot
// search its own past is still a session. The line is part of the
// mechanism rather than decoration — the same posture
// `codemode.unavailable` takes — because an absent tool is otherwise
// indistinguishable from a host that never had one.

/// Establishes history seam for the caller, keeping its validation and result policy at this boundary.
fn history_seam(
  index_path: String,
  name: address.Address(history.Message),
  logger: Logger,
) -> Option(history_tool.History) {
  // Decide how to handle history.probe(index_path) {.
  case history.probe(index_path) {
    Ok(Nil) -> {
      log.info(logger, "history.ready", [
        field.text(key: "index", value: index_path),
      ])
      Some(history.seam_with_logger(
        name,
        timeout_ms: history.default_timeout_ms,
        logger:,
      ))
    }
    Error(reason) -> {
      log.warn(logger, "history.unavailable", [
        field.text(key: "index", value: index_path),
        field.text(key: "reason", value: reason),
        field.text(
          key: "effect",
          value: "no history_search tool is registered; check the directory "
            <> "beside the session file is writable, or remove a corrupt "
            <> "index file and it will be rebuilt",
        ),
      ])
      None
    }
  }
}

// The memory door, or nothing and one line saying why.
//
// The same posture `history_seam` and `codemode.unavailable` take, for
// the same arithmetic: a tool definition renders into the provider's
// cached byte prefix and is paid for on every request for the life of
// the session, so a door that could only ever refuse must not be
// registered. The probe takes no lease and creates nothing (see
// `memory.probe`), so a boot never contends with a `remember` write.
//
// A reachable store also has its notes index brought up to date here, so the
// first run of a session already carries notes written before the index
// existed.

/// Establishes memory seam for the caller, keeping its validation and result policy at this boundary.
fn memory_seam(
  store_path: String,
  notes_path: String,
  inject: memory_config.Injection,
  clock: Clock,
  entropy: fn() -> Int,
  logger: Logger,
) -> Option(remember.Memory) {
  // Decide how to handle memory.probe(store_path) {.
  case memory.probe(store_path) {
    Ok(Nil) -> {
      log.info(logger, "memory.ready", [
        field.text(key: "store", value: store_path),
      ])
      refresh_notes_index(
        inject,
        store_path,
        notes_path,
        clock,
        entropy,
        logger,
      )
      Some(memory.remember_seam(store_path, clock:, entropy:, logger:))
    }
    Error(reason) -> {
      log.warn(logger, "memory.unavailable", [
        field.text(key: "store", value: store_path),
        field.text(key: "reason", value: reason),
        field.text(
          key: "effect",
          value: "no remember tool is registered; check the directory beside "
            <> "the session file is writable, or remove a corrupt "
            <> "loom-memory.db and it will be recreated",
        ),
      ])
      None
    }
  }
}

// The writer subscribers the index needs, which is one when there is an
// index and none when there is not.

/// Establishes history subscribers for the caller, keeping its validation and result policy at this boundary.
fn history_subscribers(
  seam: Option(history_tool.History),
  pulls: address.Address(writer.Event),
) -> List(writer.Subscriber) {
  case seam {
    None -> []
    Some(_seam) -> [writer.Routed(pulls)]
  }
}

// The holder and its commit subscriber, added to the service tree only
// when this host has an index for them to serve.

/// Establishes with instance history for the caller, keeping its validation and result policy at this boundary.
fn with_instance_history(tree, services, seam, config: history.Config, pulls) {
  case services {
    None -> with_history(tree, seam, config, pulls)
    Some(services) ->
      case domain_service.history(services) {
        None -> tree
        Some(shared) ->
          sup.add(
            tree,
            history.supervised_shared_commit_pull(
              shared,
              config.session,
              as_name: pulls,
            ),
          )
      }
  }
}

/// Establishes with history for the caller, keeping its validation and result policy at this boundary.
fn with_history(
  tree: sup.Builder,
  seam: Option(history_tool.History),
  config: history.Config,
  pulls: address.Address(writer.Event),
) -> sup.Builder {
  case seam {
    None -> tree
    Some(_seam) ->
      tree
      |> sup.add(history.supervised(config))
      |> sup.add(history.supervised_commit_pull(to: config.name, as_name: pulls))
  }
}

// --- the system prompt -----------------------------------------------------

// Renders the prompt for a session that has none pinned yet. Everything
// expensive lives behind this thunk — the pack file, the instruction files,
// and the helper spawn the degraded question needs — so a resumed session
// pays for none of it.
//
// The instruction files come from two places, and the order is the one the
// single lookup always produced. The operator's global `AGENTS.md` is read
// here, on the owner, from `Settings` rather than the process environment, so
// the lookup is a function of its arguments and a test can stand a server up
// that never reads the machine's real home. The workspace's own files are the
// workspace's to read: they arrive from the plane as text, with the helper's
// health, the platform and the shell it learned on its own machine.

/// Establishes render prompt for the caller, keeping its validation and result policy at this boundary.
fn render_prompt(
  settings: Settings,
  plane: workspace_plane.WorkspacePlane,
  rules_path: String,
  tools: List(String),
  available_tools: List(String),
) -> Result(system_prompt.Rendered, String) {
  use facts <- result.try(plane.prompt_facts())
  let census = plane.census
  let #(standing, standing_notes) = system_prompt.discover_user(settings.home)

  // The approved-rules file is read here, on the owner, because it is the
  // owner's file, and it goes last: it follows the operator's and the
  // project's files so that nothing a person approved can displace them.
  let #(approved, approved_notes) = proposals.guidance(rules_path)
  let #(guidance, notes) =
    system_prompt.render_guidance(
      list.flatten([
        option.values([standing]),
        facts.guidance,
        option.values([approved]),
      ]),
      list.flatten([standing_notes, facts.guidance_notes, approved_notes]),
    )
  use #(origin, source) <- result.try(
    system_prompt.pack_source(
      option.from_result(workspace_policy.env_text(
        system_prompt.pack_path_variable,
      )),
    ),
  )
  use rendered <- result.try(system_prompt.render_pack(
    origin,
    source,
    system_prompt.Host(
      workspace: census.workspace,
      platform: census.platform,
      shell: census.shell,
      tools:,
      available_tools:,
      demand: settings.demand,
      degraded: case facts.helper {
        workspace_plane.Degraded -> True
        workspace_plane.Healthy -> False
      },
      base_policy: census.base_policy,
      guidance:,
    ),
  ))
  Ok(
    system_prompt.Rendered(
      ..rendered,
      warnings: list.append(notes, rendered.warnings),
    ),
  )
}

// How this session runs the operator's goal check.
//
// The seven fields are the jobs wiring's, for the same reason: the broker
// seam is `tools/tool.broker_runner`, the closure the `bash` tool clears
// through, so a check admits under exactly the rules a model-authored
// command does. What differs is only the operation it is attributed to — an
// attribution-only one of its own, minted here the way a hook's is, so
// nothing can abort a check out from under the loop — and the step, which is
// its own name so the pooled execution budget is not shared with the hooks'.
//
// The wall is `client/goalloop`'s constant, and the same number reaches the
// process's own limit and the durable `Checking` deadline, so a restarted
// actor cannot be waiting on a process the sandbox has already killed.
//
// Two clocks come in because they answer different questions. The operation
// id is minted on the session's clock, like every other id this session mints,
// so ids made on one machine order by one timebase. The runner's clock is the
// one `call_clock` names: it builds the absolute deadline a check puts in a
// `CallSpec`, which the broker compares with its own clock, and for a
// workspace on an executor that is the executor's.

/// Establishes goal check wiring for the caller, keeping its validation and result policy at this boundary.
fn goal_check_wiring(
  settings: Settings,
  plane: workspace_plane.WorkspacePlane,
  session_clock: Clock,
  call_clock: Clock,
  seed: Int,
) -> goalcheck.Wiring {
  let #(op_id, _generator) = ids.mint_op(ids.generator(session_clock, seed:))
  let census = plane.census

  goalcheck.wiring(
    goalcheck.Runner(
      clear_call: tool.broker_runner(
        broker: plane.broker,
        waiting: workspace_plane.jobs_clearance_ms,
      ),
      base_policy: census.base_policy,
      demand: settings.demand,
      env: census.env,
      workspace: census.workspace,
      clock: call_clock,
      op_id:,
      clearance_ms: workspace_plane.jobs_clearance_ms,
    ),
    timeout_ms: goalloop.check_timeout_ms,
  )
}

// How this session reaches its schedule store, or `None` when the
// operator shut the door — which registers none of the three tools and
// routes none of the three capabilities, rather than offering doors that
// always refuse. A tool definition is not free: it renders into the
// provider's cached byte prefix and is paid for on every request, which
// is the same argument `memory_seam` and `history_seam` are gated by,
// and an unrouted capability is a clearer answer to a program than one
// that exists and says no.

/// Establishes schedule wiring for the caller, keeping its validation and result policy at this boundary.
fn schedule_wiring(
  settings: Settings,
  agency_config: agency.Config,
  scanner: address.Address(schedulescan.Message),
) -> Option(scheduleseam.Wiring) {
  case schedule.policy_opens_the_door(settings.schedule_policy) {
    False -> None
    True ->
      Some(scheduleseam.Wiring(
        runtime: fn() { agency.borrow_runtime(agency_config) },
        policy: settings.schedule_policy,
        operator_schedules: settings.schedules,
        scanner:,
      ))
  }
}

// The operator's scheduling door, applied only when this session has a
// scheduling plane at all. `Option.map` over the options would answer an
// `Option(Options)` the pipeline above would have to unwrap, which is the
// shape this small function exists to keep out of it — the same reason
// `schedule_reaping` below is a function rather than a `case` inline.

/// Establishes with schedule admin for the caller, keeping its validation and result policy at this boundary.
fn with_schedule_admin(
  options: hub.Options,
  admin: Option(scheduleadmin.Admin),
) -> hub.Options {
  case admin {
    None -> options
    Some(admin) -> hub.with_schedules(options, admin)
  }
}

// Installs the memory hook the operator chose: the notes index by default,
// or nothing. The sidecar and store stay protected from jailed writes either
// way, because that protection does not depend on anything reading them.
// The notes index is a projection of the store that a `remember` call
// rewrites, so a note written before the index existed, or by a release that
// did not maintain it, would stay out of every prompt until the next note. A
// session open rebuilds it while holding the same writer lease through its
// publication. A held lease or failure leaves the previous sidecar in place
// and costs a warning, never the open.

/// Establishes refresh notes index for the caller, keeping its validation and result policy at this boundary.
fn refresh_notes_index(
  inject: memory_config.Injection,
  store_path: String,
  notes_path: String,
  clock: Clock,
  entropy: fn() -> Int,
  logger: Logger,
) -> Nil {
  case inject {
    memory_config.InjectsNothing -> Nil
    memory_config.InjectsNotes ->
      case
        memory.rebuild_notes_index(
          store_path,
          notes_path,
          clock:,
          generator: ids.generator(clock, seed: entropy()),
        )
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warn(logger, "memory.notes_index_unrefreshed", [
            field.text(key: "index", value: notes_path),
            field.text(key: "reason", value: reason),
            field.text(
              key: "effect",
              value: "runs keep the previous notes index until the next note "
                <> "rebuilds it",
            ),
          ])
      }
  }
}

/// Establishes with memory context for the caller, keeping its validation and result policy at this boundary.
fn with_memory_context(
  hooks: effects.Hooks,
  inject: memory_config.Injection,
  read_notes: fn() -> Option(String),
  clock: Clock,
) -> effects.Hooks {
  case inject {
    memory_config.InjectsNothing -> hooks
    memory_config.InjectsNotes -> memory.notes_hooks(hooks, read_notes, clock)
  }
}

// The advisor's hooks, added to a hook record only when this session
// routes an advisor at all. A function rather than a `case` inline for
// the reason `schedule_reaping` below is one: `option.map` would answer
// an `Option(Hooks)` that the composition pipeline would then have to
// unwrap back to the hooks it started with.

/// Establishes with advisor for the caller, keeping its validation and result policy at this boundary.
fn with_advisor(
  hooks: effects.Hooks,
  wiring: Option(advisor.Wiring),
) -> effects.Hooks {
  case wiring {
    None -> hooks
    Some(wiring) -> advisor.hooks(hooks, wiring)
  }
}

// The gateway's goal-abort seam, filled only when this session wires
// an advisor — the same posture `with_advisor` takes, because a host
// with no advisor has no goal loop to notify and the seam's `None` is
// what makes the gateway skip the cast entirely.

/// Establishes with goal abort for the caller, keeping its validation and result policy at this boundary.
fn with_goal_abort(
  options: hub.Options,
  wiring: Option(advisor.Wiring),
) -> hub.Options {
  case wiring {
    None -> options
    Some(wiring) -> hub.with_goal_abort(options, advisor.abort_notice(wiring))
  }
}

// The gateway's goal command seam, on the same posture `with_goal_abort`
// takes and for the same reason: the actor that answers these calls
// exists only where an advisor is routed, and the seam's `None` is what
// makes the gateway refuse the commands in words rather than send them
// to an address nobody holds.

/// Establishes with goal control for the caller, keeping its validation and result policy at this boundary.
fn with_goal_control(
  options: hub.Options,
  wiring: Option(advisor.Wiring),
) -> hub.Options {
  case wiring {
    None -> options
    Some(wiring) -> hub.with_goal_control(options, goalcommand.seam(wiring))
  }
}

// The glance loop's wiring, or `None` when the catalogue routes no model
// the summarizer could fall back to. That case is logged once here rather
// than failing the boot: a session with no glance runs exactly as it did
// before glances existed.

/// Establishes glance wiring for the caller, keeping its validation and result policy at this boundary.
fn glance_wiring(
  settings: Settings,
  opened: session.Session,
  agency_config: agency.Config,
  clock: Clock,
  logger: Logger,
  name: address.Address(glance.Message),
) -> Option(glance.Wiring) {
  case glance.summarizer(settings.gateway) {
    Error(reason) -> {
      log.warn(logger, "glance.unavailable", [
        field.text(key: "reason", value: reason),
      ])
      None
    }

    // Borrowed through the Agency's holder rather than held, for the
    // reason the advisor's wiring borrows: the runtime contains the hook
    // this loop is composed into.
    Ok(summarizer) ->
      Some(glance.Wiring(
        session: opened,
        runtime: fn() { agency.borrow_runtime(agency_config) },
        summarizer:,
        clock:,
        pace: glancepace.default_pace,
        logger:,
        name:,
      ))
  }
}

// The block summarizer's route, or `None` when the catalogue routes no
// `summarize` model. That case is logged at debug level rather than warned:
// routing a summarizer is how an operator opts into the spend, and a
// session without one is working as configured.

/// Establishes summary route for the caller, keeping its validation and result policy at this boundary.
fn summary_route(
  settings: Settings,
  logger: Logger,
) -> Option(blocksummary.Route) {
  // Decide how to handle blocksummary.route(settings.gateway) {.
  case blocksummary.route(settings.gateway) {
    Ok(route) -> Some(route)
    Error(reason) -> {
      log.debug(logger, "block_summary.unavailable", [
        field.text(key: "reason", value: reason),
      ])
      None
    }
  }
}

// Both observers share the effective dispatch and terminal event ordering.

/// Establishes side and summary tap for the caller, keeping its validation and result policy at this boundary.
fn side_and_summary_tap(name, opened, build, summaries) {
  let side = btw.observer(name, opened, build)
  fn(spec, generation) {
    let observe_side = side(spec, generation)
    let observe_summary = summaries(spec, generation)
    fn(event) {
      observe_side(event)
      observe_summary(event)
    }
  }
}

// The live feed's observer, or one that observes nothing when no route
// exists. Which strand identities it observes is decided once here, from
// the catalogue's chains: only an identity every one of whose possible
// answering targets shares the summarize entry's endpoint, which is the
// confidentiality check for text still streaming.

/// Establishes summary tap for the caller, keeping its validation and result policy at this boundary.
fn summary_tap(
  route: Option(blocksummary.Route),
  catalogue: catalog.Catalog,
  name: address.Address(blocksummary.Message),
  config: wiring.Config,
) -> fn(effects.RequestSpec, String) -> fn(stream.StreamEvent) -> Nil {
  // This observer is copied with both provider entry points and every runtime
  // owner. Its classification capability owns only the session, rather than
  // the executable registry held by the provider and tool dispatch configuration.
  let image_bearing = wiring.request_image_classifier(config)

  // Decide how to handle route {.
  case route {
    Some(route) ->
      blocksummary.observer(
        name,
        // The dispatcher's own rule, so the observer and the dispatch agree
        // about which requests go to the `vision` chain.
        fn(operation, context) {
          case image_bearing(operation, context) {
            True -> blocksummary.ImageTurn
            False -> blocksummary.TextTurn
          }
        },
        blocksummary.live_admission(catalogue, route.provider),
      )
    None -> fn(_spec, _generation) { fn(_event) { Nil } }
  }
}

// The reader of remote children's transcript pages, when the session can reach
// other orchestrators at all (protocol-change/090). A session with no reach has
// no remote child, and its gateway answers `child_history` as unavailable.

/// Establishes with child history for the caller, keeping its validation and result policy at this boundary.
fn with_child_history(
  options: hub.Options,
  reach: Option(remote_reach.Reach),
  runtime: api.Runtime,
) -> hub.Options {
  case reach {
    Some(reach) ->
      hub.with_child_history(
        options,
        remote_child.history_reader(runtime, reach),
      )
    None -> options
  }
}

// The report of the session's first prompt, when the host listens for one.

/// Establishes with first prompt for the caller, keeping its validation and result policy at this boundary.
fn with_first_prompt(
  options: hub.Options,
  report: Option(fn(String) -> Nil),
) -> hub.Options {
  case report {
    Some(report) -> hub.with_first_prompt(options, report)
    None -> options
  }
}

// Drops the session's remembered grants that came through its spawner and that
// the spawner's ceiling, as the configuration now reads, does not admit. A
// spawner whose table has no ceiling admits nothing, so every such grant goes.
// A failure is logged and leaves the grants where they are for the next open to
// try again: the ceiling is a bound on an honest spawner, and one open's delay
// does not change that.

/// Establishes withdraw outside the ceiling for the caller, keeping its validation and result policy at this boundary.
fn withdraw_outside_the_ceiling(
  settings: Settings,
  runtime: api.Runtime,
  logger: Logger,
) -> Nil {
  // Decide how to handle settings.spawner {.
  case settings.spawner {
    None -> Nil
    Some(link) -> {
      // Decide how to handle let admits =  link.ceiling {.
      let admits = case link.ceiling {
        Some(ceiling) -> approval_ceiling.admits(ceiling, _)
        None -> fn(_grant) { False }
      }

      // Decide how to handle permissions.withdraw_spawner_grants(runtime, link.spawner, admits) {.
      case permissions.withdraw_spawner_grants(runtime, link.spawner, admits) {
        Ok([]) -> Nil
        Ok(withdrawn) ->
          log.warn(logger, "serve.spawner_grants_withdrawn", [
            field.count("grants", list.length(withdrawn)),
            field.text("spawner", link.spawner),
          ])
        Error(reason) ->
          log.warn(logger, "serve.spawner_grants_kept", [
            field.text("reason", reason),
          ])
      }
    }
  }
}

// Files the row that sends a request on to the spawner's operator, and rings the
// delegate drainer. It runs on the parked call's own process, and a failure
// costs the spawner's operator the question and nothing else: the record stands,
// and the box's owner can still answer it.

/// Establishes announce to spawner for the caller, keeping its validation and result policy at this boundary.
fn announce_to_spawner(
  spawner: Option(delegate_outbox.SpawnerLink),
  runtime: api.Runtime,
  id: String,
  until: Int,
  drain: address.Address(peer_outbox_drain.Message),
  logger: Logger,
) -> Nil {
  case spawner {
    Some(delegate_outbox.SpawnerLink(ceiling: Some(_), ..)) ->
      case delegate_outbox.announce(runtime, id, until:) {
        Ok(Nil) -> peer_outbox_drain.ring(drain)
        Error(reason) ->
          log.warn(logger, "serve.announce_unsent", [
            field.text("reason", reason),
          ])
      }
    _ -> Nil
  }
}

// A delegate session's hub takes a spawner's operator's decisions when it knows
// the spawner's link.

/// Establishes with spawner link for the caller, keeping its validation and result policy at this boundary.
fn with_spawner_link(
  options: hub.Options,
  link: Option(delegate_outbox.SpawnerLink),
) -> hub.Options {
  case link {
    Some(link) -> hub.with_spawner(options, link)
    None -> options
  }
}

// The daemon's door for the session's model profile, when it supplied one.

/// Establishes with profile desk for the caller, keeping its validation and result policy at this boundary.
fn with_profile_desk(
  options: hub.Options,
  desk: Option(profile_switch.Desk),
) -> hub.Options {
  case desk {
    Some(desk) -> hub.with_profile_desk(options, desk)
    None -> options
  }
}

// A terminal's read of a block with no stored summary asks the summarizer
// for one, when the session has a summarizer at all.

/// Establishes with summary demand for the caller, keeping its validation and result policy at this boundary.
fn with_summary_demand(
  options: hub.Options,
  route: Option(blocksummary.Route),
  name: address.Address(blocksummary.Message),
) -> hub.Options {
  case route {
    Some(_route) ->
      hub.with_summary_demand(options, blocksummary.ask_for(name, _))
    None -> options
  }
}

/// Establishes with block summarizer for the caller, keeping its validation and result policy at this boundary.
fn with_block_summarizer(
  builder: sup.Builder,
  route: Option(blocksummary.Route),
  catalogue: catalog.Catalog,
  opened: session.Session,
  runtime: api.Runtime,
  event_bus: bus.Bus,
  logger: Logger,
  name: address.Address(blocksummary.Message),
  commits: address.Address(writer.Event),
) -> sup.Builder {
  // Decide how to handle route {.
  case route {
    None -> builder
    Some(route) -> {
      // Keyed by the canonical session id, the key the hub's `Outputs`
      // subscription joins under; a label published under any other key
      // reaches no terminal.
      let key = bus.key(of: api.session_id(runtime))
      let wiring =
        blocksummary.Wiring(
          session: opened,
          route:,
          settled: blocksummary.settled_admission(catalogue, route.provider),
          write: fn(cell, value) {
            api.put_reserved_fact(runtime, cell, value)
            |> result.map_error(string.inspect)
          },
          publish: fn(event) { bus.publish(event_bus, session: key, event:) },
          pace: blocksummarybook.default_pace,
          logger: log.scoped(
            logger,
            context.for_session(
              ids.session_id_to_string(api.session_id(runtime)),
            ),
          ),
          name:,
          commits:,
        )
      sup.add(builder, blocksummary.supervised(wiring))
    }
  }
}

/// Establishes with glance for the caller, keeping its validation and result policy at this boundary.
fn with_glance(
  hooks: effects.Hooks,
  wiring: Option(glance.Wiring),
) -> effects.Hooks {
  case wiring {
    None -> hooks
    Some(wiring) -> glance.hooks(hooks, wiring.name)
  }
}

/// Establishes with metering for the caller, keeping its validation and result policy at this boundary.
fn with_metering(
  hooks: effects.Hooks,
  config: agency.Config,
  metering: Option(agency.Metering),
) -> effects.Hooks {
  case metering {
    None -> hooks
    Some(metering) -> agency.metering_hooks(hooks, config, metering)
  }
}

/// Establishes with glance loop for the caller, keeping its validation and result policy at this boundary.
fn with_glance_loop(
  builder: sup.Builder,
  wiring: Option(glance.Wiring),
) -> sup.Builder {
  case wiring {
    None -> builder
    Some(wiring) -> sup.add(builder, glance.supervised(wiring))
  }
}

// The advisor actor, added to the service tier only when this session
// routes an advisor, on the posture `with_rule_scanner` takes: a plane
// nobody configured should cost a host a process of exactly nothing.

/// Establishes with advisor actor for the caller, keeping its validation and result policy at this boundary.
fn with_advisor_actor(
  builder: sup.Builder,
  wiring: Option(advisor.Wiring),
) -> sup.Builder {
  case wiring {
    None -> builder
    Some(wiring) -> sup.add(builder, advisor.supervised(wiring))
  }
}

// Seeds the advisor strand and says, in one line, either which model is
// reviewing with which tools or why nothing is.

/// Establishes seed advisor for the caller, keeping its validation and result policy at this boundary.
fn seed_advisor(
  runtime: api.Runtime,
  wiring: Option(advisor.Wiring),
  registry: tool.Registry,
  logger: Logger,
) -> Nil {
  case wiring {
    None -> Nil
    Some(wiring) -> announce_advisor(runtime, wiring, registry, logger)
  }
}

/// Establishes announce advisor for the caller, keeping its validation and result policy at this boundary.
fn announce_advisor(
  runtime: api.Runtime,
  wiring: advisor.Wiring,
  registry: tool.Registry,
  logger: Logger,
) -> Nil {
  let names = tool.names(registry)

  // Decide how to handle advisor.ensure_strand(runtime, wiring.settings, names) {.
  case advisor.ensure_strand(runtime, wiring.settings, names) {
    Error(reason) ->
      log.warn(logger, "advisor.unavailable", [
        field.text(key: "detail", value: reason),
      ])

    Ok(Nil) ->
      log.info(logger, "advisor.ready", [
        field.ident(key: "model", value: wiring.settings.model.model_id),
        field.text(
          key: "tools",
          value: string.join(advisor.active_tools(wiring.settings, names), ","),
        ),
      ])
  }
}

// The schedule reap, added to a hook record only when this session has a
// scheduling plane at all. `Option.map` would answer an `Option(Hooks)`
// and every caller would then have to unwrap it back to the hooks it
// started with, which is the shape this small function exists to keep out
// of the composition pipeline above.

/// Establishes schedule reaping for the caller, keeping its validation and result policy at this boundary.
fn schedule_reaping(
  hooks: effects.Hooks,
  wiring: Option(scheduleseam.Wiring),
) -> effects.Hooks {
  case wiring {
    None -> hooks
    Some(wiring) -> scheduleseam.reaping_hooks(hooks, wiring)
  }
}

/// Where a code-mode build seed lives by default, relative to the
/// workspace: exactly where `make codemode-seed` writes one in this repo,
/// so a development host that ran it is wired without a flag.
pub const default_seed_directory = "build/codemode-seed"

/// The build-seed ladder, as an order: `--codemode-seed`, then the
/// workspace's own, then the one a release ships, and `otherwise` when
/// nothing answers.
///
/// **The workspace outranks the bundle.** A checkout's seed is
/// regenerated by `make codemode-seed` against the tree being worked on,
/// so preferring it means a contributor who changed the compile service's
/// dependency table builds against their own seed rather than a frozen
/// one `seed.verify` would then reject — and a release, which has no
/// workspace seed, still reaches the rung below.
///
/// The flag is first for the same reason it is first in the helper
/// ladder: an operator naming a seed must not be quietly handed another.
///
/// `otherwise` is a choice about the *refusal* rather than a fallback
/// that can work. Nothing is at that path — that is why the ladder got
/// there — so what it decides is which path `seed.verify` names when it
/// says there is no seed, and naming somewhere a person can actually put
/// one beats naming a directory inside a release they may not have.
///
/// ## Examples
///
/// ```gleam
/// // serve.seed_ladder(None, in_workspace: .., bundled: .., otherwise: "…")
/// ```
///
pub fn seed_ladder(
  flag: Option(String),
  in_workspace in_workspace: fn() -> Result(String, Nil),
  bundled bundled: fn() -> Result(String, Nil),
  otherwise otherwise: String,
) -> String {
  install.first_of([
    fn() { option.to_result(flag, Nil) },
    in_workspace,
    bundled,
  ])
  |> result.unwrap(otherwise)
}

// The ladder run against this host.

/// Establishes seed root for the caller, keeping its validation and result policy at this boundary.
fn seed_root(flag: Option(String), workspace: String) -> String {
  let in_workspace = workspace <> "/" <> default_seed_directory
  seed_ladder(
    flag,
    in_workspace: fn() { usable_seed(in_workspace) },
    bundled: install.bundled_seed,
    otherwise: in_workspace,
  )
}

/// An existing workspace snapshot outranks the release only when it contains
/// the capabilities this host admits. Explicit flags still reach discovery
/// unchanged, where an invalid operator selection receives its own refusal.
///
/// The in-workspace rung of `seed_ladder` uses this on a local daemon and on
/// an executor, so a checkout with a half-built seed falls through to the
/// bundled one on both.
///
/// ## Examples
///
/// ```gleam
/// // serve.usable_seed("/no/such/seed") == Error(Nil)
/// ```
///
pub fn usable_seed(root: String) -> Result(String, Nil) {
  use Nil <- result.try(
    seed.verify(root, compile.default_dependencies())
    |> result.replace_error(Nil),
  )
  Ok(root)
}

// ---------------------------------------------------------------------------
// Governed evolution
//
// A session owns one evolution plane when code mode is available: a durable
// catalogue of candidates (`evolution_store`), the single owner process that
// stages and retires live generations (`evolution_live`), the queue that
// serialises operator-approved transitions (`evolution_queue`), and the model
// and operator doors over them. Everything below is assembly. The rules live
// in the modules it calls; this block decides only which directories exist,
// which effect plane a native check runs on, how a trial session is built
// from its source session's settings, and in what order the plane retires.
//
// The catalogue and the live owner are always this VM's, beside the session's
// own state, and are the same whichever machine compiles and runs candidates.
// A workspace with a local code-mode host uses the machine in this VM
// (`local_evolution_machine`). A workspace on an executor whose census says it
// compiles uses a machine that sends the work there
// (`evolution/machine/remote`), with no scratch directory here. A workspace
// with neither has no wiring, and with no wiring there is no door, no hook and
// no control seam.
// ---------------------------------------------------------------------------

// Evolution lives under one maskable directory, so future SQLite sidecars and
// immutable envelopes cannot appear after the session policy was captured.

/// Establishes evolution root for the caller, keeping its validation and result policy at this boundary.
fn evolution_root(settings: Settings) -> String {
  // Decide how to handle let state =  settings.codemode_sockets {.
  let state = case settings.codemode_sockets {
    Some(root) -> filepath.directory_name(root)
    None -> filepath.directory_name(settings.session_path)
  }

  state <> "/evolution"
}

// The artifact mask also covers hosts that keep cap sockets in the workspace.
// It exists before file-door capture so every native file door sees the same path.
fn evolution_scratch(settings: Settings) -> String {
  evolution_root(settings) <> "/run/" <> settings.session_id
}

// Trials live beside the protected catalogue. A fresh trial can grant its own
// workspace without removing the original catalogue's enclosing mask.
fn evolution_trials(settings: Settings) -> String {
  evolution_root(settings) <> "-trials"
}

// The directories this session's jail must mask. A trial names none, for two
// reasons. It binds under the source's socket root, and one of the source's
// directories encloses the trial's workspace; `evolution_trial_policy` already
// lifted that entry from the inherited mask list, and the trial's jail reads
// only its own workspace, so naming the entry again would shadow the workspace
// and refuse the trial's boot. And the trial's base policy still carries the
// source's protected `<state>/evolution` mask through `ctx.base_policy`, so the
// catalogue stays hidden from the trial even if a later step widens its reads.

/// Returns evolution masks according to the client contract.
@internal
pub fn evolution_masks(settings: Settings) -> List(String) {
  case settings.evolution_role {
    Trial(_) -> []

    Source -> evolution_directories(settings)
  }
}

/// The three directories in the order they are made and masked.
fn evolution_directories(settings: Settings) -> List(String) {
  [
    evolution_root(settings),
    evolution_scratch(settings),
    evolution_trials(settings),
  ]
}

/// What one session's assembly keeps of its evolution plane. Each field is
/// consumed at one place in `assemble_in`.
type EvolutionWiring {
  EvolutionWiring(
    /// Owns staged generations; recovered after the runtime opens and closed
    /// by `close_evolution`.
    live: evolution_live.Live,
    /// Serialises approved transitions; closed before `live`.
    transitions: evolution_queue.Queue,
    /// The name programs borrow the doors under; stopped before either owner
    /// closes, so a late call is refused at once.
    cell: address.Address(evolution_capability.Message),
    /// The operator commands the gateway exposes.
    control: evolution_control.Seam,
    /// Read when the session pins its prompt profiles at boot.
    catalogue: evolution_store.Store,
  )
}

// Which string names the workspace in the catalogue's scopes and in the
// operator's commands. A workspace in this VM keeps naming itself by the path
// every context carries, as it always has. A workspace on an executor is named
// `executor:<executor>/<name>`, because its registered name is only unique on
// the executor and two executors may register the same name for different
// checkouts; the same label scopes its program candidates.
type EvolutionScope {
  LocalScope
  ExecutorScope(label: String)
}

// The workspace a door call's candidates are scoped to.
/// Establishes the scope string a context's candidates are filed under.
fn scope_of_context(scope: EvolutionScope, ctx: tool.Ctx) -> String {
  case scope {
    LocalScope -> ctx.workspace
    ExecutorScope(label:) -> label
  }
}

// The workspace the operator's commands are scoped to.
/// Establishes the scope string the operator's commands act under.
fn scope_of_settings(scope: EvolutionScope, settings: Settings) -> String {
  case scope {
    LocalScope -> settings.workspace
    ExecutorScope(label:) -> label
  }
}

// The machine for a workspace in this VM: everything staging and evaluation
// need that does not change per call. Its `open` starts a fresh effect plane
// for each check, under the policy that check was granted. It holds no
// catalogue, so it exists before the catalogue is opened with the identity it
// reports, and every call that needs the catalogue is handed it.
//
// Candidates are vetted and run under the host with the evolution door
// withdrawn, so no selected program can import `cap/evolution`.

/// Establishes the evolution machine for a workspace started in this VM.
fn local_evolution_machine(
  settings: Settings,
  host: codemode_wiring.Config,
  base: policy.SandboxPolicy,
  agency_config: agency.Config,
  namespace: address.Registry,
  environment: List(#(String, String)),
  clock: Clock,
  logger: Logger,
) -> evolution_machine.Machine {
  let scratch = evolution_scratch(settings)

  // These callbacks outlive assembly and are copied with the machine. Keep
  // only their own coordinates, rather than the full startup settings.
  let secrets = settings.secrets
  let helper = settings.helper_path
  evolution_machine_local.new(
    evolution_machine_local.Config(
      host: codemode_wiring.without_evolution(host),
      base:,
      at: hook_coordinates(
        settings,
        base,
        workspace_plane.mixed_entropy()(),
        clock,
        environment,
      ),
      memory: extension_memory.for_session(agency_config),
      secrets: fn(name) { secret.lookup(secrets, name) },
      namespace:,
      scratch:,
      logger:,
      open: fn(policy) {
        evolution_machine_local.open_plane(helper, policy, scratch, clock)
      },
    ),
  )
}

// Opens the plane for a session that has an evolution machine. The catalogue
// is opened as owner once, here. Every model-facing call re-opens it as a
// caller scoped to that call's session and workspace, so a tool never acts
// with the owner's authority.
//
// The machine says where candidates are compiled and run, and `scope` says how
// the workspace is named. `scratch` is the directory this VM keeps for the
// machine's check and build output, or `None` for a machine that builds on
// another one.

/// Establishes open evolution for the caller, keeping its validation and result policy at this boundary.
fn open_evolution(
  settings: Settings,
  machine: evolution_machine.Machine,
  scope: EvolutionScope,
  scratch: Option(String),
  agency_config: agency.Config,
  clock: Clock,
  owner: Option(custody.Owner),
  name: address.Address(evolution_capability.Message),
) -> Result(EvolutionWiring, String) {
  let root = evolution_root(settings)

  // These callbacks outlive assembly and are copied with the door.
  // Keep only their own coordinates, rather than the full startup settings.
  let source_session = settings.session_id
  let gateway = settings.gateway
  let workspace = scope_of_settings(scope, settings)

  // Establish store authority, and make the scratch directory if the machine
  // keeps one on this VM.
  use identity <- result.try(machine.identity())
  let opener = fn(authority) {
    evolution_store.open(root, authority, identity, clock)
  }
  use catalogue <- result.try(
    opener(evolution_store.Owner) |> result.map_error(evolution_store.describe),
  )

  // A machine that builds on another one keeps nothing here to prepare.
  use Nil <- result.try(case scratch {
    Some(directory) -> bootstrap.ensure_private_directory(directory)
    None -> Ok(Nil)
  })

  // Start live evolution runtime and initialize transition queue.
  let adopt = fn(selection) { evolution_adopt(agency_config, selection) }
  use live <- result.try(
    evolution_live.start(
      evolution_live.Config(
        clock:,
        stage: fn(selection) { machine.stage(catalogue, selection) },
        adopt:,
        recover: fn() {
          evolution_recover(machine, catalogue, source_session, adopt)
        },
      ),
    )
    |> result.map_error(string.inspect),
  )

  // Subscribers learn of a change through the session's own key: the catalogue
  // is daemon-wide, but the live generation and the queue this board draws are
  // this session's. The key is the runtime's canonical session identity, which
  // the settings string need not be, so it is read from the runtime that owns
  // it. That read runs inside the transition queue's turn, where a stalled
  // holder must not crash the custodian of a live transition, so it is a
  // bounded `try_call` that gives up silently; a hint with no key has no one
  // to wake and the board's own refresh covers it.
  let announce = fn() {
    case agency.try_borrow_runtime(agency_config) {
      Ok(runtime) ->
        bus.publish(
          bus.start(),
          session: bus.key(of: api.session_id(runtime)),
          event: bus.EvolutionChanged,
        )
      Error(Nil) -> Nil
    }
  }
  use transitions <- result.try(evolution_queue.start_notifying(
    live,
    clock,
    announce,
  ))

  // A failed door call hands its refusal to `live` first, which retains any
  // cleanup authority the refusal carries, and only then words the error.
  let lookup = fn(ctx: tool.Ctx) {
    opener(evolution_store.Caller(source_session, scope_of_context(scope, ctx)))
  }
  let failed = fn(error) {
    evolution_live.retain(live, error)
    tool.failure(evolution_store.describe(error))
  }
  let source = fn(_ctx: tool.Ctx) {
    agency.borrow_runtime(agency_config)
    |> result.map(fn(runtime) { runtime.session })
    |> result.replace_error("the native session is unavailable")
  }
  let actual = fn(ctx: tool.Ctx) {
    evolution_actual_model(gateway, agency_config, ctx)
  }

  // Build the initial evolution door with candidate evaluation hooks.
  let initial =
    evolution.door_over_capture_model(
      lookup,
      fn(ctx: tool.Ctx) {
        evolution_record.Origin(
          source_session,
          ctx.strand,
          scope_of_context(scope, ctx),
          None,
        )
      },
      fn(ctx) { actual(ctx) |> result.map_error(evolution_store.Unavailable) },
      fn(ctx, directory) {
        evolution_live.snapshot(live, fn() { machine.snapshot(ctx, directory) })
        |> result.map_error(evolution_owned_refusal)
      },
      fn(ctx, catalogue, id, args) {
        evolution_live.evaluate(live, fn() {
          use candidate <- result.try(evolution_store.read_candidate(
            catalogue,
            id,
          ))

          // Decide how to handle candidate.kind {.
          case candidate.kind {
            evolution_record.Extension | evolution_record.Program ->
              machine.evaluate(catalogue, ctx, id)
              |> result.try(evolution_evaluate.record(catalogue, id, _))
            evolution_record.Prompt ->
              evolution_compare(
                settings,
                agency_config,
                catalogue,
                id,
                ctx,
                args,
              )
          }
        })
        |> result.map_error(evolution_owned_refusal)
      },
      fn(ctx, args) {
        case lookup(ctx) {
          Error(error) -> failed(error)
          Ok(visible) ->
            evolution_invoked(live, visible, machine, ctx, args, failed)
        }
      },
      failed,
    )
  let door =
    evolution_tool.Door(
      ..initial,
      catalogue: fn(ctx, args) {
        case lookup(ctx) {
          Error(error) -> failed(error)
          Ok(visible) -> evolution_catalogue(live, visible, args, failed)
        }
      },
      trace: evolution_model_door.trace_door(source, actual),
    )

  // The doors become reachable from programs only here, and custody is
  // registered in the same step, so the cell never exists without an owner
  // that stops it. Registering custody makes the owner's close stop the cell,
  // so a late program call reads "not open" at once instead of waiting for a
  // lease, and then retire the queue and the live owner. Its detach drops all
  // three without closing, so a host that exits early cannot leave a staged
  // generation unaccounted for. On the no-custody path nothing is detached and
  // the builder's own death takes them, with `close_evolution` as the orderly
  // close.
  use cell <- result.try(evolution_capability.start(name, door))
  use Nil <- result.try(
    retain(
      owner,
      custody.Evolution,
      fn() {
        evolution_capability.stop(name)
        use Nil <- result.try(evolution_queue.close(transitions))
        evolution_live.close(live, 120_000)
        |> result.map_error(evolution_store.describe)
      },
      fn() {
        evolution_capability.detach(cell)
        evolution_live.detach(live)
        evolution_queue.detach(transitions)
      },
    ),
  )

  Ok(EvolutionWiring(
    live:,
    transitions:,
    cell: name,
    catalogue:,
    control: evolution_control.announcing(
      evolution_operator_controls(
        agency_config,
        evolution_control.new(
          source_session,
          workspace,
          opener,
          live,
          transitions,
          clock,
        ),
      ),
      announce,
    ),
  ))
}

// Records that this session adopted a selection, as a write-once reserved
// fact keyed by name and generation. Repeating the same adoption (a recovery
// after a restart) is a no-op; a fact holding a different payload means the
// selection changed underneath the audit, which is `Changed`.

/// Establishes evolution adopt for the caller, keeping its validation and result policy at this boundary.
fn evolution_adopt(
  agency_config: agency.Config,
  selection: evolution_record.Selection,
) -> Result(Nil, evolution_store.Refusal) {
  use runtime <- result.try(
    agency.borrow_runtime(agency_config)
    |> result.replace_error(evolution_store.Unavailable(
      "runtime unavailable for adoption audit",
    )),
  )
  let key =
    "evolution/adoption/"
    <> selection.name
    <> "/"
    <> int.to_string(selection.generation)
  let payload =
    json.Object([
      #(
        "candidate_id",
        json.String(evolution_record.id_string(selection.candidate_id)),
      ),
      #(
        "evidence_id",
        json.String(evolution_record.evidence_string(selection.evidence_id)),
      ),
      #("generation", json.Int(selection.generation)),
    ])
  use cell <- result.try(
    api.fact_cell(runtime, key)
    |> result.map_error(fn(error) {
      evolution_store.Unavailable(string.inspect(error))
    }),
  )

  // Decide how to handle cell {.
  case cell {
    Some(cell) ->
      case cell.value == payload {
        True -> Ok(Nil)
        False -> Error(evolution_store.Changed)
      }
    None ->
      api.put_reserved_fact_expecting(runtime, key, payload, None)
      |> result.replace(Nil)
      |> result.map_error(fn(error) {
        evolution_store.Unavailable(string.inspect(error))
      })
  }
}

// Restages the session's selected extension after a restart. A session may
// hold at most one active promoted extension, so two distinct selections are a
// bounds refusal and not a choice. If the adoption audit fails after staging,
// the staged generation retires before the refusal is returned.

/// Establishes evolution recover for the caller, keeping its validation and result policy at this boundary.
fn evolution_recover(
  machine: evolution_machine.Machine,
  catalogue: evolution_store.Store,
  session_id: String,
  adopt: fn(evolution_record.Selection) -> Result(Nil, evolution_store.Refusal),
) -> Result(Option(evolution_live.Generation), evolution_store.Refusal) {
  use candidates <- result.try(evolution_store.catalogue(catalogue))
  let extensions =
    list.filter(candidates, fn(candidate) {
      candidate.kind == evolution_record.Extension
      && candidate.scope == evolution_record.Session(session_id)
    })
  use selections <- result.try(
    list.try_map(extensions, fn(candidate) {
      evolution_store.selected(catalogue, candidate.scope, candidate.name)
    }),
  )
  let selections =
    list.unique(
      list.filter_map(selections, fn(selection) {
        option.to_result(selection, Nil)
      }),
    )

  // Decide how to handle selections {.
  case selections {
    [] -> Ok(None)
    [selection] -> {
      use active <- result.try(machine.stage(catalogue, selection))

      // Decide how to handle adopt(selection) {.
      case adopt(selection) {
        Ok(Nil) -> Ok(Some(active))
        Error(error) -> {
          case evolution_retirement.perform(active.retire) {
            Ok(Nil) -> Error(error)
            Error(reason) ->
              Error(evolution_store.CleanupUnconfirmed(
                reason.reason,
                reason.retry,
              ))
          }
        }
      }
    }
    [_, _, ..] ->
      Error(evolution_store.Bounds("one active promoted extension per session"))
  }
}

// Runs one candidate tool. The model names the candidate, its generation and
// the tool, and the generation must match what is selected now: an extension
// is checked by `live` against its active generation, a program against the
// catalogue's current selection, and a prompt profile is never executable.

/// Establishes evolution invoked for the caller, keeping its validation and result policy at this boundary.
fn evolution_invoked(
  live: evolution_live.Live,
  catalogue: evolution_store.Store,
  machine: evolution_machine.Machine,
  ctx: tool.Ctx,
  args: json.JsonValue,
  failed: fn(evolution_store.Refusal) -> tool.ToolOutcome,
) -> tool.ToolOutcome {
  let parsed = fn() {
    use id <- result.try(
      tool.required_string(args, "candidate_id")
      |> result.map_error(evolution_store.Authority),
    )
    use candidate_id <- result.try(
      evolution_record.candidate_id(id)
      |> result.map_error(evolution_store.Authority),
    )
    use generation <- result.try(
      tool.optional_int(args, "generation")
      |> result.map_error(evolution_store.Authority),
    )
    use generation <- result.try(option.to_result(
      generation,
      evolution_store.Authority("generation required"),
    ))
    use name <- result.try(
      tool.required_string(args, "tool")
      |> result.map_error(evolution_store.Authority),
    )
    use arguments <- result.try(
      tool.optional_value(args, "arguments")
      |> result.map_error(evolution_store.Authority),
    )
    use arguments <- result.try(option.to_result(
      arguments,
      evolution_store.Authority("arguments required"),
    ))
    use candidate <- result.try(evolution_store.read_candidate(
      catalogue,
      candidate_id,
    ))
    Ok(#(id, generation, name, arguments, candidate))
  }

  // Decide how to handle parsed() {.
  case parsed() {
    Error(error) -> failed(error)
    Ok(#(id, generation, name, arguments, candidate)) ->
      case candidate.kind {
        evolution_record.Extension ->
          evolution_live.invoke(
            live,
            id,
            generation,
            name,
            ctx,
            arguments,
            120_000,
          )
        evolution_record.Program -> {
          case
            evolution_store.selected(catalogue, candidate.scope, candidate.name)
          {
            Ok(Some(selected))
              if selected.candidate_id == candidate.id
              && selected.generation == generation
              && name == candidate.name
            ->
              evolution_live.execute(live, name, ctx, arguments, fn() {
                machine.run_program(catalogue, selected, ctx, arguments)
              })
            Ok(None) | Ok(Some(_)) -> failed(evolution_store.Stale)
            Error(error) -> failed(error)
          }
        }
        evolution_record.Prompt ->
          failed(evolution_store.Authority(
            "prompt profiles are not executable tools",
          ))
      }
  }
}

// The model's catalogue page: every visible candidate, plus the callable
// schemas of the active extension generation and of each selected program.
// A refusal from the live owner may already hold cleanup authority, so it is
// worded through `evolution_owned_refusal`; the others carry none.

/// Establishes evolution catalogue for the caller, keeping its validation and result policy at this boundary.
fn evolution_catalogue(
  live: evolution_live.Live,
  catalogue: evolution_store.Store,
  args: json.JsonValue,
  failed: fn(evolution_store.Refusal) -> tool.ToolOutcome,
) -> tool.ToolOutcome {
  let paged = {
    use active <- result.try(
      evolution_live.catalogue(live)
      |> result.map_error(evolution_owned_refusal),
    )
    use programs <- result.try(evolution_program_catalogue(catalogue))
    use values <- result.try(evolution.catalogue_values(catalogue))
    evolution.catalogue_page(
      evolution.CatalogueValues(
        candidates: values.candidates,
        active: list.append(evolution_extension_entries(active), programs),
      ),
      args,
    )
  }

  // Decide how to handle paged {.
  case paged {
    Ok(value) -> tool.success(json.to_string(value))
    Error(error) -> failed(error)
  }
}

/// Establishes evolution extension entries for the caller, keeping its validation and result policy at this boundary.
fn evolution_extension_entries(
  active: Option(evolution_live.Generation),
) -> List(json.JsonValue) {
  case active {
    None -> []
    Some(active) ->
      list.map(active.tools, fn(declared) {
        json.Object([
          #(
            "candidate_id",
            json.String(evolution_record.id_string(
              active.selection.candidate_id,
            )),
          ),
          #("generation", json.Int(active.selection.generation)),
          #("name", json.String(declared.name)),
          #("description", json.String(declared.description)),
          #("schema", declared.schema),
        ])
      })
  }
}

/// Establishes with evolution control for the caller, keeping its validation and result policy at this boundary.
fn with_evolution_control(
  options: hub.Options,
  wiring: Option(EvolutionWiring),
  core: evolution_control.Seam,
) -> hub.Options {
  // Core release authority is available independently of authored candidates.
  // Retain only the two command capabilities in the gateway's service closure.
  let extensions = option.map(wiring, fn(wiring) { wiring.control })
  hub.with_evolution(
    options,
    evolution_control.Seam(command: fn(authority, principal, via, action, args) {
      case action {
        "core_status" | "core_upgrade" | "core_downgrade" ->
          core.command(authority, principal, via, action, args)
        _ ->
          case extensions {
            Some(control) ->
              control.command(authority, principal, via, action, args)
            None -> Error("runtime evolution is unavailable for this session")
          }
      }
    }),
  )
}

// The prompt profiles a session chose, in precedence order: a trial's
// `Trial(profiles)` role, the set pinned in the session file at an earlier boot,
// and otherwise the catalogue's current selections. Pinning means a reopened
// session keeps the profile it started with even after a later selection.
//
// `None` means the session has nothing to choose from: a Source role with no pin
// and no evolution wiring. It runs with no profile but chooses none, so the caller
// pins nothing and a later boot that has wiring chooses then. `Some([])` is a
// choice of no profiles: the session has wiring and nothing was selected when
// it started, and it keeps running without one after a later selection.

/// Establishes evolution profiles for the caller, keeping its validation and result policy at this boundary.
fn evolution_profiles(
  settings: Settings,
  opened: session.Session,
  wiring: Option(EvolutionWiring),
) -> Result(Option(List(evolution_profile.Profile)), String) {
  // Decide how to handle settings.evolution_role {.
  case settings.evolution_role {
    Trial(profiles) -> Ok(Some(profiles))
    Source -> {
      use pinned <- result.try(system_prompt.pinned_profiles_in(opened))

      // Decide how to handle pinned, wiring {.
      case pinned, wiring {
        Some(profiles), _ -> Ok(Some(profiles))
        None, None -> Ok(None)
        None, Some(wiring) ->
          evolution_selected_profiles(wiring)
          |> result.map(Some)
          |> result.map_error(fn(error) {
            evolution_live.retain(wiring.live, error)
            evolution_store.describe(error)
          })
      }
    }
  }
}

/// Establishes evolution selected profiles for the caller, keeping its validation and result policy at this boundary.
fn evolution_selected_profiles(
  wiring: EvolutionWiring,
) -> Result(List(evolution_profile.Profile), evolution_store.Refusal) {
  use candidates <- result.try(evolution_store.catalogue(wiring.catalogue))
  use profiles <- result.try(
    list.try_fold(candidates, [], fn(profiles, candidate) {
      // Decide how to handle candidate.kind {.
      case candidate.kind {
        evolution_record.Extension | evolution_record.Program -> Ok(profiles)
        evolution_record.Prompt -> {
          use selected <- result.try(evolution_store.selected(
            wiring.catalogue,
            candidate.scope,
            candidate.name,
          ))

          // Decide how to handle selected {.
          case selected {
            None -> Ok(profiles)
            Some(selection) -> {
              use selected <- result.try(evolution_store.authorized(
                wiring.catalogue,
                selection,
              ))
              use profile <- result.try(
                evolution_prompt.candidate_profile(selected)
                |> result.map_error(evolution_store.Corrupt),
              )
              Ok([profile, ..profiles])
            }
          }
        }
      }
    }),
  )
  evolution_profile.validate_map(list.unique(profiles))
  |> result.map_error(evolution_store.Corrupt)
}

/// Establishes evolution attempt for the caller, keeping its validation and result policy at this boundary.
fn evolution_attempt(
  config: agency.Config,
  attempt: provider_gateway.ProfileAttempt,
) -> Result(Nil, String) {
  use runtime <- result.try(
    agency.borrow_runtime(config)
    |> result.replace_error(
      "runtime unavailable for provider attempt provenance",
    ),
  )

  // The fact is write-once under an expect-absent compare-and-set, and a
  // reopened session keeps every key an earlier daemon wrote, so the key must
  // not repeat across VM boots. The unique-integer counter restarts at one
  // with each boot and the clock can step backwards, so neither is enough;
  // 128 random bits make a collision negligible.
  let key =
    "evolution/attempt/"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let value =
    json.Object([
      #("provider", json.String(attempt.target.provider)),
      #("model", json.String(attempt.target.model_id)),
      #("api", json.String(attempt.api)),
      #("ordinal", json.Int(attempt.ordinal)),
      #("digest", json.String(attempt.digest)),
      #("profile_id", case attempt.profile_id {
        None -> json.Null
        Some(id) -> json.String(id)
      }),
    ])
  api.put_reserved_fact_expecting(runtime, key, value, None)
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}

/// Establishes close evolution for the caller, keeping its validation and result policy at this boundary.
fn close_evolution(
  wiring: Option(EvolutionWiring),
) -> evolution_retirement.Task {
  case wiring {
    None -> evolution_retirement.done()
    Some(wiring) ->
      evolution_retirement.sequence(
        evolution_retirement.repeat(fn() {
          Ok(evolution_capability.stop(wiring.cell))
        }),
        evolution_retirement.sequence(
          evolution_retirement.repeat(fn() {
            evolution_queue.close(wiring.transitions)
          }),
          evolution_retirement.repeat(fn() {
            evolution_live.close(wiring.live, 120_000)
            |> result.map_error(evolution_store.describe)
          }),
        ),
      )
  }
}

/// Retires a legacy open_instance evaluator with the native executor witness.
/// Owned daemon instances retire through their existing custody owner instead.
///
/// ## Examples
///
/// `serve.retire_instance(instance)` refuses unconfirmed helper retirement.
pub fn retire_instance(instance: Instance) -> Result(Nil, String) {
  evolution_retirement.perform(instance_retirement(instance))
  |> result.map_error(fn(failed) { failed.reason })
}

/// Retires a legacy evaluator through its sole host and typed continuation.
/// Acknowledged failures transfer the remaining phases before that host exits.
///
/// ## Examples
///
/// `instance_retirement(instance)` is a production trial's native close task.
pub fn instance_retirement(instance: Instance) -> evolution_retirement.Task {
  case instance.legacy_host {
    Some(owner) -> host.retire_task(owner)
    None ->
      evolution_retirement.repeat(fn() {
        Error("owned instances retire through their custody owner")
      })
  }
}

// The legacy host is the sole caller. Its failure transfers remaining phases,
// so neither a consumed queue nor a confirmed pool is asked to close again.
//
// The hub is drained first, while it is still alive: a prompt the hub was
// holding for a busy strand can no longer be promised to anyone once this
// instance is going away, so every one is returned to its submitter before
// the runtime and the effect plane behind it stop. Tools run until the runtime
// has drained, so the holder they fetch from retires only after that.

/// Establishes instance retirement body for the caller, keeping its validation and result policy at this boundary.
fn instance_retirement_body(instance: Instance) -> evolution_retirement.Task {
  let drained =
    evolution_retirement.repeat(fn() {
      hub.drain_held(instance.gateway)
      api.close(instance.runtime) |> result.map_error(string.inspect)
    })
  let holder =
    evolution_retirement.repeat(fn() {
      let _retired = tool_holder.stop(instance.tools)
      Ok(Nil)
    })

  // The language server stops after the runtime, so no query is still
  // asking it, and before the services, so its manager is stopped
  // deliberately (and not replaced) rather than killed with the tree.
  let services =
    evolution_retirement.repeat(fn() {
      instance.plane.close()
      stop_services(instance.services)
      let _stopped = address.stop(instance.namespace)
      Ok(Nil)
    })

  // The broker and the helpers are this session's only for a local
  // workspace. For one on an executor the broker is a handle on the
  // executor's, which must not be stopped from here, and the plane's close
  // already closed the scope that owns the helpers.
  let pool = case instance.executor, instance.pool {
    Some(service), Some(pool) ->
      workspace_plane.retire_effect_plane(instance.broker, pool, service)
    _, _ -> evolution_retirement.done()
  }

  // Last, and after the runtime: an MCP client owns a child OS process, and
  // stopping one closes that child's stdin and kills it. Nothing can still be
  // calling by here, and the stop is a cast.
  let mcp =
    evolution_retirement.repeat(fn() {
      mcp_wiring.stop(instance.mcp)
      Ok(Nil)
    })

  // Each native plane remains independently retireable when the runtime's
  // writer or supervisor has already died. Only uncertain phases survive.
  evolution_retirement.join([
    drained,
    holder,
    instance.evolution_retire,
    services,
    pool,
    mcp,
  ])
}

// Legacy callers may render the refusal, while evaluator callers keep its task.
fn retire_instance_body(instance: Instance) -> Result(Nil, String) {
  evolution_retirement.perform(instance_retirement_body(instance))
  |> result.map_error(fn(failed) { failed.reason })
}

/// Establishes evolution program catalogue for the caller, keeping its validation and result policy at this boundary.
fn evolution_program_catalogue(
  catalogue: evolution_store.Store,
) -> Result(List(json.JsonValue), evolution_store.Refusal) {
  use candidates <- result.try(evolution_store.catalogue(catalogue))
  use entries <- result.try(
    list.try_map(candidates, fn(candidate) {
      // Decide how to handle candidate.kind {.
      case candidate.kind {
        evolution_record.Extension | evolution_record.Prompt -> Ok([])
        evolution_record.Program -> {
          use selected <- result.try(evolution_store.selected(
            catalogue,
            candidate.scope,
            candidate.name,
          ))

          // Decide how to handle selected {.
          case selected {
            Some(selection) if selection.candidate_id == candidate.id -> {
              use authorized <- result.try(evolution_store.authorized(
                catalogue,
                selection,
              ))
              use schema <- result.try(
                json.parse(authorized.input_schema)
                |> result.replace_error(evolution_store.Corrupt(
                  "program schema",
                )),
              )
              Ok([
                json.Object([
                  #(
                    "candidate_id",
                    json.String(evolution_record.id_string(candidate.id)),
                  ),
                  #("generation", json.Int(selection.generation)),
                  #("name", json.String(candidate.name)),
                  #("kind", json.String("program")),
                  #("description", json.String(candidate.description)),
                  #("schema", schema),
                  #("origin_session", json.String(candidate.origin.session_id)),
                ]),
              ])
            }
            Some(_) | None -> Ok([])
          }
        }
      }
    }),
  )
  Ok(list.flatten(entries))
}

// The model chooses an immutable task-set ID. Native admission owns its fixture,
// target and scoring bytes, and every arm opens the ordinary session assembly.

/// Establishes evolution compare for the caller, keeping its validation and result policy at this boundary.
fn evolution_compare(
  settings: Settings,
  agency_config: agency.Config,
  catalogue: evolution_store.Store,
  candidate_id: evolution_record.CandidateId,
  ctx: tool.Ctx,
  arguments: json.JsonValue,
) -> Result(evolution_record.Evidence, evolution_store.Refusal) {
  use #(taskset_id, limits) <- result.try(
    evolution_model_door.evaluation_request(arguments)
    |> result.map_error(evolution_store.Bounds),
  )
  use source <- result.try(
    agency.borrow_runtime(agency_config)
    |> result.replace_error(evolution_store.Unavailable(
      "source runtime is unavailable",
    )),
  )
  use admitted <- result.try(
    evolution_tasks.load(source.session, taskset_id)
    |> result.map_error(evolution_store.Authority),
  )
  use actual <- result.try(
    evolution_actual_model(settings.gateway, agency_config, ctx)
    |> result.map_error(evolution_store.Authority),
  )
  use target <- result.try(
    catalog.find(settings.catalog, actual.provider)
    |> result.map(catalog.resolved)
    |> result.replace_error(evolution_store.Authority(
      "actual model catalogue entry is absent",
    )),
  )

  // Decide how to handle use Nil <- result.try( target.model_id == actual.model {.
  use Nil <- result.try(case target.model_id == actual.model {
    True -> Ok(Nil)
    False ->
      Error(evolution_store.Authority(
        "actual model differs from its native catalogue",
      ))
  })

  evolution_rollout.evaluate(
    catalogue,
    candidate_id,
    target,
    actual.api,
    list.map(admitted.tasks, fn(fixture) { fixture.task }),
    limits,
    evolution_rollouts(settings, admitted, ctx.clock, ctx.base_policy),
  )
}

/// Establishes evolution rollouts for the caller, keeping its validation and result policy at this boundary.
fn evolution_rollouts(
  settings: Settings,
  admitted: evolution_tasks.TaskSet,
  clock: Clock,
  base: policy.SandboxPolicy,
) -> evolution_rollout.Callbacks {
  evolution_rollout_host.callbacks(
    settings.gateway,
    clock,
    fn(request, guarded) {
      evolution_trial(settings, admitted, request, guarded, base)
    },
    fn(task, workspace) { evolution_fixture.score(admitted, task, workspace) },
  )
}

// A trial has neither the source conversation nor another trial's filesystem.
// The guarded provider still dispatches through the actual production runtime,
// whose filesystem, bash and code-mode tools use the ordinary jail and broker.

/// Establishes evolution trial for the caller, keeping its validation and result policy at this boundary.
fn evolution_trial(
  settings: Settings,
  admitted: evolution_tasks.TaskSet,
  request: evolution_rollout.TrialRequest,
  guarded: provider_gateway.Gateway,
  base: policy.SandboxPolicy,
) -> Result(evolution_rollout_host.Running, String) {
  use fixture <- result.try(evolution_fixture.find(admitted, request.task))

  // Decide how to handle use target <- result.try( request.target {.
  use target <- result.try(case request.target {
    model.ForResolved(target) -> Ok(target)
    model.ForRole(..) -> Error("a trial requires its exact admitted model")
  })

  // Prepare private fixture trial directory and workspace structure.
  let tag = bit_array.base16_encode(token.production_entropy()(8))
  let private_trials = evolution_trials(settings)
  let root = private_trials <> "/" <> tag
  let workspace = root <> "/work"
  use Nil <- result.try(bootstrap.ensure_private_directory(root))
  use Nil <- result.try(evolution_fixture.install(fixture, workspace))

  // Configure isolated settings and profiles for trial session.
  let sockets = case settings.codemode_sockets {
    None -> filepath.directory_name(settings.session_path) <> "/run"
    Some(root) -> root
  }

  // Decide how to handle let profiles =  request.profile {.
  let profiles = case request.profile {
    None -> []
    Some(profile) -> [profile]
  }

  let isolated =
    Settings(
      ..settings,
      session_path: root <> "/state/session.db",
      token_path: root <> "/state/token",
      workspace:,
      domain_paths: None,
      // A trial is a fresh local session that belongs to no daemon: it is
      // reachable by no peer, places nothing on another machine, answers no
      // spawner and cannot restart itself through a profile or config edit.
      peer_directory: None,
      peer_defaults: None,
      remote_reach: None,
      deadline_tick_ms: None,
      depth_cap: None,
      metering: None,
      spawner: None,
      laptop: None,
      first_prompt: None,
      profile_desk: None,
      // The trial binds under the source's own socket root, not a directory
      // below it. The inherited protected list masks that root, and
      // `codemode.reaching_socket` lifts only a mask lying inside the socket
      // root, so a nested root would leave the daemon's mask over every
      // satellite directory and refuse each code-mode launch in the trial.
      // Per-execution directories are keyed by operation, step, source and a
      // length-prefixed work root, which is unique to the trial, so trials
      // cannot collide with each other or with the source session.
      codemode_sockets: Some(sockets),
      base_policy: evolution_trial_policy(base, private_trials, workspace),
      tools: catalog.ToolsConfig(..settings.tools, network: case base.network {
        policy.NetworkFull -> catalog.ToolNetworkFull
        policy.NetworkOff | policy.NetworkProxy(_, _) -> catalog.ToolNetworkOff
      }),
      helper_pool_size: 2,
      session_id: "trial-" <> tag,
      gateway: guarded,
      evolution_role: Trial(profiles),
      system: None,
      home: Some(root <> "/home"),
      model: machine_strand.ModelIdentity(target.provider, target.model_id),
      context_window: target.context_window,
      max_output_tokens: target.max_output_tokens,
      api: request.api,
      rules: [],
      schedules: [],
      schedule_policy: schedule.ModelSchedulesOff,
      memory: memory_config.Options(
        inject: memory_config.InjectsNothing,
        retired: [],
      ),
      advisor: None,
      // The source workspace's Go caches are writable roots of its own jail;
      // a trial builds in its fresh fixture and must not share them.
      go_caches: None,
    )
  use instance <- result.try(open_instance(isolated, log.discard()))
  Ok(
    evolution_rollout_host.Running(
      runtime: instance.runtime,
      workspace:,
      retire: instance_retirement(instance),
      cleanup: fn() {
        simplifile.delete(root)
        |> result.map_error(simplifile.describe_error)
      },
    ),
  )
}

/// Grants a trial only its fresh fixture while preserving source restrictions.
///
/// The native trial directory is the sole mask exception. It holds no retained
/// criteria or source state, and the replacement read/write roots reach only
/// this trial's workspace. Boot separately admits the discovered toolchain;
/// caller mounts and broad host reads cannot expose other trials or the daemon.
/// Original network, resource, environment and protected-state restrictions
/// remain in force.
///
/// ## Examples
///
/// `evolution_trial_policy(base, "/state/evolution-trials", workspace)`.
@internal
pub fn evolution_trial_policy(
  base: policy.SandboxPolicy,
  private_trials: String,
  workspace: String,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    readable_roots: [workspace],
    writable_roots: [workspace],
    mounts: [],
    scratch: policy.ScratchTmpfs,
    protected: [
      workspace <> "/" <> codemode_wiring.blob_directory,
      ..list.filter(base.protected, fn(path) { path != private_trials })
    ],
  )
}

/// Establishes evolution actual model for the caller, keeping its validation and result policy at this boundary.
fn evolution_actual_model(
  gateway: provider_gateway.Gateway,
  agency_config: agency.Config,
  ctx: tool.Ctx,
) -> Result(evolution_record.ModelScope, String) {
  use runtime <- result.try(
    agency.borrow_runtime(agency_config)
    |> result.replace_error("the native session is unavailable"),
  )
  use resolved <- result.try(
    provider_gateway.resolve(gateway, model.Main)
    |> result.replace_error("the native model is unavailable"),
  )
  use api <- result.try(
    provider_gateway.api_for(gateway, resolved)
    |> result.replace_error("the native provider API is unavailable"),
  )
  evolution_trace.actual_model(
    runtime.session,
    ctx.strand,
    evolution_record.ModelScope(resolved.provider, resolved.model_id, api),
  )
}

// Only the authenticated operator door can admit independent criteria or marks.
// The source runtime is borrowed natively; JSON never chooses a private session.

/// Establishes evolution operator controls for the caller, keeping its validation and result policy at this boundary.
fn evolution_operator_controls(
  config: agency.Config,
  lifecycle: evolution_control.Seam,
) -> evolution_control.Seam {
  evolution_control.Seam(
    command: fn(authority, principal, via, action, arguments) {
      // Decide how to handle action {.
      case action {
        "admit_tasks" | "mark_outcome" -> {
          // Decide how to handle use Nil <- result.try( authority {.
          use Nil <- result.try(case authority {
            access.Owner | access.Participant(access.Operator) -> Ok(Nil)
            access.Participant(access.Observer) ->
              Error("Denied: an operator is required")
          })

          use runtime <- result.try(
            agency.borrow_runtime(config)
            |> result.replace_error("the native source runtime is unavailable"),
          )

          // Decide how to handle action {.
          case action {
            "admit_tasks" -> {
              use admitted <- result.try(evolution_tasks.admit(
                runtime,
                authority,
                principal,
                arguments,
              ))
              Ok(
                json.Object([
                  #("taskset_id", json.String(admitted.id)),
                  #("tasks", json.Int(list.length(admitted.tasks))),
                ]),
              )
            }
            _ -> evolution_mark(runtime, principal, arguments)
          }
        }
        _ -> lifecycle.command(authority, principal, via, action, arguments)
      }
    },
  )
}

/// Establishes evolution mark for the caller, keeping its validation and result policy at this boundary.
fn evolution_mark(
  runtime: api.Runtime,
  principal: String,
  arguments: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use text <- result.try(tool.required_string(arguments, "entry_id"))
  use id <- result.try(
    ids.parse_entry_id(text)
    |> result.replace_error("invalid source entry identity"),
  )
  use found <- result.try(
    storage.get_entries(runtime.session.store, [id])
    |> result.replace_error("source entry is unreadable"),
  )
  use entry <- result.try(
    dict.get(found, id)
    |> result.replace_error("source entry is absent from this session"),
  )

  // Decide how to handle use Nil <- result.try( entry {.
  use Nil <- result.try(case entry {
    evolution_entry.MessageEntry(message: message.AssistantMessage(..), ..) ->
      Ok(Nil)
    _ -> Error("only a settled assistant source may receive a task outcome")
  })

  use verdict <- result.try(tool.required_string(arguments, "outcome"))

  // Decide how to handle use verdict <- result.try( verdict {.
  use verdict <- result.try(case verdict {
    "succeeded" -> Ok(evolution_trace.Succeeded)
    "failed" -> Ok(evolution_trace.Failed)
    _ -> Error("outcome must be succeeded or failed")
  })

  use Nil <- result.try(evolution_trace.mark(runtime, id, verdict, principal))
  Ok(
    json.Object([
      #("entry_id", json.String(text)),
      #(
        "outcome",
        json.String(case verdict {
          evolution_trace.Succeeded -> "succeeded"
          evolution_trace.Failed -> "failed"
          evolution_trace.Unmarked -> "unmarked"
        }),
      ),
    ]),
  )
}

// Live has already retained cleanup authority before answering. Model rendering
// may keep its named refusal, but must not retain the same retry twice.

/// Establishes evolution owned refusal for the caller, keeping its validation and result policy at this boundary.
fn evolution_owned_refusal(
  reason: evolution_store.Refusal,
) -> evolution_store.Refusal {
  case reason {
    evolution_store.CleanupUnconfirmed(..) ->
      evolution_store.Unavailable(evolution_store.describe(reason))
    _ordinary -> reason
  }
}
