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
  key drain (`tui/interaction.gleam:1224` (`drain_connection`)) and the tick
  (`tui/tick.gleam:131` (`drain_connection`)). The attachment's reads:
  `tui/attachment.gleam:496` (`prepare`),
  `tui/attachment.gleam:550` (`drain`) and
  `tui/attachment.gleam:609` (`settle`). The replay drain:
  `tui/tick.gleam:172` (`drain_replay`).
- **Left for S4 and S5.** The reconnect outcome
  (`tui/tick.gleam:129` (`drain_reconnect`)), the control reply
  (`tui/tick.gleam:127` (`drain_control`)), the picker's activity reply
  (`tui/session_control.gleam:930` (`drain_activity`)), and the session
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

## Addendum: phase 2 S3, recording joins the effect stream (2026-09-26)

The third slice of phase 2 takes the recording writes out of the step. It
settles the paragraph above that kept recording appends and attempt trace
notes synchronous in phase 1, and it replaces two mechanisms phase 1
introduced: the three queues `runtime.take` collected, and
`tui_model.release_channel`. What it means for the recording's bytes and
timestamps is in [ADR-009](009-record-terminal-attempt-custody.md), in its
addendum on recording as effects.

**Recording writes are effect values.** `tui.step` queues the input's line
through `tui_model.record_input` before the reducer runs, so it is the
first effect of its step. A line is `effect.Record(recorder, event)`. An
attempt event is `session_channel.Note(recorder, event)`, an output of the
lane that decided it, and the attachment queues its own failure note the
same way, as one of the lane's notes. `attempt.Trace`, a closure, is gone:
`recording.Trace` is the recorder handle and the attempt identity, as
data, and every note carries the recorder it was decided under.
`recording.append` is the perform half, and `session_channel.perform` and
`runtime.perform` call it.

**One queue.** The model outbox is the only queue a step has, and
`runtime.take` is its reversal. Two changes made that possible. Every
reducer that transitions the adopted lane stores the result through
`tui_model.hold_channel`, which moves the lane's queued outputs into the
outbox at that point: `inbound.tick_channel`, `inbound.handle_connection_message`,
`inbound.cancel_pending`, `inbound.service_history`, `inbound.request_decisions`,
`outbound.send_frame`, `submit.quit` and `interaction.retire_previous`, and
the adoption stores the `Adopted` note the same way after the cut. And
`attachment.poll` and `accept` move the candidate lane's outputs into the
list they return after each advance (`release`), so the candidate holds none
between calls and `attachment.take_outputs` is gone. Nothing is left on a
lane when a step ends, so `runtime.take` has nothing to collect from the
channels.

**`release_channel` is gone.** Phase 1 needed it because a lane kept its
outputs until the end of the step, and a reducer that replaced the lane
first had to move them out or lose them. Now they leave the lane when the
transition that decided them is stored, so replacing the lane later in the
step finds it empty. The rule moved rather than vanished: a site that
stores a lane without `hold_channel` strands its outputs where nothing
collects them, and the compiler does not check it. The retirement in an
adoption is the case with the most to lose, and
`an_adoption_queues_the_retired_lanes_close_before_the_adoption_test`
fails if `retire_previous` stores the retired lane directly: the old
socket's close and its `attempt_closed` disappear. The quit's lane close is
pinned by `effects_test` and by the golden recording.

**What the attachment keeps from a failed advance.** An advance that fails
part way through a poll returns the lane as it left it (`Broken`), and
`discard` keeps that lane's notes and drops its writes, then fails the
attempt from the status as it stood before the advance, whose `Abandon`
closes the socket once. That is what the terminal did when notes were
synchronous and writes were queued, and
`a_failing_replacement_keeps_its_notes_and_drops_its_writes_test` pins it.

**The effect list is in decision order.** Phase 1 returned the adopted
lane's outputs, then the candidate's, then the outbox. Now the list is the
order the step decided things in. For a socket nothing changes, since one
lane's outputs keep their order either way. Across resources the order
changes, and one site was reordered to keep the recording the same: a quit
queues the adopted lane's close ahead of the attempt's cancel, as the old
collection order had it, and the preview peer's close moves with it.

**Sites.** Every recording write, where it was and where it is:

| Write | Site | Before S3 | After S3 |
|---|---|---|---|
| input line | `tui.step` | `recording.note_input`, in the step | `tui_model.record_input`, the step's first effect |
| message with no lane | `inbound.handle_connection_message` | `recording.note_message`, in the step | `tui_model.record`, an `effect.Record` |
| `attempt_started` | `session_channel.start_recorded`, `start_resumed` | trace callback | `Note`, ahead of the subscribe |
| `attempt_requested` | `session_channel.emit` | trace callback | `Note`, ahead of its `Transmit` |
| `attempt_frame` and the lifecycle messages | `session_channel.receive` | trace callback | `Note`, ahead of anything the message queues |
| `attempt_closed` of a lane the step closes | `session_channel.close`, through `fail`, `retire` and quit | trace callback | `Note`, ahead of its `Shut` |
| `attempt_adopted` | `session_channel.adopted`, from `interaction.candidate_outcome` | trace callback | `Note`, stored after the cut |
| `attempt_failed` | `attachment.failed` | trace callback | a `Note` in `attachment.FromChannel`, ahead of `Abandon` |
| `attempt_closed` of an abandoned attempt | `attachment.cancel`, performing `Abandon` | after the step, after every other line | after the step, at the `Abandon`'s place |
| the format header | `recording.start`, from `tui.open_recording` | at launch, before the loop | unchanged |
| the teardown close in the client test driver | `tui_driver.disconnect` | outside the loop | unchanged, performed through `session_channel.perform` |

`recording.trace`, in `tui.open_recording` and `session_control`'s open
and create, binds a recorder to an attempt and writes nothing.

**Replay.** A replay queues no recording effect, as it wrote nothing
before, and for the same two reasons: `loom replay` opens no recorder, so
`Model.recorder` is `None`, and replay lanes are `session_channel.replay`
lanes with no trace. `replaying_a_recording_queues_no_recording_effect_test`
steps the golden recording through the shipped step and checks it.

**Callers outside `update`.** `runtime.flush` now empties only the outbox,
so a caller that builds a lane and puts it on a model stores it through
`tui_model.hold_channel` before flushing (the live `tui_v2_test` does). A
bare channel is still drained with `take_outputs` and `perform`, and its
notes are among the outputs. A caller polling a bare attachment performs
what `poll` returns, which now includes the lane's outputs
(`bootstrap_test`). Tests that watched a lane through a trace closure
either read the `Note` outputs (`session_pushed_test`) or pass
`recording.observed(subject)`, a test-only recorder that sends each
event to a subject when the runtime performs it (`queue_editor_test`,
`tui_v2_test`). The client test driver needed no change: it reduces
selected messages through `inbound.accept_connection_message`, which
queues their notes, and the next step performs them.

**Model.** The protocol model does not model recording, and it keeps
phase 1's three-queue collection in `finishStep`. Its README now says why
every spec reads the same under the one queue: within one socket both
orders are the lane's, both put a candidate's lane outputs ahead of its
`Abandon`, and both put a quitting lane's close ahead of the attempt's
cancel. The Terminal machine is still one reducer step followed by a
separate effect step. `p check -tc tcReplace -s 30000` found no bug.

**Compile time.** `record_input` and `hold_channel` are cross-module calls,
and the step's new first statement applies to its parameter, so the slice
adds no local step for the inliner to revisit (`docs/execution.md` §8).
Measured with `erlc +time` on the generated modules before and after, wall
time and `core_inline_module` moved by less than the run-to-run noise:
`tui` 0.55 s and 0.024 s before, 0.53 s and 0.024 s after; `tui@tick` 0.53 s
and 0.022 s, 0.54 s and 0.021 s; `tui@inbound` 2.63 s and 0.133 s, 2.50 s
and 0.128 s; `tui@interaction` 2.59 s and 0.189 s, 2.56 s and 0.172 s;
`tui@runtime` 0.26 s and 0.007 s, 0.26 s and 0.007 s; `tui@recording`
0.25 s and 0.008 s, unchanged; `tui@attachment` 0.25 s and 0.008 s, 0.26 s
and 0.009 s; `tui@session_channel` 0.37 s and 0.018 s, unchanged.

## Addendum: phase 2 S4, jobs as data (2026-09-26)

The fourth slice of phase 2 takes the daemon control job, the relaunch
after a daemon death and the session picker's activity poll out of the
step. It carries out, for those three jobs, the line under "Later phases"
that job starts become effects carrying reducer-allocated keys. The
session switch and the attachment attempt follow in S5. Nothing above is
changed by it.

**Jobs are effect values.** A reducer allocates a `job.Key` from
`Model.next_job`, a counter that never reuses a key, and queues
`effect.StartJob(key, spec)` through `tui_model.start_job`. The slot that
waits for the job holds the key. `job.Spec` is data:
`Control(host, request)`, where `job.ControlJob` has one variant for each
of the seven requests the picker and the peer manager make (`LoadPage`,
`Rename`, `Remove`, `LoadPeerWorkspace`, `InspectPeers`,
`LoadPeerSessions`, `MutatePeers`); `Reconnect(options)`; and
`Activity(host, ids)`. The worker bodies moved from the reducers into the
new `tui/job_runner`, which the runtime calls to turn a spec into a
one-task weft run. The old workers were closures built in the reducer,
and each had a comment about binding scalars outside the closure so that
weft would not copy the whole model into the task. A spec variant cannot
capture the model at all, so those comments are gone with the closures.
`effect.CancelJob(key)` replaces `CancelTask(signal)`.

**The key is the handle.** Phase 1 ruled that every effect carries the
handle it acts on and that the runtime never looks a target up in the
model, because an adoption or a quit changes the model's handles during a
step and a lookup at perform time could find the new one. `CancelJob`
carries a key and the runtime looks the key up, but not in anything a
reducer writes: the table is the runtime's own, and a key is never
reused, so it names at perform time the same job it named when the
reducer decided. The ruling's concern cannot arise.

**Where the handles live.** `Model.running` holds the runtime's table,
`job_runner.Running`, which maps each key to the job's cancel signal and
a selector over its reply subject that tags each reply with the key. The
type is opaque and no reducer imports `job_runner`; `tui/model` names the
type and `tui/runtime` is its only caller. `runtime.perform(effects,
running)` now threads the table through the effects in order and returns
it, and `runtime.settle` performs a step's effects and stores the table on
the model the step returned, so `tui.update` is
`settle(step(event, receive(stamp(model))))` and `runtime.flush` is
`settle(take(model))`. Two alternatives were rejected. Having `perform`
return each new job's handles for the runtime to write into the reducers'
slots would put Subjects and Cancels back into types the reducers read,
which is what this slice removes. A separate registry process holding the
table would own the reply subjects in another process, and the terminal
would have to ask it for replies by message, a cross-process protocol
where a field is enough. The loop keeps no state beside the model, so the
table is on the model.

**How replies reach a reducer.** `runtime.receive` reads every message
every running job has sent. A one-task run's relay sends at most two, its
outcome and then `AllDelivered` or `RunLost`, so this is bounded without a
per-job cap. Each goes to `runtime.hold`, which removes the job from the
table once its last message has been read, then admits the reply into the
slot of its kind when that slot holds the reply's key, and drops it
otherwise. The replies live inside the slot (`job.Awaiting`), as S2 put
received messages inside an inbox value, so a reducer that clears or
replaces a slot drops what it held, and no reply can reach a slot that
stopped waiting for it. The drains take from the slot at the points they
took from the mailbox: the tick's `drain_reconnect` and `drain_control`
became `session_control.drain_reconnect` and `drain_control`, beside
`drain_activity`, and `update_tick` calls all three where it called them
before (`tui/tick.gleam:127` (`drain_control`)). `accept_control_event`,
`accept_reconnect_event`, `ControlEvent` and `ReconnectEvent` are gone,
and so are the two comparisons of subjects they made. In the shipped loop
neither comparison could fail, because the tick only ever read the
subject the slot named; a stale reply could reach a reducer only through
the client test driver.

**Orderings kept.**

- *Quit.* It still queues the adopted lane's close, the session switch's
  cancel and the attempt's `Abandon` first, in that order. Then it queues
  `CancelJob` for the control job and the relaunch, in the order their
  `CancelTask`s had, then for the activity poll, which had no cancel
  signal and used to run on to its own nine-second deadline, and then the
  control close. It clears each job's slot in the same step. The cancels
  that block at quit are the switch's and the attempt's, which this slice
  does not touch; the job cancels were `weft.cancel` before and are now,
  and do not block. `effects_test` pins the list.
- *A cancelled job delivers nothing.* The reducer clears the slot in the
  step that queues the cancel, so `hold` finds no slot with that key. The
  runner keeps the job in its table until its relay's last message, so
  the cancelled outcome is read and dropped rather than left in the
  mailbox.
- *Tick drain order.* The replay, strip, session switch, control,
  candidate, relaunch, activity and connection drains run in the order
  they did.
- *Same process.* The runtime performs `StartJob` inside `update`, in the
  process that created the model, so each reply subject belongs to the
  process whose `receive` reads it. The launch paths, `tui.connect_remote`
  and `attach_daemon`, flush the `StartJob` their first catalogue load
  queues, so that job still starts before the loop does. A job now starts
  at the end of the step that asked for it instead of during it; nothing
  later in that step could have read its reply.

**Two leaks, fixed.** The survey for this slice found two places where a
job's reply went unread.

- A spent reconnect left a message in the terminal's mailbox for the life
  of the process. The tick read the relaunch's subject only while the
  attempt was `ReconnectAttempting`, and the attempt's outcome makes it
  `ReconnectSpent`, so the relay's `AllDelivered` that follows was never
  received, and every later selective receive scanned past it. The
  runner now reads every job to its last message whatever its slot
  holds. `a_spent_reconnect_leaves_nothing_in_the_mailbox_test` runs a
  terminal in a process of its own whose relaunch slot is spent while its
  relay is still sending, ticks it until its job table is empty, and
  asserts an empty mailbox. The same scenario written against the old
  API at the commit S4 started from left one message in the mailbox and
  failed.
- The client test driver selected only the control job's subject. An
  actor discards a message its selector does not match, so a relaunch or
  activity reply that arrived while the driver waited between scripts was
  lost. The driver now selects `job_runner.selector(model.running)`, every
  running job's replies, and hands each to `runtime.hold`, where a reply
  the runtime received also goes.

**Callers outside `update`.** A test that stands a slot in for a running
job allocates its key with `tui_model.allocate_job`, gives it replies with
`runtime.hold`, and calls the drain or `step`. A test that performs
effects passes a table to `runtime.perform` and gets one back, and
`runtime.no_jobs()` is an empty one. A test that needs a real worker
starts one with `job_runner.start_task`, which takes the work as a
function; `job_runner.start` is that function applied to a spec. A test
that waits for a real reply selects on `job_runner.selector`.

**What the step still does itself.** It starts the local session switch
(`sessions.start`) and the attachment attempt (`attachment.start_recorded`)
and pulls the switch's run, which S5 moves. Adoption calls
`connection.adopt` (`tui/inbound.gleam:971` (`connection.adopt`),
`tui/attachment.gleam:657` (`connection.adopt`)), which creates nothing
but reads whether the replacement socket's actor is alive. That read
stays in the step until phase 3, which replaces etui's events with a
domain message type; the runtime can then read the liveness when it
delivers the message that carries the socket, and hand the answer to the
reducer with it.

**Sites.**

| Job | Start, before | Start, after | Reply read, before | Reply read, after |
|---|---|---|---|---|
| control, seven kinds | seven closures in `session_control`, each with its own `cancel_signal`, `new_subject` and `start_relayed` | `session_control.start_control` queues `StartJob(key, Control(host, request))` | `tick.drain_control`, `process.receive` on the slot's subject | `runtime.hold` admits into `ControlRequest.job`; `session_control.drain_control` takes |
| relaunch | `inbound.begin_reconnect` spawned the relay | `inbound.begin_reconnect` queues `StartJob(key, Reconnect(options))` | `tick.drain_reconnect` | `runtime.hold` admits into `ReconnectAttempting`; `session_control.drain_reconnect` takes |
| activity poll | `session_control.start_activity` spawned the relay, with no cancel | `session_control.start_activity` queues `StartJob(key, Activity(host, ids))` | `session_control.drain_activity`, `process.receive` | `runtime.hold` admits into `ActivityAsking`; `drain_activity` takes |
| quit's cancels | `CancelTask(run.cancel)` and `CancelTask(cancel)` | `CancelJob(key)` for all three jobs, slots cleared | | |

**Tests and mutations.** `jobs_test` pins the slice: a picker key queues
exactly one `StartJob` under the key its slot holds and the step starts
nothing; a reply under another key is not admitted; a late message from an
earlier job does not finish the job that took its slot; a quit cancels a
running job before it answers and nothing it sends reaches a slot; the
spent reconnect above; and one tick takes the control reply before the
relaunch's. Each mutation below was applied alone, and the named tests
failed; each was then reverted.

| Mutation | Tests that failed |
|---|---|
| `job.admit` admits a reply under any key | `a_reply_for_another_key_is_not_admitted_test`, `a_late_reply_from_an_earlier_job_does_not_reach_its_successor_test`, `reconnect_test.a_reply_for_another_attempt_is_not_admitted_test` |
| `job.allocate` hands out the same key every time | the same three |
| `job_runner.cancel` cancels a new signal instead of the job's | `a_cancelled_job_never_delivers_a_reply_test` |
| quit cancels the relaunch before the control job | `effects_test.quit_with_a_channel_queues_every_close_and_cancel_test` |
| the tick drains the relaunch before the control job | `a_tick_drains_the_jobs_in_their_fixed_order_test` |
| `runtime.receive` stops reading jobs once no slot waits | `a_spent_reconnect_leaves_nothing_in_the_mailbox_test` |

**Compile time.** The drains the tick now calls are cross-module calls,
and `update` applies `settle` to the step's result, so the slice adds no
local step for the inliner to revisit (`docs/execution.md` §8). Measured
with `erlc +time` on the generated modules, median of three, before and
after: `tui` 0.46 s and 0.022 s before, 0.47 s and 0.023 s after;
`tui@tick` 0.47 s and 0.020 s, 0.47 s and 0.021 s; `tui@session_control`
0.92 s and 0.061 s, 0.91 s and 0.059 s; `tui@inbound` 2.46 s and 0.126 s,
2.53 s and 0.128 s; `tui@interaction` 2.48 s and 0.165 s, 2.56 s and
0.168 s; `tui@submit` 1.17 s and 0.058 s, 1.25 s and 0.059 s; `tui@model`
0.32 s and 0.012 s, 0.32 s and 0.013 s. `tui@runtime` grew with the
routing it now does, from 0.21 s and 0.006 s to 0.33 s and 0.012 s. The
new `tui@job` compiles in 0.15 s and `tui@job_runner` in 0.17 s.
