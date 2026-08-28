//// The session server: the production host the wiring adapter was
//// promoted for. `gleam run -m client/serve -- --session path.db`
//// (or the erlang shipment's `bin/loom-server`) opens or creates one
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
//// - `--best-effort` — accept a degraded sandbox helper (development
////   kernels without bwrap/Landlock). The default demands full
////   enforcement, under which a degraded helper is refused at dispatch
////   — the server still runs, tool calls fail in-band. Run
////   `make selftest` to learn which posture your kernel supports.
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
//// Assembled once, at the first open of a session, and pinned into the
//// reserved `prompt/` blackboard cell; every later boot sends the pinned
//// bytes rather than deriving them again. `client/system_prompt` owns
//// the whole story, including why re-deriving would be expensive. Two
//// environment variables reach it:
////
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
////   `loom-server`.
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
//// **Restartable** — the commit forwarder, the Agency holder, and the
//// gateway hub, under `Booted.services` (one-for-one, three restarts in
//// five seconds). None of the three is addressed by pid: the forwarder
//// is the writer's subscriber by name, the Agency's tool seam borrows
//// the runtime through the holder's name, and the listener, the
//// forwarder, and the provider tap all reach the hub through the
//// gateway name. A replacement under the same name is therefore the
//// same address, and a crash costs a moment of hints and the sockets
//// already attached to the old hub — clients reconnect — rather than
//// the whole server. A spent restart budget is fatal, in order.
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
import broker/exec.{type EnforcementDemand, type Pool}
import broker/policy
import broker/token
import client/agency
import client/catalog
import client/codemode as codemode_wiring
import client/escalate
import client/gateway as hub
import client/history
import client/host
import client/install
import client/internal/ffi_os
import client/mcp as mcp_wiring
import client/notes
import client/scratch
import client/server
import client/summaries
import client/system_prompt
import client/wiring
import core/clock.{type Clock}
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
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
import tools/bash
import tools/codemode as codemode_tool
import tools/fs
import tools/grep
import tools/history as history_tool
import tools/tool.{type Registry}

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
      io.println_error("loom-server: " <> reason)
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
    // nonzero so whatever runs `loom-server` restarts it.
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
    "loom-server: session "
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
    "loom-server: system prompt "
    <> system_prompt.named(booted.prompt.origin)
    <> ", digest "
    <> booted.prompt.digest,
  )
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
    best_effort: Bool,
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
      best_effort: False,
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
      parse_loop(rest, Flags(..flags, best_effort: True))
    [unknown, ..] -> Error("unknown argument `" <> unknown <> "`\n" <> usage)
  }
}

const usage = "usage: loom-server --session <path.db>
  [--bind <host:port>]     listen interface (default 127.0.0.1:0)
  [--token-file <path>]    bearer token file (default <session>.token)
  [--workspace <dir>]      workspace root (default the current directory)
  [--helper <path>]        loom-exec binary (default: beside this server, then PATH, then ./bin)
  [--config <loom.toml>]   model catalogue file (default: LOOM_* env vars)
  [--codemode-seed <dir>]  code-mode build seed (default <workspace>/build/codemode-seed, then the bundled one)
  [--codemode-seams <s>]   code-mode seams: workspace, orchestration, both (default workspace)
  [--best-effort]          accept a degraded sandbox helper"

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
  use catalogue <- result.try(load_catalog(flags.config))
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
    demand: case flags.best_effort {
      True -> exec.BestEffort
      False -> exec.FullEnforcement
    },
    gateway: catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret.env(),
      clock:,
    ),
    catalog: catalogue,
    system: option.from_result(env_text(system_prompt.override_variable)),
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
  ))
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
  }
}

// The catalogue ladder: an explicit file must load and validate or the
// boot refuses (a typoed config silently ignored would serve the wrong
// model); no file falls back to the environment surface.
fn load_catalog(flag: Option(String)) -> Result(catalog.Catalog, String) {
  case flag {
    None -> Ok(env_catalog())
    Some(path) ->
      case simplifile.read(path) {
        Error(error) ->
          Error(
            "the config file "
            <> path
            <> " is unreadable: "
            <> string.inspect(error),
          )
        Ok(text) ->
          catalog.parse(text)
          |> result.map_error(fn(reason) { path <> ": " <> reason })
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
  <> "`make binaries`, or run the `bin/loom` of an unpacked release, "
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
) -> #(Option(codemode_tool.CodeMode), mcp_wiring.Layer) {
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
          // The MCP layer widens the workspace seam's allowlist, its
          // description and its router together; an empty layer widens
          // nothing, so this is unconditional.
          |> codemode_wiring.over_mcp(layer)
          |> codemode_wiring.seam,
        ),
        layer,
      )
    }
  }
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
  let base_policy = protecting_index(settings.base_policy, index_path)
  // Before a directory is made, a lease is taken or a helper is spawned:
  // a base policy the sandbox cannot enforce is a boot failure, not a
  // surprise waiting in the first tool call. See `base_policy_fault`.
  use Nil <- result.try(base_policy_fault(base_policy))
  let blob_root = settings.workspace <> "/" <> codemode_wiring.blob_directory
  let tmp_dir = settings.session_path <> ".tmp"
  use Nil <- result.try(prepare_directories(settings, blob_root, tmp_dir))
  // One clock function, therefore one era, across session, broker,
  // tools, and provider — the shared-clock requirement the M2
  // integration learned live (spec-gaps, M2 item 1).
  let clock = clock.from_function(ffi_os.system_time_ms)
  let entropy = mixed_entropy()
  use opened <- result.try(
    session.open_sqlite(
      path: settings.session_path,
      owner: "loom-server",
      lease_ttl_ms: 60_000,
      clock:,
    )
    |> result.map_error(fn(error) {
      "the session did not open (held lease? bad path?): "
      <> string.inspect(error)
    }),
  )
  // The effect plane: a pool of jailed helpers behind the one broker.
  let spawn_config =
    exec.SpawnConfig(
      helper_path: settings.helper_path,
      shell_path:,
      base_policy:,
      // The server never opts out of enforcement on the caller's behalf:
      // on a platform with no jail the helper refuses to serve, which is
      // the refusal `--allow-unenforced` exists to make deliberate.
      helper_args: [],
      tmp_dir:,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  use pool <- result.try(
    exec.start_pool(size: settings.helper_pool_size, spawn: fn() {
      exec.spawn_helper(spawn_config)
    })
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
  // The orchestration plane: runtime over the production wiring, with
  // the hub's two composition seams — commit hints in, provider deltas
  // teed out — threaded through before `api.open`.
  let name = process.new_name(prefix: "loom_gateway")
  // The forwarder itself starts later, under the service supervisor.
  // Only its *name* is needed here, because that is what the writer
  // subscribes to — a subscription by name is what lets the forwarder be
  // restarted without the writer noticing.
  let forwarder_name = process.new_name(prefix: "loom_forwarder")
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
  let #(code_mode, mcp_layer) =
    code_mode_seam(
      settings,
      logger,
      broker_actor,
      clock,
      agency_seam,
      scratch.seam(scratch_name, timeout_ms: scratch.default_timeout_ms),
    )
  // Recall, on the same two-name pattern and gated the same way: the
  // holder that owns the index cannot exist until the runtime has been
  // opened (its canonical session id is what a scoped query and every
  // hit from this session are named by), so the tool seam closes over
  // the name now and the holder starts under it further down. An index
  // that will not open registers no tool at all.
  let history_name = process.new_name(prefix: "loom_history")
  let history_pulls = process.new_name(prefix: "loom_history_pulls")
  let history_seam = history_seam(index_path, history_name, logger)
  // One registry serves two masters: the effect wiring dispatches
  // through it, and the hub validates `set_config active_tools` against
  // it. They must be the same registry or the check means nothing.
  let tool_registry = registry(Some(agency_seam), code_mode, history_seam)
  // The registry itself, once, at boot. Three planes decide their own
  // presence from the host they found — a messaging plane, a code-mode
  // pipeline, a search index — so "which tools does this server actually
  // offer" is not derivable from the flags, and it is the same sorted
  // list that renders into the provider's cached byte prefix. Naming it
  // here is what lets a release smoke assert on registration rather than
  // on a proxy for it.
  log.info(logger, "server.tools", [
    field.text(key: "names", value: string.join(tool.names(tool_registry), ",")),
  ])
  // The system prompt, before the open, because `wiring.Config` needs
  // the string and `api.open` is what stands the writer up. The pinned
  // cell is therefore read straight off the store here — legal, nothing
  // owns it yet — and written back through the writer after the open.
  use pinned <- result.try(system_prompt.pinned_in(opened))
  use assembled <- result.try(
    system_prompt.assemble(pinned:, override: settings.system, render: fn() {
      render_prompt(settings, base_policy, pool, tool.names(tool_registry))
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
      env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")],
      clock:,
      entropy:,
    ))
  let effects_record =
    effects.Effects(
      ..built,
      provider: hub.tap_provider(built.provider, to: name),
      // The only work this adds on the driver process is one
        // `process.spawn_unlinked`; everything a reap actually does happens
        // on that spawned process. See `client/agency`. The notes digest
        // wraps the result rather than replacing a slot, so the two
        // compose instead of one silently dropping the other.
        hooks: agency.reaping_hooks(built.hooks, agency_config)
        |> notes.digest_hooks(opened, clock),
    )
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
        // Two subscribers, both by name, both restartable: the hub's
        // hint forwarder, and — when this host has an index — the poke
        // that drives search sync. The second is what makes recall a
        // *commit*-driven projection rather than a scheduled sweep; a
        // poke lost while its subscriber restarts costs latency, never a
        // row, because `search.sync`'s own durable cursor decides what
        // gets indexed.
        subscribers: [
          process.named_subject(forwarder_name),
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
  // bytes every strand of this session will send, recorded durably so the
  // next boot reads them rather than deriving them again from inputs that
  // may have moved.
  use Nil <- result.try(system_prompt.pin(runtime, assembled))
  // The restartable half of the per-child policy. These three hold no
  // state a restart cannot rebuild and — crucially — none of them is
  // addressed by pid: the forwarder is the writer's subscriber by name,
  // the Agency's tool seam borrows the runtime through the holder's
  // name, and the listener, the forwarder, and the provider tap all
  // reach the hub through `name`. So a replacement under the same name
  // is the same address, and a crash here costs a moment of hints and
  // the sockets already attached to the old hub rather than the server.
  // One-for-one because they are independent: nothing in the three
  // reaches another except through a name.
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
    |> sup.add(
      supervision.worker(fn() {
        hub.start(
          hub.default_options(settings.session_id, runtime)
            |> hub.with_catalog(settings.catalog)
            |> hub.with_registry(tool_registry),
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
  ))
}

/// Takes a booted server apart, front to back: the listener first so no
/// new client arrives mid-teardown, then the service supervisor (hub,
/// Agency holder, commit forwarder), then the runtime — whose close
/// stops the strand drivers before the writer they commit through and
/// releases the session lease — and finally the effect plane, broker
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
  stop_services(booted.services)
  let _closed = api.close(booted.runtime)
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

fn await_death(pid: Pid, remaining_ms: Int) -> Nil {
  case process.is_alive(pid) {
    False -> Nil
    True ->
      case remaining_ms <= 0 {
        True -> process.kill(pid)
        False -> {
          process.sleep(5)
          await_death(pid, remaining_ms - 5)
        }
      }
  }
}

fn prepare_directories(
  settings: Settings,
  blob_root: String,
  tmp_dir: String,
) -> Result(Nil, String) {
  let wanted = [
    parent_directory(settings.session_path),
    parent_directory(settings.token_path),
    Some(settings.workspace),
    Some(blob_root),
    Some(tmp_dir),
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
  let path = history.index_beside(settings.session_path)
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(here) { here <> "/" <> path })
      |> result.map_error(fn(error) {
        "the working directory is unreadable, so the search index has no "
        <> "absolute path: "
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
  policy.SandboxPolicy(..base, protected: [index_path, ..base.protected])
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
// expensive lives behind this thunk — the pack file, the workspace's
// `CLAUDE.md`, and the helper spawn the degraded question needs — so a
// resumed session pays for none of it.
fn render_prompt(
  settings: Settings,
  base_policy: policy.SandboxPolicy,
  pool: Pool,
  tools: List(String),
) -> Result(system_prompt.Rendered, String) {
  let #(guidance, notes) = system_prompt.guidance(settings.workspace)
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

/// The tool registry: the five core tools, plus the six `agent_*` tools
/// when this host wired a messaging plane, plus `code_mode` when it wired
/// a code-mode pipeline, plus `history_search` when its search index
/// opened.
///
/// Registration is gated on the seam existing rather than the tools being
/// registered unconditionally and refusing at call time, and the reason
/// is arithmetic rather than tidiness: the wire tool array is built from
/// this registry, renders ahead of the system prompt, and is the byte
/// prefix of the provider's cached region — so permanently-refusing
/// definitions would be paid for on every request of every strand for the
/// life of the session. A host with none of the three simply has five
/// tools.
///
/// ## Examples
///
/// ```gleam
/// // tool.lookup(serve.registry(option.None, option.None, option.None), "bash")
/// ```
///
pub fn registry(
  agency: Option(agent.Agency),
  code_mode: Option(codemode_tool.CodeMode),
  history: Option(history_tool.History),
) -> Registry {
  tool.registry(
    list.flatten([
      [
        bash.tool(),
        grep.tool(),
        fs.read_tool(),
        fs.write_tool(),
        fs.edit_tool(),
      ],
      case agency {
        None -> []
        Some(agency) -> agent.tools(agency)
      },
      case code_mode {
        None -> []
        Some(code_mode) -> codemode_tool.tools(code_mode)
      },
      case history {
        None -> []
        Some(history) -> [history_tool.tool(history)]
      },
    ]),
  )
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
