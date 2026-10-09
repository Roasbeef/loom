# ChatGPT subscription provider

The subscription provider signs in with OpenAI's documented
[Sign in with ChatGPT for open-source apps](https://developers.openai.com/siwc/token-sharing-open-source)
flow, implemented in Gleam inside the server's BEAM application. It uses no
helper process and no private Codex backend. The `codex-subscription`
catalogue dialect and the `loomd codex` command keep their names.
[ADR-012](../adr/012-responses-and-subscription-boundaries.md) records the
boundary by addendum; [protocol 081](../../protocol-change/081-request-usage-accounting.md)
records the accounting contract.

## Request boundary

Loom owns history, tools, policy, effect execution, and the agent loop. The
subscription transport supplies credentials to one public Responses request;
it does not start a Codex thread or a second agent loop. The provider builds
a relative `/responses` request with nonsecret content headers, `store: false`,
`stream: true`, and functions grouped in the `loom` namespace. The native
transport validates that shape before adding a bearer to the fixed
`https://api.openai.com/v1/responses` origin. The pure Responses fold preserves
namespaced tool calls across durable replay and accepts `response.completed`.
Legacy `response.done` is rejected.

Catalogue entries require `dialect = "codex-subscription"`, `auth = "codex"`,
and a valid profile name. They reject API-key sources, alternate base URLs,
and arbitrary headers. Platform API-key entries retain their separate
`openai-responses` identity and billing arrangement. A profile is a local
registration name, never an operator-selected network host.

The optional `cyber_access` catalogue setting is a typed operator selection of
`access_programs.cyber`. The opaque gateway stores it under the provider name;
each actual Responses attempt emits that entry's selection. Missing settings
leave the server default in place. Approval and model compatibility remain
remote, and an access denial cannot remove the selection and retry as standard.
Whether an account may select a program for a model is decided by the
provider; each account establishes its own access.

## Authentication and profile ownership

`client/codex/profile` acquires a bounded kernel lock, rereads the protected
record, performs required grant work, and atomically saves rotation before
releasing the lock. No VM-wide bearer cache survives an operation. Native
profiles live under `$XDG_CONFIG_HOME/loom/chatgpt-subscription`, falling back
to `$HOME/.config/loom/chatgpt-subscription`. Existing Codex CLI credentials
and old helper grants are not imported.

Browser login binds literal `127.0.0.1` on an ephemeral port. It prints only
the local `/auth/start` URL, validates the exact bound Host authority on both
routes, and keeps state, nonce, and PKCE material inside the attempt. Initial
registration uses `dynamic_agent_client` and a stable host identity; returning
login and refresh use the issued client ID. Gose verifies the ID-token RS256
signature, issuer, audience, expiry, subject, nonce for login, and authorized
party when multiple audiences are present. Returning account binding cannot
silently change after logout or refresh.
[Sign-in contract](https://developers.openai.com/siwc/token-sharing-open-source/sign-in).

Identity-only grants are durable but cannot admit inference. Both
`resource.invoke` and `chatgpt.tokens.use.direct` are required for inference
and model discovery. Status describes the saved grant, not live entitlement.
Logout attempts refresh-token revocation, clears local authorization, and
retains registration and verified account binding. Unconfirmed revocation
remains visible. Login holds the profile lock through the browser attempt;
ordinary operations wait at most five seconds. Inference releases that lock
before its HTTP owner begins, permitting separate operator commands during
an active stream. Logout does not retract a request already admitted.

## Cancellation custody

The native transport publishes a parked, monitorable Weft operation owner before
begin. The operation adopts every HTTP owner and callback listener into the
same surviving ledger before admitting their work. Cancellation and consumer
loss address the ledger; normal operation-owner exit proves original native
owners drained. Losing a worker cannot erase its resources or replace drain
proof with a cancellation call.

The scope depends on a Weft version that starts cancelling adopted owners when
a worker exits without reporting, rather than first waiting for them, while it
keeps their original drain witnesses. Weft 0.4.6 is the first release that
does, and Loom pins it.

## Models and consumption evidence

Authenticated `/v1/models` discovery returns bounded, validated visible model
IDs. It does not invent context windows, output limits, or reasoning
capabilities, and visibility does not prove successful inference. Operators
configure those properties separately. HTTP and streamed errors retain their
authentication, access, or usage-limit classification.
[Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

The provider terminal carries a constant-size request accounting report:
aggregate usage, final-attempt observation, and attempt count. Each returned
attempt is priced before fallback, including failures. Reported snapshots
replace earlier snapshots from that attempt rather than charging twice.
Cancellation or disconnect retains reported consumption and marks missing
consumption unknown. Trusted local refusal before inference produces an empty
report; a remote HTTP error never proves no consumption.

Usage partitions uncached input, cache reads, cache writes, and output;
reasoning is a subset of output. Configured rates produce display estimates.
Missing rates and missing usage retain explicit uncertainty. Subscription
estimates are labelled API reference estimates, distinct from ChatGPT plan
credits or account charges. Actual allowance remains on ChatGPT's usage
surface; Loom does not invent a credit conversion.

Runtime persists one reserved usage row with terminal settlement or failure.
Auxiliary distillation, glance, and block summaries record their aggregate
report before using the result, including paid failures. Goals count uncached
input plus output and fold cost evidence alongside their accounting cursor.
Context and cache projections use the final observation rather than fallback
totals. An unknown all-zero observation preserves the prior measurement;
reported zero and historical nonzero observations remain measurements.
Historical records decode with unknown evidence, while malformed present
fields are refused. A fork copies history but begins a fresh usage ledger.

## Pi and Durable Pi comparison

Pi at pinned revision
[`1b094148`](https://github.com/earendil-works/pi/blob/1b094148b91d737fb398bf1591604de58ec169e1/packages/ai/src/auth/oauth/openai-chatgpt.ts)
uses the supported grant through its regular `openai` provider and retains
`openai-codex` as a legacy option. Its
[Durable Pi runtime](https://github.com/earendil-works/pi/blob/1b094148b91d737fb398bf1591604de58ec169e1/packages/coding-agent/src/experimental/durable/runtime.ts#L129)
uses the same ModelRuntime and authentication store. Durability does not
require a different OAuth protocol. That revision checks ID-token presence
without verifying its signature and claims; Loom validates them. Pi also
uses a static catalogue with a remote overlay, while Loom's operator command
queries account-visible models directly. These are source comparisons, not
live account tests.

## Test coverage and its limits

Focused native tests cover real signed identity fixtures, callback state and
Host binding, concurrent refresh, logout, bounded HTTP, CLI rendering, and
prepared cancellation custody. A native status check also runs in the bundled
release smoke.

Fixtures cannot show that an account is entitled to a model or that a live
login, Sol or Astra inference request, or subscription tool turn succeeds, so
model entitlement is never claimed from them. The [operator guide](../codex-subscription.md)
contains the native commands, the supported headless forwarding procedure,
and the end-to-end trial that checks those properties against a real account.
