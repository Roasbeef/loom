//// The provider half of `runtime/effects.Effects`: the routing and admission
//// that turn a `RequestSpec` into a gateway call.
////
//// The runtime asks its host for a provider surface and nothing else about
//// models. This module is that surface over a routed `provider/gateway`, and
//// it is the part of `client/wiring` that has nothing to do with a daemon
//// (issue #1030, `docs/design-notes/harness-extraction.md`). The daemon builds
//// the same `Provider` record from its `Config`; an embedder builds one
//// through `harness.new`.
////
//// A `Provider` owns routing facts and rendered tool definitions, never tool
//// executors, jail policy, environment or broker callbacks. The runtime copies
//// its `Effects` into every process and supervisor child specification which
//// holds a session, and BEAM drops sharing when it copies, so anything a
//// provider callback closes over is paid for once per holder.
////
//// - **Context and options.** `GenerationRequest.context` is already the
////   projected conversation, oldest first, and maps verbatim onto
////   `ProviderRequest.messages`. `stream_options` is the runtime's opaque
////   options bag; the provider request vocabulary has no field for it, so it
////   is dropped here. `max_output_tokens` is left `None`: the resolved
////   model's ceiling governs.
//// - **Tools on the wire.** The intent's captured `active_tool_names`, looked
////   up in the definitions and rendered as `ToolSpec`s; names with no
////   registration are omitted. The render is canonical, sorted by name with
////   duplicates collapsed, because the tool array is the byte prefix of the
////   provider's cached region and reordering it invalidates the cache head.
//// - **Polls and summaries.** `ProviderRequest` cannot express a deferred
////   continuation fetch, so a `PollRequest` settles immediately as an in-band
////   provider error; a `SummaryRequest` is refused the same way, because a
////   host which answers compaction itself dispatches no summarization prompt.
////   Both failures are terminally classified so the retry ladder is not
////   burned on a permanently absent surface.
////
//// ## Flow
////
//// `surface` wraps `dispatch` and `prepare`; `dispatch` is `prepare` followed
//// by the begin permit. `prepare` builds the request with `request`, counts
//// the protected images through `admission.active_run_images`, and hands the
//// gateway a scoped copy; a poll or a summary takes `prepared_unsupported`. `request` picks the vision route or the ordinary
//// target and shapes the body with `generation_request`.

import core/accounting
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness/admission
import harness/model_facts.{ReadsImages, TextOnly}
import harness/routing.{type Routing}
import harness/vision
import machine/strand.{type StrandConfiguration}
import provider/gateway
import provider/image_budget
import provider/model.{type ProviderRequest, type RequestTarget, type ToolSpec}
import provider/stream.{type StreamHandle}
import runtime/effects
import session/session.{type Session}
import tools/tool.{type Registry}

/// Everything a provider request needs and nothing a tool run needs.
pub type Provider {
  Provider(
    /// The routing facts: the gateway, the role, the model facts.
    routing: Routing,
    /// The session whose durable state classifies images and measures
    /// protected ones. Read only here.
    session: Session,
    /// The system prompt sent with every generation, if any.
    system: Option(String),
    /// The rendered tool definitions, keyed by name. Data alone: a schema or
    /// description may be large, but each is required on the wire.
    definitions: Dict(String, ToolSpec),
  )
}

/// Builds a provider over a registry, rendering its tool definitions once.
///
/// ## Examples
///
/// ```gleam
/// // provider.new(routing, session, system: Some("be brief"), registry:)
/// ```
///
pub fn new(
  routing: Routing,
  session: Session,
  system system: Option(String),
  registry registry: Registry,
) -> Provider {
  Provider(routing:, session:, system:, definitions: definitions(registry))
}

/// The provider surface the runtime consumes, over a provider and the time
/// the effect process waits for a terminal event.
///
/// ## Examples
///
/// ```gleam
/// // provider.surface(provider, timeout_ms: 600_000)
/// ```
///
pub fn surface(
  provider: Provider,
  timeout_ms timeout_ms: Int,
) -> effects.ProviderSurface {
  effects.PreparedProviderSurface(
    request: fn(spec) { dispatch(provider, spec) },
    prepare: fn(spec) { prepare(provider, spec) },
    timeout_ms:,
  )
}

/// Dispatches one request spec: `prepare` followed by the begin permit.
///
/// ## Examples
///
/// ```gleam
/// // provider.dispatch(provider, spec)
/// ```
///
pub fn dispatch(provider: Provider, spec: effects.RequestSpec) -> StreamHandle {
  prepare(provider, spec)
  |> stream.start_prepared
}

/// Prepares one request spec, keeping role resolution and secret lookup behind
/// the begin permit.
///
/// Only a generation reaches the gateway. A poll and a summary settle
/// immediately in band, but through the same prepare, publish, begin shape so
/// every wrapper can apply one protocol.
///
/// ## Examples
///
/// ```gleam
/// // let prepared = provider.prepare(provider, spec)
/// ```
///
pub fn prepare(
  provider: Provider,
  spec: effects.RequestSpec,
) -> stream.PreparedStream {
  case spec {
    effects.GenerationRequest(operation:, ..) -> {
      let request = request(provider, spec)
      let protected = case image_budget.count(request.messages) {
        0 -> 0
        _ ->
          admission.active_run_images(provider.session, operation)
          |> result.unwrap(0)
      }
      let scoped =
        gateway.with_protected_images(provider.routing.gateway, protected)
      gateway.prepare(scoped, request)
    }
    effects.PollRequest(..) ->
      prepared_unsupported(
        "deferred polls are not wired to a provider surface yet",
      )

    // Unreachable in production: every compaction is answered at the
    // decision, so the machine never enters its generate path here. Total all
    // the same, and terminal rather than retryable, because a summary request
    // which somehow reached the wire has no prompt it could be made with.
    effects.SummaryRequest(..) ->
      prepared_unsupported(
        "this host answers compaction with a notes checkpoint and dispatches "
        <> "no summary request",
      )
  }
}

/// Maps a generation or poll spec onto the provider-neutral request shape: the
/// pinned system prompt, the strand's tool array and the projected context.
///
/// A structural summary is not a request this host makes. The arm here keeps
/// the function total and deliberately carries nothing, because sending a
/// strand's context under a summarization intent would be worse than sending
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // provider.request(provider, spec).messages == spec.context
/// ```
///
pub fn request(
  provider: Provider,
  spec: effects.RequestSpec,
) -> ProviderRequest {
  case spec {
    effects.SummaryRequest(configuration:, ..) ->
      model.ProviderRequest(
        target: routing.request_target(provider.routing, configuration),
        system: None,
        messages: [],
        tools: [],
        max_output_tokens: None,
      )
    effects.GenerationRequest(operation:, configuration:, context:, ..) ->
      generation(provider, operation, configuration, context)

    // A poll never walks a chain: the handle it would fetch belongs to the
    // identity that minted it.
    effects.PollRequest(configuration:, ..) ->
      generation_request(
        provider,
        configuration,
        [],
        routing.resolved_target(provider.routing, configuration),
      )
  }
}

// The vision rule's dispatch half (issue #358): the request's own content, not
// the strand's pinned model, decides the target when the two disagree about
// images. An image-bearing request from a text-only model dispatches through
// the `vision` chain, admitted there already, so an unresolvable chain here
// means the registry moved between admission and dispatch, and the ordinary
// target plus placeholders is the honest fallback. Every other request to a
// text-only identity has its images placeholdered, because an image the model
// cannot read is invalid input on any turn, not just the newest one.
fn generation(
  provider: Provider,
  operation: OpId,
  configuration: StrandConfiguration,
  context: List(AgentMessage),
) -> ProviderRequest {
  let reading =
    model_facts.of_identity(
      provider.routing.lookup,
      provider.routing.fallback,
      configuration.model,
    ).reading
  let routed = case
    reading == TextOnly
    && admission.image_bearing(provider.session, operation, context)
  {
    True -> routing.vision_route(provider.routing, configuration)
    False -> None
  }

  case routed {
    Some(target) -> generation_request(provider, configuration, context, target)
    None ->
      generation_request(
        provider,
        configuration,
        case reading {
          TextOnly -> vision.placeholdered(context)
          ReadsImages -> context
        },
        routing.request_target(provider.routing, configuration),
      )
  }
}

fn generation_request(
  provider: Provider,
  configuration: StrandConfiguration,
  messages: List(AgentMessage),
  target: RequestTarget,
) -> ProviderRequest {
  model.ProviderRequest(
    target:,
    system: provider.system,
    messages:,
    tools: tool_specs(provider.definitions, configuration.active_tool_names),
    max_output_tokens: None,
  )
}

/// The rendered tool definitions of a registry: data alone, so a provider
/// request never copies a tool's executor or requirements.
///
/// ## Examples
///
/// ```gleam
/// // provider.definitions(registry) |> dict.get("bash")
/// ```
///
pub fn definitions(registry: Registry) -> Dict(String, ToolSpec) {
  tool.registered(registry)
  |> list.map(fn(registered) {
    #(
      registered.name,
      model.ToolSpec(
        name: registered.name,
        description: registered.description,
        input_schema: registered.schema,
      ),
    )
  })
  |> dict.from_list
}

/// The wire-facing specs for the active tool names, in one canonical order:
/// sorted by name, duplicates collapsed, unregistered names omitted.
///
/// ## Examples
///
/// ```gleam
/// // provider.tool_specs(definitions, ["grep", "bash", "ghost"])
/// // -> [model.ToolSpec(name: "bash", ..), model.ToolSpec(name: "grep", ..)]
/// ```
///
pub fn tool_specs(
  definitions: Dict(String, ToolSpec),
  active: List(String),
) -> List(ToolSpec) {
  // The sort is load-bearing, not tidiness. Tool definitions render ahead of
  // the system prompt and the messages in a provider request, and prompt
  // caching matches on an exact byte prefix of that render: the Anthropic
  // adapter hangs one cache breakpoint on the last tool definition and a
  // second on the system block, so this array is a strict prefix of both
  // cached regions. Two requests whose active set is the same but whose
  // configuration lists it in a different order would render different bytes
  // and miss the cache entirely, paying the write again on every turn.
  // Deduping is the same argument plus an honesty one: a name listed twice
  // would advertise the same tool twice on the wire.
  //
  // Neither step touches authorization. `tool_table.clear` decides what may
  // run by `list.contains` on the same list, and set membership is blind to
  // order and multiplicity.
  active
  |> list.sort(string.compare)
  |> list.unique
  |> list.filter_map(fn(name) { dict.get(definitions, name) })
}

fn prepared_unsupported(reason: String) -> stream.PreparedStream {
  stream.PreparedStream(handle: unsupported(reason), begin: fn() { Nil })
}

// A handle whose single event is an in-band, terminally-classified failure.
// `StreamError` with a non-transient error type is Terminal under
// `retry.classify`, so the machine fails the operation at once instead of
// burning its whole retry ladder against a surface that can never succeed (a
// transport failure would read as retryable).
fn unsupported(reason: String) -> StreamHandle {
  let events = process.new_subject()
  process.send(
    events,
    stream.Failed(
      error: stream.StreamError(
        api_error_type: "unsupported_request",
        message: reason,
      ),
      accounting: accounting.empty(),
    ),
  )
  stream.immediate(events:, cancel: fn() { Nil })
}
