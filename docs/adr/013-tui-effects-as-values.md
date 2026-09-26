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

## Addendum: protocol model

The second correctness check named under "Later phases" now exists as a P
model in `protocol/models/terminal-attachment/`, written before phase 2 moves
mailbox drains into the runtime. It models the terminal as a reducer step
followed by a separate perform step, the attachment worker, and each socket
together with the daemon's gateway handler for it, with the network, the
attempt deadline and the operator as the environment. Its README maps each
machine and event to the Gleam functions it stands for.

The model checks, over 30,000 random schedules per test case, that
replacement is fail-preserving (the visible session changes only after a
validated cut, a completed worker and a passed adoption check); that no
message from a replaced socket is reduced into the adopted lane; that a
mutation is written and applied at most once, a lost reply becomes
`UnknownOutcome` exactly once, and a waiting command is sent or reported
`DefinitelyNotSent` exactly once on its own attachment; that nothing is
written to a socket after the terminal closes it and no socket is closed
twice; that a worker which published `Prepared` is never left waiting; that
quit releases every socket and worker; and that one request at a time owns
each socket. Its invariants pair one for one with the property tests over
`session_channel` from PR #536, and the rules that live inside one reducer are
left to those tests. A mutation script in the model directory reintroduces
seventeen changes one at a time. The thirteen that break a rule are each
caught by the spec for that rule. The README explains the other four: three
break no rule, and one leaves only a duplicate update that the property
tests check.

The model reproduced one bug in the shipped code: a lane that had already
failed closed its socket a second time, on quit or on a second report of the
same transport loss. The property tests found the same bug, and PR #536
fixed it.

The model also settles what phase 2 must preserve about the old inbox. The
rule is that no message from the old inbox reaches the reducer after the
swap. Whether the old inbox is also flushed afterwards does not matter for
correctness; the `Discard` only frees memory. The runtime that phase 2
introduces must stop delivering from a replaced inbox at the swap.

## Addendum: phase 2 S1, the clock becomes an input (2026-09-26)

The first slice of phase 2 takes clock reads out of the step. Nothing above
is changed by it; this records how the step now gets the time.

`tui.update` calls `runtime.stamp` before `step`. It reads the presentation
clock (`Model.monotonic_time_ms`), the transport clock
(`Model.transport_time_ms`) and the wall clock once each and stores them on
the model as `Model.stamp`, and every reducer that read a clock reads the
stamp instead. A step therefore reads no
clock, and every reducer in one step sees the same instant. The OS and BEAM
process identity in a session creation key is read once, when the model is
created, and held as `Model.terminal`. The stamp is a call into
`tui/runtime` applied to `update`'s parameter rather than a local step in
`tui.gleam`, so it does not add to the inliner cost `docs/execution.md` §8
describes; `core_inline_module` on the generated `tui` and `tui@tick`
modules measured the same before and after.

`tui/session_channel` no longer stores a clock. Every transition that sets
or checks a deadline or the idle refresh takes `now` as a parameter. The
terminal passes the stamp's transport reading rather than the presentation
clock, because a test driver fixes the presentation clock to pin frames
while its live socket still needs real deadlines. The transport clock is
the host's monotonic clock in the shipped client, which is the clock the
lane used before, and it is injected on the model like the presentation
clock. That matters for tests: a replay lane's time starts at zero, and a
fixture that puts one on a model freezes the transport clock at zero too.
Read from the host instead, the lane's refresh would stay quiet only
because ERTS starts its monotonic clock at a large negative value, which
is not something a test should depend on. `tui/attempt_replay` passes zero,
which is what its stored clock returned.

Two cases are the caller's to handle. A test that calls `step` directly runs
at whatever stamp the model carries, which for a fresh model is the reading
taken when it was created, and sets the field to choose another time. A
caller that runs a reducer outside `update`, such as a test driver handing a
selected socket message to `inbound.accept_connection_message`, calls
`runtime.stamp` first, or the reducer runs at the time of the previous event.

Recording timestamps and the launch, bootstrap and daemon waits stay on the
real clock. They are outside the step: the recording is S3's subject, and
the waits run before the loop or in their own processes.

## Addendum: phase 2 S2, the runtime receives (2026-09-26)

The second slice of phase 2 takes the connection, replay and attachment
mailbox reads out of the step. Nothing above is changed by it; this records
how the step now gets its traffic.

`tui.update` is `step(event, runtime.receive(runtime.stamp(model)))`
followed by `perform`. `runtime.receive` tops up every inbox the model holds
from its mailbox, and the reducers take from those buffers exactly where they
used to call `process.receive(subject, 0)`: `inbound.drain_connection`,
`tick.drain_replay`, and the attachment's `prepare`, `drain` and `settle`.
Etui's tick and key events are still the points where traffic is delivered,
and every ordering that lived in the step is unchanged, because it is still
the step that decides when to take. Escape with a waiting command still
cancels before any traffic is reduced (ADR-010), and the batch the runtime
received for that event stays held. The fixed drain order in
`tick.update_tick` still settles the candidate before it drains the
connection. An adoption in the middle of a tick still swaps the inbox before
the connection drain, which then reads the adopted inbox. `models(1)` is
still sent after `apply_cut`, and quit still blocks on the candidate's
cancel.

The buffers live inside the inbox values. `tui/buffered.Inbox(a)` holds the
subject and the messages already received from it, oldest first. `Model.inbox`, `Model.replay_inbox` and the candidate's `prepared`,
`frames` and `outcomes` are `Inbox` values, and `attachment.Adopted.inbox`
carries the frames inbox together with the frames the candidate received and
left for the adopted lane. The protocol-model addendum above states the rule
this slice had to keep: no message from a replaced inbox reaches the reducer
after the swap. With the buffer inside the inbox, the swap in
`interaction.candidate_outcome` is one assignment of a whole value. The old
inbox leaves the model together with everything it had received, and there
is no second place a stale buffer could outlive it, so a stale delivery
cannot be expressed rather than being prevented by a check. A test that
carries the old buffer across the swap sees three commit notices reach the
adopted lane instead of one. The other half is that `attachment.adopt`
hands the frames inbox on with what the candidate held after its capture;
a test that plays the worker sees both notices held past the capture
reduced by the adopted lane, and none if the adoption starts a fresh
inbox.

A message leaves the mailbox exactly once, so whatever an inbox holds is
older than anything still in its mailbox. Code outside the step that waits
on an inbox therefore reads it through `buffered.receive`, which returns the
held head first and only then waits on the mailbox. `attachment.cancel`,
which runs as an effect, reads a `Prepared` that way, so a socket the runtime
already received is still closed at quit. A test driver that selects on the
mailboxes cannot see the held messages, so the client driver reduces the
held connection messages before a selected one. `attachment.accept` uses
`buffered.push`, which appends the selected message behind the held ones
(its place, since it is newer than all of them), and then advances exactly
as the poll does: frames are drained up to the capture, outcomes are settled
in order, and a `Prepared` is taken by `prepare`. A selected frame and a
held one therefore meet the same rule: before the capture the candidate
reduces it, after the capture it stays in the inbox for the adopted lane. A
frame selected once the candidate has already captured is still dropped,
because nothing would bound what a driver held while the attempt waits for
its worker, and the adopted lane's credited catch-up recovers it. `buffered.sender` is the send side; reading from it bypasses the
buffer, and tests use it only to inject messages.

Each top-up is bounded by what the step can consume, so nothing buffers
without limit:

| Inbox | Fills to | When |
|---|---|---|
| `Model.inbox` | 64 (`connection_batch`, the drain cap) | every event |
| `Model.replay_inbox` | 1 | every event |
| candidate `prepared` | 1 | only while there is no candidate |
| candidate `frames` | 40 (the poll's batch) | until the initial cut is captured |
| candidate `outcomes` | 1 | every event |

An inbox the step did not drain already holds its bound and reads nothing
more. Frames are topped up before a candidate exists, as well as after,
because the old poll read the frames mailbox in the same tick that it took
the `Prepared`; without that the first frames would wait one tick longer.

Two cases are the caller's to handle. A test that calls `step` directly and
expects it to see queued traffic calls `runtime.receive` first, as it calls
`runtime.stamp` to choose the time. And `update` now reads mailboxes on
every event, including a resize, so it must run in the process that created
the model's subjects. One test broke on this: the stream-bounds holder built
its model in the test process and called `update` from an actor. It now
builds the model in the actor's initialiser.

The survey of mailbox reads, at the commit this slice started from:

- **Moved into the runtime by this slice.** `inbound.drain_connection`,
  which read through `connection.receive`, and the four places that call it:
  the wheel and drag arms of `apply_input`
  (`packages/tui/src/tui.gleam:1481`, `packages/tui/src/tui.gleam:1501`), the
  key drain (`tui/interaction.gleam:1218` (`drain_connection`)) and the tick
  (`tui/tick.gleam:160` (`drain_connection`)). The attachment's reads:
  `tui/attachment.gleam:484` (`prepare`),
  `tui/attachment.gleam:538` (`drain`) and
  `tui/attachment.gleam:594` (`settle`). The replay drain:
  `tui/tick.gleam:201` (`drain_replay`).
- **Left for S4 and S5.** The reconnect outcome
  (`tui/tick.gleam:46` (`drain_reconnect`)), the control reply
  (`tui/tick.gleam:61` (`drain_control`)), the picker's activity reply
  (`tui/session_control.gleam:1163` (`drain_activity`)), and the session
  switch, which reads through `sessions.receive` and `weft.pull`
  (`tui/sessions.gleam:256` (`weft.pull`)). Each answers a job the step
  started, and they move when job starts become keyed effects.
- **Outside the step, and staying there.** The worker's acknowledgement wait
  (`tui/attachment.gleam:202` (`acknowledged`)) runs in the worker, and
  `attachment.cancel` (`tui/attachment.gleam:758` (`buffered.receive`)) runs
  as an effect. `sessions.discard` (`tui/sessions.gleam:328`
  (`discard_up_to`)) is the `Discard` effect. The bootstrap snapshot wait
  (`tui/bootstrap.gleam:1355` (`await_snapshot`)) runs before the loop, the
  daemon control handshake in `tui/daemon.gleam` runs in its own process, and
  the virtual backend's frame collection (`tui/virtual_backend.gleam:315`
  (`drain`)) is test infrastructure outside the model.

`buffered` and the new `runtime.receive` are cross-module calls on
`update`'s parameter, so this slice adds no local step for the inliner to
revisit (`docs/execution.md` §8). Measured with `erlc +time` on the
generated modules, before and after, wall time and `core_inline_module`
moved by less than the run-to-run noise: `tui` 0.49 s and 0.023 s before,
0.52 s and 0.024 s after; `tui@tick` 0.52 s and 0.020 s, 0.53 s and 0.022 s;
`tui@attachment` 0.25 s and 0.008 s, unchanged; `tui@inbound` 2.56 s and
0.137 s, 2.59 s and 0.133 s; `tui@interaction` 2.55 s and 0.169 s, 2.52 s
and 0.167 s; `tui@runtime` 0.26 s and 0.007 s, unchanged. The new
`tui@buffered` compiles in 0.20 s.
