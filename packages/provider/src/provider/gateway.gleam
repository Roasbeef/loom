//// The provider gateway: a typed registry of provider configurations and
//// role routes, exposing the frozen contract (spec §1.5) —
//// `resolve(gw, role)` and `request(gw, req)`.
////
//// The gateway is pure data plus injected effects: a `Transport` (HTTP),
//// an optional isolated Codex transport, a `SecretStore` (API keys), and a
//// `Clock` (timestamps). Construction
//// is the builder pattern; `prepare` allocates only a parked owner, and
//// nothing resolves a route, reads a secret, or touches the network until its
//// begin permit is granted. `request` is the synchronous facade which grants
//// that permit after constructing the handle.
////
//// Dispatch semantics:
////
//// - `resolve` returns the first target of the role's fallback chain
////   whose provider is registered — the identity durable state stores.
//// - `request` with `ForRole` resolves the chain at dispatch and walks
////   it: an attempt that fails with a *retryable* error (per
////   `retry.classify`) moves to the next target; a terminal error, or an
////   exhausted chain, delivers the failure in-band as `Failed`. A
////   settled response never falls back. `ForRole.thinking` overlays one
////   reasoning budget onto every target of the walk, or `None` leaves
////   each entry's own static level in force (`protocol-change/009`).
//// - `request` with `ForResolved` dispatches to exactly that identity —
////   the recovery path, where the machine re-dispatches what it stored.
////
//// Secrets are read at dispatch, flow into the adapter's request
//// constructor, and exist nowhere else: not in the gateway value beyond
//// the store itself, not in any event, error, or returned structure
//// (spec §3.3 invariant 4).
////
//// ## Flow
////
//// `request` → `prepare` → `start_guard` → `step` → `begin_request` → `pump` → `attempt` → `attempt_one` → `forward_or_settle` → `settle`
////
//// 1. `request` is `prepare` followed by `stream.start_prepared`; the public
////    registry setters (`new`, `add_provider`, `route`) only build the value
////    these read.
//// 2. `prepare` starts the guard with `start_guard` and puts a custodian over
////    it, returning a parked handle that has resolved no route and read no
////    secret.
//// 3. The guard is a weft state machine over `Phase`: `handle` sends every
////    signal through `classify` into `step`, whose arms are the whole
////    transition set, and `entered` arms the deadline a phase owns.
//// 4. The begin permit reaches `begin_request`, which spawns the pump parked
////    (`parked_pump`); `release_pump` adopts it through `adopt_pump` and only
////    then lets it run.
//// 5. `pump` gathers the per-request constants into one `Walk` and hands it to
////    `dispatch_role` for a role, or straight to `attempt` for one resolved
////    identity; `usable_chain` and `overlaid` decide the targets walked.
//// 6. `attempt` walks the chain one target at a time. `attempt_one` limits
////    images, looks up the provider and secret, and runs the adapter through
////    `tracked`, which calls `stream.run_tracked`; `continue_or_deliver` falls
////    back to the next target only for a retryable failure.
//// 7. Back in the guard, `forward_or_settle` relays deltas and sends a
////    terminal to `settle`, which waits for the attempt's exit proof and
////    publishes through `publish_settled`; `reap` and `abandon` handle the
////    pump or consumer dying first.

import core/accounting.{type RequestAccounting}
import core/clock.{type Clock}
import core/message.{type Usage, AssistantMessage}
import core/usage_evidence
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/adapter/anthropic
import provider/adapter/gemini
import provider/adapter/openai
import provider/adapter/responses
import provider/custodian
import provider/http.{type RunningRequest, type Transport}
import provider/image_budget
import provider/internal/diagnostic
import provider/model.{
  type CyberAccessProgram, type MissingIdentity, type ProviderRequest,
  type ResolvedModel, type Role, type ThinkingLevel, ForResolved, ForRole,
  MissingIdentity, ResolvedModel,
}
import provider/pricing.{type Pricing}
import provider/retry.{Retryable, Terminal}
import provider/secret.{type SecretStore}
import provider/stream.{
  type AttemptOutcome, type Control, type StreamEvent, type StreamHandle,
  AttemptCancellationUnconfirmed, AttemptCancelled, AttemptDrainProofLost,
  AttemptTerminal, Cancel, ConsumerGone, Delta, Failed, NoIdentity, NoSecret,
  ProviderCancelled, Settled, UnknownProvider,
}
import weft/state_machine as sm

const request_start_timeout_ms = 5000

const request_cancel_grace_ms = 1500

/// The public cancel capability, as the guard hears it.
///
/// One variant, because the only deadline the guard ever armed by hand —
/// the cancellation grace — is now a state timeout on the `Cancelling`
/// state and arrives on weft's own timer subject instead. This is the
/// subject `custodian.start` is handed as the worker's cooperative stop.
type RequestControl {
  CancelRequest
}

/// The begin permit: the custodian which has already adopted this guard.
///
/// Adoption and the permit are separate messages from separate processes,
/// which is why the custodian travels with the permit rather than being
/// known at spawn time.
type RequestStart {
  BeginRequest(custodian.Custodian)
}

/// The two ways a parked pump leaves its begin gate.
type ParkedPumpEvent {
  StartPump
  StopBeforePump
}

/// One transport the pump has prepared but not yet begun, published to the
/// guard for adoption together with the permit subject the pump blocks on.
type AttemptRegistration {
  AttemptRegistration(
    running: RunningRequest,
    permit: process.Subject(AttemptPermit),
    billing: usage_evidence.Billing,
  )
}

/// The pump replaces its retained report after each completed attempt.
/// These updates share its registration channel, so custody and evidence arrive
/// in sender order without an additional acknowledgement protocol.
type PumpUpdate {
  TransportPrepared(registration: AttemptRegistration)

  ReportRetained(report: RequestAccounting)
}

/// The guard's answer to a registration: begin the transport, or do not.
type AttemptPermit {
  BeginAttempt
  RejectAttempt
}

/// What stays fixed while the pump walks one request's route chain.
///
/// Every function on the walk (`attempt`, `attempt_one`, the keyed and
/// subscription dispatches, the fallback decision) needs the same seven values
/// and none of them changes between targets: the gateway, the caller's
/// request, the clock reading, the three channels to the guard and the
/// consumer to watch. Only the ordinal, the remaining targets and the retained
/// report change per target, so those stay ordinary parameters. Built once by
/// `pump`, which keeps a new constant a one-field change here rather than a
/// signature change in each function.
type Walk {
  Walk(
    gateway: Gateway,
    request: ProviderRequest,
    now: Int,
    events: process.Subject(StreamEvent),
    attempts: process.Subject(PumpUpdate),
    control: process.Subject(Control),
    consumer: process.Pid,
  )
}

/// One configured provider endpoint. The variant selects the adapter
/// dialect; the fields are pure configuration — the API key itself lives
/// in the secret store under `api_key_secret` and is only read at
/// dispatch.
///
/// Constructor invariants: `name` is the registry key `ResolvedModel.
/// provider` refers to, unique among registered providers; `base_url`
/// has no trailing slash (Anthropic: the host root, e.g.
/// `"https://api.anthropic.com"`; OpenAI-compatible: the API root, e.g.
/// `"https://api.openai.com/v1"`; Gemini: the API version root, e.g.
/// `"https://generativelanguage.googleapis.com/v1beta"`); `api_key_secret`
/// is a secret *name*,
/// never a value.
pub type ProviderConfig {
  /// An Anthropic Messages API endpoint.
  AnthropicProvider(name: String, base_url: String, api_key_secret: String)

  /// An OpenAI-compatible chat-completions endpoint.
  OpenAiCompatibleProvider(
    name: String,
    base_url: String,
    api_key_secret: String,
  )

  /// A public API-key Responses endpoint, distinct from Chat Completions.
  OpenAiResponsesProvider(
    name: String,
    base_url: String,
    api_key_secret: String,
  )

  /// An experimental subscription profile owned by the trusted Codex bridge.
  /// The profile is a name, never a credential, path, or endpoint URL.
  CodexSubscriptionProvider(name: String, profile: String)

  /// A Gemini `generateContent` endpoint (the Gemini Developer API, or
  /// any host speaking that dialect).
  GeminiProvider(name: String, base_url: String, api_key_secret: String)
}

/// A parked request bridge which owns the Codex credential and fixed host.
///
/// Its prepared owner must satisfy `http.Transport`'s drain contract. The
/// gateway supplies only a profile and a relative, uncredentialed request;
/// this function adds authentication outside the gateway and returns a
/// monitorable owner before any outbound work begins.
pub type CodexTransport {
  CodexTransport(
    prepare_streaming: fn(
      String,
      http.HttpRequest,
      process.Subject(http.HttpEvent),
    ) -> Result(http.PreparedRequest, String),
  )
}

/// The gateway registry. Built with `new` and the pipeable setters;
/// consumed by `resolve` and `request`.
pub opaque type Gateway {
  /// Invariants: `providers` hold unique names (later registrations of a
  /// name shadow earlier ones via first-match lookup order); `routes`
  /// map each role to its ordered fallback chain, best target first;
  /// `prices` carries at most one rate card per provider name and a
  /// provider absent from it has unavailable pricing evidence. `image_limits`
  /// holds explicit endpoint/model limits; absent entries use eight images.
  /// `protected_images` belongs to a request-scoped copy, never shared state.
  /// `attempt_timeout_ms` is positive and bounds one attempt from transport
  /// start through settlement. Response activity does not renew the deadline.
  Gateway(
    providers: List(ProviderConfig),
    routes: List(#(Role, List(ResolvedModel))),
    prices: List(#(String, Pricing)),
    image_limits: List(#(#(String, String), Int)),
    /// Each provider name owns its optional Responses access selection.
    cyber_access: List(#(String, CyberAccessProgram)),
    protected_images: Int,
    transport: Transport,
    codex_transport: Option(CodexTransport),
    secrets: SecretStore,
    clock: Clock,
    attempt_timeout_ms: Int,
  )
}

/// The phase the guard is in — the machine's *state*, in weft's sense.
///
/// The public request owner is a guard rather than the process doing the
/// route walk. That extra process has one job: preserve the stream law if
/// the pump crashes after startup. It also makes cancellation bounded
/// without asking the caller to understand the pump's monitor or the active
/// fallback attempt.
///
/// Every deadline the guard owns belongs to one of these states and is
/// armed by `entered`, so it is cancelled by the move out of the state
/// that armed it. Nothing here re-establishes its own relevance, and a fire
/// that raced a transition is dropped by weft's timer book before it
/// reaches the handler — which is why the stale-deadline arms below can say
/// they are unreachable and mean it.
///
/// Nothing in a payload changes while the machine is in that state: a
/// transition to an equal value is not a state change, so a payload that
/// moved would restart or void the deadline the state exists to hold.
/// Everything that moves per event lives in `Guard`.
type Phase {
  /// Nothing has resolved a route, read a secret, or opened a socket. The
  /// guard is waiting for the begin permit which publishes its custodian.
  Parked

  /// The pump has been spawned parked and its ready handshake is
  /// outstanding. Entering this state arms the start deadline.
  Starting

  /// The route walk is running and the public response window is open.
  Requesting

  /// Cancellation has been selected and the pump asked to stop. Entering
  /// this state arms the fixed grace; the terminal is the guard's to author
  /// when the grace expires.
  Cancelling

  /// The pump authored `terminal`, but the active transport's owner has not
  /// yet retired. Its exit reason decides whether that terminal survives or
  /// becomes `DrainProofLost`.
  Settling(terminal: StreamEvent)

  /// The pump died without authoring a terminal. Entering this state arms
  /// the same fixed grace for the active transport to acknowledge its own
  /// cancellation; `cause` is what a clean acknowledgement means.
  Reaping(cause: ReapCause)

  /// The public terminal has been published and the pump's ownership
  /// frontier is still open.
  ClosingPump

  /// The direct consumer died. Nothing more will be published; the frontier
  /// stays open and every late transport is cancelled as well as refused.
  Abandoning

  /// Nothing remains but the active transport owner's `Down`.
  ClosingActive
}

/// What a clean transport acknowledgement means when the pump died without
/// authoring a terminal of its own.
type ReapCause {
  /// The pump stopped mid-walk. The consumer is owed an in-band transport
  /// failure, which is retryable at the layer above.
  PumpStoppedEarly

  /// The pump died after cancellation was selected. Only the guard may say
  /// cancellation won its race, and a dead pump proves nothing about it.
  PumpGoneAfterCancel
}

/// The pump as the guard knows it.
///
/// The guard keeps the monitor it created before the pump was released,
/// because a later failure must not collapse a normal exit, an abnormal
/// one, and a late `noproc` into one answer.
type Pump {
  /// No pump: the begin permit has not arrived.
  NoPump

  /// Spawned and parked behind its own begin gate. This process still owns
  /// its teardown, because nothing has been adopted yet.
  PumpParked(owner: process.Pid, monitor: process.Monitor)

  /// Released into the route walk, with the control subject its
  /// cancellation travels on.
  PumpRunning(monitor: process.Monitor, control: process.Subject(Control))

  /// Its `Down` has been seen.
  PumpGone
}

/// The transport attempt the pump most recently published.
///
/// The guard keeps the monitor created before it publishes an attempt
/// permit. Carrying the monitor with the capability prevents a later pump
/// failure from collapsing normal drain, abnormal exit, and a late `noproc`
/// into one Boolean.
type Attempt {
  /// No transport has been registered, or the last one was superseded.
  NoAttempt

  /// One transport whose owner the guard is still watching.
  LiveAttempt(running: RunningRequest, monitor: process.Monitor)

  /// The owner's `Down` has arrived. It is recorded rather than acted on,
  /// because the phase which was going to wait for it may not have been
  /// reached yet — an exit seen early must mean exactly what an exit seen
  /// late would have meant.
  ExitedAttempt(outcome: ActiveExit)
}

/// What an attempt owner's exit proved.
///
/// Only a normal exit acknowledges that the native work beneath the owner
/// stopped; any other reason means the proof was lost, whatever the pump
/// had computed.
type ActiveExit {
  ActiveDrained
  ActiveProofLost
}

/// Everything the guard carries *across* phases.
///
/// The split from `Phase` is weft's and it is load-bearing: data may change
/// on any event without disturbing a state timeout, while a change of state
/// cancels one. So the custodian, the pump, the active attempt and the
/// consumer monitor live here — putting the attempt in the state would make
/// an ordinary registration cancel the cancellation grace.
type Guard {
  Guard(
    gateway: Gateway,
    request: ProviderRequest,
    now: Int,
    events: process.Subject(StreamEvent),
    pump_ready: process.Subject(
      #(process.Subject(Control), process.Subject(Nil)),
    ),
    pump_events: process.Subject(StreamEvent),
    pump_attempts: process.Subject(PumpUpdate),
    /// `None` once the consumer's death has stopped mattering, so a later
    /// `Down` cannot be mistaken for one of the guard's live monitors.
    consumer_watch: Option(process.Monitor),
    /// `None` only while parked: the custodian arrives with the permit.
    custodian: Option(custodian.Custodian),
    pump: Pump,
    attempt: Attempt,
    /// Completed attempts retained before any fallback can begin.
    report: RequestAccounting,
    /// A permitted attempt whose observation has not reached this custodian.
    pending_usage: Option(Usage),
  )
}

/// What the guard's selector delivers.
///
/// The selector is fixed when the machine starts, before the consumer,
/// pump, or attempt monitors exist, so a `Down` cannot be given a meaning
/// at selection time. `Watched` carries it raw and `classify` asks which of
/// the guard's monitors fired; everything else already knows what it means.
type Signal {
  Told(event: Event)
  Watched(down: process.Down)
}

/// One thing that happened, in the guard's own vocabulary.
type Event {
  /// The begin permit, carrying the custodian which has adopted the guard.
  Begin(custodian: custodian.Custodian)

  /// The parked pump answered its ready handshake.
  PumpAdmitted(control: process.Subject(Control), begin: process.Subject(Nil))

  /// The start deadline on `Starting` expired.
  PumpStartExpired

  /// The pump published a stream event.
  FromPump(streamed: StreamEvent)

  /// The pump published a prepared transport and is blocked on its permit.
  Registered(registration: AttemptRegistration)

  /// The pump replaced its bounded report after one distinct attempt.
  AccountingUpdated(report: RequestAccounting)

  /// The direct consumer exited.
  ConsumerExited

  /// The pump exited.
  PumpExited

  /// The active attempt's transport owner exited.
  AttemptExited(exit: ActiveExit)

  /// A `Down` matching none of the guard's monitors. Unreachable in
  /// practice — `demonitor_process` flushes — and total by construction.
  StrayExited

  /// The public cancel capability was invoked.
  CancelAsked

  /// The cancellation grace on `Cancelling` expired.
  CancelExpired

  /// The reap grace on `Reaping` expired.
  ReapExpired
}

/// What every handler in this machine returns.
type Step =
  sm.Next(Phase, Guard, Signal)

/// A gateway with no providers or routes. Inject the real transport,
/// secret store, and clock in production; fixtures in tests.
///
/// ## Examples
///
/// ```gleam
/// // gateway.new(
/// //   transport: http.httpc_transport(),
/// //   secrets: secret.env(),
/// //   clock: clock.from_function(runtime_now),
/// // )
/// ```
///
pub fn new(
  transport transport: Transport,
  secrets secrets: SecretStore,
  clock clock: Clock,
) -> Gateway {
  Gateway(
    providers: [],
    routes: [],
    prices: [],
    image_limits: [],
    cyber_access: [],
    protected_images: 0,
    transport:,
    codex_transport: None,
    secrets:,
    clock:,
    attempt_timeout_ms: 300_000,
  )
}

/// Attaches the isolated subscription transport to this gateway.
/// Without it, subscription dispatch fails locally and opens no socket.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_codex_transport(gw, bridge)
/// ```
pub fn with_codex_transport(
  gateway: Gateway,
  transport: CodexTransport,
) -> Gateway {
  Gateway(..gateway, codex_transport: Some(transport))
}

/// Registers a provider endpoint.
///
/// ## Examples
///
/// ```gleam
/// // gateway.new(transport:, secrets:, clock:)
/// // |> gateway.add_provider(gateway.AnthropicProvider(
/// //   name: "anthropic",
/// //   base_url: "https://api.anthropic.com",
/// //   api_key_secret: "ANTHROPIC_API_KEY",
/// // ))
/// ```
///
pub fn add_provider(gateway: Gateway, config: ProviderConfig) -> Gateway {
  let providers = list.append(gateway.providers, [config])
  Gateway(..gateway, providers:)
}

/// Sets the image count limit for one endpoint and model identity.
///
/// Non-positive values fail locally at dispatch. Catalogue callers validate
/// them at load time, so malformed configuration never reaches a transport.
///
/// ## Examples
///
/// ```gleam
/// // gateway |> gateway.with_image_limit("eyes", "vision-model", 8)
/// ```
pub fn with_image_limit(
  gateway: Gateway,
  provider: String,
  model_id: String,
  limit: Int,
) -> Gateway {
  let key = #(provider, model_id)
  Gateway(..gateway, image_limits: [
    #(key, limit),
    ..list.filter(gateway.image_limits, fn(entry) { entry.0 != key })
  ])
}

/// Selects the Responses access program for one configured provider.
///
/// The attempt reads its own provider's selection, so a fallback cannot borrow
/// another entry's program. Other dialects do not send this setting.
///
/// ## Examples
///
/// ```gleam
/// // gateway |> gateway.with_cyber_access("sol-blue", model.DaybreakBlue)
/// ```
pub fn with_cyber_access(
  gateway: Gateway,
  provider: String,
  program: CyberAccessProgram,
) -> Gateway {
  Gateway(..gateway, cyber_access: [
    #(provider, program),
    ..list.filter(gateway.cyber_access, fn(entry) { entry.0 != provider })
  ])
}

/// Makes a request-scoped registry copy that protects the active run's images.
///
/// Use this for held prompt batches whose first image precedes the newest
/// attributed prompt. Each fallback still applies its own endpoint limit.
/// The shared registry and durable request remain unchanged.
///
/// ## Examples
///
/// ```gleam
/// // gateway.prepare(gateway.with_protected_images(gw, 4), request)
/// ```
pub fn with_protected_images(gateway: Gateway, count: Int) -> Gateway {
  Gateway(..gateway, protected_images: count)
}

/// Sets a role's ordered fallback chain, best target first, replacing
/// any previous chain for the role.
///
/// ## Examples
///
/// ```gleam
/// // gateway |> gateway.route(model.Main, [primary, fallback])
/// ```
///
pub fn route(
  gateway: Gateway,
  role: Role,
  chain: List(ResolvedModel),
) -> Gateway {
  let routes = [
    #(role, chain),
    ..list.filter(gateway.routes, fn(entry) { entry.0 != role })
  ]
  Gateway(..gateway, routes:)
}

/// Attaches a rate card to a registered provider, replacing any card it
/// already had.
///
/// Pricing hangs off the provider name rather than off `ProviderConfig`
/// because it is not a wire fact: the adapter's request is byte-identical
/// whether or not the operator wrote down what the endpoint charges. A
/// provider with no card retains unavailable pricing evidence; its numeric
/// zero cannot establish that the request was free.
///
/// ## Examples
///
/// ```gleam
/// // gateway |> gateway.price("kimi-k3", pricing.Pricing(3.0, 15.0, 0.3, 3.0))
/// ```
///
pub fn price(gateway: Gateway, provider: String, card: Pricing) -> Gateway {
  let prices = [
    #(provider, card),
    ..list.filter(gateway.prices, fn(entry) { entry.0 != provider })
  ]
  Gateway(..gateway, prices:)
}

/// The rate card registered for a provider, or `Error(Nil)` when it is
/// unpriced.
///
/// The gateway is opaque, so this is how a caller assembling one from a
/// catalogue can check that the cards it wrote down are the cards that
/// arrived. Dispatch does not go through it.
///
/// ## Examples
///
/// ```gleam
/// // gateway.card_for(gw, "anthropic") -> Error(Nil)
/// ```
///
pub fn card_for(gateway: Gateway, provider: String) -> Result(Pricing, Nil) {
  list.key_find(gateway.prices, provider)
}

/// Overrides the absolute per-attempt deadline in milliseconds. Response
/// chunks do not renew this deadline.
///
/// ## Examples
///
/// ```gleam
/// // gateway |> gateway.with_attempt_timeout(60_000)
/// ```
///
pub fn with_attempt_timeout(gateway: Gateway, timeout_ms: Int) -> Gateway {
  Gateway(..gateway, attempt_timeout_ms: timeout_ms)
}

/// Resolves a role to the identity durable state should store: the first
/// target in the role's chain whose provider is registered. Frozen
/// contract (spec §1.5).
///
/// ## Examples
///
/// ```gleam
/// // gateway.resolve(gw, model.Main)
/// // -> Ok(model.ResolvedModel(provider: "anthropic", ..))
/// ```
///
/// ```gleam
/// // gateway.resolve(gw, model.Vision)
/// // -> Error(model.MissingIdentity(role: model.Vision))
/// ```
///
pub fn resolve(
  gateway: Gateway,
  role: Role,
) -> Result(ResolvedModel, MissingIdentity) {
  case usable_chain(gateway, role) {
    [first, ..] -> Ok(first)
    [] -> Error(MissingIdentity(role:))
  }
}

// The role's chain restricted to targets whose provider is registered.
fn usable_chain(gateway: Gateway, role: Role) -> List(ResolvedModel) {
  case list.key_find(gateway.routes, role) {
    Ok(chain) ->
      list.filter(chain, fn(target) {
        case find_provider(gateway, target.provider) {
          Ok(_config) -> True
          Error(Nil) -> False
        }
      })
    Error(Nil) -> []
  }
}

fn find_provider(
  gateway: Gateway,
  name: String,
) -> Result(ProviderConfig, Nil) {
  list.find(gateway.providers, fn(config) { config.name == name })
}

/// Dispatches one assistant-generation request, returning the stream
/// handle its events arrive on. Frozen contract (spec §1.5); see the
/// module documentation for the fallback-walk semantics and
/// `provider/stream` for the handle's consumption contract.
///
/// The handle's subject is owned by the calling process. A minimal public
/// custodian owns its lifecycle while a guard and private pump run the
/// fallback walk. Both workers are adopted before they begin, so this returns
/// without making either worker's crash a false drain signal. Call `prepare`
/// when another owner must adopt this request before route or network work can
/// begin.
///
/// ## Examples
///
/// ```gleam
/// // let handle = gateway.request(gw, model.ProviderRequest(
/// //   target: model.ForRole(model.Main, thinking: option.None),
/// //   system: option.Some("You are ..."),
/// //   messages: projected,
/// //   tools: tools,
/// //   max_output_tokens: option.None,
/// // ))
/// // stream.await_terminal(handle, within: 300_000)
/// ```
///
pub fn request(gateway: Gateway, request: ProviderRequest) -> StreamHandle {
  prepare(gateway, request)
  |> stream.start_prepared
}

/// Prepares a routed provider request without starting role resolution,
/// secret lookup, or transport work.
///
/// The returned owner is the publication point for wrappers. They must adopt
/// it before invoking `begin`; cancellation before that permit retires the
/// parked request without reading a secret or opening a socket.
///
/// ## Examples
///
/// ```gleam
/// let prepared = gateway.prepare(gw, request)
/// // Publish `prepared.handle.owner` to the parent custodian first.
/// let handle = stream.start_prepared(prepared)
/// ```
///
pub fn prepare(
  gateway: Gateway,
  request: ProviderRequest,
) -> stream.PreparedStream {
  let consumer = process.self()
  let events = process.new_subject()
  let #(now, _clock) = clock.read(gateway.clock)

  // The guard is started unlinked: a crashing guard must be observed
  // through the custodian's worker adoption, never as an exit signal
  // arriving in the consumer. The start itself is bounded by the machine's
  // initialisation timeout, so a guard that never comes up is a reported
  // failure rather than a wait.
  let started = start_guard(gateway, request, now, events, consumer)

  case started {
    Ok(#(owner, control, begin)) -> {
      let custodian = custodian.start(owner, control, CancelRequest, consumer)
      stream.PreparedStream(
        handle: stream.owned(
          events:,
          owner: custodian.owner(custodian),
          cancel: fn() { custodian.cancel(custodian) },
        ),
        begin: fn() { process.send(begin, BeginRequest(custodian)) },
      )
    }

    // No guard came up, so nothing was adopted and nothing has to be torn
    // down: a guard which started but could not be published is parked on
    // its own consumer monitor and retires when the consumer does.
    Error(Nil) -> {
      process.send(
        events,
        Failed(
          stream.TransportFailed(reason: "provider request owner did not start"),
          accounting.empty(),
        ),
      )
      stream.PreparedStream(
        handle: stream.immediate(events:, cancel: fn() { Nil }),
        begin: fn() { Nil },
      )
    }
  }
}

// --- the request guard -----------------------------------------------------

// Starts the guard machine, unlinked from the consumer that asked for it,
// and returns its identity: the pid the custodian adopts and the two
// subjects the request is driven through.
fn start_guard(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  events: process.Subject(StreamEvent),
  consumer: process.Pid,
) -> Result(
  #(process.Pid, process.Subject(RequestControl), process.Subject(RequestStart)),
  Nil,
) {
  let started =
    sm.new_with_initialiser(request_start_timeout_ms, fn(_default) {
      let control = process.new_subject()
      let begin = process.new_subject()
      let pump_ready = process.new_subject()
      let pump_events = process.new_subject()
      let pump_attempts = process.new_subject()

      // The consumer is watched from here rather than from the begin
      // permit, which is what closes `prepare`'s return gap: the public
      // custodian starts watching the consumer only once `prepare` has
      // published it, and a consumer that dies inside that gap must still
      // retire the parked request.
      let consumer_watch = process.monitor(consumer)
      let guard =
        Guard(
          gateway:,
          request:,
          now:,
          events:,
          pump_ready:,
          pump_events:,
          pump_attempts:,
          consumer_watch: Some(consumer_watch),
          custodian: None,
          pump: NoPump,
          attempt: NoAttempt,
          report: accounting.empty(),
          pending_usage: None,
        )
      sm.initialised(Parked, guard)
      |> sm.selecting(guard_selector(
        control,
        begin,
        pump_ready,
        pump_events,
        pump_attempts,
      ))
      |> sm.returning(#(control, begin))
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.on_enter(entered)
    |> sm.unlinked
    |> sm.start

  case started {
    Ok(machine) -> {
      let #(control, begin) = machine.data
      Ok(#(machine.pid, control, begin))
    }

    // Nothing was published, so `prepare` reports the same failure it would
    // have reported for a guard that never spawned at all.
    Error(_error) -> Error(Nil)
  }
}

// The guard's whole mailbox in one selector.
//
// It replaces weft's default, which selects only the machine's own subject;
// the guard never sends to itself, so nothing is lost by leaving it out.
// Monitors go on as a single arm because the three the guard installs do
// not exist yet when this is built.
fn guard_selector(
  control: process.Subject(RequestControl),
  begin: process.Subject(RequestStart),
  pump_ready: process.Subject(#(process.Subject(Control), process.Subject(Nil))),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(PumpUpdate),
) -> process.Selector(Signal) {
  process.new_selector()
  |> process.select_map(begin, fn(message) {
    let BeginRequest(custodian) = message
    Told(Begin(custodian:))
  })
  |> process.select_map(control, fn(message) {
    case message {
      CancelRequest -> Told(CancelAsked)
    }
  })
  |> process.select_map(pump_ready, fn(admitted) {
    let #(control, begin) = admitted
    Told(PumpAdmitted(control:, begin:))
  })
  |> process.select_map(pump_events, fn(streamed) { Told(FromPump(streamed:)) })
  |> process.select_map(pump_attempts, fn(update) {
    case update {
      TransportPrepared(registration) -> Told(Registered(registration:))
      ReportRetained(report) -> Told(AccountingUpdated(report:))
    }
  })
  |> process.select_monitors(Watched)
}

// One event, in one phase.
fn handle(phase: Phase, guard: Guard, signal: Signal) -> Step {
  case signal {
    Told(event:) -> step(phase, guard, event)
    Watched(down:) -> step(phase, guard, classify(guard, down))
  }
}

// Which of the guard's monitors fired.
//
// The selector cannot answer this, so it is asked here, against the
// monitors the guard is holding at the moment the `Down` is handled. A
// superseded attempt was demonitored with a flush, so its exit never
// arrives and never has to be told apart from the live one's.
fn classify(guard: Guard, down: process.Down) -> Event {
  case guard.consumer_watch == Some(down.monitor) {
    True -> ConsumerExited
    False -> classify_worker(guard, down)
  }
}

fn classify_worker(guard: Guard, down: process.Down) -> Event {
  case pump_watch(guard.pump) == Some(down.monitor) {
    True -> PumpExited
    False -> classify_attempt(guard, down)
  }
}

fn classify_attempt(guard: Guard, down: process.Down) -> Event {
  case attempt_watch(guard.attempt) == Some(down.monitor) {
    True -> AttemptExited(exit: active_exit(down))
    False -> StrayExited
  }
}

fn pump_watch(pump: Pump) -> Option(process.Monitor) {
  case pump {
    PumpParked(monitor:, ..) | PumpRunning(monitor:, ..) -> Some(monitor)
    NoPump | PumpGone -> None
  }
}

fn attempt_watch(attempt: Attempt) -> Option(process.Monitor) {
  case attempt {
    LiveAttempt(monitor:, ..) -> Some(monitor)
    NoAttempt | ExitedAttempt(..) -> None
  }
}

// Only a normal exit acknowledges that native work stopped. Death alone is
// not enough: the owner may have abandoned a process or a socket beneath it.
fn active_exit(down: process.Down) -> ActiveExit {
  case down {
    process.ProcessDown(reason:, ..) ->
      case reason {
        process.Normal -> ActiveDrained
        process.Killed | process.Abnormal(_) -> ActiveProofLost
      }
    process.PortDown(..) -> ActiveProofLost
  }
}

// The deadline each state owns, armed by every path into it.
//
// Arming here rather than at the transition site is what makes each
// deadline die with its state: `Cancelling`'s grace does not refresh when a
// second cancel arrives, because `keep` is not a state change, and it is
// gone the moment a terminal moves the machine on.
fn entered(
  _from: Phase,
  to: Phase,
  guard: Guard,
) -> sm.Enter(Phase, Guard, Signal) {
  case to {
    Starting ->
      sm.keep(guard)
      |> sm.with_state_timeout(
        after: request_start_timeout_ms,
        sending: Told(PumpStartExpired),
      )

    Cancelling ->
      sm.keep(guard)
      |> sm.with_state_timeout(
        after: request_cancel_grace_ms,
        sending: Told(CancelExpired),
      )

    Reaping(..) ->
      sm.keep(guard)
      |> sm.with_state_timeout(
        after: request_cancel_grace_ms,
        sending: Told(ReapExpired),
      )

    Parked
    | Requesting
    | Settling(..)
    | ClosingPump
    | Abandoning
    | ClosingActive -> sm.keep(guard)
  }
}

// The exhaustive matrix: every phase against every event.
//
// Adding a phase or an event makes the compiler name each combination
// nobody has thought about, which is where the hand-rolled guard used to
// carry a stale-deadline arm and a re-read of its own phase.
fn step(phase: Phase, guard: Guard, event: Event) -> Step {
  case phase, event {
    // Replacing a report never renews a phase deadline. A later registration
    // reopens the frontier only after this sender-ordered update was retained.
    Parked, AccountingUpdated(report)
    | Starting, AccountingUpdated(report)
    | Requesting, AccountingUpdated(report)
    | Cancelling, AccountingUpdated(report)
    | Settling(_), AccountingUpdated(report)
    | Reaping(_), AccountingUpdated(report)
    | ClosingPump, AccountingUpdated(report)
    | Abandoning, AccountingUpdated(report)
    | ClosingActive, AccountingUpdated(report)
    -> sm.keep(Guard(..guard, report:, pending_usage: None))

    // The permit publishes the custodian, so the pump can be spawned,
    // adopted, and only then released.
    Parked, Begin(custodian:) -> begin_request(guard, custodian)

    // Cancellation before the permit retires the parked request without
    // reading a secret or opening a socket, and a consumer nobody can
    // deliver to is the same fact arriving from the other side.
    Parked, CancelAsked | Parked, ConsumerExited -> sm.stop()

    Starting, PumpAdmitted(control:, begin:) ->
      release_pump(guard, control, begin)

    // The pump never crossed its ready gate, so nothing was adopted and
    // this process still owns its teardown.
    Starting, PumpStartExpired | Starting, PumpExited -> {
      kill_parked_pump(guard.pump)
      sm.stop()
    }

    // Neither can be acted on until the pump has been adopted and released:
    // cancelling a pump the custodian does not yet know about would leave
    // it parked behind a dead guard. weft replays them in arrival order the
    // instant `Requesting` is entered, which is where the hand-rolled guard
    // used to find them still waiting in its mailbox.
    Starting, CancelAsked | Starting, ConsumerExited ->
      sm.keep(guard) |> sm.postpone

    Requesting, Registered(registration:) -> admit_attempt(guard, registration)

    Requesting, FromPump(streamed:) -> forward_or_settle(guard, streamed)

    // Cancellation is an owner-authored terminal. The pump is asked to stop
    // and the grace begins; nothing is published until it answers or the
    // deadline says it cannot be confirmed.
    Requesting, CancelAsked -> {
      cancel_pump(guard)
      sm.transition(to: Cancelling, data: guard)
    }

    Requesting, ConsumerExited -> abandon(guard)

    Requesting, PumpExited -> reap(guard, PumpStoppedEarly)

    // A late registration during cancellation is adopted, so the custodian
    // still accounts for it, and refused, so the transport never starts.
    Cancelling, Registered(registration:) ->
      sm.keep(refuse_attempt(guard, registration))

    Cancelling, FromPump(streamed:) -> forward_cancelled(guard, streamed)

    // The grace belongs to the state, so a second cancel does not refresh
    // it: `keep` is not a state change, and the deadline the first one
    // armed keeps running.
    Cancelling, CancelAsked -> sm.keep(guard)

    Cancelling, CancelExpired -> expire_cancellation(guard)

    Cancelling, ConsumerExited -> abandon(guard)

    Cancelling, PumpExited -> reap(guard, PumpGoneAfterCancel)

    Settling(terminal:), AttemptExited(exit:) ->
      publish_settled(record_exit(guard, exit), terminal, exit)

    Reaping(cause:), AttemptExited(exit:) ->
      publish_reaped(record_exit(guard, exit), cause, exit)

    // The transport owner did not answer within the grace. It is not killed
    // from above — that would erase the only acknowledgement that its
    // native descendant stopped — so the public terminal says exactly that
    // and the guard stays alive behind it until the owner retires.
    Reaping(cause), ReapExpired -> {
      let initiator = case cause {
        PumpStoppedEarly -> stream.TransportExit
        PumpGoneAfterCancel -> stream.CancellationRequested
      }
      emit(
        guard,
        gateway_failure(
          stream.CancellationUnconfirmed,
          initiator,
          retained_accounting(guard),
        ),
      )
      close_attempt(guard)
    }

    ClosingPump, Registered(registration:) ->
      sm.keep(refuse_attempt(guard, registration))

    ClosingPump, PumpExited -> close_attempt(pump_gone(guard))

    // A dead consumer is owed no terminal, but a transport it left behind
    // is still cancelled rather than merely refused.
    Abandoning, Registered(registration:) -> {
      let guard = refuse_attempt(guard, registration)
      cancel_attempt(guard.attempt)
      sm.keep(guard)
    }

    Abandoning, PumpExited -> close_attempt(pump_gone(guard))

    ClosingActive, AttemptExited(..) -> sm.stop()

    // An attempt owner's exit is recorded wherever it lands. The phase that
    // was going to wait for it may not have been reached yet, and an exit
    // seen early must mean what an exit seen late would have meant.
    Parked, AttemptExited(exit:)
    | Starting, AttemptExited(exit:)
    | Requesting, AttemptExited(exit:)
    | Cancelling, AttemptExited(exit:)
    | ClosingPump, AttemptExited(exit:)
    | Abandoning, AttemptExited(exit:)
    -> sm.keep(record_exit(guard, exit))

    // The pump's own exit after the public terminal is bookkeeping: it is
    // what lets `ClosingPump` know the frontier is already closed.
    Settling(..), PumpExited | ClosingActive, PumpExited ->
      sm.keep(pump_gone(guard))

    // The begin permit is granted once. A second one names a custodian the
    // guard already has.
    Starting, Begin(..)
    | Requesting, Begin(..)
    | Cancelling, Begin(..)
    | Settling(..), Begin(..)
    | Reaping(..), Begin(..)
    | ClosingPump, Begin(..)
    | Abandoning, Begin(..)
    | ClosingActive, Begin(..)
    -> sm.keep(guard)

    // The ready handshake and its deadline belong to `Starting` alone; the
    // deadline is a state timeout, so a fire that raced the move out of
    // `Starting` is dropped by weft's timer book before it arrives here.
    Parked, PumpAdmitted(..)
    | Requesting, PumpAdmitted(..)
    | Cancelling, PumpAdmitted(..)
    | Settling(..), PumpAdmitted(..)
    | Reaping(..), PumpAdmitted(..)
    | ClosingPump, PumpAdmitted(..)
    | Abandoning, PumpAdmitted(..)
    | ClosingActive, PumpAdmitted(..)
    | Parked, PumpStartExpired
    | Requesting, PumpStartExpired
    | Cancelling, PumpStartExpired
    | Settling(..), PumpStartExpired
    | Reaping(..), PumpStartExpired
    | ClosingPump, PumpStartExpired
    | Abandoning, PumpStartExpired
    | ClosingActive, PumpStartExpired
    -> sm.keep(guard)

    // Outside the response window nothing the pump streams can be
    // published: before the permit it has not begun, and after the terminal
    // the stream law forbids a second one.
    Parked, FromPump(..)
    | Starting, FromPump(..)
    | Settling(..), FromPump(..)
    | Reaping(..), FromPump(..)
    | ClosingPump, FromPump(..)
    | Abandoning, FromPump(..)
    | ClosingActive, FromPump(..)
    -> sm.keep(guard)

    // A registration in one of these phases has no permit to be given: the
    // pump has not begun, or it has already authored its terminal, or it is
    // gone and nothing is blocked behind an answer.
    Parked, Registered(..)
    | Starting, Registered(..)
    | Settling(..), Registered(..)
    | Reaping(..), Registered(..)
    | ClosingActive, Registered(..)
    -> sm.keep(guard)

    // The consumer's death stops mattering once a terminal has been
    // decided; in `Reaping` the monitor has been released outright.
    Settling(..), ConsumerExited
    | Reaping(..), ConsumerExited
    | ClosingPump, ConsumerExited
    | Abandoning, ConsumerExited
    | ClosingActive, ConsumerExited
    -> sm.keep(guard)

    // No pump has been spawned, or its exit is what put the machine in this
    // phase to begin with.
    Parked, PumpExited | Reaping(..), PumpExited -> sm.keep(guard)

    // Cancellation after a terminal has been decided is a no-op: the first
    // terminal-class event already won the race.
    Settling(..), CancelAsked
    | Reaping(..), CancelAsked
    | ClosingPump, CancelAsked
    | Abandoning, CancelAsked
    | ClosingActive, CancelAsked
    -> sm.keep(guard)

    // Both graces are state timeouts, so a fire that raced the move out of
    // the state that armed it is stale and weft's timer book has already
    // dropped it. These arms exist because the matrix is exhaustive, not
    // because the case can arise.
    Parked, CancelExpired
    | Starting, CancelExpired
    | Requesting, CancelExpired
    | Settling(..), CancelExpired
    | Reaping(..), CancelExpired
    | ClosingPump, CancelExpired
    | Abandoning, CancelExpired
    | ClosingActive, CancelExpired
    | Parked, ReapExpired
    | Starting, ReapExpired
    | Requesting, ReapExpired
    | Cancelling, ReapExpired
    | Settling(..), ReapExpired
    | ClosingPump, ReapExpired
    | Abandoning, ReapExpired
    | ClosingActive, ReapExpired
    -> sm.keep(guard)

    // A `Down` from none of the guard's three monitors. Demonitoring
    // flushes, so a superseded attempt's exit never arrives at all.
    Parked, StrayExited
    | Starting, StrayExited
    | Requesting, StrayExited
    | Cancelling, StrayExited
    | Settling(..), StrayExited
    | Reaping(..), StrayExited
    | ClosingPump, StrayExited
    | Abandoning, StrayExited
    | ClosingActive, StrayExited
    -> sm.keep(guard)
  }
}

// --- phase transitions -----------------------------------------------------

// Spawns the route-walk pump, parked behind its own begin gate.
//
// The pump is not the guard: a crash in the route walk must not erase the
// guard's ability to author a terminal, which is the whole reason there are
// two processes here.
fn begin_request(guard: Guard, custodian: custodian.Custodian) -> Step {
  let self = process.self()
  let owner =
    process.spawn_unlinked(fn() {
      parked_pump(
        guard.gateway,
        guard.request,
        guard.now,
        guard.pump_ready,
        guard.pump_events,
        guard.pump_attempts,
        self,
      )
    })
  let monitor = process.monitor(owner)
  sm.transition(
    to: Starting,
    data: Guard(
      ..guard,
      custodian: Some(custodian),
      pump: PumpParked(owner:, monitor:),
    ),
  )
}

// The pump before its first effect: it publishes its own control and begin
// subjects and then waits to be told which of the two happened.
fn parked_pump(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  ready: process.Subject(#(process.Subject(Control), process.Subject(Nil))),
  events: process.Subject(StreamEvent),
  attempts: process.Subject(PumpUpdate),
  guard: process.Pid,
) -> Nil {
  let pump_control = process.new_subject()
  let pump_begin = process.new_subject()
  let creator_monitor = process.monitor(guard)
  process.send(ready, #(pump_control, pump_begin))

  // Adoption and begin are separate messages from separate processes. If
  // the guard dies between them, its custodian cancels this parked pump.
  // Selecting both gates keeps that cancellation from becoming an
  // unconsumed mailbox message which would pin the whole drain chain.
  let parked =
    process.new_selector()
    |> process.select_map(pump_begin, fn(_nil) { StartPump })
    |> process.select_map(pump_control, fn(_control) { StopBeforePump })
    |> process.select_specific_monitor(creator_monitor, fn(_down) {
      StopBeforePump
    })
    |> process.selector_receive_forever()
  case parked {
    StopBeforePump -> process.demonitor_process(creator_monitor)
    StartPump -> {
      // Custody has crossed to the guard's custodian before this permit;
      // the creator monitor must not compete with that durable edge.
      process.demonitor_process(creator_monitor)
      pump(gateway, request, now, events, attempts, pump_control, guard)
    }
  }
}

// Adopts the parked pump and, only then, releases it.
fn release_pump(
  guard: Guard,
  control: process.Subject(Control),
  begin: process.Subject(Nil),
) -> Step {
  case guard.pump {
    PumpParked(owner:, monitor:) ->
      permit_pump(guard, owner, monitor, control, begin)

    // Unreachable: `Starting` is entered only with a parked pump, and the
    // ready handshake is answered exactly once.
    NoPump | PumpRunning(..) | PumpGone -> sm.keep(guard)
  }
}

fn permit_pump(
  guard: Guard,
  owner: process.Pid,
  monitor: process.Monitor,
  control: process.Subject(Control),
  begin: process.Subject(Nil),
) -> Step {
  case adopt_pump(guard, owner, control) {
    True -> {
      process.send(begin, Nil)
      sm.transition(
        to: Requesting,
        data: Guard(..guard, pump: PumpRunning(monitor:, control:)),
      )
    }

    // The pump has not crossed its begin gate. Rejection means this process
    // retains teardown responsibility if the custodian died, so kill the
    // parked pump instead of starting secret lookup.
    False -> {
      process.kill(owner)
      sm.stop()
    }
  }
}

fn adopt_pump(
  guard: Guard,
  owner: process.Pid,
  control: process.Subject(Control),
) -> Bool {
  case guard.custodian {
    Some(custodian) ->
      custodian.adopt_leaf(custodian, owner, fn() {
        process.send(control, Cancel)
      })

    // Unreachable: the custodian arrives with the permit that spawns the
    // pump. A guard with no custodian has nothing to transfer custody to,
    // which is the answer a dead witness gives.
    None -> False
  }
}

// A delta is display data on the open response window; a terminal closes it.
fn forward_or_settle(guard: Guard, streamed: StreamEvent) -> Step {
  case streamed {
    Delta(..) -> {
      emit(guard, streamed)
      sm.keep(guard)
    }
    Settled(..) | Failed(..) -> settle(guard, streamed)
  }
}

// Cancellation remains an owner-authored terminal. The guard forwards a
// real pump terminal if one arrives; pump death or expiry only proves that
// the request could not confirm which side of the race won.
fn forward_cancelled(guard: Guard, streamed: StreamEvent) -> Step {
  let streamed =
    stream.contextual_event(
      streamed,
      stream.FailureObservation(
        stream.GatewaySource,
        stream.CancellationRequested,
        None,
        None,
        Some(request_cancel_grace_ms),
        None,
      ),
    )
  case streamed {
    // The response window closed when cancellation was selected.
    Delta(..) -> sm.keep(guard)

    // CancellationUnconfirmed is deliberately bounded for the public
    // caller. The guard remains alive behind that terminal until the
    // retained witness eventually adjudicates the real owner exit.
    Settled(..) -> {
      emit(guard, streamed)
      close_pump(guard)
    }

    Failed(error, _) ->
      case stream.underlying_error(error) {
        stream.CancellationUnconfirmed -> {
          emit(guard, streamed)
          close_pump(guard)
        }
        _ -> settle(guard, streamed)
      }
  }
}

// The pump authored a terminal, but the guard may publish it only once the
// active transport's owner has retired: an abnormal exit under a terminal
// is a lost drain proof, not the terminal the pump computed.
fn settle(guard: Guard, terminal: StreamEvent) -> Step {
  case guard.attempt {
    LiveAttempt(..) -> sm.transition(to: Settling(terminal:), data: guard)
    NoAttempt -> publish_settled(guard, terminal, ActiveDrained)
    ExitedAttempt(outcome:) -> publish_settled(guard, terminal, outcome)
  }
}

fn publish_settled(
  guard: Guard,
  terminal: StreamEvent,
  exit: ActiveExit,
) -> Step {
  emit(guard, case exit {
    ActiveDrained -> terminal
    ActiveProofLost -> lost_terminal_proof(terminal)
  })
  close_pump(guard)
}

// Lost custody changes the error class, not the event which began cleanup.
fn lost_terminal_proof(terminal: StreamEvent) -> StreamEvent {
  let report = stream.terminal_accounting(terminal)
  case terminal {
    Failed(error, _) ->
      Failed(
        list.fold(
          list.reverse(stream.failure_context(error)),
          stream.DrainProofLost,
          stream.with_context,
        ),
        report,
      )
    Settled(..) | Delta(..) ->
      gateway_failure(stream.DrainProofLost, stream.TransportExit, report)
  }
}

// The pump died without authoring a terminal. The active transport is asked
// to stop and given the same fixed grace to acknowledge it.
fn reap(guard: Guard, cause: ReapCause) -> Step {
  let guard = pump_gone(forget_consumer(guard))
  cancel_attempt(guard.attempt)
  case guard.attempt {
    LiveAttempt(..) -> sm.transition(to: Reaping(cause:), data: guard)
    NoAttempt -> publish_reaped(guard, cause, ActiveDrained)
    ExitedAttempt(outcome:) -> publish_reaped(guard, cause, outcome)
  }
}

fn publish_reaped(guard: Guard, cause: ReapCause, exit: ActiveExit) -> Step {
  emit(guard, case exit {
    ActiveProofLost ->
      gateway_failure(
        stream.DrainProofLost,
        stream.TransportExit,
        retained_accounting(guard),
      )
    ActiveDrained ->
      case cause {
        PumpStoppedEarly ->
          gateway_failure(
            stream.TransportFailed(
              reason: "provider request pump stopped before a terminal response",
            ),
            stream.TransportExit,
            retained_accounting(guard),
          )
        PumpGoneAfterCancel ->
          gateway_failure(
            stream.CancellationUnconfirmed,
            stream.CancellationRequested,
            retained_accounting(guard),
          )
      }
  })
  sm.stop()
}

// The public grace is over. Cancellation is re-sent to both the pump and
// the active transport, and the guard authors the one terminal it is
// entitled to: only an owner may claim that cancellation won its race, so
// an owner that has not answered leaves the result unconfirmed.
fn expire_cancellation(guard: Guard) -> Step {
  cancel_pump(guard)
  cancel_attempt(guard.attempt)
  emit(guard, case guard.attempt {
    ExitedAttempt(outcome: ActiveProofLost) ->
      gateway_failure(
        stream.DrainProofLost,
        stream.TransportExit,
        retained_accounting(guard),
      )
    ExitedAttempt(outcome: ActiveDrained) | NoAttempt | LiveAttempt(..) ->
      gateway_failure(
        stream.CancellationUnconfirmed,
        stream.CancellationRequested,
        retained_accounting(guard),
      )
  })
  close_pump(guard)
}

// A dead public consumer needs no terminal, but the pump still gets one
// grace interval to run its ordinary cancellation path. Killing it
// immediately would bypass an injected transport's cancel capability and
// would make the test seam weaker than the production custodian.
fn abandon(guard: Guard) -> Step {
  cancel_pump(guard)
  cancel_attempt(guard.attempt)
  case guard.pump {
    PumpParked(..) | PumpRunning(..) ->
      sm.transition(to: Abandoning, data: guard)
    NoPump | PumpGone -> close_attempt(guard)
  }
}

// Expiry closes the public response window, not the pump's ownership
// frontier. A transport preparation already in progress can still publish
// after that terminal, so registrations are adopted and refused until the
// pump exits: each parked owner then receives a permit decision, and the
// pump cannot remain blocked behind a guard that has stopped answering.
fn close_pump(guard: Guard) -> Step {
  case guard.pump {
    PumpParked(..) | PumpRunning(..) ->
      sm.transition(to: ClosingPump, data: guard)
    NoPump | PumpGone -> close_attempt(guard)
  }
}

// Nothing is left but the last transport owner's acknowledgement.
fn close_attempt(guard: Guard) -> Step {
  case guard.attempt {
    LiveAttempt(..) -> sm.transition(to: ClosingActive, data: guard)
    NoAttempt | ExitedAttempt(..) -> sm.stop()
  }
}

// --- bookkeeping -----------------------------------------------------------

// Adopts a freshly registered transport and permits it, unless the
// custodian has already begun teardown.
fn admit_attempt(guard: Guard, registration: AttemptRegistration) -> Step {
  let AttemptRegistration(running:, permit:, billing:) = registration
  let guard = hold_attempt(guard, running)
  let accepted = adopt_running(guard, running)
  process.send(permit, case accepted {
    True -> BeginAttempt
    False -> RejectAttempt
  })
  let pending_usage = case accepted {
    True -> Some(accounting.unknown_usage(billing))
    False -> None
  }
  sm.keep(Guard(..guard, pending_usage:))
}

// Adopts a registration and refuses it. Adoption still happens, because a
// transport the custodian does not know about is one it cannot wait for.
fn refuse_attempt(guard: Guard, registration: AttemptRegistration) -> Guard {
  let AttemptRegistration(running:, permit:, billing: _) = registration
  let guard = hold_attempt(guard, running)
  let _accepted = adopt_running(guard, running)
  process.send(permit, RejectAttempt)
  guard
}

fn adopt_running(guard: Guard, running: RunningRequest) -> Bool {
  case guard.custodian {
    Some(custodian) ->
      custodian.adopt_owner(custodian, http.owner(running), fn() {
        http.cancel(running)
      })

    // Unreachable: no attempt can be registered before the permit that
    // publishes the custodian releases the pump.
    None -> False
  }
}

// Takes custody of a new attempt, releasing the monitor on the one it
// supersedes so that a superseded owner's exit never has to be told apart
// from the live one's.
fn hold_attempt(guard: Guard, running: RunningRequest) -> Guard {
  release_attempt(guard.attempt)
  Guard(
    ..guard,
    attempt: LiveAttempt(
      running:,
      monitor: process.monitor(http.owner(running)),
    ),
  )
}

fn release_attempt(attempt: Attempt) -> Nil {
  case attempt {
    LiveAttempt(monitor:, ..) -> process.demonitor_process(monitor)
    NoAttempt | ExitedAttempt(..) -> Nil
  }
}

fn record_exit(guard: Guard, exit: ActiveExit) -> Guard {
  Guard(..guard, attempt: ExitedAttempt(outcome: exit))
}

fn pump_gone(guard: Guard) -> Guard {
  Guard(..guard, pump: PumpGone)
}

// Releases the consumer monitor once its death has stopped mattering, so a
// `Down` already in flight cannot be mistaken for a live monitor's.
fn forget_consumer(guard: Guard) -> Guard {
  case guard.consumer_watch {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  Guard(..guard, consumer_watch: None)
}

fn cancel_pump(guard: Guard) -> Nil {
  case guard.pump {
    PumpRunning(control:, ..) -> process.send(control, Cancel)
    NoPump | PumpParked(..) | PumpGone -> Nil
  }
}

fn cancel_attempt(attempt: Attempt) -> Nil {
  case attempt {
    LiveAttempt(running:, ..) -> http.cancel(running)
    NoAttempt | ExitedAttempt(..) -> Nil
  }
}

fn kill_parked_pump(pump: Pump) -> Nil {
  case pump {
    PumpParked(owner:, ..) -> process.kill(owner)
    NoPump | PumpRunning(..) | PumpGone -> Nil
  }
}

// The guard is the sole terminal sender on the public subject.
fn emit(guard: Guard, event: StreamEvent) -> Nil {
  process.send(guard.events, event)
}

fn pump(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  events: process.Subject(StreamEvent),
  attempts: process.Subject(PumpUpdate),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  let walk =
    Walk(gateway:, request:, now:, events:, attempts:, control:, consumer:)
  case request.target {
    ForResolved(resolved:) -> attempt(walk, 1, [resolved], accounting.empty())
    ForRole(role:, thinking:) -> dispatch_role(walk, role, thinking)
  }
}

// A role dispatches against the usable prefix of its configured chain — a
// role naming no registered provider at all is the empty chain, handled
// here rather than by `attempt` so the reported failure names the role,
// not a generic exhaustion.
fn dispatch_role(
  walk: Walk,
  role: Role,
  thinking: Option(ThinkingLevel),
) -> Nil {
  case stop_requested(walk, accounting.empty()) {
    True -> Nil
    False ->
      case usable_chain(walk.gateway, role) {
        [] ->
          process.send(
            walk.events,
            Failed(
              NoIdentity(role: model.role_to_string(role)),
              accounting.empty(),
            ),
          )
        chain -> attempt(walk, 1, overlaid(chain, thinking), accounting.empty())
      }
  }
}

// The caller's reasoning-budget overlay, applied to the *whole* chain
// before the walk starts (`protocol-change/009`). Applying it here rather
// than per attempt is the point: a fallback target must be asked for the
// budget the turn asked for, not for whatever its own route row declares,
// or a walk would silently change how hard the model thinks. `None` is the
// other half of the contract — each target keeps its own static level.
fn overlaid(
  chain: List(ResolvedModel),
  thinking: Option(ThinkingLevel),
) -> List(ResolvedModel) {
  case thinking {
    None -> chain
    Some(level) ->
      list.map(chain, fn(target) { ResolvedModel(..target, thinking: level) })
  }
}

// Walks the chain: one streamed attempt per target, falling to the next
// target only on a retryable failure. The last attempt's terminal event
// is delivered as-is, so an exhausted chain surfaces the real error.
fn attempt(
  walk: Walk,
  ordinal: Int,
  targets: List(ResolvedModel),
  report: RequestAccounting,
) -> Nil {
  case stop_requested(walk, report) {
    True -> Nil
    False ->
      case targets {
        [] ->
          // Unreachable from `pump` (chains are non-empty), kept total.
          process.send(
            walk.events,
            Failed(NoIdentity(role: "exhausted chain"), report),
          )
        [target, ..rest] ->
          continue_or_deliver(
            walk,
            ordinal,
            attempt_one(walk, ordinal, target),
            report,
            rest,
          )
      }
  }
}

// The one terminal event a fallback walk ever has to decide about: retry
// the remaining chain on a retryable failure, otherwise deliver whatever
// came back (a settlement, or a terminal failure) as-is.
fn continue_or_deliver(
  walk: Walk,
  ordinal: Int,
  outcome: AttemptOutcome,
  previous: RequestAccounting,
  rest: List(ResolvedModel),
) -> Nil {
  let report = accounting.combine(previous, outcome_accounting(outcome))

  // The surviving guard retains the priced prefix before another target starts.
  // Repeated stream snapshots never pass this point as separate attempts.
  process.send(walk.attempts, ReportRetained(report))
  case outcome {
    AttemptCancelled(context, _) ->
      process.send(
        walk.events,
        Failed(stream.with_context(ProviderCancelled, context), report),
      )
    AttemptCancellationUnconfirmed(context, _) ->
      process.send(
        walk.events,
        Failed(
          stream.with_context(stream.CancellationUnconfirmed, context),
          report,
        ),
      )
    AttemptDrainProofLost(context, _) ->
      process.send(
        walk.events,
        Failed(stream.with_context(stream.DrainProofLost, context), report),
      )
    ConsumerGone(_) -> Nil
    AttemptTerminal(terminal:) ->
      continue_terminal(walk, ordinal, terminal, report, rest)
  }
}

fn continue_terminal(
  walk: Walk,
  ordinal: Int,
  terminal: StreamEvent,
  report: RequestAccounting,
  rest: List(ResolvedModel),
) -> Nil {
  case terminal, rest {
    Failed(error:, ..), [_, ..] ->
      case retry.classify(error) {
        Retryable(backoff_hint_ms: _) ->
          attempt(walk, ordinal + 1, rest, report)
        Terminal -> process.send(walk.events, with_accounting(terminal, report))
      }
    _, _ -> process.send(walk.events, with_accounting(terminal, report))
  }
}

// Runs one attempt against one target, delivering deltas as they stream
// and returning the attempt's terminal event.
fn attempt_one(
  walk: Walk,
  ordinal: Int,
  target: ResolvedModel,
) -> AttemptOutcome {
  let gateway = walk.gateway
  let now = walk.now
  let limit =
    list.key_find(gateway.image_limits, #(target.provider, target.model_id))
    |> result.unwrap(image_budget.default_max_images)
  use messages <- or_image_failure(
    image_budget.project(walk.request.messages, limit, gateway.protected_images),
    fn(reason) {
      AttemptTerminal(Failed(
        stream.StreamError(
          api_error_type: "image_limit",
          message: target.provider <> "/" <> target.model_id <> ": " <> reason,
        ),
        accounting.empty(),
      ))
    },
  )
  let request = model.ProviderRequest(..walk.request, messages:)
  use config <- or_failure(find_provider(gateway, target.provider), fn() {
    AttemptTerminal(Failed(
      UnknownProvider(provider: target.provider),
      accounting.empty(),
    ))
  })
  let cyber_access =
    option.from_result(list.key_find(gateway.cyber_access, target.provider))
  let outcome = case config {
    AnthropicProvider(name:, base_url:, api_key_secret:) ->
      keyed_attempt(
        walk,
        name,
        api_key_secret,
        fn(api_key) {
          anthropic.build_request(
            base_url:,
            api_key:,
            resolved: target,
            request:,
          )
        },
        anthropic.response_machine(target, now:),
      )
    OpenAiCompatibleProvider(name:, base_url:, api_key_secret:) ->
      keyed_attempt(
        walk,
        name,
        api_key_secret,
        fn(api_key) {
          openai.build_request(base_url:, api_key:, resolved: target, request:)
        },
        openai.response_machine(target, now:),
      )
    OpenAiResponsesProvider(name:, base_url:, api_key_secret:) ->
      keyed_attempt(
        walk,
        name,
        api_key_secret,
        fn(api_key) {
          responses.build_request_with_access(
            base_url,
            api_key,
            target,
            request,
            cyber_access,
          )
        },
        responses.response_machine(target, now:),
      )
    GeminiProvider(name:, base_url:, api_key_secret:) ->
      keyed_attempt(
        walk,
        name,
        api_key_secret,
        fn(api_key) {
          gemini.build_request(base_url:, api_key:, resolved: target, request:)
        },
        gemini.response_machine(target, now:),
      )
    CodexSubscriptionProvider(name: _, profile:) ->
      subscription_attempt(walk, profile, target, request)
  }

  // Costing sits between the adapter and the walk's terminal, which is the
  // one place every settlement passes through exactly once and the last
  // place the target that produced it is still known. Doing it here rather
  // than in the adapters keeps them ignorant of commercial arrangements,
  // and doing it before `continue_or_deliver` means the ledger writes a
  // priced record without a second costing pass anywhere above the seam.
  priced(gateway, outcome, target)
  |> annotate_attempt(ordinal, gateway.attempt_timeout_ms)
}

// API-key dispatch remains the only branch that reads a secret. Scrubbing
// happens before the fallback walk can inspect or retain a remote failure.
fn keyed_attempt(
  walk: Walk,
  name: String,
  secret_name: String,
  build: fn(String) -> http.HttpRequest,
  machine: stream.ResponseMachine(state),
) -> AttemptOutcome {
  use api_key <- or_failure(
    secret.lookup(walk.gateway.secrets, secret_name),
    fn() {
      AttemptTerminal(Failed(
        NoSecret(provider: name, secret_name:),
        accounting.empty(),
      ))
    },
  )
  tracked(
    walk,
    walk.gateway.transport,
    build(api_key),
    machine,
    usage_evidence.Api,
  )
  |> scrub_attempt(api_key)
}

// The optional bridge is never substituted with the public API-key transport.
// A missing bridge or profile fails before request preparation.
fn subscription_attempt(
  walk: Walk,
  profile: String,
  target: ResolvedModel,
  request: ProviderRequest,
) -> AttemptOutcome {
  case profile, walk.gateway.codex_transport {
    "", _ ->
      AttemptTerminal(Failed(
        stream.StreamError(
          api_error_type: "codex_profile_missing",
          message: "Codex subscription profile is empty",
        ),
        accounting.empty(),
      ))
    _, None ->
      AttemptTerminal(Failed(
        stream.StreamError(
          api_error_type: "codex_transport_unavailable",
          message: "Codex subscription transport is unavailable",
        ),
        accounting.empty(),
      ))
    profile, Some(CodexTransport(prepare_streaming:)) ->
      tracked(
        walk,
        http.Transport(prepare_streaming: fn(built, events) {
          prepare_streaming(profile, built, events)
        }),
        responses.build_subscription_request_with_access(
          target,
          request,
          option.from_result(list.key_find(
            walk.gateway.cyber_access,
            target.provider,
          )),
        ),
        responses.subscription_response_machine(target, now: walk.now),
        usage_evidence.ChatGptPlan,
      )
  }
}

// Both dispatch shapes run the same tracked attempt: deltas go straight to the
// consumer, the transport is registered with the guard before it begins, and
// the attempt is bounded by the gateway's attempt timeout. Only the transport,
// the built request and the billing basis differ.
fn tracked(
  walk: Walk,
  transport: Transport,
  built: http.HttpRequest,
  machine: stream.ResponseMachine(state),
  billing: usage_evidence.Billing,
) -> AttemptOutcome {
  stream.run_tracked(
    transport,
    built,
    machine,
    fn(delta) { process.send(walk.events, Delta(delta:)) },
    fn(running) {
      register_attempt(walk.attempts, running, walk.consumer, billing)
    },
    control: walk.control,
    consumer: walk.consumer,
    within: walk.gateway.attempt_timeout_ms,
  )
}

// The ordinal names this route walk, independently of the machine's retries.
fn annotate_attempt(
  outcome: AttemptOutcome,
  ordinal: Int,
  timeout: Int,
) -> AttemptOutcome {
  case outcome {
    AttemptTerminal(terminal) ->
      AttemptTerminal(stream.contextual_event(
        terminal,
        stream.FailureObservation(
          stream.GatewaySource,
          stream.TerminalResponse,
          Some(ordinal),
          Some(timeout),
          Some(request_cancel_grace_ms),
          None,
        ),
      ))
    AttemptCancelled(context, report) ->
      AttemptCancelled(
        stream.FailureObservation(..context, attempt: Some(ordinal)),
        report,
      )
    AttemptCancellationUnconfirmed(context, report) ->
      AttemptCancellationUnconfirmed(
        stream.FailureObservation(..context, attempt: Some(ordinal)),
        report,
      )
    AttemptDrainProofLost(context, report) ->
      AttemptDrainProofLost(
        stream.FailureObservation(..context, attempt: Some(ordinal)),
        report,
      )
    ConsumerGone(report) -> ConsumerGone(report)
  }
}

fn gateway_failure(
  error: stream.ProviderError,
  cause: stream.FailureCause,
  report: RequestAccounting,
) -> StreamEvent {
  Failed(
    stream.with_context(
      error,
      stream.FailureObservation(
        stream.GatewaySource,
        cause,
        None,
        None,
        Some(request_cancel_grace_ms),
        None,
      ),
    ),
    report,
  )
}

// Each attempt is priced under its actual target before the fallback fold.
// Failures retain reported consumption too; an absent card keeps the
// estimate unavailable instead of certifying the adapter's numeric zero.
fn priced(
  gateway: Gateway,
  outcome: AttemptOutcome,
  target: ResolvedModel,
) -> AttemptOutcome {
  case list.key_find(gateway.prices, target.provider) {
    Error(Nil) -> outcome
    Ok(card) -> {
      let report = price_attempt(outcome_accounting(outcome), card)
      case outcome {
        AttemptTerminal(Settled(message: settled, ..)) ->
          AttemptTerminal(Settled(repriced(settled, card), report))
        AttemptTerminal(Failed(error:, ..)) ->
          AttemptTerminal(Failed(error, report))
        AttemptTerminal(Delta(..) as delta) -> AttemptTerminal(delta)
        AttemptCancelled(context, _) -> AttemptCancelled(context, report)
        AttemptCancellationUnconfirmed(context, _) ->
          AttemptCancellationUnconfirmed(context, report)
        AttemptDrainProofLost(context, _) ->
          AttemptDrainProofLost(context, report)
        ConsumerGone(_) -> ConsumerGone(report)
      }
    }
  }
}

// Context readers consume only the final assistant's usage, while the report
// owns the request sum. Pricing this message separately preserves that split.
// Updating usage cannot change its settled stop reason, so settle succeeds.
fn repriced(
  settled: stream.SettledAssistantMessage,
  card: pricing.Pricing,
) -> stream.SettledAssistantMessage {
  case stream.message(settled) {
    AssistantMessage(..) as assistant ->
      AssistantMessage(..assistant, usage: pricing.price(assistant.usage, card))
      |> stream.settle
      |> result.unwrap(settled)

    _other -> settled
  }
}

// The remote endpoint necessarily sees the request key and can reflect it in
// any diagnostic field. Scrub the terminal before retry classification, not
// only before final delivery, so a fallback never carries the credential into
// another lifetime or a later diagnostic.
fn scrub_attempt(outcome: AttemptOutcome, api_key: String) -> AttemptOutcome {
  case outcome {
    AttemptTerminal(Failed(error:, accounting: report)) ->
      AttemptTerminal(Failed(
        error: diagnostic.scrub_error(error, api_key),
        accounting: report,
      ))
    AttemptTerminal(terminal:) -> AttemptTerminal(terminal:)
    AttemptCancelled(context, report) -> AttemptCancelled(context, report)
    AttemptCancellationUnconfirmed(context, report) ->
      AttemptCancellationUnconfirmed(context, report)
    AttemptDrainProofLost(context, report) ->
      AttemptDrainProofLost(context, report)
    ConsumerGone(report) -> ConsumerGone(report)
  }
}

// Registration is a synchronous ownership handoff. The prepared transport
// cannot begin until the guard has retained its outer custodian. The guard
// continues rejecting registrations even after its public cancellation
// deadline, so this wait always receives a decision while the guard is alive.
// Rejection cancels the prepared owner before `run_tracked` sends its begin
// message; per-sender ordering prevents the underlying transport from starting.
fn register_attempt(
  attempts: process.Subject(PumpUpdate),
  running: RunningRequest,
  guard: process.Pid,
  billing: usage_evidence.Billing,
) -> Nil {
  let permit = process.new_subject()
  let guard_monitor = process.monitor(guard)
  process.send(
    attempts,
    TransportPrepared(AttemptRegistration(running:, permit:, billing:)),
  )
  let permit =
    process.new_selector()
    |> process.select(permit)
    |> process.select_specific_monitor(guard_monitor, fn(_down) {
      RejectAttempt
    })
    |> process.selector_receive_forever()
  process.demonitor_process(guard_monitor)
  case permit {
    BeginAttempt -> Nil
    RejectAttempt -> http.cancel(running)
  }
}

// Cancellation is checked before any target starts, including a fallback.
// A live consumer receives the one cancellation terminal; a dead consumer
// needs no terminal and only suppresses new work.
fn stop_requested(walk: Walk, report: RequestAccounting) -> Bool {
  case process.is_alive(walk.consumer) {
    False -> True
    True ->
      case process.receive(walk.control, within: 0) {
        Ok(Cancel) -> {
          process.send(walk.events, Failed(ProviderCancelled, report))
          True
        }
        Error(Nil) -> False
      }
  }
}

// Unwraps a `Result(a, Nil)` into a `StreamEvent`-returning continuation,
// or the given terminal failure on `Error` — the gateway's counterpart to
// `machine/planner`'s `or_fault`, for the one place here a lookup failure
// must become an in-band `Failed` rather than a corruption report.
fn or_failure(
  result: Result(a, Nil),
  on_error: fn() -> AttemptOutcome,
  then: fn(a) -> AttemptOutcome,
) -> AttemptOutcome {
  case result {
    Error(Nil) -> on_error()
    Ok(value) -> then(value)
  }
}

// An image-budget rejection is terminal before secret lookup or transport
// registration. Keeping its reason preserves the corrective action for users.
fn or_image_failure(
  result: Result(a, String),
  failure: fn(String) -> AttemptOutcome,
  next: fn(a) -> AttemptOutcome,
) -> AttemptOutcome {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> failure(reason)
  }
}

// A custodian can retain only observations it received. Its permitted current
// attempt is unknown when the pump dies before replacing that observation.
fn retained_accounting(guard: Guard) -> RequestAccounting {
  case guard.pending_usage {
    None -> guard.report
    Some(usage) -> accounting.append(guard.report, usage)
  }
}

fn outcome_accounting(outcome: AttemptOutcome) -> RequestAccounting {
  case outcome {
    AttemptTerminal(terminal) -> stream.terminal_accounting(terminal)
    AttemptCancelled(accounting: report, ..)
    | AttemptCancellationUnconfirmed(accounting: report, ..)
    | AttemptDrainProofLost(accounting: report, ..)
    | ConsumerGone(accounting: report) -> report
  }
}

fn with_accounting(
  event: StreamEvent,
  report: RequestAccounting,
) -> StreamEvent {
  case event {
    Settled(message:, ..) -> Settled(message, report)
    Failed(error:, ..) -> Failed(error, report)
    Delta(..) -> event
  }
}

// This boundary sees exactly one target's report: `stream.run_tracked` never returns
// more than one attempt, so the report's `last` is the whole attempt and
// pricing it alone prices everything the target consumed. Pricing precedes
// route-fold addition, so fallback models can have different rates without
// repricing history.
fn price_attempt(
  report: RequestAccounting,
  card: Pricing,
) -> RequestAccounting {
  case accounting.last(report) {
    None -> report
    Some(usage) -> accounting.from_usage(pricing.price(usage, card))
  }
}
