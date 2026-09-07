# ADR-012: keep Responses inference separate from Codex authentication

**Status**: accepted · **Date**: 2026-09-07 · **Supersedes**: nothing ·
**Relates to**: [issue #117](https://github.com/Roasbeef/loom/issues/117)
(Responses and subscription support),
[issue #189](https://github.com/Roasbeef/loom/issues/189)
(malformed tool arguments)

## The question

Issue #117 proposes two integrations: public Responses API inference and
experimental Codex subscription access. Both must preserve Loom's
ownership of conversation history, tool execution, policy, and the agent
loop. The issue makes documented support for the subscription integration
a merge gate; if the supported boundary is Codex App Server, Loom must use
that boundary or defer the integration.

OpenAI documents ChatGPT subscription authentication for Codex and
separate, usage-billed Platform API keys. Its authentication guide also
directs general API calls to Platform keys, not Codex access tokens.
[Authentication documentation](https://learn.chatgpt.com/docs/auth).

App Server exposes Codex threads and turns, including persisted dynamic
tools and its own execution lifecycle. Those are useful integration
surfaces, but they are not a documented raw-inference replacement for
Loom's provider request. That distinction remains even where an App Server
method can inject history or submit a tool result.
[App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Decision

**Implement public Responses inference with API keys; defer subscription
inference until its supported boundary is established.**

`openai-responses` is a separate dialect from `openai`, which continues to
mean Chat Completions. It uses the existing HTTP transport and attempt
owner. Requests carry Loom's reconstructed history with `store: false`,
not a provider conversation identifier. No frozen request field, native
helper, credential-file reader, or OAuth refresh owner is needed for this
integration.

No `codex-subscription` dialect or authentication-profile placeholder ships
with this work. Reopening that track requires documented support or
explicit OpenAI confirmation for a boundary that accepts caller-owned
history and tools, performs inference without a second agent loop, and
has a supported credential lifecycle. This is a missing-support-evidence
finding, not a claim that such an integration is prohibited.

## Why

A direct call to a private backend might work with a subscription token,
and Codex source can explain how Codex itself authenticates. Neither
establishes a supported interface for Loom. Shipping such a path would
make credential custody and compatibility depend on an assumption the
issue explicitly requires us to verify.

Embedding App Server is a different integration: Loom would need to
reconcile two conversation and execution owners. We do not add that
architecture merely to treat its login flow as a provider credential
source. The cost of deferral is explicit: this change does not let an
operator spend ChatGPT subscription credits through Loom.

Responses replay also distinguishes wire corruption from a model's bad
tool arguments. Streamed argument bytes and their completion records must
agree. Once they agree, the shared `provider/internal/wire.tool_arguments`
decoder applies the convention established by #189: malformed JSON or a
non-object becomes an invalid-arguments sentinel, so the tool path can
return a corrective result. Empty arguments retain the existing empty
object convention. The older #117 requirement to reject these model
mistakes as `MalformedStream` does not override that later fix.

## Consequences

Operators configure `dialect = "openai-responses"`, `auth = "api-key"`,
and an `api_key_env` name. Subscription authentication and arbitrary
header bags remain rejected. A model entry's name is durable provider
identity; changing an existing entry's dialect in place can reinterpret
stored history, so a different dialect gets a different entry name.

Encrypted reasoning is opaque replay material, not an authentication
credential. The adapter validates the surrounding replay metadata and
does not inject arbitrary stored JSON into requests. Tests must cover
request construction, stream agreement, durable replay, usage accounting,
and a complete runtime tool turn. Existing transport deadlines and native
drain guarantees apply without a new process owner.

Issue #117 remains open for its deferred subscription track. A later
supported integration needs an addendum here, including the evidence that
satisfies the gate and the owner of login, refresh, cancellation, and
history.
