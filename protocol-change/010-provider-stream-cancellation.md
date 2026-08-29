# protocol-change/010 — provider stream cancellation

**Status**: ACCEPTED 2026-08-29 · **Affects**: Part 1.5 provider stream ·
**Raised by**: issue #131 (detached provider requests) · **Implemented**:
provider + runtime + client

## Problem

Part 1.5 gives a provider caller an event-only `StreamHandle`. A normal server
generation then crosses four ownership boundaries, some split into a guard and
worker so one crash cannot erase the other's cancel path:

```text
strand effect -> client relay -> gateway -> HTTP transport
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

Add two terminal provider errors and one cancellation capability:

```gleam
pub type ProviderError {
  ProviderCancelled
  CancellationUnconfirmed
  // Existing variants remain unchanged.
}

pub type StreamHandle {
  StreamHandle(
    events: Subject(StreamEvent),
    cancel: fn() -> Nil,
    owner: Option(Pid),
  )
}

pub fn cancel(handle: StreamHandle) -> Nil
pub fn await_stopped(handle: StreamHandle, within: Int) -> Bool
pub fn await_stopped_forever(handle: StreamHandle) -> Nil
```

`ProviderCancelled` means the provider request owner selected explicit
cancellation before a provider terminal. It is terminal under
`provider/retry.classify`; it can never advance a fallback chain. Its rendered
diagnostic is constant and contains no request, account, or credential data.

`CancellationUnconfirmed` means an outer ownership boundary requested
cancellation but the inner owner neither returned a terminal nor died within
the bounded grace period. It is also terminal: uncertainty about whether old
work stopped must never authorize new provider work. The distinct error keeps
the public result honest; only the request owner may claim that cancellation
won its race with settlement.

The closure is a capability to signal the owner, not permission for each layer
to invent an acknowledgement. `StreamHandle.owner = Some(pid)` is the drain
witness for every asynchronous descendant beneath that handle: it exits only
after that subtree stops. `None` is reserved for immediate fixtures with no
work to drain. A wrapper may synthesize only `CancellationUnconfirmed` after
its fixed grace expires or an in-band transport failure when its direct worker
crashes and the inner owner has drained. Repeated calls may send repeated
signals, but the first selected cancellation ends a healthy owner and makes
every later call harmless.

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

The production shim closes that acknowledgement gap without moving the
lifecycle into Erlang. A non-empty socket option gives each Loom request a
dedicated, non-reused `httpc` handler; the shim captures that handler through
public `httpc:info/0`, issues the cancellation cast, and waits for its Down.
The handler closes its socket during termination before that Down is delivered.
Raw tuple selection and this one OTP-specific wait remain in the shim; request,
fallback, timeout, and terminal state stay in Gleam.

## Ownership and race semantics

`provider/gateway.request` starts a public guard and a private pump for the
whole role walk. The guard owns the returned cancel endpoint, monitors its
direct consumer and the pump, and retains the latest `RunningRequest` published
by the pump. Every attempt gets a fresh HTTP subject. The guard can therefore
cancel and observe the live transport even if the pump crashes. Together they
select HTTP events, explicit cancellation, consumer death, transport death,
and the attempt timeout without making the long-running pump its own public
crash boundary.

The first selected terminal-class event decides the result:

- A provider settlement or terminal failure is forwarded once; later cancel is
  a no-op.
- Explicit cancellation cancels the active transport, emits exactly
  `Failed(ProviderCancelled)` when its owner acknowledges the race, and stops
  the route walk.
- If a cancellation crosses a wrapper or gateway guard but no owner-authored
  terminal arrives within the fixed grace period, that boundary emits exactly
  `Failed(CancellationUnconfirmed)` and stops. It does not retry or fall back.
- Consumer death cancels and reaps the active transport, emits nothing, and
  stops the route walk.
- Attempt timeout first cancels that transport. It returns the existing
  retryable timeout failure only after the transport owner exits; otherwise it
  returns terminal `CancellationUnconfirmed`.
- Transport death without its preceding terminal HTTP event becomes one
  in-band `TransportFailed` rather than a wait until timeout.
- Unexpected death of the runtime's provider effect is not translated into a
  retryable provider failure. Its reaper cancels the already-published stream
  owner, the driver restarts, and replacement recovery waits for that owner's
  complete drain.
- A retryable failure may advance to the next route entry only after checking
  the shared cancel endpoint again. Once cancellation is selected, no fallback
  can start.

The owner observes bounded transport-owner death after invoking cancel. A
transport owner that does not retire is not killed from above, because doing so
would erase the only acknowledgement that its native descendant stopped. The
boundary emits `CancellationUnconfirmed` and remains alive until the owner
eventually exits. The production transport custodian has already issued
`httpc:cancel_request/1` for the exact request id and retires its raw receiver
before it exits.

Any wrapper that constructs a new `StreamHandle` inherits the same obligation.
Its public guard monitors both the direct consumer and a private worker; the
worker is the inner stream's direct consumer and runs the observer. Explicit
cancellation or consumer death propagates to the inner handle. Worker death
becomes a prompt in-band transport failure only when inner drain is confirmed;
otherwise it becomes `CancellationUnconfirmed` and the guard stays alive as
the drain witness. A terminal observer still runs before the same terminal is forwarded;
in particular, the summary wrapper records a settled summary before the
runtime can ask for summary progress.

## Impact

- Every `StreamHandle` constructor supplies a cancel capability and declares
  whether it has an asynchronous owner. Scripted handles use `None` only when
  no external work exists; the starved simulation owner monitors its consumer.
- `provider/http.Transport` implementations return a monitorable
  `RunningRequest`. Fixture transports expose cancellation probes so tests can
  prove work stopped rather than merely prove a late result was ignored.
- `provider/gateway` owns cancellation, fallback, crash translation, and the
  one-terminal law through its guard-and-pump pair.
- `client/gateway.tap_provider` and `client/wiring.recording_summaries`
  propagate cancellation and consumer death inward.
- `runtime/strand_runtime` cancels a timed-out handle before reporting its
  terminal observation. Provider effects publish the handle owner to their
  incarnation reaper before consuming events and do not report `ProviderDone`
  until that owner drains. The reaper independently monitors both pids and
  thereby remains a transitive drain barrier if the effect dies first.
  Replacement recovery waits for all prior reapers in a dedicated drain
  ledger that precedes the restartable strand-name registry. The ledger's own
  death stops the session tree rather than erasing those barriers.
- Pure SSE parsing and provider adapter state machines do not change. Request
  headers and secrets remain below the provider seam.

No durable or network wire format changes. `ProviderCancelled`,
`CancellationUnconfirmed`, and the cancel capability are in-VM orchestration
vocabulary.

## Decision

**Accepted.** Encoding cancellation as
`TransportFailed("cancelled")` was rejected because transport failures are
retryable; that representation can start a fallback after an operator asked to
stop. Inferring cancellation from caller timeout was rejected because timeout
does not prove the work stopped. So was fabricating `ProviderCancelled` after
an acknowledgement timeout; that says the owner selected a result it never
sent. Linking all processes was rejected because a provider or transport
failure is an application result that must settle in band, not a reason to
crash a strand.

The extra monitorable transport owner is the minimum boundary that can retain
the real request id, distinguish death from completion, and cancel future
Responses or subscription-backed transports without exposing their
credentials. The gateway pump remains the provider-neutral fallback owner; no
HTTP proxy, adapter I/O, or provider-specific option bag is introduced.
