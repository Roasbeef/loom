# Scoped executor lifetime

Status: proposed implementation contract, reviewed by Astra. The lifecycle API
and native close-state correction await owner approval. This note does not change
protocol 067 or claim that the production host already implements these rules.

## The failure this closes

Two scopes share one executor node and its six transport credits. If scope A's
services stop while its registration remains active, a valid retry for A still
receives a credit. Discovering the dead service retires that credit. Repeated
retries can exhaust the credits that scope B needs.

The endpoint must fence A's exact registration before orderly service teardown.
Its acknowledgement means later reservations for A are refused before taking a
credit. A crash can race with that fence: already assigned work may remain
uncertain and consume capacity. The design preserves that uncertainty instead
of constructing replacement capacity.

A separate close bug follows from the existing native contract. Successful
native close ends the native actor. A wire CloseScope can complete that close
while the remote service remains alive. A subsequent host shutdown must retain
and use the original result; asking the dead native actor again loses the proof
and reports uncertainty.

## Ownership

One node owner holds distribution membership, protected credential paths and the
fixed endpoint. Each temporary scope owner holds its original native pool,
services, journals and physical resources. A scope borrows the endpoint's local
administrative handle; closing it cannot stop the node endpoint or a sibling.

The endpoint retains at most sixteen immutable registrations for its lifetime.
A registration includes its exact concrete service binding, generation and scope
owner. Closed rows remain tombstones. This proposal adds no unregister, same-scope
rebind, automatic restart or replacement credit mechanism.

## Proposed local administrative API

`fence(server, registration)` acknowledges the exact row's permanent transition
from Active to Fenced. Repeating it for the same row is harmless; a different
concrete binding is an error. `inspect_drain(server, registration)` returns one
of Busy, Drained or Uncertain. Missing and mismatched rows are errors.

The six fixed credit records become the sole allocation state, replacing the
current free lists. Each retains its lane and actor identity plus one disposition:

| Disposition | Meaning |
| --- | --- |
| Available | No original run owns the credit. |
| Assigned(row, correlation) | That exact original reservation owns the credit. |
| Unusable(None) | An idle credit died; capacity is lost without a scoped obligation. |
| Unusable(Some(assignment)) | An assigned credit lost its witness; the original scope remains uncertain. |

A completion names the concrete credit and original correlation. It releases
only the matching Assigned record, after the existing credit has observed the
actual service answer and transport AllDelivered, or joined a run that never
handed off an ask. A delayed completion cannot release a later reservation.
Credit monitors preserve death as Unusable; timeout and DOWN never imply drain.

A snapshot scans only these six records. An active row is Busy. A fenced row
with an unresolved assignment is Uncertain; otherwise an assigned run makes it
Busy. Only a fenced row with neither kind of obligation is Drained. That result
covers transport and service-ask custody, not native descendants, Compile or
workspace continuations, physical cleanup, or journal release.

The endpoint also monitors the sixteen possible scope owners. Owner death
fences the corresponding row even when it has no active credit. This prevents
idle dead registrations from accepting retries after the fence is applied.

## Closing one scope

The scope owner registers last, after creating its linked services privately.
Registration and any failure-path fence originate from that same owner, retaining
message order. A lost registration acknowledgement can follow publication;
timeout cannot prove that the row was never installed.

Orderly close performs these steps:

1. Acknowledge the exact row fence and quiesce native first admission.
2. Poll its bounded drain snapshot through `weft/poll` while reply-producing
   services remain alive.
3. Close and join Compile and workspace continuations, settle physical-resource
   obligations, obtain original native retirement, and join service actors.
4. Release original journal endpoints only after every required witness exists.

The public close budget must cover these sequential steps and reserve time for
cleanup. Poll expiry or failed journal closure does not skip cancellation and
native cleanup. The final verdict combines the attempted operations. A failed
close preserves fenced authority and original evidence; it does not report
successful aggregate drain.

Whole-node shutdown fences all rows, completes the same obligations, then stops
and joins idle endpoint actors. Endpoint DOWN alone supplies no native or
aggregate producer-drain proof.

## Retaining native close once

The existing remote service should own a closed-lifetime state. Its original
native close disposition is retained independently of durable closure and
retirement-confirmation writes. Native close can succeed while one of those
writes fails; the service must retain that native result even when the outward
answer is an error.

Repeated close may complete the remaining exact durable confirmations for the
original covered set. It cannot reopen admission, create a pool, renew a deadline
or reinterpret native DOWN as retirement. Native uncertainty stays uncertain.
Service death before the required witness is retained or returned also leaves
uncertainty. No new public retirement-proof token is proposed.

## Required evidence

Real TLS peers must exercise A and B with separate native pools and journals.
Hold A's ask, fence A, verify late reservations consume no additional credit, and
show B can use the remaining capacity. Release A's actual answer and producer
drain in both orders. Stale handoffs and releases must not settle newer work.
Kill idle and busy credits separately, and kill an idle scope owner.

Successful wire CloseScope followed by host close must invoke native close once.
A journal failure after native success must preserve that success without claiming
durable closure. Poll expiry must still attempt native cleanup. Lost registration
acknowledgement must not leave active admission after successful cleanup.

The [P credit model](../review/distributed-scoped-drain-model.md) now covers
scoped fencing, original correlation, unusable assignment retention and the
snapshot predicate. Its answer and drain events remain assumptions until
bridged to those real-peer tests. This is not a proof
of OTP delivery or native process retirement.

See the [transport review](../review/distributed-beam-transport-transition.md),
[executor architecture](../architecture/executor.md) and
[integration acceptance checklist](distributed-runtime-integration.md).
