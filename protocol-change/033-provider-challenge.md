# protocol-change/033 — `Challenged` and `ChallengeUnanswered`: an extension answers a provider's authentication challenge

**Status**: PROPOSED · **Date**: 2026-09-13 · **Affects**: Part 1.5, the
provider error vocabulary and the adapter request builder ·
**Raised by**: the loom-402 wave (provider seam)

## Problem

Some providers answer a request with an HTTP authentication challenge
rather than a response. The three statuses HTTP defines for this are
401, 402 and 407. A challenge says what the client must present to be
served, and the grammar in which it says so belongs to whatever scheme
the provider speaks.

Loom cannot see such a challenge today. All three adapters fold every
non-200 status into `stream.HttpError(status, api_error_type, message,
retry_after_ms)` and drop the response headers; the headers are read
only for a `retry-after` hint and are not retained. `classify` then
treats a 402 as terminal, which is correct — a retry with the same
credential buys nothing — and the attempt ends with a message that says
a status code and nothing else.

So the one piece of information that could be acted on never reaches
anything that could act on it. There is no value in the error vocabulary
that a credential-producing mechanism could be handed, and so nowhere to
attach one.

## Accepted interface

Two variants are added to `provider/stream.ProviderError`, the spec §1.5
vocabulary:

```gleam
/// The provider answered an HTTP authentication challenge (401, 402 or
/// 407) that an extension may be able to satisfy. Carries the raw
/// status, the response headers (lowercase names) and the body, bounded
/// to 65,536 bytes. Nothing here interprets the challenge.
Challenged(status: Int, headers: List(#(String, String)), body: String)

/// A challenged attempt could not be answered: no challenger is wired,
/// no extension answered, or the one that did declined with `reason`.
ChallengeUnanswered(provider: String, reason: String)
```

Three supporting shapes change with them.

`provider/model.Credential` replaces the `api_key: String` parameter of
each adapter's `build_request`. It has three variants: `NoCredential`,
`ApiKeyCredential(key)`, and `ExtensionCredential(headers)` — the
headers an extension answered a challenge with. An API key is rendered
where the dialect already puts one. Extension headers are appended after
the adapter's own, except that a header named `content-type`,
`content-length`, `host` or `accept` is dropped, because the adapter
owns those four and a provider must not be able to rewrite the request
body's framing through a challenge. No credential sends no
authentication header at all, which is how a challenged entry provokes
its first challenge.

`gateway.Auth` replaces `ProviderConfig`'s `api_key_secret: String`
field. `ApiKey(secret_name)` is the existing behaviour under a name.
`Extension` says the entry carries no operator credential and is
expected to be challenged.

`provider/challenger.Challenger` is the injected effect that supplies
headers, with one function for each of the two moments. `headers(provider,
model_id)` is consulted **before every attempt** on an `Extension` entry
and returns the headers to send, or `None` to send none — which is how an
unauthenticated request provokes the endpoint into stating its terms.
`answer(provider, challenge)` runs only after a challenge has arrived and
either returns the headers to retry with or a reason it did not.
`challenger.none()` is the default: it supplies no headers and declines
everything. `gateway.with_challenger` installs one, in the same pipeable
style as the other setters.

**The harness caches nothing.** Whatever `headers` answers is what is
sent, and a provider asked twice is asked of the challenger twice; the
gateway does not retain what `answer` returned, either. Whoever satisfies
a challenge is the only party that knows what it bought, for which entry
and model, and when it stops being worth anything, so a copy kept here
could only guess at all three and would go on presenting a dead
credential after the answerer had replaced it. The `model_id` rides on
`headers` for the same reason one step down: a proxy that prices per
model hands out a credential per model.

**Adapters map three statuses and nothing else.** On 401, 402 or 407 the
response settles as `Failed(Challenged(status, headers, body))`
regardless of the body's shape; every other non-200 stays `HttpError` as
it is today. `describe_error` for `Challenged` renders the status alone
("provider challenged the request with http 402") and never a header or
the body.

**One answer, one retry.** When an `Extension` entry's attempt fails
with `Challenged` — including beneath `WithContext` — the gateway checks
for a cancellation request, calls `answer` once, and on success runs the
same target exactly once more with `ExtensionCredential(headers)`.
Whatever that second attempt produces is the outcome. A second
`Challenged` is delivered as it stands; there is no third attempt and no
second answer within one gateway attempt. A declining `answer` produces
`ChallengeUnanswered`. For an `ApiKey` entry a `Challenged` is delivered
as it stands, unanswered.

**Both variants are terminal.** `classify` returns `Terminal` for each,
beneath `WithContext` as for every other variant. A request that was
challenged and not satisfied does not become a retryable one by being
asked again, and the chain walk must not answer a challenge by trying a
different entry (see Alternatives).

## Why the harness parses nothing

A challenge grammar belongs to whoever can satisfy it. The harness
cannot satisfy any of them: it holds no wallet, no token vendor and no
second-factor device, so a parser in the harness would exist only to
hand a decoded shape to the party that was going to read the raw bytes
anyway.

What the harness does know is HTTP's three authentication statuses. That
is the whole of its knowledge, and it is enough to decide the one thing
the harness owns: that this attempt may be worth retrying with different
headers, once, if something can supply them. Everything below that —
which scheme word, which carrier, what a price means, what a token costs
— is the extension's.

The payoff is that a new scheme needs no harness change. L402 is the
scheme the first extension speaks; MPP, or a bearer-token vending
machine, or an enterprise SSO exchange, is another extension answering
the same hook with different headers. `loom-402` holds the whole of
L402 — the scheme words, the macaroon, the invoice, the amount decoder
and the `authorization` header it composes — inside the extension,
exactly as pi-402 does.

## Compared with pi's paying fetch

pi solves the same problem by letting an extension wrap the fetch itself:
the extension sees every outgoing request, attaches whatever credential
it holds, and on a 402 pays and re-issues. The token store is the
extension's, kept durably in its own state, which is why a bought bundle
survives a restart of the host process.

Loom replicates that shape with two hooks around the harness's own
request rather than by handing the request over. `provider_request` is
the pre-request half — it is what `Challenger.headers` is wired to, and
it is where an extension presents a credential it already holds.
`provider_challenge` is the post-challenge half. Together they are
middleware in the same position pi's wrapper occupies, and the durable
store stays on the same side of the boundary: the extension keeps its
credential in its own `ext/memory` cell, so a bought bundle survives a
daemon restart.

The one deliberate difference is that the request body never crosses
either hook. pi's wrapper sees the whole request because it *is* the
fetch; Loom's hooks are told which provider and model are about to be
asked and when, and nothing more. Reading a conversation is the
separately approved `context` capability, and paying for a request is not
a reason to be granted it.

## Alternatives

**Parse the challenge in a transport wrapper.** A layer between the
adapters and `httpc` could recognise a challenge, satisfy it, and
re-issue, leaving the error vocabulary alone. It would sit below the
gateway, where cancellation is not observable and the attempt ordinal is
not known, so the answer would proceed after a stop was requested and
the retry would not appear in attempt accounting or in protocol 028's
failure context. The gateway is the layer that already owns both facts.

**Retry through the chain walk.** Treating `Challenged` as retryable
would reuse the existing fallback machinery. The walk moves to the *next
entry*, so headers bought against one target would be spent at another's
URL. A challenge is a property of one target, so it is resolved inside
one attempt or not at all.

**Parse the challenge in the harness.** The earlier draft of this
proposal decoded an L402 challenge in a pure `provider/l402` module and
handed the extension an invoice. That puts one scheme's grammar into the
harness permanently, and the next scheme puts a second one there. It
also splits the credential across two parties — the harness composing a
header out of a secret the extension returned — which buys nothing: an
extension that can be trusted to spend money can be trusted to write the
header it paid for.

## Invariants and verification

The challenge body and headers never appear in a rendered error or a log
line. `describe` and `to_string` render `Challenged` as its status, and
`ChallengeUnanswered` as the provider and the extension's reason. A
challenge is attacker-influenced text and is not diagnostic.

Every value in an `ExtensionCredential` is scrubbed. The gateway's
`scrub_attempt` redacts the API key inside `ApiKeyCredential` and each
header *value* inside `ExtensionCredential`, so a provider that reflects
an `authorization` header into an error body cannot return it to the
operator.

Cancellation is honoured between the two attempts. The stop check runs
before `answer`, so a stop requested while the first attempt was in
flight prevents the extension from acting rather than merely discarding
what it produced.

A second challenge after an answer is delivered, never answered again in
the same attempt. An extension is asked at most once per gateway
attempt, which bounds what a misbehaving or compromised provider can
extract for a single request.

The four adapter-owned header names are dropped from an extension's
answer. A provider cannot use a challenge to make the retry carry a
different `content-type` or a different `host` than the adapter built.

Fixtures cover: each of 401, 402 and 407 settling as `Challenged`; a
403 and a 500 still settling as `HttpError`; a body over 65,536 bytes
truncated; an answer-then-succeed round trip asserting the second request
carries the answered headers; an extension header named `content-type`
dropped and the adapter's kept; a declining challenger producing
`ChallengeUnanswered` without walking the chain; a second challenge after
an answer; a reflected header value scrubbed from an error body; and both
variants classifying `Terminal`.

## What this does not decide

- **Where the answered headers are kept.** That they are not kept *here*
  is decided; where they are kept instead is the answerer's. The
  reference extension holds them in a durable `ext/memory` cell, which is
  what makes a bought credential outlive a daemon restart, but the
  gateway sees only what `headers` answers on each call.
- **The hooks behind the two functions.** That `headers` is `provider_request`
  and `answer` is `provider_challenge` on the extension bus is a separate
  proposal against Part 1.4; neither is needed for the seam, which is
  satisfied by any `Challenger`.
- **Any policy about what an answer may cost.** The harness knows no
  price, because it parses no challenge; what ceiling an extension holds
  itself to, and who sets it, is entirely the extension's.
- **Which schemes exist.** The gateway sees a status, a set of headers, a
  body and a set of headers back. It knows nothing about how one becomes
  the other.

## Cost

Every construction site of `ProviderConfig` names an `Auth` value instead
of a secret name, and every adapter's `build_request` takes a
`Credential`. Both are mechanical and compiler-checked. Error consumers
that enumerate `ProviderError` gain two arms; a consumer that classifies
rather than enumerates is unaffected. Nothing durable changes: neither
variant is stored, and no wire field is added.
