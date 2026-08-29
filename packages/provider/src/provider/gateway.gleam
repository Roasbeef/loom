//// The provider gateway: a typed registry of provider configurations and
//// role routes, exposing the frozen contract (spec §1.5) —
//// `resolve(gw, role)` and `request(gw, req)`.
////
//// The gateway is pure data plus injected effects: a `Transport` (HTTP),
//// a `SecretStore` (API keys), and a `Clock` (timestamps). Construction
//// is the builder pattern; nothing touches the network until `request`.
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

import core/clock.{type Clock}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/adapter/anthropic
import provider/adapter/openai
import provider/http.{type RunningRequest, type Transport}
import provider/model.{
  type MissingIdentity, type ProviderRequest, type ResolvedModel, type Role,
  type ThinkingLevel, ForResolved, ForRole, MissingIdentity, ResolvedModel,
}
import provider/retry.{Retryable, Terminal}
import provider/secret.{type SecretStore}
import provider/stream.{
  type AttemptOutcome, type Control, type StreamEvent, type StreamHandle,
  AttemptCancellationUnconfirmed, AttemptCancelled, AttemptTerminal, Cancel,
  ConsumerGone, Delta, Failed, NoIdentity, NoSecret, ProviderCancelled, Settled,
  UnknownProvider,
}

const request_start_timeout_ms = 5000

const request_cancel_grace_ms = 1500

type RequestControl {
  CancelRequest
  CancelDeadline
}

type RequestEvent {
  PumpEvent(StreamEvent)
  AttemptStarted(RunningRequest)
  ConsumerDown(process.Down)
  PumpDown(process.Down)
  CancelRequested
  CancelExpired
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
/// `"https://api.openai.com/v1"`); `api_key_secret` is a secret *name*,
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
}

/// The gateway registry. Built with `new` and the pipeable setters;
/// consumed by `resolve` and `request`.
pub opaque type Gateway {
  /// Invariants: `providers` hold unique names (later registrations of a
  /// name shadow earlier ones via first-match lookup order); `routes`
  /// map each role to its ordered fallback chain, best target first;
  /// `attempt_timeout_ms` is positive and bounds each idle wait on one
  /// attempt's response.
  Gateway(
    providers: List(ProviderConfig),
    routes: List(#(Role, List(ResolvedModel))),
    transport: Transport,
    secrets: SecretStore,
    clock: Clock,
    attempt_timeout_ms: Int,
  )
}

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
    transport:,
    secrets:,
    clock:,
    attempt_timeout_ms: 300_000,
  )
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

/// Overrides the per-attempt idle timeout (milliseconds).
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
/// The handle's subject is owned by the calling process; a public guard owns
/// its lifecycle while a private pump runs the fallback walk, so this returns
/// immediately without making a pump crash indistinguishable from silence.
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
  let consumer = process.self()
  let events = process.new_subject()
  let ready = process.new_subject()
  let #(now, _clock) = clock.read(gateway.clock)
  let owner =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let pump_ready = process.new_subject()
      let pump_events = process.new_subject()
      let pump_attempts = process.new_subject()
      let self = process.self()
      let pump_owner =
        process.spawn_unlinked(fn() {
          let pump_control = process.new_subject()
          process.send(pump_ready, pump_control)
          pump(
            gateway,
            request,
            now,
            pump_events,
            pump_attempts,
            pump_control,
            self,
          )
        })
      let consumer_monitor = process.monitor(consumer)
      let pump_monitor = process.monitor(pump_owner)
      let pump_started =
        process.new_selector()
        |> process.select_map(pump_ready, Ok)
        |> process.select_specific_monitor(pump_monitor, fn(_down) {
          Error(Nil)
        })
        |> process.selector_receive(request_start_timeout_ms)
      case pump_started {
        Ok(Ok(pump_control)) -> {
          process.send(ready, control)
          guard_request(
            events,
            control,
            pump_events,
            pump_attempts,
            pump_control,
            consumer_monitor,
            pump_owner,
            pump_monitor,
            None,
          )
        }
        Ok(Error(Nil)) | Error(Nil) -> {
          process.kill(pump_owner)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    })
  let monitor = process.monitor(owner)
  let started =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(request_start_timeout_ms)
  process.demonitor_process(monitor: monitor)
  case started {
    Ok(Ok(control)) ->
      stream.owned(events:, owner:, cancel: fn() {
        process.send(control, CancelRequest)
      })
    Ok(Error(Nil)) | Error(Nil) -> {
      process.kill(owner)
      process.send(
        events,
        Failed(stream.TransportFailed(
          reason: "provider request owner did not start",
        )),
      )
      stream.immediate(events:, cancel: fn() { Nil })
    }
  }
}

// The public request owner is a guard rather than the process doing the route
// walk. That extra process has one job: preserve the stream law if the pump
// crashes after startup. It also makes cancellation bounded without asking the
// caller to understand the pump's monitor or the active fallback attempt.
fn guard_request(
  events: process.Subject(StreamEvent),
  control: process.Subject(RequestControl),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(RunningRequest),
  pump_control: process.Subject(Control),
  consumer_monitor: process.Monitor,
  pump_owner: process.Pid,
  pump_monitor: process.Monitor,
  active: Option(RunningRequest),
) -> Nil {
  let selector =
    request_selector(
      control,
      pump_events,
      pump_attempts,
      consumer_monitor,
      pump_monitor,
    )
  case process.selector_receive_forever(selector) {
    AttemptStarted(running) ->
      guard_request(
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        Some(running),
      )
    PumpEvent(event) -> {
      process.send(events, event)
      case event {
        Delta(..) ->
          guard_request(
            events,
            control,
            pump_events,
            pump_attempts,
            pump_control,
            consumer_monitor,
            pump_owner,
            pump_monitor,
            active,
          )
        Settled(..) | Failed(..) -> {
          await_active_forever(active)
          await_pump_down_forever(pump_owner, pump_monitor)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    }
    ConsumerDown(_down) ->
      stop_for_dead_consumer(
        pump_control,
        pump_owner,
        consumer_monitor,
        pump_monitor,
        active,
      )
    PumpDown(_down) -> {
      process.demonitor_process(consumer_monitor)
      case stop_active(active, request_cancel_grace_ms) {
        True ->
          process.send(
            events,
            Failed(stream.TransportFailed(
              reason: "provider request pump stopped before a terminal response",
            )),
          )
        False -> {
          process.send(events, Failed(stream.CancellationUnconfirmed))
          await_active_forever(active)
        }
      }
    }
    CancelRequested -> {
      process.send(pump_control, Cancel)
      let _timer =
        process.send_after(control, request_cancel_grace_ms, CancelDeadline)
      guard_cancelling(
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        active,
      )
    }
    CancelExpired ->
      guard_request(
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        active,
      )
  }
}

// Cancellation remains an owner-authored terminal. The guard forwards a real
// pump terminal if one arrives; pump death or expiry only proves that the
// request could not confirm which side of the race won.
fn guard_cancelling(
  events: process.Subject(StreamEvent),
  control: process.Subject(RequestControl),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(RunningRequest),
  pump_control: process.Subject(Control),
  consumer_monitor: process.Monitor,
  pump_owner: process.Pid,
  pump_monitor: process.Monitor,
  active: Option(RunningRequest),
) -> Nil {
  let selector =
    request_selector(
      control,
      pump_events,
      pump_attempts,
      consumer_monitor,
      pump_monitor,
    )
  case process.selector_receive_forever(selector) {
    AttemptStarted(running) -> {
      http.cancel(running)
      guard_cancelling(
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        Some(running),
      )
    }
    PumpEvent(event) ->
      case event {
        Delta(..) ->
          guard_cancelling(
            events,
            control,
            pump_events,
            pump_attempts,
            pump_control,
            consumer_monitor,
            pump_owner,
            pump_monitor,
            active,
          )
        Settled(..) | Failed(..) -> {
          process.send(events, event)
          await_active_forever(active)
          await_pump_down_forever(pump_owner, pump_monitor)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    ConsumerDown(_down) ->
      stop_for_dead_consumer(
        pump_control,
        pump_owner,
        consumer_monitor,
        pump_monitor,
        active,
      )
    PumpDown(_down) -> {
      process.send(pump_control, Cancel)
      http_cancel(active)
      process.send(events, Failed(stream.CancellationUnconfirmed))
      await_active_forever(active)
      process.demonitor_process(consumer_monitor)
    }
    CancelExpired -> {
      process.send(pump_control, Cancel)
      http_cancel(active)
      process.send(events, Failed(stream.CancellationUnconfirmed))
      await_active_forever(active)
      await_pump_down_forever(pump_owner, pump_monitor)
      forget_request(consumer_monitor, pump_monitor)
    }
    CancelRequested ->
      guard_cancelling(
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        active,
      )
  }
}

fn request_selector(
  control: process.Subject(RequestControl),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(RunningRequest),
  consumer_monitor: process.Monitor,
  pump_monitor: process.Monitor,
) -> process.Selector(RequestEvent) {
  process.new_selector()
  |> process.select_map(pump_events, PumpEvent)
  |> process.select_map(pump_attempts, AttemptStarted)
  |> process.select_map(control, fn(message) {
    case message {
      CancelRequest -> CancelRequested
      CancelDeadline -> CancelExpired
    }
  })
  |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
  |> process.select_specific_monitor(pump_monitor, PumpDown)
}

// A dead public consumer needs no terminal, but the pump still gets one grace
// interval to run its ordinary cancellation path. Killing it immediately would
// bypass an injected transport's cancel capability and would make the test
// seam weaker than the production custodian.
fn stop_for_dead_consumer(
  pump_control: process.Subject(Control),
  pump_owner: process.Pid,
  consumer_monitor: process.Monitor,
  pump_monitor: process.Monitor,
  active: Option(RunningRequest),
) -> Nil {
  process.send(pump_control, Cancel)
  http_cancel(active)
  await_active_forever(active)
  await_pump_down_forever(pump_owner, pump_monitor)
  forget_request(consumer_monitor, pump_monitor)
}

fn http_cancel(active: Option(RunningRequest)) -> Nil {
  case active {
    None -> Nil
    Some(running) -> http.cancel(running)
  }
}

fn stop_active(active: Option(RunningRequest), within: Int) -> Bool {
  case active {
    None -> False
    Some(running) -> {
      http.cancel(running)
      await_running_down(running, within)
    }
  }
}

fn await_active_forever(active: Option(RunningRequest)) -> Nil {
  case active {
    None -> Nil
    Some(running) -> {
      let monitor = process.monitor(http.owner(running))
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
  }
}

fn await_running_down(running: RunningRequest, within: Int) -> Bool {
  let monitor = process.monitor(http.owner(running))
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { True })
    |> process.selector_receive(within)
    |> result.unwrap(False)
  process.demonitor_process(monitor)
  down
}

fn await_pump_down_forever(
  owner: process.Pid,
  monitor: process.Monitor,
) -> Nil {
  case process.is_alive(owner) {
    False -> Nil
    True -> {
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
  }
}

fn forget_request(
  consumer_monitor: process.Monitor,
  pump_monitor: process.Monitor,
) -> Nil {
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(pump_monitor)
}

fn pump(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case request.target {
    ForResolved(resolved:) ->
      attempt(
        gateway,
        request,
        now,
        [resolved],
        events,
        attempts,
        control,
        consumer,
      )
    ForRole(role:, thinking:) ->
      dispatch_role(
        gateway,
        request,
        now,
        role,
        thinking,
        events,
        attempts,
        control,
        consumer,
      )
  }
}

// A role dispatches against the usable prefix of its configured chain — a
// role naming no registered provider at all is the empty chain, handled
// here rather than by `attempt` so the reported failure names the role,
// not a generic exhaustion.
fn dispatch_role(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  role: Role,
  thinking: Option(ThinkingLevel),
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case stop_requested(control, consumer, events) {
    True -> Nil
    False ->
      case usable_chain(gateway, role) {
        [] ->
          process.send(
            events,
            Failed(NoIdentity(role: model.role_to_string(role))),
          )
        chain ->
          attempt(
            gateway,
            request,
            now,
            overlaid(chain, thinking),
            events,
            attempts,
            control,
            consumer,
          )
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
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  targets: List(ResolvedModel),
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case stop_requested(control, consumer, events) {
    True -> Nil
    False ->
      case targets {
        [] ->
          // Unreachable from `pump` (chains are non-empty), kept total.
          process.send(events, Failed(NoIdentity(role: "exhausted chain")))
        [target, ..rest] -> {
          let outcome =
            attempt_one(
              gateway,
              request,
              now,
              target,
              events,
              attempts,
              control,
              consumer,
            )
          continue_or_deliver(
            gateway,
            request,
            now,
            outcome,
            rest,
            events,
            attempts,
            control,
            consumer,
          )
        }
      }
  }
}

// The one terminal event a fallback walk ever has to decide about: retry
// the remaining chain on a retryable failure, otherwise deliver whatever
// came back (a settlement, or a terminal failure) as-is.
fn continue_or_deliver(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  outcome: AttemptOutcome,
  rest: List(ResolvedModel),
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case outcome {
    AttemptCancelled -> process.send(events, Failed(ProviderCancelled))
    AttemptCancellationUnconfirmed ->
      process.send(events, Failed(stream.CancellationUnconfirmed))
    ConsumerGone -> Nil
    AttemptTerminal(terminal:) ->
      continue_terminal(
        gateway,
        request,
        now,
        terminal,
        rest,
        events,
        attempts,
        control,
        consumer,
      )
  }
}

fn continue_terminal(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  terminal: StreamEvent,
  rest: List(ResolvedModel),
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case terminal, rest {
    Failed(error:), [_, ..] ->
      case retry.classify(error) {
        Retryable(backoff_hint_ms: _) ->
          attempt(
            gateway,
            request,
            now,
            rest,
            events,
            attempts,
            control,
            consumer,
          )
        Terminal -> process.send(events, terminal)
      }
    _, _ -> process.send(events, terminal)
  }
}

// Runs one attempt against one target, delivering deltas as they stream
// and returning the attempt's terminal event.
fn attempt_one(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  target: ResolvedModel,
  events: process.Subject(StreamEvent),
  attempts: process.Subject(RunningRequest),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> AttemptOutcome {
  let deliver = fn(delta) { process.send(events, Delta(delta:)) }
  use config <- or_failure(find_provider(gateway, target.provider), fn() {
    AttemptTerminal(Failed(UnknownProvider(provider: target.provider)))
  })
  use api_key <- or_failure(
    secret.lookup(gateway.secrets, config.api_key_secret),
    fn() {
      AttemptTerminal(
        Failed(NoSecret(
          provider: config.name,
          secret_name: config.api_key_secret,
        )),
      )
    },
  )
  case config {
    AnthropicProvider(name: _, base_url:, api_key_secret: _) ->
      stream.run_tracked(
        gateway.transport,
        anthropic.build_request(base_url:, api_key:, resolved: target, request:),
        anthropic.response_machine(target, now:),
        deliver,
        fn(running) { process.send(attempts, running) },
        control:,
        consumer:,
        within: gateway.attempt_timeout_ms,
      )
    OpenAiCompatibleProvider(name: _, base_url:, api_key_secret: _) ->
      stream.run_tracked(
        gateway.transport,
        openai.build_request(base_url:, api_key:, resolved: target, request:),
        openai.response_machine(target, now:),
        deliver,
        fn(running) { process.send(attempts, running) },
        control:,
        consumer:,
        within: gateway.attempt_timeout_ms,
      )
  }
}

// Cancellation is checked before any target starts, including a fallback.
// A live consumer receives the one cancellation terminal; a dead consumer
// needs no terminal and only suppresses new work.
fn stop_requested(
  control: process.Subject(Control),
  consumer: process.Pid,
  events: process.Subject(StreamEvent),
) -> Bool {
  case process.is_alive(consumer) {
    False -> True
    True ->
      case process.receive(control, within: 0) {
        Ok(Cancel) -> {
          process.send(events, Failed(ProviderCancelled))
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
