# Delivery: from the socket to the screen

This document follows a frame the daemon sends a client until the client
has reduced it and painted the result, in both of Loom's client hosts: the
terminal (`packages/tui`) and the web view (`packages/web_view`). It
describes delivery as it stands after ADR-013's addendum on event-driven
delivery, which replaced a fixed 250 ms tick with a wake on arrival and one
timer for the lane's own deadlines. The decision, its costs and the
measurements are in that addendum; this is the map of how the pieces fit.

## Six terms

A **lane** is one client's credited connection to one session: a
`session_view/session_channel.Channel`, with one request on the wire at a
time. Each terminal and each open page holds its own lane, and the lane
carries the frames of every strand in the session.

A **strand** is one conversation thread in a session, such as `main`, the
advisor, or `sub:reviewer`. Frames name the strand they belong to; the lane
does not open one per strand.

An **inbox** is what a host has received from one source and not yet handed
to the lane, oldest first. The terminal's is a `tui/buffered.Inbox` over the
socket's `Subject`; the web view's is a `session_view/inbox.Inbox` that the
shared step fills when the component hands it an `Arrived`.

A **batch** is the set of frames one host step takes from its inbox: at
most 64 in either host (`tui_model.connection_batch`,
`component.arrival_batch`).

A **reduction** is one pass that hands a batch to the lane in arrival order
(`operator.drain` calling `session_channel.receive` for each frame) and then
runs the lane's own `session_channel.tick`. A reduction is where a frame
takes effect: a capture completes, a notice issues a catch-up, a delta
reaches the transcript.

A **deadline** is a reading of the host's monotonic clock at which the
lane's `tick` would act without any frame arriving: the in-flight
request's timeout, or the idle refresh of a ready lane.
`session_channel.next_due` names the earliest one, and `None` when there is
nothing a tick could do.

## The rule both hosts follow

Traffic is reduced when it arrives, and time is handled by one wake-up at
the lane's next deadline. Nothing polls on a fixed cadence to find traffic.

The two halves have different owners. Arrival is a host fact: only the
host can see its mailbox. The deadline is a lane fact: only the lane knows
whether it is waiting on a reply, when it last captured, and whether its
daemon pushes. So the lane exposes `next_due` and never reads a clock, and
the host arms a wake-up for the answer and reads the clock when the wake-up
fires.

`next_due` is exact in both directions. A `tick` at any reading before it
changes nothing, and a `tick` at it acts. The property test in
`packages/tui/test/session_channel_property_test.gleam` checks both after
every generated step (rule N1). A host that wakes late acts late but never
misses a deadline, because `tick` compares with `>=`.

## The terminal, step by step

```mermaid
sequenceDiagram
    participant G as daemon gateway
    participant S as socket actor<br/>(host/websocket)
    participant M as terminal mailbox
    participant E as etui loop
    participant U as tui.update
    participant T as terminal screen
    G->>S: text frame
    S->>M: Incoming(text), mapped by connection.terminal_event
    S->>M: {etui_wake}, paced by websocket.pace
    E->>M: read_with_timeout receives {etui_wake}
    E->>U: Tick
    U->>M: runtime.receive reads the inbox, up to 64
    U->>U: tick.update_tick, inbound.drain_connection,<br/>session_channel.receive per frame
    U->>U: settle_tick, session_channel.tick
    U->>U: refresh_frame_cache, pacing.frame_decision
    U-->>E: model with the new frame cached
    E->>T: diff of the frame
    E->>U: tick.terminal_poll_timeout
```

1. **The socket actor files the frame.** The gateway writes a text frame
   to the websocket. Stratus hands it to the socket actor's `on_message`
   in `packages/host/src/host/websocket.gleam`, which calls `deliver`.
   `deliver` sends `Incoming(text)`, mapped by `connection.terminal_event`,
   to the terminal's inbox subject.
2. **The socket actor wakes the loop.** Still in `deliver`, and only after
   the send, `websocket.pace` decides the wake. Outside the 16 ms interval
   it calls `notify` at once; inside it, the first delivery arms one
   `send_after` for the interval's end and later ones are covered by it.
   `notify` is the closure `connection.connect_waking` built, which calls
   `etui_terminal_ffi:wake/1` and sends `{etui_wake}` to the process that
   owns the inbox. The same process sent the frame first, so the frame is
   in the mailbox before its wake.
3. **Etui ends its wait.** The loop was blocked in
   `etui_terminal_ffi:read_with_timeout`, a selective receive of keyboard
   input with an `after` clause. The `{etui_wake}` clause returns
   `{error, woken}`, and the backend turns that into a `Tick`, treating it
   as a zero-wait probe so a half-read escape sequence is not resolved
   early.
4. **The runtime receives.** `tui.update` stamps the clocks
   (`runtime.message`), then `runtime.receive` reads the inbox's mailbox
   up to the room its buffer has (`runtime.arrivals`) and
   `tui/admission` files what it read.
5. **The tick reduces.** `tick.update_tick` drains, in its fixed order, the
   replay, the candidate attachment, the jobs' replies and up to 64
   connection frames (`inbound.drain_connection`). Each frame goes through
   `inbound.handle_connection_message` to `session_channel.receive`, and
   the updates it returns are folded in by `inbound.apply_channel_update`.
   `settle_tick` services the side reads and runs `inbound.tick_channel`,
   which is the lane's `tick` at the stamp's transport reading.
6. **The frame is paced.** `settle_update` calls `tick.refresh_frame_cache`,
   and `pacing.frame_decision` renders a stale frame if 16 ms have passed
   since the last one, or defers it to the next tick. The lane's outputs
   leave through `runtime.perform` and `terminal_lane.perform`.
7. **Etui paints and asks when to wake.** Etui diffs the cached frame
   against the screen and writes the difference. It then calls
   `tick.terminal_poll_timeout` for its next wait.

The poll timeout is only for what no wake announces. A drain that stopped
at its batch (`Model.connection_backlog`) polls at once, because the frames
it left in the mailbox had their wakes spent on earlier ticks. A walking
viewport polls at 16 ms, and a lane with a request in flight at 8 ms,
because a reply usually lands inside the wake interval of the wake that let
the loop send its request. A model that `tick.wakes_itself` takes the paced
poll (40 ms after activity, 400 ms when quiet) capped at 250 ms, the cap it
had before wakes, and by the lane's deadline: something running anywhere, a
deferred frame, a job whose replies wake nothing, or frames still held.
Anything else sleeps until `session_channel.next_due`, capped at
`tick.idle_poll_ceiling_ms`, one second, because etui notices a resized
window only when its loop runs.

## The web view, step by step

```mermaid
sequenceDiagram
    participant G as daemon gateway
    participant R as ui_relay
    participant C as component process
    participant L as Lustre runtime
    participant B as browser
    G->>R: reply or push
    R->>C: connection_event.Message on the inbox subject
    C->>C: selector mapping in component.open:<br/>the frame, then up to 63 already waiting
    C->>L: one Arrived(messages)
    L->>C: component.update, which reads transport.now()
    C->>C: step.update(Arrived) files the frames,<br/>step.update(Ticked) drains them:<br/>session_channel.receive, session_channel.tick
    C->>C: refreshed, then rearm:<br/>cancel_timer, send_after(next_due - at)
    L->>L: view, diff, reconcile
    L->>B: one patch per message
```

1. **The relay files the frame.** `client/daemon/ui_relay` receives the
   gateway's reply or push for the page's attachment and sends it, as a
   `connection_event.Message`, to the inbox subject the component created
   in `component.open`.
2. **The selector drains the burst.** The component's selector matches the
   frame, and its mapping function in `component.open` reads up to 63 more
   frames already waiting with `process.receive(inbox, 0)` (`waiting`) and
   builds one `Arrived(messages)`. It reads no clock.
3. **Lustre runs `update`.** The runtime takes the message
   (`EffectDispatchedMessage`) and calls `component.update`, or
   `operator_page.update`, which passes it on. `update` reads
   `transport.now()` once, then hands the shared step two messages in
   order (`stepping`). `step.update(msg.Arrived(..))` files the batch into
   the record's inbox with `admission.file_frame` and reduces nothing.
   `step.update(msg.Input(at, msg.Ticked))` then runs the tick: the
   activity and roster clocks, the drain (`operator.drain` handing every
   filed frame to `session_channel.receive`, and each update the lane
   returns applied through `lane_fold` before the next frame is taken), the
   side-surface reads (`service_reads`), and the lane's `tick` at the
   reading. The step settles the record against the one it started from
   and returns the effects it decided, which the component turns into one
   `effect.from` (`perform`). `component.refreshed` then rebuilds the rows
   and the strip if their inputs moved.
4. **The component re-arms its timer.** `rearm` cancels the timer it armed
   before and calls `process.send_after` for `next_due - at`. It does this
   inside `update`, because the `Timer` handle has to be stored in the
   model for the next arming to cancel it.
5. **Lustre renders once.** The runtime calls `view`, diffs the new tree
   against the last one and broadcasts the patch to the page's socket,
   whether the patch holds a change or not. The page's `ui_socket` writes
   it to the browser, and Lustre's client runtime applies it.

When the timer fires, its selector mapping in `component.arm` sends
`Ticked`, and `update` reads the clock and runs the same tick
(`step.update(msg.Input(at, msg.Ticked))`). The strip's cache labels come
up to that reading in `refreshed`. An `Opened` message is a tick too, after
the lane is adopted, so frames filed before the lane existed are drained
in order. The terminal's tick runs the same shared units in the same order
with its own drains among them, and `session_view/step_test` holds the two
compositions together.

## When the lane is due

```mermaid
stateDiagram-v2
    direction LR
    state "in flight<br/>next_due = deadline" as Flight
    state "ready with a cut<br/>next_due = refresh_at" as Ready
    state "no cut, or closed<br/>next_due = None" as None
    [*] --> Flight: subscribe
    Flight --> Ready: capture completes<br/>refresh_at = now + interval
    Flight --> Ready: command answered
    Ready --> Flight: tick at refresh_at, catch_up
    Ready --> Flight: notice at or above the cut
    Ready --> Flight: command sent
    Flight --> None: deadline passes, lane fails
    Ready --> None: close
```

The interval after a capture depends on what the lane has seen of its
daemon:

```mermaid
stateDiagram-v2
    direction LR
    Polling: Polling<br/>refresh 250 ms
    Pushing: Pushing<br/>refresh 5 s
    [*] --> Polling: lane starts
    Polling --> Pushing: first pushed frame (apply_pushed)
```

A lane that has seen no push cannot tell a quiet session from a daemon that
never pushes, so it refreshes every 250 ms. A pushed frame is evidence that
commits are announced; from the next capture on, the refresh repairs a
lost final notice and catches what the daemon does not announce. The hello
is not used as that evidence: it names no push capability, and a lane that
reconnects may face an older daemon.

The `Pushing` interval, `session_channel.pushing_refresh_ms`, is 5 s. It
can be that long because no change a peer's screen depends on waits for
it. The last one that did was a peer joining the session: protocol-change/018
had the hub push `presence` when a peer departed and not when one
subscribed, so the peers already attached saw a newcomer only at their
next capture, and with a 5 s refresh the shipped multiplayer fixture spent
4.7 s of its 12.2 s waiting for it. The constant was 1 s while that was
so. [protocol-change/054](../../protocol-change/054-roster-push-on-subscribe.md)
has the hub push the roster to every subscriber when a network peer
subscribes, so a join now reaches the other peers as a pushed frame.

The newcomer receives its own copy of that roster, and that copy is the
first frame pushed to it. A client that attaches to a session where
nothing happens therefore moves to `Pushing` at attach and refreshes
every 5 s, rather than staying `Polling` at 250 ms until the first commit,
stream or departure reaches it. The roster and the reply to `subscribe`
leave the hub by different paths, so either may arrive first; a roster
that arrives before the lane has a cut marks the lane pushed and captures
nothing.

## Four timelines

**One frame.** A stream delta arrives while the terminal is idle and its
last wake was more than 16 ms ago. At t = 0 the socket actor files the
frame and wakes the loop. The loop's `Tick` receives and reduces it; the
tick changed the transcript, so the frame is paced, and more than 16 ms
have passed since the last paint, so it is painted in the same step. On
the web, the selector matches at t = 0 and the component renders once.
Before event-driven delivery, the frame waited in the terminal's inbox for
the next poll timeout, up to 250 ms, and on the web for the next 250 ms
tick. A commit notice takes a catch-up's round trips on top: the notice
issues `catch_up` at once, and each reply either wakes the loop or arrives
within its 8 ms in-flight poll.

**A burst of 500 frames.** A provider writes 500 deltas in a few
milliseconds. The socket actor files all 500, wakes the loop for the first
and schedules one more wake for the end of the 16 ms interval. The first
tick reduces 64 frames and records `MailboxMayHoldMore`, so the next poll
waits for nothing and the next batch is taken at once. Eight back-to-back
batches reduce the burst in a few tens of milliseconds, at the same
reductions per frame as before, and frame pacing paints at most one frame
per 16 ms however many ticks run; the viewport then walks the new rows into
view a row per frame. On the web the 500 frames become eight
`Arrived` messages of up to 64, and so eight renders. Before, each of the
500 frames was its own Lustre message and render.

**An idle session.** Nothing is running and the daemon has pushed to the
lane before.
The terminal sleeps up to one second at a time (the idle ceiling), and
every `pushing_refresh_ms` (5 s) its lane is due: the tick issues `catch_up`, the loop polls at
8 ms while it is in flight, and the reply's frames wake it. A capture that
brings back the cut already drawn repaints nothing. The page sleeps until
its timer fires at the lane's refresh, `pushing_refresh_ms` after the last
capture, and renders once for the timer and once per reply batch. Before, both
hosts woke four times a second and each wake issued or waited on a
capture.

**A lost final notice.** The last commit before a session goes quiet is
announced by a notice that never reaches the client. No later notice will
cause a catch-up from the lane's `cut.next_seq`, so the commit is fetched by
the idle refresh: within `pushing_refresh_ms` of the lane's last capture
on a pushing lane, within 250 ms on a polling one. A lost notice followed by
any later notice costs nothing, because a notice at or above the cut
catches up from `cut.next_seq` and fetches both commits.

## Why time is an input

The lane reads no clock. Every transition that sets or checks a deadline
takes `now` from its caller, and `next_due` is a pure function of the lane.
Three things depend on that.

- **Replay.** `loom replay` drives the same lane with its own time, which
  starts at zero and moves only with the recording, so a replay makes the
  same transitions and draws the same frames on every run. The replay
  goldens in the `tui` tests pin its output byte for byte.
- **The protocol model.** The P model in
  `protocol/models/terminal-attachment/` has no clock. A refresh or a
  deadline can fall due at any tick the checker chooses, which covers every
  ordering a real clock allows, and `eTick` with `tickPending` already
  stood for a reduction woken by an arrival and coalesced with others.
  Event-driven delivery changed when a host ticks, not what a tick does, so
  the model changed only in its prose.
- **Fake-clock tests.** The property test passes the oracle's own `now`,
  `poll_timeout_test` sets the model's stamp, and `component_test` sets the
  transport's clock through `page_fixture.clock`. None of them sleeps, and each schedule
  reproduces from its seed.

## Debugging latency

Start with counts, then with a scenario.

**Counts on a live client.** Launch with `--profile` (see
[distribution.md](../distribution.md)) or start `erl` with `-name`, then
count calls over a window with `erlang:trace_pattern(MFA, true,
[call_count, local])` and read them back with `erlang:trace_info(MFA,
call_count)`. The functions that answer the usual questions:

| Question | Function to count |
|---|---|
| How often does the terminal's loop wake? | `etui_terminal_ffi:read_with_timeout/1` |
| How often does the socket wake it? | `etui_terminal_ffi:wake/1` |
| How often does a lane capture? | `session_view@session_wire:catch_up/2` |
| How many requests does the daemon decode? | `client@protocol:decode_command/1` |
| How often does the terminal paint? | `tui@render:render_frame/2` |
| How often does a page render? | `web_view@component:view/1`, `web_view@operator_page:view/1` |

A terminal whose frames reach the screen late but whose loop wakes often
is paying for pacing: look at `frame_debt` and the viewport backlog. One
whose loop does not wake after a frame is missing its wake: count
`host@websocket:deliver/2` against `etui_terminal_ffi:wake/1`. A page that
renders once per frame is not batching: count `web_view@component:update/2`
during a burst.

**Scenarios.** `scripts/tui_perf.sh <checkout> <label> <scenario>` measures
the terminal's update loop on a pinned clock, so two revisions compare by
reductions and words, which the machine's load does not move:

- `events`: one key, one idle tick, and a tick and a key with 64 frames
  waiting. The idle tick is the per-wake cost.
- `burst <n>`: a burst drained tick by tick; `ticks` is the number of
  reductions a burst costs, and the per-frame figures should not move.
- `backlog <n> <jobs> live`: a mailbox backlog while jobs run, which is
  the cost of each selective receive that scans it.
- `growth <n>`: per-frame cost as one reply grows, which should stay flat.
- `session <n>` and `replay <n>`: memory after a long reply, and a
  replay's cost and frame count.

For the web view, `packages/web_view/test/delivery_test.gleam` counts the
patches a burst costs on Lustre's real runtime, and
`packages/client/test/client/terminal_wake_test.gleam` watches a real
socket wake its loop after the frames it files.

## Goal writes after a run settles

The primary's idle edge can precede its advisor's goal evaluation. The advisor
publishes `GoalChanged` only after its reserved goal write or deletion succeeds.
The gateway pushes `goal_changed` to authorized subscribers on the existing
Outputs path. It invalidates an auxiliary board, so no capture frontier or
transcript entry represents it (protocol-change/056).

The shared session lane retains one goal read owed until it can issue
`goal_get`. Operator intent already queued goes first. A notification during
an older read survives that reply and causes another read. Both hosts quietly
replace the correlated goal observation. The terminal draws the composer row
and its open inspector; the web view reads `component.goal` for its session
summary and operator controls. Neither host adds a periodic goal read.

## Reading the held-input and goal paths in Gleam

The following paths describe the implementation merged at `8b3455493`
(#583), including the request ownership correction. Start with the `## Flow`
module comments, then follow the private helpers named there. The gateway and
renderer keep their larger subsystem sections; the guide names the small path
through each rather than requiring a read of every command or drawing routine.

| Question | Source path and reading order |
|---|---|
| Why does input stay held after the interrupt retires? | [`snapshot_view.queue_halted`](../../packages/session_view/src/session_view/snapshot_view.gleam), then [`model.active_queue_halted`](../../packages/session_view/src/session_view/model.gleam), [`tui/model.active_queue_halted`](../../packages/tui/src/tui/model.gleam) and [`render.input_behavior`](../../packages/tui/src/tui/render.gleam). |
| What announces a goal cell write? | [`advisor.store_goal` / `clear_goal`](../../packages/client/src/client/advisor.gleam), `write_cell` / `delete_cell`, then `goal_written`. |
| Which attached peers receive it? | [`bus.publish` / `topic_of`](../../packages/events/src/events/bus.gleam), then [`gateway.handle`](../../packages/client/src/client/gateway.gleam), `push_to_subscribed`, `deliver` and `check_binding`. |
| Why can't an old read consume a newer invalidation? | [`session_channel.receive`](../../packages/session_view/src/session_view/session_channel.gleam), `apply_pushed`, `apply_reply`, `send_queued`, `flush_queued` and `read_changed_goal`. |
| Which request owns a confirmation or refusal? | [`outbound.apply_submission` / `record_sent`](../../packages/session_view/src/session_view/outbound.gleam), then [`surfaces.receive_goal` / `owns_goal_report` / `refuse_goal`](../../packages/session_view/src/session_view/surfaces.gleam). |
| Where does the host display an observation? | [`tui/model.hold_shared`](../../packages/tui/src/tui/model.gleam), `show_goal_observations` and `observe_goal`; on the web, [`component.goal`](../../packages/web_view/src/web_view/component.gleam) feeds the page's views. |

### A cut can retain held input after a local interrupt is gone

`snapshot_view.queue_halted` requires a known strand whose captured
`live_phase` is `None`, plus a captured pending input for that strand. Both
facts come from one validated cut. `pending_inputs: None` means the daemon
provided no queue observation, so the predicate returns false rather than
inferring a hold. Protocol 033 ensures ordinary queued input drains before
an idle cut is exposed. Pending rows on an idle strand therefore describe
input waiting for the operator's next submission.

The local `Interrupt` names one operation and can retire when that operation
ends. Its retirement leaves the cut's pending rows intact. This is why a
second attachment, which never sent Escape and has no local interrupt, can
still draw the same held-input guidance. `model.active_queue_halted` adds one
composer rule: a submitting prompt or a live operation outranks the retained
idle cut. The existing queue does not make a new prompt into another steer.

In `render.input_behavior`, `use <- bool.guard(condition, value)` means the
rest of the function is the callback used when the condition is false. A true
condition returns `value`. The held-input guard therefore selects the stopped
composer text before the ordinary prompt/steer cases. The value is a literal;
it creates no eager fallback work. [`submit.toggle_submission_mode`](../../packages/tui/src/tui/submit.gleam)
keeps steering unavailable while an interrupt is active, while normal prompt
submission remains the way to release the held input with the new message.

### Three different goal fields

`Channel.goal_refresh` is the lane's invalidation debt, with private
constructors `Idle` and `Due`. `Shared.goal_refresh` is the surface scheduler's
request state, with `worktree_view.Requested` and `worktree_view.Settled`.
The two fields share a spelling but have different owners. Lifecycle edges
through `surfaces.sync_goal` schedule the latter; a pushed `GoalChanged`
schedules the former. Neither field is the board itself.

`Shared.goal_request: Option(Int)` names the currently issued goal command.
`Shared.goal_report` describes what the operator is owed. Its
`ConfirmGoal(line, request: Option(Int))` has `None` while a mutation waits
behind a read, then `Some(id)` after that mutation's `Sent` update. `None`
means an ID has not been issued; it is not zero, failure, or an anonymous
request that any reply may settle.

| State | Transition | Result |
|---|---|---|
| `Channel.goal_refresh = Idle` | `GoalChanged` in any open lane phase | `Due`; a ready lane enters `send_queued`. |
| `Channel.goal_refresh = Due` | Another notice while a request owns the slot | `Due`; notices coalesce into one owed read. |
| `Channel.goal_refresh = Due` | `read_changed_goal` matches `Ready, Due` | `Idle` at issuance; a new read owns the slot. |
| `ConfirmGoal(request: None)` | An older goal read answers | Observation changes; confirmation stays unowned. |
| `ConfirmGoal(request: None)` | The queued mutation emits `Sent(command, id)` | `ConfirmGoal(request: Some(id))`. |
| `ConfirmGoal(request: Some(id))` | Its own board or refusal answers | Its report settles; an unrelated ID cannot consume it. |
| `HoldGoalReport` | An automatic board or refusal answers | Observation changes without transcript confirmation. |

The source's `Phase` table lists the actual constructors (`AwaitingBegin`,
`Receiving`, `AwaitingReply`, `Ready`, `Closed`) and the admission guards.
`Ready` is an intermediate boundary in a completed reply: `send_queued` may
immediately use the slot again. It first tries queued operator intent, then
an invalidation read, then transcript capture debt. The last two remain due
when the earlier operation takes the slot.

`read_changed_goal` matches `channel.phase` and `channel.goal_refresh` in
one `case`; a comma separates those subjects. Only the `Ready, Due` arm
issues a read. Its argument to `send` uses this record expression:

```gleam
Channel(..channel, goal_refresh: Idle)
```

The record update constructs a new value with all other fields retained.
It never mutates the earlier channel, so `channel.request_id` can still
name an older reply while `sent.request_id` names the read issued afterward.
The wildcard arm returns the original tuple `#(channel, updates)` when the
phase or debt does not permit issuance.

### An invalidation before or after an older read

Suppose read 7 is outstanding and the retained board says `Active`. The
advisor writes the goal cell, receives the writer's successful reply and
attempts best-effort publication of the data-free `GoalChanged` event.
For a delivered event, `gateway.handle` pushes it only
to subscribed connections; `deliver` rechecks each network peer's immutable
binding. The client decoder treats it as a push, so it consumes no credit and
cannot acquire read 7's identity.

If the notice arrives before read 7's board, `Channel.goal_refresh` becomes
`Due`. Read 7's reply makes the lane ready and supplies `Auxiliary(board7)`
to `send_queued`. With no queued operator intent, `read_changed_goal` issues
read 8 and appends `Submission(Sent("goal_get", 8))` *after* that auxiliary
update. The shared reducer first accepts board 7 and clears read 7's slot,
then records ID 8. The reverse order would let board 7 clear ID 8.

If the notice arrives after read 7's reply, the ready lane issues read 8
immediately. If a second notice arrives while read 8 is outstanding, it
restores `Due`; read 8's reply cannot consume that later debt, so the lane
issues read 9 afterward. Debt is cleared when the read is issued, rather
than when its board succeeds. Repeated notices before issuance need only one
read because every read asks for the current durable cell.

### A queued mutation owns its own report

Suppose read 7 is outstanding when the operator pauses the goal.
`surfaces.confirming` stores the pending confirmation with `request: None`,
and the lane keeps the encoded mutation in its one queued slot. Read 7's
board can update the observation, but `owns_goal_report` cannot confirm a
mutation whose ID has not been issued. `send_queued` emits the old board
update before `flush_queued`'s `Sent("goal_pause", 8)` update. The latter
binds the confirmation to ID 8 in `outbound.record_sent`.

A pending goal invalidation waits while that mutation owns the slot. The
mutation's board or refusal settles its own report first; if goal debt is
still due, a subsequent automatic read gets another ID and no operator
confirmation. Read IDs are allocated by the lane, so a caller's draft ID is
not evidence that a waiting mutation was issued.

The alternatives in `record_sent` share one body:

```gleam
"goal_set", ConfirmGoal(line:, ..)
| "goal_check", ConfirmGoal(line:, ..)
| "goal_clear", ConfirmGoal(line:, ..)
| "goal_pause", ConfirmGoal(line:, ..)
| "goal_resume", ConfirmGoal(line:, ..)
-> ConfirmGoal(line:, request: Some(request_id))
```

The `|` combines patterns for different commands, not boolean conditions.
`line:` binds the field to a local variable of the same name; `..` ignores
other fields. Constructing `ConfirmGoal(line:, request: Some(request_id))`
retains the line but binds it to this issued mutation. `goal_get` has no arm
in this group, so a read cannot acquire a queued mutation's report.

### A refused observation is visible without disconnecting

A bounded goal read can fail with `snapshot_failed` while the gateway keeps
the connection. `session_channel.apply_reply` returns `RequestRefused` with
the exact correlated command and ID. `surfaces.refuse_goal` checks that ID
against `Shared.goal_request` before clearing `Shared.goal` and recording
`GoalUnavailable`. The composer and the web controls then have no current
board. An open terminal inspector retains its old board with the failed
refresh label through `tui/model.observe_goal`; that board is explicitly stale.
An automatic refusal remains silent in the transcript. A queued mutation's
unowned confirmation survives an older read refusal just as it survives an
older board.

The total decoder idiom in `snapshot_view.decode` is another way to read
these functions without assuming exceptions:

```gleam
use fields <- result.try(object(captured.metadata))
use cells <- result.try(captured_cells(captured))
```

Each `use` passes the following block as the continuation. `result.try`
returns the error unchanged when the preceding step fails, and passes the
successful value into that continuation otherwise. Validation completes
before a host adopts the view. The public decoder is separate from the
lane's request correlation, which determines whether this validated result
belongs to the request being answered.

Goal notifications remain best-effort. The guarantee covers a notice that
reaches the lane and the reads it owes. A lost final goal notice can leave
an auxiliary board stale until another goal notice, a lifecycle-triggered
read, an explicit read or a new attachment observes the cell. Transcript
catch-up is not a periodic goal read and cannot supply that missing board.
