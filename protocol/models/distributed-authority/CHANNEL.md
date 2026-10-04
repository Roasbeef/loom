# Channel custody boundary

The owner and executor each send three ordered items, with sizes 1, 2 and 1.
There is one pending data credit per direction. The final inbound item carries
the configured Outcome or HookResult equality class. A quota of four permits
the complete sequence; three exercises cumulative exhaustion. Every source
item satisfies the frame bound of two scaled byte units.

`admitted` retains the independent item history; `usedBytes` is the mutable
counter checked by admission. `LifetimeBytesBound` sums the retained history,
so removing the cumulative admission check cannot conceal an excess. Neither
sequence numbers nor these equality classes are durable execution identities.
The model generates an ordered source sequence; hostile wire decoders and
cryptographic equality remain implementation tests.

Transport drainage appends to `consumer`, which has no one-item admission guard.
Only the pending credit establishes `ConsumerBound`. Final consumption removes
that item and places its exact sequence number in a separate ACK slot. ACK
delivery checks the consumed history, then releases its original credit.
Neither ACK admission nor consumption requires reverse-direction data credit.
The algorithm permits inbound consumption when outbound credit is busy.

Timeout closes that lane while preserving pending custody. A late final
consumption and ACK can resolve its original pending item, but cannot reopen
the stream. `lateConsumed` records the exact original pending item only at
consumption after timeout. The late-consumption witness requires its matching
ACK on the closed lane; an ACK delayed after earlier consumption is insufficient.
Credit-owner death permanently disables its lane; an already
queued final-consumer item may survive. The first product has no reconnect or
replacement action. Timeout and restart mutants deliberately violate this
restriction in the same surviving sink. `NoRemintedCredit` checks the closed
state against independently retained invalidation history.

Cancellation has one separate reserved slot. `ControlReady` is the guard used
by the actual consumption action. `ControlIndependent` compares that guard to
the independent premise of queued control and a live recipient. Its mutation
adds a data-credit dependency to that guard. Enabled control is the checked
property; without fairness, eventual cancellation is not established. Recipient
liveness is fixed in this model; credit-owner death is modeled separately.

Known transport drop or cumulative exhaustion records both irreversible
`failed` and independent `lossHistory`. The final-consumption action accepts success only for the fully consumed
inbound terminal and an unfailed stream. Success closes the finite scenario;
there are no later protocol effects. The dropped-success mutation removes
only that failure guard: an already queued terminal can then complete after
an opposite-direction protocol item is dropped. Resource cleanup and native
retirement are outside this algorithm.

## Checks and measured evidence

Run `python3 protocol/models/distributed-authority/run.py` from the repository
root. It checks all 47 controls with pinned TLA tools 1.7.1, translation equality,
one worker, a 512-MiB heap, 64-MiB direct memory and a 60-second case deadline.
The complete run exited zero on 2026-10-04. Channel safety exhausted 7,737
states for quota four and 4,025 for quota three. Its six positive controls and
six mutants require exact exit 12, the intended invariant and a multi-state
trace. Their counts are partial exploration, recorded in WITNESSES.md.

## Production bridge obligations

| Model action or fact | Required production boundary and fault regression |
| --- | --- |
| Data admission and `admitted` history | A fixed bounded writer window, independent per-frame and lifetime byte checks; cumulative-exhaustion regression. |
| Transport-to-consumer movement | Stable final-host credit, beyond socket/TLS drainage; stalled recipient and network-drain mutation. |
| Final consumption and exact ACK | Credit returns from final bounded recipient state; delayed ACK with the opposite data window full. |
| Timeout and credit-owner death | Preserve original pending custody and retire the lane; timeout/restart mutations with the same surviving consumer queue. |
| `ControlReady` | Separate bounded cancellation admission and processing; both data windows occupied. |
| Terminal acceptance and `lossHistory` | Ordered Outcome/HookResult decode and irreversible stream failure; opposite-direction drop before consuming an already queued terminal. |

These are obligations for future source mapping. No production function or
fault regression is claimed to implement this model yet. The model assumes
trusted participants, fixed source items and atomic in-memory transitions.
It proves finite safety, not parameterized bounds, TLS authentication, BEAM
memory ceilings, disk limits, native retirement or shipped two-host completion.
