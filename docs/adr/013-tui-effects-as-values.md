# ADR-013: The terminal's step returns its effects as values

**Status**: accepted (phase 1) · **Date**: 2026-09-26 · **Supersedes**: nothing ·
**Relates to**: [issue #530](https://github.com/Roasbeef/loom/issues/530)
(Lustre-style TUI core), [ADR-009](009-record-terminal-attempt-custody.md),
[ADR-010](010-retain-one-unsent-terminal-command.md)

## The question

The terminal client already has the Elm shape: one immutable `Model`, one
reducer `tui.update(event, model) -> Model`, and a pure `render.view`. That
shape is what lets the virtual backend drive the shipped loop for replay and
for the golden-frame tests. The reducer itself is not pure. A survey of
`packages/tui/src` on September 26 found every websocket write going through
`session_channel.emit` or the preview peer's direct send, and the other
one-way effects spread across the reducers: socket and control closes during
retirement, adoption, quit and attachment cancellation; weft cancels; inbox
discards; the OSC 52 clipboard write; Herdr reports; recording appends and
attempt trace notes; and the acknowledgement that releases the attachment
worker.

Because each reducer performed its own I/O, nothing could run a transition
without acting on it. Replay and tests kept the loop from acting by
suppressing effects one site at a time, through socketless channels and about
twenty branches on `Peer` (`Replaying`, `Attached`-only, `Preview`), each of
which decides for itself whether it is allowed to write.

Issue #530 sets the goal of a Lustre-shaped core. `update` becomes a pure
function from a domain message and the model to a new model plus a
description of the effects to perform, and a per-platform runtime performs
them. The change is worth making for the terminal alone: a transition can be
inspected without acting on it, and replay and tests decide what happens to
effects in one place instead of in twenty branches. It is also the
precondition for a second client. A web view served by the daemon as a
Lustre server component could share the session channel, snapshot adoption,
projection, and the queue, approval and command logic with the terminal, but
only if that shared code describes its effects rather than performing them
against the terminal's transport.

This ADR records how phase 1 gets part of the way there without rewriting
the reducer in one change, and what that phase must preserve.

## Decision

**A terminal step returns its fire-and-forget effects as values, and a
separate runtime performs them.** `tui.step(event, model) -> #(Model,
List(Effect))` applies one event and returns the effects it decided on
without performing them. `tui.update` is `step` followed by
`runtime.perform`. Etui and the virtual backend still call `update`, so the
shipped loop's signature and behaviour are unchanged. Phase 1 covers the
one-way effects: frame writes, socket and control closes, worker, session
switch and attachment cancels, inbox discards, the clipboard write, Herdr
announcements and reports, and the attachment acknowledgement.

The effects are a closed data type, `tui/effect.Effect`, and not closures.
A test can assert that a submitted prompt produced exactly one
`Channel(Transmit(..))`, which it cannot do with an opaque function. A second
platform can interpret the same vocabulary against its own transport, where a
closure would carry the terminal's transport with it.

Every effect carries the handle it acts on, and the runtime never looks a
socket, control connection or worker up in the model. The model's handles
change during a step: an adoption replaces the socket, and a quit clears the
candidate. A write decided against the old socket before an adoption must
reach the old socket, and a lookup at perform time would find the new one.

Reducers queue effects on an `outbox` field of the model through
`tui_model.emit`. At the end of every step `runtime.take` empties the outbox
and the queues of the adopted and candidate channels, so between two steps
every queue is empty. The outbox is an implementation detail behind `step`.
A runtime or a test sees only the returned list, which would have the same
shape if the reducers threaded their effects explicitly.

`tui/session_channel` becomes a pure transition system. Its `emit` and
`close` queue `Transmit` and `Shut` outputs on the channel instead of writing
to or closing the socket, and `session_channel.perform`, beside the type, is
the only function in the module that touches the transport.
`tui/attachment` exposes its candidate channel's outputs the same way through
`attachment.take_outputs`, and adds `Acknowledge` for the reply that releases
the preparing worker.

A reducer that replaces or drops the adopted channel within a step calls
`tui_model.release_channel` first, which moves the channel's queued outputs
into the outbox. Before this change, a write the channel had decided on had
already happened by the time the channel was dropped. Without the release,
the write would be discarded along with the channel value and never reach
its socket.

The runtime performs the adopted channel's outputs first, then the
candidate's, then the model outbox. Order within one channel is preserved,
and that is the order the protocol needs: frames on one socket leave in the
order the lane issued them. Order across the three queues does not matter. A
channel never writes after its own close, and the outbox holds closes and
cancels of resources that the channels are not writing to.

Recording appends and attempt trace notes stay synchronous in phase 1. The
recording orders an input before the channel traces that the input caused
(ADR-009), and that order holds only while every recording write happens
where it did before. Moving the trace notes into the post-step queues while
`recording.note_input` stays inline would write a request's trace after the
next input. Issue #530 originally listed record and trace effects in the
phase 1 vocabulary; they are left out here for that reason and join the
effect stream as a whole in phase 2.

A caller that drives reducers or channels outside the loop must perform what
they queued. A test driver that hands a selected socket message to
`inbound.accept_connection_message` passes the resulting model through
`runtime.flush`. A caller holding a bare channel or attachment against a live
socket calls its `take_outputs` and passes each output to its `perform`. The
next `update` also collects anything still queued, so a missing flush delays
an effect rather than losing it; a test that waits on the daemon's reply to
the delayed write will wait until that next step.

## Alternatives considered

Threading `#(Model, List(Effect))` through every reducer was rejected. The
package is about 50,000 lines, and the change would alter hundreds of
signatures at once, conflict with every open branch that touches a reducer,
and add tuple construction and destructuring to the local transformation
chains whose compile time already had to be bounded. `docs/execution.md` §8
describes the Erlang inliner blow-up that `settle_update` and `settle_tick`
exist to prevent, and more local steps over the same expressions is the
shape that triggers it. Explicit threading would not change `step`'s public
shape, which is all a runtime or a test sees. If the outbox proves to be a
problem, it can be replaced by explicit threading later, one module at a
time.

Closures as effects were rejected because a test cannot inspect a closure and
a web runtime cannot reinterpret one.

Resolving an effect's target when it is performed, for example an effect
meaning "write this frame to the adopted socket", was rejected because an
adoption later in the same step changes which socket that is.

Converting every kind of I/O in one change was rejected. Mailbox drains, job
starts, clock reads and file reads return values that the rest of the step
uses. Moving them out of the reducer requires the runtime to deliver their
results as messages, which changes the event type. That work is phases 2 and
3.

## Consequences

`step` is pure for the effects phase 1 covers, and a replay or a test can
decide in one place what happens to them. The existing replay suppression,
socketless channels and the `Peer` branches, still exists and still does its
job during phase 1. It is deleted in phase 3, once the replay runtime drops
effects itself.

A send decided in the middle of a step now leaves at the end of the step, not
at the moment it was decided. A zero-timeout mailbox drain later in the same
step can therefore no longer observe the reply to that send. It never
reliably could: the reply crosses a socket and the daemon's own processing,
and a zero-timeout read racing it saw the reply only by chance. A
`session_channel.Sent` disposition now means the frame is queued on the
lane's socket and leaves when the step ends. Nothing later in the step
withdraws it, because reducers only append to the queues.

Every site that replaces or drops the adopted channel must call
`release_channel` first, and the compiler does not check this. The sites are
few (adoption and retirement of a channel), and a missed one loses that
channel's last writes or its close.

Tests that drive a channel or an attachment by hand against a live daemon
now perform its outputs themselves, as the runtime does.

## Later phases

Phase 2 moves incoming traffic and jobs to messages. The runtime selects on
the live inboxes and delivers their contents as messages, so `Tick` no longer
drains them. Job starts become effects carrying reducer-allocated keys, and
their replies come back as keyed messages, which removes the comparisons by
`Subject` identity. Clock readings and file reads become inputs or effect
results, and recording joins the ordered effect stream.

Phase 3 replaces etui's `InputEvent` with a domain `Msg` type in front of the
reducer and deletes the `Peer` branches that exist only to suppress effects.

Phase 4 extracts the platform-free client core behind the `Msg` and `Effect`
boundary and builds a spike of a Lustre server component in the daemon that
renders a read-only session view from it. What a second runtime means for the
daemon's surface is a separate decision.

Two correctness checks are under consideration and are not part of this
decision. Now that `session_channel` is pure, property-based tests can drive
it with generated sequences of frames, ticks and submissions and check its
invariants (one request on the wire, no resent mutation, per-socket output
order) without a socket. The attachment and mutation protocol spans the
terminal, the attachment worker and the daemon, and a small model of it in
TLA+/PlusCal or P could check the cross-process orderings that unit tests
cannot enumerate.

## Verification required

A test must pin that a scripted prompt yields exactly one `Transmit` from
`tui.step` and that the same script under replay yields none. Tests that
hold a live socket must flush or perform their channel outputs, and the
existing replay goldens and real-client fixtures must pass unchanged, since
`update` performs the same effects it did before, at the end of the step.
