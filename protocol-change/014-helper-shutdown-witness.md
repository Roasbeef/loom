# protocol-change/014: retain native exit on helper shutdown

**Status**: ACCEPTED 2026-09-05 · **Affects**: Part 1.4 executor channel ·
**Raised by**: single-daemon session retirement · **Implementation**: broker + sandbox implemented; release acceptance remains open

## Problem

A daemon must finish retiring one session's effects before releasing its
writer lease and admitting a replacement. The helper already cancels and
joins its active jail when stdin closes. But `erlang:port_close` removes
the port before the broker can select its native exit-status event.
Returning from that call proves that BEAM closed the channel, not that
the helper finished cleanup.

The existing `cancel` frame stops an execution but keeps the helper alive
for reuse. Neither `exec_exit` nor an acknowledgement sent before helper
exit proves that the helper itself has retired.

## Proposal

Add one harness-to-helper frame after the hello exchange:

```
{v: 1, id: u64, kind: "shutdown", body: {}}
```

The body must be an empty map. The helper does not use the identifier and
sends no acknowledgement. On receipt, it stops accepting commands, cancels
and joins any active jail through its existing cleanup path, then exits.
Execution output already in flight may precede that exit.

The broker sends the frame and retains the port until it selects the
native exit-status event. A successful send, an `exec_exit`, a caller
timeout, or the death of the BEAM owner is not confirmed retirement.
Without native exit evidence, session cleanup remains unconfirmed and
cannot release the session's reservation or writer lease.

Native exit proves that the helper process ended. Successful orderly
shutdown also runs the helper's existing cancel-and-join path. Neither
claim strengthens platform containment: Darwin's documented descendant
tracking limits still apply, and helper exit does not undo remote effects.

## Impact

The Go framing package accepts `shutdown`; the helper server handles it
through the same final cleanup used by EOF. Gleam framing gains the
corresponding body variant. The helper state machine retains the port
while draining, and the pool must retain every idle and lent helper until
its close outcome is known.

Both ends ship from the same tree. Rebuild `bin/loom-exec` and release
artifacts together; there is no compatibility fallback to `port_close`.
The frame version stays at 1, following the other accepted additions to
this wire. No conversation-store format or generated SQL artifact changes.

**Superseded on 2026-09-06 by the addendum to `protocol-change/006`
(issue #64).** "Following the other accepted additions" was following a
precedent that had already cost an hour of wrong diagnosis in issue #61.
Adding a kind to the exec channel is a version bump like any other: a
helper that predates this document answers `shutdown` as an unknown kind
rather than by retiring, which is exactly the disagreement a version
number exists to name. This change is the exec protocol's **3**. The
envelope version — the `v` key — does stay at 1, and that half of the
sentence still holds; the two numbers are separate, and
`broker/framing`'s module comment says why.

## Decision

**Accepted.** The owner approved the frame on September 5. Closing stdin
through `port_close` was rejected because it discards the required exit
evidence. A shutdown acknowledgement was rejected because the helper can
send it while cleanup is still running. Native exit supplies the completion
event without another acknowledgement protocol.
