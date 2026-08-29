# protocol-change/010 — provider stream cancellation

**Status**: ACCEPTED 2026-08-29 · **Affects**: Part 1.5 provider stream ·
**Raised by**: issue #131 (detached provider requests) · **Implemented**:
provider + runtime + client

## Problem

Part 1.5 gives a provider caller an event-only `StreamHandle`. A normal server
generation then crosses four local processes:

```text
strand effect -> client relay -> gateway pump -> HTTP request owner
```

Each process has a real job, but none of the outer three could stop the next
one. A timeout only stopped receiving. A killed strand effect left the relay,
fallback pump, and OTP `httpc` request running until their independent
timeouts. Recovery could start another billable request while the orphan from
the prior incarnation still consumed a socket and provider quota.

Ignoring a late settlement protects durable state. It does not stop external
work. The provider request needs an explicit cancellation fact and one owner
that decides its race with settlement.

## Proposal

Add one terminal provider error and one cancellation capability:

```gleam
pub type ProviderError {
  ProviderCancelled
  // Existing variants remain unchanged.
}

pub type StreamHandle {
  StreamHandle(
    events: Subject(StreamEvent),
    cancel: fn() -> Nil,
  )
}

pub fn cancel(handle: StreamHandle) -> Nil
```

`ProviderCancelled` means the provider request owner selected explicit
cancellation before a provider terminal. It is terminal under
`provider/retry.classify`; it can never advance a fallback chain. Its rendered
diagnostic is constant and contains no request, account, or credential data.

The closure is a capability to signal the owner, not permission for each layer
to invent a result. The owner is the only terminal sender. Repeated calls may
send repeated signals, but the first selected cancellation ends the owner and
makes every later call harmless.

The provider-neutral transport seam also separates startup from completion:

```gleam
pub type RunningRequest {
  RunningRequest(owner: Pid, cancel: fn() -> Nil)
}

pub type Transport {
  Transport(
    start_streaming: fn(
      HttpRequest,
      Subject(HttpEvent),
    ) -> Result(RunningRequest, String),
  )
}
```

`RunningRequest.owner` is monitorable and is the sole sender of that attempt's
HTTP events. The cancellation closure stops the transport-native request. The
production owner retains the exact OTP request id returned by
`httpc:request/4`; cancellation invokes `httpc:cancel_request/1` before the
local owner exits. Startup failures surface as one redacted `RequestFailed`,
never as a secret-bearing exception string.

OTP 27's contract matters here. `httpc:cancel_request/1` targets the default
profile used by Loom's `httpc:request/4` call, returns `ok`, and is asynchronous.
It explicitly does not guarantee that a response already in flight will not be
delivered. Therefore cancellation of the socket and selection of the public
terminal are separate facts: late HTTP messages are confined to the cancelled
attempt's private subject and cannot produce another `StreamEvent` terminal.
If Loom later uses `httpc:request/5` with a non-default profile, the owner must
retain that profile and use `httpc:cancel_request/2`.

## Ownership and race semantics

`provider/gateway.request` starts one owner for the whole role walk. That owner
creates the cancel endpoint, monitors its direct consumer, and retains the
current `RunningRequest`. Every attempt gets a fresh HTTP subject. It selects
HTTP events, explicit cancellation, consumer death, transport death, and the
attempt timeout in one loop.

The first selected terminal-class event decides the result:

- A provider settlement or terminal failure is forwarded once; later cancel is
  a no-op.
- Explicit cancellation cancels and reaps the active transport, emits exactly
  `Failed(ProviderCancelled)` to a live consumer, and stops the route walk.
- Consumer death cancels and reaps the active transport, emits nothing, and
  stops the route walk.
- Attempt timeout first cancels and reaps that transport, then returns the
  existing retryable timeout failure to the fallback policy.
- Transport death without its preceding terminal HTTP event becomes one
  in-band `TransportFailed` rather than a wait until timeout.
- A retryable failure may advance to the next route entry only after checking
  the shared cancel endpoint again. Once cancellation is selected, no fallback
  can start.

The owner observes bounded transport-owner death after invoking cancel. A
transport owner that does not retire is killed locally after the grace period;
for production, the cancellation closure has already issued
`httpc:cancel_request/1` for the exact request id before that fallback.

Any wrapper that constructs a new `StreamHandle` inherits the same obligation.
It monitors its direct consumer and propagates explicit cancellation or
consumer death to the inner handle. A terminal observer still runs before the
same terminal is forwarded; in particular, the summary wrapper records a
settled summary before the runtime can ask for summary progress.

## Impact

- Every `StreamHandle` constructor supplies a cancel capability. Scripted and
  simulation handles use a harmless no-op only when no external work exists.
- `provider/http.Transport` implementations return a monitorable
  `RunningRequest`. Fixture transports expose cancellation probes so tests can
  prove work stopped rather than merely prove a late result was ignored.
- `provider/gateway` owns cancellation, fallback, and the one-terminal law.
- `client/gateway.tap_provider` and `client/wiring.recording_summaries`
  propagate cancellation and consumer death inward.
- `runtime/strand_runtime` cancels a timed-out handle before reporting its
  terminal observation. Reaper-driven effect death is covered independently by
  the monitor chain.
- Pure SSE parsing and provider adapter state machines do not change. Request
  headers and secrets remain below the provider seam.

No durable or network wire format changes. `ProviderCancelled` and the cancel
capability are in-VM orchestration vocabulary.

## Decision

**Accepted.** Encoding cancellation as
`TransportFailed("cancelled")` was rejected because transport failures are
retryable; that representation can start a fallback after an operator asked to
stop. Inferring cancellation from caller timeout was rejected because timeout
does not prove the work stopped. Linking all processes was rejected because a
provider or transport failure is an application result that must settle in
band, not a reason to crash a strand.

The extra monitorable transport owner is the minimum boundary that can retain
the real request id, distinguish death from completion, and cancel future
Responses or subscription-backed transports without exposing their
credentials. The gateway pump remains the provider-neutral fallback owner; no
HTTP proxy, adapter I/O, or provider-specific option bag is introduced.
