# ADR-014: one client engine, two views

**Status**: accepted, implemented in #552 (2026-09-27); the step moved into `session_view` under #569, per the addendum of 2026-09-29 · **Date**: 2026-09-26 · **Supersedes**: nothing ·
**Relates to**: [issue #530](https://github.com/Roasbeef/loom/issues/530),
[ADR-013](013-tui-effects-as-values.md),
[protocol-change/051](../../protocol-change/051-web-view-route.md)

## The question

Issue #530 set out to give Loom's client a Lustre-shaped core: a pure step
from a message and a model to a new model and a list of effects, with a
per-platform runtime that performs the effects. ADR-013 records how the
terminal got there over three phases. Phase 4 asks the question that work
was for: can the same engine drive a second view, a page in a browser, and
what may differ between the two?

The owner's answer sets the terms. The web view reuses the terminal's
engine: its lane, snapshot adoption, projection, effects, and later its
model, update and reducers. Only the view differs, rendered by Lustre
instead of etui. This ADR records how phase 4 honours that, what it leaves
for the phase that builds the web view out, and where that phase is headed.

## Decision

**One engine, a host per platform, and the view is the only code a host
owns that is about presentation.**

The engine is `packages/session_view`: the session lane
(`session_channel`, generic over the host's socket and recorder handles),
the protocol decoders, snapshot adoption (`snapshot`, `snapshot_view`,
`history_view`), and the transcript's line builders (`transcript_lines`,
reading a `Presentation` record rather than any host's model). It imports
`core`, `machine` and the standard library only, and lint R6 keeps it
that way. Some of its modules have terminal-sounding names, such as
`composer`, `queued_input` and `pasted_image`. They are engine modules all
the same: the rules for how pasted text is shown in the transcript, the
queued-input document the protocol decodes, and the record of an image
already read. The terminal's editor, its file read and its drawing stay
in `tui`.

A host is two things:

- **A runtime.** It reads what the engine may not read (clocks, mailboxes,
  sockets) and delivers it as messages, and it performs the engine's
  effects. The terminal's is `tui/runtime`, `tui/job_runner` and
  `tui/terminal_lane.perform`. The web view's is the Lustre server
  component's `init` and effects, and the daemon-side relay that stands in
  for a socket (protocol-change/051).
- **A view.** The terminal's is `tui/render` and `tui/layout` over etui;
  the web view's is Lustre elements over the same `transcript_line.Line`
  values.

The rule that follows: **the web view grows no state logic of its own.**
Where the component would need logic that decides something about the
session (what a capture means, which lines a record becomes, when to catch
up, what a reply settles), that logic belongs in `session_view`, where the
terminal already uses it or can. A reviewer who finds session logic in
`packages/web_view` has found a bug in the extraction.

### What phase 4 extracts

Phase 4 moved the read-only closure: the lane and everything the lane
imports, snapshot adoption, the history window, and the line builders
with everything they import, plus `transcript.project`, which turns one
completed capture into one strand's lines for a host that keeps no
presentation state. The terminal drives the same modules it drove before.
The moves were renames, and the replay goldens did not change. The
ADR-013 phase 3 addendum ("What phase 4 extracts") planned more than
this, and the reason for the smaller cut is below.

### Why the step waits for the build-out phase

A read-only view needs the lane and the projection. It does not need the
step (`msg`, `admission`, the reducers, `tui/model`), and moving the step
means moving `tui/model`, which every reducer imports. Four things tie the
step to the terminal today. Each has a path, and the build-out phase takes
them when the web view first needs input: a composer, an approval, a sent
message.

1. **`buffered.Inbox(a)` wraps a `Subject`.** The step's buffers are pure
   already (admission files into them, reducers take from them); only the
   subject inside is BEAM. Path: split the buffer from its source. The
   engine keeps `Inbox(source, a)`, the held messages and a
   host-supplied source key, which is what admission compares since phase
   3. The host keeps the subject and reads it (`buffered.waiting`,
   `discard`).
2. **`msg.Event` carries etui's `keys.Key` and `backend.MouseButton`.**
   Path: key and pointer types owned by the engine. `tui/keymap.translate`
   is already the only place etui's event is parsed, so it maps into the
   new types, and the web host maps DOM events into the same ones. Pointer
   events that hit-test the screen (`Pressed(x, y, button)`) become
   targets the view resolves (a row, a button), since only the view knows
   its layout.
3. **The model holds the terminal's render caches.** `FrameCache.rendered`
   and `selection_frame` are etui buffers; `rendered_rows`, `record_rows`,
   `diff_rows` and their caches are etui `span.Line`s; the composer and
   workspaces hold etui text areas. Path: split `Model` into the engine's
   state and a per-host view state the host keeps beside it. The line
   caches already key on `transcript_line.Line`, so the split falls along
   an existing seam.
4. **The model holds host handles.** `running: job_runner.Running`, the
   `recorder`, the Herdr reporter, the attachment candidate's worker, and
   the adopted `terminal_lane.Lane`. Path: the handles become type
   parameters of the engine's model, as the lane's socket and recorder
   did in phase 4. Job replies already arrive by `job.Key`, so the table
   that maps keys to handles stays in the host.

Doing this in phase 4 would have touched every reducer (the `tui`
package's source was 40,965 lines after the P4a moves) to serve a view
that sends nothing.

### Delivery under option C

ADR-013's phase 3 addendum chose option C: arrivals are messages that are
only filed, and reduction happens at a tick or a key, in a fixed order.
The web host keeps it.

- The component's messages are `Arrived` (the frames the relay delivered)
  and `Ticked`. `Arrived` appends to the component's buffer and reduces
  nothing. `Ticked` hands every buffered frame to
  `session_channel.receive` in order, then calls `session_channel.tick`,
  so the lane's 250 ms reconciliation and idle refresh run as they do in
  the terminal.
- The relay's subject and the tick's subject are created inside the
  component's process with `server_component.select`, so every reply is
  read by the process that owns its subject (the "same process" rule in
  ADR-013's phase 2 S4 addendum). The tick is a `send_after` the
  component re-arms on each `Ticked`, and the clock is read when the
  selector maps the timer message, which is host code.
- A Lustre selector consumes everything it matches, so the buffer bound is
  the host's, as the phase 3 addendum says. The skeleton drains the whole
  buffer on each tick, which bounds it by 250 ms of pushed frames plus
  the credited transfer.
- The lane's outputs go through one interpreter with the terminal's
  shape: `Transmit(socket, frame)` writes to the relay and `Shut(socket)`
  detaches it. The skeleton has no recorder, so its recorder type is
  `Nil` and it never sees a `Note`.

The skeleton's two messages are the shape of the engine's `msg.Msg`
(`Arrived`, and an `Input` whose event is `Ticked`). When the step moves
into the engine, the component adopts `msg.Msg` rather than being
rewritten, and mutations arrive the way they do in the terminal: a
reducer calls `session_channel.submit`, and the lane queues a
`Transmit`. The interpreter does not change.

### What the skeleton is

A page for one session, picked by ID, that shows that session's
transcript lines and follows the session live. No styling beyond what
makes the lines legible, no navigation, no second session, no composer
and no approvals. It is served only when `loomd --ui` is set, reached
through a link `loom --ui` prints, and read-only both by role in the daemon
and by type in the component (protocol-change/051 has the mechanics).
Building the UI out is the next phase, after this one closes.

## Alternatives considered

**A separate web client that speaks the protocol from the browser.**
`session_view` has no BEAM-only dependency, so it could compile to JavaScript and a Lustre
single-page app could run the lane in the browser. It would put the
person's credential in the browser, which protocol-change/051 rules out,
and it would make the browser a second implementation site for behaviour
that must match the terminal's. A server component keeps the engine on
the BEAM, next to the terminal's copy of the same code.

**A sidecar process instead of the daemon.** The phase 4 design first
proposed serving the page from a separate development program that
attached over loopback, to avoid changing the daemon's surface. The owner
ruled that the view belongs in `loomd` behind a flag, and per-person
authentication needs the daemon's own credential store, which a sidecar
does not have.

**A web model of its own for the skeleton.** It would be less code today
and a rewrite later. The skeleton instead holds only the engine's lane
and last capture, and draws through `transcript.project`.

## Direction

A direction, not a plan. The web view exists to make multiplayer work
smoother than a terminal can, and the build-out moves toward:

- **Agent-first and multi-agent views.** The page leads with the agents
  (strands) of a session rather than one transcript, and can show several
  agents, or several sessions, side by side. Each view is its own
  component keyed by person and session, which the routes already allow.
- **Cross-session messaging.** Messages between agents and sessions
  ([messaging](../architecture/messaging.md),
  [async collaboration](../architecture/async-collaboration.md)) are
  shown and sent from the page, through the engine's submit path and the
  existing protocol commands, with the daemon checking the sender's role.
- **Presence.** Everyone attached to a session, from a terminal or a page,
  appears to everyone else, from the presence roster the gateway already
  pushes.

The terminal pieces the web view would reuse through the shared engine,
once their state logic moves into it: `tui/agents` and `tui/agent_view`
(the agent workspace and its rows), `tui/agent_strip`,
`tui/agent_messages`, `tui/peer_links`, and the session catalogue behind
`tui/session_selector`. Their drawing stays in the terminal; the web view
draws the same state with Lustre.

## Consequences

- Session logic has one home. A behaviour fixed in `session_view` is fixed
  for both views, and a view-specific fix that is really about the session
  is a review finding.
- The daemon serves a page when asked to, and carries Lustre and houdini
  in its release. The flag keeps the page off by default.
- The skeleton proves the engine runs under a second host. It does not
  prove the step can move; the four blockers above are that phase's work.

## Verification required

- A parity test: one recorded capture, projected by `transcript.project`,
  equals the lines the terminal's projection draws for the same records
  (`tui_model.presentation` with an empty history and caches), and the
  component's HTML (`element.to_string`) holds those lines in order.
- The component driven with `lustre/dev/simulate`: `Arrived` changes no
  lines until a `Ticked`, and the lines after a tick match the parity
  test's.
- The route's defences, each with a test: no `/ui` route and no `hello`
  field without `--ui`; `401` without a cookie, with a spent or expired
  ticket, and after the minting credential is revoked; `403` for a
  session outside the UI session's set, a non-loopback `Host`, and a
  mismatched `Origin`; and a mutation frame sent through the relay is
  refused by the gateway as an observer's.
- `loom --ui` against a running daemon without the view prints the
  message and exits 1 without touching that daemon.

## Addendum: the page wakes on a reply it is waiting for (2026-09-27)

In the operator page demo, a page stayed on "connecting" for seconds
before its first cut, on a session with a handful of entries. Timed from the
server's side, the socket upgrade took 2 ms and the first cut reached the
browser 2.77 s later. All of that was the tick. The first capture is a chain
of requests, each answered before the next is asked. A reply filed under
option C waited for the next 250 ms tick before the lane saw it and asked
for the next chunk, so eleven round trips cost eleven ticks. The relay's
attach and the daemon's answers took a few milliseconds between them.

ADR-013's phase 3 addendum left one design open for this case: a host that
wakes the loop when traffic arrives instead of at the poll timeout, which
"changes when a host delivers, not what the step does". The web host now
does that, narrowly. An `Arrived` carries the clock reading taken when the
host received it. When the lane has a request out
(`session_channel.in_flight`, the predicate the terminal shortens its poll
on), the arrival runs the same reduction a tick runs, at that reading,
without re-arming the timer. When the lane has nothing out, the arrival is
filed and waits for the timer as before, so a pushed notice or a run of
stream deltas is still reduced at the 250 ms cadence.

The step itself is unchanged: the same drain, in the same order, followed by
the lane's own tick. The parity test still holds the two lanes equal after
every step. Measured the same way, the first cut now reaches the browser
4 ms after the upgrade (46 ms on the first page after a daemon restart,
which also opens the session). The verification line above, that `Arrived`
changes no lines until a `Ticked`, now holds only for a lane with nothing
out; `component_test` covers both cases.

## Addendum: event-driven delivery (2026-09-27)

The waking described in the addendum above was the first half of a larger
change, which ADR-013's addendum on event-driven delivery records. The
component no longer has a periodic tick. Its selector drains a burst into
one `Arrived`, which is reduced at once whether or not a reply is awaited,
and one timer armed for the lane's `session_channel.next_due` replaces the
250 ms tick. The first capture's chain of replies was already reduced on
arrival and still is; what changed is that a push to an idle lane is
reduced on arrival too, a burst costs one render per batch of up to 64
frames, and an idle page wakes at the lane's refresh rather than four
times a second. The verification line above that `Arrived` changes
nothing until a `Ticked` no longer holds for any lane.

## Addendum: the step moved into `session_view` (2026-09-29)

**Status**: implemented over slices S1 to S5 of
`docs/design-notes/step-extraction.md` (issue #569, Part 1; the pull
requests are listed on the issue). This addendum supersedes the sections
"Why the step waits for the build-out phase" and "Delivery under option C"
where they say otherwise, and amends the second blocker. The sections above
are left as written.

The four blockers listed under "Why the step waits" are closed. The
session's half of the step lives in `session_view`, the terminal and the
web view both run it, and lint R6 holds it to the portable subset.

### The blockers

1. **`buffered.Inbox(a)` wrapped a `Subject`.** Closed on 2026-09-26 by
   splitting the buffer from its source. `session_view/inbox.Inbox(source,
   a)` holds the messages and the host's key for the source; the terminal's
   `tui/buffered` keeps the subject and reads it. The record holds two
   inboxes, `Shared.inbox` and `Shared.replay_inbox`, keyed by the type
   parameters `source` and `replay_source`.
2. **`msg.Event` carried etui's key and pointer types.** Amended, and
   closed by a different path. The owner ruled on 2026-09-27 that the step
   does not take an engine-owned key vocabulary. The key handlers read four
   terminal surfaces before they decide, and moving them would have moved
   the surfaces. Keys stay in the terminal (`tui/keymap`, `tui/msg`,
   `tui/interaction`). What a key or a click means is decided by the host,
   and both hosts hand the session the same closed set,
   `session_view/msg.Command`: `Submit`, `Interrupt`, `Stop`, `Decide`,
   `SelectModel` and `Quit`. A submitted draft reaches the session already
   parsed: `command.Command` is `Surface(..)` for what a host carries out
   with its own machinery (a panel, the model selector, daemon control, a
   change of strand, its exit) and `Session(..)` for what the session
   carries out, and only a `Session` command reaches `commands.act`. The
   terminal maps keys to commands in `tui/interaction` and `tui/submit`;
   the web view maps its two DOM events to them in `component.submit` and
   `component.decide`. Daemon control, reconnection and the attachment jobs
   stay in the terminal.
3. **The model held the terminal's render caches.** Closed by splitting
   the terminal's model into two records. `Shared` (`session_view/model`)
   is the session state, and `tui/model.View` is the terminal's own state,
   including its etui render caches as `View.caches`. Three records that
   held both kinds of state are split, each with its session half in
   `Shared`: a strand's parked history window and its editor, the agent
   roster and the strip's focus, and the queue editor's requests on the lane
   and the editor. `Shared` also carries four presentation revisions
   (`render_revision`, `frame_revision`, `activity_revision` and
   `record_cache_epoch`) that a host may compare and may ignore.
4. **The model held host handles.** Closed by type parameters. `Shared`
   is `Shared(socket, recorder, source, replay_source)`: four parameters,
   not three, because the terminal reads its two inboxes from subjects of
   different types. The terminal binds them in `tui/model.TerminalShared`;
   the web view leaves the socket to its transport and binds the other three
   to `Nil`. The terminal's job table, its Herdr reporter and its
   attachment worker stay in `View`. Two values the moved code reached could
   not follow it, because `host` reads the environment and the filesystem:
   the client's and the daemon's build identities, and the workspace
   context. The terminal keeps them and hands the shared code what it needs
   as data: `Shared.build_notice` is the mismatch lines the terminal
   computed when it adopted a daemon.

A fifth thing was not among the blockers. A shared reducer cannot write a
surface it has no type for, such as the composer, an overlay or the footer,
so it records a fact (`Shared.surface_facts`, `queue_notices`,
`goal_observations`, `drafts_sent` and `returned_drafts`) and the host
applies the facts after the call. A host applies each update's facts before
the next update in the same drain reads the state they change (the owner's
ruling on question 11 of the design note), so the host keeps the loop over a
drain's updates and one update is the shared unit.

### The entry point

The ADR planned that the web component would adopt `msg.Msg` and that
mutations would arrive as they do in the terminal. Both landed in a
narrower form, by the owner's ruling on question 12 (2026-09-28, option
(a)).

`session_view/step.update(shared, msg.Msg)` is the entry for a whole event
in a host with no surfaces of its own. `msg.Arrived` files traffic through
`admission` and reduces nothing. `msg.Input(at, Ticked)` runs the terminal's
tick less its surfaces, in its order: the activity and roster clocks, the
drain of every held frame, the side-surface reads and the lane's tick.
`msg.Input(at, Acted(command))` runs the command and settles. The web
component calls it, and reads the transport's clock once at the top of its
own `update`. The terminal does not call it. Its tick places its own drains
among the shared ones and applies facts between updates, and a key handler
that runs a command writes its own state after the command, so a settle
inside a shared `update` would run in the middle of the event. The terminal
calls the shared units one at a time, and `session_view/step_test` holds
`update` to the terminal's order over a scripted drain, including that the
drain runs before the reads.

A further option, (d), is recorded on issue #569 for later: move the
terminal onto `update` too, by passing a pure callback that the sequencer
calls after each piece so the host applies its facts, so that both hosts run
one sequence instead of the terminal's copy being held to it by a test. It
is not planned. Its costs are callbacks threaded through the step, a
reordering risk that the replay identity checks would catch, and the Erlang
inliner's cost on long settle chains.

### What changed in delivery

"Delivery under option C" above describes the component's messages as
`Arrived` and `Ticked` carrying a clock reading, and reducing through
`operator.drain` directly. Since S5 the messages carry no reading, and the
component's `update` reads the transport's clock once, at its top. An
`Arrived` is `step.update(msg.Arrived(..))` and then a tick in one Lustre
message, so a burst is still one render. `Opened` adopts the lane and
ticks, so anything filed before the lane existed is drained in order, and
`Ticked` is a tick. Event-driven delivery, the one timer armed for the
lane's `next_due`, and the buffer bound being the host's, are as the
earlier addendum on event-driven delivery states.

### What the page does now that it runs the step

- **It sends more.** The operator page parses a draft as the terminal
  does and runs any session command it names, except `/add-dir` and
  `/add-write-dir`, which name a path on the daemon's host.
  protocol-change/051's addendum "the operator page runs session commands"
  supersedes the text that says the page has two commands, and re-prices a
  stolen page. A `command.Surface` command is refused with a notice.
- **It reads more.** The step's tick reads the strand's notes, the
  session's context, the advisor's pending nudges and the goal, as the
  terminal's does, for surfaces the page does not draw. That is four round
  trips at load that hold the lane's command slot. The block-summary read is
  left out of `update`, because the daemon may run a summarizer for a label
  it is asked for and the page draws no labels.
- **It says more.** The composer's notice line shows the shared notice.
- **It loses a returned prompt.** `step.forget_surfaces` drops the facts
  the page has no surface for, including a held prompt the daemon hands
  back. The page has no editor to put it in, so the prompt's last copy is
  lost.

These are the costs of running the engine whole rather than choosing, host
by host, which reads and facts to take, and the ruling on question 12
accepted them. Each has an item under Part 2 of issue #569.

### The rule, checked

The rule under "Decision", that the web view grows no state logic of its
own, held by review while the component had its own fold of the lane's
updates. It now holds by construction. `component.update` reads a clock,
calls `step.update`, derives what it draws from the record the step left
and performs the effects the step returned. The fold of captures, the cache
and usage handling, the submission handling and the strip's input
bookkeeping are deleted from `web_view/component`. The page compares what
each projection was built from (`Projected` and `Stripped` in the
component) and not the record's `render_revision`, which moves for stream
fragments and tool tails the page does not draw.

The modules the "Direction" section lists as terminal pieces the web view
would reuse have moved as it proposed: `agent_view`, `agent_roster` and
`agent_messages` are in `session_view`, and the strip's roster is
`Shared.roster`. `tui/agent_strip`, `tui/peer_links` and the session
catalogue behind `tui/session_selector` remain the terminal's.

### Verification

- The terminal's suite and the replay goldens passed at each slice, with
  test changes limited to import lines, field paths and the handful of
  cases the slices' entries in the design note name. For S1 to S4, `loom
  replay --all --plain` on the two committed recordings was byte-identical
  between each slice's build and its base; S5 changed the terminal's step by
  one field in its constructor and one in its adoption, and the recordings'
  goldens pass. `session_channel_property_test` and the P model in
  `protocol/models/terminal-attachment/` pass, and the P model was not
  changed.
- The phase 3 admission mutation, "admission files a frame from any
  subject", fails the same eight tests on `main`, when applied to
  `session_view/admission.file_frame`, and when applied to the terminal's
  routing of a refused frame (question 9 of the design note).
- `session_view/step_test` holds `step.update` to the terminal's tick order.
  `client/web_view_parity_test` runs one script of frames and commands
  through both hosts and compares the lanes' states and the approvals on
  offer, and one capture through both projections. `component_test`,
  `operator_page_test` and `delivery_test` cover the component, the commands
  it now accepts and its render count per burst.
- The measurements (reductions and words per event, compile time of the
  generated modules, test counts) are in section 5 of the design note, slice
  by slice. No slice measured a rise on the terminal's idle tick, key or
  burst near the two percent that question 5 of the note set as a finding.
- Not run at S5: the hand check in a browser of the operator page, the
  observer page and a session with a running strand.
