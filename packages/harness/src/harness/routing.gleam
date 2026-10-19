//// Which model a request is sent to: roles, chains, thinking levels and the
//// vision route.
////
//// A captured `ModelIdentity` is a durable fact, and the decision about where
//// to send a request made under it must be a pure function of durable state
//// and boot configuration. That is what lets a re-attempt after a crash
//// choose what the original attempt chose: recovery orphans an in-flight
//// request and re-attempts it, it never re-dispatches one. So there is no
//// per-request rerouting, no mutable role registry, no health tracking and no
//// sticky chain position. The head of a chain is tried first, every time.
////
//// Moved here from `client/wiring` (issue #1030), whose decisions are quoted
//// below because they are the reason the code has this shape.
////
//// - **Role follows identity.** An `effects.RequestSpec` carries no strand
////   name and one configuration serves every strand, so the captured
////   identity decides. A generation whose identity **heads a role's usable
////   chain** dispatches `ForRole`, so a retryable failure walks that chain
////   inside the one attempt rather than burning the machine's ladder against
////   a rate-limited endpoint. An identity no role heads dispatches
////   `ForResolved` to exactly what was captured, which keeps a strand
////   switched off-route running.
//// - **A deferred poll is always `ForResolved`.** The handle is bound to the
////   identity that minted it and ORCH-L4 validates a settlement against
////   exactly that value, so a poll that walked a chain would fetch a
////   continuation nobody issued.
//// - **Thinking levels** collapse the machine's seven-point scale onto the
////   provider's four-point one, and the strand's per-turn level travels as an
////   overlay onto every target a role walk attempts, so neither a route's
////   static configuration nor a fallback entry's can override what the turn
////   asked for.
////
//// ## Flow
////
//// `request_target` picks `ForRole` through `routed_role` or falls to
//// `resolved_target`; `vision_route` is the vision chain's target for an
//// image-bearing request; `resolution` asks whether a role still routes;
//// `thinking_level` and `strand_thinking_level` are the two directions of the
//// thinking map.

import gleam/list
import gleam/option.{type Option, None, Some}
import harness/model_facts.{type Fallback, type Lookup}
import harness/vision
import machine/operation.{OperationError}
import machine/planner.{type ModelResolution, ModelResolved, ModelUnresolved}
import machine/strand.{type ModelIdentity, type StrandConfiguration}
import provider/gateway.{type Gateway}
import provider/model.{
  type RequestTarget, type ResolvedModel, type Role, ForResolved, ForRole,
  ResolvedModel,
}

/// The routing facts a provider request owns: the gateway, the role the host
/// asks `resolution` about, and the model facts. Never tool executors, jail
/// policy or broker callbacks, so it is cheap to copy into every process which
/// holds the provider surface.
pub type Routing {
  Routing(
    /// The provider gateway, fully routed.
    gateway: Gateway,
    /// The role `resolution` asks the gateway about. Dispatch does not read
    /// it as the strand's route: the role a request is served under is
    /// derived from the captured identity, in canonical order, whatever this
    /// names. It leads the candidates only when it is neither `Main` nor
    /// `Subagent`.
    role: Role,
    /// The identity-keyed model facts.
    lookup: Lookup,
    /// The figures for an identity the lookup does not know.
    fallback: Fallback,
  )
}

/// Resolves the captured identity into a generation's dispatch target.
///
/// **On route** the target is `ForRole` for that role, carrying the strand's
/// per-turn thinking level as an overlay. **Off route** it is `ForResolved`
/// on exactly the captured identity, with its own facts behind it. Both
/// answers are a pure function of durable state and boot configuration.
///
/// ## Examples
///
/// ```gleam
/// // routing.request_target(routing, configuration)
/// // -> model.ForRole(role: model.Main, thinking: Some(model.ThinkingHigh))
/// ```
///
pub fn request_target(
  routing: Routing,
  configuration: StrandConfiguration,
) -> RequestTarget {
  case routed_role(routing, configuration.model) {
    Ok(role) ->
      ForRole(
        role:,
        thinking: Some(thinking_level(configuration.thinking_level)),
      )
    Error(Nil) -> resolved_target(routing, configuration)
  }
}

/// The dispatch target for a request which must reach exactly the captured
/// identity and nothing else: a deferred poll, and any generation whose
/// identity no configured role heads.
///
/// ## Examples
///
/// ```gleam
/// // routing.resolved_target(routing, configuration)
/// // -> model.ForResolved(model.ResolvedModel(provider: "acme", ..))
/// ```
///
pub fn resolved_target(
  routing: Routing,
  configuration: StrandConfiguration,
) -> RequestTarget {
  let identity = configuration.model
  let facts =
    model_facts.of_identity(routing.lookup, routing.fallback, identity)

  ForResolved(resolved: ResolvedModel(
    provider: identity.provider,
    model_id: identity.model_id,
    thinking: thinking_level(configuration.thinking_level),
    context_window: facts.context_window,
    max_output_tokens: facts.max_output_tokens,
  ))
}

/// The vision chain's target for one image-bearing request, or `None` when no
/// usable chain resolves.
///
/// The thinking overlay is the strand's own per-turn level, carried onto every
/// target the walk attempts, exactly as `request_target` carries it for the
/// strand's own route: a turn that raised its reasoning budget reaches the
/// vision model with the budget it would have reached its own with.
///
/// ## Examples
///
/// ```gleam
/// // routing.vision_route(routing, configuration)
/// ```
///
pub fn vision_route(
  routing: Routing,
  configuration: StrandConfiguration,
) -> Option(RequestTarget) {
  case gateway.resolve(routing.gateway, model.Vision) {
    Ok(_head) ->
      Some(
        vision.routed_target(
          thinking: Some(thinking_level(configuration.thinking_level)),
        ),
      )
    Error(_missing) -> None
  }
}

/// Whether the configured role still routes, asked before a deferred poll and
/// by the resolution hook.
///
/// The gateway is the authority: a role whose chain has no usable provider
/// cannot be dispatched to, and saying so here fails the operation in band
/// instead of at the transport.
///
/// ## Examples
///
/// ```gleam
/// // routing.resolution(gateway, model.Main) == planner.ModelResolved
/// ```
///
pub fn resolution(provider_gateway: Gateway, role: Role) -> ModelResolution {
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

// Which role, if any, this dispatch is on route for.
//
// A role serves a request exactly when the head of its usable chain is the
// identity the intent captured, because the head is what `gateway.resolve`
// would have stored and what the walk will try first. Candidates are taken in
// canonical order so the answer is a function of durable state alone: a tie
// between `main` and `subagent` routed to the same entry resolves to `main`,
// every time, on every boot.
fn routed_role(routing: Routing, identity: ModelIdentity) -> Result(Role, Nil) {
  list.find(candidate_roles(routing.role), fn(role) {
    case gateway.resolve(routing.gateway, role) {
      Ok(resolved) -> heads(resolved, identity)
      Error(_missing) -> False
    }
  })
}

fn heads(resolved: ResolvedModel, identity: ModelIdentity) -> Bool {
  resolved.provider == identity.provider
  && resolved.model_id == identity.model_id
}

// The configured role leads only when it is neither `main` nor `subagent`,
// which is the one case a host has said something the canonical order does
// not cover.
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

/// Collapses the machine's seven-point thinking scale onto the provider's
/// four-point scale.
///
/// ## Examples
///
/// ```gleam
/// assert routing.thinking_level(strand.ThinkingMax) == model.ThinkingHigh
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
/// seven-point scale, the section of `thinking_level`.
///
/// This is where a route's static thinking configuration takes effect: at
/// strand *creation*, seeding the durable per-turn level. It is never
/// consulted at dispatch, where the per-turn level is absolute.
///
/// ## Examples
///
/// ```gleam
/// assert routing.strand_thinking_level(model.ThinkingHigh)
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
