# Live delivery on the shared daemon

*Design note for [issue #240](https://github.com/Roasbeef/loom/issues/240).
This is the ruling the workers implement against; the mechanics below are
settled, the open questions are listed at the end.*

## The problem, stated from the code

The shipped daemon serves every terminal by pull. Three facts on `main` make
that so, and each one is a separate piece of work:

1. **No commit ever reaches the network gateway.** `gateway.commit_forwarder`
   turns a writer publication into a `CommitHint`, but only `client/demo`
   starts one. `client/serve` subscribes the writer to history and rules and
   never to the hub, so under `Network` delivery the hub learns of a commit
   only when a client's `catch_up` reads the store.
2. **The hub refuses to push even when it knows.** `pull_and_broadcast` and
   `broadcast_delta` return early under `Network`, `send_to` routes every
   network envelope through `send_response`, and `send_response` drops any
   envelope without a `reply_to`. The socket registers `fn(_) { Nil }` as its
   sink, so a frame that did escape would go nowhere.
3. **The terminal fails closed on anything it did not ask for.**
   `session_channel.receive` treats an incoming frame in the `Ready` phase as
   "unsolicited conversation response" and closes the socket, and
   `session_wire.decode` requires `reply_to` to equal the outstanding request.

What already works, and stays: the per-delivery authority check. `deliver`
re-resolves the binding (`check_binding`) before every frame it hands a sink
and closes the attachment when the answer changed; `revalidate_all` runs on
every hint. Push does not need a new authority path. It needs the existing
one to be reachable from the network side.

A second thing that stays is the bounded stream preview. `tap_preview_provider`
already carries a discontinuous 24 KiB sample of the live stream into every
snapshot, so a peer sees *some* of an answer being generated today. Pushed
deltas make that continuous; the preview remains the catch-up fallback for a
terminal that reconnects mid-answer.

## Ruling 1: what a push carries

**A pushed durable frame is a commit notice, not the record.** When the hub
observes new sequences it pushes one frame per committed entry:

```json
{"v":2,"event":"committed","seq":41,"body":{"strand":"main"}}
```

with no `reply_to`. The record body still travels the credited snapshot path:
the terminal that receives a notice for a sequence it has not seen issues its
`catch_up` *now* instead of at the 250 ms idle refresh. Two properties made
this the choice over pushing the entry inline:

- The 64 KiB response bound and the bounded retention window are enforced in
  exactly one place, the snapshot transfer with its `Part` reassembly. An
  inline entry push would need a second size bound and a second append path
  into the window, or an oversize escape hatch, for a latency gain of one
  loopback round trip.
- A notice is idempotent and order-free. A terminal that already holds the
  sequence (its own catch-up raced the commit) ignores it; a terminal with a
  request in flight defers it; a terminal that missed one is repaired by any
  later catch-up. There is no client-side reordering to get wrong.

Issue #240's acceptance says "as pushed frames without issuing a catch-up".
This ruling changes that sentence deliberately: the frame that is pushed is
the notice, and the catch-up it triggers is the delivery. The observable
property the fixture proves is the one the issue actually wants: every
attached terminal renders both answers without waiting for an idle refresh,
and the Reader sees tokens while the answer is being generated.

**A stream delta is pushed inline.** `broadcast_delta` already builds the
`stream_delta` event; the guard comes off and the frame goes to every
subscribed connection through `deliver`. Delta text is clipped with the same
`preview_text` bound the snapshot preview uses, so no pushed frame exceeds
what the terminal's decoder accepts.

**Presence events** go out the same way: `publish_presence` already calls
`send_to` with no `reply_to` when a peer departs; under `Network` that now
reaches `deliver` instead of being dropped. A join is not pushed, since every
pushed frame costs one authority check per peer and the joiner's capture
already carries the roster.

## Ruling 2: the delivery path

`send_to` under `Network` splits on the envelope, not on the connection:

- `reply_to: Some(_)` keeps the existing `send_response` path. One request,
  one reply capability, the bounded response, the authority re-check.
- `reply_to: None` goes through `deliver(link, frame)`, which is the same
  per-frame `check_binding` the host fixture path has always used, and which
  closes the attachment on a changed answer. This is the "same per-delivery
  authority check" the issue asks for, and it is the existing function.

The socket registers a real sink: `fn(frame) { process.send(outbound,
Push(frame)) }`. The websocket process handles `Admitted(_), Custom(Push(f))`
with `mist.send_text_frame`. Because the socket process serialises its own
writes and a request's reply is written from the same process before the next
mailbox message is read, a notice for sequence *n* is never written ahead of a
reply that was computed after *n* committed. The client does not rely on that
ordering, but it holds.

The hub primes its high-water under `Network` exactly as it does under
`HostOnly` (`pull(state).0` at start). Without the prime a restarted hub would
push a notice for every historical sequence on its first hint.

`client/serve` starts one `commit_forwarder` per session hub and adds
`writer.Routed(forwarder)` to the runtime's subscribers. A hint that arrives
while the hub is absent is lost by design: it cannot interrupt a commit, and
the next catch-up recovers.

## Ruling 3: concurrent submits are queued per strand, in arrival order

A `prompt` on a strand with a live run no longer returns `code_conflict`. The
hub holds it in a per-strand FIFO and replies:

```json
{"v":2,"reply_to":7,"event":"mutation_outcome","body":{"status":"queued"}}
```

When `pull` observes the strand's live operation reach a terminal phase, the
hub pops the head and calls `api.prompt` with the held message and its
recorded origin. The entry then commits with the submitter's authorship and
reaches every terminal as a notice. The daemon-chosen order is arrival order
at the hub, which is one actor, so it is total.

Bounds and failure behaviour:

- At most four held prompts per strand. A fifth is refused with the existing
  `code_conflict`, so a stalled strand cannot accumulate unbounded state.
- Held prompts are hub memory, not durable. The reply says `queued`, not
  `admitted`, and a hub restart drops the queue. The terminal shows the
  queued state locally and clears it when its own entry arrives or when the
  socket closes. Making the queue durable would mean a new operation kind in
  `machine`; nothing here needs that, and it is recorded as open below.
- If admission fails at drain time for a reason other than `StrandBusy`, the
  hub pushes an `error` event to the submitter's connection (through
  `deliver`, so a revoked submitter gets nothing) and drops the prompt. A
  `StrandBusy` at drain time keeps the prompt at the head; another run opened
  through a host path and the next terminal transition drains it.
- `steer` and `follow_up` are unchanged: a principal who wants their message
  folded into the live run uses those. `prompt` on a busy strand means "next
  turn", and the wire status says so.

## Ruling 4: what the terminal does with a pushed frame

`session_wire.decode` gains a third outcome: an envelope with no `reply_to` is
`Pushed(event)`, and it is accepted in every phase except `Closed`. Reply
correlation is unchanged for envelopes that carry `reply_to`.

- `committed` with `seq >= cut.next_seq`: in `Ready`, capture now; while a
  request is in flight, mark the channel so the next `Ready` transition
  captures immediately instead of at `+250`. A notice for a sequence already
  held is ignored.
- `stream_delta`: applied to the model as a live-stream update in any phase.
  It replaces the discontinuous preview for that strand and operation while
  deltas keep arriving; the committed entry replaces both.
- `presence` and `attachment`: treated as a capture trigger, the same as a
  notice. The metadata arrives with the capture.
- `mutation_outcome` with `queued`: an `Acknowledged("prompt", "queued")`
  update, rendered as a queued composer state rather than a conflict.

The 250 ms idle refresh stays. It is the recovery path for a lost notice and
the only path on a daemon that predates this change.

## Wire summary

All of the following is additive and lands as `protocol-change/018`:

| Frame | Direction | Correlation | New? |
|---|---|---|---|
| `committed` `{strand}` with `seq` | hub → socket | none | new event |
| `stream_delta` | hub → socket | none | existing event, newly pushed |
| `presence`, `attachment` | hub → socket | none | existing events, newly pushed |
| `mutation_outcome` `{status: "queued"}` | reply | `reply_to` | new status |
| `error` after a failed drain | hub → socket | none | existing event, newly pushed |

## What proves it

A shipped fixture in the `tui_shipped_multiplayer_test` style, in its own
module and CI step: Alice and Bob submit on the same strand within one
catch-up window; the loser's reply is `queued`; both answers render at Alice,
Bob and the Reader without an idle refresh firing (the driver asserts the
capture that painted each answer was notice-driven); the Reader observes
`stream_delta` frames before the answer's entry exists in its cut; Bob is
revoked mid-answer and his socket closes at the per-delivery check with no
further frames written. The scripted provider gains a per-chunk pacing option
so the stream is observable.

## Open, deliberately

- **Durable queue.** A held prompt that survives a hub restart needs a
  pending-run operation in `machine`. Not needed for the property above.
- **Per-frame versus registry-pushed revalidation.** Pushed delivery re-checks
  per frame, as replies do. The registry-pushed revision from the review wave
  stays deferred; if the per-frame cost shows up in the soak, that is the
  measurement that reopens it.
- **Dropping the snapshot preview.** Once every shipping terminal consumes
  pushed deltas the preview lease machinery is redundant. It stays until a
  release has been cut with both.
