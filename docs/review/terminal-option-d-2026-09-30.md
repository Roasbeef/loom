# Option (d) for the terminal revamp: measured costs

Measured on macOS on 2026-09-30 at `f9927f7d9` (`main`), with Gleam
1.19.0-rc2 and OTP 29. Nothing in `packages/` was changed. This answers the
first item of `docs/next.md`: whether the terminal revamp
([#655](https://github.com/Roasbeef/loom/issues/655)) takes option (d) first.
The option is recorded in ADR-014 (`docs/adr/014-second-runtime.md:366`) and
on #569: move the terminal onto `session_view/step.update` by passing a pure
callback that the sequencer applies after each piece, so that the terminal
and the web view run one sequence instead of the terminal's copy being held
to it by a test. The ADR names three costs: callbacks threaded through the
step, a reordering risk that the replay identity checks would catch, and the
Erlang inliner's cost on long settle chains. This report measures each.

The result in one paragraph: the first and third costs are below what this
machine can resolve, and the second is real but is a design cost, not a
performance one. The callback the ADR describes cannot be the whole
interface, because the terminal's tick has five terminal-only drains that
run between shared pieces and can replace the lane mid-tick. The
recommendation, at the end, is to take option (d) later and not as a
prerequisite of the revamp.

## How the two hosts step today

The terminal and the web view share the units and the drain, and differ in
who composes them.

The terminal's tick is `update_tick` (`packages/tui/src/tui/tick.gleam:139`).
In order it does: the recorded-replay drain (`drain_replay`, line 223); the
activity clocks and the glyph (`advance_activity_indicator`, line 261); the
strip's roster clock (`inbound.tick_strip`,
`packages/tui/src/tui/inbound.gleam:1161`); the daemon-control, candidate,
reconnect, activity and configuration drains; and the connection drain
(`inbound.drain_connection`, `packages/tui/src/tui/inbound.gleam:373`). It
then passes the drained model to `settle_tick` (`tick.gleam:167`), which
runs the eight side-surface reads (`session_step.service_reads`), the
terminal's activity read, the block-summary read, the lane's tick
(`inbound.tick_channel`, `packages/tui/src/tui/inbound.gleam:154`) and the cache-outlook label.
After that, `settle_update` (`packages/tui/src/tui.gleam:2135`) runs the
worktree request for a newly shown diff, the shared settle
(`session_step.settle`), the Herdr report, the projection, the viewport snap
and the frame decision.

Every lane update in the drain goes through `inbound.apply_channel_update`
(`packages/tui/src/tui/inbound.gleam:184`), which reads what the terminal shows
(`inbound.surroundings`) before the update and applies the recorded surface
facts after it (`inbound.settle_surfaces`, `packages/tui/src/tui/inbound.gleam:476`, through
`run_settled`, `packages/tui/src/tui/inbound.gleam:507`). The later update in the same drain
reads what the earlier one wrote (`packages/tui/src/tui/inbound.gleam:440-475`, the doc comment of
`settle_surfaces`).

The web view's message is `step.update` (`packages/session_view/src/session_view/step.gleam:376`).
A tick runs `tick` (`step.gleam:489`): activity clocks, roster clock, the
drain of every held frame (`drain_connection`, line 519), `service_reads`,
the lane's tick (`tick_lane`, line 568), then the settle and
`forget_surfaces`. Each lane update is applied with
`lane_fold.nothing_shown()` (`apply_update`, line 559), because that host has
no diff, notes surface or approval inspector. The component calls it from
`stepping` (`packages/web_view/src/web_view/component.gleam:1030`, call at
1037) and, for a command, from `commanded` (line 2093, call at 2104).

Both hosts already pass closures per piece. `operator.drain`
(`packages/session_view/src/session_view/operator.gleam:184`) takes a `take`
and a `handle` function and calls each once per frame, and the terminal's
`run_shared` (`packages/tui/src/tui/model.gleam:766`) and `run_settled` take a
reducer closure per call. Option (d) would add a host closure beside
these, not introduce the first one.

### What option (d) would change

The sequencer is `step.tick`. The callback would be applied after each of its
pieces: after the clocks, the roster, each lane update of the drain (once per
update, not per frame, since `receive_frame` folds a frame's updates,
`step.gleam:544-555`), the reads, each update of the lane's tick, and the
settle. That is at least five calls per tick plus one per lane update. A
64-frame burst makes at least 64 more.

Reading the source, a callback of type `fn(view, facts) -> view` is not enough
for the terminal, for three reasons.

1. The terminal reads its surfaces before each update. `surroundings` takes
   the model (overlay, notes surface, worktree) and the update's decisions
   read it. A callback that only runs after a piece cannot supply it, so the
   host needs a second hook before each update (`Surroundings` in, facts out).
2. Five terminal-only drains sit between the roster and the connection drain,
   and one of them (`drain_candidate`, `tick.gleam:590`) adopts a new lane
   and inbox, which the connection drain must then read
   (`packages/tui/src/tui/inbound.gleam:348-353`). A callback over `view` cannot replace
   `shared.channel`. The hook must take and return the whole model, or the step
   must name slots (before the drain, between the reads and the lane's tick)
   at which the host runs its own drains.
3. The terminal's key handlers run a command and then write their own state
   before the event's settle, which is why ADR-014 kept `Acted` out of the
   terminal (`docs/adr/014-second-runtime.md:351-364`). Moving key events onto
   `update` needs the same hooks and a decision about where the settle runs.

These are estimates from reading the code, not measurements. They matter for
cost 2.

## Cost 1: callbacks through the step

Commands, all from a built `packages/tui` (`gleam build` exit 0), one fresh
VM on one scheduler per run:

```sh
bash scripts/tui_perf.sh "$PWD" optd1 events   # then optd2, alternating
bash scripts/tui_perf.sh "$PWD" optd1 burst 64 # then optd2
bash scripts/tui_perf.sh "$PWD" optd1 render 200 50
bash scripts/tui_perf.sh "$PWD" optd1 growth 512
```

There is one tree, so the two labels measure the harness's run-to-run noise,
which is the floor any callback cost must clear.

| Scenario | Reductions (run 1 / run 2) | Words | Time median (run 1 / run 2) |
| --- | ---: | ---: | ---: |
| Key | 79,358 / 79,358 | 182,617-185,628 | 0.38 ms / 0.44 ms |
| Idle tick | 4,555 / 4,555 | 6,578-8,214 | 25 us / 25 us |
| Tick, 64 frames waiting | 201,403 / 201,934 | 488,091-509,935 | 3.71 ms / 3.99 ms |
| Key, 64 frames waiting | 202,464 / 202,729 | 494,184-494,245 | 3.49 ms / 3.68 ms |
| Burst of 64, per frame | 6,491.0 / 6,491.0 | 14,146.7 | 80.7 us / 83.1 us |

The burst is three ticks. One frame of a 200 by 50 paint is 362,247
reductions and 824,393 words (3.08 ms), and forty scroll events are
17,551,285 reductions; the rendering witness hash is the one recorded in
`docs/review/tui-render-cpu-2026-09-29.md`, so the tree is the one that
report left. Per-frame cost grows with the reply: 3,230 reductions per
frame at 64 frames, 5,196 at 512 (`growth 512`).

Two runs of the same tree differ by 0.26% in reductions on the 64-frame tick
and by up to 4% in words across samples, and by 4-15% in time. That is the
resolution.

### Closure call overhead

A throwaway Erlang micro-benchmark (not committed; written in the session's
scratch directory, `optd_bench.erl`) measured a loop of one million pieces,
each writing one field of an 8-element tuple, with (a) a direct local call to
the host's unit, (b) a call through a closure capturing one value, and (c) two
closures, one producing a `surroundings` tuple and one consuming it. Median
of five, one scheduler, two runs:

| Shape | ns per piece |
| --- | ---: |
| Direct local call | 27.4, 27.6 |
| One closure | 27.2, 26.7 |
| Two closures, one allocating a tuple | 33.4, 33.1 |

The BEAM counts a call through a fun as one reduction. A second hook costs
about 6 ns and one tuple.

### Estimate

The added work is one or two fun calls per lane update. At two per update and
three updates per frame, that is about 40 ns against 80,700 ns per frame in
the burst, 0.05%; counting words at a generous ten per piece, 60 words
against 14,147 per frame, 0.4%. Both are an estimate from the micro-benchmark,
and both are below the run-to-run spread in the table above. The terminal's
existing per-update work (`surroundings`, `settle_surfaces`) already runs at
every update today, so option (d) moves it behind a call without adding it.

One cost this does not bound: widening the state `operator.drain` threads from
`Shared` to the whole `Model` copies a 3-word outer record per piece, as
`hold_shared` does now (`packages/tui/src/tui/model.gleam:726`). No figure
here isolates that, because it would need the change itself.

## Cost 2: reordering risk and what catches it

The checks that hold the two hosts to one order today are three.

1. `session_view/step_test`'s
   `a_tick_runs_the_terminals_units_in_its_order_test`
   (`packages/session_view/test/step_test.gleam:243`). It compares `step.update`
   against `as_the_terminal_ticks` (line 185), a hand-written copy of the
   terminal's order over the shared record. It does not call
   `tui/tick.update_tick`.
2. `client`'s `one_script_leaves_both_hosts_in_one_engine_state_test`
   (`packages/client/test/client/web_view_parity_test.gleam:553`). The terminal
   side steps with `ticked` (line 466), again a hand-written chain:
   `service_reads`, `tick_channel`, `settle`. A frame reaches it through
   `inbound.accept_connection_message`, not through the tick's drain, and the
   script delivers one frame per step, so a multi-frame drain is not compared.
3. The terminal's own suite, which does call `tui.step`: 986 tests at the
   last signoff (`docs/design-notes/step-extraction.md:1976-1982`), the golden
   recording (`packages/tui/test/recording_effects_test.gleam:53`) and the
   replay snapshot (`replay_round_trip_snapshot_test`,
   `packages/tui/test/tui_test.gleam:2255`). `loom replay --all --plain` is
   named in the design note and ADR-013/014 as a manual comparison and is not
   in any gate (`grep` over `Makefile`, `scripts` and `.github` finds nothing).

So the claim in the ADR that the replay identity checks would catch a
reordering holds for the terminal's own behaviour (check 3) and does not hold
for the relationship between the hosts: checks 1 and 2 compare the step to
copies, and a drift in `update_tick` fails neither. That is the case for
option (d): after it, the copies are deleted and checks 1 and 2 become
statements about one function.

Orderings the terminal performs that a shared step would have to either
preserve through hooks or change:

| Terminal today | Shared `step.tick` | Source |
| --- | --- | --- |
| Recorded-replay drain first, then the clocks | No replay drain; clocks first | `tick.gleam:141` |
| Roster clock only when the strip has height | Roster clock always | `packages/tui/src/tui/inbound.gleam:1161`, `step.gleam:505` |
| Control, candidate, reconnect, activity and configuration drains between roster and connection drain | None | `tick.gleam:142-145` |
| Activity read and block-summary read between the side-surface reads and the lane's tick | Reads then lane tick only | `tick.gleam:170-173` |
| Surface facts applied after every update, before the next reads state | Facts dropped once at the end | `packages/tui/src/tui/inbound.gleam:476`, `step.gleam:499` |
| Worktree request for a newly shown diff before the settle edges | No such request | `tui.gleam:2136-2139` |
| Key events: drain before the action, no tick | `Acted` settles inside `update` | `tui.gleam:2054`, ADR-014:351 |

Of these, the existing checks would catch a change in the row for the drain
placed against the reads (step_test mutates exactly that, per
`docs/architecture/terminal.md:187-190`) and, through the terminal's suite,
most terminal-only rows. No check was run against a deliberately reordered
terminal for this report: doing so needs a change to `packages/tui`, which
this task excluded. The claim that the suite would catch each row is
therefore unmeasured.

## Cost 3: the inliner on long settle chains

Gleam 1.19 writes abstract forms (`.abstr`) rather than `.erl`, so
`skills/beam-compile-review/scripts/profile_module.py` finds no source. The
figures come from `compile:forms` with `time` and `inline` over the `.abstr`
files of this build, as the design note did (`step-extraction.md:1787-1790`),
from a throwaway escript in the scratch directory. Median of three, wall time
of the compile call and `core_inline_module`:

| Module | Total | `core_inline_module` | Largest pass |
| --- | ---: | ---: | --- |
| `session_view@step` | 0.106 s | 0.009 s | `beam_ssa_opt` 0.047 s |
| `session_view@commands` | 0.218 s | 0.020 s | `beam_ssa_opt` 0.093 s |
| `session_view@surfaces` | 0.237 s | 0.020 s | `beam_ssa_opt` 0.104 s |
| `session_view@lane_fold` | 0.484 s | 0.040 s | `beam_ssa_opt` 0.204 s |
| `session_view@event_fold` | 0.507 s | 0.042 s | `beam_ssa_opt` 0.223 s |
| `tui` | 0.181 s | 0.014 s | `beam_ssa_opt` 0.087 s |
| `tui@tick` | 0.091 s | 0.005 s | `beam_ssa_opt` 0.041 s |
| `tui@inbound` | 0.372 s | 0.019 s | `beam_ssa_opt` 0.178 s |
| `tui@submit` | 0.434 s | 0.024 s | `beam_ssa_opt` 0.194 s |
| `tui@session_control` | 0.491 s | 0.036 s | `beam_ssa_opt` 0.233 s |
| `tui@interaction` | 1.513 s | 0.102 s | `beam_ssa_opt` 0.674 s |

`beam_ssa_opt` dominates every module and `core_inline_module` is between 4%
and 9% of each. Nothing here resembles the failure in
`docs/execution.md:553-590`, where `core_inline_module` was the whole time (51
s in `update_tick`, 75 s for the package). The recorded hazard is N local
steps applied to an expensive expression, re-visited about 2^N times; both
chains that matter are applied to a parameter. The tick's is explained in the
comment at `packages/tui/src/tui/tick.gleam:150-158`, and the event's in the
comment above `apply_input` (`packages/tui/src/tui.gleam:2054`).

### Ablation: a callback after each piece

I pretty-printed the `session_view@step` forms to Erlang in the scratch
directory (`optd_pp.escript`), and made a copy in which `tick` takes a host
function `H` and applies it after each of its five pieces and after each lane
update in `receive_frame` and `tick_lane` (`optd_ablate.py`). `H` is a
parameter, so each call is a call to an unknown fun, which the inliner does
not attempt. Both copies were compiled with `erlc +inline +time`, five runs
alternating, with the same options:

| Copy | `core_inline_module` per run | Wall per run |
| --- | --- | --- |
| Original step | 0.015, 0.015, 0.015, 0.015, 0.015 s | 0.35-0.38 s |
| With `H` after each piece | 0.017, 0.016, 0.014, 0.015, 0.015 s | 0.36-0.47 s |

Wall time includes `erlc` start-up and is noisy; the inliner's time is the
same. This is the skill's "focused ablation in a temporary copy of generated
Erlang", not a validation of a Gleam change. It threads a `Shared -> Shared`
function, which is narrower than the two-way hook of the section above.
The copy is throwaway and was not committed.

I also generated 12 synthetic modules (`optd_gen.py`) with chains of 6, 12 and
18 local steps applied either to a dispatch expression or to a parameter,
with and without a host call after each. `core_inline_module` ran 0.009 to
0.022 s and rose by at most 0.003 s with the host calls. The synthetic
modules did not reproduce the 2^N failure in the bad shape either, so they
bound only the cost of the unknown calls, and they say nothing about the
real hazard.

### Estimate

Option (d) would remove, not add, a chain in the terminal: `update_tick` and
`settle_tick` would become calls into the step. Added local steps in
`session_view/step.gleam` would be calls to a fun parameter. The design note's
rule still applies, since it is the reason this holds: every local step added
to a chain applied to an expensive expression is the risk, and a call through
a parameter is not a step. The estimate is no measurable change, which the
ablation supports. The unmeasured case is the terminal's own slots, where the
hooks would be local functions in `tui/tick.gleam`; each needs the measurement
the design note asks of every landing (`step-extraction.md:2079-2088`).

## Recommendation

Take option (d) later, and do not make it a prerequisite of #655.

The performance evidence does not argue against it. A closure call costs
about a reduction and 0 to 6 ns; threading a host function through the step's
tick left `core_inline_module` at 0.015 s.

The evidence against doing it first is the interface. The hook the ADR
describes is one callback over `view`, and the terminal needs a before-update
read, slots for five drains that can replace the lane, and a decision about
where key events settle. That is a redesign of the step's host interface, with
the terminal's 986-test suite and a golden recording as its only real guard,
and the revamp it would precede is layout, theme and panels, which live in
`tui/render`, `tui/layout` and `View` and do not touch the sequence.

The benefit is real and separable: the two copies of the terminal's tick in
`step_test` and in the parity test are not the terminal's tick. A smaller
change gets most of that benefit without (d): have the parity test drive
`tui.step` with `msg.Ticked` through `runtime.receive`, so a drift in
`update_tick` fails a test against the page. This report did not try it; it
might need the terminal-only pieces (summaries, cache outlook) to be quiet in
the script, which they are not guaranteed to be.

Conditions that would change the recommendation:

- The revamp adds a session surface whose facts must be applied between lane
  updates in both hosts, so the terminal needs the page's sequence exactly.
- A second reordering defect between the hosts is found that neither copy
  catches. One is evidence; the copy is the cause.
- The terminal gains a drain that changes shared state outside `tick.gleam`,
  which would widen the gap above.
- A prototype on a branch shows the before-update and drain slots fit in one
  `Host` record with `core_inline_module` on `tui@tick` and `session_view@step`
  unchanged. That is the measurement this report could not make.

## What was not measured

- The step's tick with a real two-way host in Gleam. A change to
  `packages/session_view` and `packages/tui` was out of scope, and an in-place
  edit of `step.gleam` for the experiment was refused by the session's
  permission check. The ablation above is on a scratch copy of generated
  Erlang instead.
- `web_view@component`, not built here; its figure is 0.17 s with
  `core_inline_module` 0.014 s from the S5 landing
  (`docs/design-notes/step-extraction.md:1985-1987`).
- Whether the terminal suite, golden recording and replay snapshot fail for
  each row of the ordering table. That needs deliberate reorderings.
- The idle-tick effect of `Model` versus `Shared` as the drained state, for
  the reason given under cost 1.
- Linux or hosted CI timings. All numbers are one macOS machine.
