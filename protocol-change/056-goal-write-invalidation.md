# 056: Announce durable goal changes

Status: accepted for implementation within the authorized #399/#524 batch.
Amends Part 1.6 with the unsolicited `goal_changed` event. Independent review
and final acceptance remain with the root reviewer before landing.

## Problem

The advisor evaluates a goal asynchronously after the primary settles. A
client reading at the primary's idle edge can finish before the goal write.
Paused, limited and satisfied outcomes need not start another operation, so
no later phase edge repairs that observation.

## Decision

After a successful write or deletion of the reserved goal cell, the advisor
publishes `GoalChanged` on the session's existing event bus `Outputs` topic.
The gateway relays it to subscribed, authorized peers as an uncorrelated v2
`goal_changed` event with an empty object body. It carries no goal data and
no sequence frontier; it invalidates the auxiliary observation rather than
the transcript capture. Failed writes publish nothing.

The shared session lane retains one owed goal read. When its outstanding
request and any queued operator command finish, it issues `goal_get` and
clears that debt. A change arriving during a goal read leaves another read
owed, so a reply captured before the write cannot consume the notification.
Multiple changes coalesce. Both terminal and web hosts drive this same lane;
the terminal retains the returned board, while the current web view has no
goal panel. All reads and notifications use existing authorization checks.

## Alternatives and cost

Reading on the advisor's idle edge still depends on the write occurring
before that edge. Polling introduces a cadence and leaves the race visible
until its next tick. Pushing a goal board can race an older correlated reply.
An explicit invalidation after the write costs one small notification and
one bounded read per coalesced group of changes, with one extra lane field.
It adds no dependency, FFI, timer, durable cell or transcript entry.

A dropped notification has the existing best-effort delivery boundary; an
explicit goal inspection or later roster edge still reads authoritative state.
This proposal does not introduce a periodic goal read.

## Verification

Drive the connected client with a goal read completed before the invalidation
and with an invalidation arriving during an older read. Prove a subsequent
read renders paused, limited and complete without another phase edge. Drive
the advisor's real write and the gateway's real subscription path, including
a second subscriber. Mutation witnesses remove publication and remove the
client invalidation respectively. Root review records final disposition here.
