//// The provider gateway: a typed registry of provider configurations and
//// role routes, exposing the frozen contract (spec §1.5) —
//// `resolve(gw, role)` and `request(gw, req)`.
////
//// The gateway is pure data plus injected effects: a `Transport` (HTTP),
//// a `SecretStore` (API keys), and a `Clock` (timestamps). Construction
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

import core/clock.{type Clock}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/adapter/anthropic
import provider/adapter/openai
import provider/custodian
import provider/http.{type RunningRequest, type Transport}
import provider/internal/diagnostic
import provider/model.{
  type MissingIdentity, type ProviderRequest, type ResolvedModel, type Role,
  type ThinkingLevel, ForResolved, ForRole, MissingIdentity, ResolvedModel,
}
import provider/retry.{Retryable, Terminal}
import provider/secret.{type SecretStore}
import provider/stream.{
  type AttemptOutcome, type Control, type StreamEvent, type StreamHandle,
  AttemptCancellationUnconfirmed, AttemptCancelled, AttemptDrainProofLost,
  AttemptTerminal, Cancel, ConsumerGone, Delta, Failed, NoIdentity, NoSecret,
  ProviderCancelled, Settled, UnknownProvider,
}

const request_start_timeout_ms = 5000

const request_cancel_grace_ms = 1500

type RequestControl {
  CancelRequest
  CancelDeadline
}

type RequestStart {
  BeginRequest(custodian.Custodian)
}

type ParkedRequestEvent {
  StartRequest(custodian.Custodian)
  StopBeforeRequest
}

type ParkedPumpEvent {
  StartPump
  StopBeforePump
}

type AttemptRegistration {
  AttemptRegistration(
    running: RunningRequest,
    permit: process.Subject(AttemptPermit),
  )
}

type AttemptPermit {
  BeginAttempt
  RejectAttempt
}

// The guard keeps the monitor created before it publishes an attempt permit.
// Carrying the monitor with the capability prevents a later pump failure from
// collapsing normal drain, abnormal exit, and a late `noproc` into one Boolean.
type ActiveAttempt {
  ActiveAttempt(running: RunningRequest, monitor: process.Monitor)
}

type RequestEvent {
  PumpEvent(StreamEvent)
  AttemptStarted(AttemptRegistration)
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
  /// `attempt_timeout_ms` is positive and bounds one attempt from transport
  /// start through settlement. Response activity does not renew the deadline.
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
  let ready = process.new_subject()
  let #(now, _clock) = clock.read(gateway.clock)
  let owner =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let begin = process.new_subject()
      let creator_monitor = process.monitor(consumer)
      process.send(ready, #(control, begin))
      let parked =
        process.new_selector()
        |> process.select_map(begin, fn(message) {
          let BeginRequest(owner) = message
          StartRequest(owner)
        })
        |> process.select_map(control, fn(_cancel) { StopBeforeRequest })
        |> process.select_specific_monitor(creator_monitor, fn(_down) {
          StopBeforeRequest
        })
        |> process.selector_receive_forever()
      case parked {
        StopBeforeRequest -> process.demonitor_process(creator_monitor)
        StartRequest(custodian) -> {
          // The public custodian monitors the consumer after publication, so
          // this temporary edge is needed only across prepare's return gap.
          process.demonitor_process(creator_monitor)
          start_request(
            gateway,
            request,
            now,
            events,
            control,
            consumer,
            custodian,
          )
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
    Ok(Ok(#(control, begin))) -> {
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
    Ok(Error(Nil)) | Error(Nil) -> {
      process.kill(owner)
      process.send(
        events,
        Failed(stream.TransportFailed(
          reason: "provider request owner did not start",
        )),
      )
      stream.PreparedStream(
        handle: stream.immediate(events:, cancel: fn() { Nil }),
        begin: fn() { Nil },
      )
    }
  }
}

fn start_request(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  events: process.Subject(StreamEvent),
  control: process.Subject(RequestControl),
  consumer: process.Pid,
  custodian: custodian.Custodian,
) -> Nil {
  let pump_ready = process.new_subject()
  let pump_events = process.new_subject()
  let pump_attempts = process.new_subject()
  let self = process.self()
  let pump_owner =
    process.spawn_unlinked(fn() {
      let pump_control = process.new_subject()
      let pump_begin = process.new_subject()
      let creator_monitor = process.monitor(self)
      process.send(pump_ready, #(pump_control, pump_begin))

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
          pump(
            gateway,
            request,
            now,
            pump_events,
            pump_attempts,
            pump_control,
            self,
          )
        }
      }
    })
  let consumer_monitor = process.monitor(consumer)
  let pump_monitor = process.monitor(pump_owner)
  let pump_started =
    process.new_selector()
    |> process.select_map(pump_ready, Ok)
    |> process.select_specific_monitor(pump_monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(request_start_timeout_ms)
  case pump_started {
    Ok(Ok(#(pump_control, pump_begin))) -> {
      let adopted =
        custodian.adopt_leaf(custodian, pump_owner, fn() {
          process.send(pump_control, Cancel)
        })
      case adopted {
        True -> {
          process.send(pump_begin, Nil)
          guard_request(
            custodian,
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
        False -> {
          // The pump has not crossed its begin gate. Rejection means this
          // process retains teardown responsibility if the custodian died, so
          // kill the parked pump instead of starting secret lookup.
          process.kill(pump_owner)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    }
    Ok(Error(Nil)) | Error(Nil) -> {
      process.kill(pump_owner)
      forget_request(consumer_monitor, pump_monitor)
    }
  }
}

// The public request owner is a guard rather than the process doing the route
// walk. That extra process has one job: preserve the stream law if the pump
// crashes after startup. It also makes cancellation bounded without asking the
// caller to understand the pump's monitor or the active fallback attempt.
fn guard_request(
  custodian: custodian.Custodian,
  events: process.Subject(StreamEvent),
  control: process.Subject(RequestControl),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(AttemptRegistration),
  pump_control: process.Subject(Control),
  consumer_monitor: process.Monitor,
  pump_owner: process.Pid,
  pump_monitor: process.Monitor,
  active: Option(ActiveAttempt),
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
    AttemptStarted(AttemptRegistration(running:, permit:)) -> {
      release_active(active)
      let active =
        ActiveAttempt(running:, monitor: process.monitor(http.owner(running)))
      let accepted =
        custodian.adopt_owner(custodian, http.owner(running), fn() {
          http.cancel(running)
        })
      process.send(permit, case accepted {
        True -> BeginAttempt
        False -> RejectAttempt
      })
      guard_request(
        custodian,
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        Some(active),
      )
    }
    PumpEvent(event) -> {
      case event {
        Delta(..) -> {
          process.send(events, event)
          guard_request(
            custodian,
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
        Settled(..) | Failed(..) -> {
          let terminal = case await_active_forever(active) {
            stream.Drained -> event
            stream.TimedOut | stream.ProofLost -> Failed(stream.DrainProofLost)
          }
          process.send(events, terminal)
          await_pump_down_forever(pump_owner, pump_monitor)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    }
    ConsumerDown(_down) ->
      stop_for_dead_consumer(
        custodian,
        pump_control,
        pump_attempts,
        consumer_monitor,
        pump_monitor,
        active,
      )
    PumpDown(_down) -> {
      process.demonitor_process(consumer_monitor)
      case stop_active(active, request_cancel_grace_ms) {
        stream.Drained ->
          process.send(
            events,
            Failed(stream.TransportFailed(
              reason: "provider request pump stopped before a terminal response",
            )),
          )
        stream.TimedOut -> {
          process.send(events, Failed(stream.CancellationUnconfirmed))
          let _drained = await_active_forever(active)
          Nil
        }
        stream.ProofLost -> process.send(events, Failed(stream.DrainProofLost))
      }
    }
    CancelRequested -> {
      process.send(pump_control, Cancel)
      let _timer =
        process.send_after(control, request_cancel_grace_ms, CancelDeadline)
      guard_cancelling(
        custodian,
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
        custodian,
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
  custodian: custodian.Custodian,
  events: process.Subject(StreamEvent),
  control: process.Subject(RequestControl),
  pump_events: process.Subject(StreamEvent),
  pump_attempts: process.Subject(AttemptRegistration),
  pump_control: process.Subject(Control),
  consumer_monitor: process.Monitor,
  pump_owner: process.Pid,
  pump_monitor: process.Monitor,
  active: Option(ActiveAttempt),
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
    AttemptStarted(AttemptRegistration(running:, permit:)) -> {
      release_active(active)
      let active =
        ActiveAttempt(running:, monitor: process.monitor(http.owner(running)))
      let _accepted =
        custodian.adopt_owner(custodian, http.owner(running), fn() {
          http.cancel(running)
        })
      process.send(permit, RejectAttempt)
      guard_cancelling(
        custodian,
        events,
        control,
        pump_events,
        pump_attempts,
        pump_control,
        consumer_monitor,
        pump_owner,
        pump_monitor,
        Some(active),
      )
    }
    PumpEvent(event) ->
      case event {
        Delta(..) ->
          guard_cancelling(
            custodian,
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
        Settled(..) | Failed(stream.CancellationUnconfirmed) -> {
          // CancellationUnconfirmed is deliberately bounded for the public
          // caller. The guard remains alive behind that terminal until the
          // retained witness eventually adjudicates the real owner exit.
          process.send(events, event)
          let _drained = await_active_forever(active)
          await_pump_down_forever(pump_owner, pump_monitor)
          forget_request(consumer_monitor, pump_monitor)
        }
        Failed(..) -> {
          let terminal = case await_active_forever(active) {
            stream.Drained -> event
            stream.TimedOut | stream.ProofLost -> Failed(stream.DrainProofLost)
          }
          process.send(events, terminal)
          await_pump_down_forever(pump_owner, pump_monitor)
          forget_request(consumer_monitor, pump_monitor)
        }
      }
    ConsumerDown(_down) ->
      stop_for_dead_consumer(
        custodian,
        pump_control,
        pump_attempts,
        consumer_monitor,
        pump_monitor,
        active,
      )
    PumpDown(_down) -> {
      process.demonitor_process(consumer_monitor)
      case stop_active(active, request_cancel_grace_ms) {
        stream.Drained ->
          process.send(events, Failed(stream.CancellationUnconfirmed))
        stream.TimedOut -> {
          process.send(events, Failed(stream.CancellationUnconfirmed))
          let _drained = await_active_forever(active)
          Nil
        }
        stream.ProofLost -> process.send(events, Failed(stream.DrainProofLost))
      }
    }
    CancelExpired -> {
      process.send(pump_control, Cancel)
      http_cancel(active)
      let outcome = await_active(active, within: 0)
      case outcome {
        stream.ProofLost -> process.send(events, Failed(stream.DrainProofLost))
        stream.Drained | stream.TimedOut ->
          process.send(events, Failed(stream.CancellationUnconfirmed))
      }
      case outcome {
        stream.TimedOut -> {
          let _drained = await_active_forever(active)
          Nil
        }
        stream.Drained | stream.ProofLost -> Nil
      }
      await_pump_down_rejecting_attempts(
        custodian,
        pump_attempts,
        pump_monitor,
        None,
      )
      forget_request(consumer_monitor, pump_monitor)
    }
    CancelRequested ->
      guard_cancelling(
        custodian,
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
  pump_attempts: process.Subject(AttemptRegistration),
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
  custodian: custodian.Custodian,
  pump_control: process.Subject(Control),
  pump_attempts: process.Subject(AttemptRegistration),
  consumer_monitor: process.Monitor,
  pump_monitor: process.Monitor,
  active: Option(ActiveAttempt),
) -> Nil {
  process.send(pump_control, Cancel)
  http_cancel(active)
  abandon_request(
    custodian,
    pump_attempts,
    consumer_monitor,
    pump_monitor,
    active,
  )
}

// The pump may be blocked handing a freshly prepared attempt to the guard when
// the public consumer dies. Keep accepting and refusing those handoffs until
// the pump exits; otherwise both processes could wait forever before the
// underlying transport had even been allowed to start.
fn abandon_request(
  custodian: custodian.Custodian,
  pump_attempts: process.Subject(AttemptRegistration),
  consumer_monitor: process.Monitor,
  pump_monitor: process.Monitor,
  active: Option(ActiveAttempt),
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(pump_attempts, AttemptStarted)
    |> process.select_specific_monitor(pump_monitor, PumpDown)
    |> process.selector_receive_forever()
  case event {
    AttemptStarted(AttemptRegistration(running:, permit:)) -> {
      release_active(active)
      let active =
        ActiveAttempt(running:, monitor: process.monitor(http.owner(running)))
      let _accepted =
        custodian.adopt_owner(custodian, http.owner(running), fn() {
          http.cancel(running)
        })
      process.send(permit, RejectAttempt)
      http.cancel(running)
      abandon_request(
        custodian,
        pump_attempts,
        consumer_monitor,
        pump_monitor,
        Some(active),
      )
    }
    PumpDown(_down) -> {
      let _drained = await_active_forever(active)
      forget_request(consumer_monitor, pump_monitor)
    }
    PumpEvent(_) | ConsumerDown(_) | CancelRequested | CancelExpired ->
      abandon_request(
        custodian,
        pump_attempts,
        consumer_monitor,
        pump_monitor,
        active,
      )
  }
}

fn http_cancel(active: Option(ActiveAttempt)) -> Nil {
  case active {
    None -> Nil
    Some(ActiveAttempt(running:, ..)) -> http.cancel(running)
  }
}

fn stop_active(
  active: Option(ActiveAttempt),
  within timeout: Int,
) -> stream.DrainOutcome {
  http_cancel(active)
  await_active(active, within: timeout)
}

fn await_active(
  active: Option(ActiveAttempt),
  within timeout: Int,
) -> stream.DrainOutcome {
  case active {
    None -> stream.Drained
    Some(ActiveAttempt(monitor:, ..)) -> {
      let outcome =
        process.new_selector()
        |> process.select_specific_monitor(monitor, active_drain_outcome)
        |> process.selector_receive(timeout)
        |> result.unwrap(stream.TimedOut)
      case outcome {
        stream.TimedOut -> Nil
        stream.Drained | stream.ProofLost -> process.demonitor_process(monitor)
      }
      outcome
    }
  }
}

fn await_active_forever(active: Option(ActiveAttempt)) -> stream.DrainOutcome {
  case active {
    None -> stream.Drained
    Some(ActiveAttempt(monitor:, ..)) -> {
      let outcome =
        process.new_selector()
        |> process.select_specific_monitor(monitor, active_drain_outcome)
        |> process.selector_receive_forever()
      process.demonitor_process(monitor)
      outcome
    }
  }
}

fn active_drain_outcome(down: process.Down) -> stream.DrainOutcome {
  case down {
    process.ProcessDown(reason:, ..) ->
      case reason {
        process.Normal -> stream.Drained
        process.Killed | process.Abnormal(_) -> stream.ProofLost
      }
    process.PortDown(..) -> stream.ProofLost
  }
}

fn release_active(active: Option(ActiveAttempt)) -> Nil {
  case active {
    None -> Nil
    Some(ActiveAttempt(monitor:, ..)) -> process.demonitor_process(monitor)
  }
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

// Expiry closes the public response window, not the pump's ownership frontier.
// A transport preparation already in progress can still publish after that
// terminal. Reject registrations until PumpDown so each parked owner receives
// a permit decision and the pump cannot remain blocked behind a dead guard loop.
fn await_pump_down_rejecting_attempts(
  custodian: custodian.Custodian,
  attempts: process.Subject(AttemptRegistration),
  monitor: process.Monitor,
  active: Option(ActiveAttempt),
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(attempts, AttemptStarted)
    |> process.select_specific_monitor(monitor, PumpDown)
    |> process.selector_receive_forever()
  case event {
    AttemptStarted(AttemptRegistration(running:, permit:)) -> {
      release_active(active)
      let active =
        ActiveAttempt(running:, monitor: process.monitor(http.owner(running)))
      let _accepted =
        custodian.adopt_owner(custodian, http.owner(running), fn() {
          http.cancel(running)
        })
      process.send(permit, RejectAttempt)
      await_pump_down_rejecting_attempts(
        custodian,
        attempts,
        monitor,
        Some(active),
      )
    }
    PumpDown(_down) -> {
      let _drained = await_active_forever(active)
      Nil
    }
    PumpEvent(_) | ConsumerDown(_) | CancelRequested | CancelExpired ->
      await_pump_down_rejecting_attempts(custodian, attempts, monitor, active)
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
  attempts: process.Subject(AttemptRegistration),
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
  attempts: process.Subject(AttemptRegistration),
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
  attempts: process.Subject(AttemptRegistration),
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
  attempts: process.Subject(AttemptRegistration),
  control: process.Subject(Control),
  consumer: process.Pid,
) -> Nil {
  case outcome {
    AttemptCancelled -> process.send(events, Failed(ProviderCancelled))
    AttemptCancellationUnconfirmed ->
      process.send(events, Failed(stream.CancellationUnconfirmed))
    AttemptDrainProofLost -> process.send(events, Failed(stream.DrainProofLost))
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
  attempts: process.Subject(AttemptRegistration),
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
  attempts: process.Subject(AttemptRegistration),
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
  let outcome = case config {
    AnthropicProvider(name: _, base_url:, api_key_secret: _) ->
      stream.run_tracked(
        gateway.transport,
        anthropic.build_request(base_url:, api_key:, resolved: target, request:),
        anthropic.response_machine(target, now:),
        deliver,
        fn(running) { register_attempt(attempts, running, consumer) },
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
        fn(running) { register_attempt(attempts, running, consumer) },
        control:,
        consumer:,
        within: gateway.attempt_timeout_ms,
      )
  }
  scrub_attempt(outcome, api_key)
}

// The remote endpoint necessarily sees the request key and can reflect it in
// any diagnostic field. Scrub the terminal before retry classification, not
// only before final delivery, so a fallback never carries the credential into
// another lifetime or a later diagnostic.
fn scrub_attempt(outcome: AttemptOutcome, api_key: String) -> AttemptOutcome {
  case outcome {
    AttemptTerminal(Failed(error:)) ->
      AttemptTerminal(Failed(error: diagnostic.scrub_error(error, api_key)))
    AttemptTerminal(terminal:) -> AttemptTerminal(terminal:)
    AttemptCancelled -> AttemptCancelled
    AttemptCancellationUnconfirmed -> AttemptCancellationUnconfirmed
    AttemptDrainProofLost -> AttemptDrainProofLost
    ConsumerGone -> ConsumerGone
  }
}

// Registration is a synchronous ownership handoff. The prepared transport
// cannot begin until the guard has retained its outer custodian. The guard
// continues rejecting registrations even after its public cancellation
// deadline, so this wait always receives a decision while the guard is alive.
// Rejection cancels the prepared owner before `run_tracked` sends its begin
// message; per-sender ordering prevents the underlying transport from starting.
fn register_attempt(
  attempts: process.Subject(AttemptRegistration),
  running: RunningRequest,
  guard: process.Pid,
) -> Nil {
  let permit = process.new_subject()
  let guard_monitor = process.monitor(guard)
  process.send(attempts, AttemptRegistration(running:, permit:))
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
