# protocol-change/028: provider failure context

Status: accepted under the owner delegation in `docs/execution.md` section 7,
after the independent September 10 critique. Affects the provider error
vocabulary in spec Part 1.5.
The stream still emits deltas followed by exactly one terminal result.

## Problem

Cancellation can begin at an attempt deadline, an explicit stop, a consumer
exit, or an enclosing relay deadline. Several of those paths currently produce
the same `CancellationUnconfirmed` value. The error proves only that cleanup
was not confirmed within the caller's bound. It does not prove a provider
outage. The reviewed session lost the initiating event and then stored an
unsupported provider-drop diagnosis in memory.

## Accepted interface

Add one wrapper to `provider/stream.ProviderError`:

```gleam
WithContext(error: ProviderError, context: FailureContext)
```

`FailureContext` contains a closed source (attempt, gateway, relay, runtime),
a closed initiating event (explicit stop, deadline, consumer exit, terminal
response, or transport exit), a separate cancellation-requested event when
upstream intent is unknown, the local attempt ordinal when known,
the configured request and cancellation bounds, and an optional request
identity. These are local facts. It contains no URL, request body, headers,
credentials, reasoning, or workspace text. Unknown values remain absent.

The wrapper preserves the underlying error. Retry classification unwraps it,
so cancellation and lost drain proof remain terminal; HTTP 429 retains its
existing backoff hint. One normalized envelope retains at most four local
observations, one per
boundary. Attempt cancellation outcomes carry their observation before the
gateway forms a public error. Cancellation-sensitive consumers classify the
underlying error before choosing the bounded terminal path. Composition retains bounded context from the layers
which observed the event, rather than replacing an initiating cause with the
last cleanup timeout. The runtime copies this data into the existing optional
`AssistantMessage.diagnostics` JSON field for durable inspection. Ordinary
error text remains readable, and the UI distinguishes cancellation, uncertain
cleanup, rate limiting, and terminal failure.

## Alternatives

Logging only leaves the session database unable to explain its own failure.
Encoding context into a transport-error string changes retry classification
or forces downstream readers to parse prose. Adding fields to every existing
error variant creates more churn than a wrapper and still needs the same
normalization boundary. A new stream event would alter terminal ordering and
require every consumer to handle another event class.

## Invariants and verification

The original custodian remains the only drain witness. This proposal does
not permit retry or replacement while cleanup is unproven, does not turn an
abnormal owner exit into a successful drain, and does not lengthen deadlines.
Fixtures must cover a deadline followed by a stuck transport, explicit cancel,
late transport retirement, consumer loss, retryable 429 with backoff, terminal
redaction, and the persisted diagnostic shown to the operator. Existing
cancellation race and transitive-custody tests remain in force.

## Cost

Error consumers must unwrap context for classification and cancellation-race
handling. A bounded diagnostic accompanies a failed response; successful
streams and the persisted conversation codec need no new wire field. Older
recordings without diagnostics remain readable and explicitly lack a cause.
