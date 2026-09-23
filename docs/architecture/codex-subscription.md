# Codex subscription transport

**Status: implementation target on the isolated subscription branch.** The
public Responses adapter merged in [PR #278](https://github.com/Roasbeef/loom/pull/278)
and uses a Platform API key. This note defines the separate, opt-in
ChatGPT subscription path. It does not assert that OpenAI supports the
private Codex backend as a public third-party inference API. The merge
condition in [ADR-012](../adr/012-responses-and-subscription-boundaries.md)
and [issue #117](https://github.com/Roasbeef/loom/issues/117) still applies.

## Boundary and ownership

Loom constructs each provider-neutral request from its durable history,
supplies its tools, receives model deltas, executes approved effects through
its broker, and records the result. The subscription helper acts only as a
credential owner and streaming HTTP transport. It never starts a Codex
thread or runs an inner agent loop. The pure Responses accumulator remains
the semantic decoder for both public and subscription streams. In
particular, `store: false` and caller-owned replay keep provider state out
of Loom's durable identity.

The operator selects a new catalogue entry with
`dialect = "codex-subscription"`, `auth = "codex"`, and a nonempty
`profile`. The entry has its own durable name. It cannot contain
`api_key_env`, `base_url`, arbitrary `headers`, or credential values.
`openai-responses` retains `auth = "api-key"` and its Platform key source;
`openai` remains Chat Completions. A subscription profile names only a
helper-owned credential record, never a path or host supplied to the
provider. The catalogue must reject every mixed authentication shape at
load time.

## Credential and request helper

One long-lived helper owns one dedicated profile and all subscription
requests for that profile. This implementation admits one active profile per
Loom VM and refuses a different profile while it is active. It does not parse
or reuse the installed Codex CLI's `~/.codex/auth.json` or its keyring slot.
The CLI commands run from the packaged `loomd`, which loads the helper from
that release's absolute `bin/codex-bridge` path. The helper completes a
browser sign-in flow, reports status without tokens, and supports explicit
logout. It stores access and rotating refresh material with owner-only
permissions and atomic replacement. The profile is bound to an expected
ChatGPT account ID; a later login or refresh resolving a different identity
fails closed until the operator explicitly logs out and logs in.
Parallel requests share a single refresh operation. The helper resolves
credentials per request and, after a 401, reloads or refreshes and replays
the request at most once. Permanent authentication errors are terminal;
ordinary provider fallback must not turn them into an unbounded login loop.

The helper pins the Codex backend origin internally. Loom sends a relative
`/responses` request with a Responses body and non-secret content headers;
the helper adds the bearer and account routing headers. It refuses an
operator-supplied host and redirects to another origin. The public API-key
transport never sends a subscription account header to `api.openai.com`,
and the subscription transport never sends a Platform key to
`chatgpt.com`. Request bodies use the public adapter's history and tool
projection, with only endpoint-specific fields selected by the helper.
The helper returns a redacted status, bounded SSE chunks, and one terminal
event. It cannot return raw authentication responses or token material.

The process protocol is versioned and length-prefixed, with a hard frame
limit, correlated request IDs, and explicit cancellation. The helper emits
`end` after every settled command, including a command that emitted an
`error`; cancellation instead terminates with `cancel_ack`. `error` is a
diagnostic event, never proof that HTTP or the helper has drained. Unsafe or
unreadable stored credentials produce the redacted `credential_unavailable`
code rather than an invitation to overwrite them. Unknown versions,
duplicate terminals, partial frames, helper exit, and oversized frames fault
the request owner and lose drain proof. Tokens and account IDs never
appear in protocol frames, argv, tool environments, diagnostics, logs,
telemetry, or conversation storage. A packaged release must include the
pinned helper binary and state its upstream Codex revision. Compatibility
fixtures must run when that revision changes.

## Models, limits, and user-visible state

Subscription model availability depends on the signed-in account,
workspace, plan, and current Codex catalogue. The helper queries the
Codex model-discovery route for its bound account and returns a validated
model list and capabilities. Loom should not infer that a model such as
Sol or Astra is usable from its public API name or a static default.
Configuration can select only an entitled discovered model; the model
picker and status output must distinguish unavailable, login-required,
and temporarily exhausted models. A 401 or 403 is an authentication or
access failure; a 429 is a usage-limit failure with the available reset
facts. Neither is converted into an API-key billing error. A refreshed
catalogue must not silently change a durable model identity.

## Evidence and release gate

The [official authentication guide](https://learn.chatgpt.com/docs/auth)
documents ChatGPT sign-in for Codex and separates it from Platform API
billing. The [official App Server guide](https://learn.chatgpt.com/docs/app-server)
documents an integration that owns threads and turns. The pinned
[OpenAI Codex endpoint selection](https://github.com/openai/codex/blob/5fc7840cf6d085a7a7b3438d69a2beb934a2a5f4/codex-rs/model-provider-info/src/lib.rs#L292-L333),
[Codex Responses transport](https://github.com/openai/codex/blob/5fc7840cf6d085a7a7b3438d69a2beb934a2a5f4/codex-rs/codex-api/src/endpoint/responses.rs#L92-L190),
and [oh-my-pi provider](https://github.com/can1357/oh-my-pi/blob/da58b16f424273605795435a6753778f422baff3/packages/ai/src/providers/openai-codex-responses.ts)
are implementation references. The private route and its headers may
change without public API versioning. Successful interoperability proves
technical compatibility with the tested revision, not permission or
support for Loom's use.

Acceptance requires: strict catalogue rejection for mixed auth fields;
dummy-credential tests proving host and header separation; login, status,
logout, account mismatch, refresh rotation, parallel single-flight, and
one-replay 401 tests; redirect and secret-canary tests; framing and crash
tests; model discovery and usage-limit tests; a complete Loom tool turn
with caller-owned history; release smoke proving the helper is bundled;
and the repository gates by their own exit codes. A live subscription
smoke must exercise an entitled model without storing or printing tokens.
The support gate in ADR-012 remains separately necessary before a normal
provider release. This branch has no live authenticated Sol or Astra smoke
yet, so model entitlement and full subscription inference remain unverified.
