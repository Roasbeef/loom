//// The session server: the production host the wiring adapter was
//// promoted for. `gleam run -m client/serve -- --session path.db`
//// (or the erlang shipment's `bin/loomd`) opens or creates one
//// SQLite session, stands up the whole stack over it — helper pool,
//// ToolBroker, tool registry, provider gateway, runtime with the
//// `client/wiring` effects, gateway hub, and the `client/server`
//// websocket transport — prints where it is listening, and serves any
//// number of thin clients until `SIGTERM` or a fatal fault, then closes
//// the runtime so the session lease is released rather than left to
//// expire.
////
//// ## Flags
////
//// - `--session <path>` (required) — the SQLite session file, created
////   if absent.
//// - `--bind <host:port>` — listen interface; default `127.0.0.1:0`
////   (an ephemeral port, printed at startup). Keep it loopback: auth
////   is `LocalAuth`'s token file, whose protection is file permissions.
//// - `--token-file <path>` — where the startup-minted bearer token is
////   written (`0600`); default `<session>.token`, printed at startup.
//// - `--workspace <dir>` — the agent's workspace root; default the
////   current directory.
//// - `--helper <path>` — the `loom-exec` sandbox helper; default the
////   first of `loom-exec` on `PATH` and `./bin/loom-exec`.
//// - `--config <loom.toml>` — a model catalogue file (`client/catalog`;
////   `docs/examples/loom.toml` is the worked example). A file that does
////   not parse or validate refuses the boot with a worded message —
////   the documented halt path, never a partial start.
//// - `--codemode-seed <dir>` — the prepared code-mode build seed
////   (`make codemode-seed`); default `<workspace>/build/codemode-seed`.
////   Code mode also needs `gleam` and `erl` on `PATH`. A host missing any
////   of the three says so once on stderr and registers no `code_mode`
////   tool at all, rather than shipping a definition in the provider's
////   cached prefix that can only ever refuse.
//// - `--codemode-seams <workspace|orchestration|both>` — which code-mode
////   seams this server offers; default `workspace`. `orchestration` and
////   `both` need a messaging plane, which this boot always wires, and
////   `both` is what lets a submission choose per program
////   (`docs/architecture/code-mode.md`, "Two seams").
//// - `--full-enforcement` — require every requested resource and lifecycle
////   layer, including the ones current Darwin kernels cannot provide. The
////   default is platform enforcement: it still refuses a missing jail or
////   any unexpected skip, while admitting the three Darwin gaps ADR-006
////   documents when the helper reports them explicitly.
//// - `--best-effort` — accept any degraded sandbox helper (development
////   kernels without bwrap/Landlock). This is weaker than the default and
////   remains an explicit opt-in. Run `make selftest` to learn which posture
////   your kernel supports.
//// - `LOOM_HELPER_POOL` — how many `loom-exec` helpers may run at
////   once (not a flag: it is a property of the host, not of the
////   session). Default `exec.default_pool_size()`, the node's
////   scheduler count clamped to `[4, 16]`. This is the real ceiling on
////   how wide a parallel tool batch runs: helpers are OS processes
////   running bwrap and a jail, and a batch wider than the pool waits
////   for a slot rather than failing. An override is clamped to that
////   same range, so a memory-tight host can come down to four and no
////   further: below two code mode cannot run at all, and anywhere below
////   the default a batch that no longer fits simply queues, so the
////   smaller pool buys latency rather than headroom.
////
//// ## Model configuration and precedence
////
//// Flags beat the config file, the config file beats the environment,
//// and built-in defaults fill whatever remains. Concretely: with
//// `--config` the catalogue file is the whole model surface — the
//// `LOOM_MODEL`/`LOOM_BASE_URL`/`LOOM_CONTEXT_WINDOW`/
//// `LOOM_MAX_OUTPUT_TOKENS` variables are not consulted — and without
//// it those variables shape a one-entry catalogue named `anthropic`
//// (model `claude-opus-5`, the built-in default) so the zero-config
//// boot keeps working unchanged. Either way `LOOM_SYSTEM_PROMPT` is
//// read from the environment, and API keys *only* ever come from the
//// environment: the catalogue names the variable per model
//// (`api_key_env`; `ANTHROPIC_API_KEY` in the env fallback), and the
//// gateway reads it at dispatch. A keyless environment still boots and
//// serves — generation requests then fail in-band with the
//// missing-secret error, exactly as the effect doctrine prescribes.
//// The env fallback's thinking level is off, which sends no thinking
//// field at all — on current Anthropic models that means server-chosen
//// adaptive thinking, and it sidesteps the adapter's `budget_tokens`
//// vocabulary, which newer models reject.
////
//// ## The system prompt
////
//// Assembled at the first open of a session and pinned into the reserved
//// `prompt/` blackboard cells; later boots send the pinned bytes rather
//// than deriving them again while the enforcement demand is unchanged.
//// Changing that demand deliberately re-renders and re-pins once, because
//// a byte-stable prompt that describes a stronger sandbox than the broker
//// demands would be a lie. `client/system_prompt` owns the whole story,
//// including why every other re-derivation would be expensive. Two
//// environment variables reach it:
////
//// - `LOOM_DISABLE_TOOLS` — a comma-separated list of built-in tools
////   this server does not register. The way an extension's tool comes
////   to stand in for a built-in of the same name; see
////   `client/contributions`. It frees a *name* and is not a capability
////   control: `code_mode`'s prelude still reaches `cap/proc.run`,
////   `cap/fs.write` and `cap/fs.edit` through the broker whatever this
////   list says, so narrowing what a session may do is the base policy's
////   job and never this variable's.
//// - `LOOM_PROMPT_PACK` — a pack file to render instead of the one
////   shipped in `prompt/default`. A file that cannot be read, or does not
////   decode, or renders to nothing, refuses the boot with a worded
////   message naming the file; a pack that merely renders *incompletely*
////   warns on stderr and serves.
//// - `LOOM_SYSTEM_PROMPT` — a literal prompt that bypasses the pack
////   entirely, still pinned, and taking precedence over an existing pin
////   because setting it is a deliberate act. Whitespace is not an
////   override: the pack renders as usual.
////
//// Everything the pack renders comes from a real source — the workspace
//// root, the VM's platform, the jail's shell, the registry's sorted tool
//// names, the demanded enforcement paired with a helper's `degraded`
//// hello, the base policy's network posture and protected paths, and the
//// workspace's own `CLAUDE.md`. Nothing volatile may join them: the
//// string sits behind a one-hour cache breakpoint and must be identical
//// for every strand and every turn of the session.
////
//// ## Failure and shutdown
////
//// This module is an entry point, so §0.2's no-panic rule is honored
//// by construction rather than by supervision: every boot step returns
//// a `Result`, `main` prints the first failure and exits nonzero via
//// the documented halt in `client/internal/ffi_os`. A boot that fails
//// has started nothing worth keeping and leaves nothing behind.
////
//// A boot that *succeeds* is rooted on a host process — `client/host` —
//// that traps exits, so every link an `actor.start` forms during the
//// boot lands there rather than on the caller. The server then stops
//// exactly two ways, and both arrive on one subject (`Booted.stops`):
////
//// - **`SIGTERM`.** `main` runs `shutdown` and exits 0.
//// - **A fatal child died.** The host runs `shutdown` *first* — so the
////   listener is closed and the session lease is released, not left to
////   its sixty-second TTL — and only then reports what died. `main`
////   prints it and exits 1, leaving the restart to whatever runs
////   `loomd`.
////
//// Either way `shutdown` is the same path, front to back: listener,
//// then the service supervisor, then the runtime (whose close stops the
//// strand drivers before the writer they commit through and releases
//// the lease), then broker, pool, and summary sink.
////
//// ## Which deaths are fatal, and which restart
////
//// Two tiers, and the difference is whether a replacement process would
//// be *reachable*.
////
//// **Restartable** — the commit forwarder, the Agency holder, the
//// escalation holder, the scratch store, the search holder, and the
//// gateway hub, under `Booted.services` (one-for-one, three restarts in
//// five seconds). None of them is addressed by pid: each registers
//// under a name and every caller reaches it through that name, so a
//// replacement is the same address, and a crash costs a moment of
//// hints, an evicted scratch cache, or the sockets attached to the old
//// hub — never the server. A spent restart budget is fatal, in order.
////
//// **Fatal** — the helper pool, the broker, the summary sink, the
//// session tree, the listener, and the service supervisor. Each of the
//// first three is captured *by value* into closures built during the
//// boot (the broker into the wiring effects and the code-mode seam, the
//// pool into the broker's checkout, the sink into `wiring.Config`), so
//// a replacement would be unreachable by everything already holding the
//// old handle: restarting one leaves a server that looks alive and
//// refuses every call. That is also the posture the effect plane wants
//// — a harness that cannot broker capabilities or jail a helper must
//// not keep serving. The session tree is fatal because it is itself a
//// supervisor whose own restart budget is already spent by the time it
//// dies.
////
//// One case is neither: the storage actor's death. It *is* the
//// connection that would delete the lease row, so when it goes the
//// lease can only expire. Everything else releases it.

import argv
import broker/broker.{type Broker}
import broker/egress
import broker/exec.{type EnforcementDemand, type Pool}
import broker/policy
import broker/token
import client/agency
import client/catalog
import client/codemode as codemode_wiring
import client/contributions
import client/distill
import client/distillpass
import client/escalate
import client/extension/dispatch as extension_dispatch
import client/extension/hooks as extension_hooks
import client/extension/hosts as extension_hosts
import client/extension/installed
import client/extension/manifest as extension_manifest
import client/extension/memory as extension_memory
import client/extension/record as extension_record
import client/gateway as hub
import client/history
import client/host
import client/install
import client/internal/ffi_os
import client/mcp as mcp_wiring
import client/memory
import client/notes
import client/rules
import client/rulescan
import client/schedule
import client/scheduleadmin
import client/schedulescan
import client/scheduleseam
import client/scratch
import client/server
import client/summaries
import client/system_prompt
import client/wiring
import core/clock.{type Clock}
import core/ids
import gleam/bool
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/adapter/gemini
import provider/adapter/openai
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import runtime/effects
import runtime/writer
import session/session
import simplifile
import telemetry/context
import telemetry/field
import telemetry/handler
import telemetry/log.{type Logger}
import tools/agent.{type Agency}
import tools/history as history_tool
import tools/remember
import tools/tool
import weft/poll

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
    /// The session's base policy — the ceiling every tool call is
    /// composed against, and the thing an escalation widens. `main`
    /// fills it with `base_policy(workspace)`; it is a field rather than
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
    /// The model catalogue behind the gateway's registry.
    catalog: catalog.Catalog,
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
    /// has built one. The default is `WorkspaceOnly` — the seam an
    /// unconfigured server has always served.
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
    /// The `[memory]` table: whether this host distils on boot, and how
    /// long one pass may take. Defaults to
    /// `client/distillpass.default_options`, which is one pass per boot
    /// — the shipped producer #149 asked for, and the reason a release
    /// needs no cron job to fill its memory.
    memory: distillpass.Options,
    /// The `[tools]` table: whether jailed tool shells reach the network,
    /// and what else their environment carries. Defaults to
    /// `catalog.default_tools()` — offline, three names — which is the
    /// jail every session has had until an operator writes otherwise, and
    /// is what the environment-shaped configuration path takes.
    tools: catalog.ToolsConfig,
  )
}

/// A running server: everything `shutdown` needs to take it apart in
/// order, plus the channel the host reports a stop on.
///
/// Constructor invariants: `services` is the supervisor over the
/// restartable composition layer (commit forwarder, Agency holder,
/// gateway hub); `stops` is owned by whichever process called `boot` and
/// is the only process that may receive on it.
pub type Booted {
  Booted(
    runtime: api.Runtime,
    served: server.Server,
    broker: Broker,
    pool: Pool,
    summaries: summaries.Summaries,
    /// The hub's stable address. Everything that talks to the hub — the
    /// listener, the commit forwarder, the provider tap — holds this
    /// name rather than a pid, which is what lets the hub be restarted
    /// under it.
    gateway: hub.Gateway,
    services: Pid,
    stops: Subject(host.Stop),
    session_id: String,
    token_path: String,
    bind_host: String,
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
    rulescan: Option(Name(writer.Event)),
    /// The scheduled-heartbeat scanner's name, or `None` on a boot that
    /// configured no schedules and therefore started no scanner. Not a
    /// writer subscriber — it is driven by its own injected timer, never
    /// by a commit hint — so its name has nothing to do with
    /// `subscribers:` the way `rulescan`'s does.
    schedulescan: Option(Name(schedulescan.Message)),
    /// The distillation worker's name, or `None` on a boot that runs no
    /// pass — `memory.distill = "off"`, or a catalogue that routes
    /// nothing the pipeline could ask. A name for the reason
    /// `rulescan`'s is one, and the door `client/distillpass.settled`
    /// waits on.
    memory_pass: Option(Name(distillpass.Message)),
  )
}

/// Parses flags, boots the stack, prints the startup lines, and serves
/// until `SIGTERM`. Usage failures print to stderr; everything after
/// the flags parse is logged. Either way a failure exits nonzero.
///
/// Two output channels, deliberately (spec §3.4). **stdout** carries the
/// startup banner and nothing else: it is this process's contract with
/// whoever launched it — the ephemeral port, the token file, the prompt
/// digest — and a supervisor script reads it with `head -1`. **The log
/// stream** carries everything about the running system, as JSON, one
/// event per line. A usage error is on neither side of that split: it
/// belongs to the person who mistyped a flag, before there is a session
/// to correlate anything to, so it stays on stderr with the usage text.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m client/serve -- --session ./loom.db --best-effort
/// ```
///
pub fn main() -> Nil {
  // Installed before anything can fail, so no line of this boot lands on
  // the VM's default text formatter.
  let logger =
    handler.install(
      threshold: handler.threshold_named(env_text(handler.level_variable)),
    )
  case parse(argv.load().arguments) |> result.try(resolve) {
    // A flag error is a message to a human at a terminal, and it carries
    // the usage text: stderr, not the log stream.
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
    Ok(settings) -> run_server(settings, logger)
  }
}

// Boots `settings` and, on success, serves until stopped. A boot failure
// is a log line and a nonzero exit.
fn run_server(settings: Settings, logger: Logger) -> Nil {
  let logger = log.scoped(logger, context.for_session(settings.session_id))
  case boot_with(settings, logger:) {
    Error(reason) -> {
      log.error(logger, "boot.failed", [
        field.text(key: "reason", value: reason),
      ])
      ffi_os.halt(1)
    }
    Ok(booted) -> serve_until_stopped(logger, booted)
  }
}

// The listening line, the signal wait, and either an orderly shutdown or
// a fatal exit — whichever way `booted.stops` fires.
fn serve_until_stopped(logger: Logger, booted: Booted) -> Nil {
  announce(booted)

  // The helper path is on this line because it is the answer to "which
  // binary enforced this session's sandbox", and the ladder that picked
  // it has four rungs. An operator auditing a running server should not
  // have to re-derive it, and a release smoke should not have to guess.
  log.info(logger, "server.listening", [
    field.count(key: "port", value: booted.served.port),
    field.ident(key: "prompt_digest", value: booted.prompt.digest),
    field.text(key: "helper", value: booted.helper_path),
  ])

  // Only an entry point installs the signal handler: doing so replaces
  // the VM's default, whose answer to `SIGTERM` is an immediate
  // `init:stop()`. From here both ways the server can stop arrive on one
  // subject.
  host.relay_sigterm(to: booted.stops, through: ffi_os.wait_for_sigterm)
  case process.receive_forever(booted.stops) {
    host.Signalled -> {
      log.info(logger, "server.stopping", [
        field.text(key: "cause", value: "sigterm"),
      ])
      shutdown(booted)
      log.info(logger, "server.stopped", [])
    }

    // The host already tore the stack down, lease included, before it
    // said anything. All that is left is to say what died and exit
    // nonzero so whatever runs `loomd` restarts it.
    host.Faulted(child:, reason:) -> {
      log.error(logger, "server.faulted", [
        field.text(key: "child", value: child),
        field.text(key: "reason", value: reason),
      ])
      ffi_os.halt(1)
    }
  }
}

// The banner, and the only thing on stdout. It stays plain text rather
// than becoming a log line because it is this process's contract with
// whoever launched it: a supervisor script reads the port and the token
// path off `head -1`, and a JSON envelope would break every such reader
// for no diagnostic gain. The log stream gets its own `server.listening`
// record; the one fact they share is the port.
fn announce(booted: Booted) -> Nil {
  io.println(
    "loomd: session "
    <> booted.session_id
    <> " listening on ws://"
    <> booted.bind_host
    <> ":"
    <> int.to_string(booted.served.port)
    <> "/v1/ws (token file "
    <> booted.token_path
    <> ")",
  )

  // The digest is what makes a cache miss attributable: a changed head
  // is either a prompt change, which this line names, or a bug.
  io.println(
    "loomd: system prompt "
    <> system_prompt.named(booted.prompt.origin)
    <> ", digest "
    <> booted.prompt.digest,
  )
}

// --- the effect plane, on its own -------------------------------------------
//
// `loom ext install` runs a jailed, network-off `gleam build` and needs
// exactly what a boot needs to do that: a helper it can find, a pool of
// them, the broker over the pool, and a verified toolchain and seed. It
// needs none of the rest of a boot — no session, no runtime, no listener
// — and it must not grow a second copy of any of it, because a divergence
// between the two would mean an extension built under a policy no session
// would have granted.

/// A pool of jailed helpers and the one broker over them.
///
/// Factored out of `assemble` because the extension installer wants this
/// and nothing else. The boot's own call is the only reason this is a
/// function rather than eight lines inline, and it is enough of one: the
/// two paths must compose the same policy from the same helper, or a
/// build that passes at install could fail at run.
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
) -> Result(#(Pool, Broker), String) {
  let spawn_config =
    exec.SpawnConfig(
      helper_path: helper,
      shell_path:,
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
  use pool <- result.try(
    exec.start_pool(size:, spawn: fn() { exec.spawn_helper(spawn_config) })
    |> result.map_error(fn(error) {
      "the helper pool did not start: " <> string.inspect(error)
    }),
  )
  use broker_actor <- result.try(
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock:,
        checkout: fn() { exec.checkout(pool, waiting: 15_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    |> result.map_error(fn(error) {
      "the broker did not start: " <> string.inspect(error)
    }),
  )
  Ok(#(pool, broker_actor))
}

/// Everything a jailed offline build needs, and nothing a session does.
pub type BuildPlane {
  BuildPlane(
    /// The broker every clearance goes through.
    broker: Broker,
    /// The pool behind it, held so the plane can be stopped.
    pool: Pool,
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
/// //   writable: staging, tmp_dir: staging, clock:)
/// ```
///
pub fn start_build_plane(
  helper helper: Option(String),
  seed seed: Option(String),
  workspace workspace: String,
  writable writable: String,
  tmp_dir tmp_dir: String,
  clock clock: Clock,
) -> Result(BuildPlane, String) {
  use helper_path <- result.try(find_helper(helper))

  // `workspace` and `writable` are two different questions and a boot
  // only ever asks them of one directory, which is why they were one
  // parameter until now. The seed ladder looks in the *checkout* a
  // contributor ran `make codemode-seed` in; the jail may write only
  // where the build root is, which for an install is under the
  // extensions root and nowhere near the checkout.
  let base = base_policy(writable)

  // The same refusal the boot makes, in the same place in the order: a
  // base policy the sandbox cannot enforce is a failure now, not a
  // surprise inside the build.
  use Nil <- result.try(base_policy_fault(base))
  use #(pool, broker_actor) <- result.try(start_effect_plane(
    helper: helper_path,
    base_policy: base,
    tmp_dir:,
    size: exec.min_pool_size,
    clock:,
  ))
  case codemode_wiring.discover(seed_root(seed, workspace)) {
    Ok(toolchain) ->
      Ok(BuildPlane(broker: broker_actor, pool:, toolchain:, base_policy: base))

    // A toolchain this host does not have is not a reason to leave a
    // pool of jails running: tear the plane down before saying so.
    Error(reason) -> {
      broker.stop(broker_actor)
      exec.stop_pool(pool)
      Error(reason)
    }
  }
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
  broker.stop(plane.broker)
  exec.stop_pool(plane.pool)
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
    codemode_seed: Option(String),
    codemode_seams: Option(String),
    demand: Option(EnforcementDemand),
  )
}

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
      codemode_seed: None,
      codemode_seams: None,
      demand: None,
    ),
  )
}

fn parse_loop(arguments: List(String), flags: Flags) -> Result(Flags, String) {
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
    ["--best-effort", ..rest] ->
      set_demand(rest, flags, exec.BestEffort, "--best-effort")
    ["--full-enforcement", ..rest] ->
      set_demand(rest, flags, exec.FullEnforcement, "--full-enforcement")
    [unknown, ..] -> Error("unknown argument `" <> unknown <> "`\n" <> usage)
  }
}

const usage = "usage: loomd --session <path.db>
  [--bind <host:port>]     listen interface (default 127.0.0.1:0)
  [--token-file <path>]    bearer token file (default <session>.token)
  [--workspace <dir>]      workspace root (default the current directory)
  [--helper <path>]        loom-exec binary (default: beside this server, then PATH, then ./bin)
  [--config <loom.toml>]   model catalogue file (default: LOOM_* env vars)
  [--codemode-seed <dir>]  code-mode build seed (default <workspace>/build/codemode-seed, then the bundled one)
  [--codemode-seams <s>]   code-mode seams: workspace, orchestration, both (default workspace)
  [--full-enforcement]     require every requested resource and lifecycle layer
  [--best-effort]          accept any degraded sandbox helper"

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

// Fills every default and builds the provider gateway from the model
// catalogue — the `--config` file when given, the environment-shaped
// one-entry catalogue otherwise — turning Flags into a bootable
// Settings. The new-strand identity and the wiring's fallback model
// facts all come from the main route's head entry, so one catalogue is
// the single source for everything model-shaped.
fn resolve(flags: Flags) -> Result(Settings, String) {
  use session_path <- result.try(case flags.session {
    Some(path) -> Ok(path)
    None -> Error("--session is required\n" <> usage)
  })
  use #(bind_host, bind_port) <- result.try(
    split_bind(option.unwrap(flags.bind, "127.0.0.1:0")),
  )
  use workspace <- result.try(case flags.workspace {
    Some(dir) -> Ok(dir)
    None ->
      simplifile.current_directory()
      |> result.map_error(fn(error) {
        "the working directory is unreadable: " <> string.inspect(error)
      })
  })
  use helper_path <- result.try(find_helper(flags.helper))

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
  use #(catalogue, rule_list, schedule_list, schedule_policy, memory, tools) <- result.try(
    load_config(flags.config),
  )

  // parse guarantees a routed, resolvable main chain, and the env
  // catalogue routes one by construction; the check stays for
  // directly-constructed catalogues.
  use main_entry <- result.try(
    catalog.main_model(catalogue)
    |> result.replace_error("the catalogue routes no usable main model"),
  )
  use codemode_seams <- result.try(parse_codemode_seams(flags.codemode_seams))
  let clock = clock.from_function(ffi_os.system_time_ms)
  Ok(Settings(
    session_path:,
    bind_host:,
    bind_port:,
    token_path: option.unwrap(flags.token_file, session_path <> ".token"),
    workspace:,
    base_policy: base_policy(workspace),
    helper_path:,
    helper_pool_size:,
    session_id: session_id_of(session_path),
    demand: option.unwrap(flags.demand, exec.PlatformEnforcement),
    gateway: catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret.env(),
      clock:,
    ),
    catalog: catalogue,
    system: option.from_result(env_text(system_prompt.override_variable)),
    home: option.from_result(env_text("HOME")),
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
    deactivated_tools: named_tools(env_text_or("LOOM_DISABLE_TOOLS", "")),
    memory:,
    tools:,
  ))
}

// A comma-separated tool list from the environment. Blank entries are
// dropped so that a trailing comma, or an empty variable, names nothing
// rather than naming the empty tool.
fn named_tools(value: String) -> List(String) {
  string.split(value, on: ",")
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
}

// The `--codemode-seams` value, or the default. An unrecognised name is a
// usage error rather than a fallback: a typo that quietly served the
// workspace seam would look exactly like a server that ignored the flag,
// and the person who typed it is standing at the terminal.
fn parse_codemode_seams(
  named: Option(String),
) -> Result(codemode_wiring.Seams, String) {
  case named {
    None -> Ok(codemode_wiring.WorkspaceOnly)
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
fn catalogue_facts(
  catalogue: catalog.Catalog,
) -> fn(machine_strand.ModelIdentity) ->
  Result(#(model.ResolvedModel, String), Nil) {
  fn(identity: machine_strand.ModelIdentity) {
    use entry <- result.map(catalog.find(catalogue, identity.provider))
    #(catalog.resolved(entry), adapter_api(entry.dialect))
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
fn adapter_api(dialect: catalog.Dialect) -> String {
  case dialect {
    catalog.Anthropic -> anthropic.api_name
    catalog.OpenAiCompatible -> openai.api_name
    catalog.Gemini -> gemini.api_name
  }
}

// The configuration ladder: an explicit file must load and validate or
// the boot refuses (a typoed config silently ignored would serve the
// wrong model); no file falls back to the environment surface, which
// defines no rules and no schedules — both are a deliberate act, and
// there is no environment variable that could be one by accident.
//
// The three parsers divide the document rather than sharing it: `catalog`
// owns the top-level key check and the model tables, `rules` owns
// everything inside a `[[rule]]`, `schedule` owns everything inside a
// `[[schedule]]`. Each is handed the text and does its own decode, which
// costs two extra parses of a small file at boot and keeps each parser's
// own worded TOML failure — the message an operator actually has to act
// on.
fn load_config(
  flag: Option(String),
) -> Result(
  #(
    catalog.Catalog,
    List(rules.Rule),
    List(schedule.Schedule),
    schedule.Policy,
    distillpass.Options,
    catalog.ToolsConfig,
  ),
  String,
) {
  case flag {
    None ->
      Ok(#(
        env_catalog(),
        [],
        [],
        schedule.default_policy,
        distillpass.default_options(),
        catalog.default_tools(),
      ))
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
      let named = fn(reason) { path <> ": " <> reason }
      use catalogue <- result.try(
        catalog.parse(text) |> result.map_error(named),
      )
      use rule_list <- result.try(rules.parse(text) |> result.map_error(named))
      use schedule_list <- result.try(
        schedule.parse(text) |> result.map_error(named),
      )
      use schedule_policy <- result.try(
        schedule.parse_policy(text) |> result.map_error(named),
      )
      use memory <- result.try(
        distillpass.parse(text) |> result.map_error(named),
      )
      use tools <- result.try(
        catalog.parse_tools(text) |> result.map_error(named),
      )
      Ok(#(catalogue, rule_list, schedule_list, schedule_policy, memory, tools))
    }
  }
}

// Splits `host:port` on the *last* colon, because IPv6 hosts carry
// colons of their own.
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
fn find_helper(flag: Option(String)) -> Result(String, String) {
  let found =
    helper_ladder(
      flag,
      beside: install.bundled_helper,
      on_path: fn() { ffi_os.find_executable(install.helper_name) },
      in_bin: fn() { install.existing_file(repo_helper) },
    )
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
fn session_id_of(path: String) -> String {
  let base = case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }
  case string.split(base, ".") {
    [name, ..] if name != "" -> name
    _ -> base
  }
}

// --- the environment -------------------------------------------------------

/// The default model identity when `LOOM_MODEL` is unset.
pub const default_model = "claude-opus-5"

// Environment reads go through the provider secret env store rather
// than a second env FFI: it is the injected env-lookup seam this tree
// already has, and these values are configuration, not durable state.
fn env_text(name: String) -> Result(String, Nil) {
  secret.lookup(secret.env(), name)
}

fn env_text_or(name: String, fallback: String) -> String {
  result.unwrap(env_text(name), fallback)
}

fn env_int_or(name: String, fallback: Int) -> Int {
  env_text(name)
  |> result.try(int.parse)
  |> result.unwrap(fallback)
}

// The zero-config surface as a one-entry catalogue: one Anthropic
// entry named `anthropic` (so pre-catalogue durable identities keep
// resolving) shaped by the LOOM_* variables, routed as main. The API
// key is *named* here and read only at dispatch, so a keyless
// environment boots fine and fails in-band per request.
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
      ),
    ],
    roles: [#(model.Main, ["anthropic"])],
    mcp_servers: [],
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
/// // ... booted.served.port is bound, booted.runtime is live ...
/// // serve.shutdown(booted)
/// ```
///
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
pub fn boot_with(
  settings: Settings,
  logger logger: Logger,
) -> Result(Booted, String) {
  host.adopt(
    boot: fn(stops) { assemble(settings, logger, stops) },
    fatal: fatal_children,
    teardown: shutdown,
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
  let named = [
    #("the session tree", booted.runtime.tree.supervisor),
    #("the websocket listener", booted.served.supervisor),
    #("the service supervisor", booted.services),
  ]
  case summaries.pid(booted.summaries) {
    Ok(pid) -> [#("the summary sink", pid), ..named]
    Error(Nil) -> named
  }
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
fn code_mode_seam(
  settings: Settings,
  logger: Logger,
  broker_actor: Broker,
  clock: Clock,
  agency_seam: Agency,
  scratch_seam: codemode_wiring.Scratch,
  schedule_door: Option(scheduleseam.Door),
) -> #(Option(codemode_wiring.Config), mcp_wiring.Layer) {
  case codemode_wiring.discover(settings.codemode_seed) {
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
      #(None, mcp_wiring.none())
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
      let layer =
        start_mcp(settings.codemode_seams, settings.catalog.mcp_servers, logger)
      #(
        Some(
          codemode_wiring.default_config(
            broker: broker_actor,
            clock:,
            workspace: settings.workspace,
            toolchain:,
          )
          // Which seams this server offers is the operator's decision, and
          // the Agency the orchestration one routes onto is the same seam
          // the `agent_*` tools call — one messaging plane, reached two
          // ways.
          |> codemode_wiring.serving(settings.codemode_seams, over: agency_seam)
          // `kv.*` is answered by the session's one scratch store, which
          // starts under the service supervisor below. The seam is a
          // name, so it can be built here and resolved per call.
          |> codemode_wiring.over_scratch(scratch_seam)
          // `schedule.*` is answered by the same door the `schedule_*`
          // tools call, so a program and a tool call cannot disagree
          // about what this session's schedules are. A shut door leaves
          // the capabilities unrouted rather than always-refusing.
          |> codemode_wiring.over_schedules(schedule_door)
          // The MCP layer widens the workspace seam's allowlist, its
          // description and its router together; an empty layer widens
          // nothing, so this is unconditional.
          |> codemode_wiring.over_mcp(layer),
        ),
        layer,
      )
    }
  }
}

// --- installed extensions ---------------------------------------------------
//
// Discovery is read-only and happens once, here, before the registry is
// built. `installed.discover` re-derives the tree digest, the artifact's
// content address, the manifest and the vetting from what is actually on
// disk and refuses anything that no longer matches what an operator
// approved, so what reaches this function is already the answer to "is
// this still the thing that was installed".
//
// What is left to decide is what to do with each answer, and there are
// three. A `Refused` is *logged*, never silently dropped: an operator who
// installed something and then sees nothing has no way to tell "it is
// broken" from "I imagined installing it". A `Ready` on a host with no
// toolchain is logged too and registers nothing, because an extension
// tool with no `erl` to boot a satellite with is a definition in the
// provider's cached byte prefix that can only ever fail — the same
// argument that gates `code_mode` itself. Everything else becomes one
// `Contribution` per extension, and a name two contributions both claim
// refuses the boot in `contributions.registry`.

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

fn extension_registrations(
  settings: Settings,
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> List(Registration) {
  case settings.home {
    // No home is no extensions root, which is the same fact to a booting
    // server as an empty one: there is nothing installed and nothing to
    // warn about.
    None -> []

    Some(home) -> {
      let root = extension_record.root_for(home)
      list.filter_map(installed.discover(root), fn(found) {
        extension_contribution(
          root,
          found,
          logger,
          hosts,
          hooking,
          host,
          memory,
        )
      })
    }
  }
}

fn extension_contribution(
  root: extension_record.Root,
  found: installed.Discovered,
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> Result(Registration, Nil) {
  case found {
    installed.Refused(name:, reason:) -> {
      log.warn(logger, "extension.refused", [
        field.text(key: "name", value: name),
        field.text(key: "reason", value: reason),
      ])
      Error(Nil)
    }

    installed.Ready(record: written, manifest: decoded, artifact:) ->
      extension_registered(
        root,
        written,
        decoded,
        artifact,
        logger,
        hosts,
        hooking,
        host,
        memory,
      )
  }
}

fn extension_registered(
  root: extension_record.Root,
  written: extension_record.Record,
  decoded: extension_manifest.Manifest,
  artifact: String,
  logger: Logger,
  hosts: extension_hosts.Hosts,
  hooking: extension_hooks.Invoker,
  host: Option(codemode_wiring.Config),
  memory: extension_memory.Door,
) -> Result(Registration, Nil) {
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
      Error(Nil)
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
          // The process environment, the same store `api_key_env`
          // reads. The value never reaches a `Tool`, a frame or a log:
          // this function is handed to `broker/egress`, which reads it
          // after the origin and method are judged and puts the result
          // straight on the wire.
          secrets: env_text,
          // The platform trust store. A pinned root is a test-only
          // shape, and there is no operator surface for one.
          trust: egress.SystemRoots,
          launch: extension_dispatch.jailed_node,
        )
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
          Error(Nil)
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
fn extension_subscription(
  written: extension_record.Record,
  logger: Logger,
  hooking: extension_hooks.Invoker,
) -> Option(extension_hooks.Extension) {
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

/// Whether the seams this server offers can reach an MCP server at all.
///
/// A server's tools are a module a **workspace** program may import, and
/// the orchestration seam is widened by none of it, ever
/// (`client/codemode.over_mcp`) — so a host serving orchestration alone
/// holds nothing that could ever call one, and starting third-party
/// server processes for it, each with a configured secret in its
/// environment, would be cost and attack surface bought for no
/// capability. The same argument the absent-`code_mode` arm above makes,
/// one decision further in.
///
/// A function rather than an inline `case` because it is the whole of
/// the decision and the only part of this boot a hermetic test can hold
/// still.
///
/// ## Examples
///
/// ```gleam
/// assert serve.mcp_reachable(codemode.WorkspaceOnly)
/// ```
///
pub fn mcp_reachable(seams: codemode_wiring.Seams) -> Bool {
  case seams {
    codemode_wiring.WorkspaceOnly | codemode_wiring.BothSeams -> True
    codemode_wiring.OrchestrationOnly -> False
  }
}

// One `mcp.unavailable` line naming every server that was configured and
// not started, and why. Worded as the layer's own refusals are: a
// skipped server has no module, so a program importing it is refused by
// vetting with no word about the absence, and this line is the only
// thing an operator will ever see about it.
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

// Every configured server this host can reach started, and one line
// each way.
//
// The seam gate lives here rather than at the call site so there is one
// place a server can be started from, and it is the place that asks
// whether anything could call one.
//
// `mcp.ready` names the servers that answered and how many tools each
// listed, because "how many" is the number that decides what the
// description costs. `mcp.unavailable` names one server and its reason
// — a missing executable, a refused handshake, an unset `api_key_env`,
// a listing this generator will not accept — and is the only thing
// anybody will ever see about it: a refused server has no module, so a
// program importing it is refused by vetting with no word about why the
// module is absent.
fn start_mcp(
  seams: codemode_wiring.Seams,
  servers: List(catalog.McpServer),
  logger: Logger,
) -> mcp_wiring.Layer {
  case mcp_reachable(seams) {
    True -> started_mcp(servers, logger)
    False -> {
      skipped_mcp(
        servers,
        logger,
        "MCP servers are reached from the workspace seam only, and this "
          <> "host serves the orchestration seam alone, so none was started",
      )
      mcp_wiring.none()
    }
  }
}

fn started_mcp(
  servers: List(catalog.McpServer),
  logger: Logger,
) -> mcp_wiring.Layer {
  use <- bool.lazy_guard(when: servers == [], return: mcp_wiring.none)
  let #(layer, refusals) =
    mcp_wiring.start(servers, mcp_wiring.default_options())
  list.each(refusals, fn(refusal) {
    log.warn(logger, "mcp.unavailable", [
      field.text(key: "server", value: refusal.server),
      field.text(key: "reason", value: refusal.reason),
    ])
  })
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
  layer
}

fn assemble(
  settings: Settings,
  logger: Logger,
  stops: Subject(host.Stop),
) -> Result(Booted, String) {
  // The search index is protected before the policy is validated,
  // because it is part of the policy this server refuses to boot
  // without. See `protecting_index` for why a model-writable index is a
  // security property rather than a tidiness one.
  use index_path <- result.try(index_path(settings))

  // Memory is protected on the same argument one step along: the digest
  // sidecar is text this server injects into every run's context, and
  // the store behind it is what the digest is rendered from. See
  // `protecting_memory`.
  use memory_store <- result.try(beside_session(settings, memory.memory_file))
  use memory_digest <- result.try(beside_session(settings, memory.digest_file))
  let base_policy =
    protecting_index(settings.base_policy, index_path)
    |> protecting_memory(memory_store, memory_digest)
    |> allowing_tool_tmpdir
    |> under_tools_config(settings.tools)

  // Before a directory is made, a lease is taken or a helper is spawned:
  // a base policy the sandbox cannot enforce is a boot failure, not a
  // surprise waiting in the first tool call. See `base_policy_fault`.
  use Nil <- result.try(base_policy_fault(base_policy))
  let blob_root = settings.workspace <> "/" <> codemode_wiring.blob_directory
  let tmp_dir = settings.session_path <> ".tmp"
  use Nil <- result.try(prepare_directories(
    settings,
    blob_root,
    tmp_dir,
    tool_tmp_directory(settings.workspace),
  ))

  // One clock function, therefore one era, across session, broker,
  // tools, and provider — the shared-clock requirement the M2
  // integration learned live (spec-gaps, M2 item 1).
  let clock = clock.from_function(ffi_os.system_time_ms)
  let entropy = mixed_entropy()
  use opened <- result.try(
    session.open_sqlite(
      path: settings.session_path,
      owner: "loomd",
      lease_ttl_ms: 60_000,
      clock:,
    )
    |> result.map_error(fn(error) {
      "the session did not open (held lease? bad path?): "
      <> string.inspect(error)
    }),
  )

  // The effect plane: a pool of jailed helpers behind the one broker.
  use #(pool, broker_actor) <- result.try(start_effect_plane(
    helper: settings.helper_path,
    base_policy:,
    tmp_dir:,
    size: settings.helper_pool_size,
    clock:,
  ))

  // The orchestration plane: runtime over the production wiring, with
  // the hub's two composition seams — commit hints in, provider deltas
  // teed out — threaded through before `api.open`.
  let name = process.new_name(prefix: "loom_gateway")

  // The forwarder itself starts later, under the service supervisor.
  // Only its *name* is needed here, because that is what the writer
  // subscribes to — a subscription by name is what lets the forwarder be
  // restarted without the writer noticing.
  let forwarder_name = process.new_name(prefix: "loom_forwarder")

  // The triggered-rule scanner is the writer's second subscriber, and
  // reaches it the same way and for the same reason. A name is minted
  // whether or not any rule is configured — an unregistered name is a
  // subscriber the writer skips, which costs the commit path nothing —
  // so the branch that matters is the one that decides whether to start
  // anything under it.
  let rulescan_name = process.new_name(prefix: "loom_rulescan")

  // The scheduled-heartbeat scanner is not a writer subscriber — it is
  // driven by its own injected timer, never by a commit hint, so its
  // name is minted for exactly one reason: the restartable-service tier
  // below needs an address that survives the scanner being replaced.
  let schedulescan_name = process.new_name(prefix: "loom_schedulescan")

  // The distillation pass, on the same arrangement and for the same
  // reason: it is a supervised child, and `client/distillpass.settled`
  // asks it by name rather than holding a pid that a restart would
  // stale.
  let distill_name = process.new_name(prefix: "loom_distill")

  // The Agency's holder cannot exist yet: `api.open` takes the effects
  // and returns the runtime, and the runtime contains the effects, so a
  // closure over the live runtime is a value cycle rather than an
  // ordering problem. The seam closes over a *name* instead — the same
  // indirection `hub.commit_forwarder` uses four lines above — and the
  // holder is started under that name once the open has returned.
  let agency_name = process.new_name(prefix: "loom_agency")
  let agency_config =
    agency.Config(
      ..agency.default_config(agency_name, clock),
      // Role follows identity: a spawned child is seeded from the
      // `subagent` route when the catalogue routes one, and inherits its
      // parent when it does not. Resolved at spawn from the gateway built
      // at boot, so the answer is a function of durable configuration.
      subagent_model: fn() {
        use resolved <- result.map(
          provider_gateway.resolve(settings.gateway, model.Subagent)
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
  let agency_seam = agency.seam(agency_config)

  // The escalation plane has the same knot and the same answer: a name
  // now, a holder under it after the open. `interactive` is a question
  // rather than a flag because the answer changes while a call is
  // parked — a session serves whoever is attached, and a refusal must
  // not hold a call open for a decision from a client that has gone.
  // Asking the hub by name (not by handle) keeps that true across a hub
  // restart.
  let escalate_name = process.new_name(prefix: "loom_escalate")
  let escalate_config =
    escalate.Config(
      ..escalate.default_config(escalate_name, clock),
      interactive: fn() { hub.attached(hub.Gateway(name:)) > 0 },
    )

  // Code mode needs no such indirection — its seam closes over the
  // broker, which already exists — but it does need a toolchain and a
  // prepared build seed on this host. A host without them says so once
  // here and registers no `code_mode` tool, rather than shipping a
  // definition in the cached prefix that can only ever refuse.
  // The scratch store `cap/kv` reads and writes: session-scoped,
  // byte-capped, and gone when the session is. Reached through a name
  // for the reason the Agency is — the seam is built while this
  // configuration is assembled and the store starts under the service
  // supervisor further down — though the knot here is only ordering,
  // since the store closes over no runtime at all.
  let scratch_name = process.new_name(prefix: "loom_scratch")

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

  // The host configuration, not the tool seam: an extension dispatch
  // stands up a satellite under exactly this configuration, so the boot
  // holds the value both readers derive from rather than one reader's
  // view of it.
  let #(code_mode_host, mcp_layer) =
    code_mode_seam(
      settings,
      logger,
      broker_actor,
      clock,
      agency_seam,
      scratch.seam(scratch_name, timeout_ms: scratch.default_timeout_ms),
      schedule_door,
    )
  let code_mode = option.map(code_mode_host, codemode_wiring.seam)

  // The environment every jailed child of this session inherits, tool
  // and hook alike. It is built once the code-mode decision is in so the
  // shell finds the same `gleam` and `erl` the compiler uses.
  let #(environment, unset_names) =
    tool_environment(
      settings.workspace,
      option.map(code_mode_host, fn(config) { config.toolchain_path }),
      settings.tools,
      reading: env_text,
    )

  // A configured name the host has not set is one warned line and not a
  // boot failure: the operator learns it here, and the tool that wanted
  // it says so in band when it runs.
  list.each(unset_names, fn(name) {
    log.warn(logger, "tools.env_unset", [field.ident(key: "name", value: name)])
  })

  // Recall, on the same two-name pattern and gated the same way: the
  // holder that owns the index cannot exist until the runtime has been
  // opened (its canonical session id is what a scoped query and every
  // hit from this session are named by), so the tool seam closes over
  // the name now and the holder starts under it further down. An index
  // that will not open registers no tool at all.
  let history_name = process.new_name(prefix: "loom_history")
  let history_pulls = process.new_name(prefix: "loom_history_pulls")
  let history_seam = history_seam(index_path, history_name, logger)

  // The memory door, gated the same way and for the same reason: a
  // `remember` definition renders into the provider's cached byte prefix
  // and is paid for on every request, so a host whose memory plane will
  // not open registers no tool and says so once.
  let memory_seam = memory_seam(memory_store, clock, entropy, logger)

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
  // Discovery then happens once and answers three questions: which tools
  // each installed extension contributes, which hook events it
  // subscribed to, and how its node is launched. The hook half is used
  // further down, after the effects record exists to compose it into.
  let hosts_name = process.new_name(prefix: "loom_ext_hosts")
  let hosts_seam =
    extension_hosts.seam(
      hosts_name,
      clock:,
      margin_ms: extension_host_margin_ms,
    )
  let extensions =
    extension_registrations(
      settings,
      logger,
      hosts_seam,
      extension_hosts.invoker(
        hosts_seam,
        at: hook_coordinates(settings, entropy(), clock, environment),
      ),
      code_mode_host,
      extension_memory.for_session(agency_config),
    )

  use tool_registry <- result.try(
    list.append(
      contributions.built_in(
        Some(agency_seam),
        code_mode,
        history_seam,
        memory_seam,
        schedule_seam,
      ),
      // After the built-ins, always. `contributions.registry` refuses a
      // repeated name whichever order it meets one in, so the order is
      // not what makes an extension unable to shadow `bash` — but the
      // collision message names the *second* claimant as the thing to
      // remove, and the newcomer is the extension.
      list.map(extensions, fn(registration) { registration.contribution }),
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
        base_policy,
        pool,
        tool.names(tool_registry),
        tool.snippets(tool_registry),
      )
    }),
  )
  list.each(assembled.warnings, fn(warning) {
    log.warn(logger, "prompt.warning", [
      field.text(key: "detail", value: warning),
    ])
  })

  // The summarization pack, before the open for the same reason the
  // system prompt is: `wiring.Config` needs the decoded value. Nothing
  // about it is pinned — it is read once per compaction, never cached,
  // and swapping it costs no cache write.
  use #(summary_pack, summary_warnings) <- result.try(
    system_prompt.summary_pack(
      option.from_result(env_text(system_prompt.summary_pack_variable)),
    ),
  )
  list.each(summary_warnings, fn(warning) {
    log.warn(logger, "summary_pack.warning", [
      field.text(key: "detail", value: warning),
    ])
  })
  use summary_sink <- result.try(
    summaries.start()
    |> result.map_error(fn(error) {
      "the summary sink did not start: " <> string.inspect(error)
    }),
  )
  let configuration =
    machine_strand.StrandConfiguration(
      model: settings.model,
      thinking_level: seed_thinking(settings),
      // `tool.names` is sorted, which is what a durable active list must
      // be: the render order of the tool array is the provider cache's
      // byte prefix (see `gateway.canonical_tool_names`).
      active_tool_names: tool.names(tool_registry),
    )
  let built =
    wiring.build_effects(wiring.Config(
      gateway: settings.gateway,
      role: model.Main,
      facts: catalogue_facts(settings.catalog),
      system: Some(assembled.text),
      api: settings.api,
      fallback_context_window: settings.context_window,
      fallback_max_output_tokens: settings.max_output_tokens,
      provider_timeout_ms: 300_000,
      summary_role: model.Summarize,
      summary_pack:,
      summaries: summary_sink,
      session: opened,
      compaction: settings.compaction,
      broker: broker_actor,
      broker_timeout_ms: 30_000,
      registry: tool_registry,
      workspace: settings.workspace,
      blob_root:,
      base_policy:,
      escalations: escalate.seam(escalate_config),
      demand: settings.demand,
      env: environment,
      clock:,
      entropy:,
    ))
  let effects_record =
    effects.Effects(
      ..built,
      provider: hub.tap_provider(built.provider, to: name),
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
        // The memory digest is read at every run start rather than once
        // here, because this server runs the producer as well: the pass
        // `client/distillpass` starts writes the sidecar under this same
        // boot, and a digest captured here would hold every session one
        // pass behind its own pipeline. It is still a read of bytes and
        // never an open — this server takes no memory lease outside that
        // pass — so a consolidation landing mid-session costs the next
        // run one file read and nothing else. The reader carries the
        // logger because a sidecar too large to be a digest is refused,
        // and a silent refusal looks exactly like a repository that has
        // never distilled. Absent file, nothing injected, no tokens
        // spent.
        |> memory.digest_hooks(
          memory.digest_reader(memory_digest, logger),
          clock,
        ),
    )

  // The extension hook bus goes on last, over the composed record, so an
  // extension's `before_agent_start` injection lands after the harness's
  // own digests and its `context` fold is the final thing to touch a
  // request's messages. Wrapping rather than replacing is what lets the
  // two layers coexist at all.
  let effects_record =
    with_extension_hooks(effects_record, extensions, opened, clock, logger)
  let options = api.default_options(configuration)
  use runtime <- result.try(
    api.open(
      opened,
      effects_record,
      api.Options(
        ..options,
        // The run-settings snapshot every accepted run captures. This is
        // what gates step 3 of a checkpoint; the hooks carry their own
        // copy for the arithmetic.
        settings: operation.RunSettings(
          ..options.settings,
          compaction: settings.compaction,
        ),
        // Three subscribers, all by name, all restartable: the hub's
        // hint forwarder; the rule scanner, whose name the writer
        // safely skips on a host with no rules; and — when this host
        // has an index — the poke that drives search sync. The latter
        // two are what make triggered rules and recall *commit*-driven
        // rather than scheduled; a hint lost while a subscriber
        // restarts costs latency, never a row or a fire, because each
        // pulls from its own durable cursor.
        subscribers: [
          process.named_subject(forwarder_name),
          process.named_subject(rulescan_name),
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
    )
    |> result.map_error(fn(error) {
      "the runtime did not open: " <> string.inspect(error)
    }),
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
    |> sup.restart_tolerance(
      intensity: service_restart_intensity,
      period: service_restart_period,
    )
    |> sup.add(hub.supervised_commit_forwarder(
      to: name,
      as_name: forwarder_name,
    ))
    |> sup.add(
      supervision.worker(fn() { agency.start(agency_config, runtime) }),
    )
    |> sup.add(
      supervision.worker(fn() { escalate.start(escalate_config, runtime) }),
    )
    // The scratch store is here rather than among the fatal children
    // because it is addressed by *name* and holds nothing a restart
    // cannot do without: `cap/kv` requires every caller to tolerate a
    // vanished value, so an emptied store costs a running program a
    // cache miss it was already written to handle.
    |> sup.add(scratch.supervised(scratch_name, scratch.default_bounds()))
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
    |> with_rule_scanner(settings, runtime, rulescan_name, logger)
    |> with_schedule_scanner(settings, runtime, schedulescan_name, logger)
    // Started here rather than inside the boot: the pass dispatches
    // model turns, and this tier starts after the session's own writer
    // lease is held — which is what makes the live session the one file
    // the pass is guaranteed to skip.
    |> with_distill_pass(
      settings,
      distill_name,
      memory_store,
      clock,
      entropy,
      logger,
    )
    |> sup.add(
      supervision.worker(fn() {
        hub.start(
          hub.default_options(settings.session_id, runtime)
            |> hub.with_catalog(settings.catalog)
            |> hub.with_registry(tool_registry)
            |> with_schedule_admin(schedule_admin),
          name,
        )
      }),
    )

  // The index holder is in this tier for the same reason the scratch
  // store is: it is addressed by name, and everything it holds is one
  // connection to a rebuildable projection that a restart reopens. Its
  // canonical session id comes from the runtime, which is why it is
  // added here rather than in the pipeline above.
  use services <- result.try(
    services_tree
    |> with_history(
      history_seam,
      history.over_session(
        name: history_name,
        path: index_path,
        session: api.session_id(runtime),
        store: opened.store,
        generation: history.sqlite_generation(settings.session_path),
        timeout_ms: history.default_timeout_ms,
      ),
      history_pulls,
    )
    |> sup.start
    |> result.map_error(fn(error) {
      "the service supervisor did not start: " <> string.inspect(error)
    }),
  )

  // The host owns this supervisor through the record and a monitor, not
  // through the start link, so that its death is a fault the host
  // *handles* rather than a signal that fells the host mid-teardown.
  process.unlink(services.pid)
  use served <- result.try(
    server.serve(server.Config(
      gateway: hub.Gateway(name:),
      bind: settings.bind_host,
      port: settings.bind_port,
      auth: server.LocalAuth(token_path: settings.token_path),
      entropy:,
    ))
    |> result.map_error(fn(error) {
      "the websocket server did not start: " <> string.inspect(error)
    }),
  )
  Ok(Booted(
    runtime:,
    served:,
    broker: broker_actor,
    pool:,
    summaries: summary_sink,
    gateway: hub.Gateway(name:),
    services: services.pid,
    stops:,
    session_id: settings.session_id,
    token_path: settings.token_path,
    bind_host: settings.bind_host,
    prompt: assembled,
    helper_path: settings.helper_path,
    mcp: mcp_layer,
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
    // The same question `with_distill_pass` starts one on, asked in the
    // same order and of the same two facts, so the field cannot say
    // `None` while a worker runs under that name.
    memory_pass: case settings.memory.cadence, distiller(settings) {
      distillpass.DistillsOff, _routed -> None
      distillpass.DistillsOnBoot, Error(_unroutable) -> None
      distillpass.DistillsOnBoot, Ok(_distiller) -> Some(distill_name)
    },
  ))
}

/// Takes a booted server apart, front to back: the listener first so no
/// new client arrives mid-teardown, then the runtime — whose close
/// stops the strand drivers before the writer they commit through and
/// releases the session lease while its drain witness is still observable —
/// then the service supervisor and finally the effect plane, broker
/// before pool because the broker is what holds helpers out on loan.
///
/// Idempotent and callable from any process, which both paths need: the
/// entry point runs it on `SIGTERM`, and the host runs it from its own
/// process when a fatal child dies. An error closing the session is
/// swallowed deliberately — it means the lease release did not commit,
/// which only the TTL can now mop up, and there is nothing left to
/// abandon.
///
/// ## Examples
///
/// ```gleam
/// // serve.shutdown(booted)
/// ```
///
pub fn shutdown(booted: Booted) -> Nil {
  server.stop(booted.served)
  let _closed = api.close(booted.runtime)
  stop_services(booted.services)
  broker.stop(booted.broker)
  exec.stop_pool(booted.pool)
  summaries.stop(booted.summaries)

  // Last, and after the runtime: an MCP client owns a child OS process,
  // and stopping one closes that child's stdin and kills it. Nothing can
  // still be calling by here — the drivers stopped with the runtime —
  // and the stop is a cast, so a client that has already died costs
  // nothing.
  mcp_wiring.stop(booted.mcp)
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
fn with_rule_scanner(
  builder: sup.Builder,
  settings: Settings,
  runtime: api.Runtime,
  name: Name(writer.Event),
  logger: Logger,
) -> sup.Builder {
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

// The scheduled-heartbeat scanner, and the decision not to start one —
// the same `codemode.unavailable` posture `with_rule_scanner` takes, for
// the same reason: a plane nobody configured should cost a host a
// process of exactly nothing.
fn with_schedule_scanner(
  builder: sup.Builder,
  settings: Settings,
  runtime: api.Runtime,
  name: Name(schedulescan.Message),
  logger: Logger,
) -> sup.Builder {
  let door_open = schedule.policy_opens_the_door(settings.schedule_policy)
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
// The distillation pass, and the two decisions not to start one.
//
// The same posture `with_rule_scanner` takes, over a plane that is on by
// default rather than off: a host that opted out logs one line and
// starts nothing, and a host whose catalogue routes neither a summarize
// nor a main model cannot ask the pipeline's two questions, so it says
// that instead of standing up a worker that could only fail. Both lines
// exist because memory that silently never fills is the failure #149 was
// filed about.
fn with_distill_pass(
  builder: sup.Builder,
  settings: Settings,
  name: Name(distillpass.Message),
  memory_store: String,
  clock: Clock,
  entropy: fn() -> Int,
  logger: Logger,
) -> sup.Builder {
  case settings.memory.cadence, distiller(settings) {
    distillpass.DistillsOff, _routed -> {
      log.info(logger, distillpass.off_event, [
        field.text(
          key: "effect",
          value: "no distillation pass runs; remembered notes accumulate "
            <> "until `loom-distill` is run by hand",
        ),
      ])
      builder
    }

    distillpass.DistillsOnBoot, Error(reason) -> {
      log.warn(logger, distillpass.failed_event, [
        field.text(key: "reason", value: reason),
        field.text(
          key: "effect",
          value: "no distillation pass runs on this boot; route a summarize "
            <> "or main model in the catalogue",
        ),
      ])
      builder
    }

    distillpass.DistillsOnBoot, Ok(distiller) ->
      sup.add(
        builder,
        distillpass.supervised(distillpass.Config(
          name:,
          // Derived from the store this boot protected rather than from
          // the session path again, so the pass writes the very sidecar
          // the run-start hook reads.
          directory: memory.directory_of(memory_store),
          distiller:,
          clock:,
          entropy:,
          wall_ms: settings.memory.wall_ms,
          logger:,
        )),
      )
  }
}

// The pipeline's provider surface, over the gateway this boot already
// routed. The same resolution `client/distill`'s own command performs
// from `--config`, reached through the catalogue rather than by parsing
// the file a second time.
fn distiller(settings: Settings) -> Result(distill.Distiller, String) {
  use dispatch <- result.map(distill.target(settings.gateway))
  distill.gateway_distiller(
    settings.gateway,
    dispatch,
    timeout_ms: distill.default_timeout_ms,
  )
}

fn with_model_door(
  options: schedulescan.Options,
  policy: schedule.Policy,
) -> schedulescan.Options {
  case schedule.policy_opens_the_door(policy) {
    True -> schedulescan.with_model_door_open(options)
    False -> options
  }
}

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
fn hook_coordinates(
  settings: Settings,
  seed: Int,
  clock: Clock,
  environment: List(#(String, String)),
) -> extension_hosts.Coordinates {
  let #(op_id, _generator) = ids.mint_op(ids.generator(clock, seed:))
  extension_hosts.Coordinates(
    op_id:,
    step_id: hook_step_id,
    // Attribution only: `hosts.Coordinates.strand` names the workspace
    // seam's reads, and a hook's are the session's rather than any one
    // strand's. The session's root strand is the honest name for that.
    strand: root_strand,
    workspace: settings.workspace,
    base_policy: settings.base_policy,
    demand: settings.demand,
    env: environment,
  )
}

/// The strand a hook's harness-side reads are attributed to.
const root_strand = "main"

/// The step every hook invocation clears under. One name, because the
/// hooks of a session are one long-running step rather than a sequence of
/// them, and the pooled budget follows the pair.
const hook_step_id = "extension-hooks"

/// The environment a session's jailed children inherit: the shell the
/// `bash` tool runs, a satellite, a hook host.
///
/// Allowlist-constructed and shared by the tool path and the hook path,
/// so a host launched by whichever came first is the same host. Three
/// names, each earned by a failure a live drive produced:
///
/// - `PATH` is the toolchain's when code mode found one, so `gleam` and
///   `erl` resolve in the shell exactly as they do for the compiler. On a
///   Homebrew Mac the system directories alone hide both, and a model
///   that cannot run the project's tests falls back to `find /`.
/// - `HOME` is the workspace. `bash -l` sources the dotfiles under
///   `$HOME`, and with the name unset it read the operator's profile
///   against an empty home and failed every line that mentioned it.
/// - `TMPDIR` is a directory under the workspace, the one root the jail
///   lets a tool write. The host's temp directory is not writable from
///   inside, so a compiler or test runner that mints temp files died on
///   its first one. Code mode pins its compiler's `TMPDIR` the same way.
///
/// ## Examples
///
/// ```gleam
/// assert serve.session_environment("/work", option.None)
///   == [
///     #("PATH", "/usr/local/bin:/usr/bin:/bin"),
///     #("HOME", "/work"),
///     #("TMPDIR", "/work/.codemode/tmp"),
///   ]
/// ```
///
@internal
pub fn session_environment(
  workspace: String,
  toolchain_path: Option(String),
) -> List(#(String, String)) {
  [
    #("PATH", option.unwrap(toolchain_path, "/usr/local/bin:/usr/bin:/bin")),
    #("HOME", workspace),
    #("TMPDIR", tool_tmp_directory(workspace)),
  ]
}

/// The whole environment a jailed tool shell of this session runs under:
/// the three names the server owns, then whatever the `[tools]` table
/// added.
///
/// The order is the guarantee. `session_environment`'s three names come
/// first and nothing after them may repeat one, because each is derived
/// from the workspace or from the toolchain this boot discovered and a
/// shell that took one from a config file would run against neither.
/// `client/catalog.parse_tools` refuses a table that names one, so the
/// order here is the second lock rather than the only one.
///
/// A configured name the host environment does not set is **skipped**,
/// and the skipped names come back beside the environment rather than
/// being logged from in here — this stays a decision about values, and
/// the caller owns the warning line. Skipping rather than refusing is
/// deliberate: an operator who lists `GH_TOKEN` on a machine that has
/// none has a `gh` that will not authenticate, and that is a better
/// thing to learn from one warned line and an in-band tool failure than
/// from a server that would not start.
///
/// ## Examples
///
/// ```gleam
/// // serve.tool_environment("/work", None, tools, reading: env_text)
/// // -> #([#("PATH", ..), #("HOME", ..), #("TMPDIR", ..), #("GH_TOKEN", ..)], [])
/// ```
///
@internal
pub fn tool_environment(
  workspace: String,
  toolchain_path: Option(String),
  tools: catalog.ToolsConfig,
  reading reading: fn(String) -> Result(String, Nil),
) -> #(List(#(String, String)), List(String)) {
  let owned =
    session_environment(workspace, toolchain_path)
    |> extending_path(tools.path)

  // A pass-through name settles one of two ways, so the fold carries
  // both answers: the pairs that were found, and the names that were not.
  let #(passed, unset) =
    list.fold(tools.env, #([], []), fn(state, name) {
      let #(found, missing) = state
      case reading(name) {
        Ok(value) -> #([#(name, value), ..found], missing)
        Error(Nil) -> #(found, [name, ..missing])
      }
    })

  // The literals come last, after the host reads, because a name cannot
  // be in both lists and the file's own order is the one an operator
  // reading it back expects.
  #(list.flatten([owned, list.reverse(passed), tools.set]), list.reverse(unset))
}

/// Where a jailed tool's `TMPDIR` points: beneath the code-mode work
/// directory the server already owns inside the workspace, so the
/// workspace gains no second dot-directory for it.
///
/// ## Examples
///
/// ```gleam
/// assert serve.tool_tmp_directory("/work") == "/work/.codemode/tmp"
/// ```
///
@internal
pub fn tool_tmp_directory(workspace: String) -> String {
  workspace <> "/" <> codemode_wiring.work_directory <> "/tmp"
}

// The policy meet keeps only the environment names the session base
// allows, and the base allows `PATH` and `HOME` but not `TMPDIR`. The
// bash tool passes `TMPDIR` (see `session_environment`), so the name is
// granted on the session base here — the same move the code-mode
// builder makes on its own derived base, for the same variable.
fn allowing_tool_tmpdir(base: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(list.append(base.env_allow, ["TMPDIR"])),
  )
}

// The operator's `path` entries go on the tail of the server's `PATH`:
// the toolchain and system directories stay in front, so the shell and
// the compiler resolve the same `gleam` and `erl`, and what follows is
// where the rest of the host's tools are found.
fn extending_path(
  environment: List(#(String, String)),
  extra: List(String),
) -> List(#(String, String)) {
  case extra {
    [] -> environment
    dirs ->
      list.map(environment, fn(pair) {
        case pair {
          #("PATH", value) -> #("PATH", value <> ":" <> string.join(dirs, ":"))
          other -> other
        }
      })
  }
}

/// The operator's `[tools]` table applied to the session base: the
/// network posture they chose, and every name their two lists mention
/// added to the environment allowlist.
///
/// The second half is what makes the first half reach a shell, and it is
/// exactly `allowing_tool_tmpdir`'s argument one table further on.
/// `policy.meet` intersects `env_allow`, and a jailed tool asks for
/// precisely the names in `Ctx.env` — so a variable that is in the
/// environment and not on the base's allowlist is a narrowing refusal
/// rather than a variable.
///
/// Public to this package for the reason `base_policy_fault` is: this is
/// a decision about a value, and it should be testable as one rather than
/// through a boot that has nowhere to hand its composed policy back.
///
/// ## Examples
///
/// ```gleam
/// // serve.under_tools_config(base, tools).network == policy.NetworkFull
/// ```
///
@internal
pub fn under_tools_config(
  base: policy.SandboxPolicy,
  tools: catalog.ToolsConfig,
) -> policy.SandboxPolicy {
  let configured =
    list.append(tools.env, list.map(tools.set, fn(pair) { pair.0 }))
  policy.SandboxPolicy(
    ..base,
    network: configured_network(tools.network),
    env_allow: list.unique(list.append(base.env_allow, configured)),
  )
}

// The catalogue's two-word posture as the policy lattice's own value.
// `NetworkProxy` is deliberately unreachable from here: the broker
// downgrades it to `NetworkOff` in phase 1 (`broker/policy`'s module
// doc), so a config word for it would promise host filtering that nothing
// on this path enforces.
fn configured_network(network: catalog.ToolNetwork) -> policy.NetworkPolicy {
  case network {
    catalog.ToolNetworkOff -> policy.NetworkOff
    catalog.ToolNetworkFull -> policy.NetworkFull
  }
}

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
fn stop_services(services: Pid) -> Nil {
  case process.is_alive(services) {
    False -> Nil
    True -> {
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
fn await_death(pid: Pid, remaining_ms: Int) -> Nil {
  let outcome: poll.Outcome(Nil, Nil) =
    poll.until(within: remaining_ms, every: 5, attempt: fn() {
      case process.is_alive(pid) {
        False -> poll.Done(Nil)
        True -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(Nil) -> Nil
    poll.Expired -> process.kill(pid)

    // The probe never fails outright; the arm is exhaustiveness.
    poll.Failed(Nil) -> Nil
  }
}

fn prepare_directories(
  settings: Settings,
  blob_root: String,
  tmp_dir: String,
  tool_tmp_dir: String,
) -> Result(Nil, String) {
  let wanted = [
    parent_directory(settings.session_path),
    parent_directory(settings.token_path),
    Some(settings.workspace),
    Some(blob_root),
    Some(tmp_dir),
    Some(tool_tmp_dir),
  ]
  list.try_each(option.values(wanted), fn(directory) {
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "could not create " <> directory <> ": " <> string.inspect(error)
    })
  })
}

fn parent_directory(path: String) -> Option(String) {
  case list.reverse(string.split(path, "/")) {
    [_file, ..rest] if rest != [] -> Some(string.join(list.reverse(rest), "/"))
    _ -> None
  }
}

// --- the search index ------------------------------------------------------

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
fn beside_session(settings: Settings, file: String) -> Result(String, String) {
  let path = case parent_directory(settings.session_path) {
    Some(directory) -> directory <> "/" <> file
    None -> file
  }
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

/// The base policy with the search index protected: never writable, by
/// any jailed process or by the harness's own write tools.
///
/// This is a security property rather than hygiene, and it is the same
/// argument the blob store's protection rests on one step further along.
/// Search snippets are read back into *future* sessions' contexts, so an
/// index a model can write is a channel from one execution's output into
/// a later execution's input — prompt injection with a persistence
/// layer. Writing is the whole of the poisoning path: `protected` bars
/// writes and leaves reads alone, which is exactly the asymmetry wanted,
/// since the harness's own indexing never goes through `resolve_writable`
/// and a model reading the file learns nothing it could not ask
/// `history_search` for.
///
/// ## Examples
///
/// ```gleam
/// // serve.protecting_index(base, "/data/loom-search.db").protected
/// ```
///
pub fn protecting_index(
  base: policy.SandboxPolicy,
  index_path: String,
) -> policy.SandboxPolicy {
  // The whole SQLite file family, not the database alone (see
  // `sqlite_side_files`), enumerated rather than protected as a
  // directory because the index sits beside the session file, where a
  // protected directory would swallow paths the operator owns. The
  // database itself is always protected: the boot's probe creates it.
  // The side files are conditional, on the argument `protecting` states.
  protecting(
    base,
    always: [index_path],
    where_writable: sqlite_side_files(index_path),
  )
}

/// The base policy with this repository's memory protected: the digest
/// sidecar the server injects at every run start, and the store the
/// digest is rendered from.
///
/// The same argument `protecting_index` makes, one step further along
/// and one degree more direct. A search snippet reaches a later session
/// only if a model searches for it; the memory digest is injected into
/// **every** run of every session on this repository, unasked. A
/// model-writable digest would therefore be the cleanest prompt-injection
/// channel in the tree.
///
/// Both files are conditional, and unlike the index this is not a
/// refinement but a requirement: neither exists until a distillation run
/// has happened, and the jail refuses to mask a *missing* protected path
/// under a read-only parent — the failure that once turned the index's
/// side-file list into a refusal of every jailed call. Where no writable
/// root reaches the directory there is nothing to protect against
/// anyway, because the harness fs tools are workspace-contained and the
/// jail makes a file under a read-only parent uncreatable.
///
/// The wrapper is the other half of this bargain and does not depend on
/// it: `client/memory.wrapped` builds the fence and the attribution at
/// injection time, so even a digest somebody managed to write cannot
/// claim to be operator text.
///
/// ## Examples
///
/// ```gleam
/// // serve.protecting_memory(base, "/d/loom-memory.db", "/d/loom-memory.digest")
/// ```
///
pub fn protecting_memory(
  base: policy.SandboxPolicy,
  store_path: String,
  digest_path: String,
) -> policy.SandboxPolicy {
  protecting(base, always: [], where_writable: [
    store_path,
    digest_path,
    ..sqlite_side_files(store_path)
  ])
}

// The whole SQLite file family beside a database: it runs in WAL mode,
// so `-wal` and `-shm` live beside it and a write to either is the same
// poisoning door one filename to the right — WAL frame checksums are not
// cryptographic, so a crafted `-wal` is served as content on the next
// read. `-journal` covers the rollback fallback a failed WAL pragma
// leaves.
fn sqlite_side_files(path: String) -> List(String) {
  [path <> "-wal", path <> "-shm", path <> "-journal"]
}

// The one conditional-protection mechanism, shared by the index and by
// memory rather than copied for each.
//
// `always` is for paths that certainly exist by the time a jail is
// built — the index database, which the boot's probe creates — because
// masking an existing file needs nothing from its parent.
// `where_writable` is for everything else, and the condition is the
// threat model rather than a convenience: a protected path that does not
// exist under a read-only parent is one the jail refuses to mask, which
// is a refusal of every jailed call, while a path no writable root
// reaches has no write path to bar in the first place.
//
// The residual is stated rather than hidden: an approval granting a
// writable root over the session's own directory reopens the conditional
// door — and already exposes the unprotected session file itself, which
// is the larger half of that decision.
fn protecting(
  base: policy.SandboxPolicy,
  always always: List(String),
  where_writable conditional: List(String),
) -> policy.SandboxPolicy {
  let reachable =
    list.filter(conditional, fn(path) {
      writable_reaches(base, parent_of(path))
    })
  policy.SandboxPolicy(
    ..base,
    protected: list.flatten([
      always,
      reachable,
      base.protected,
    ]),
  )
}

// Whether any writable root covers `directory` — the question of
// whether a jailed or harness-side write could create a file there.
fn writable_reaches(base: policy.SandboxPolicy, directory: String) -> Bool {
  list.any(base.writable_roots, fn(root) {
    policy.covers(root: root, path: directory)
  })
}

// The directory holding a path: everything before the last slash. The
// index path is absolute by construction (`index_path` resolves it), so
// there is always a slash to find.
fn parent_of(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_leaf, ..parents] -> parents |> list.reverse |> string.join("/")
    [] -> path
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
fn history_seam(
  index_path: String,
  name: process.Name(history.Message),
  logger: Logger,
) -> Option(history_tool.History) {
  case history.probe(index_path) {
    Ok(Nil) -> {
      log.info(logger, "history.ready", [
        field.text(key: "index", value: index_path),
      ])
      Some(history.seam(name, timeout_ms: history.default_timeout_ms))
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
// `memory.probe`): a boot that opened the store would be the very theft
// `memory.run_lease_ttl_ms` exists to prevent, arriving mid-run and
// stealing a distillation's expired lease.
fn memory_seam(
  store_path: String,
  clock: Clock,
  entropy: fn() -> Int,
  logger: Logger,
) -> Option(remember.Memory) {
  case memory.probe(store_path) {
    Ok(Nil) -> {
      log.info(logger, "memory.ready", [
        field.text(key: "store", value: store_path),
      ])
      Some(memory.remember_seam(store_path, clock:, entropy:))
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
fn history_subscribers(
  seam: Option(history_tool.History),
  pulls: process.Name(writer.Event),
) -> List(Subject(writer.Event)) {
  case seam {
    None -> []
    Some(_seam) -> [process.named_subject(pulls)]
  }
}

// The holder and its commit subscriber, added to the service tree only
// when this host has an index for them to serve.
fn with_history(
  tree: sup.Builder,
  seam: Option(history_tool.History),
  config: history.Config,
  pulls: process.Name(writer.Event),
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

/// How long the boot waits on the helper it spawns to ask whether this
/// host can confine anything. Above the pool's own handshake timeout, so
/// the helper actor has always settled into ready or dead by the time the
/// answer is due and the call cannot outrun it.
pub const helper_probe_ms = 15_000

// Renders the prompt for a session that has none pinned yet. Everything
// expensive lives behind this thunk — the pack file, the session's
// instruction files, and the helper spawn the degraded question needs —
// so a resumed session pays for none of it.
//
// The operator's home comes off `Settings` rather than out of the process
// environment, so the lookup of the global `AGENTS.md` is a pure function
// of its arguments and a test can stand a server up that never reads the
// machine's real home.
fn render_prompt(
  settings: Settings,
  base_policy: policy.SandboxPolicy,
  pool: Pool,
  tools: List(String),
  available_tools: List(String),
) -> Result(system_prompt.Rendered, String) {
  let #(guidance, notes) =
    system_prompt.guidance(workspace: settings.workspace, home: settings.home)
  use #(origin, source) <- result.try(
    system_prompt.pack_source(
      option.from_result(env_text(system_prompt.pack_path_variable)),
    ),
  )
  use rendered <- result.try(system_prompt.render_pack(
    origin,
    source,
    system_prompt.Host(
      workspace: settings.workspace,
      platform: ffi_os.platform(),
      shell: shell_path,
      tools:,
      available_tools:,
      demand: settings.demand,
      degraded: degraded(pool),
      base_policy:,
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

/// Whether this host's helper advertises degraded enforcement, asked once
/// at session open by borrowing a helper from the pool the session will
/// use anyway. The system prompt has no other source for it: the
/// per-layer `skip:` report lives inside an `ExecResult`, which is after
/// a run, and the `ENFORCED`/`SKIPPED` table is a separate `--self-test`
/// process invocation.
///
/// A helper that will not spawn, or will not finish its handshake, is
/// reported as degraded — which is what it behaves as: under
/// `FullEnforcement` every jailed execution against it fails, and the
/// pack's degraded fragment says exactly that.
///
/// ## Examples
///
/// ```gleam
/// // serve.degraded(pool) == False   // a healthy loom-exec
/// ```
///
pub fn degraded(pool: Pool) -> Bool {
  case exec.checkout(pool, waiting: helper_probe_ms) {
    Error(_unavailable) -> True
    Ok(helper) -> {
      let answer = case exec.await_ready(helper, waiting: helper_probe_ms) {
        Ok(features) -> list.contains(features, "degraded")
        Error(_dead) -> True
      }
      exec.checkin(pool, helper)
      answer
    }
  }
}

/// The shell every jailed command runs under, and the shell the system
/// prompt tells the agent about. One constant so the two cannot drift:
/// a prompt that named a shell the helper does not use would be a lie
/// the agent could only discover by writing a broken command.
pub const shell_path = "/bin/sh"

/// The default session base policy: workspace writable, the whole
/// filesystem readable (interpreters live outside the workspace —
/// spec-gaps WP-I item 3), network off. Escalations widen it per
/// approval. This is what `main` puts in `Settings.base_policy`; a host
/// that supplies its own may serve a narrower one.
///
/// ## Examples
///
/// ```gleam
/// // serve.base_policy("/work").writable_roots == ["/work"]
/// ```
///
pub fn base_policy(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: ["/"],
    // The blob store is content-addressed, and an address is only worth
    // something if nothing can be reached under it but the content it
    // names — which a jailed `proc.run` inside the writable workspace
    // could otherwise defeat by pre-planting bytes at a future address.
    // Protecting the directory masks it from every jail; the harness's
    // own blob writes never pass `resolve_writable`, so they cost
    // nothing, and the bridge's `fs.write` is refused there, correctly.
    protected: [workspace <> "/" <> codemode_wiring.blob_directory],
  )
}

/// Why this server will not boot on the base policy it was given, worded
/// for the operator who wrote it.
///
/// `Settings.base_policy` is a *field*, so a host may serve any policy
/// value it can construct — and a policy the effect plane cannot
/// enforce is one this server must refuse to start on rather than start
/// and enforce differently in different places. The three checks are
/// `broker/policy.validate`'s, which is also the check every composed
/// policy passes immediately before dispatch, so what is refused here is
/// exactly what would be refused there.
///
/// A **relative `protected` entry** is the one worth naming. It reaches
/// the jail as `RelativePath` and refuses the clearance, loudly; it
/// reaches `tools/fs.resolve_writable` as a list nothing can be judged
/// against, which now refuses in band rather than covering nothing. Two
/// enforcement points agreeing to refuse is correct and still the wrong
/// place to learn about it — the operator finds out from the first tool
/// call of a live session, having been told nothing at boot. So the
/// value is checked once, before anything is spawned, and the server
/// does not come up.
///
/// Pure, and separate from `boot` for that reason: this is a decision
/// about a value, and it should be testable as one.
///
/// ## Examples
///
/// ```gleam
/// assert serve.base_policy_fault(serve.base_policy("/work")) == Ok(Nil)
/// ```
///
pub fn base_policy_fault(base: policy.SandboxPolicy) -> Result(Nil, String) {
  policy.validate(base)
  |> result.map_error(fn(error) {
    "the session base policy is not one the sandbox can enforce: "
    <> policy_fault_text(error)
  })
}

fn policy_fault_text(error: policy.PolicyError) -> String {
  case error {
    policy.RelativePath(path:) ->
      "the path `"
      <> path
      <> "` is not absolute. Every writable root, readable root and "
      <> "protected entry must start with `/` — a relative protected "
      <> "entry is refused by the jail and covers nothing in the "
      <> "harness's own path checks, so it would protect nothing while "
      <> "looking as though it did"
    policy.NegativeLimit(field:, value:) ->
      "the limit `"
      <> policy.limit_field_name(field)
      <> "` is "
      <> int.to_string(value)
      <> ", and a resource ceiling cannot be negative (use 0 for "
      <> "unlimited)"
    policy.ScratchIsRoot ->
      "scratch names the host root `/`. Landlock has no deny rules, so a "
      <> "host-path scratch of `/` grants read-write over the whole "
      <> "filesystem at that layer whatever the mount layer does"
  }
}

// How this session reaches its schedule store, or `None` when the
// operator shut the door — which registers none of the three tools and
// routes none of the three capabilities, rather than offering doors that
// always refuse. A tool definition is not free: it renders into the
// provider's cached byte prefix and is paid for on every request, which
// is the same argument `memory_seam` and `history_seam` are gated by,
// and an unrouted capability is a clearer answer to a program than one
// that exists and says no.
fn schedule_wiring(
  settings: Settings,
  agency_config: agency.Config,
  scanner: Name(schedulescan.Message),
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
fn with_schedule_admin(
  options: hub.Options,
  admin: Option(scheduleadmin.Admin),
) -> hub.Options {
  case admin {
    None -> options
    Some(admin) -> hub.with_schedules(options, admin)
  }
}

// The schedule reap, added to a hook record only when this session has a
// scheduling plane at all. `Option.map` would answer an `Option(Hooks)`
// and every caller would then have to unwrap it back to the hooks it
// started with, which is the shape this small function exists to keep out
// of the composition pipeline above.
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
fn seed_root(flag: Option(String), workspace: String) -> String {
  let in_workspace = workspace <> "/" <> default_seed_directory
  seed_ladder(
    flag,
    in_workspace: fn() { install.existing_directory(in_workspace) },
    bundled: install.bundled_seed,
    otherwise: in_workspace,
  )
}

// One entropy seam serves two masters: id seeds must never repeat
// within a session lifetime (spec-gaps WP-E item 6) and the bearer
// token must be unguessable. A VM-unique monotonic integer gives the
// first; 64 bits of `crypto:strong_rand_bytes` in the low limb give
// the second (the token minter keeps only low bits). The sum is
// injective in the pair, so uniqueness survives the mixing.
fn mixed_entropy() -> fn() -> Int {
  let random_bytes = token.production_entropy()
  fn() {
    let unique = ffi_os.unique_positive_integer()
    case random_bytes(8) {
      <<random:size(64)>> -> unique * 18_446_744_073_709_551_616 + random
      _ -> unique
    }
  }
}
