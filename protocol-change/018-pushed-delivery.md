# protocol-change/018 — pushed frames on an authenticated session socket

**Status**: ACCEPTED 2026-09-07 · **Affects**: Part 1.3 session protocol
v2 (event envelope, `committed` event, `mutation_outcome` status) ·
**Raised by**: issue #240 (client: true multiplayer delivery) ·
**Implemented**: `client/gateway`, `client/protocol`,
`client/daemon/session_socket`, `client/serve`

## Problem

The v2 session protocol as frozen is request/reply and nothing else. An
authenticated socket sends one command and reads exactly one envelope
carrying that command's `reply_to`; the gateway drops any envelope with
no `reply_to` (`send_response` returns `Nil` for it), and the socket
registers `fn(_) { Nil }` as its outbound sink, so a frame that escaped
the hub would go nowhere. Three consequences, all visible to an operator
with two terminals open on one session:

- A peer's committed entry reaches the other terminals only when one of
  them next asks. The shipped client asks on a 250 ms idle refresh, so
  every collaborator sees every answer late by up to a quarter second
  after the transfer it triggers, and only while it is idle.
- A live answer is visible to a peer only as the discontinuous 24 KiB
  `tap_preview_provider` sample carried inside a snapshot. Deltas exist
  in the hub — `broadcast_delta` builds the `stream_delta` event — and
  are discarded under network delivery.
- Presence and attachment metadata are built and thrown away for the
  same reason: `publish_presence` calls `send_to` with `reply_to: None`.

There is no room inside request/reply to fix any of these. A reply is
owed to a command; none of these facts answers a command.

Two separate concerns shape what the fix may look like. The bounded
response is the one place the 64 KiB frame ceiling and the retention
window are enforced, and it is enforced *per reply*, on the transfer's
`Part` reassembly. And every frame that leaves the hub for a network
socket passes the per-delivery authority re-check, so an unsolicited
frame must not become a second, unchecked way out.

## Proposal

Four additive changes to Part 1.3. Nothing existing changes shape, and
no command changes meaning.

**1. A new event, `committed`.** The hub pushes one per newly committed
durable emit it observes:

```json
{"v":2,"event":"committed","seq":41,"body":{"strand":"main"}}
```

`seq` is the storage seq of the write, exactly as on every other
durable-stream event. There is no `reply_to`: it answers no command.
The body carries the strand and nothing else.

**2. `stream_delta`, `presence` and `attachment` may arrive unsolicited.**
The events are unchanged on the wire. What changes is that a client must
accept them with no `reply_to` in any phase, rather than treating an
uncorrelated frame as a protocol violation.

**3. `mutation_outcome` gains the status `queued`.**

```json
{"v":2,"reply_to":7,"event":"mutation_outcome","body":{"status":"queued"}}
```

It is the reply to a `prompt` on a strand that already has a live
operation. `admitted` and `committed` are unchanged. `queued` means the
hub holds the message in memory and will submit it when the strand goes
idle; it is not a durable acknowledgement, and a client must not render
it as one.

**4. `error` may arrive unsolicited.** An `error` event with no
`reply_to` is a connection-scoped fault, which Part 1.3 already
describes; what is new is that the hub emits one when a held prompt
fails at drain time, long after the command that queued it was answered.

### Size

Every pushed frame is under the 64 KiB reply bound, by construction
rather than by a second check:

- `committed` is a version, an event name, an integer and a strand name.
- `presence` is one small object per attached peer, bounded by the
  parser reservations the daemon root admits.
- `stream_delta` is clipped with `preview_text`, the same 24 KiB bound
  the snapshot preview already uses, before it is encoded.
- `error` is a code and a message the hub itself writes.

So the bound stays enforced in one place for the thing that needs a
mechanism — the snapshot transfer, whose payload is a durable record of
unbounded size — and pushed frames stay small enough that the question
does not arise. A pushed frame carries no durable record: that is the
point of `committed` being a notice.

### Ordering

**A notice is idempotent and order-free, and a client must treat it as
one.** It carries a seq and nothing that depends on having seen an
earlier one. A terminal that already holds that sequence (its own
catch-up raced the commit) ignores it; one with a request in flight
defers it; one that missed a notice entirely is repaired by any later
catch-up, and by the 250 ms idle refresh that remains as the recovery
path. Nothing on the client reorders, buffers or acknowledges.

The daemon happens to write in a stronger order than that — the socket
process serialises its own writes, and a request's reply is written from
that process before it reads the next mailbox message, so a notice for
seq *n* is never written ahead of a reply computed after *n* committed —
but no client may depend on it. A daemon that queued its pushes
differently would still be conformant.

## Impact

- `client/protocol` gains `CommittedEvent(strand)` with its encoder and
  decoder, and `mutation_outcome`'s decoder accepts `queued`. The
  envelope encoding is untouched: a pushed frame goes through the same
  `event_value` that stamps `"v":2`, with `reply_to: None`.
- `client/gateway` lifts the network guard on `pull_and_broadcast` and
  `broadcast_delta`, primes its high-water under network delivery as it
  already does for host fixtures, and splits `send_to` on the envelope's
  `reply_to` rather than on the connection: `Some` keeps the bounded
  reply path, `None` goes through `deliver`, which is the existing
  per-frame `check_binding`. There is no new authority path.
- `client/daemon/session_socket` registers a real sink and gains one
  `Signal` variant; a push is written with `mist.send_text_frame` from
  the socket process, and a failed write stops the socket exactly as a
  failed reply does.
- `client/serve` starts a `commit_forwarder` per session hub and
  subscribes the writer to it, so a commit reaches the hub at all.
- A client built before this change sees event names it does not know.
  Part 1.3's tolerant name decoding already requires such a frame to be
  ignored rather than refused — but the shipped terminal on `main` does
  not honour that for *uncorrelated* frames, which is a client bug this
  change forces to the surface. `session_wire.decode` gains a `Pushed`
  outcome in the same series.

No durable format changes. No storage format changes. No exec-helper
frames are touched, so `exec_protocol_version` does not move
(`protocol-change/006`'s addendum).

## Decision

**Accepted.** Two alternatives were weighed and dismissed.

*Pushing the entry inline* instead of a notice. It is one loopback round
trip faster and costs a second size bound and a second append path into
the retention window, or an oversize escape hatch on a path with no
credit to fund one. The notice buys the latency property the issue
actually asks for — every attached terminal renders without waiting for
an idle refresh — while leaving the record on the one credited path that
already knows how to bound it.

*Making the queue of held prompts durable* rather than hub memory. A
prompt held across a hub restart needs a pending-run operation in
`machine`, which is a new operation kind, a new state-space, and a
durable object whose only reader is a convenience. The reply says
`queued` and not `admitted` precisely so that dropping the queue on a
restart is a behaviour a client is written against rather than a lost
write. Recorded as open in `docs/design-notes/live-delivery.md`.
