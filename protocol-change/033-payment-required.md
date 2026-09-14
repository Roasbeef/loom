# protocol-change/033 — `PaymentRequired` and `PaymentDeclined`: a priced provider entry

**Status**: PROPOSED · **Date**: 2026-09-13 · **Affects**: Part 1.5, the
provider error vocabulary and the adapter request builder ·
**Raised by**: the loom-402 wave (provider seam)

## Problem

An L402 proxy answers an unpaid request with `402 Payment Required`. The
response carries a challenge: a macaroon and a BOLT11 invoice, either in
a JSON body or in a `WWW-Authenticate: L402 …` header beside
`X-Aperture-Challenge-Id`, `X-Aperture-Route-Id` and
`X-Aperture-Price-Sat`. Paying the invoice and retrying with
`Authorization: L402 <macaroon>:<preimage>` is what turns the 402 into a
response.

Loom cannot see that challenge today. All three adapters fold every
non-200 status into `stream.HttpError(status, api_error_type, message,
retry_after_ms)` and drop the response headers: `on_end` and `http_error`
in `adapter/openai.gleam:464`, `adapter/anthropic.gleam:641`, and
`adapter/gemini.gleam:716`. The headers are read only for a
`retry-after` hint and are not retained, so the macaroon and the invoice
are discarded at the point they arrive. `classify`
(`provider/retry.gleam:67`) then treats a 402 as terminal, which is
correct — a retry with the same credential buys nothing — and the
attempt ends with a message that says a status code and nothing about
price.

The result is that the one piece of information that could be acted on
never reaches anything that could act on it. There is no value in the
error vocabulary that a payment mechanism could be handed, so there is
nowhere to attach one.

## Accepted interface

Two variants are added to `provider/stream.ProviderError`, the spec §1.5
vocabulary:

```gleam
/// The provider answered 402 with an L402 challenge: the request is
/// priced and unpaid. Carries the challenge so a paywall can settle it.
PaymentRequired(challenge: l402.Challenge)

/// A paywalled attempt could not be settled: the paywall declined,
/// failed, or none is wired. `reason` is the paywall's own text.
PaymentDeclined(provider: String, reason: String)
```

`l402.Challenge` is a new pure record in `provider/l402`, holding the
macaroon and invoice verbatim, an optional amount in satoshis (from the
header or body price, else decoded from the invoice's human-readable
part), and the challenge and route identifiers when the proxy sent them.
`l402.parse` builds one from a response's headers and body; `l402.authorization`
renders the credential header value. Both are total and neither performs
I/O.

Three supporting shapes change with them.

`provider/model.Credential` replaces the `api_key: String` parameter of
each adapter's `build_request`. It has three variants: no credential, an
API key, and a settled L402 token. An API key is rendered where the
dialect already puts one; an L402 token always goes in `authorization`;
no credential sends no authentication header at all, which is how a
paywalled entry provokes its first challenge.

`gateway.Auth` replaces `ProviderConfig`'s `api_key_secret: String`
field. `ApiKey(secret_name)` is the existing behaviour under a name.
`L402` says the entry is unpaid until the proxy prices it.

`provider/paywall.Paywall` is the injected effect that turns a challenge
into a credential: `credential(provider)` returns the last settled token
for that provider if there is one, and `settle(provider, challenge)`
either returns a full authorization header value or a reason it did not.
`paywall.none()` is the default and declines everything.
`gateway.with_paywall` installs one, in the same pipeable style as the
other setters.

**One settle, one retry.** When an `L402` entry's attempt fails with
`PaymentRequired` — including beneath `WithContext` — the gateway checks
for a cancellation request, calls `settle` once, and on success runs the
same target exactly once more with the returned token. Whatever that
second attempt produces is the outcome. A second `PaymentRequired` is
delivered as it stands; there is no third attempt and no second payment
within one gateway attempt. A declining `settle` produces
`PaymentDeclined`.

**Both variants are terminal.** `classify` returns `Terminal` for each,
beneath `WithContext` as for every other variant. A priced request that
was not paid for does not become a retryable one by being asked again,
and the chain walk must not answer a payment failure by trying a
different entry (see Alternatives).

## Alternatives

**Parse the challenge in a transport wrapper.** A layer between the
adapters and `httpc` could recognise a 402, pay, and re-issue, leaving
the error vocabulary alone. It would sit below the gateway, where
cancellation is not observable and the attempt ordinal is not known, so
a payment would proceed after a stop was requested and the retry would
not appear in attempt accounting or in protocol 028's failure context.
The gateway is the layer that already owns both facts.

**Retry through the chain walk.** Treating `PaymentRequired` as
retryable would reuse the existing fallback machinery. The walk moves to
the *next entry*, so a settled payment would be spent against a
different target than the one that priced it, and a challenge issued by
one proxy would be answered at another's URL. Payment is a property of
one target, so it is resolved inside one attempt or not at all.

**Make the extension parse the raw 402.** The harness could deliver the
status, headers and body to a payment extension and let it find the
challenge. That puts an untyped header grammar — two scheme words, two
carriers, three vendor headers, an invoice encoding — into every
extension that wants to pay, and into every future one. Parsing it once,
totally, in a pure module the harness property-tests is the cheaper
place.

## Invariants and verification

The macaroon and the invoice never appear in a rendered error or a log
line. `describe` and `to_string` render `PaymentRequired` as its amount
and challenge identifier only, and `PaymentDeclined` as the provider and
the paywall's reason. The invoice is a payment instruction and the
macaroon is a bearer credential; neither is diagnostic, and both are long.

A settled L402 token is scrubbed exactly as an API key is. The gateway's
`scrub_attempt` redacts the secret string inside whichever `Credential`
variant an attempt used, so a proxy that reflects the `authorization`
header into an error body cannot return it to the operator.

Cancellation is honoured between the two attempts. The stop check runs
before `settle`, so a stop requested while the first attempt was in
flight prevents a payment rather than merely discarding what it bought.

A second 402 after a settlement is delivered, never paid again in the
same attempt. Payment happens at most once per gateway attempt, which
bounds what a misbehaving or compromised proxy can charge for a single
request regardless of how it answers.

A 402 whose challenge does not parse stays an `HttpError(402, …)`. An
unpaid keyed provider, or a proxy speaking a dialect this parser does
not know, keeps today's behaviour and today's classification.

Fixtures cover: a JSON-body challenge and a header challenge, under both
the `L402` and the older `LSAT` scheme word; the price taken from the
header and the price decoded from the invoice; a 402 with no parseable
challenge; a settle-then-succeed round trip asserting the second request
carries the credential; a declining paywall producing `PaymentDeclined`
without walking the chain; a second 402 after settlement; a reflected
token scrubbed from an error body; and both variants classifying
`Terminal`.

## What this does not decide

- **Where the credential cache lives.** `paywall.credential` is a
  function the gateway calls; whether the token behind it is held per
  session, per process, or durably is the paywall implementation's.
- **The hook that answers the challenge.** A `payment_required` hook on
  the extension bus is a separate proposal against Part 1.4, and is not
  needed for the seam.
- **Budget policy.** What ceiling a payment is held to, and who sets it,
  belongs to whatever settles; the gateway asserts none.
- **Multi-path payments and any other Lightning mechanics.** The gateway
  sees a challenge and a token and knows nothing of how one becomes the
  other.

## Cost

Every construction site of `ProviderConfig` names an `Auth` value
instead of a secret name, and every adapter's `build_request` takes a
`Credential`. Both are mechanical and compiler-checked. Error consumers
that enumerate `ProviderError` gain two arms; a consumer that classifies
rather than enumerates is unaffected. Nothing durable changes: neither
variant is stored, and no wire field is added.
