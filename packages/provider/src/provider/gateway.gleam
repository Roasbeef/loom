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
////   settled response never falls back.
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
import provider/adapter/anthropic
import provider/adapter/openai
import provider/http.{type Transport}
import provider/model.{
  type MissingIdentity, type ProviderRequest, type ResolvedModel, type Role,
  ForResolved, ForRole, MissingIdentity,
}
import provider/retry.{Retryable, Terminal}
import provider/secret.{type SecretStore}
import provider/stream.{
  type StreamEvent, type StreamHandle, Delta, Failed, NoIdentity, NoSecret,
  StreamHandle, UnknownProvider,
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
/// The handle's subject is owned by the calling process; the request
/// itself runs on a dedicated pump process, so this returns immediately.
///
/// ## Examples
///
/// ```gleam
/// // let handle = gateway.request(gw, model.ProviderRequest(
/// //   target: model.ForRole(model.Main),
/// //   system: option.Some("You are ..."),
/// //   messages: projected,
/// //   tools: tools,
/// //   max_output_tokens: option.None,
/// // ))
/// // stream.await_terminal(handle, within: 300_000)
/// ```
///
pub fn request(gateway: Gateway, request: ProviderRequest) -> StreamHandle {
  let events = process.new_subject()
  let #(now, _clock) = clock.read(gateway.clock)
  let _pump =
    process.spawn_unlinked(fn() { pump(gateway, request, now, events) })
  StreamHandle(events:)
}

fn pump(
  gateway: Gateway,
  request: ProviderRequest,
  now: Int,
  events: process.Subject(StreamEvent),
) -> Nil {
  case request.target {
    ForResolved(resolved:) -> attempt(gateway, request, now, [resolved], events)
    ForRole(role:) -> dispatch_role(gateway, request, now, role, events)
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
  events: process.Subject(StreamEvent),
) -> Nil {
  case usable_chain(gateway, role) {
    [] ->
      process.send(events, Failed(NoIdentity(role: model.role_to_string(role))))
    chain -> attempt(gateway, request, now, chain, events)
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
) -> Nil {
  case targets {
    [] ->
      // Unreachable from `pump` (chains are non-empty), kept total.
      process.send(events, Failed(NoIdentity(role: "exhausted chain")))
    [target, ..rest] -> {
      let terminal = attempt_one(gateway, request, now, target, events)
      continue_or_deliver(gateway, request, now, terminal, rest, events)
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
  terminal: StreamEvent,
  rest: List(ResolvedModel),
  events: process.Subject(StreamEvent),
) -> Nil {
  case terminal, rest {
    Failed(error:), [_, ..] ->
      case retry.classify(error) {
        Retryable(backoff_hint_ms: _) ->
          attempt(gateway, request, now, rest, events)
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
) -> StreamEvent {
  let deliver = fn(delta) { process.send(events, Delta(delta:)) }
  use config <- or_failure(find_provider(gateway, target.provider), fn() {
    Failed(UnknownProvider(provider: target.provider))
  })
  use api_key <- or_failure(
    secret.lookup(gateway.secrets, config.api_key_secret),
    fn() {
      Failed(NoSecret(provider: config.name, secret_name: config.api_key_secret))
    },
  )
  case config {
    AnthropicProvider(name: _, base_url:, api_key_secret: _) ->
      stream.run(
        gateway.transport,
        anthropic.build_request(base_url:, api_key:, resolved: target, request:),
        anthropic.response_machine(target, now:),
        deliver,
        within: gateway.attempt_timeout_ms,
      )
    OpenAiCompatibleProvider(name: _, base_url:, api_key_secret: _) ->
      stream.run(
        gateway.transport,
        openai.build_request(base_url:, api_key:, resolved: target, request:),
        openai.response_machine(target, now:),
        deliver,
        within: gateway.attempt_timeout_ms,
      )
  }
}

// Unwraps a `Result(a, Nil)` into a `StreamEvent`-returning continuation,
// or the given terminal failure on `Error` — the gateway's counterpart to
// `machine/planner`'s `or_fault`, for the one place here a lookup failure
// must become an in-band `Failed` rather than a corruption report.
fn or_failure(
  result: Result(a, Nil),
  on_error: fn() -> StreamEvent,
  then: fn(a) -> StreamEvent,
) -> StreamEvent {
  case result {
    Error(Nil) -> on_error()
    Ok(value) -> then(value)
  }
}
