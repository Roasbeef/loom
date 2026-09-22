# 047: Bounded usage observations on the session socket

Status: accepted for implementation in PR #482.

## Problem

Protocol 018 sends a `committed` notice for every durable write on a network
socket. The terminal then fetches a bounded capture. That capture includes the
session's cumulative usage, but no individual provider usage row. A cache-miss
reading needs two consecutive rows on one strand. The terminal cannot recover
those rows from the cumulative total, especially when other strands run at the
same time.

The host fixture receives raw usage events. The network gateway instead turns
each usage event into a notice, so a test that injects a raw usage push into
the terminal does not exercise production delivery.

## Decision

For a newly committed usage row, the network gateway pushes the existing
`usage` event after its `committed` notice. The observation carries the row's
durable sequence in the envelope, the attributed strand and operation in the
body when known, and the provider's fixed-shape usage counters. The gateway
checks the encoded frame against the 64 KiB response limit before sending it.
If the observation exceeds that limit, it sends only the notice. Other durable
records still travel only through credited captures.

The notice continues to trigger capture. Captured cumulative usage remains
authoritative; a pushed row never adds to that total. The terminal keeps the
highest observed usage sequence per strand so a duplicate or delayed push
cannot reset its cache clock or count the same settlement twice. It retains
only the latest pending row per strand and compares it after a capture covers
that sequence. The captured configuration then decides whether the row may
extend a cache baseline. A missing or superseded observation can lose a cache
warning, but the next capture still repairs the session total. The client
makes no correctness claim about receiving every observation or about the
order of pushes and replies.

A model switch clears that strand's cache baseline and fences the first
operation identified by a later usage observation. Every row from that
operation is ignored by the cache detector. An in-flight request accepted
under the old model may settle after the switch, so its rows cannot establish
the new model's baseline. If that request had already settled, the fence
conservatively skips one new-model operation. A later operation starts a fresh
baseline; it cannot report a false miss against the old provider. Rows with
no operation identity remain outside the detector while the fence stands.
The fence is installed for a captured model change even when the strand had
no prior cache baseline. An initially captured live strand is fenced as well:
its running operation may have been accepted under a model selected before
this terminal attached. If the first observation arrives after an initial cut
that already covers its sequence, it cannot seed a baseline: its operation may
have settled before attachment under that earlier model.

## Alternatives and cost

Pushing arbitrary durable records would undo protocol 018's bounded transfer
rule. A new credited command for usage history would preserve that rule but
would add a second catch-up cursor and another request to the terminal's
single-credit lane. The fixed-shape, size-checked observation is enough for a
live cache reading while the existing capture retains custody of totals.

The additional push costs one authority check and one small frame per usage
row per subscribed peer. Older terminals ignore the unsolicited event name.
The wire shape of `usage` and every command remains unchanged; only the
existing event's unsolicited delivery gains a bounded case.
