# protocol-change/038 — held-input custody return on drain

**Status**: PROPOSED 2026-09-14 · **Affects**: the session-protocol v2 event
vocabulary (Part 1.6), adding one pushed event and no command ·
**Implemented**: `client/protocol`, `client/gateway`, `client/daemon`,
`client/serve`, `runtime/api`

## Problem

One daemon serves many workspaces and outlives the terminal that started
it, so an update installs a new release *beside* the old one and the old
daemon keeps running until it exits (issue #392, see
[037](037-build-identity.md)). When it does exit, its gateway's held
queue — prompts held for a strand that was busy when they arrived
([018](018-pushed-delivery.md), [033](033-abort-halts-held-input.md)) —
lives only in hub memory. The daemon drain tears the hub down with the
queue in it, so a prompt the operator submitted and saw acknowledged as
`queued` vanishes without a word. The submitter is left believing a
message is on its way when it was never admitted.

The queue is **deliberately not durable** (`client/gateway`: a prompt that
survived a hub restart would need a pending-run operation in `machine`,
which is a new durable operation kind bought for a convenience nothing
else needs). So the drain cannot *keep* the held prompts; it can only give
their custody back to whoever submitted them.

## Proposal

**1. The hub returns each held item to its submitter, unsent.** On drain,
every held prompt is emitted to the connection that submitted it — the
same connection-addressed delivery the rejection path already uses — as a
pushed event:

```
held_input_returned { strand, id, kind, text, attachment_count }
```

- `strand` is the strand whose queue held it.
- `id` is the held item's own hub identity, so a client can match the
  return against the acknowledgement it received at submission.
- `kind` is the item's order spelling (`"queue"` for a turn, `"steer"` for
  a steer), the same vocabulary the queue board already uses.
- `text` is the **complete** submitted text, not the board's clipped
  preview: the item's custody has left the server, and a draft restored
  from a prefix would silently lose what the operator typed.
- `attachment_count` counts image blocks the body cannot carry as text, so
  the client knows how many it must keep beside the restored draft.

**2. The event is pushed and uncorrelated.** It answers no command — the
submission it undoes was acknowledged as `queued` long before the drain —
so it carries no `reply_to`, exactly like `input_queue_changed` and every
other notice.

**3. Client reconnect is the client half, and it is already defined.**
The operator learns the daemon is restarting from two things the wire
already carries: the `daemon.shutdown` acknowledgement (`state:
"draining"`) at the moment they ask for the update, and the transport
closing when the daemon actually exits. What this proposal adds is not a
second "I am going away" event — it is the *custody* half, so that when
the client reconnects ([037](037-build-identity.md) carries the identity
a reattached client compares) the operator's held prompts are already
back in their hands as drafts rather than lost. A separate draining
notice was considered and rejected as redundant with the existing
acknowledgement and the transport close, which the client already
handles.

## Impact

### Drain ordering and confirmation

The gateway enters a permanent draining state before returning held input.
It refuses subsequent mutations, continues authenticated reads, and does not
start a held successor when an aborted strand becomes idle. This fence is
owned by the gateway: changing the daemon root's phase cannot fence frames
on a session socket that was already admitted.

The registry only snapshots the resident drain capabilities. A bounded Weft
task owned by the daemon root invokes them outside both actors' receive
loops. Delivery revalidates session authority through the registry, so an
inline registry callback would wait on its own blocked receive loop. The
root must also remain responsive to control reads throughout the drain.

Each instance fences its gateway before requesting runtime cancellation.
All instances, gateway calls, transport flushes, and runtime waits spend one
shared deadline. The transport places its flush acknowledgement after the
gateway's pushed frames from the same sender; the acknowledgement is awaited
outside the gateway, where it cannot block a socket's in-flight request.
It confirms completed socket writes, not receipt or persistence by the
remote client. A dead peer or an expired budget cannot confirm custody
return. The held queue remains memory-only, so this is a bounded graceful
shutdown facility, not a guarantee against disconnection or daemon failure.

After this drain attempt, normal lifetime shutdown still requires the
original custody monitor's retirement evidence. Completion of the drain
worker does not replace that evidence or permit early lock release.

These corrections follow an independent review of the production callback
chain during the #404 takeover. Its authenticated gateway delivery calls
back into the registry; the original host-only fixtures did not exercise
that dependency. Acceptance requires a barrier test with real registry
authority checks, a late-mutation refusal, an abort that starts no held
successor, and a socket fixture that observes the return before closure.

`client/protocol` gains the event name, its encoder and decoder.
`client/gateway` gains `drain_held`, a synchronous call that walks every
strand's held queue, emits one `held_input_returned` per item to
`item.submitter`, and clears the queue. `client/daemon` threads a `drain`
capability through the registry's assembly so the root can drain a
resident instance's hub *before* it kills the session sockets those
returns travel over, and `runtime/api` gains `drain`, which requests an
abort on every live strand and awaits the resulting terminals inside one
shared budget before the tree is stopped — so a drained in-flight turn
commits an ordinary `Aborted` terminal rather than being lost.

## What this does not do, and the follow-up it names

The `Aborted` terminal a drain commits carries the **generic** abort
diagnostic (`interrupted: ...`), not text naming the restart. Threading a
restart-specific reason into that entry would mean changing a frozen
Part-1 shape — `OperationState.Control.CancelRequested` or
`PlannerInputs` — for one line of text. That is deliberately not done
here. The operator is not left guessing, though: the drain happens in
response to an explicit `daemon.shutdown` (whose acknowledgement already
says `draining`), and the client's reconnect path reattaches with the
transcript intact. A future proposal may carry a durable reason on the
cancel marker so the *entry itself* names the restart; that is a
machine-package change with its own protocol-change, and it is named here
so the gap is recorded rather than mistaken for an oversight.

## Alternatives considered

**Make the hub queue durable.** Rejected: it needs a new durable operation
kind and its own replay, to preserve a convenience that a client can
already reproduce by keeping the draft it typed. The queue's memory-only
nature is the ruling; the fix is to return custody, not to persist it.

**Return a held item to *any* attached operator rather than its
submitter.** Rejected: a held item already carries its submitter's
connection, and custody returning to the connection that owns it is the
same rule the rejection path uses. Broadcasting it would hand one
operator's draft to another.

**Refuse new submissions during the drain instead.** Rejected as
insufficient: the prompts already held when the drain begins are exactly
the ones at risk, and refusing later ones does nothing for them.
