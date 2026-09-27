# protocol-change/054: push the roster when a network peer subscribes

**Status**: ACCEPTED 2026-09-27 (owner), being implemented on
`gateway/roster-push-on-subscribe` · **Affects**: Part 1.3
session protocol v2 (when the hub pushes `presence`); amends
[protocol-change/018](018-pushed-delivery.md) · **Raised by**: PR #567
(event-driven delivery for the terminal and the web view)

## Problem

A peer joining a session is not announced to the peers already attached.
[protocol-change/018](018-pushed-delivery.md) says so directly, in its
second proposal: the hub pushes `presence` on a departure, and "a join is
not announced by a push, since every pushed frame costs one authority
check per peer and the joiner's own capture already carries the roster."
The code follows it. `gateway.remove_connection` calls
`publish_presence`, and `gateway.network_command`'s `Subscribe` arm marks
the connection subscribed and begins its transfer without calling it.
(The shared dispatch's `subscribe`, which host delivery uses, does publish
on subscribe; only the network path, which every real client uses, does
not.)

When 018 was written this cost little, because every client also polled
its lane every 250 ms and so saw a newcomer within a quarter of a second.
PR #567 removed that poll. A lane that has received a pushed frame now
refreshes only every `session_channel.pushing_refresh_ms`, and relies on
pushes for everything else. A join is the one change a peer's screen
depends on that produces no frame at all, so nothing arrives that the
lane could treat as a reason to catch up.

The cost is measured. `client/tui_shipped_multiplayer_test` has Bob leave
and rejoin while Alice and a reader stay attached. With a 5 s refresh,
Alice's wait to see Bob's new attachment went from 231 ms to 4,979 ms
(median of five runs), and the fixture from 7.9 s to 12.2 s; each of its
other 79 waits moved by less than 30 ms. The wait is close to the full
interval rather than a random fraction of it: Bob's departure is pushed,
Alice's lane captures on it and schedules its next refresh a whole
interval out, and his rejoin a few milliseconds later arrives inside that
interval with no frame.

The same gap has a second effect. A client that attaches to a quiet
session receives no pushed frame until something happens there, so its
lane stays `Polling` and refreshes every 250 ms. A web page in that state
renders 15.3 times a second while idle, against 9.9 before #567.

PR #567 covers the join with an interim `pushing_refresh_ms` of 1 s. That
bounds a join's delay to one second at the price of a capture a second
from every idle attached client, where 5 s was the intended cost.

## What was considered

**Push the roster to every subscriber when a network peer subscribes.**
The `Subscribe` arm calls `publish_presence` after `mark_subscribed`, as
the shared dispatch's `subscribe` already does. Every subscribed peer,
the newcomer included, receives the existing `presence` event with the new roster. No
event changes shape and no client code changes: the lane already decodes
`presence` as `MetadataChanged` and captures on it, and it already treats
any pushed frame as the evidence that moves it from `Polling` to
`Pushing`. The newcomer's own copy is that evidence, so a client attached
to a quiet session leaves `Polling` at once.

**Push a join notice without the roster.** A new event, or a `presence`
with an empty body, that says only "the roster changed". Peers would
capture on it exactly as they do on `presence`, so it removes the same
delay. It saves the roster's bytes, which are one small object per peer
and already bounded by 018's size argument, and it costs a new event name
or a second meaning for an existing one. It does not reduce the authority
checks, which are per frame and not per byte. It gains nothing the first
option lacks.

**Keep polling.** Leave 018 as it is and keep a short `Pushing` refresh.
At 1 s this costs every idle attached client one capture a second, which
is a catch-up request the daemon decodes and answers, to cover an event
(a join) that happens a handful of times per session. At 5 s it leaves a
newcomer invisible to the others for up to five seconds. Neither is a
good trade for an event the hub already knows about when it happens.

## Proposal

Amend 018's second proposal to read: the hub pushes `presence` when a
peer subscribes and when a peer departs. The `presence` event, its body
and its bounds are unchanged.

In `client/gateway`, `network_command`'s `Subscribe` arm becomes:

```gleam
True -> {
  let state = mark_subscribed(state, connection)
  publish_presence(state)
  begin_transfer(state, connection, id, transfer.Recent)
}
```

Ordering is 018's rule unchanged: a pushed frame is idempotent and
order-free. The newcomer's `presence` and the reply to its `subscribe`
leave the gateway by different paths (`deliver` and `send_response`), so
either may reach the socket first. A lane that receives `presence` before
its first cut records that it has been pushed to and otherwise does
nothing (`session_channel.capture_or_defer` has no capture to take without
a cut), so the order does not matter.

## Frozen-interface impact

Part 1.3 does not change shape. What changes is a behaviour 018 fixed in
prose: a client may now receive an unsolicited `presence` right after it
subscribes, which 018 already requires every client to accept in any
phase.

## Impact

- `client/gateway`: one call in the `Subscribe` arm of `network_command`.
- `client` tests: in a trial of this change, nine client tests failed
  because they read the push order or count authority checks. The four in
  `session_authorization_test` count authority queries around admission
  and delivery and now see one more per subscribed peer; the others,
  among them `ui_relay_test`, read the frame after `subscribe` and expect
  the reply. Each needs the new order stated, not loosened.
- `session_view`: no change beyond setting `pushing_refresh_ms` back to
  5000.
- No durable format changes. No exec-helper frames are touched, so
  `exec_protocol_version` does not move (protocol-change/006's addendum).

## Cost

- **Authority checks.** Each pushed frame to a network attachment passes
  `deliver`, which calls `check_binding`. A join therefore costs one check
  per subscribed peer, the newcomer included. 018 declined this cost; it
  is the same cost every committed entry already pays, and joins are far
  rarer than commits.
- **Nine client tests change**, as above.
- **A page on a quiet session leaves `Polling`.** Its idle refresh goes
  from 250 ms to `pushing_refresh_ms`. This is the intended effect, but it
  is a behaviour change: any state the daemon does not push reaches that
  page at the pushing interval rather than within 250 ms. After this
  change no such state is known; the audit in PR #567 found configuration,
  committed entries, input-queue changes, operation transitions and
  departures all pushed.

## Consequences

- Raise `session_channel.pushing_refresh_ms` back to 5 s once this lands.

## Verification required

- A `gateway_test` case: with two network peers subscribed, a third
  subscribes, and both earlier peers and the newcomer receive a `presence`
  whose roster holds all three.
- `session_authorization_test` states the new check counts exactly.
- `client/tui_shipped_multiplayer_test`, with each wait timed as in PR
  #567: Alice's wait for Bob's rejoin returns to a few hundred
  milliseconds with `pushing_refresh_ms` at 5000, and the fixture returns
  to about 8 s. Run five times under load against `bin/loomd` with
  `LOOM_BOOTSTRAP_E2E_SERVER` set.
- A live drive: a page attached to a quiet session reaches `Pushing` at
  attach, and its idle renders and catch-ups per second match a page on a
  session that has pushed.

## Decision

**Accepted by the owner on 2026-09-27.** The recommendation below is what
was accepted and what is being implemented. It was written as:

The recommendation is the first option:
push the existing `presence` roster to every subscriber when a network
peer subscribes. It reuses an event every client already handles, it
removes both the join delay and the quiet-session poll, and its cost is
one authority check per peer per join, which is the cost 018 already
accepts for every commit.
