# Design note: simulating the client

Status: **brief, not built.** Two work packages, written before the code
so the code has something to be held to. Both stand on the virtual
backend, the frame dump, and record/replay landing in `tui/virtual-backend`
(PR to follow); neither is worth starting before that merges. Where this
note and the code disagree once either package lands, the code is right
and this note should say so at the top.

The pieces this note leans on: etui's `Backend(state)` is a record of
five functions, so a scripted backend replaces the terminal without the
TUI knowing; `tui.update` and `tui.render_frame` are pure; server traffic
enters the model through one `Subject(connection.Message)` inbox that
`update_tick` drains; and the conformance simulator
(`packages/conformance/src/conformance/simulation/`) already turns one
integer into a script plus a fault schedule, runs the real supervision
tree against scripted effects, and prints the seed when a check breaks
(`docs/architecture/simulation.md`).

---

# Part A — the client-side simulator (work package 4)

## The claim to check

The runtime simulator's claim is convergence: the same script ends in the
same place under every fault schedule. The client has no such single
claim, because the client's job is to *show* state rather than to reach
it. Its claim is a set of frame invariants: **for every seed, every frame
the TUI renders is well-formed, and every frame is consistent with the
server state the TUI has been told about.** The generator's job is to
find the interleaving of server events, keystrokes, pastes, resizes and
ticks under which one of those stops being true. This week alone found
three by hand — a footer that changed row count as a turn ran, a status
label the section cut to nothing, a tokens-per-second figure computed
over a one-millisecond window — and each is a one-line invariant below.

## Seed, script, schedule, checks

```
  seed ──split──▶ script      what the server says and the operator does
       └─split──▶ schedule    how it arrives: order, batching, timing

  script + schedule ──▶ events ──▶ tui.update, one at a time
                                   │  every frame boundary
                                   ▼
                              render_frame ──▶ Buffer ──▶ the checks
```

**The script** is semantic and keyed by durable position, exactly as the
runtime simulator's is. It names the strands that exist, a sequence of
turns per strand (each an `OperationChanged` into `assistant`, zero or
more `StreamDelta`s of each kind, an optional tool phase with a call and
stderr, an `OperationChanged` to `done`, and one `UsageChanged`), the
snapshots the server would send (`FullSnapshot` at connect, catalogue and
schedule snapshots), escalations that pend and resolve, server errors,
and the operator's actions in between: prompt text typed and submitted,
a paste, a slash command from the real palette, a scroll, `/details`,
`/effort`, a steer while a turn is live, an abort, a session switch, a
`/quit`. Operator actions are keyed to positions in the server sequence
("after turn 2's first delta") so they mean the same thing under every
schedule.

**The schedule** is everything that is legitimately allowed to vary
without changing what the operator was told. Its taxonomy, each fault
transparent by definition:

- *Batching.* Several inbox messages drained in one tick versus one per
  tick; a whole reply arriving as one `StreamDelta` versus a hundred
  single-character ones (this is the Gemini shape that broke the rate).
- *Pacing.* The number of `Tick`s between events, which drives the
  activity indicator, the elapsed clock and the adaptive poll; the
  monotonic clock must be injected so a schedule can advance it by
  whatever it likes and the run stays deterministic.
- *Geometry.* A `Resize` at any point, drawn from a small set of widths
  and heights that straddle every layout threshold the code has
  (`footer_rows`' three regimes, the rail, the narrowest the input box
  survives) plus a few pathological sizes (1×1, 400×3, 20×80).
- *Interleaving across strands.* Events for a non-active strand landing
  between the active strand's deltas; the active strand switching
  mid-stream.
- *Connection.* `Closed` and reconnect (`Connected` followed by a fresh
  `FullSnapshot`) at any position; the model must come back to the
  snapshot's truth with no ghost of the stream it was watching.
- *Input bursts.* A paste and a keystroke in the same poll; a key
  arriving during the paced-frame window so the frame cache is exercised.

What is deliberately **not** a fault: anything the operator would
notice as different content. A different reply is a different script.

**The checks**, run on every rendered frame and on the final model:

1. *No panic, ever.* The run itself completes.
2. *Frame fits.* Every row is exactly the screen width in cells; no row
   is wider (wide glyphs count two); the buffer's area equals the
   screen.
3. *Layout is a function of the window.* `footer_rows` and the other
   layout decisions taken from `width`/`height` alone give the same
   answer for every frame at a given size within a run. The footer bug
   was exactly a layout decision that depended on content.
4. *Cursor is home.* When the prompt box has focus the cursor position
   lies inside the input area's interior; when a selector or palette has
   focus, inside it.
5. *No truncation without an ellipsis.* Any section the code compacts
   ends in `…` if it was cut; no section is cut to fewer than its label.
6. *Transcript is monotone.* Scrolling never passes the first or last
   line; the transcript at `done` contains every delta's text of the
   active strand in order, once each (a paced frame may lag, the final
   one may not).
7. *Footer tells the truth.* The usage summary equals the sum of the
   `UsageChanged` events seen; the agent count equals the strands the
   last snapshot named; the rate is absent when the generation window was
   under `output_rate_min_ms`, and otherwise within rounding of
   `output / window`.
8. *Reconnect is a reset.* After `Closed` then `Connected` +
   `FullSnapshot`, no stream text from before the close is on screen.
9. *Frame cache is honest.* A frame reused from the cache is
   byte-identical to what `render_frame` would produce for that model
   and screen; checked by rendering both on a sample of frames.

A violation prints the seed, the schedule description, the frame index,
the frame as text, and the check that failed — the same shape as the
runtime simulator's report — and the runner shrinks the schedule the
same way `fault.shrink` does before printing.

## Where it lives and what it reuses

In `packages/tui/test/simulation/`, not in `packages/conformance`: the
generator needs `Model`, `update` and `render_frame`, and the checks are
about frames. It reuses `conformance/simulation/random.gleam` verbatim
(seed, split, weighted picks, `list_of`) — move it into a small shared
package if the dependency direction objects, since `tui` must not depend
on `conformance`. It reuses the virtual backend's `run_script` for the
loop so the loop under test is the loop that ships, and `buffer_to_lines`
for the checks. It needs one thing the TUI does not yet have: an injected
monotonic clock. `ffi_bootstrap.monotonic_time_ms()` is called from
`update_tick`, the generation clock and the activity indicator; thread a
`clock: fn() -> Int` through `Model` (or a `Clock` record beside it) so a
schedule can own time. That is the only production change Part A needs,
and it is a refactor with no behaviour change.

`make sim-tui SIM_SEEDS=n SIM_FROM=n` mirrors `make soak`'s chunking, and
`make check-tui` runs a fixed small range (say 50 seeds) so the gate
catches a regression without the soak.

## Exit criteria

- A seed range of 2 000 runs clean in under two minutes on a laptop.
- Each of the three bugs found this week, reintroduced on a scratch
  branch, is caught within 200 seeds with the check named above.
- A violation report reproduces from its printed seed alone.

---

# Part B — the end-to-end run under the virtual backend (work package 5)

## What Part A cannot see

Part A feeds the model `connection.Message`s it minted itself, so it
proves the TUI is consistent with *what it was told*, never that the
server tells it the right things, that the wire decoders agree with the
wire encoders, or that a command the TUI sends actually does what the
footer then claims. `client/tui_e2e_test` covers that seam today through
tmux: it builds the TUI, boots a real server, launches the binary in a
pane and greps the pane. It is the right test and the wrong harness — it
depends on `tmux`, on a terminal's reflow, and on `wait_until` polling a
pane, so it runs once and slowly and asserts a few substrings.

## The shape

Replace the pane with the virtual backend, and the substrings with the
frame checks.

```
  conformance script ──▶ real loomd (scripted provider + tools, in-memory session)
                             │ websocket, real wire
                             ▼
                       real tui model loop under the virtual backend
                             │ every frame
                             ▼
                       Part A's checks + protocol checks + snapshots
```

- **The server** is booted the way `tui_e2e_test` boots it now
  (`serve.Booted`, an ephemeral port, a token), but its provider and
  tool effects are the conformance simulator's scripted surface
  (`conformance/simulation/surface.gleam`), keyed by phase and call id
  as the runtime simulator keys them. One seed picks the runtime script;
  the operator's actions are drawn from Part A's script generator with
  the server-side positions as their anchors.
- **The client** is the shipped `tui` module, driven in-process by
  `run_script` under the virtual backend with a real `connection`
  actor to the real socket. No binary is built, no PTY is opened, no
  `tmux` is required. The recording flag from the virtual-backend PR is
  on, so every run leaves a replayable recording beside its report.
- **Time** is the runtime simulator's `vclock` on the server side and
  Part A's injected clock on the client side, advanced together by the
  schedule. The wall clock does not appear.

## The checks it adds

10. *Wire round trip.* Every `Event` the server encodes decodes on the
    client to the same value (the client's `protocol.decode` against the
    gateway's encoder); every command the client sends decodes on the
    server to what the client meant. Today these are two hand-written
    codecs with no test that they agree.
11. *Command effect.* `/effort high` is followed by a `ConfigSnapshot`
    that says so and a footer that says so; `/model` to a catalogue
    entry changes the footer's model label to that entry; a steer
    while a turn is live appears in the next turn's projected context
    on the server (read through `surface.projection`) and in the
    transcript on the client.
12. *Settled frame equals snapshot.* At each operator-visible settling
    point (`main: done`), the frame equals a golden under
    `packages/tui/test/snapshots/e2e/`, normalised the same way Part
    A normalises. Goldens are per seed for a small pinned set of seeds
    and are regenerated with `LOOM_UPDATE_SNAPSHOTS=1`.
13. *Escalation path.* A tool call the policy refuses produces an
    `EscalationPending` the frame shows, an approval keystroke produces
    the grant, and the tool's result then appears — the whole
    two-channel path through the UI, never behind it.

## What it replaces and what it keeps

`client/tui_e2e_test` retires once Part B runs in `make check-client`
with a pinned seed set and `make e2e-tui SIM_SEEDS=n` runs the range. The
tmux-and-herdr route stays for what only it does: a session that
survives across an agent's turns so a person or an agent can sit down
and use the program. The earlier note
(`agent-driven-tui-testing.md`) argued for a `drive` verb set over tmux;
with record/replay in hand, the agent-native surface is `loom replay`
over a recording and the checks above, and a live pane is for
exploration rather than for tests.

## Exit criteria

- The existing `tui_e2e_test` scenario expressed as one Part B seed,
  green without `tmux` installed.
- The wire round-trip check runs over every `Event` and command variant
  (a variant added to either codec without the other fails the build).
- A 500-seed range clean; each violation reproduces from seed alone and
  ships a recording that `loom replay` renders.

---

# Order of work and hazards

Part A first: it is pure, fast, and the injected clock it needs is the
one production change both parts share. Part B after the virtual backend
and Part A have merged, since it composes both with the conformance
surface and any churn underneath it is paid twice.

Hazards, each already met once in this tree:

- *A check that always passes.* Assert the frame is non-trivial (the
  prompt border is present, the footer is present) before comparing
  anything; an empty buffer compared to an empty golden is the failure
  `docs/notebook.md` already records.
- *Timers on the wall clock.* Anything in the TUI that reads
  `monotonic_time_ms` directly is a source of nondeterminism the
  schedule cannot own. Grep for it and route it through the injected
  clock before writing a single generator.
- *Snapshot churn.* A golden that changes whenever a label's wording
  does is a golden nobody reads. Keep goldens few, at settled points,
  and put wording under the invariants rather than the snapshots.
- *Two codecs.* Part B's round-trip check is the reason the client and
  gateway codecs can be allowed to stay separate; without it, merge
  them.
