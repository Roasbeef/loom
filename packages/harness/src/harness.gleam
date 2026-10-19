//// Embedding loom's session runtime in another program.
////
//// `runtime/api.open` takes a `Session` and an `Effects` record, and the
//// `Effects` record needs a provider half: the routing and admission which
//// turn a request into a gateway call. That half used to live inside the
//// daemon (`client/wiring`), so an application which wanted to run a session
//// in its own process had to depend on the whole of `client` or fork the
//// routing. This package is that half without the daemon (issue #1030,
//// `docs/design-notes/harness-extraction.md`).
////
//// ## The embedding contract
////
//// An embedder owns four things and `harness` supplies the rest.
////
//// 1. **A gateway**, built with `provider/gateway`: the providers, the role
////    routes and their fallback chains. `new` refuses one which does not
////    route the `Main` role.
//// 2. **A tool registry** (`tools/tool.registry`) of `tool.Tool` records. A
////    tool's `run` closes over whatever it needs, such as a per-job grant.
////    A tool which returns `tool.terminate()` ends the run, which is how a
////    "submit" tool says the job is done.
//// 3. **A session**, `session.open_memory` for a run which leaves nothing on
////    disk, and a system prompt of the embedder's own.
//// 4. **A supervisor** it starts the session under. `runtime/api.open` links
////    the session's tree to its caller, so the caller's own supervision
////    decides what a crash costs.
////
//// ```gleam
//// let assert Ok(config) =
////   harness.new(harness.settings(
////     gateway:, session:, registry:, clock:, fallback:,
////     tools: harness.Embedded(workspace: "/work", blob_root: "/work/.blobs"),
////   ))
//// let assert Ok(runtime) = harness.open(config, api.default_options(strand))
//// let assert Ok(operation) = api.prompt(runtime, [user_message])
//// let assert Ok(result) = api.await_result(runtime, operation, within_ms: 60_000)
//// ```
////
//// `test/harness/embedding_test.gleam` runs exactly this, with a custom tool,
//// a terminating `submit` tool, a custom system prompt and an in-memory
//// session, against a scripted provider.
////
//// ## Defaults
////
//// `effects` installs the runtime's default hooks with two slots replaced:
//// `admission` (the facts-driven decision, including the vision rule) and
//// `resolution` (does the gateway still route the role). That means no
//// compaction, no run-start injection and no escalation channel: a tool which
//// would need approval settles its refusal in band. Compaction in the daemon is
//// a notes checkpoint (`client/checkpoint`), which belongs to the daemon.
////
//// ## Two doors
////
//// `new` is the typed front door and refuses what the daemon would turn into
//// an in-band `model_unavailable` at run time. `harness/provider.new` is the
//// floor under it, with no checks, and is what `client/wiring` builds from its
//// own `Config`: the daemon's behaviour must not change, and some of its
//// fixtures assemble a gateway which routes only part of the roles.
////
//// ## Flow
////
//// `settings` fills the defaults, `new` validates them into a `HarnessConfig`
//// (`routed` asks the gateway about the role, `positive` checks a limit and
//// `absolute` a path), and `effects` assembles the record. `random_entropy` is the unique-seed
//// source a host may use, and `embedded_context` is the tool context an
//// `Embedded` host runs its tools under.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import core/clock.{type Clock}
import gleam/option.{type Option, None}
import harness/admission
import harness/model_facts.{type Fallback}
import harness/provider.{type Provider}
import harness/routing.{Routing}
import harness/tool_table
import provider/gateway.{type Gateway}
import provider/model.{type Role}
import runtime/api
import runtime/effects.{type Effects}
import runtime/hooks
import session/session.{type Session}
import tools/directory_access
import tools/fs
import tools/tool.{type Registry}

/// Where an embedder's tools run, and what context they run under.
pub type Tools {
  /// Tools run in this VM under a context with no broker: `clear_call`
  /// refuses every jailed execution and every policy refusal settles in band.
  /// The right choice for tools which are plain Gleam functions, such as a
  /// grant-checked lookup or a `submit` tool.
  ///
  /// Constructor invariants: both paths are absolute. A tool which reads files
  /// resolves relative paths against `workspace`, and large outputs overflow
  /// into `blob_root`.
  Embedded(workspace: String, blob_root: String)

  /// Tools run under a context the embedder builds for each call, for a host
  /// which has its own broker or filesystem seam.
  Hosted(context: fn(effects.ToolRun) -> tool.Ctx)
}

/// Everything `new` needs, with the defaults filled in by `settings`.
///
/// This is plain data so that a caller can override one field with record
/// update syntax; `new` is where the combination is judged.
pub type Settings {
  Settings(
    /// The provider gateway, fully routed.
    gateway: Gateway,
    /// The session the runtime will open. Read for image classification, so
    /// the runtime must be opened over this same session: `open` does that,
    /// and a plain `api.open` must be handed this value, never another. A
    /// different session would classify images and measure windows against
    /// the wrong store without any error.
    session: Session,
    /// The tools the model may call.
    registry: Registry,
    /// Where those tools run.
    tools: Tools,
    /// The injected time source.
    clock: Clock,
    /// Fresh id-generator seeds. Values must never repeat within a session;
    /// `random_entropy` is the default.
    entropy: fn() -> Int,
    /// The system prompt sent with every generation, if any.
    system: Option(String),
    /// The role `resolution` asks the gateway about. `Main` for a
    /// single-model session.
    role: Role,
    /// The identity-keyed model facts. `model_facts.no_facts()` accounts every
    /// identity against `fallback`.
    lookup: model_facts.Lookup,
    /// The figures for an identity the lookup does not know.
    fallback: Fallback,
    /// How long the effect process waits for a provider terminal event.
    provider_timeout_ms: Int,
  )
}

/// Why `new` refused a configuration.
pub type ConfigError {
  /// The gateway has no usable route for this role, so the first request
  /// would settle `model_unavailable`.
  RoleUnrouted(role: Role)

  /// A limit which must be positive was not. The name is the `Settings`
  /// field, or the `Fallback` field spelled `fallback.<field>`.
  InvalidLimit(name: String)

  /// A path which must be absolute was not.
  RelativePath(path: String)
}

/// A validated configuration. Opaque: the only way to hold one is `new`.
pub opaque type HarnessConfig {
  HarnessConfig(
    provider: Provider,
    registry: Registry,
    clock: Clock,
    entropy: fn() -> Int,
    context: fn(effects.ToolRun) -> tool.Ctx,
    provider_timeout_ms: Int,
  )
}

/// Settings for the common case: the `Main` role, no model facts beyond the
/// fallback, a random entropy source, no system prompt and a ten minute
/// provider timeout.
///
/// ## Examples
///
/// ```gleam
/// // harness.settings(gateway:, session:, registry:, clock:, fallback:, tools:)
/// ```
///
pub fn settings(
  gateway gateway: Gateway,
  session session: Session,
  registry registry: Registry,
  clock clock: Clock,
  fallback fallback: Fallback,
  tools tools: Tools,
) -> Settings {
  Settings(
    gateway:,
    session:,
    registry:,
    tools:,
    clock:,
    entropy: random_entropy(),
    system: None,
    role: model.Main,
    lookup: model_facts.no_facts(),
    fallback:,
    provider_timeout_ms: 600_000,
  )
}

/// Judges a set of settings, refusing every combination the daemon would
/// reject at run time.
///
/// The role must resolve to a usable chain, the fallback window, the fallback
/// ceiling and the provider timeout must be positive, and an `Embedded`
/// workspace and blob root must be absolute.
///
/// ## Examples
///
/// ```gleam
/// // harness.new(settings) == Error(harness.RoleUnrouted(model.Main))
/// ```
///
pub fn new(settings: Settings) -> Result(HarnessConfig, ConfigError) {
  use _routed <- try(routed(settings.gateway, settings.role))
  use _window <- try(positive(
    "fallback.context_window",
    settings.fallback.context_window,
  ))
  use _ceiling <- try(positive(
    "fallback.max_output_tokens",
    settings.fallback.max_output_tokens,
  ))
  use _timeout <- try(positive(
    "provider_timeout_ms",
    settings.provider_timeout_ms,
  ))
  use context <- try(context_for(settings.tools, settings.clock))

  let routing =
    Routing(
      gateway: settings.gateway,
      role: settings.role,
      lookup: settings.lookup,
      fallback: settings.fallback,
    )

  Ok(HarnessConfig(
    provider: provider.new(
      routing,
      settings.session,
      system: settings.system,
      registry: settings.registry,
    ),
    registry: settings.registry,
    clock: settings.clock,
    entropy: settings.entropy,
    context:,
    provider_timeout_ms: settings.provider_timeout_ms,
  ))
}

// `result.try` under a short name, so the checks above read as a column.
fn try(
  result: Result(a, ConfigError),
  then: fn(a) -> Result(b, ConfigError),
) -> Result(b, ConfigError) {
  case result {
    Ok(value) -> then(value)
    Error(error) -> Error(error)
  }
}

fn routed(provider_gateway: Gateway, role: Role) -> Result(Nil, ConfigError) {
  case gateway.resolve(provider_gateway, role) {
    Ok(_resolved) -> Ok(Nil)
    Error(_missing) -> Error(RoleUnrouted(role:))
  }
}

fn positive(name: String, value: Int) -> Result(Nil, ConfigError) {
  case value > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidLimit(name:))
  }
}

fn context_for(
  tools: Tools,
  clock: Clock,
) -> Result(fn(effects.ToolRun) -> tool.Ctx, ConfigError) {
  case tools {
    Hosted(context:) -> Ok(context)
    Embedded(workspace:, blob_root:) ->
      case absolute(workspace), absolute(blob_root) {
        True, True -> Ok(embedded_context(workspace, blob_root, clock))
        False, _ -> Error(RelativePath(path: workspace))
        True, False -> Error(RelativePath(path: blob_root))
      }
  }
}

fn absolute(path: String) -> Bool {
  case path {
    "/" <> _ -> True
    _ -> False
  }
}

/// Opens the runtime over the configuration's own session: the documented
/// entry point.
///
/// The session appears once, in `Settings`, and this passes that same value
/// to `runtime/api.open` with the effects built from it. Calling `api.open`
/// directly with `effects` works only if it is given the session the
/// configuration was built over.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(runtime) = harness.open(config, api.default_options(strand))
/// ```
///
pub fn open(
  config: HarnessConfig,
  options: api.Options,
) -> Result(api.Runtime, String) {
  api.open(config.provider.session, effects(config), options)
}

/// Builds the `Effects` record a host hands to `runtime/api.open`.
///
/// The provider surface routes and admits through the gateway, the tool
/// surface clears against the registry and runs each call through
/// `tool.dispatch`, and the hooks are the runtime's defaults with admission and
/// resolution replaced. The `run` slot closes over the registry, which the
/// runtime copies into each process holding the effects; a host with a very
/// large registry assembles its own surface from `harness/tool_table`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(runtime) = api.open(session, harness.effects(config), options)
/// ```
///
pub fn effects(config: HarnessConfig) -> Effects {
  // The hooks and the tool surface are built from the few values they read,
  // not from the configuration: `Effects` is copied into every process which
  // holds the runtime, and a closure over `config` would copy the provider's
  // definitions and the registry into each of them again.
  let routes = config.provider.routing
  let provider_gateway = routes.gateway
  let opened = config.provider.session
  let lookup = routes.lookup
  let fallback = routes.fallback
  let role = routes.role

  let registry = config.registry
  let context = config.context
  let clock = config.clock

  effects.Effects(
    clock:,
    entropy: config.entropy,
    timers: effects.real_timers(),
    provider: provider.surface(
      config.provider,
      timeout_ms: config.provider_timeout_ms,
    ),
    tools: tool_table.surface(tool.declarations(registry), fn(run) {
      tool_table.run_registry(registry, context, clock, run)
    }),
    hooks: default_hooks(opened, provider_gateway, lookup, fallback, role),
  )
}

// The runtime's default hooks with the two slots a provider needs replaced:
// `admission`, which accounts each request against the facts of the identity
// it will reach, and `resolution`, which asks the gateway whether the role
// still routes. Everything else (no compaction, no run-start injection) is the
// default, which is what an embedder without a notes checkpoint wants.
fn default_hooks(
  opened: Session,
  provider_gateway: Gateway,
  lookup: model_facts.Lookup,
  fallback: Fallback,
  role: Role,
) -> effects.Hooks {
  hooks.new()
  |> hooks.with_admission(fn(query) {
    admission.admit(opened, provider_gateway, lookup, fallback, query)
  })
  |> hooks.with_resolution(fn(_configuration) {
    routing.resolution(provider_gateway, role)
  })
  |> hooks.build
}

/// A unique-seed source built from the broker's strong entropy: sixty-four
/// random bits per call. The odds of a repeat within one session are about two
/// to the minus sixty-four per pair, which is the standard the id generator
/// asks for.
///
/// ## Examples
///
/// ```gleam
/// // let seed = harness.random_entropy()
/// // assert seed() != seed()
/// ```
///
pub fn random_entropy() -> fn() -> Int {
  let random_bytes = token.production_entropy()
  fn() {
    case random_bytes(8) {
      <<value:size(64)>> -> value
      _ -> 0
    }
  }
}

/// The context an `Embedded` host runs each tool call under: the call's own
/// durable coordinates, a workspace-scoped default policy, the real
/// filesystem, and seams which refuse every broker execution and settle every
/// policy refusal in band.
///
/// ## Examples
///
/// ```gleam
/// // harness.embedded_context("/work", "/work/.blobs", clock)(run).workspace
/// //   == "/work"
/// ```
///
pub fn embedded_context(
  workspace: String,
  blob_root: String,
  clock: Clock,
) -> fn(effects.ToolRun) -> tool.Ctx {
  fn(run: effects.ToolRun) {
    tool.Ctx(
      workspace:,
      strand: run.strand,
      op_id: run.operation,
      step_id: run.step_id,
      source_index: run.source_index,
      base_policy: policy.workspace_default(workspace),
      directory_access: directory_access.none(),
      grants: [],
      demand: exec.FullEnforcement,
      env: [],
      clock:,
      filesystem: fs.real_filesystem(),
      blob_root:,
      clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
      raise_refusal: tool.no_raise(),
      observe_output: tool.ignore_output(),
    )
  }
}
