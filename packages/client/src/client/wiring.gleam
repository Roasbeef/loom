//// The production-wiring adapter for the runtime's effect seam (the M2
//// integration): builds a `runtime/effects.Effects` record over the real
//// provider gateway, the real ToolBroker, and the real tool registry.
//// The record is what a production host injects into `api.open` —
//// `client/serve` is that host — and the e2e conformance suite proves
//// the same wiring against a jailed helper. The module started life in
//// `conformance/src` because only the test leaf could depend on every
//// layer; with the client package serving sessions for real it was
//// promoted here (spec-gaps, M2 integration item 7).
////
//// ## Flow
////
//// `build_effects` → `dispatch` → `prepare_dispatch` → `provider_request` → `generation_request`; `build_effects` → `run_tool` → `tool_context`
////
//// 1. `build_effects` assembles the `Effects` record a host hands to
////    `runtime/api.open`: clock, entropy, timers, a provider surface, a tool
////    surface and `compaction_hooks`.
//// 2. A model call enters at `dispatch`, which is `prepare_dispatch` followed
////    by the begin permit; only a generation reaches the gateway, and polls
////    and summaries are refused as unsupported.
//// 3. `provider_request` picks the target. `request_image_bearing` and
////    `vision_route` send an image-bearing request from a text-only model down
////    the vision chain, and `generation_request` builds the wire request.
//// 4. A tool call enters at `run_tool`, which reads the session's standing
////    directory and permission grants, widens the base policy with them, and
////    dispatches through `tool_context`'s `Ctx`.
//// 5. `clear`, `replay_still_safe` and `execution_mode` answer the machine's
////    declaration questions from the projected table.
//// 6. `compaction_hooks` wires admission and the compaction signals, using
////    the same model facts `strand_window` reports.
////
//// ## Mapping decisions (each recorded here because the spec leaves the
//// seam's production shape open)
////
//// - **Provider identity.** Effect intents capture a durable
////   `ModelIdentity` (spec §1.5: durable state stores the resolved
////   `{provider, model_id}`), and the contract that identity carries is
////   narrower than "the same endpoint answers". Recovery never
////   re-dispatches a request that is still in flight: an orphaned
////   generation settles synthetically and the machine re-attempts from
////   the checkpoint. What must therefore agree across a crash is not the
////   socket but the *decision*, and the decision here is a pure function
////   of durable state and boot configuration — the strand's captured
////   identity, plus routes and a catalogue that were fixed before the
////   session opened — so a re-attempt chooses exactly what the original
////   attempt chose. Two consequences. A generation whose captured
////   identity **heads a configured role's chain** dispatches `ForRole`,
////   so a retryable failure walks that chain inside the one attempt
////   rather than burning the machine's ladder against a rate-limited
////   endpoint; an identity no role heads dispatches `ForResolved` to
////   exactly what was captured, which is what keeps a strand switched
////   off-route running. And a **deferred poll** is always `ForResolved`:
////   the handle is bound to the identity that minted it and ORCH-L4
////   validates it against exactly that captured value, so a poll that
////   walked a chain would fetch a continuation nobody issued. The
////   residual cost is stated and accepted in `protocol-change/009` — a
////   deferred handle settled by a *fallback* target fails ORCH-L4 and
////   drains as failure — and nothing settles `Deferred` today.
//// - **Thinking levels.** The machine's seven-point scale collapses onto
////   the provider's four-point scale: off→off, minimal/low→low,
////   medium→medium, high/xhigh/max→high. The strand's per-turn level is
////   carried onto the dispatch target on every generation path, as an
////   overlay onto every target a role walk attempts, so neither a
////   route's static configuration nor a fallback entry's can override
////   what the turn asked for. The catalogue's own `thinking` is not
////   dead: it *seeds* a strand's per-turn level at creation (see
////   `strand_thinking_level`), which is where a static configuration
////   belongs. A structural summary is the one dispatch with no per-turn
////   level to carry, and it routes with no overlay so the summarization
////   route's own declared level applies.
//// - **Context and options.** `GenerationRequest.context` is already the
////   projected conversation, oldest first, and maps verbatim onto
////   `ProviderRequest.messages`. `stream_options` is the runtime's opaque
////   options bag; the provider request vocabulary has no field for it,
////   so it is dropped here (recorded as a spec gap). `max_output_tokens`
////   is left `None` — the resolved model's ceiling governs.
//// - **Tools on the wire.** The intent's captured
////   `active_tool_names`, looked up in the registry and rendered as
////   `ToolSpec`s; names with no registration are silently omitted from
////   the request (the model cannot call what does not exist). The
////   render is canonical — sorted by name, duplicates collapsed —
////   because the tool array is the byte prefix of the provider's
////   cached region and reordering it invalidates the cache head. The
////   gateway stores the durable list in the same canonical form; this
////   sort also covers lists written by any other path.
//// - **Polls.** `ProviderRequest` cannot express a deferred
////   continuation fetch, so `PollRequest` settles immediately as an
////   in-band provider error rather than dispatching a nonsensical
////   generation; the failure is terminally classified so the retry
////   ladder is not burned on a permanently-absent surface. Nothing
////   reaches it today — resolution always succeeds but responses never
////   settle `Deferred`. Recorded as a spec gap.
//// - **Compaction.** No `SummaryRequest` is ever dispatched. This host
////   answers every compaction at the structural decision with the
////   checkpoint `client/checkpoint` builds from the strand's own notes —
////   the model's record of what mattered, carried whole across the
////   window boundary — so no provider is asked to condense a
////   conversation and no summarization prompt ships. The machine's
////   generate path is left standing as the frozen contract it is (the
////   deterministic simulation still drives it), and a summary request
////   that somehow reached `dispatch` is refused terminally rather than
////   sent: there is no prompt it could be made with.
//// - **Clearance** is registry-level: the call's name must be in the
////   intent's captured `active_tool_names` and registered; the effective
////   arguments are the model's arguments unchanged (no rewriting hook
////   yet), and the replay policy is the registration's declared safety.
////   Policy composition happens later, inside the tool's own
////   `clear_call` against the broker — a clearance here is not an
////   execution grant.
//// - **Execution.** Each `ToolRun` gets a fresh `Ctx` (op/step ids from
////   the run, broker/filesystem/blob seams from the config, and the
////   output observer `Config.observe_output` resolves for that run) and
////   goes through `tool.dispatch`. Dispatch is total: unknown names and every
////   tool failure come back as in-band `is_error` results, so the
////   adapter always answers `ToolCompleted`; `ToolFailed` remains the
////   runtime's own path for a dead effect worker. The persisted
////   `ToolRun.replay` is deliberately not consulted — replay decisions
////   were made durably at intent time. No core tool terminates a run, so
////   `terminate` is always `False`.
//// - **Replay-still-safe** reads the registration's own declaration
////   (pi §4.5: stored and current declarations must both say safe); an
////   unregistered name is never safe. It reads it from the declaration
////   table projected when `Effects` was built, which is the same answer
////   a lookup would give: the registry a session runs under is fixed for
////   that record's life.
//// - **Hooks** are built through `runtime/hooks` from real facts, not
////   `effects.default_hooks()`. `admission` is asked **per query** and
////   answers from the catalogue entry the *query's own* strand
////   configuration names, so a strand switched to another entry is
////   admitted against that entry's window, ceiling and dialect rather
////   than against the main chain head's — the api it captures is the one
////   the request will actually be dispatched to, which is what ORCH-L4
////   later validates a deferred handle against; `threshold` and
////   `overflow_preparation`
////   share one preparation builder over the strand's *durable*
////   projection, read from the session store (hooks must decide from
////   durable state so a decision taken before a crash is taken again
////   after it); `structural_decision` supplies the notes checkpoint, which is
////   what keeps a compaction off the provider entirely; and
////   `resolution` asks the gateway whether the captured identity still
////   routes. A host that wires a messaging plane wraps this record
////   afterwards — `client/serve` composes `client/agency.reaping_hooks`
////   over it so a run's end reaps the undetached children that run
////   spawned — which is why the field is built here rather than fixed
////   here.
//// - **Enforcement demand** is caller-chosen config: production sessions
////   pass `exec.FullEnforcement`; the conformance container's helper
////   runs degraded (no bwrap/Landlock), so its suites pass
////   `exec.BestEffort` and assert on the helper's honest enforcement
////   report instead.

import broker/broker.{type Broker}
import broker/escalation.{type Denial}
import broker/exec.{type EnforcementDemand}
import broker/policy.{type Grant, type SandboxPolicy}
import client/catalog
import client/checkpoint
import client/config_reload
import client/directories
import client/escalate.{type Escalations}
import client/grants
import client/notes
import client/permissions
import client/tool_holder
import client/vision
import core/clock.{type Clock}
import core/entry
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation.{
  type CompactionSettings, type ReplayPolicy, OperationError,
}
import machine/planner.{
  type ModelResolution, type RequestAdmission, type StructuralVerdict, Admitted,
  ModelResolved, ModelUnresolved, ThresholdExceeded, ThresholdNotExceeded,
  VerdictDeclined, VerdictSupplied,
}
import machine/strand.{
  type ModelIdentity, type StrandConfiguration, ModelIdentity,
}
import provider/gateway.{type Gateway}
import provider/image_budget
import provider/model.{
  type ProviderRequest, type RequestTarget, type ResolvedModel, type Role,
  type ToolSpec, ForResolved, ForRole, ProviderRequest, ResolvedModel, ToolSpec,
}
import provider/stream.{type StreamHandle}
import runtime/effects.{type Effects}
import runtime/hooks
import session/session.{type Session}
import storage/storage
import tools/directory_access
import tools/fs
import tools/history
import tools/tool.{type Registry}

/// Everything the adapter needs to reach the world: the provider
/// gateway, a running broker, the tool registry, and the session-scoped
/// policy and path facts.
///
/// Constructor invariants: `workspace` and `blob_root` are absolute
/// paths (`blob_root` should live under a readable workspace path so
/// blob refs stay `fs_read`-able — spec §3.2); `env` is the
/// allowlist-constructed child environment for jailed executions, never
/// an inherited one; `entropy` must never return the same seed twice
/// within a session's lifetime (spec-gaps WP-E item 6) — production
/// derives it from strong randomness or a monotonic unique source;
/// `fallback_context_window` and `fallback_max_output_tokens` are
/// positive token counts used only for an identity `facts` does not know.
pub type Config {
  Config(
    /// The provider gateway, fully routed.
    gateway: Gateway,
    /// The role `resolution` asks the gateway about. Dispatch does not
    /// read it: the role a
    /// request is served under is derived from the captured identity
    /// (`request_target`), in canonical order — `Main` first, then
    /// `Subagent` — whatever this field names.
    role: Role,
    /// The static model facts an identity's own catalogue entry declares:
    /// its resolved form and the adapter api its dialect speaks.
    /// `Error(Nil)` for an identity the host's catalogue does not know,
    /// which falls back to the two `fallback_*` counts and `api` below.
    ///
    /// This is the seam that makes a strand switched *off* the configured
    /// route accounted for honestly: admission, the compaction threshold,
    /// and an off-route dispatch target all read the switched-to entry's
    /// own window and ceiling rather than the main chain head's.
    facts: fn(ModelIdentity) ->
      Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
    /// The system prompt sent with every generation, if any.
    system: Option(String),
    /// The adapter api to capture for an identity `facts` does not know
    /// (`anthropic.api_name`, `openai.api_name`). Captured durably into
    /// every generation intent, where deferred-handle validity compares
    /// against it rather than against a response's self-report
    /// (ORCH-L4), so it must name the api actually dispatched to — which
    /// is why a known identity's own dialect wins over this.
    api: String,
    /// Context-window facts for identities `facts` does not know.
    fallback_context_window: Int,
    /// Output ceiling for identities `facts` does not know.
    fallback_max_output_tokens: Int,
    /// How long the effect process waits for a provider terminal event.
    provider_timeout_ms: Int,
    /// The session this wiring serves. Read-only here: the compaction
    /// hooks project a strand's durable context from it, because a hook
    /// must decide from durable state (`runtime/hooks`).
    session: Session,
    /// Compaction settings for the hooks built here. These are the
    /// *hook's* copy; the machine separately captures a run's settings
    /// snapshot at acceptance, and `settings.enabled` there is what
    /// gates step 3 of a checkpoint.
    compaction: CompactionSettings,
    /// The running ToolBroker.
    broker: Broker,
    /// Bound on the synchronous broker clearance call, in milliseconds.
    broker_timeout_ms: Int,
    /// The tool registry, as `client/contributions` built it.
    registry: Registry,
    /// Absolute workspace root.
    workspace: String,
    /// Absolute blob-overflow directory (spec §3.2).
    blob_root: String,
    /// The session's base sandbox policy.
    base_policy: SandboxPolicy,
    /// What a policy refusal does before it settles: raise a durable
    /// record, and — when someone is attached to decide — hold the call
    /// open until they do (`client/escalate`). `escalate.none()` is the
    /// no-plane default, under which a refusal settles exactly as it did
    /// before escalations existed.
    escalations: Escalations,
    /// Enforcement strictness for jailed executions. Production demands
    /// `exec.FullEnforcement`; `exec.BestEffort` accepts a degraded
    /// helper and is for development containers and self-tests only.
    demand: EnforcementDemand,
    /// Allowlist-constructed environment for jailed children.
    env: List(#(String, String)),
    /// The injected time source.
    clock: Clock,
    /// Fresh id-generator seeds; values must never repeat in-session.
    entropy: fn() -> Int,
    /// Who watches a jailed execution's output while it runs. Resolved
    /// once per `ToolRun` — the run names the operation and step every
    /// observation is keyed by — and the observer it returns is shown
    /// the rolling tail after every chunk (`tools/tool.collect_observed`,
    /// issue #186). `unobserved()` for a host with no terminal to show
    /// it to; `client/serve` supplies `gateway.tool_output_observer`,
    /// which publishes on the event bus.
    observe_output: fn(effects.ToolRun) -> fn(tool.OutputTail) -> Nil,
  )
}

// A provider request owns routing facts and rendered definitions, never tool
// executors, jail policy, environment or broker clearance callbacks. The routing
// projection also serves public target queries without building a tool table.
type ProviderRouting {
  ProviderRouting(
    gateway: Gateway,
    role: Role,
    facts: fn(ModelIdentity) ->
      Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
    api: String,
    fallback_context_window: Int,
    fallback_max_output_tokens: Int,
  )
}

type ProviderConfiguration {
  ProviderConfiguration(
    routing: ProviderRouting,
    session: Session,
    system: Option(String),
    definitions: Dict(String, ToolSpec),
  )
}

fn provider_routing(config: Config) -> ProviderRouting {
  ProviderRouting(
    gateway: config.gateway,
    role: config.role,
    facts: config.facts,
    api: config.api,
    fallback_context_window: config.fallback_context_window,
    fallback_max_output_tokens: config.fallback_max_output_tokens,
  )
}

fn provider_configuration(config: Config) -> ProviderConfiguration {
  ProviderConfiguration(
    routing: provider_routing(config),
    session: config.session,
    system: config.system,
    definitions: tool_definitions(config.registry),
  )
}

/// The reloadable provider projections, kept together with their UI catalogue.
/// Executable tools and boot services stay in their existing owners.
pub opaque type ModelRevision {
  ModelRevision(
    provider: ProviderConfiguration,
    hooks: effects.Hooks,
    catalogue: catalog.Catalog,
    changed_summary_sources: List(String),
  )
}

/// Projects one validated catalogue into coherent routing, admission and hooks.
///
/// ## Examples
///
/// ```gleam
/// // wiring.model_revision(config, catalogue)
/// ```
pub fn model_revision(
  config: Config,
  catalogue: catalog.Catalog,
) -> ModelRevision {
  ModelRevision(
    provider_configuration(config),
    compaction_hooks(config),
    catalogue,
    [],
  )
}

/// Carries endpoint history across publications for settled-summary admission.
///
/// Durable assistant messages name a provider but do not record its endpoint.
/// Once a name changes service, that historical name cannot safely authorize
/// sending its stored text to the boot summarizer, even if the operator reverts.
///
/// ## Examples
///
/// ```gleam
/// // wiring.model_revision_after(config, catalogue, previous)
/// ```
pub fn model_revision_after(
  config: Config,
  catalogue: catalog.Catalog,
  previous: ModelRevision,
) -> ModelRevision {
  let changed =
    previous.catalogue.models
    |> list.filter(fn(old) {
      case catalog.find(catalogue, old.name) {
        Ok(next) ->
          old.base_url != next.base_url
          || old.dialect != next.dialect
          || old.api_key_env != next.api_key_env
        Error(Nil) -> True
      }
    })
    |> list.map(fn(entry) { entry.name })
  ModelRevision(
    ..model_revision(config, catalogue),
    changed_summary_sources: list.unique(list.append(
      previous.changed_summary_sources,
      changed,
    )),
  )
}

/// Whether durable text still has an unambiguous boot endpoint for this name.
///
/// ## Examples
///
/// ```gleam
/// // wiring.revision_summary_source_allowed(revision, "acme")
/// ```
pub fn revision_summary_source_allowed(
  revision: ModelRevision,
  provider: String,
) -> Bool {
  !list.contains(revision.changed_summary_sources, provider)
}

/// Reads the exact catalogue behind a published provider revision.
///
/// ## Examples
///
/// ```gleam
/// // wiring.revision_catalogue(revision)
/// ```
pub fn revision_catalogue(revision: ModelRevision) -> catalog.Catalog {
  revision.catalogue
}

/// The selected strand's window from the same snapshot admission uses.
///
/// ## Examples
///
/// ```gleam
/// // wiring.revision_window(revision, session, "main")
/// ```
pub fn revision_window(
  revision: ModelRevision,
  opened: Session,
  strand: String,
) -> Int {
  let routing = revision.provider.routing
  strand_window(
    opened,
    routing.facts,
    strand,
    fallback: routing.fallback_context_window,
  )
}

/// The current identity window for a client context inspection.
///
/// ## Examples
///
/// ```gleam
/// // wiring.revision_identity_window(revision, identity)
/// ```
pub fn revision_identity_window(
  revision: ModelRevision,
  identity: ModelIdentity,
) -> Int {
  model_facts(revision.provider.routing, identity).context_window
}

/// Resolves a role from a published snapshot for new child selection.
///
/// ## Examples
///
/// ```gleam
/// // wiring.revision_role(revision, model.Subagent)
/// ```
pub fn revision_role(
  revision: ModelRevision,
  role: Role,
) -> Result(ResolvedModel, Nil) {
  gateway.resolve(revision.provider.routing.gateway, role)
  |> result.replace_error(Nil)
}

/// Adds operation snapshots beneath the host's existing hooks and stream taps.
///
/// The first hook or provider fetch pins a revision. Later requests, retries,
/// admission and compaction all read that pin. Tools remain boot-configured.
/// Resolution has no operation identity, but production dispatch refuses both
/// deferred polls and summary generation, the only paths which consult it.
/// Supporting either path requires adding an operation to that hook first.
///
/// ## Examples
///
/// ```gleam
/// // wiring.with_model_reloads(built, revisions)
/// ```
pub fn with_model_reloads(
  built: Effects,
  revisions: config_reload.Holder(ModelRevision),
) -> Effects {
  let original = built.hooks
  let prepare = fn(spec: effects.RequestSpec) {
    let operation = case spec {
      effects.GenerationRequest(operation:, ..)
      | effects.PollRequest(operation:, ..)
      | effects.SummaryRequest(operation:, ..) -> operation
    }
    case config_reload.capture(revisions, operation) {
      Ok(revision) -> prepare_dispatch(revision.provider, spec)
      Error(Nil) ->
        prepared_unsupported("the session configuration is unavailable")
    }
  }
  effects.Effects(
    ..built,
    provider: effects.PreparedProviderSurface(
      request: fn(spec) { prepare(spec) |> stream.start_prepared },
      prepare:,
      timeout_ms: provider_timeout(built.provider),
    ),
    hooks: effects.Hooks(
      ..original,
      admission: fn(query: effects.AdmissionQuery) {
        case config_reload.capture(revisions, query.operation) {
          Ok(revision) -> revision.hooks.admission(query)
          Error(Nil) ->
            planner.AdmissionUnavailable(OperationError(
              code: "config_unavailable",
              message: "the session configuration is unavailable",
              details: None,
            ))
        }
      },
      threshold: fn(query: effects.ThresholdQuery) {
        case config_reload.capture(revisions, query.operation) {
          Ok(revision) -> revision.hooks.threshold(query)
          Error(Nil) -> ThresholdNotExceeded
        }
      },
      overflow_preparation: fn(query: effects.OverflowQuery) {
        case config_reload.capture(revisions, query.operation) {
          Ok(revision) -> revision.hooks.overflow_preparation(query)
          Error(Nil) -> planner.EmptyPreparation
        }
      },
      context: fn(operation, messages) {
        case config_reload.capture(revisions, operation) {
          Ok(revision) -> revision.hooks.context(operation, messages)
          Error(Nil) -> messages
        }
      },
    ),
  )
}

fn provider_timeout(surface: effects.ProviderSurface) -> Int {
  case surface {
    effects.ProviderSurface(timeout_ms:, ..)
    | effects.PreparedProviderSurface(timeout_ms:, ..) -> timeout_ms
  }
}

/// An observer resolver that watches nothing: every execution's output
/// still reaches its collected result, and no tail leaves the tool. The
/// default for a host with nobody attached, and for tests about
/// something else.
///
/// ## Examples
///
/// ```gleam
/// // wiring.Config(..config, observe_output: wiring.unobserved())
/// ```
///
pub fn unobserved() -> fn(effects.ToolRun) -> fn(tool.OutputTail) -> Nil {
  fn(_run) { tool.ignore_output() }
}

/// Builds the production `Effects` record from a config. See the module
/// documentation for every mapping decision.
///
/// ## Examples
///
/// ```gleam
/// // let effects = wiring.build_effects(config)
/// // api.open(session, effects, options)
/// ```
///
pub fn build_effects(config: Config) -> Effects {
  effects_over(config, fn(run) { run_tool(config, run) })
}

/// Builds the production `Effects` record with a `run` slot that fetches
/// its configuration from `holder` instead of capturing it.
///
/// `build_effects` closes the `run` slot over the whole `Config`, and
/// `Effects` is copied into every process and supervisor child
/// specification that holds a session's runtime, so each holder carried
/// its own copy of the tool registry. Here the slot captures only the
/// holder's address, and each tool run asks the holder for the
/// configuration, runs against that one copy, and releases it. A session
/// that assembles through this function holds the registry once in the
/// holder rather than once per holder of the effects.
///
/// A holder that is gone or silent cannot supply the configuration, and the
/// slot still has to answer `ToolCompleted`: see `run_tool_held`. The
/// caller owns the holder and must keep it alive for as long as the
/// runtime can run a tool.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(holder) = tool_holder.start(config)
/// // let effects = wiring.build_effects_held(config, holder)
/// ```
///
pub fn build_effects_held(
  config: Config,
  holder: tool_holder.Holder(Config),
) -> Effects {
  // The failure path has no configuration to read a timestamp from, so the
  // clock is captured by itself. It is a small record of one function and
  // holds neither the registry nor the session.
  let clock = config.clock
  effects_over(config, fn(run) { run_tool_held(holder, clock, run) })
}

// The record both builders share, differing only in the `run` slot. The
// configuration this function receives is read for projections and field
// copies; nothing it builds other than `run` may close over `config`.
fn effects_over(
  config: Config,
  run: fn(effects.ToolRun) -> effects.ToolOutcome,
) -> Effects {
  // The two declaration slots below read two words out of a registration
  // and nothing else, so they are given the projected declaration table
  // rather than the configuration the registry hangs off. `Effects` is a
  // record of closures and it is copied into every process a session
  // assembly starts; BEAM drops sharing when it copies, so a closure that
  // held `config` to answer a declaration question put a second and a
  // third copy of the whole tool registry into each of those heaps. The
  // registry a session runs under does not change while this record
  // exists, so the projection answers what a lookup would have.
  let declared = tool.declarations(config.registry)

  // Definitions are immutable for this effect graph. Project them once before
  // retaining either provider facade, so executable registrations stay only in
  // the tool surface. Active names are still chosen from each request's own
  // durable configuration, not from this boot-time projection.
  let provider = provider_configuration(config)

  effects.Effects(
    clock: config.clock,
    entropy: config.entropy,
    timers: effects.real_timers(),
    provider: effects.PreparedProviderSurface(
      request: fn(spec) { dispatch(provider, spec) },
      prepare: fn(spec) { prepare_dispatch(provider, spec) },
      timeout_ms: config.provider_timeout_ms,
    ),
    tools: effects.ToolSurface(
      clear: fn(query) { clear(declared, query) },
      run:,
      replay_still_safe: fn(name) { replay_still_safe(declared, name) },
      execution_mode: fn(name) { execution_mode(declared, name) },
    ),
    hooks: compaction_hooks(config),
  )
}

/// The hooks a production session runs: real admission from the
/// gateway's model facts, the two compaction signals over the strand's
/// durable projection, the notes checkpoint as the structural verdict,
/// and the near-limit reminder on the `context` slot.
///
/// Exposed separately from `build_effects` so a host with its own
/// provider and tool surfaces — the scripted M3 demo is one — installs
/// exactly these hooks rather than an imitation of them. A demo that
/// answers its own compaction proves nothing about whether compaction
/// runs.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..scripted, hooks: wiring.compaction_hooks(config))
/// ```
///
pub fn compaction_hooks(config: Config) -> effects.Hooks {
  // Reference preparation needs the session and registered tool surface.
  // Capture those fields rather than the entire wiring configuration.
  let opened = config.session
  let compaction = config.compaction
  let gateway = config.gateway
  let role = config.role
  let facts = config.facts
  let api = config.api
  let fallback_context_window = config.fallback_context_window
  let fallback_max_output_tokens = config.fallback_max_output_tokens
  let clock = config.clock

  // Compaction asks the registry one question — whether this host offers
  // history search at all — and three of the hook closures below would
  // otherwise capture the whole registry to ask it. Answering it once here
  // is what keeps those three closures small, and the answer cannot go
  // stale: the registry a session runs under is fixed for the life of the
  // `Effects` record these hooks belong to.
  let searchable = history_registration(config.registry)

  let projection = fn(strand) {
    reference_projection(opened, searchable, strand)
  }

  // The threshold's window is the *strand's*, not the session's. One
  // `Effects` record serves every strand, and a strand switched to a
  // catalogue entry with a different context window must be compacted
  // against that window or the clamp fires at the wrong size — early on a
  // larger model, never on a smaller one. `ThresholdQuery` carries the
  // strand name and nothing else, so the configuration is read back from
  // the durable store, the same place every other hook decides from.
  let threshold_for = fn(strand) {
    hooks.threshold(
      compaction,
      context_window: strand_facts_from(
        opened,
        facts,
        api,
        fallback_context_window,
        fallback_max_output_tokens,
        strand,
      ).context_window,
      estimate: hooks.estimate_message,
    )
  }
  hooks.new()
  |> hooks.with_admission(fn(query: effects.AdmissionQuery) {
    admit_projected(
      opened,
      gateway,
      facts,
      api,
      fallback_context_window,
      fallback_max_output_tokens,
      query,
    )
  })
  |> hooks.with_threshold(fn(query: effects.ThresholdQuery) {
    // First decide whether to compact from the driver's existing context.
    // Only a crossed threshold pays for source recovery through older windows.
    case threshold_for(query.strand)(query) {
      ThresholdExceeded(outcome:) ->
        ThresholdExceeded(outcome: hooks.reference_outcome(
          outcome,
          projection(query.strand),
        ))
      ThresholdNotExceeded -> ThresholdNotExceeded
    }
  })
  |> hooks.with_overflow_preparation(hooks.overflow(
    compaction,
    projection:,
    estimate: hooks.estimate_message,
  ))
  // Every compaction is answered here, with the checkpoint
  // `client/checkpoint` builds from the strand's own notes. Nothing
  // selects generation: no summarizer serves this host.
  |> hooks.with_structural_decision(fn(operation, _task) {
    structural_decision_projected(opened, searchable, operation)
  })
  // The checkpoint's other half: the reminder a request carries once the
  // context is within a reserve of the compaction point, so the model
  // writes its notes while the messages they describe are still in
  // front of it. Identity when compaction is off.
  |> hooks.with_context(fn(operation, messages) {
    near_limit_reminder_projected(
      opened,
      facts,
      api,
      fallback_context_window,
      fallback_max_output_tokens,
      compaction,
      clock,
      operation,
      messages,
    )
  })
  |> hooks.with_resolution(fn(_configuration) {
    resolution_projected(gateway, role)
  })
  |> hooks.build
}

// Whether this host registered the history-search tool at all. It is the
// only thing compaction asks the tool registry, so it travels as its own
// answer: the three hook closures that need it would otherwise each hold
// the registry, and `Effects` is copied into every process a session
// assembly starts.
type HistoryRegistration {
  /// The host offers history search, so a reference may be handed out if
  /// the strand has the tool active as well.
  HistorySearchRegistered

  /// No history search on this host, so no reference can be useful.
  HistorySearchAbsent
}

// Read once, where the registry already is.
fn history_registration(registry: Registry) -> HistoryRegistration {
  case tool.lookup(registry, history.tool_name) {
    Ok(_registered) -> HistorySearchRegistered
    Error(Nil) -> HistorySearchAbsent
  }
}

// The registration question in `use` position, so it chains with the durable
// reads beside it instead of branching around them. The two sides are not
// both `Result`, which is the case the house combinator pattern exists for
// (`docs/gleam-style.md` Part III, "Short-circuit combinators").
fn if_searchable(
  registration: HistoryRegistration,
  then: fn() -> Result(a, Nil),
) -> Result(a, Nil) {
  case registration {
    HistorySearchRegistered -> then()
    HistorySearchAbsent -> Error(Nil)
  }
}

// A pointer is useful only if this strand can ask for its contents. Require
// both host registration and strand activation, plus the canonical session
// identity. Missing configuration keeps the original messages; compaction
// must never grant a tool or expose a database path to make recall possible.
fn reference_projection(
  opened: Session,
  searchable: HistoryRegistration,
  strand: String,
) -> hooks.Projected {
  let projected = hooks.project(opened, strand)
  let available = {
    use cell <- result.try(
      session.strand_configuration(opened, strand)
      |> result.replace_error(Nil),
    )
    use configuration <- result.try(option.to_result(cell, Nil))
    use <- if_searchable(searchable)
    use session_cell <- result.try(
      session.id(opened) |> result.replace_error(Nil),
    )
    use session_id <- result.try(option.to_result(session_cell, Nil))
    use <- bool.guard(
      when: !list.contains(
        configuration.value.active_tool_names,
        history.tool_name,
      ),
      return: Error(Nil),
    )
    Ok(session_id)
  }
  case available {
    Ok(session_id) -> hooks.with_tool_references(projected, opened, session_id)
    Error(Nil) -> projected
  }
}

// --- the checkpoint --------------------------------------------------------

// A checkpoint the host holds is supplied, with no usage row because no
// provider was billed. Everything else declines: a branch summary,
// because notes say nothing about an abandoned branch and nothing in the
// tree asks for one; and a checkpoint that could not be built, which
// leaves a threshold compaction's run alive and unclamped and drains an
// overflow's — never a published claim that the strand wrote nothing.
fn structural_decision_projected(
  opened: Session,
  searchable: HistoryRegistration,
  operation: OpId,
) -> StructuralVerdict {
  case
    checkpoint.for_operation(
      opened,
      operation,
      recall_projected(opened, searchable, operation),
      instructions_for_session(opened, operation),
    )
  {
    Ok(checkpoint.Checkpoint(text:)) ->
      VerdictSupplied(summary: text, usage: None)
    Ok(checkpoint.NotACompaction) -> VerdictDeclined
    Error(Nil) -> VerdictDeclined
  }
}

// A registered tool may still be disabled on this strand. Match the
// durable active-tool list used to build generation requests.
fn recall_projected(
  opened: Session,
  searchable: HistoryRegistration,
  operation: OpId,
) -> checkpoint.Recall {
  let available = {
    use strand <- result.try(notes.strand_of(opened, operation))
    use cell <- result.try(
      session.strand_configuration(opened, strand)
      |> result.replace_error(Nil),
    )
    use configuration <- result.try(option.to_result(cell, Nil))
    use <- if_searchable(searchable)
    Ok(list.contains(configuration.value.active_tool_names, history.tool_name))
  }
  case available {
    Ok(True) -> checkpoint.Searchable
    _ -> checkpoint.Unsearchable
  }
}

// The request's messages with the notes reminder appended, or untouched.
// Compaction switched off means no boundary is coming, so there is
// nothing to remind about.
fn near_limit_reminder_projected(
  opened: Session,
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  fallback_api: String,
  fallback_context_window: Int,
  fallback_max_output_tokens: Int,
  compaction: CompactionSettings,
  clock: Clock,
  operation: OpId,
  messages: List(AgentMessage),
) -> List(AgentMessage) {
  use <- bool.guard(when: !compaction.enabled, return: messages)
  case notes.strand_of(opened, operation) {
    Error(Nil) -> messages
    Ok(strand) ->
      reminded_projected(
        opened,
        facts,
        fallback_api,
        fallback_context_window,
        fallback_max_output_tokens,
        compaction,
        clock,
        strand,
        messages,
      )
  }
}

// Re-projects the strand from the store rather than pricing the list in
// hand: `hooks.context_tokens` needs to know how many leading messages a
// compaction carried, or it reads the pre-compaction usage those carry
// and fires the reminder on every request for the rest of the session.
// One projection per generation request, against the threshold's one
// per driver pass. The window is the strand's, as the threshold's is.
// The count is over the messages this request will carry, which the
// driver projected and every earlier `context` hook has already shaped.
// Reading the branch again here cost a full scan and decode per request
// for a number the request already holds (issue #359). What the count
// still needs from the store is one entry: the newest compaction, whose
// retained tail heads the projection and whose priced turns report the
// context as it stood before the compaction. `carried` is how the usage
// fold skips those, and without it the first request after a compaction
// read a stale total and raised the reminder against room that was there.
fn reminded_projected(
  opened: Session,
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  fallback_api: String,
  fallback_context_window: Int,
  fallback_max_output_tokens: Int,
  compaction: CompactionSettings,
  clock: Clock,
  strand: String,
  messages: List(AgentMessage),
) -> List(AgentMessage) {
  let projected =
    hooks.Projected(
      messages:,
      carried: carried_by_session(opened, strand),
      previous_summary: None,
      origins: list.repeat(None, list.length(messages)),
      reference_session: None,
      copied_from: None,
    )
  let total = hooks.context_tokens(projected, hooks.estimate_message)
  let window =
    strand_facts_from(
      opened,
      facts,
      fallback_api,
      fallback_context_window,
      fallback_max_output_tokens,
      strand,
    ).context_window
  case total > checkpoint.reminder_point(window, compaction) {
    False -> messages
    True ->
      list.append(messages, [
        checkpoint.reminder(
          clock,
          remaining: window - compaction.reserve_tokens - total,
        ),
      ])
  }
}

// How many head messages of the strand's projection the newest compaction
// carried forward: its summary plus its retained tail. Read as one entry,
// the compaction itself, which is the only part of the branch the count
// needs; a strand with no compaction, or a store that will not answer,
// carries nothing.
fn carried_by_session(opened: Session, strand: String) -> Int {
  case session.strand_leaf(opened, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) -> {
      let newest =
        storage.branch_scan(from: leaf)
        |> storage.branch_stop_at_kind(storage.Compaction)
        |> storage.branch_kind(storage.Compaction)
        |> storage.branch_limit(1)
        |> storage.scan_branch(opened.store, _)
      case newest {
        Ok([entry.CompactionEntry(retained_tail:, ..)]) ->
          1 + list.length(retained_tail)
        Ok(_) | Error(_) -> 0
      }
    }
    Ok(Some(_)) | Ok(None) | Error(_) -> 0
  }
}

// --- the provider surface -------------------------------------------------

// Dispatches one request spec. Generations go to the gateway; polls and
// summary requests settle immediately in-band (see the module doc).

fn dispatch(
  config: ProviderConfiguration,
  spec: effects.RequestSpec,
) -> StreamHandle {
  prepare_dispatch(config, spec)
  |> stream.start_prepared
}

// Production dispatch keeps role resolution and secret lookup behind the
// begin permit. The immediate error cases still use the same shape so every
// wrapper can apply one prepare, publish, begin protocol.
fn prepare_dispatch(
  config: ProviderConfiguration,
  spec: effects.RequestSpec,
) -> stream.PreparedStream {
  case spec {
    effects.GenerationRequest(operation:, ..) -> {
      let request = provider_request_from(config, spec)
      let protected = case image_budget.count(request.messages) {
        0 -> 0
        _ -> active_run_images(config.session, operation) |> result.unwrap(0)
      }
      let scoped =
        gateway.with_protected_images(config.routing.gateway, protected)
      gateway.prepare(scoped, request)
    }
    effects.PollRequest(..) ->
      prepared_unsupported(
        "deferred polls are not wired to a provider surface yet",
      )

    // Unreachable in production: every compaction is answered at the
    // decision with a checkpoint, so the machine never enters its
    // generate path here. Total all the same, and terminal rather than
    // retryable, because a summary request that somehow reached the wire
    // has no prompt it could be made with.
    effects.SummaryRequest(..) ->
      prepared_unsupported(
        "this host answers compaction with a notes checkpoint and dispatches "
        <> "no summary request",
      )
  }
}

fn prepared_unsupported(reason: String) -> stream.PreparedStream {
  stream.PreparedStream(handle: unsupported(reason), begin: fn() { Nil })
}

// The operator's `Compact(strand, instructions)` text, read from the
// operation's durable state. It reaches the checkpoint through here
// rather than through the preparation because `StructuralPreparation`
// has no field for it: the preparation is the *input* the decision hook
// froze, and the instructions are a property of the operation that asked
// for the compaction.
fn instructions_for_session(
  opened: Session,
  operation: OpId,
) -> Option(String) {
  case session.op_state(opened, operation) {
    Ok(Some(session.Cell(value: state, ..))) ->
      case state {
        operation.CompactionState(custom_instructions:, ..) ->
          custom_instructions
        operation.NavigationState(
          navigation: operation.SummarizedNavigation(custom_instructions:, ..),
          ..,
        ) -> custom_instructions
        _ -> None
      }
    _ -> None
  }
}

/// Whether the captured identity still routes, asked before a deferred
/// poll. The gateway is the authority: an identity
/// whose provider is no longer configured cannot be dispatched to, and
/// saying so here fails the operation in band instead of at the
/// transport.
///
/// The honest limit: the configuration argument is unread today — the
/// answer is about the configured *roles*, not about the identity in
/// hand — so an off-route strand whose provider vanished from the
/// catalogue passes this check and fails at dispatch as an unknown
/// provider rather than as the in-band `model_unavailable` this hook
/// exists to produce. Reading the identity here is the fix when that
/// gap earns its change.
///
/// ## Examples
///
/// ```gleam
/// // wiring.resolution(config, configuration) == planner.ModelResolved
/// ```
///
pub fn resolution(
  config: Config,
  _configuration: StrandConfiguration,
) -> ModelResolution {
  case gateway.resolve(config.gateway, config.role) {
    Ok(_resolved) -> ModelResolved
    Error(_missing) ->
      ModelUnresolved(error: OperationError(
        code: "model_unavailable",
        message: "no configured route resolves to a usable provider",
        details: None,
      ))
  }
}

fn resolution_projected(
  provider_gateway: Gateway,
  role: Role,
) -> ModelResolution {
  case gateway.resolve(provider_gateway, role) {
    Ok(_resolved) -> ModelResolved
    Error(_missing) ->
      ModelUnresolved(error: OperationError(
        code: "model_unavailable",
        message: "no configured route resolves to a usable provider",
        details: None,
      ))
  }
}

// --- the catalogue's model facts -------------------------------------------

// The window, output ceiling and adapter api one identity is accounted
// against. Read from the identity's *own* catalogue entry, so a strand
// switched off the configured route is admitted, compacted and captured
// against what it will actually be dispatched to. An identity the
// catalogue does not know falls back to the config's declared facts,
// which is what keeps a session with a moved route running rather than
// admitting requests against numbers nobody stands behind.
type ModelFacts {
  ModelFacts(
    api: String,
    context_window: Int,
    max_output_tokens: Int,
    reading: catalog.ImageReading,
  )
}

// The fallback reading is `ReadsImages`, the same answer the catalogue
// gives an entry that never wrote the key: an identity the catalogue
// does not know was switched to by an operator or seeded from an
// environment the catalogue never described, and routing consults only
// the blind declarations the catalogue actually made.
fn model_facts(config: ProviderRouting, identity: ModelIdentity) -> ModelFacts {
  model_facts_from(
    config.facts,
    config.api,
    config.fallback_context_window,
    config.fallback_max_output_tokens,
    identity,
  )
}

fn model_facts_from(
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  fallback_api: String,
  fallback_context_window: Int,
  fallback_max_output_tokens: Int,
  identity: ModelIdentity,
) -> ModelFacts {
  case facts(identity) {
    Ok(#(resolved, api, reading)) ->
      ModelFacts(
        api:,
        context_window: resolved.context_window,
        max_output_tokens: resolved.max_output_tokens,
        reading:,
      )
    Error(Nil) ->
      ModelFacts(
        api: fallback_api,
        context_window: fallback_context_window,
        max_output_tokens: fallback_max_output_tokens,
        reading: catalog.ReadsImages,
      )
  }
}

// The figures for an identity nobody stands behind: the config's own
// declared fallbacks, stated once so the two readers cannot drift.
// One strand's facts, read from its durable configuration. A strand whose
// configuration is unreadable is accounted against the fallback figures:
// a token count that cannot be taken must not halt a strand
// (`runtime/hooks`' own rule for a failed projection).
fn strand_facts_from(
  opened: Session,
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  fallback_api: String,
  fallback_context_window: Int,
  fallback_max_output_tokens: Int,
  strand: String,
) -> ModelFacts {
  case strand_identity(opened, strand) {
    Some(identity) ->
      model_facts_from(
        facts,
        fallback_api,
        fallback_context_window,
        fallback_max_output_tokens,
        identity,
      )
    None ->
      ModelFacts(
        api: fallback_api,
        context_window: fallback_context_window,
        max_output_tokens: fallback_max_output_tokens,
        reading: catalog.ReadsImages,
      )
  }
}

// The identity a strand's durable configuration captured, or nothing
// when the cell is absent or the store would not answer.
fn strand_identity(session: Session, strand: String) -> Option(ModelIdentity) {
  case session.strand_configuration(session, strand) {
    Ok(Some(session.Cell(value: configuration, ..))) ->
      Some(configuration.model)
    Ok(None) -> None
    Error(_unreadable) -> None
  }
}

/// The context window a strand is measured against: its captured
/// identity's own catalogue entry when `facts` knows it, `fallback`
/// otherwise — the rule `strand_facts` applies for admission and the
/// compaction threshold, stated once. Public so a host can build the
/// `context_remaining` seam from it before this `Config` exists: the tool
/// registry that seam lands in is one of the config's inputs.
///
/// ## Examples
///
/// ```gleam
/// // wiring.strand_window(session, facts, "main", fallback: 200_000)
/// ```
///
pub fn strand_window(
  session: Session,
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  strand: String,
  fallback fallback: Int,
) -> Int {
  case
    strand_identity(session, strand)
    |> option.then(fn(identity) { option.from_result(facts(identity)) })
  {
    Some(#(resolved, _api, _reading)) -> resolved.context_window
    None -> fallback
  }
}

// The pre-request admission, answered from the query's own configuration
// rather than from a closure frozen at boot. Three durable values ride on
// it — the intended output limit and context window overflow
// classification is stable against, and the `request_api` a deferred
// handle is validated against (ORCH-L4) — and all three are properties of
// the identity *this attempt* will reach, which a boot-time answer cannot
// know for a strand that switched models since.
//
// The fourth question is the vision rule (issue #358): an
// image-bearing request from a strand whose model cannot read images
// is admitted against the *vision head's* facts — the identity this
// attempt will actually reach — and refused in band when no usable
// vision route resolves. The image classification reads the strand's
// durable projection, the same place the threshold and overflow hooks
// decide from, so a decision taken before a crash is taken again after
// it. Dispatch classifies the request context instead, which is that
// projection after the `context` hook; the run-start digests are
// durable, so the two agree unless an extension rewrites the current
// turn, and then the request is placeholdered rather than sent blind.
// A store that will not answer classifies as imageless: a read that
// fails must not strand the conversation (the `strand_facts` rule
// above).
fn admit_projected(
  opened: Session,
  provider_gateway: Gateway,
  facts: fn(ModelIdentity) ->
    Result(#(ResolvedModel, String, catalog.ImageReading), Nil),
  fallback_api: String,
  fallback_context_window: Int,
  fallback_max_output_tokens: Int,
  query: effects.AdmissionQuery,
) -> RequestAdmission {
  let identity = query.configuration.model
  let model =
    model_facts_from(
      facts,
      fallback_api,
      fallback_context_window,
      fallback_max_output_tokens,
      identity,
    )
  case
    image_bearing_projected(opened, query.operation)
    && model.reading == catalog.TextOnly
  {
    False ->
      Admitted(
        stream_options: query.stream_options,
        intended_output_limit: model.max_output_tokens,
        context_window: model.context_window,
        api: model.api,
      )
    True ->
      case gateway.resolve(provider_gateway, model.Vision) {
        Error(_missing) -> vision.no_route_refusal(identity)
        Ok(head) ->
          case facts(identity_of(head)) {
            Ok(#(_resolved, _api, catalog.TextOnly)) ->
              vision.blind_route_refusal(head)
            Ok(#(_resolved, _api, catalog.ReadsImages)) | Error(Nil) -> {
              let head_facts =
                model_facts_from(
                  facts,
                  fallback_api,
                  fallback_context_window,
                  fallback_max_output_tokens,
                  identity_of(head),
                )
              Admitted(
                stream_options: query.stream_options,
                intended_output_limit: head_facts.max_output_tokens,
                context_window: head_facts.context_window,
                api: head_facts.api,
              )
            }
          }
      }
  }
}

// The admission for an image-bearing request a strand's own model
// cannot read: through the vision chain when one resolves and its
// head reads images, or refused in band. The head's facts — not the
// strand's — are what the request is admitted against, because they
// are the facts of the identity the request will actually reach.
// The identity a resolved model dispatches to, back on the seam's own
// terms: `Config.facts` is keyed by the durable identity shape.
fn identity_of(resolved: ResolvedModel) -> ModelIdentity {
  ModelIdentity(provider: resolved.provider, model_id: resolved.model_id)
}

// Whether the current turn of this operation's strand projection
// carries an image.
fn image_bearing_projected(opened: Session, operation: OpId) -> Bool {
  case notes.strand_of(opened, operation) {
    Error(Nil) -> False
    Ok(strand) ->
      request_image_bearing_projected(
        opened,
        operation,
        hooks.project(opened, strand).messages,
      )
  }
}

// A held batch and its tool continuations belong to one admitted run, even
// when its newest attributed prompt contains no images. Protect every image
// since the immutable source leaf. Compaction preserves parent links, so walk
// through it and count original messages once, never the copied retained tail.
// Retained tails are contiguous suffixes: if compaction removed current-run
// images, it also removed all older history. The gateway's cap to the actual
// projected count then protects exactly the surviving current-run images.
fn active_run_images(opened: Session, operation: OpId) -> Result(Int, Nil) {
  use cell <- result.try(
    session.op_meta(opened, operation) |> result.replace_error(Nil),
  )
  use cell <- result.try(option.to_result(cell, Nil))
  let meta = cell.value
  use leaf_cell <- result.try(
    session.strand_leaf(opened, meta.strand) |> result.replace_error(Nil),
  )
  use leaf_cell <- result.try(option.to_result(leaf_cell, Nil))
  use leaf <- result.try(option.to_result(leaf_cell.value, Nil))

  let scan = storage.branch_scan(leaf)
  let scan = case meta.source_leaf {
    None -> scan
    Some(source) -> storage.branch_stop_at_id(scan, source)
  }
  use entries <- result.try(
    storage.scan_branch(opened.store, scan) |> result.replace_error(Nil),
  )
  entries
  |> list.filter_map(fn(item) {
    case item {
      entry.MessageEntry(id:, message:, ..) if Some(id) != meta.source_leaf ->
        Ok(message)
      entry.MessageEntry(..)
      | entry.CompactionEntry(..)
      | entry.BranchSummaryEntry(..)
      | entry.CustomEntry(..) -> Error(Nil)
    }
  })
  |> image_budget.count
  |> Ok
}

/// Whether the dispatcher sends this generation to the `vision` chain when
/// its identity reads only text.
///
/// The admitted prompt batch is immutable for the operation. It can contain
/// an image followed by a text instruction when held inputs are released
/// together. Keep that entire image-bearing run on vision, including tool and
/// run-end continuations; the next operation gets a new batch and can recover
/// to text after a failed image run. Context classification additionally covers
/// image steers and legacy callers without operation metadata.
///
/// This is public so that a consumer with a confidentiality stake in the
/// routing, the block summarizer's live observer, asks the dispatcher's own
/// rule rather than re-deriving it from the context alone.
///
/// ## Examples
///
/// ```gleam
/// // wiring.request_image_bearing(config, operation, context)
/// ```
///
pub fn request_image_bearing(
  config: Config,
  operation: OpId,
  context: List(AgentMessage),
) -> Bool {
  request_image_bearing_projected(config.session, operation, context)
}

/// Captures the session alone for observers that share dispatch's image rule.
///
/// The registry and executable tool closures belong to tool dispatch. A live
/// summary observer needs only the operation's immutable admitted prompt batch
/// and current context, so retaining its classifier must not retain that graph.
/// Each call still reads operation metadata from the same session as dispatch.
///
/// ## Examples
///
/// ```gleam
/// // let classify = wiring.request_image_classifier(config)
/// // classify(operation, context)
/// ```
@internal
pub fn request_image_classifier(
  config: Config,
) -> fn(OpId, List(AgentMessage)) -> Bool {
  let opened = config.session
  fn(operation, context) {
    request_image_bearing_projected(opened, operation, context)
  }
}

fn request_image_bearing_projected(
  opened: Session,
  operation: OpId,
  context: List(AgentMessage),
) -> Bool {
  vision.image_bearing(context)
  || admitted_image_bearing(opened, operation) |> result.unwrap(False)
}

fn admitted_image_bearing(
  session: Session,
  operation: OpId,
) -> Result(Bool, Nil) {
  use cell <- result.try(
    session.op_meta(session, operation) |> result.replace_error(Nil),
  )
  use cell <- result.try(option.to_result(cell, Nil))
  let meta = cell.value
  use last_prompt <- result.try(case meta.intent {
    operation.RunIntent(prompt_entries:) -> list.last(prompt_entries)
    operation.CompactionIntent(..) | operation.NavigationIntent(..) ->
      Error(Nil)
  })
  let scan = storage.branch_scan(last_prompt)
  let scan = case meta.source_leaf {
    None -> scan
    Some(leaf) -> storage.branch_stop_at_id(scan, leaf)
  }
  use entries <- result.try(
    storage.scan_branch(session.store, scan) |> result.replace_error(Nil),
  )
  Ok(
    list.any(entries, fn(item) {
      case item {
        entry.MessageEntry(id:, message:, ..) ->
          Some(id) != meta.source_leaf && vision.image_bearing([message])
        entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> False
      }
    }),
  )
}

// A handle whose single event is an in-band, terminally-classified
// failure. `StreamError` with a non-transient error type is Terminal
// under `retry.classify`, so the machine fails the operation at once
// instead of burning its whole retry ladder against a surface that can
// never succeed (a transport failure would read as retryable).
fn unsupported(reason: String) -> StreamHandle {
  let events = process.new_subject()
  process.send(
    events,
    stream.Failed(error: stream.StreamError(
      api_error_type: "unsupported_request",
      message: reason,
    )),
  )
  stream.immediate(events:, cancel: fn() { Nil })
}

/// Maps a generation or poll spec onto the provider-neutral request
/// shape: the session's pinned system prompt, the strand's tool array,
/// and the projected context. Exposed for the wiring unit tests;
/// `build_effects` routes through it.
///
/// A structural summary is not a request this host makes: `dispatch`
/// refuses one before anything is built (see `prepare_dispatch`). The
/// arm here keeps the function total and deliberately carries nothing,
/// because sending a strand's context under a summarization intent would
/// be worse than sending nothing.
///
/// ## Examples
///
/// ```gleam
/// // wiring.provider_request(config, spec).messages == spec.context
/// ```
///
pub fn provider_request(
  config: Config,
  spec: effects.RequestSpec,
) -> ProviderRequest {
  provider_request_from(provider_configuration(config), spec)
}

fn provider_request_from(
  config: ProviderConfiguration,
  spec: effects.RequestSpec,
) -> ProviderRequest {
  case spec {
    effects.SummaryRequest(configuration:, ..) ->
      ProviderRequest(
        target: request_target_from(config.routing, configuration),
        system: None,
        messages: [],
        tools: [],
        max_output_tokens: None,
      )
    effects.GenerationRequest(operation:, configuration:, context:, ..) -> {
      // The vision rule's dispatch half (issue #358): the request's
      // own content, not the strand's pinned model, decides the target
      // when the two disagree about images. An image-bearing request
      // from a text-only model dispatches through the `vision` chain —
      // admitted there already, so an unresolvable chain here means
      // the registry moved between admission and dispatch, and the
      // ordinary target plus placeholders below is the honest fallback.
      // Every other request to a text-only identity has its images
      // placeholdered, because an image the model cannot read is
      // invalid input on any turn, not just the newest one.
      let reading = model_facts(config.routing, configuration.model).reading
      let routed = case
        reading == catalog.TextOnly
        && request_image_bearing_projected(config.session, operation, context)
      {
        True -> vision_route(config.routing, configuration)
        False -> None
      }
      case routed {
        Some(target) ->
          generation_request(config, configuration, context, target)
        None ->
          generation_request(
            config,
            configuration,
            case reading {
              catalog.TextOnly -> vision.placeholdered(context)
              catalog.ReadsImages -> context
            },
            request_target_from(config.routing, configuration),
          )
      }
    }

    // A poll never walks a chain: the handle it would fetch belongs to
    // the identity that minted it. See `resolved_target`.
    effects.PollRequest(configuration:, ..) ->
      generation_request(
        config,
        configuration,
        [],
        resolved_target_from(config.routing, configuration),
      )
  }
}

fn generation_request(
  config: ProviderConfiguration,
  configuration: StrandConfiguration,
  messages: List(AgentMessage),
  target: RequestTarget,
) -> ProviderRequest {
  ProviderRequest(
    target:,
    system: config.system,
    messages:,
    tools: tool_specs_from(config.definitions, configuration.active_tool_names),
    max_output_tokens: None,
  )
}

/// Resolves the captured identity into a generation's dispatch target.
///
/// **On route** — the captured identity heads a routable role's usable
/// chain — the target is `ForRole` for that role, carrying the strand's
/// per-turn thinking level as an overlay. The gateway then walks the
/// chain within the one attempt, so a rate-limited head costs a fallback
/// rather than the machine's whole retry ladder, and every target it
/// tries is asked for the budget this turn asked for.
///
/// **Off route** — a strand switched to an entry no role heads, or a
/// gateway whose routes have moved — the target is `ForResolved` on
/// exactly the captured identity, with that identity's own catalogue
/// facts (`Config.facts`) and the config's fallback counts behind them.
/// Walking there would dispatch to a model the intent never named.
///
/// Both answers are a pure function of durable state and boot
/// configuration, which is what makes a re-attempt after a crash choose
/// what the original attempt chose.
///
/// ## Examples
///
/// ```gleam
/// // wiring.request_target(config, configuration)
/// // -> model.ForRole(role: model.Main, thinking: Some(model.ThinkingHigh))
/// ```
///
pub fn request_target(
  config: Config,
  configuration: StrandConfiguration,
) -> RequestTarget {
  request_target_from(provider_routing(config), configuration)
}

fn request_target_from(
  config: ProviderRouting,
  configuration: StrandConfiguration,
) -> RequestTarget {
  case routed_role(config, configuration.model) {
    Ok(role) ->
      ForRole(
        role:,
        thinking: Some(thinking_level(configuration.thinking_level)),
      )
    Error(Nil) -> resolved_target_from(config, configuration)
  }
}

// The vision chain's target for one image-bearing request, or `None`
// when no usable chain resolves. The thinking overlay is the strand's
// own per-turn level, carried onto every target the walk attempts,
// exactly as `request_target` carries it for the strand's own route: a
// turn that raised its reasoning budget reaches the vision model with
// the same budget it would have reached its own with.
fn vision_route(
  config: ProviderRouting,
  configuration: StrandConfiguration,
) -> Option(RequestTarget) {
  case gateway.resolve(config.gateway, model.Vision) {
    Ok(_head) ->
      Some(
        vision.routed_target(
          thinking: Some(thinking_level(configuration.thinking_level)),
        ),
      )
    Error(_missing) -> None
  }
}

/// The dispatch target for a request that must reach exactly the captured
/// identity and nothing else: a deferred poll, and any generation whose
/// identity no configured role heads.
///
/// A poll is here by contract rather than by caution. A deferred handle
/// is minted by one identity and ORCH-L4 validates a settlement against
/// the `{provider, model_id, api}` the intent captured, so a poll that
/// walked a chain would ask a model for a continuation it never issued
/// and the answer would be refused as an invalid handle.
///
/// ## Examples
///
/// ```gleam
/// // wiring.resolved_target(config, configuration)
/// // -> model.ForResolved(model.ResolvedModel(provider: "acme", ..))
/// ```
///
pub fn resolved_target(
  config: Config,
  configuration: StrandConfiguration,
) -> RequestTarget {
  resolved_target_from(provider_routing(config), configuration)
}

fn resolved_target_from(
  config: ProviderRouting,
  configuration: StrandConfiguration,
) -> RequestTarget {
  let identity = configuration.model
  let facts = model_facts(config, identity)
  ForResolved(resolved: ResolvedModel(
    provider: identity.provider,
    model_id: identity.model_id,
    thinking: thinking_level(configuration.thinking_level),
    context_window: facts.context_window,
    max_output_tokens: facts.max_output_tokens,
  ))
}

// Which role, if any, this dispatch is *on route* for.
//
// An `effects.RequestSpec` carries no strand name, and one wiring config
// serves every strand of a session, so the configured role cannot say
// whether a subagent strand is on its own route. The identity can: a role
// serves a request exactly when the head of its usable chain is the
// identity the intent captured, because the head is what `gateway.resolve`
// would have stored and what the walk will try first.
//
// Candidates are taken in canonical order so the answer is a function of
// durable state alone — a tie between `main` and `subagent` routed to the
// same entry resolves to `main`, every time, on every boot. The
// configured role leads only when it is neither of them, which is the one
// case a host has said something the canonical order does not cover.
fn routed_role(
  config: ProviderRouting,
  identity: ModelIdentity,
) -> Result(Role, Nil) {
  list.find(candidate_roles(config.role), fn(role) {
    case gateway.resolve(config.gateway, role) {
      Ok(resolved) ->
        resolved.provider == identity.provider
        && resolved.model_id == identity.model_id
      Error(_missing) -> False
    }
  })
}

fn candidate_roles(configured: Role) -> List(Role) {
  case configured {
    model.Main | model.Subagent -> [model.Main, model.Subagent]
    model.Plan | model.Summarize | model.Vision | model.Custom(..) -> [
      configured,
      model.Main,
      model.Subagent,
    ]
  }
}

/// Collapses the machine's seven-point thinking scale onto the
/// provider's four-point scale.
///
/// ## Examples
///
/// ```gleam
/// assert wiring.thinking_level(strand.ThinkingMax) == model.ThinkingHigh
/// ```
///
pub fn thinking_level(level: strand.ThinkingLevel) -> model.ThinkingLevel {
  case level {
    strand.ThinkingOff -> model.ThinkingOff
    strand.ThinkingMinimal | strand.ThinkingLow -> model.ThinkingLow
    strand.ThinkingMedium -> model.ThinkingMedium
    strand.ThinkingHigh | strand.ThinkingXHigh | strand.ThinkingMax ->
      model.ThinkingHigh
  }
}

/// Lifts a catalogue entry's declared thinking level onto the machine's
/// seven-point scale — the section of `thinking_level`, so the two round
/// trip and a `medium` in the catalogue seeds a strand that dispatches at
/// medium.
///
/// This is where a route's static thinking configuration takes effect:
/// at strand *creation*, seeding the durable per-turn level a later
/// `set_config thinking_level` overwrites. It is never consulted at
/// dispatch, where the per-turn level is absolute.
///
/// ## Examples
///
/// ```gleam
/// assert wiring.strand_thinking_level(model.ThinkingHigh)
///   == strand.ThinkingHigh
/// ```
///
pub fn strand_thinking_level(
  level: model.ThinkingLevel,
) -> strand.ThinkingLevel {
  case level {
    model.ThinkingOff -> strand.ThinkingOff
    model.ThinkingLow -> strand.ThinkingLow
    model.ThinkingMedium -> strand.ThinkingMedium
    model.ThinkingHigh -> strand.ThinkingHigh
  }
}

/// The wire-facing specs for the active tool names: registry lookups
/// rendered as `ToolSpec`s in one canonical order — sorted by name,
/// duplicates collapsed — with unregistered names omitted.
///
/// ## Examples
///
/// ```gleam
/// // wiring.tool_specs(config, ["grep", "bash", "ghost"])
/// // -> [model.ToolSpec(name: "bash", ..), model.ToolSpec(name: "grep", ..)]
/// ```
///
pub fn tool_specs(config: Config, active: List(String)) -> List(ToolSpec) {
  tool_specs_from(tool_definitions(config.registry), active)
}

// The table is rendered data alone. A schema or description may be large, but
// each is required on the provider wire; a tool's executor and requirements are
// not, and must not be copied into every owner of the provider surface.
fn tool_definitions(registry: Registry) -> Dict(String, ToolSpec) {
  tool.registered(registry)
  |> list.map(fn(registered) {
    #(
      registered.name,
      ToolSpec(
        name: registered.name,
        description: registered.description,
        input_schema: registered.schema,
      ),
    )
  })
  |> dict.from_list
}

fn tool_specs_from(
  definitions: Dict(String, ToolSpec),
  active: List(String),
) -> List(ToolSpec) {
  // The sort is load-bearing, not tidiness. Tool definitions render
  // ahead of the system prompt and the messages in a provider request,
  // and prompt caching matches on an exact byte prefix of that render:
  // the Anthropic adapter hangs one cache breakpoint on the last tool
  // definition and a second on the system block, so this array is a
  // strict prefix of both cached regions. Two requests whose active
  // set is the same but whose configuration lists it in a different
  // order would render different bytes and miss the cache entirely,
  // paying the write again on every turn. Deduping is the same
  // argument plus an honesty one: a name listed twice would advertise
  // the same tool twice on the wire.
  //
  // Neither step touches authorization. `clear` below decides what may
  // run by `list.contains` on the same list, and set membership is
  // blind to order and multiplicity.
  active
  |> list.sort(string.compare)
  |> list.unique
  |> list.filter_map(fn(name) { dict.get(definitions, name) })
}

// --- the tool surface -----------------------------------------------------

/// Clears one planned call at registry level: active and registered →
/// cleared with the model's arguments and the registration's replay
/// policy; anything else → refused (the driver stages the reason as the
/// ordinary in-band error result). Broker policy composition happens at
/// execution, inside the tool's `clear_call`.
///
/// Clearance reads the registration's replay declaration and nothing
/// else, so it takes the declaration projection for the reason
/// `build_effects` gives. The registry's policy requirements belong to
/// execution, which reaches them through `tool.dispatch` in `run_tool`.
///
/// ## Examples
///
/// ```gleam
/// // wiring.clear(tool.declarations(registry), query)
/// // -> effects.Cleared(effective_arguments: .., replay: ReplayNever)
/// ```
///
pub fn clear(
  declared: tool.Declarations,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  let name = query.call.name
  case list.contains(query.configuration.active_tool_names, name) {
    False ->
      effects.ClearanceRefused(
        reason: "the tool `"
        <> name
        <> "` is not active for this strand. The system prompt lists the "
        <> "session's tools, and a strand may hold fewer; this one can call "
        <> "only: "
        <> string.join(query.configuration.active_tool_names, ", ")
        <> ".",
      )
    True ->
      case tool.declared(declared, name) {
        Ok(declaration) ->
          effects.Cleared(
            effective_arguments: query.call.arguments,
            replay: replay_policy(declaration.replay),
          )
        Error(Nil) ->
          effects.ClearanceRefused(
            reason: "the tool `" <> name <> "` is unavailable",
          )
      }
  }
}

/// Runs one cleared call: a fresh `Ctx` per call, `tool.dispatch`
/// through the registry, and the outcome wrapped as the result message
/// the runtime commits. Always `ToolCompleted` — dispatch is total and
/// tool failures are in-band `is_error` results, never harness faults.
///
/// This is where the tool vocabulary's `Terminate` meets the effect
/// plane's `Bool`. `runtime/effects`, `machine` and `core` have carried
/// `terminate` since WP-D; what they never had was a producer, so the
/// answer was welded to `False` here. It is now the tool's, converted at
/// this one boundary — which is the only place the two vocabularies
/// touch, and therefore the only place the polarity has to be written
/// down.
///
/// ## Examples
///
/// ```gleam
/// // let assert effects.ToolCompleted(result:, terminate: False) =
/// //   wiring.run_tool(config, run)
/// ```
///
pub fn run_tool(config: Config, run: effects.ToolRun) -> effects.ToolOutcome {
  let ctx = tool_context(config, run)
  let authority = {
    use access <- result.try(directories.read(config.session))
    use standing <- result.try(permissions.read_for(
      config.session,
      run.strand,
      run.call.name,
      run.arguments,
    ))
    Ok(#(access, standing))
  }
  let outcome = case authority {
    Error(reason) -> tool.failure(reason)
    Ok(#(access, standing)) -> {
      let access = directory_access.approved(access, standing)
      let base = directory_access.widen(ctx.base_policy, access)
      let base = policy.compose(base, base, standing).0
      let ctx = tool.Ctx(..ctx, directory_access: access, base_policy: base)
      tool.dispatch(config.registry, ctx, run.call.name, run.arguments)
    }
  }
  let #(now, _clock) = clock.read(config.clock)
  completed(outcome, run, now)
}

/// `run_tool` over the configuration a `tool_holder` keeps for the session.
///
/// The fetch is bounded by `holder_deadline_ms`. A holder that has exited or
/// does not answer is not a reason to crash the effect process: the runtime
/// is owed a `ToolCompleted` for the call, and an in-band error result is the
/// shape every other tool failure already takes, so the model sees that the
/// call failed and the strand carries on. `clock` supplies the timestamp
/// because the configuration the usual one comes from is the thing which
/// could not be fetched.
///
/// ## Examples
///
/// ```gleam
/// // let assert effects.ToolCompleted(result:, ..) =
/// //   wiring.run_tool_held(holder, config.clock, run)
/// ```
///
pub fn run_tool_held(
  holder: tool_holder.Holder(Config),
  clock: Clock,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  case tool_holder.fetch(holder, within_ms: holder_deadline_ms) {
    Ok(config) -> run_tool(config, run)
    Error(unavailable) -> {
      let reason = case unavailable {
        tool_holder.Gone -> "the session's tool configuration is gone"
        tool_holder.TimedOut ->
          "the session's tool configuration did not answer in time"
      }
      let #(now, _clock) = clock.read(clock)
      completed(
        tool.failure(
          "the tool `" <> run.call.name <> "` did not run: " <> reason,
        ),
        run,
        now,
      )
    }
  }
}

// How long a tool run waits for the holder to hand back the configuration.
// The holder does nothing but answer, so this is a scheduler stall's worth
// of patience rather than an operation's; a holder that has exited answers
// at once through its monitor and never reaches it.
const holder_deadline_ms = 5000

// The one place a tool outcome becomes the effect plane's answer, shared by
// the executed and the refused-to-run paths so both build the same shape.
fn completed(
  outcome: tool.ToolOutcome,
  run: effects.ToolRun,
  now: Int,
) -> effects.ToolOutcome {
  effects.ToolCompleted(
    result: tool.to_result_message(
      outcome,
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      timestamp: now,
    ),
    terminate: terminates(outcome.terminate),
  )
}

/// The tool vocabulary's answer as the effect plane's frozen field.
///
/// ## Examples
///
/// ```gleam
/// assert wiring.terminates(tool.TerminateRun)
/// ```
///
pub fn terminates(terminate: tool.Terminate) -> Bool {
  case terminate {
    tool.ContinueRun -> False
    tool.TerminateRun -> True
  }
}

/// The per-call tool context: the caller's durable coordinates from the
/// run, everything else from the config. The broker seam is
/// `tool.broker_runner` over the config's live broker; the filesystem
/// seam is the production simplifile-backed one.
///
/// The whole coordinate quadruple travels rather than just op and step,
/// because the agent tools are judged against `strand` and derive a
/// spawned child's name from `{operation, step, source index}` — the same
/// triple a replayed call arrives under, which is what makes a spawn
/// idempotent. Every one of them comes from the driver, never from the
/// model.
///
/// `grants` travels the same way, and for the same reason: they are the
/// grants *this call's* clearance consumed, decoded here from the
/// broker's escalation vocabulary. There is deliberately no session-wide
/// grant list to fall back on — a grant that is not attributable to the
/// call in hand widens nothing (design §5.3: one re-execution of the
/// denied action, never a silent session widening).
///
/// ## Examples
///
/// ```gleam
/// // wiring.tool_context(config, run).workspace == config.workspace
/// ```
///
pub fn tool_context(config: Config, run: effects.ToolRun) -> tool.Ctx {
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace: config.workspace,
    strand: run.strand,
    op_id: run.operation,
    step_id: run.step_id,
    source_index: run.source_index,
    base_policy: config.base_policy,
    grants: run_grants(run),
    demand: config.demand,
    env: config.env,
    clock: config.clock,
    filesystem: fs.real_filesystem(),
    blob_root: config.blob_root,
    clear_call: escalating_runner(config, run),
    raise_refusal: raising_seam(config, run),
    observe_output: config.observe_output(run),
  )
}

// The other door onto the same escalation plane: the one a tool knocks on
// when it met a policy refusal somewhere `clear_call` is not.
//
// `code_mode` is why it exists. Its clearances happen inside the
// code-mode pipeline, against the broker that pipeline holds, so the
// runner above never sees them and a refused execution used to reach no
// record at all — grants could be spent there and nothing could mint one
// (#97). Everything below this line is the runner's own reasoning, one
// seam over: the same `Refused` value, the same seam, the same "one
// re-execution of exactly this call" on an approval.
//
// **Once for the whole execution, not once per clearance.** A code-mode
// program's clearances happen while a satellite is alive, and parking one
// of them parks inside a live node: the program's own capability call
// times out long before a human answers, the execution's pooled wall
// deadline runs down while they decide, and the node holds one
// outstanding effect throughout. Consent is the sharper argument. An
// approval binds to the *call's* arguments (#65) and a `code_mode` call's
// arguments are the program, so a human asked about an individual
// `cap_call` would be answering about something no client rendered.
// Asked once, about the whole submission, the consent unit is exactly
// what was shown — and exactly what the action digest already covers.
//
// The tool decides *whether* to raise, because only the tool knows which
// of its refusals a re-execution could actually repair; this decides what
// happens to the one it raises.
fn raising_seam(
  config: Config,
  run: effects.ToolRun,
) -> fn(tool.RaisedRefusal) -> tool.Escalated {
  fn(raised: tool.RaisedRefusal) {
    let tool.RaisedRefusal(denial:, deadline_ms:) = raised
    case config.escalations.refused(refused_call(run, denial, deadline_ms)) {
      escalate.Settle -> tool.Settle
      escalate.Resume(grants:) -> tool.Resume(grants:)
    }
  }
}

// One refused call as the escalation seam sees it. Both doors build it
// the same way and from the same place — the driver's `ToolRun` — so a
// record raised through either is scoped to one real call in the tree and
// bound to the arguments a resumption would re-execute with.
fn refused_call(
  run: effects.ToolRun,
  denial: Denial,
  deadline_ms: Int,
) -> escalate.Refused {
  escalate.Refused(
    operation: run.operation,
    strand: run.strand,
    step_id: run.step_id,
    source_index: run.source_index,
    call_id: run.call.id,
    tool: run.call.name,
    denial:,
    // The post-clearance arguments, which is what a resumption
    // re-executes with and therefore what a human's consent is bound
    // to — never `run.call.arguments`, which a clearance hook may have
    // rewritten out from under the execution.
    arguments: run.arguments,
    deadline_ms:,
  )
}

// The broker seam a tool actually gets: the production runner, plus the
// one thing a tool must not have to know about.
//
// A `PolicyRefused` is the only refusal a human can overturn, and it is
// raised *before* the broker reserves budget or borrows a helper, so a
// refused call has spent nothing and can be asked again for free. The
// seam decides what happens — record it, hold it, or settle it — and on
// an approval the same spec is re-cleared with the approved grants
// appended. That is the whole "one re-execution under the widened
// policy" of design §5.3: exactly one retry, of exactly this call, and
// if the widened policy still does not satisfy the tool the second
// refusal stands in band.
//
// Every other refusal — an invalid policy, a spent budget, a missing
// helper — passes straight through: none of them is a decision a human
// is being asked to make.
fn escalating_runner(
  config: Config,
  run: effects.ToolRun,
) -> fn(broker.CallSpec, Subject(broker.CallEvent)) ->
  Result(tool.RunningCall, broker.Refusal) {
  let direct =
    tool.broker_runner(broker: config.broker, waiting: config.broker_timeout_ms)
  fn(spec: broker.CallSpec, events) {
    case direct(spec, events) {
      Error(broker.PolicyRefused(denial:)) -> {
        let refused = refused_call(run, denial, spec.budget.deadline_ms)
        case config.escalations.refused(refused) {
          escalate.Settle -> Error(broker.PolicyRefused(denial:))
          escalate.Resume(grants: approved) ->
            direct(
              broker.CallSpec(
                ..spec,
                grants: list.append(spec.grants, approved),
              ),
              events,
            )
        }
      }
      other -> other
    }
  }
}

// The typed grants a run carries, decoded from the opaque escalation
// vocabulary the runtime moves them in. Total by construction: a payload
// that will not decode is dropped rather than faulted on, because
// skipping a grant can only *narrow* what the call receives and the call
// still settles in band under whatever remains. Faulting instead would
// turn a corrupt durable byte into a halted strand.
fn run_grants(run: effects.ToolRun) -> List(Grant) {
  list.filter_map(run.grants, fn(payload) {
    grants.decode(payload) |> result.replace_error(Nil)
  })
}

/// Whether the named tool's registration declares safe replay (pi §4.5:
/// stored and current must both say safe). Unregistered names are never
/// safe.
///
/// It takes the declaration projection rather than the configuration
/// because that is all it reads, and because the difference is a copy of
/// the tool registry in every process of a session assembly — see
/// `build_effects`.
///
/// ## Examples
///
/// ```gleam
/// // wiring.replay_still_safe(tool.declarations(registry), "fs_read")
/// //   == True
/// ```
///
pub fn replay_still_safe(declared: tool.Declarations, name: String) -> Bool {
  case tool.declared(declared, name) {
    Ok(declaration) ->
      case declaration.replay {
        tool.Safe -> True
        tool.Never -> False
      }
    Error(Nil) -> False
  }
}

/// The named tool's scheduling constraint, mapped from its registration.
/// Unregistered names report exclusive — the safe direction, and the
/// clearance that follows refuses them anyway.
///
/// ## Examples
///
/// ```gleam
/// // wiring.execution_mode(tool.declarations(registry), "fs_read")
/// //   == effects.ConcurrentExecution
/// ```
///
pub fn execution_mode(
  declared: tool.Declarations,
  name: String,
) -> effects.ExecutionMode {
  case tool.declared(declared, name) {
    Ok(declaration) ->
      case declaration.execution_mode {
        tool.Exclusive -> effects.ExclusiveExecution
        tool.Concurrent -> effects.ConcurrentExecution
      }
    Error(Nil) -> effects.ExclusiveExecution
  }
}

/// Maps the tool package's replay declaration onto the machine's
/// persisted replay policy.
///
/// ## Examples
///
/// ```gleam
/// assert wiring.replay_policy(tool.Never) == operation.ReplayNever
/// ```
///
pub fn replay_policy(safety: tool.ReplaySafety) -> ReplayPolicy {
  case safety {
    tool.Never -> operation.ReplayNever
    tool.Safe -> operation.ReplaySafe
  }
}
