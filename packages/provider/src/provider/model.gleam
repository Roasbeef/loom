//// Model identity and request vocabulary for the provider gateway.
////
//// This module holds the pure data types shared by the gateway, the
//// adapters, and the streaming machinery: which model a request targets
//// (`Role`, `ResolvedModel`), and what the request carries
//// (`ProviderRequest`, `ToolSpec`). It performs no I/O and depends only on
//// `core` types.
////
//// Per the frozen contract (spec §1.5), fallback chains resolve at
//// dispatch and durable state stores the resolved `{provider, model_id}`
//// pair. `ResolvedModel` is that durable identity plus the static model
//// facts (context window, output ceiling, thinking level) an adapter needs
//// to build a request and to compute overflow at settlement.

import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/option.{type Option}

/// The purpose a model is being asked to serve. Roles map to ordered
/// fallback chains in the gateway registry (spec §1.5).
///
/// Constructor invariants: `Custom` carries a non-empty application-chosen
/// role name; the five named roles are the design-doc vocabulary.
pub type Role {
  /// The main conversation model.
  Main

  /// The model used for subagent strands.
  Subagent

  /// The model used for plan generation.
  Plan

  /// The model used for compaction and navigation summaries.
  Summarize

  /// The model used for image-bearing requests.
  Vision

  /// An application-defined role.
  Custom(name: String)
}

/// Renders a role for error messages and durable summaries.
///
/// ## Examples
///
/// ```gleam
/// assert model.role_to_string(model.Main) == "main"
/// ```
///
/// ```gleam
/// assert model.role_to_string(model.Custom("critic")) == "custom:critic"
/// ```
///
pub fn role_to_string(role: Role) -> String {
  case role {
    Main -> "main"
    Subagent -> "subagent"
    Plan -> "plan"
    Summarize -> "summarize"
    Vision -> "vision"
    Custom(name:) -> "custom:" <> name
  }
}

/// How much extended reasoning the request asks for. Adapters translate
/// the level into their provider's dialect (a thinking token budget for
/// the Anthropic Messages API, `reasoning_effort` for OpenAI-compatible
/// APIs); `ThinkingOff` sends no reasoning configuration at all.
pub type ThinkingLevel {
  /// No extended reasoning requested.
  ThinkingOff

  /// A small reasoning budget.
  ThinkingLow

  /// A medium reasoning budget.
  ThinkingMedium

  /// A large reasoning budget.
  ThinkingHigh
}

/// A fully resolved model identity, produced by `gateway.resolve` or
/// carried in durable operation state. This is the value the machine
/// persists at intent time so recovery re-dispatches to exactly the same
/// provider and model.
///
/// Constructor invariants: `provider` names a provider config registered
/// in the gateway; `model_id` is that provider's model identifier;
/// `context_window` and `max_output_tokens` are positive token counts —
/// `context_window` is what adapter-computed overflow detection compares
/// against (spec §1.5).
pub type ResolvedModel {
  ResolvedModel(
    provider: String,
    model_id: String,
    thinking: ThinkingLevel,
    context_window: Int,
    max_output_tokens: Int,
  )
}

/// The error returned by `gateway.resolve` when a role has no usable
/// route, per the frozen contract.
///
/// Constructor invariants: `role` is the role that failed to resolve.
pub type MissingIdentity {
  MissingIdentity(role: Role)
}

/// One tool made available to the model.
///
/// Constructor invariants: `name` is unique within a request;
/// `input_schema` is a JSON-schema object describing the tool's arguments.
pub type ToolSpec {
  ToolSpec(name: String, description: String, input_schema: JsonValue)
}

/// Where a request should be dispatched.
///
/// Constructor invariants: `ForRole` resolves the role's fallback chain at
/// dispatch and walks it on retryable failure; `ForResolved` dispatches to
/// exactly the given identity with no fallback — the shape used when the
/// machine re-dispatches a durably stored resolved identity.
///
/// `ForRole.thinking` is the caller's reasoning-budget overlay
/// (`protocol-change/009`). `None` leaves each walked target's own static
/// level in force — the route entry's declared `thinking`, which is what a
/// summarization route configured `off` means. `Some(level)` overlays that
/// level onto **every** target the walk attempts, so a turn that raised or
/// lowered its budget reaches the fallback with the same budget it would
/// have reached the head with.
pub type RequestTarget {
  /// Resolve the role's chain at dispatch time.
  ForRole(role: Role, thinking: Option(ThinkingLevel))

  /// Dispatch to a previously resolved identity, no fallback.
  ForResolved(resolved: ResolvedModel)
}

/// One assistant-generation request, in provider-neutral shape. Adapters
/// translate it into their wire dialect.
///
/// Constructor invariants: `messages` is the projected conversation in
/// order, ending with the content the model should respond to;
/// `CustomMessage` values must already be projected away (adapters skip
/// any that remain); `max_output_tokens`, when set, overrides the resolved
/// model's default output ceiling.
pub type ProviderRequest {
  ProviderRequest(
    target: RequestTarget,
    system: Option(String),
    messages: List(AgentMessage),
    tools: List(ToolSpec),
    max_output_tokens: Option(Int),
  )
}

/// What one attempt authenticates with.
///
/// The credential is resolved by the gateway and rendered by the adapter,
/// because where it goes on the wire is a fact about the dialect: an API
/// key goes wherever that dialect puts one (`authorization: Bearer` for
/// the chat-completions dialect, `x-api-key` for Messages,
/// `x-goog-api-key` for `generateContent`), while an L402 credential
/// always goes in `authorization`, since it is an HTTP authentication
/// scheme rather than a vendor header.
///
/// Constructor invariants: the string inside `ApiKeyCredential` and
/// `L402Credential` is a secret *value*, read at dispatch and copied into
/// exactly one outbound header — the gateway scrubs it from any terminal
/// error before that error can be classified, delivered, or logged.
/// `L402Credential.token` is a complete header value, `l402.authorization`'s
/// output, not a bare macaroon.
pub type Credential {
  /// Send no authentication header at all. This is how a paywalled entry
  /// that has not yet paid provokes its first 402 challenge.
  NoCredential

  /// A bearer API key, in whichever header the dialect uses for one.
  ApiKeyCredential(key: String)

  /// A settled L402 credential: the whole `L402 <macaroon>:<preimage>`
  /// value, for the `authorization` header.
  L402Credential(token: String)
}

/// The secret value a credential carries, or `""` when it carries none.
///
/// The gateway scrubs this exact string out of an attempt's terminal
/// error, because a remote endpoint necessarily sees whatever was sent and
/// can reflect it back in a diagnostic field. `""` for `NoCredential` is
/// what the scrubber treats as "nothing to redact", so the no-credential
/// path needs no separate case anywhere above it.
///
/// ## Examples
///
/// ```gleam
/// assert model.credential_secret(model.ApiKeyCredential("sk-1")) == "sk-1"
/// ```
///
/// ```gleam
/// assert model.credential_secret(model.NoCredential) == ""
/// ```
///
pub fn credential_secret(credential: Credential) -> String {
  case credential {
    NoCredential -> ""
    ApiKeyCredential(key:) -> key
    L402Credential(token:) -> token
  }
}
