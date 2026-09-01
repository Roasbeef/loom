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
//// - **Summaries.** A `SummaryRequest` becomes a real generation against
////   the `Summarize` role, carrying the frozen `op.preparation` register
////   serialized by `prompt/summary`, the ported summarization prompts
////   from the summary pack, and **nothing else** — no system prompt, no
////   tool array. It is the one dispatch made `ForRole` unconditionally,
////   chain walk and all: a summary is published as text rather than as a
////   response attributed to a model, so there is no durable identity
////   contract to honour and a cheaper fallback is pure gain.
////
////   The omissions are the cache decision, not an oversight. The
////   Anthropic adapter hangs its two one-hour breakpoints on the tool
////   array and the system block, so a request carrying neither writes
////   no long-lived cache entry and cannot disturb the session's own
////   pinned head; a one-shot prompt read once must not pay a
////   cache-write premium (pi's `cacheRetention: "none"`, expressed as a
////   request shape). See `docs/design-notes/compaction-and-memory.md`,
////   Part 2. The settled text goes to `client/summaries`, where the
////   `summary_progress` hook — whose frozen signature carries only
////   `(operation, task, attempt)` — reads it back.
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
////   after it); `structural_decision` selects generation, which is what
////   sends a compaction to a provider instead of declining it; and
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
import client/escalate.{type Escalations}
import client/grants
import client/provider_relay
import client/summaries.{type Summaries}
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation.{
  type CompactionSettings, type ReplayPolicy, type StructuralPreparation,
  OperationError,
}
import machine/planner.{
  type ModelResolution, type RequestAdmission, type SummaryProgress, Admitted,
  ModelResolved, ModelUnresolved, SummaryFailed, SummaryProduced,
  VerdictGenerate,
}
import machine/strand.{type ModelIdentity, type StrandConfiguration}
import prompt/pack.{type Pack}
import prompt/summary
import provider/gateway.{type Gateway}
import provider/model.{
  type ProviderRequest, type RequestTarget, type ResolvedModel, type Role,
  type ToolSpec, ForResolved, ForRole, ProviderRequest, ResolvedModel, ToolSpec,
}
import provider/retry
import provider/stream.{type StreamHandle}
import runtime/effects.{type Effects}
import runtime/hooks
import session/session.{type Session}
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
/// positive token counts used only for an identity `facts` does not know.
pub type Config {
  Config(
    /// The provider gateway, fully routed.
    gateway: Gateway,
    /// The role `resolution` asks the gateway about when the summary
    /// role does not resolve. Dispatch does not read it: the role a
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
    facts: fn(ModelIdentity) -> Result(#(ResolvedModel, String), Nil),
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
    /// The role whose route serves structural summary requests.
    /// `model.Summarize` in production; a host with no separate
    /// summarization route points it at the same role as `role`.
    summary_role: Role,
    /// The decoded summarization pack (`prompt/summary`). A host reads
    /// it from `default.summary_source` or from an operator's file, and
    /// decodes it through `pack.decode` like any other pack.
    summary_pack: Pack,
    /// Where settled summary text waits between the effect process that
    /// received it and the hook that reports on it.
    summaries: Summaries,
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
    /// The tool registry (`tool.registry([...])`).
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
    provider: recording_summaries(
      effects.PreparedProviderSurface(
        request: fn(spec) { dispatch(config, spec) },
        prepare: fn(spec) { prepare_dispatch(config, spec) },
        timeout_ms: config.provider_timeout_ms,
      ),
      into: config.summaries,
    ),
    tools: effects.ToolSurface(
      clear: fn(query) { clear(config, query) },
      run: fn(run) { run_tool(config, run) },
      replay_still_safe: fn(name) { replay_still_safe(config, name) },
      execution_mode: fn(name) { execution_mode(config, name) },
    ),
    hooks: compaction_hooks(config),
  )
}

/// The hooks a production session runs: real admission from the
/// gateway's model facts, the two compaction signals over the strand's
/// durable projection, generation as the structural verdict, and the
/// summary-progress hook that reads back what `dispatch` filed.
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
  let projection = fn(strand) { hooks.project(config.session, strand) }

  // The threshold's window is the *strand's*, not the session's. One
  // `Effects` record serves every strand, and a strand switched to a
  // catalogue entry with a different context window must be compacted
  // against that window or the clamp fires at the wrong size — early on a
  // larger model, never on a smaller one. `ThresholdQuery` carries the
  // strand name and nothing else, so the configuration is read back from
  // the durable store, the same place every other hook decides from.
  let threshold_for = fn(strand) {
    hooks.threshold(
      config.compaction,
      context_window: strand_facts(config, strand).context_window,
      projection:,
      estimate: hooks.estimate_message,
    )
  }
  hooks.new()
  |> hooks.with_admission(fn(query: effects.AdmissionQuery) {
    admit(config, query)
  })
  |> hooks.with_threshold(fn(query: effects.ThresholdQuery) {
    threshold_for(query.strand)(query)
  })
  |> hooks.with_overflow_preparation(hooks.overflow(
    config.compaction,
    projection:,
    estimate: hooks.estimate_message,
  ))
  // Every structural decision goes to the provider. Loom has no hook
  // that supplies a summary itself — `VerdictSupplied` exists for a host
  // that does, and a harness that used it here would be answering its
  // own compaction.
  |> hooks.with_structural_decision(fn(_operation, _task) { VerdictGenerate })
  |> hooks.with_summary_progress(fn(operation, task, attempt) {
    summary_progress(config, operation, task, attempt)
  })
  |> hooks.with_resolution(fn(configuration) {
    resolution(config, configuration)
  })
  |> hooks.build
}

// --- the provider surface -------------------------------------------------

// Dispatches one request spec. Generation and summary requests go to the
// gateway; polls settle immediately in-band (see the module doc).
fn dispatch(config: Config, spec: effects.RequestSpec) -> StreamHandle {
  prepare_dispatch(config, spec)
  |> stream.start_prepared
}

// Production dispatch keeps role resolution and secret lookup behind the
// begin permit. The immediate error cases still use the same shape so every
// wrapper can apply one prepare, publish, begin protocol.
fn prepare_dispatch(
  config: Config,
  spec: effects.RequestSpec,
) -> stream.PreparedStream {
  case spec {
    effects.GenerationRequest(..) ->
      gateway.prepare(config.gateway, provider_request(config, spec))
    effects.PollRequest(..) ->
      prepared_unsupported(
        "deferred polls are not wired to a provider surface yet",
      )
    effects.SummaryRequest(..) ->
      case summary_provider_request(config, spec) {
        Ok(request) -> gateway.prepare(config.gateway, request)

        // No preparation register behind a dispatched summary request is
        // corruption, not a transient fault: the machine writes the
        // preparation and the intent in one transaction. Fail it
        // terminally rather than asking a provider to summarize nothing.
        Error(reason) -> prepared_unsupported(reason)
      }
  }
}

fn prepared_unsupported(reason: String) -> stream.PreparedStream {
  stream.PreparedStream(handle: unsupported(reason), begin: fn() { Nil })
}

// --- recording a settled summary -------------------------------------------

/// Wraps a provider surface so a settled structural summary is filed in
/// the sink on its way past, keyed by the `(operation, task, attempt)`
/// triple the `summary_progress` hook is asked about. Requests of every
/// other kind pass through untouched.
///
/// The wrapper is a composition seam, like `gateway.tap_provider`, and
/// exists for the same reason: a host with its own provider surface —
/// the scripted M3 demo is one — must be able to run the *real*
/// compaction hooks rather than an imitation of them, and those hooks
/// read what this records. Wrapping the surface is what makes the two
/// separable.
///
/// The relay owns the inner stream and records the terminal **before**
/// forwarding it, so by the time the effect process reports the request
/// settled and the driver asks for progress, the text is already there.
/// The shared relay also propagates explicit cancellation and consumer
/// death to the inner stream.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..scripted,
/// //   provider: wiring.recording_summaries(scripted, into: sink))
/// ```
///
pub fn recording_summaries(
  surface: effects.ProviderSurface,
  into summaries: Summaries,
) -> effects.ProviderSurface {
  effects.PreparedProviderSurface(
    timeout_ms: effects.provider_timeout_ms(surface),
    request: fn(spec) {
      case summary_observer(spec, summaries) {
        Some(observe) -> provider_relay.wrap(surface, spec, observe)
        None -> surface.request(spec)
      }
    },
    prepare: fn(spec) {
      case summary_observer(spec, summaries) {
        Some(observe) -> provider_relay.prepare(surface, spec, observe)
        None -> effects.prepare_provider(surface, spec)
      }
    },
  )
}

// The callback is derived before either facade starts work, keeping summary
// identity identical across immediate callers and the runtime's prepared path.
fn summary_observer(
  spec: effects.RequestSpec,
  summaries: Summaries,
) -> Option(fn(stream.StreamEvent) -> Nil) {
  case spec {
    effects.SummaryRequest(operation:, task_id:, attempt:, ..) -> {
      let key = summaries.key(operation, task_id, attempt)
      Some(fn(event) { record_summary_event(event, summaries, key) })
    }
    _ -> None
  }
}

fn record_summary_event(
  event: stream.StreamEvent,
  sink: Summaries,
  key: String,
) -> Nil {
  case event {
    stream.Delta(..) -> Nil
    stream.Settled(message:, usage:) -> {
      summaries.record(
        sink,
        key:,
        settlement: settlement_of(stream.message(message), usage),
      )
    }
    stream.Failed(error:) -> {
      summaries.record(
        sink,
        key:,
        settlement: summaries.Failed(
          message: stream.describe_error(error),
          retryable: case retry.classify(error) {
            retry.Retryable(backoff_hint_ms: _) -> True
            retry.Terminal -> False
          },
        ),
      )
    }
  }
}

/// How one settled summary response reads as a settlement.
///
/// A response that reached for a tool is a **failed** attempt (pi): the
/// summarizer was sent no tool array, so a call in the answer means it
/// did something other than summarize, and publishing its prose as a
/// summary would be guessing. It is retryable — a later attempt may
/// behave — and so is an answer with no text at all.
///
/// ## Examples
///
/// ```gleam
/// // wiring.settlement_of(assistant_text_response, usage)
/// // -> summaries.Produced(summary: "…", usage: Some(usage))
/// ```
///
pub fn settlement_of(
  settled: AgentMessage,
  usage: message.Usage,
) -> summaries.Settlement {
  case settled {
    message.AssistantMessage(content:, ..) ->
      case summary_text(content) {
        Error(reason) -> summaries.Failed(message: reason, retryable: True)
        Ok(text) -> summaries.Produced(summary: text, usage: Some(usage))
      }
    _ ->
      summaries.Failed(
        message: "the summarizer settled something other than an assistant response",
        retryable: True,
      )
  }
}

fn summary_text(
  content: List(message.AssistantBlock),
) -> Result(String, String) {
  let called =
    list.any(content, fn(block) {
      case block {
        message.AssistantToolCall(..) -> True
        _ -> False
      }
    })
  case called {
    True -> Error("the summarizer attempted a tool call instead of summarizing")
    False -> {
      let text =
        content
        |> list.filter_map(fn(block) {
          case block {
            message.AssistantText(text:, ..) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> string.join("\n")
        |> string.trim
      case text {
        "" -> Error("the summarizer produced no text")
        _ -> Ok(text)
      }
    }
  }
}

/// The provider request one structural summary is made as: the
/// summarization prompts and the serialized preparation in a single user
/// message, no system prompt, no tools.
///
/// The shape is the cache decision. The Anthropic adapter spends its two
/// one-hour breakpoints on the tool array and the system block, so a
/// request carrying neither writes no long-lived cache entry — pi's
/// `cacheRetention: "none"` for a prompt that will be read exactly once.
/// It also means a summary request cannot disturb the session's own
/// pinned head, because it never sends one.
///
/// `Error` when the frozen preparation register is not in hand.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(request) = wiring.summary_provider_request(config, spec)
/// // assert request.tools == [] && request.system == option.None
/// ```
///
pub fn summary_provider_request(
  config: Config,
  spec: effects.RequestSpec,
) -> Result(ProviderRequest, String) {
  case spec {
    effects.SummaryRequest(preparation: None, ..) ->
      Error(
        "a structural summary was dispatched without its preparation register",
      )
    effects.SummaryRequest(
      preparation: Some(preparation),
      configuration:,
      operation:,
      ..,
    ) ->
      Ok(ProviderRequest(
        target: summary_target(config, configuration),
        system: None,
        messages: [
          summary_message(
            config,
            preparation,
            instructions_for(config, operation),
          ),
        ],
        tools: [],
        max_output_tokens: None,
      ))
    _ -> Error("that request spec is not a structural summary")
  }
}

// Summaries route through the `Summarize` role when one is configured —
// as a role, chain walk and all, so a busy summarizer falls to the next
// entry instead of failing the compaction. A session with no such route
// summarizes with the strand's own target. Routing a summary to a cheaper
// model is the whole reason the role exists (design §4.4), and unlike a
// generation there is no durable identity contract to honour here: the
// summary is published as text, not as a response attributed to a model.
//
// `thinking: None` is the one place a route's own declared level is left
// standing. There is no per-turn level to carry — the strand's belongs to
// the conversation, not to the one-shot prompt being summarized — so the
// operator's `thinking` on the summarization entry is what applies.
fn summary_target(
  config: Config,
  configuration: StrandConfiguration,
) -> RequestTarget {
  case gateway.resolve(config.gateway, config.summary_role) {
    Ok(_resolved) -> ForRole(role: config.summary_role, thinking: None)
    Error(_missing) -> request_target(config, configuration)
  }
}

// The operator's `Compact(strand, instructions)` text, read from the
// operation's durable state. It reaches the provider through here rather
// than through the preparation because `StructuralPreparation` has no
// field for it: the preparation is the *input* the decision hook froze,
// and the instructions are a property of the operation that asked for
// the compaction.
fn instructions_for(config: Config, operation: OpId) -> Option(String) {
  case session.op_state(config.session, operation) {
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

// One user message: the summarization system prompt, then the
// instruction the preparation selects. Both come from the pack, so every
// sentence a summarizer reads is swappable data.
fn summary_message(
  config: Config,
  preparation: StructuralPreparation,
  instructions: Option(String),
) -> AgentMessage {
  let input = case preparation {
    operation.CompactionPreparation(
      messages_to_summarize:,
      turn_prefix_messages:,
      previous_summary:,
      file_ops:,
      ..,
    ) ->
      summary.Compaction(
        conversation: summary.serialize(list.append(
          turn_prefix_messages,
          messages_to_summarize,
        )),
        previous_summary:,
        custom_instructions: instructions,
        files_read: file_ops.read,
        files_modified: list.sort(
          list.unique(list.append(file_ops.written, file_ops.edited)),
          string.compare,
        ),
      )
    operation.BranchSummaryPreparation(messages:, ..) ->
      summary.Branch(
        conversation: summary.serialize(messages),
        custom_instructions: instructions,
      )
  }
  let text =
    summary.system(config.summary_pack)
    <> "\n\n"
    <> summary.instruction(config.summary_pack, input)
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

/// What the sink holds for one structural attempt, as the machine's
/// progress vocabulary.
///
/// A record that is not there is a **retryable** failure, never an empty
/// summary: the response was lost with a crashed process, an evicted
/// record, or a reaped effect, and asking the provider again is the only
/// honest recovery. `SummaryProduced(summary: "")` would publish a
/// `CompactionEntry` whose summary is nothing at all, silently replacing
/// a conversation with a blank.
///
/// `SummaryNeedsRequest` is never returned. This wiring builds no split
/// preparations (`runtime/hooks` cuts only at turn boundaries), so one
/// request per attempt is the whole loop.
///
/// ## Examples
///
/// ```gleam
/// // wiring.summary_progress(config, operation, "task-1", 1)
/// ```
///
pub fn summary_progress(
  config: Config,
  operation: ids.OpId,
  task_id: String,
  attempt: Int,
) -> SummaryProgress {
  case
    summaries.read(
      config.summaries,
      key: summaries.key(operation, task_id, attempt),
    )
  {
    summaries.Recorded(settlement: summaries.Produced(summary:, usage:)) ->
      SummaryProduced(summary:, usage:)
    summaries.Recorded(settlement: summaries.Failed(message:, retryable:)) ->
      SummaryFailed(
        error: OperationError(code: "summary_failed", message:, details: None),
        retryable:,
      )
    summaries.Absent ->
      SummaryFailed(
        error: OperationError(
          code: "summary_lost",
          message: "the summary response was not recorded; the attempt is "
            <> "being retried",
          details: None,
        ),
        retryable: True,
      )
  }
}

/// Whether the captured identity still routes, asked before a deferred
/// poll or a summary request. The gateway is the authority: an identity
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
  case gateway.resolve(config.gateway, config.summary_role) {
    Ok(_resolved) -> ModelResolved
    Error(_missing) ->
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
  ModelFacts(api: String, context_window: Int, max_output_tokens: Int)
}

fn model_facts(config: Config, identity: ModelIdentity) -> ModelFacts {
  case config.facts(identity) {
    Ok(#(resolved, api)) ->
      ModelFacts(
        api:,
        context_window: resolved.context_window,
        max_output_tokens: resolved.max_output_tokens,
      )
    Error(Nil) -> fallback_facts(config)
  }
}

// The figures for an identity nobody stands behind: the config's own
// declared fallbacks, stated once so the two readers cannot drift.
fn fallback_facts(config: Config) -> ModelFacts {
  ModelFacts(
    api: config.api,
    context_window: config.fallback_context_window,
    max_output_tokens: config.fallback_max_output_tokens,
  )
}

// One strand's facts, read from its durable configuration. A strand whose
// configuration is unreadable is accounted against the fallback figures:
// a token count that cannot be taken must not halt a strand
// (`runtime/hooks`' own rule for a failed projection).
fn strand_facts(config: Config, strand: String) -> ModelFacts {
  case session.strand_configuration(config.session, strand) {
    Ok(Some(session.Cell(value: configuration, ..))) ->
      model_facts(config, configuration.model)
    _ ->
      ModelFacts(
        api: config.api,
        context_window: config.fallback_context_window,
        max_output_tokens: config.fallback_max_output_tokens,
      )
  }
}

// The pre-request admission, answered from the query's own configuration
// rather than from a closure frozen at boot. Three durable values ride on
// it — the intended output limit and context window overflow
// classification is stable against, and the `request_api` a deferred
// handle is validated against (ORCH-L4) — and all three are properties of
// the identity *this attempt* will reach, which a boot-time answer cannot
// know for a strand that switched models since.
fn admit(config: Config, query: effects.AdmissionQuery) -> RequestAdmission {
  let facts = model_facts(config, query.configuration.model)
  Admitted(
    stream_options: query.stream_options,
    intended_output_limit: facts.max_output_tokens,
    context_window: facts.context_window,
    api: facts.api,
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
/// A structural summary is a different request entirely — no system
/// prompt, no tools, one assembled user message — and it is built by
/// `summary_provider_request`, which this function delegates the shape
/// to so there is exactly one summary request in the module.
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
  case spec {
    effects.SummaryRequest(configuration:, ..) ->
      // An unbuildable summary spec (no preparation register) never
      // reaches a provider: `dispatch` checks first and fails the
      // request in band. The fallback keeps this function total and
      // deliberately carries nothing — sending a strand's context under
      // a summarization intent would be worse than sending nothing.
      // Lazily: `request_target` resolves the model catalogue, and an
      // eager fallback would run that resolution on every summary
      // request only to discard it on the path that always succeeds.
      result.lazy_unwrap(summary_provider_request(config, spec), fn() {
        ProviderRequest(
          target: request_target(config, configuration),
          system: None,
          messages: [],
          tools: [],
          max_output_tokens: None,
        )
      })
    effects.GenerationRequest(configuration:, context:, ..) ->
      generation_request(
        config,
        configuration,
        context,
        request_target(config, configuration),
      )

    // A poll never walks a chain: the handle it would fetch belongs to
    // the identity that minted it. See `resolved_target`.
    effects.PollRequest(configuration:, ..) ->
      generation_request(
        config,
        configuration,
        [],
        resolved_target(config, configuration),
      )
  }
}

fn generation_request(
  config: Config,
  configuration: StrandConfiguration,
  messages: List(AgentMessage),
  target: RequestTarget,
) -> ProviderRequest {
  ProviderRequest(
    target:,
    system: config.system,
    messages:,
    tools: tool_specs(config, configuration.active_tool_names),
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
  case routed_role(config, configuration.model) {
    Ok(role) ->
      ForRole(
        role:,
        thinking: Some(thinking_level(configuration.thinking_level)),
      )
    Error(Nil) -> resolved_target(config, configuration)
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
fn routed_role(config: Config, identity: ModelIdentity) -> Result(Role, Nil) {
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
