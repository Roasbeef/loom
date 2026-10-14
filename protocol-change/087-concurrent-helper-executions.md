# protocol-change/087 — address concurrent helper executions

**Status**: PROPOSED 2026-10-13 · **Affects**: Part 1.4 exec channel and pool
capacity · **Raised by**: concurrent native helper implementation ·
**Implemented for review**: broker + sandbox

## Problem

The current helper owns one execution. `cancel.body` is empty and
`exec_stdin.body` contains only data and EOF, so neither can identify a sibling
execution. Output and exit already echo their execution-start ID. Reusing one
Go runtime for several jails therefore requires explicit control targets and
bounded admission, not only concurrent goroutines.

The idle-retirement measurements found approximately 40 MiB of summed RSS for
four used native helpers. This motivates measuring shared runtime overhead;
it does not establish how much a multiplexed helper saves. Multiplexing also
increases the failure domain: killing one unhealthy helper affects its siblings.

## Proposal

Keep envelope `v = 1`; advance exec-channel `hello.proto` from 3 to 4:

```text
hello.body = {proto: 4, peer: "exec-helper", features: [...],
              max_concurrency: integer in [1, 4]}
exec_stdin.body = {exec_id: positive u64, data: binary, eof: bool}
cancel.body = {exec_id: positive u64}
shutdown.body = {}
```

The native helper advertises four execution slots. The broker may use fewer.
The target `exec_id` is the original `exec_start` envelope ID. Stdin and cancel
retain fresh envelope request IDs: a refused control request must not masquerade
as an execution's terminal refusal. Output and exit keep their existing
start-ID correlation. Duplicate execution-start IDs cannot replace active work.
Cancellation of an unknown or completed positive target is an idempotent no-op.
Invalid or missing target IDs are refused, never interpreted as cancel-all.

Capacity is required on protocol-4 exec-helper hello. Older hello bodies remain
decodable without that field so handshake failure can name both incompatible
versions. Non-exec peers may omit capacity. Empty cancellation on capability
channels keeps its existing meaning; the version-4 native exec channel requires
an execution target. A helper built at protocol 3 cannot be used through fallback.

## Ownership and race semantics

One BEAM owner and one Go helper own at most four concurrent executions. The
broker records a checkout-specific opaque lease before replying to checkout.
Only a valid, unused lease can start work. Returning the lease revokes it;
stale handles and duplicate checkins cannot dispatch new work, release another
borrower's capacity or cancel a later execution. Direct unpooled helper handles
retain singleton sequential behavior.

Each native helper reserves a quota from the existing configured execution
ceiling. The sum of all quotas, including draining and unconfirmed helpers,
cannot exceed `LOOM_HELPER_POOL`. Packing several slots into one native process
does not multiply the allowed number of simultaneous jails. Pool census
availability counts describe physical entries; `size` remains the execution
ceiling. Native starting, live, cleanup and reporting entries all occupy the announced
capacity. The native helper reserves its entry before launching the execution
worker, so overlapping startup cannot exceed that bound. Each execution owns
its output, enforcement expectations and named
cancel-escalation timer. Sibling traffic cannot reset that timer.

Idle retirement begins only when the last checkout lease returns. A partially
occupied native helper is borrowed, even when it can accept additional leases.
Physical retirement still requires native exit and the original owner's normal
monitor event. Failed retirement holds the entire reserved quota.

A corrupt channel, failed write, heartbeat failure, native death or cancel
escalation withdraws the physical helper and settles every accepted execution
exactly once. No lost effect is automatically replayed. Shutdown and EOF stop
admission, cancel all remaining executions, join their terminal writes and
native cleanup, then exit. Neither an individual `exec_exit` nor a closed port
replaces the native retirement witness. Platform containment limits remain
unchanged.

## Stdin and output bounds

Stdin queue admission must be bounded and nonblocking. The existing per-execution
16-MiB pending bound remains; an overflowing chunk is refused under its control
request ID and cancels only that target execution. Cancellation prevents a
silently truncated input stream from later being reported as successful work.
No unbounded goroutine or queue may be allocated for each incoming frame. FIFO
and EOF ordering remain per execution. Before startup finishes, the helper may
coalesce input into one lazy buffer under the same 16-MiB byte limit. It
transfers those bytes and EOF before admitting later input to the running jail.
Early cancellation is retained until startup settles; shutdown joins starting
entries as well as running jails and terminal writes. One nonreading child must not prevent
the frame loop from handling sibling cancellation, heartbeat or shutdown.

Output frames share the transport and remain serialized at frame boundaries.
Per-execution output limits remain independent. Transport failure is a shared
failure, with the bounded four-execution blast radius described above; this
proposal does not promise independent progress through a broken shared pipe.

## Alternatives considered

Keeping one execution per native process preserves the smallest failure domain,
but duplicates Go runtime memory and threads. It remains the comparison baseline.
A daemon-wide pool was rejected because it would cross session policy and
retirement custody boundaries. Separate logical helper actors over a transport
hub were considered; they still need shared physical escalation and cleanup
coordination, so they add machinery without removing the execution registry.
Unbounded native concurrency was rejected because it would amplify resource
limits and make shutdown and queued input harder to bound.

## Impact and validation

Both native helper and broker must be rebuilt together. No durable conversation
schema, capability token binding or policy widening is introduced. The pool's
public run/cancel/stdin signatures remain available through opaque leased
handles; internal state and census interpretation change as described above.

Acceptance requires actual overlapping native executions, independent output
and stdin routing, target-only cancellation, duplicate/unknown-ID refusal,
stale-lease fencing, unchanged aggregate execution capacity, stdin backpressure
isolation, shared failure settlement, per-execution cancellation deadlines,
shutdown joining every jail, and idle retirement only after all leases return.
Go race tests, full repository tests, independent lifecycle review and matched
memory/latency measurements must pass before publication. Measurements must
compare complete protocol-matched baseline and candidate stacks in separate
VMs and distinguish native helpers from their payload descendants.
