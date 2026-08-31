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

Add three terminal provider errors and one cancellation capability:

```gleam
pub type ProviderError {
  ProviderCancelled
  CancellationUnconfirmed
  DrainProofLost
  // Existing variants remain unchanged.
}

pub type DrainOutcome {
  Drained
  TimedOut
  ProofLost
}

pub type StreamHandle {
  StreamHandle(
    events: Subject(StreamEvent),
    cancel: fn() -> Nil,
    owner: Option(Pid),
  )
}

pub fn cancel(handle: StreamHandle) -> Nil
pub fn watch_drain(handle: StreamHandle) -> DrainWitness
pub fn await_drain(witness: DrainWitness, within: Int) -> DrainOutcome
pub fn await_drain_forever(witness: DrainWitness) -> DrainOutcome
pub fn await_stopped(handle: StreamHandle, within: Int) -> DrainOutcome
pub fn await_stopped_forever(handle: StreamHandle) -> DrainOutcome
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

`DrainProofLost` means an owner exited abnormally. Death alone is not enough:
the owner may have abandoned a process or socket beneath it. It is terminal
and never authorizes retry. Callers which need this distinction register a
`DrainWitness` before `begin`; a monitor installed after exit sees only
`noproc` and cannot reconstruct the original reason.

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

pub type PreparedRequest {
  PreparedRequest(running: RunningRequest, begin: fn() -> Nil)
}

pub type Transport {
  Transport(
    prepare_streaming: fn(
      HttpRequest,
      Subject(HttpEvent),
    ) -> Result(PreparedRequest, String),
  )
}
```

Composition adds one in-VM preparation envelope without changing the public
`gateway.request` facade:

```gleam
pub type PreparedStream {
  PreparedStream(handle: StreamHandle, begin: fn() -> Nil)
}

pub type ProviderSurface {
  ProviderSurface(request: fn(RequestSpec) -> StreamHandle, timeout_ms: Int)
  PreparedProviderSurface(
    request: fn(RequestSpec) -> StreamHandle,
    prepare: fn(RequestSpec) -> PreparedStream,
    timeout_ms: Int,
  )
}
```

`PreparedProviderSurface` is the production representation. The immediate
variant remains for local fixtures which own no external work; a fixture may
still use a self-reaping in-memory owner to model cancellation. A wrapper
prepares its child, publishes `handle.owner`, and only then invokes `begin`.
The ordinary `request` function performs those steps synchronously for callers
which do not participate in an outer ownership protocol.

`prepare_streaming` creates the monitorable owner without admitting network
work. The caller publishes `RunningRequest.owner`, installs its monitor, and
only then invokes `begin`. The cancellation closure stops the transport-native
request and is valid before begin. The production native owner retains the
exact OTP request id returned by `httpc:request/4`; cancellation addresses that
handler directly and awaits its Down before the owner exits. Startup failures
surface as one redacted `RequestFailed`, never as a secret-bearing exception
string.

OTP's public cancellation contract is asynchronous and routes through the
currently registered manager. It explicitly does not guarantee that a response
already in flight will not be delivered. Loom therefore confines one internal
OTP dependency to the native owner: the default manager's protected handler
table maps the exact request id to its handler PID. The manager inserts that
row before replying to successful admission. Loom forces a dedicated handler
and request-local `max_connections_open = infinity`, so the request cannot be
queued without a handler row. One O(1) lookup captures and monitors that PID;
no process scan or diagnostic call is involved. The owner then invokes
`httpc_handler:cancel/2` and awaits that original monitor. Manager or handler-
supervisor replacement cannot retarget a PID already captured. Late HTTP
messages remain confined to the cancelled attempt's private subject.

The production shim closes that acknowledgement gap without moving provider
policy into Erlang. It first allocates one parked native owner, which is both
the raw `httpc` receiver and the monitorable drain witness. Only after Gleam
publishes that PID does `begin_stream_request` admit work. A non-empty socket
option gives the request a dedicated, non-reused handler and disables manager
queueing for this request. The owner reads the published request row directly,
monitors its handler, issues cancellation to that PID, and waits for Down. The
handler closes its socket during termination before that signal is delivered.
Missing mapping after successful admission is loss of proof, so the owner
requests conservative public cancellation and exits abnormally rather than
inventing drain. If the public call loses its reply while the manager or handler-
supervisor generation changes, the owner retains the ambiguous admission until
a raw response reveals the request id. Redirects are disabled because they
retain a request id while moving work to another handler. Automatic Retry-After
retries are also disabled where the running OTP version supports that option;
older supported releases predate it. Raw tuple selection, request preparation,
admission, exact lookup, and the OTP-specific drain wait are the whole shim;
request, fallback, timeout, redaction, and terminal state stay in Gleam. The
request deadline is computed once, so recursive receives and cancellation
cannot restart its 300-second budget. Exceptions are normalized only before
admission; an unexpected post-admission fault remains an abnormal owner exit.

## Ownership and race semantics

`provider/gateway.prepare` first returns a minimal parked custodian; its caller
publishes that owner and only then grants the begin permit which releases a
guard and private pump for the whole role walk. The synchronous
`provider/gateway.request` facade performs those two steps back to back. The custodian performs no
provider or transport work. It monitors the direct consumer and adopts the
guard, pump, and every `RunningRequest` before each is permitted to begin. The
guard retains the latest attempt published by the pump, and every attempt gets
a fresh HTTP subject. A guard or pump crash can therefore trigger cancellation
without turning that worker's Down into a false drain acknowledgement.
Together the workers select HTTP events, explicit cancellation, consumer
death, transport death, and the attempt timeout; only the custodian's Down
acknowledges that the complete registered subtree is gone.

The custodian distinguishes leaf processes from transitive owners. A leaf owns
nothing beneath itself, so its own Down completes that obligation regardless
of reason; the supervising worker still translates any crash. A transitive
owner speaks for descendants, so only `Normal` proves drain. Beginning
cancellation never weakens that rule: an abnormal transitive Down poisons the
custodian even after its cancel callback has run. Cancellation helpers are
monitored separately and cannot launder the child's exit reason.

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
  in-band `TransportFailed` only when its original monitor reports `Normal`.
  An abnormal Down becomes terminal `DrainProofLost` and cannot fall back.
- Unexpected death of the runtime's provider effect is not translated into a
  retryable provider failure. Its reaper cancels the already-published stream
  owner, the driver restarts, and replacement recovery waits for that owner's
  complete drain.
- A runtime abort keeps its driver alive and spends the acknowledgement grace,
  because a real terminal with billable usage may already be queued. Driver
  death has no terminal consumer: the provider effect requests cancellation
  and exits, while the reaper's independent owner monitor retains the drain
  barrier.
- A retryable failure may advance to the next route entry only after checking
  the shared cancel endpoint again. Once cancellation is selected, no fallback
  can start.

The terminal-arbitrating worker waits only a bounded grace after invoking
cancel. A transport owner that does not retire is not killed from above,
because doing so would erase the only acknowledgement that its native
descendant stopped. The boundary emits `CancellationUnconfirmed`, while its
custodian remains alive until the owner eventually exits. The production
transport owner has already issued `httpc:cancel_request/1` for the exact
request id and waits for the dedicated handler before it exits.

Any wrapper that constructs a new `StreamHandle` inherits the same obligation.
Its prepared surface publishes a minimal custodian before releasing its guard.
The guard remains the inner stream's direct consumer, while a separate observer
process runs the synchronous callback; the custodian adopts both processes and
the inner handle before their work begins. Explicit cancellation or consumer death
propagates to the inner handle. Guard or observer death becomes a prompt
in-band transport failure only when inner drain is confirmed; otherwise it
becomes `CancellationUnconfirmed` and the custodian stays alive as the drain
witness. A terminal observer still runs before the same terminal is forwarded;
in particular, the summary wrapper records a settled or cancelled attempt
before the runtime can ask for summary progress.

## Impact

- Every `StreamHandle` constructor supplies a cancel capability and declares
  whether it has an asynchronous owner. Scripted handles use `None` only when
  no external work exists; the starved simulation owner monitors its consumer.
- `provider/http.Transport` implementations return a monitorable
  `RunningRequest`. Fixture transports expose cancellation probes so tests can
  prove work stopped rather than merely prove a late result was ignored.
- `provider/gateway` owns cancellation, fallback, crash translation, and the
  one-terminal law through its custodian, guard, and pump.
- `client/gateway.tap_provider` and `client/wiring.recording_summaries`
  propagate cancellation and consumer death inward.
- `runtime/strand_runtime` creates a parked provider worker inside a public
  custodian, publishes the custodian to the incarnation reaper, and only then
  permits the worker to call the frozen provider surface. A timed-out effect
  cancels and observes its handle before reporting a terminal. It does not
  report `ProviderDone` until that owner drains. The reaper independently
  monitors both pids and thereby remains a transitive drain barrier if the
  effect dies first. The parked worker is linked to its effect: an unexpected
  provider-surface crash still faults the operation and enters recovery, while
  the unlinked custodian survives to drain any adopted descendants.
  Replacement recovery waits for all prior reapers in a
  dedicated drain ledger that precedes the restartable strand-name registry.
  During session close that ledger traps the root's shutdown and remains until
  every registered reaper exits, so the writer lease cannot be released beside
  live provider work. `SessionTree` retains the ledger's name separately, so
  `api.close` also awaits it when an abnormal root death happened before close
  began. The ledger's own unexpected death stops the session tree rather than
  erasing those barriers.
- Pure SSE parsing and provider adapter state machines do not change. Request
  headers and secrets remain below the provider seam.

No durable or network wire format changes. `ProviderCancelled`,
`CancellationUnconfirmed`, `DrainProofLost`, the drain witness, and the cancel
capability are in-VM orchestration vocabulary.

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
