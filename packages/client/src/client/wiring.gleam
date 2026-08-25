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
//// ## Mapping decisions (each recorded here because the spec leaves the
//// seam's production shape open)
////
//// - **Provider identity.** Effect intents capture a durable
////   `ModelIdentity` (spec §1.5: durable state stores the resolved
////   `{provider, model_id}`), so every dispatch uses `ForResolved` —
////   never `ForRole`, whose fallback walk would let recovery re-dispatch
////   to a different identity than the one committed in the intent. The
////   gateway's `resolve` on the configured role supplies the full model
////   facts (context window, output ceiling, thinking) when it agrees
////   with the captured identity; when it disagrees or fails, the
////   captured identity is kept and the config's fallback facts fill the
////   gaps, so a stored identity keeps working after a routing change.
//// - **Thinking levels.** The machine's seven-point scale collapses onto
////   the provider's four-point scale: off→off, minimal/low→low,
////   medium→medium, high/xhigh/max→high. The strand's per-turn level is
////   carried onto the dispatch target on every path — including when the
////   gateway's role resolution supplies the other model facts — so a
////   route's static thinking configuration never overrides what the
////   turn asked for.
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
//// - **Polls and summaries.** `ProviderRequest` cannot express a
////   deferred continuation fetch, and structural summaries have no
////   provider surface yet, so `PollRequest`/`SummaryRequest` settle
////   immediately as in-band provider errors rather than dispatching a
////   nonsensical generation; the failure is terminally classified so
////   the retry ladder is not burned on a permanently-absent surface.
////   Default hooks never reach either path
////   (resolution always succeeds but responses never settle `Deferred`,
////   and structural decisions are declined). Recorded as a spec gap for
////   M3.
//// - **Clearance** is registry-level: the call's name must be in the
////   intent's captured `active_tool_names` and registered; the effective
////   arguments are the model's arguments unchanged (no rewriting hook
////   yet), and the replay policy is the registration's declared safety.
////   Policy composition happens later, inside the tool's own
////   `clear_call` against the broker — a clearance here is not an
////   execution grant.
//// - **Execution.** Each `ToolRun` gets a fresh `Ctx` (op/step ids from
////   the run, broker/filesystem/blob seams from the config) and goes
////   through `tool.dispatch`. Dispatch is total: unknown names and every
////   tool failure come back as in-band `is_error` results, so the
////   adapter always answers `ToolCompleted`; `ToolFailed` remains the
////   runtime's own path for a dead effect worker. The persisted
////   `ToolRun.replay` is deliberately not consulted — replay decisions
////   were made durably at intent time. No core tool terminates a run, so
////   `terminate` is always `False`.
//// - **Replay-still-safe** consults the *live* registry (pi §4.5: stored
////   and current declarations must both say safe); an unregistered name
////   is never safe.
//// - **Hooks** are `runtime/effects.default_hooks()` here: no injected
////   messages, unlimited admission windows, no compaction. The real hook
////   registry is post-M2 work. A host that wires a messaging plane wraps
////   this record afterwards — `client/serve` composes
////   `client/agency.reaping_hooks` over it so a run's end reaps the
////   undetached children that run spawned — which is why the field is
////   built here rather than fixed here.
//// - **Enforcement demand** is caller-chosen config: production sessions
////   pass `exec.FullEnforcement`; the conformance container's helper
////   runs degraded (no bwrap/Landlock), so its suites pass
////   `exec.BestEffort` and assert on the helper's honest enforcement
////   report instead.

import broker/broker.{type Broker}
import broker/exec.{type EnforcementDemand}
import broker/policy.{type Grant, type SandboxPolicy}
import core/clock.{type Clock}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import machine/operation.{type ReplayPolicy}
import machine/strand.{type StrandConfiguration}
import provider/gateway.{type Gateway}
import provider/model.{
  type ProviderRequest, type RequestTarget, type Role, type ToolSpec,
  ForResolved, ProviderRequest, ResolvedModel, ToolSpec,
}
import provider/stream.{type StreamHandle}
import runtime/effects.{type Effects}
import tools/fs
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
/// positive token counts used only when the configured role does not
/// resolve to the captured identity.
pub type Config {
  Config(
    /// The provider gateway, fully routed.
    gateway: Gateway,
    /// The role whose route should serve this strand's requests.
    role: Role,
    /// The system prompt sent with every generation, if any.
    system: Option(String),
    /// Context-window facts for identities the gateway cannot resolve.
    fallback_context_window: Int,
    /// Output ceiling for identities the gateway cannot resolve.
    fallback_max_output_tokens: Int,
    /// How long the effect process waits for a provider terminal event.
    provider_timeout_ms: Int,
    /// The running ToolBroker.
    broker: Broker,
    /// Bound on the synchronous broker clearance call, in milliseconds.
    broker_timeout_ms: Int,
    /// The tool registry (`tool.registry([...])`).
    registry: Registry,
    /// Absolute workspace root.
    workspace: String,
    /// Absolute blob-overflow directory (spec §3.2).
    blob_root: String,
    /// The session's base sandbox policy.
    base_policy: SandboxPolicy,
    /// Grants from consumed escalation approvals.
    grants: List(Grant),
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
  )
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
  effects.Effects(
    clock: config.clock,
    entropy: config.entropy,
    timers: effects.real_timers(),
    provider: effects.ProviderSurface(
      request: fn(spec) { dispatch(config, spec) },
      timeout_ms: config.provider_timeout_ms,
    ),
    tools: effects.ToolSurface(
      clear: fn(query) { clear(config, query) },
      run: fn(run) { run_tool(config, run) },
      replay_still_safe: fn(name) { replay_still_safe(config, name) },
      execution_mode: fn(name) { execution_mode(config, name) },
    ),
    hooks: effects.default_hooks(),
  )
}

// --- the provider surface -------------------------------------------------

// Dispatches one request spec. Generation requests go to the gateway;
// polls and summaries settle immediately in-band (see the module doc).
fn dispatch(config: Config, spec: effects.RequestSpec) -> StreamHandle {
  case spec {
    effects.GenerationRequest(..) ->
      gateway.request(config.gateway, provider_request(config, spec))
    effects.PollRequest(..) ->
      unsupported("deferred polls are not wired to a provider surface yet")
    effects.SummaryRequest(..) ->
      unsupported(
        "structural summaries are not wired to a provider surface yet",
      )
  }
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
  stream.StreamHandle(events:)
}

/// Maps one request spec onto the provider-neutral request shape.
/// Exposed for the wiring unit tests; `build_effects` routes through it.
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
  let #(configuration, messages) = case spec {
    effects.GenerationRequest(configuration:, context:, ..) -> #(
      configuration,
      context,
    )
    effects.PollRequest(configuration:, ..) -> #(configuration, [])
    effects.SummaryRequest(configuration:, ..) -> #(configuration, [])
  }
  ProviderRequest(
    target: request_target(config, configuration),
    system: config.system,
    messages:,
    tools: tool_specs(config, configuration.active_tool_names),
    max_output_tokens: None,
  )
}

/// Resolves the captured identity into a dispatch target: always
/// `ForResolved` (recovery must re-dispatch exactly what was committed);
/// the gateway's role resolution supplies the model facts when it agrees
/// with the captured identity, and the config's fallback facts fill in
/// otherwise. On both paths the target's `thinking` is the strand's
/// per-turn level, never the route's static configuration — a turn that
/// raises or lowers its thinking budget must reach the provider with
/// exactly that budget.
///
/// ## Examples
///
/// ```gleam
/// // wiring.request_target(config, configuration)
/// // -> model.ForResolved(model.ResolvedModel(provider: "acme", ..))
/// ```
///
pub fn request_target(
  config: Config,
  configuration: StrandConfiguration,
) -> RequestTarget {
  let identity = configuration.model
  let thinking = thinking_level(configuration.thinking_level)
  let fallback =
    ResolvedModel(
      provider: identity.provider,
      model_id: identity.model_id,
      thinking:,
      context_window: config.fallback_context_window,
      max_output_tokens: config.fallback_max_output_tokens,
    )
  case gateway.resolve(config.gateway, config.role) {
    Ok(resolved) ->
      case
        resolved.provider == identity.provider
        && resolved.model_id == identity.model_id
      {
        True -> ForResolved(resolved: ResolvedModel(..resolved, thinking:))
        False -> ForResolved(resolved: fallback)
      }
    Error(_missing) -> ForResolved(resolved: fallback)
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
  |> list.filter_map(fn(name) {
    case tool.lookup(config.registry, name) {
      Ok(registered) ->
        Ok(ToolSpec(
          name: registered.name,
          description: registered.description,
          input_schema: registered.schema,
        ))
      Error(Nil) -> Error(Nil)
    }
  })
}

// --- the tool surface -----------------------------------------------------

/// Clears one planned call at registry level: active and registered →
/// cleared with the model's arguments and the registration's replay
/// policy; anything else → refused (the driver stages the reason as the
/// ordinary in-band error result). Broker policy composition happens at
/// execution, inside the tool's `clear_call`.
///
/// ## Examples
///
/// ```gleam
/// // wiring.clear(config, query)
/// // -> effects.Cleared(effective_arguments: .., replay: ReplayNever)
/// ```
///
pub fn clear(
  config: Config,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  let name = query.call.name
  case list.contains(query.configuration.active_tool_names, name) {
    False ->
      effects.ClearanceRefused(
        reason: "the tool `" <> name <> "` is not active for this strand",
      )
    True ->
      case tool.lookup(config.registry, name) {
        Ok(registered) ->
          effects.Cleared(
            effective_arguments: query.call.arguments,
            replay: replay_policy(registered.replay),
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
/// ## Examples
///
/// ```gleam
/// // let assert effects.ToolCompleted(result:, terminate: False) =
/// //   wiring.run_tool(config, run)
/// ```
///
pub fn run_tool(config: Config, run: effects.ToolRun) -> effects.ToolOutcome {
  let ctx = tool_context(config, run)
  let outcome =
    tool.dispatch(config.registry, ctx, run.call.name, run.arguments)
  let #(now, _clock) = clock.read(config.clock)
  effects.ToolCompleted(
    result: tool.to_result_message(
      outcome,
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      timestamp: now,
    ),
    // No core tool terminates a run; the field exists for future tools.
    terminate: False,
  )
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
/// ## Examples
///
/// ```gleam
/// // wiring.tool_context(config, run).workspace == config.workspace
/// ```
///
pub fn tool_context(config: Config, run: effects.ToolRun) -> tool.Ctx {
  tool.Ctx(
    workspace: config.workspace,
    strand: run.strand,
    op_id: run.operation,
    step_id: run.step_id,
    source_index: run.source_index,
    base_policy: config.base_policy,
    grants: config.grants,
    demand: config.demand,
    env: config.env,
    clock: config.clock,
    filesystem: fs.real_filesystem(),
    blob_root: config.blob_root,
    clear_call: tool.broker_runner(
      broker: config.broker,
      waiting: config.broker_timeout_ms,
    ),
  )
}

/// Whether the named tool's current registration declares safe replay
/// (pi §4.5: stored and current must both say safe). Unregistered names
/// are never safe.
///
/// ## Examples
///
/// ```gleam
/// // wiring.replay_still_safe(config, "fs_read") == True
/// ```
///
pub fn replay_still_safe(config: Config, name: String) -> Bool {
  case tool.lookup(config.registry, name) {
    Ok(registered) ->
      case registered.replay {
        tool.Safe -> True
        tool.Never -> False
      }
    Error(Nil) -> False
  }
}

/// The named tool's current scheduling constraint, mapped from its
/// registration. Unregistered names report exclusive — the safe
/// direction, and the clearance that follows refuses them anyway.
///
/// ## Examples
///
/// ```gleam
/// // wiring.execution_mode(config, "fs_read")
/// //   == effects.ConcurrentExecution
/// ```
///
pub fn execution_mode(config: Config, name: String) -> effects.ExecutionMode {
  case tool.lookup(config.registry, name) {
    Ok(registered) ->
      case registered.execution_mode {
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
