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
  (`packages/tui/src/tui.gleam:1500`, `packages/tui/src/tui.gleam:1520`), the
  key drain (`tui/interaction.gleam:1725` (`drain_connection`)) and the tick
  (`tui/tick.gleam:146` (`drain_connection`)). The attachment's reads:
  `tui/attachment.gleam:492` (`prepare`),
  `tui/attachment.gleam:537` (`drain`) and
  `tui/attachment.gleam:597` (`settle`). The replay drain:
  `tui/tick.gleam:223` (`drain_replay`).
- **Left for S4 and S5.** The reconnect outcome
  (`tui/tick.gleam:143` (`drain_reconnect`)), the control reply
  (`tui/tick.gleam:142` (`drain_control`)), the picker's activity reply
  (`tui/session_control.gleam:1368` (`drain_activity`)), and the session
  switch, which read through `sessions.receive` and `weft.pull` in
  `tui/sessions`, a module S5 deleted with the unreachable local switch.
  Each answers a job the step started, and they move when job starts
  become keyed effects.
- **Outside the step, and staying there.** The worker's acknowledgement wait,
  now in the runner (`tui/job_runner.gleam:614` (`acknowledged`)), runs in
  the worker, and `attachment.cancel` runs as an effect; since S5 it reads
  no mailbox, and the attachment job's cancel drains the job's messages
  instead (`tui/job_runner.gleam:426` (`drain`)). `sessions.discard`, now `buffered.discard`, is the
  `Discard` effect. The bootstrap snapshot wait
  (`tui/bootstrap.gleam:1246` (`await_snapshot`)) runs before the loop, the
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
before (`tui/tick.gleam:142` (`drain_control`)). `accept_control_event`,
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
- *An adoption cancels a relaunch in flight.* An adopted attachment proves
  the daemon answers, so the step that adopts queues `CancelJob` for a
  relaunch still running, and then clears the slot. Before this slice the
  adoption only cleared the slot, which left the relaunch free to take the
  launch lock and start a second daemon; with its replies read by key, that
  cost was invisible rather than absent.
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
`job_runner.new()` is an empty one. A test that needs a real worker
starts one with `job_runner.start_task`, which takes the work as a
function; `job_runner.start` is that function applied to a spec. A test
that waits for a real reply selects on `job_runner.selector`.

**What the step still does itself.** It starts the local session switch
(`sessions.start`) and the attachment attempt (`attachment.start_recorded`)
and pulls the switch's run, which S5 moves. Adoption calls
`connection.adopt` (in the local switch's adoption, which S5 deleted, and
in the attachment's; phase 3 moved the call to
`tui/runtime.gleam:309` (`connection.adopt`)), which creates nothing but
reads whether the replacement socket's actor is alive. That read
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
| adoption clears the relaunch slot without cancelling it | `an_adoption_cancels_a_relaunch_still_in_flight_test` |

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

## Addendum: phase 2 S5, attachment jobs as data, and the local switch removed (2026-09-26)

The fifth slice of phase 2 makes the provisional attachment a keyed job,
the last job the step still started itself, and deletes the local session
switch, which the slice would otherwise have converted. Nothing above is
changed by it; the S2 and S4 surveys' citations move to where their symbols
now are, and name the deleted module where one no longer exists.

**The local switch was unreachable, and is gone.** `submit.open_legacy_session_selector`
was the only way into the `SessionSelector` overlay, whose Enter started the
`tui/sessions` worker that the tick pulled and
`inbound.handle_session_switch_message` adopted. Nothing called it: it has
had no caller in `packages/tui` or `packages/client` since `c12d22eb`
renamed it from `open_session_selector` and pointed `/sessions` at daemon
control. The deletion removes the overlay and its exhaustive arms,
`Model.session_switch`, the tick's switch drain, the switch message handler
and its adoption, `effect.CancelSessionSwitch`, `tui/sessions`, and the
record-based discovery in `tui/bootstrap` that fed it, 1,102 lines of
source and 1,509 in all. `sessions.discard`, the one live piece, is now
`buffered.discard`.

**The attachment is a job.** Opening or creating a session allocates a key
and queues `StartJob(key, job.Attach(route, within_ms))`, where
`job.AttachRoute` is `OpenSession(host, session)` or `CreateSession(host,
key, workspace, name, config)`. The candidate is `attachment.opening(key,
trace)`, which records the key and starts nothing. `job_runner.start_attach`
creates the frames subject, the `Prepared` subject and the relay's subject in
the terminal's process when the runtime performs the start, and the worker
connects its socket to the frames subject and names it in the `job.Prepared`
it publishes. The candidate learns its frames inbox from that `Prepared` and
from nowhere else, so the step creates no subject. The job's messages,
`job.Published(prepared)` and `job.Settled(reply)`, arrive tagged with the
key as `job.AttachArrived`, and `runtime.hold` admits them through
`attachment.admit`, which takes them only under the candidate's key and
takes one `Prepared` per attempt. The source-subject comparisons in
`attachment.accept`, the `Event` type that carried the sources, and the
`CloseStray` output are gone; `accept` now takes a frame a test driver
selected from the frames inbox, and `select` offers only that inbox, since
the driver selects the job's own messages through `job_runner.selector`.
`daemon_selection.Target`, which moved from `tui/attachment`, is what the
worker resolves; the move breaks the import cycle a keyed attachment would
otherwise close, since `tui/job` imports `tui/daemon/selection`.

The status is a stage. It is `Resolving` until its `Prepared` is admitted,
`Published` until the next poll starts the candidate lane on the socket, and
`Connecting` while the lane captures its cut. Each holds only what exists at
that point, so a lane without a frames inbox, or a frames inbox without the
socket that feeds it, cannot be expressed.

**A dropped `Prepared` has its socket closed.** A `Prepared` no attempt
admits, because no attempt holds its key or the attempt already took one,
carries an open socket nobody else will close on the terminal's behalf.
`runtime.hold` queues `CloseSocket` for it and then `Discard` of the frames
subject it names, and the runtime performs them after the next step, so
`receive` and `hold` only read mailboxes. A relaunch's `Completed(host)` is
the other reply that holds a resource: its control connection. When its
slot has moved on, as an adoption leaves it after cancelling a relaunch
still in flight, `hold` queues `CloseControl` for it. Every other drop is
only forgotten. `job_runner.cancel` on an attachment job cancels the worker
and then drains the job's messages without waiting, releasing what it finds
through `job_runner.dropped`, which does the same closes directly because
it runs at perform time, and empties the frames subject; that is the
bounded drain quit had before. Neither close is what finally guarantees a
socket goes down, and nothing orders the worker's `Prepared` against the
relay's messages, which come from another process; `weft.cancel` kills
asynchronously. A worker that exits without an acknowledgement has either
closed its socket itself, when its wait ran out, or been killed, and then
the socket's guardian closes it. If a `Prepared` arrives after the runner
has forgotten the job, the cost is one message left in the mailbox.

**Cancel and cleanup are two effects.** `attachment.cancel`, which
performs `Abandon`, now closes only what the status holds: an admitted
`Prepared`'s socket, or the lane with its recorded close, and the frames
inbox. Stopping the worker is the job cancel's part.
`tui_model.emit_attachment` queues every attachment output, and puts a
`CancelJob` for the attempt's key ahead of each `Abandon`, so a failed
attempt and a quit both cancel the job before the cleanup.

**Orderings kept.**

- *Quit.* The lane close, then `CancelJob` for the attempt and its
  `Abandon`, then the control job, relaunch and activity poll cancels, then
  the control close. The recording still notes the adopted lane's close
  ahead of the attempt's, and the attempt's recorded close still lands at
  the `Abandon`'s place. `effects_test` pins the list with an attempt in
  flight.
- *Nothing after a cancel.* Quit and failure clear the candidate in the
  step that queues the cancel, so nothing the job sends afterwards is
  admitted, and a late `Prepared` is closed.
- *The frames arrive with the `Prepared`.* `runtime.receive` now admits job
  messages before it tops up the inboxes, so a `Prepared` admitted in one
  receive has its first frames topped up in the same receive, as the old
  poll read the frames mailbox in the tick that took the `Prepared`.
- *Tick drain order.* Unchanged, less the deleted switch drain.
- *Same process.* The subjects are created while the runtime performs the
  start inside `update`, in the process that created the model.

**What the step still does itself.** It reads files, which a later slice
moves, and adoption still calls `connection.adopt` (phase 3 moved the
call to `tui/runtime.gleam:309` (`connection.adopt`)), which creates
nothing but reads whether the socket's actor is alive. That read stays until phase 3,
when the runtime can read the liveness as it delivers the message that
carries the socket and hand the answer to the reducer.

**The client test driver.** It selects the candidate's frames through
`attachment.select` and everything else through the job selector. An actor
discards a message its selector does not match, and the frames inbox is
known only once its `Prepared` has been admitted, so a frame that reaches
the driver's actor before that is discarded. That is usually `Connected`,
which the lane ignores; a gateway that refuses after the upgrade can send
`Closed` or `NetworkFault` first, and the driver's lane then fails at its
deadline rather than at once. The shipped loop selects nothing and loses
nothing: frames wait in the mailbox for the top-up. For the same reason
`attachment.accept` holds a frame the driver selected before the lane
exists or after the capture, where it used to drop it, since the actor
would otherwise discard what the shipped loop leaves in the mailbox for the
adopted lane; the adoption hands the held frames over with the inbox.

**Tests and mutations.** `attachment_jobs_test` pins the slice: opening a
session queues exactly one `StartJob(key, job.Attach(..))` and starts
nothing; frames sent before the `Prepared` is admitted are not reduced, and
the tick after it captures from them and acknowledges; a stale `Prepared`, a
`Prepared` with no attempt at all, and a second one for the same attempt
each have their socket closed; after a quit nothing the cancelled job sends
reaches an attempt; and a failed attempt cancels its job ahead of its
cleanup. The S2 swap regression and the adoption hand-over test
(`runtime_receive_test`) and the adoption recording tests
(`recording_effects_test`) now hand the attempt its `Prepared` with
`runtime.hold`, which retires `runtime_receive_test_ffi`, and pass. Each
mutation below was applied alone and reverted.

| Mutation | Tests that failed |
|---|---|
| `job_runner.dropped` leaves the socket open | `a_stale_prepared_has_its_socket_closed_test`, `a_second_prepared_for_the_same_attempt_is_closed_test`, `an_arrival_for_a_cancelled_attach_key_is_never_delivered_test` |
| `job_runner.dropped` leaves the frames subject full | `a_stale_prepared_has_its_socket_closed_test` |
| `attachment.admit` takes a `Prepared` under any key | `a_stale_prepared_has_its_socket_closed_test` |
| `attachment.admit` takes a second `Prepared` | `a_second_prepared_for_the_same_attempt_is_closed_test` |
| `emit_attachment` queues `Abandon` without `CancelJob` | `an_arrival_for_a_cancelled_attach_key_is_never_delivered_test`, `a_failed_attempt_cancels_its_job_ahead_of_its_cleanup_test`, `effects_test.quit_with_a_channel_queues_every_close_and_cancel_test` |
| `runtime.receive` tops up before it admits | none |

The last is not caught, and breaks no rule: a `Prepared` admitted after the
top-up has its first frames read one tick later. Catching it needs a
`Prepared` that arrives through a real job in the same receive, which only a
live socket produces.

**Model.** The P model's `AttachmentWorker` now stands for the worker
`job_runner.start_attach` runs, and the terminal's step no longer creates
it: `beginOpen` queues `EFF_START`, and performing it creates the frames
inbox and the worker and records the worker under the key. `ePrepared` and
`eOutcome` carry the key, the candidate admits them under its own key, and
the model drops anything else, closing a dropped `Prepared`'s socket and
announcing `ePreparedDropped`. A new liveness spec, S8
`DroppedPreparedClosed`, requires that close; S6 cannot see it, because the
worker's cancellation also brings the socket down through its guardian.
A new probe finds a dropped `Prepared` within 76 schedules. All ten
test cases pass at 30,000 schedules each, the ten probes find their
witnesses, and the full mutation table gives the same verdicts as before.
One report changed: M8 in `tcQuitLate` is now named by S6 rather than S5;
both are hot at the end of that run, and the checker names one. Two
mutations are new. M18 drops a `Prepared` without closing it and only S8
catches it, in 80 schedules. M19 queues an `Abandon` without its
`CancelJob`, and S5 and S6 catch it in 2. The model's README has the
table.

**Compile time.** No local step was added to the modules the inliner
revisits (`docs/execution.md` §8). Measured with `erlc +time` on the
generated modules, median of three, wall time and `core_inline_module`
before the attachment change (after the deletion) and after it: `tui`
0.45 s and 0.022 s, 0.45 s and 0.022 s; `tui@tick` 0.46 s and 0.020 s,
0.47 s and 0.021 s; `tui@session_control` 0.88 s and 0.059 s, 0.92 s and
0.061 s; `tui@inbound` 2.37 s and 0.125 s, 2.44 s and 0.132 s;
`tui@interaction` 2.47 s and 0.165 s, 2.55 s and 0.176 s; `tui@submit`
1.05 s and 0.047 s, 1.09 s and 0.050 s; `tui@attachment` 0.20 s and
0.008 s, 0.21 s and 0.007 s; `tui@runtime` 0.32 s and 0.012 s, 0.35 s and
0.013 s; `tui@job_runner` 0.16 s and 0.005 s, 0.17 s and 0.006 s. The
deletion itself took `tui@submit` from 1.25 s to 1.05 s and `tui@inbound`
from 2.53 s to 2.37 s.

## Addendum: phase 2 S6, file reads leave the step (2026-09-26)

The sixth and last slice of phase 2 takes the file-system reads out of the
step. Nothing above is changed by it. After it, `tui.step` reads no file;
what it still reads, and which phase takes each, closes this addendum.

**The survey.** Every file read reachable from `tui.step`, and the reads
around it, at the commit this slice started from:

| Read | Site | Where it ran | After S6 |
|---|---|---|---|
| a pasted image: `file_info`, a 12-byte prefix, then the body up to 20 MiB | `image_drop.load_paste`, called by the composer's paste handler, `paste_unlocked` at `tui/interaction.gleam:167` | in the step | before the step, in `read_paste`, which phase 3 folded into `message` at `tui/runtime.gleam:207` |
| a new session's configuration: `HOME`, the canonical state root, the kind and canonical path of `--config`, or whether `<state-root>/loom.toml` exists | `bootstrap.session_configuration`, called by `create_session` at `tui/session_control.gleam:547` | in the step | a job, `Configure` at `tui/job_runner.gleam:302` |
| the workspace of an opened or created session: the `.git` marker and `HEAD` | `daemon_selection.target`, which calls `discover_from` at `tui/daemon/selection.gleam:551` | the attachment worker, since S5 | unchanged |
| the owner token after a daemon death | `daemon_selection.relaunch`, which calls `read_private_bounded` at `tui/daemon/selection.gleam:136` | the relaunch worker, since S4 | unchanged |
| the working directory's workspace, `--workspace`, `--token-file`, the owner token, daemon resolution, the recording header, a replayed recording, and the Herdr and palette environment | `discover` at `tui.gleam:763`, `discover_from` at `tui.gleam:794`, `read` at `tui.gleam:1457`, `read_private_bounded` at `tui.gleam:2132`, `start` at `tui.gleam:955`, `decode_file` at `tui.gleam:1936`, `configure` at `tui/tick.gleam:61` | before the loop | unchanged |
| the record-based session discovery that fed the local switch | `tui/sessions` and `tui/bootstrap` | deleted in S5 | gone; no definition or caller remains |

Recording appends are writes, and have been effects since S3. Two reads in
the step touch no file, and the closing section below places them.

**The pasted image is read before the step.** A terminal delivers a dragged
file as a paste of its path. `tui.update` is now
`settle(step(event, read_paste(event, receive(stamp(model)))))`.
`runtime.read_paste` reads the file when a paste names exactly one path
(`image_drop.read_dropped`, over the same `load_path` the step called) and
stores the result on the model as `Model.dropped`, an `image_drop.Dropped`
recorded against the pasted text. The paste handler calls
`image_drop.dropped_image`, which is pure and uses a read only for the text
it was taken for; for other text, or for no read, it answers `Ok(None)`,
the answer for a paste that names no image, and the paste is inserted as
text. Every event overwrites the field, so a read never outlives its event
and the base64 image it holds is not retained after the composer takes it.

The other design was a keyed job, `StartJob(key, ReadImage(path))`, whose
reply would land in a slot. It was rejected because the one step of latency
is not invisible here. A job answers at the next receive, and a key the
operator types in between is applied first: an Enter pressed after a drop
could submit the prompt without the image, and a pasted path that names no
image would be inserted after the keys that followed it. Read before the
step, the paste is handled in one step, as before, and the refusals are the
strings `load_paste` has always produced. The cost is that the runtime
reads a pasted path whatever the step then does with the paste, so a path
pasted into an overlay that ignores pastes is read and dropped; the read's
bounds apply either way.

**The configuration is resolved by a job.** Pressing `n` in the session
picker with local launch options queues `StartJob(key,
job.Configure(options))` and holds the key in `Model.configuring`. The
worker is `bootstrap.session_configuration`, unchanged. The runtime admits
its reply by key, and `session_control.drain_configuration`, which
`tick.update_tick` calls after the activity poll's drain and before the
connection drain (`tui/tick.gleam:145` (`drain_configuration`)), clears the
slot at the first outcome and continues where the step used to: a resolved
path goes to `create_session_configured`, which cancels the pending
submission, refuses while a creation key is retained, control is
disconnected or another attachment is starting, and only then retains the
key and starts the attachment job; a failure is written to the transcript
with the same text, and nothing else changes. The relay's `AllDelivered`
finds the slot cleared and is dropped. A configuration reply carries only a
path, so `tui_model.release` has nothing to queue for one that no slot
admits, and quit clears the slot without a release.

Moving the resolution into the attachment worker, the job that already runs
for a creation since S5, was rejected. The step retains the creation key
and cancels the pending submission before it starts that job, and the
comment above `create_session` gives the reason the resolution comes first:
a local failure must send nothing and retain no key, so the operator can
correct the invocation and press `n` again. Resolved in the worker, a
mistyped `--config` would leave a retained key that refuses the next press,
and a submission already cancelled. The separate job keeps the order and
adds one tick, at most the 40 ms active poll after a key press.

Three details follow from the job. A terminal with no local launch options
has nothing to resolve and still creates in the step, with no
configuration, as before. A second `n` while the job runs is ignored, since
the first creation continues when its answer arrives; before this slice the
first press closed the picker at once, so a second `n` went to the
composer. And during that tick the picker stays open, so a key pressed in
that window reaches it; an Enter that opens a row there makes the creation
that follows report "a session switch is already in progress". That window
is the one tick of latency and nothing more.

**Orderings kept.**

- *Quit.* The lane close, the attempt's `CancelJob` and `Abandon`, then the
  control job, relaunch and activity poll cancels, then the configuration
  job's, which is new and goes last, then the control close. Quit clears
  `Model.configuring` in the same step, so a late answer is admitted
  nowhere.
- *Tick drain order.* Unchanged for the existing drains; the configuration
  drain is appended after the activity poll's.
- *Creation.* The checks, the pending-submission cancel and the key
  retention run in the order they ran when the step resolved inline.
- *Paste.* An image attaches, and a refusal is reported, in the step that
  handled the paste.

**Callers outside `update`.** A test that calls `step` directly with a
paste naming an image calls `runtime.read_paste` first, or the paste is
inserted as text. A test that presses `n` on a terminal with local options
ticks through `update` until `Model.configuring` is `None` before it looks
for the creation key; `tui_daemon_test`'s creation recovery and
`bootstrap_test`'s real-server lifecycle now do. The client test driver
needs no change: it selects every running job's replies through
`job_runner.selector` and hands them to `runtime.hold`, which admits a
configuration reply like any other.

**Tests and mutations.** `file_reads_test` pins the slice. For the paste:
the step alone leaves a pasted image path as text though the file is on
disk; a read taken by `read_paste` attaches its image though the file is
deleted before the step, which a step that read the file could not do; a
read for one paste is not attached to another; the next event clears the
read; and through `update` an image attaches and an oversized one reports
"dropped image exceeds the 20 MiB limit", the string `load_paste` returns.
For the configuration: asking for a session queues exactly one
`job.Configure` under the slot's key, notices nothing about a missing
`--config` and starts nothing; through `update` the real job's failure is
reported with `session_configuration`'s own error and the picker stays
open; a resolved path continues the creation with that path in the
attachment job, and the relay's last message reports nothing; a reply
under another key is not admitted; and quit cancels the job. Each mutation
below was applied alone and reverted.

| Mutation | Tests that failed |
|---|---|
| the paste handler calls `image_drop.load_paste` again | `the_step_alone_leaves_a_pasted_image_path_as_text_test`, `the_step_attaches_what_the_read_before_it_found_test` |
| `dropped_image` uses a read taken for any text | `a_read_for_another_paste_is_not_attached_test` |
| `read_paste` leaves the read on the model for later events | `the_next_event_clears_the_read_test` |
| `create_session` resolves the configuration inline again | `asking_for_a_session_queues_the_configuration_job_test`, `a_resolved_configuration_continues_the_creation_test`, `quit_cancels_the_configuration_job_test` |
| the configuration slot admits a reply under any key | `a_configuration_reply_for_another_key_is_not_admitted_test` |
| quit leaves the configuration job running | `quit_cancels_the_configuration_job_test` |
| the tick does not drain the configuration slot | `a_configuration_failure_reports_the_same_error_test`, `a_resolved_configuration_continues_the_creation_test` |
| the first outcome leaves the slot in place | `a_configuration_failure_reports_the_same_error_test`, `a_resolved_configuration_continues_the_creation_test` |

The inline-resolution mutation leaves
`a_configuration_failure_reports_the_same_error_test` passing, as it should:
that test pins the behaviour, which the move keeps.

**Compile time.** `read_paste` is a cross-module call on `update`'s
parameter, and the configuration drain the tick calls is a cross-module
call beside the other drains, so the slice adds no local step for the
inliner to revisit (`docs/execution.md` §8). Measured with `erlc +time` on
the generated modules, median of three, with the modules from the commit
this slice started from and from its last commit timed one after the other
to keep the machine's load the same, wall time and `core_inline_module`
before and after: `tui` 0.50 s and 0.024 s, 0.52 s and 0.025 s;
`tui@tick` 0.51 s and 0.022 s, 0.52 s and 0.022 s; `tui@interaction`
2.59 s and 0.173 s, 2.61 s and 0.173 s; `tui@inbound` 2.50 s and 0.129 s,
2.64 s and 0.137 s; `tui@submit` 1.14 s and 0.052 s, 1.16 s and 0.052 s;
`tui@model` 0.37 s and 0.015 s, 0.38 s and 0.015 s; `tui@job` 0.19 s and
0.004 s, unchanged; `tui@job_runner` 0.21 s and 0.007 s, unchanged;
`tui@image_drop` 0.20 s and 0.005 s, 0.20 s and 0.006 s.
`tui@session_control` grew with the drain it gained, from 0.96 s and
0.062 s to 1.08 s and 0.070 s, and `tui@runtime` with `read_paste` and the
new slot, from 0.39 s and 0.014 s to 0.44 s and 0.017 s. `tui@inbound`
did not change in source; its 0.14 s is within the spread of repeated runs
on this machine, which reached 0.3 s for that module.

**What phase 2 achieved.** The step began phase 2 reading three clocks,
its jobs' and sockets' mailboxes and the file system, writing the
recording, and creating the subjects, cancel signals and processes of its
jobs. Each has moved:

| Slice | What left the step | Where it went |
|---|---|---|
| S1 | presentation, transport and wall clock reads | `runtime.stamp`, before the step |
| S2 | connection, replay and attachment mailbox reads | `runtime.receive`, into buffered inboxes |
| S3 | recording appends and attempt notes | `Record` and `Note` effects |
| S4 | control, relaunch and activity-poll starts, cancels and replies | `StartJob` and `CancelJob`, replies admitted by key |
| S5 | the attachment attempt's start and messages; the local switch | a keyed `Attach` job; the switch deleted |
| S6 | the pasted image read; the configuration resolution | `runtime.read_paste`; a keyed `Configure` job |

Two reads remain in the step, and neither touches the file system. Adoption
asks whether the replacement socket's actor is alive (phase 3 moved the
read to `tui/runtime.gleam:309` (`connection.adopt`)). And the
build-mismatch notice reads this client's build identity from two environment variables on
every coherent cut (`tui/model.gleam:1055` (`build_identity`)). Phase 3
takes both: once etui's events are replaced by a domain message type, the
runtime can read the liveness when it delivers the message that carries the
socket, and the build identity, which does not change while the process
runs, can be read once when the model is created, as `Model.terminal` is.
Phase 3 also deletes the `Peer` branches that suppress effects during
replay; they perform no I/O now, but they remain as control flow. Every
other effect the step decides is a value in its returned list, and every
other input it reads was put on the model by the runtime before the step.

## Addendum: phase 3, the client's own message (2026-09-26)

Phase 3 replaces etui's input event with a message type of the client's
own, takes the last two host reads out of the step, and separates
received traffic from reduction. Nothing above is changed by it, except
the claim about `Peer` branches, which the survey below corrects.

**The message.** `tui.step(msg.Msg, Model)` takes one of two things.
`msg.Input(at, event)` is one event and the clock readings it is applied
at, and the step reduces it. `msg.Arrived(arrivals)` is traffic the host
received, and the step only files it (`tui/admission`): each message goes
into the buffer or slot that waits for it, nothing is reduced, and no
effect is returned. The event is in the client's terms: a key with the
text it came from and the key it parses as, a paste with what reading its
path found, a resize, the pointer, or a tick. `tui/keymap.translate`
builds one from etui's event and only parses. What Escape means depends
on whether a submission is waiting and which overlay is open, so that
decision stays in the reducer, which has the model. `tui.update` keeps
its signature and is `runtime.message`, then `runtime.receive`, then
`step`, then `runtime.settle`.

Phase 2 wrote the clocks and the pasted file's read onto the model before
the step (`runtime.stamp`, `runtime.read_paste`). A Lustre runtime calls
`update(model, msg)` and has no hook before it, so both now travel inside
the input: `runtime.message` reads the clocks once and the pasted file,
and `tui_model.start_step` stores the stamp before any reducer runs.
`Model.dropped` and `image_drop.Dropped` are gone, because a read carried
by its own paste's message cannot be attached to another paste or outlive
its event. `Stamp` moved from `tui/model` to `tui/msg`. A recording is
written from the event (`msg.recorded`), which writes the line
`recording.of_input` wrote, so the format and its bytes are unchanged, and
a replay still drives `tui.update` with etui's events decoded from the
file.

**Why admit-only arrivals.** Three designs were weighed. (A) Keep etui's
tick and key as the only messages. That leaves the writes to the model
before the step in place, and a Lustre host cannot make them. (B) One
message per arrival, each reduced. That runs `settle_update` per message,
needs a timer for the 250 ms reconcile the tick carries, and lets a reply
received before an Escape be reduced ahead of it (ADR-010). (C), chosen,
separates the two: arrivals are messages but only filed, and reduction
stays at a tick or a key, in the fixed drain order. Every ordering phase
2 kept is kept by construction, because the reducers take from the same
buffers at the same points. A fourth design, waking the loop when traffic
arrives instead of at the poll timeout, changes when a host delivers, not
what the step does, and is deferred until idle latency is measured. Any
such host delivers `Arrived` and then an input with `Ticked`; it never
expects an arrival alone to be reduced, which would be design B.

**Admission and the bound.** A frame is tagged with the inbox subject it
was read from, and the subject is its source key. Admission files it into
the adopted inbox or into the waiting attempt whose subject it names; a
frame from any other subject came from a socket the model no longer reads
and is not filed, which is the protocol model's S2 rule. Admission never
drops a frame for capacity, since a dropped frame is a gap in the lane's
sequence; past the bound it appends. The bound is the host's to keep:
`runtime.arrivals` reads each mailbox up to the room its buffer has left
(`buffered.waiting`, `attachment.frame_room`), which is phase 2's top-up
moved, and what it does not read waits in the mailbox. It reads each
subject from the model it is given, so after an adoption it reads the
adopted inbox's subject and never the replaced one's. The terminal's host
calls `admission.admit` directly, in the step's process, immediately
before the step; a host that can only call `update` delivers the same
traffic as `Arrived`. Job replies are admitted by key as `runtime.hold`
admitted them. A reply dropped at admission that holds a socket or a
control connection queues its release on the outbox, and the next input's
step returns it, as in phase 2.

**The two host reads.** The client's build identity, which the
build-mismatch notice compares with the daemon's on every coherent cut, is
read once when the model is created, into `Model.client_build`. Whether
the socket an attempt would adopt is still alive is read by the host when
it hands the attachment job's end over: `runtime.hold` turns the relay's
`AllDelivered` for the waiting attempt into
`job.Finished(SocketAlive | SocketGone(reason))`, reading the socket the
attempt's lane holds (`attachment.adoptable_socket`), and the attempt
adopts or fails on the answer, with the reasons it gave before. The read
now happens when the end is received rather than when the tick settles
it, at most one poll interval earlier; a socket can die after either
read, and the adopted lane's transport-loss handling covers both. An
unchecked end that reaches an attempt from a caller that bypassed the
host is refused rather than adopted. After phase 3 the step reads no
clock, file, mailbox, process or environment variable.

**The `Peer` survey.** The phase 1 text above says about twenty `Peer`
branches each decide whether they may write, and that phase 3 deletes
them once the replay runtime drops effects. The survey found that wrong.
During `loom replay`, `Model.channel` is `None`, so a replay's writes are
already stopped by the absence of a lane, and its recorder and Herdr
reporter are `None`. Of the sites that read the peer, three were
unreachable in the shipped client, because the only constructor of
`Attached` sets the channel in the same update and nothing clears it: the
socket close in `retire_previous` and in `submit.quit`, and the direct
write that was the only producer of `effect.Send`. They are deleted, with
`effect.Send`, and `Attached` no longer carries a second copy of the
socket. The rest change state or rendering (refusal and notice lines, the
output rate, idle time, submission bookkeeping, the disconnected footer)
and stay; deleting them changes replay frames. Two candidates were tried
and kept. The `Replaying -> sent` arms in `inbound.send_prompt_to` and
`submit.send_prompt_content` match the attached arm only while there is
no lane, and the test fixture `pushed.attached()` is a replaying peer
with a lane. The attached guard on the composer's pending marker in
`submit.submit` is not redundant for the same fixtures: removing it
failed four tests, one of them a live recording's replay. The clipboard
flag, the one check that only gates an effect, stays as the host's choice
at launch, because removing it would need a host mode in the core, which
was declined. There is no separate replay runtime.

**Orderings kept.** Escape before the drain: admission reduces nothing,
so a key step still cancels before it drains. The tick drain order is
unchanged in `tick.update_tick`. The swap: admission files only frames
whose subject is the adopted inbox's or the attempt's, and the host reads
the post-adoption subject. `models(1)` after `apply_cut`, quit's cancel
order and the 250 ms reconcile live inside reducers this phase does not
touch. The recording order: an input's line is still its step's first
effect, and admission records nothing.

**Tests and mutations.** `build_notice_test`, `keymap_test`,
`socket_liveness_test` and `admission_test` are new, and the S2 swap
regression in `runtime_receive_test` now also checks which subject the
host reads after an adoption. `admission_test` includes twenty generated
runs of frames, keys, submissions, Escapes and ticks that reduce exactly
as they did with phase 2's receive. Tests that stepped with etui's event
go through `tui_test/stepping`. Four tests were removed with the state
they pinned: two for a socket with no lane, and two for a paste read held
on the model. Each mutation below was applied alone and reverted.

| Mutation | Tests that failed |
|---|---|
| a cut reads the build identity from the environment again | `build_notice_test` |
| `translate` swaps the wheel direction | both `keymap_test` translation tests, and 17 scroll and history tests |
| `start_step` does not store the input's stamp | 13 clock and cache-notice tests |
| `start_step` records no input line | 2 in `recording_effects_test`, including `a_scripted_session_records_the_golden_bytes_test` |
| the paste handler ignores the input's read | 3 `file_reads_test` paste tests |
| `runtime.message` reads no pasted file | the same 3 |
| `hold` passes the relay's end through unchecked | 4 adoption tests |
| adoption ignores a gone socket | `a_socket_dead_before_the_end_arrives_fails_the_attempt_test` |
| the step reads the socket's process again | `a_socket_that_dies_after_the_end_arrives_is_still_adopted_test` |
| `Arrived` runs a tick after filing | 3 `admission_test` tests |
| admission files a frame from any subject | 8 tests, including the S2 swap regression |
| a frame is filed ahead of the held ones | 9 tests, including the golden recording |
| the host reads a full batch whatever the buffer holds | the room test and `escape_holds_one_batch_and_ticks_drain_it_in_order_test` |
| admission drops frames past the bound | `admission_never_drops_a_frame_for_capacity_test` |
| the host files frames before job messages | none |

The last is S5's uncaught mutation again and breaks no rule: an attempt's
first frames are read one tick later.

**Compile time.** The step's dispatch is a two-arm case: an input goes to
`reduce`, which is the phase 2 step body with its `settle_update`
boundary unchanged, and an arrival goes to `admission.admit`, a
cross-module call. `update` is cross-module calls on its parameters
(`docs/execution.md` §8). Measured with `erlc +time` on the generated
modules, median of three, with the commit phase 2 ended at and phase 3's
last code commit timed one after the other, wall time and
`core_inline_module` before and after: `tui` 0.54 s and 0.024 s, 0.53 s
and 0.024 s; `tui@tick` 0.53 s and 0.021 s, 0.55 s and 0.022 s;
`tui@interaction` 2.58 s and 0.170 s, 2.60 s and 0.169 s; `tui@inbound`
2.52 s and 0.127 s, 2.53 s and 0.126 s; `tui@submit` 1.16 s and 0.050 s,
1.15 s and 0.050 s; `tui@model` 0.39 s and 0.015 s, 0.41 s and 0.017 s;
`tui@attachment` 0.25 s and 0.008 s, 0.26 s and 0.008 s; `tui@pacing`
0.21 s and 0.005 s, 0.21 s and 0.004 s. `tui@runtime` fell from 0.45 s
and 0.017 s to 0.32 s and 0.009 s, as the slot logic left it for
`tui@admission` (0.36 s and 0.013 s). `tui@msg` and `tui@keymap` compile
in 0.21 s each.

**What phase 4 extracts.** The core is the step behind `msg.Msg` and
`effect.Effect`, `tui/admission`, and the reducers and projection they
call. The host is `tui/runtime`, which reads clocks, files, mailboxes and
process liveness and performs effects, `tui/job_runner`, and `tui/keymap`
with etui. A Lustre server component supplies its own host: a selector
that tags each socket frame with its subject and each job message with
its key and dispatches `Arrived`, a timer that dispatches
`Input(stamp, Ticked)`, and an interpreter for the effects. Under that
host the bound is a buffer bound the host keeps itself, since a selector
consumes what it matches. `keys.Key` and `backend.MouseButton` are etui
types that remain in `msg.Event`; both are plain data, and a read-only
view sends neither.

## Addendum: one mailbox scan for the jobs (2026-09-26)

Phase 2 moved the job and replay reads to every event, and each is a
selective receive that scans the whole mailbox when nothing in it
matches, so under a socket backlog a keypress paid one scan for the replay
inbox and one per running job, where before phase 1 it paid none.
Measured with `scripts/tui_perf.sh` against a 10,000-frame backlog on a
live terminal with three jobs running, a keypress cost 219,325 reductions
before phase 1, 260,405 at `42620f56`, and a tick 257,765 and 260,111.
The runtime now reads the replay inbox only while the peer is `Replaying`,
since only a replay's virtual backend sends to it and no transition
enters or leaves that peer (`runtime.arrivals`), and reads every job in
one pass through the merged `job_runner.selector`, reading nothing when no
job runs (`job_runner.receive`). Merging changes the order of arrivals
only across jobs, and each is admitted by its own key into its own slot,
which the tick drains in its fixed order; the comment at the site gives
the argument. With both, the keypress costs 230,493 reductions and the
tick 228,640, below its pre-phase-1 cost; the one scan left on a keypress
is the jobs' read, which phase 2 moved there on purpose. The per-event
bounds are unchanged. `jobs_test` pins the routing: a runtime that tags
every arrival with one job's key, or reads only one job's selector, fails
`a_keypress_admits_every_jobs_reply_into_its_own_slot_test`, and one that
reads the replay inbox outside a replay fails
`only_a_replay_reads_its_replay_inbox_test`.

## Addendum: phase 4, P4a, the lane leaves the terminal (2026-09-26)

The first part of phase 4 moved the part of the client that no host
owns into `packages/session_view`, a package that imports only `core`,
`machine` and the standard library and that lint R6 holds there. It is
the session lane, the protocol and wire decoders, snapshot adoption
(`snapshot`, `snapshot_view`), the history window, the attempt
vocabulary with the connection events, the approval decisions, and the
transcript's line builders with everything they import. The terminal
drives the same modules it drove before, the moves were renames that
changed only import lines, and the replay goldens did not change.

Three changes to names this ADR uses above:

- **`session_channel.perform` is now `tui/terminal_lane.perform`.** The
  channel is generic over its socket and recorder
  (`Channel(socket, recorder)`, `Out(socket, recorder)`), and performing
  an output needs the concrete handles, so the perform half moved to the
  host. The paragraphs above that name `session_channel.perform` (phase 1's
  decision, S3's recording paragraph and S3's table) describe it as it
  was at each phase; the function is the same, under the new name.
  `tui/terminal_lane` also names the terminal's choice once: `Lane` and
  `Output` are the channel and its output with the terminal's connection
  and recorder.
- **`connection.Message` is now `connection_event.Message`**, data in the
  engine; `tui/connection` keeps the transport.
- **`recording.Trace` is an alias of `attempt.Trace(Recorder)`**, so a
  lane can carry its trace without importing the recording.

The phase 3 addendum's "What phase 4 extracts" names the step, admission
and the reducers. Phase 4 extracts less: a read-only view needs the lane
and the projection, and the step waits for the phase that builds the web
view out. [ADR-014](014-second-runtime.md) records that decision, the
four things that tie the step to the terminal today, and a path for each.

## Addendum: event-driven delivery (2026-09-27)

This addendum revises option C from the phase 3 addendum. Option C made
arrivals messages that are only filed and put every reduction at a tick or
a key, and the tick was a poll: the terminal's loop woke when etui's input
wait timed out, at most 250 ms after the last wake while a lane was
attached, and the web view reduced on a 250 ms timer except while a reply
was awaited (ADR-014, the addendum on waking). The lane also captured
again on every one of those ticks while idle. The rule is now: traffic is
reduced when it arrives, and time is handled by one wake-up at the lane's
next deadline. What a reduction does, and the order it does it in, did not
change. [delivery.md](../architecture/delivery.md) traces one frame through
both hosts under the new rule.

**Why.** The 250 ms tick was a floor on both cost and latency. Measured on
a live terminal against a local daemon, an idle attached terminal woke its
loop 14.6 times a second and issued 3.6
catch-ups a second, and the daemon decoded 10.7 requests a
second from that one idle client. A frame that reached an idle terminal
waited for the next poll before it was reduced. Every open page paid the
same refresh traffic and rendered four times a second besides.

**What changed in the lane.** `session_channel.next_due` answers the
earliest reading at which `tick` would act: the in-flight deadline, the
refresh instant of a ready lane with a cut, or `None`. It is exact in both
directions, and the property test checks that after every generated step
(N1). The idle refresh has two intervals. A lane starts `Polling`, at
250 ms, and moves to `Pushing`, at five seconds (one second for now; see
the interim refresh below), on the first pushed frame it receives. The first push is the evidence because the hello names no
push capability and a lane that reconnects may face an older daemon. No
gap detection was added: a notice at or above the cut catches up from
`cut.next_seq`, so a lost notice followed by any later one loses nothing,
and only a lost final notice waits for the `Pushing` refresh. A pushed
configuration board, which the gateway sends every other subscriber when
one changes a strand's configuration, now catches up as a presence change
does; the lane used to drop it and let the 250 ms refresh pick the change
up.

**What changed in the terminal.** The session socket wakes the loop.
`host/websocket.connect_waking` has the socket actor call a `notify` after
it files a frame, and `tui/connection.connect_waking`, which only the
attach worker's session socket uses, makes that `notify` send etui's
`{etui_wake}` to the inbox's owner. The actor sends the wake after the
frame, so the loop never sees a wake ahead of the frame it announces.
Wakes are paced at the sender to one per 16 ms, the frame interval; a
frame inside the interval gets one wake at its end, so every frame has a
wake within 16 ms and the loop needs no feedback flag or mailbox flush.
Etui's side is two commits on the fork's `wake-clause` branch: the wake
clause in `read_with_timeout`, reported as a zero-wait probe rather than a
timeout so a half-read escape sequence or paste is not cut short, and a
40 ms bound on a lone escape byte's wait, so Escape does not wait for an
idle poll that is now up to a second long.

With traffic announced, `tick.terminal_poll_timeout` is only for what no
wake announces. A drain that stopped at its batch polls at once, because
its leftover frames had their wakes spent on earlier ticks
(`Model.connection_backlog`). A walking viewport keeps 16 ms and a request
in flight keeps 8 ms, since a reply usually lands inside the wake interval
of the wake that let the loop send the request. A model that
`wakes_itself` (a strand running, a deferred frame, a running job, frames
held back) keeps the paced poll and the 250 ms cap it had before. Anything
else sleeps until `next_due`, capped at one second.

**What changed in the web view.** The selector's mapping drains the inbox
behind the frame it matched, up to 64 frames, into one `Arrived`, which is
reduced at once. Lustre 5.7.1 renders, diffs and broadcasts once per
message whatever the message changed ([lustre.md](../lustre.md), "An empty
reconcile is still broadcast"), so one message per burst is what makes one
render per burst. There is no periodic tick: after every transition the
component cancels its timer and arms one `send_after` for `next_due`.
`update` performs that itself, because the `Timer` handle must stay in the
model for the next arming to cancel, and returning it through an effect
would cost a second message and a second render.

**What was kept.** ADR-010's ordering: a wake is a separate event behind an
Escape, so the Escape's step cancels before any traffic is reduced and the
wake's tick drains what it held; if etui ends the Escape's input burst on
the wake instead, the held frames keep the loop on its short poll.
`runtime_receive_test` pins both. The drain order in `tick.update_tick`,
admission and the swap rule (S2) are untouched. A batch is still at most
64 frames in either host, and the terminal's per-frame cost did not move.
The P model changed only in its prose: it has no clock, and `eTick` with
`tickPending` already modelled a reduction woken by an arrival and
coalesced with others. All ten test cases pass at 30,000 schedules and the
mutation table is unchanged.

**What was considered and not done.**

- *Gap detection on notice sequences.* Not needed, for the reason above.
- *The wake as a read timeout*, as first proposed. Etui resolves a pending
  escape prefix on a read that waited its full timeout; a wake that
  counted as one would split an arrow key or a paste into stray keys while
  an answer streams. The wake is a zero-wait probe instead.
- *A feedback flag or a mailbox flush for wakes.* The sender's pacing bounds
  the wakes a burst costs without either.
- *A wake on SIGWINCH.* Etui notices a resized window only when its loop
  runs, which is why the idle ceiling is one second and not the lane's
  refresh. A wake from the signal would remove that ceiling; it is left for
  a later change to the fork.

**What it costs.**

- A fact with no pushed notice reaches an idle pushing client within five
  seconds rather than 250 ms. A peer joining is one: the gateway pushes a
  departure but not a join, so the peers already attached see a newcomer
  at their next refresh. The shipped multiplayer fixture, which waits for
  exactly that after Bob rejoins, took 12.4 s instead of 7.7 s (median of
  five runs each, with twelve of sixteen cores busy). Timing each of its
  80 waits puts all of the difference in that one: Alice's wait for Bob's
  new attachment went from 231 ms to 4,979 ms, and no other wait moved by
  more than 30 ms. Pushing the join is the fix, and it amends
  protocol-change/018, which rules that a join is not announced;
  [protocol-change/054](../../protocol-change/054-roster-push-on-subscribe.md)
  proposes it. Until it lands the `Pushing` refresh is one second, which
  bounds a join's delay to a second (the interim refresh, below).
  The `client/` context cell ([models.md](../architecture/models.md)) is
  another; its figure reaches the agent strip sooner through the usage
  row's own push. A lost final notice has the same bound.
- An idle terminal notices a resized window within about 1.1 s rather than
  about 350 ms, and a cache countdown with nothing running under it moves
  in steps of up to a second (up to five on a page). A countdown is an
  upper bound, so a late label still states something true.
- `update` in the web component performs one host action, the timer.
- The socket actor carries a pacing state and a timer subject, and its
  initial reading had to be the actor's own clock: the BEAM's monotonic
  clock is negative here, and a schedule that opened at zero held the
  first wake for days. The first live drive found that; a client test on a
  real socket now pins it.
- The pin moves to an etui branch that is not yet on the fork's `main`.
- A lane that has never been pushed to keeps the 250 ms refresh, and a
  page in that state renders more often than before (below).

**Measured.** Before is `c4e6e5b64`, after is this change, on the same
machine, alternating. The live figures come from a terminal and a daemon
started as distributed nodes, counted with `call_count` trace patterns and
timed with trace timestamps on the lane owner's process, against a
loopback provider that streams either one delta every 250 ms or 500 deltas
in one write; each is the median of five runs.

| Measurement | Before | After |
|---|---|---|
| Idle terminal: loop wakes per second | 14.6 | 1.6 |
| Idle terminal: catch-ups per second | 3.6 | 0.2 |
| Idle terminal: requests the daemon decodes per second | 10.7 | 0.6 |
| One delta every 250 ms: arrival to reduction, median / p90 | 8.3 / 21.2 ms | 0.2 / 9.5 ms |
| One delta every 250 ms: arrival to the next paint, median / p90 | 20.1 / 934 ms | 2.3 / 14.3 ms |
| 500 deltas in one write: arrival to reduction, median / p90 | 75.5 / 153 ms | 11.5 / 17.0 ms |
| 500 deltas: first arrival to the paint after the last reduction | 222 ms | 154 ms |
| 500 deltas: paints | 20 | 14 |
| 500 deltas: the loop's reductions over the window | 21.6 M | 14.8 M |
| Idle page that has been pushed to: renders per second | 9.9 | 0.8 |
| Idle page that has been pushed to: catch-ups per second | 2.0 | 0.2 |
| Idle page: DOM mutations and HTTP requests in 60 s | 0 and 0 | 0 and 0 |
| Page, 500 deltas: renders in the burst's 10 s window | 618 | 100 (33 to 345) |
| Idle page never pushed to: renders / catch-ups per second | 9.9 / 2.0 | 15.3 / 3.8 |

The paint latency counts every frame, including those that changed
nothing on screen, whose next paint came with a later change; that is
where the old p90 of 934 ms comes from. The page's renders per burst
depend on how fast the deltas reach the component: a render is one batch,
and a component that keeps up takes batches of a few frames. Lustre's real
runtime with the component suspended while 40 or 150 frames queue gives
exactly one and three renders (`delivery_test`).

The last row is a regression, and it follows from the design. A lane on a
session where nothing happens receives no pushed frame, because the
gateway pushes nothing to a network subscriber when it subscribes, so it
stays `Polling` and now refreshes every 250 ms exactly, where the page's
old tick quantized that refresh to about every 500 ms. The terminal in
the same state is unchanged, at 3.6 catch-ups a second. Publishing the
roster to a new subscriber, itself included, would give every lane its
evidence at attach; that is a gateway change which moves the push order
nine client tests pin, several of them counting authorization checks, so
it is left as a follow-up in [next.md](../next.md).

`scripts/tui_perf.sh` measures the step itself on a pinned clock, median
of seven alternating runs, and it did not move: per-frame reductions for
a 500-frame burst drained tick by tick went from 5,465.7 to 5,466.4, a
64-frame tick from 226,230 to 226,066, the 10,000-frame backlog cases by
less than half a percent, and growth stayed flat at every size to 4,096
frames. An idle tick costs 27 more reductions (7,451 to 7,478), for
recording whether the drain stopped at its batch and whether the tick
adopted. The model after a long reply is one word larger, and what the
process retains after a collection is unchanged or smaller. The replay
goldens pass unchanged, and `loom replay --all --plain` of both committed
recordings is byte-identical between the two builds.

**The interim one-second refresh.** The table above was measured with
`session_channel.pushing_refresh_ms` at 5 s. Because a join is not pushed,
that value leaves a newcomer invisible to the peers already attached for
up to five seconds, so the constant is 1 s until
[protocol-change/054](../../protocol-change/054-roster-push-on-subscribe.md)
pushes the roster on subscribe, and then returns to 5 s. Measured the same
way at 1 s, median of five runs:

| Measurement | Before | After, 5 s | After, 1 s |
|---|---|---|---|
| Idle terminal: loop wakes per second | 14.6 | 1.6 | 3.9 |
| Idle terminal: catch-ups per second | 3.6 | 0.2 | 0.97 |
| Idle terminal: requests the daemon decodes per second | 10.7 | 0.6 | 2.9 |
| Idle page that has been pushed to: renders per second | 9.9 | 0.8 | 4.0 |
| Idle page that has been pushed to: catch-ups per second | 2.0 | 0.2 | 1.0 |
| Shipped multiplayer fixture, five runs under load | 8.0 s | 12.2 s | 8.2 s |

The latency and burst rows do not depend on the idle refresh and were not
remeasured. The fixture's configuration test is back within 0.25 s of the
build before event-driven delivery.

**The refresh returns to five seconds (2026-09-27).** The owner accepted
[protocol-change/054](../../protocol-change/054-roster-push-on-subscribe.md),
and the hub now pushes the `presence` roster to every subscribed peer,
the newcomer included, when a network peer subscribes. A join is
therefore a pushed frame, so `session_channel.pushing_refresh_ms` is 5 s
again, as the table above assumed. The newcomer's own copy of the roster
is also the first frame pushed to it, so a lane on a quiet session moves
to `Pushing` at attach rather than refreshing every 250 ms until
something happens there.

Measured as for the interim refresh, against `bin/loomd` with
`LOOM_BOOTSTRAP_E2E_SERVER` set and twelve cores held busy:

- Alice's wait for Bob's new attachment after he rejoins, in
  `tui_shipped_multiplayer_test`, is 1 to 6 ms over five runs (it was
  4,979 ms at a 5 s refresh without the push, and 225 to 1,077 ms at the
  interim 1 s). Alice already holds the new roster when Bob's own
  terminal finishes opening: measured from the moment Bob's terminal
  starts, she sees his attachment within 34 to 118 ms, median 51 ms. No
  wait in the fixture's two tests, 345 waits over the five runs, took
  longer than 2.8 s, so none is bound to the refresh.
- An idle terminal attached to a quiet session issued 24 catch-ups in
  120 s, one every 5.0 s (0.20 a second), and 0.60 requests a second in
  all, the "After, 5 s" figures above. Its recording shows the roster as
  the first pushed frame after the subscribe reply.

The fixture's wall time was not comparable this time. The host carried a
load average of 27 to 48 from other work beside the twelve busy cores,
and the configuration test ranged from 8.8 s to 40.9 s across ten runs,
with its waits summing to about 3.3 s in a run that took 9.1 s. The rest
is setup (daemon launch and cold attachment), which the refresh does not
touch.
