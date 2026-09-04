# Design note: agent-driven interactive testing

Status: **note, not a work package.** Captured while the idea is fresh;
nothing here is built. Promote to a numbered work package when the code
mode milestone closes.

> **Adoption update (2026-09-04).** Superseded in direction by
> `docs/design-notes/tui-simulation.md`. etui's backend is a record of
> functions, so a scripted virtual backend replaces the PTY and tmux
> layers below for testing; record/replay (`loom --record`, `loom
> replay`) is the agent-facing surface; and the seeded generator and the
> end-to-end run are briefed there as work packages 4 and 5. tmux and
> herdr remain the route for a session an agent uses across turns.
>
> **Adoption update (2026-08-31).** This note records the retired Go client
> and its proposed Bubble Tea test stack. Loom now ships the native Gleam
> `packages/tui` client. Its model tests and the real terminal/server scenario
> in `client/tui_e2e_test` cover the first two fidelity layers below; a
> persistent agent-facing tmux harness remains design work.

## The gap

Every layer of Loom is tested except the one a person actually touches.
`make check` proves the packages, `make e2e` proves the jailed effect
path, and the simulation runner proves convergence under scheduled
faults — but nothing proves that pressing `/models` renders a catalogue,
that a streaming strand paints without tearing, or that a rejected
code-mode program surfaces its rejection where a human can read it. The
TUI is a Go bubbletea program; its model is unit-testable, its
*rendering* and the human path through it are not tested at all.

The second half of the gap is that an agent cannot use Loom. It can run
the suite, but it cannot open the thing, type into it, and look at what
happened. Any bug that only appears in the rendered terminal is
invisible to the agent that would otherwise fix it.

## What such a harness must inherit

Loom already has the discipline this needs; the harness should reuse it
rather than invent a parallel world.

- **Determinism first.** The simulation runner's rule — seeded, no
  wall-clock, no ambient randomness — applies here too. A TUI test that
  sleeps is a flake with a delay. Fix `COLUMNS`/`LINES`/`TERM`, freeze
  the clock, drive spinners from injected ticks rather than real time,
  and take model responses from the existing provider fixtures.
- **The two-channel doctrine.** The harness drives the TUI *as a user*,
  through the same protocol a human drives it through. It must never
  reach behind the TUI into the gateway to set up state; if a scenario
  is unreachable through the UI, that is a finding about the UI.
- **Golden transcripts.** WP-T already keeps golden end-to-end
  transcripts. A captured pane is the same kind of artifact and should
  live beside them, diffed the same way.

## Three fidelity layers

Pick per test; they are cheap-to-faithful in order.

**L1 — in-process model tests (`teatest`).** Bubbletea ships
`x/exp/teatest` for golden-file testing of a model: feed messages, assert
the rendered view. No terminal, no binary, millisecond-fast. This is
where view logic and layout regressions belong, and most TUI tests should
be here.

**L2 — PTY harness.** Spawn the real `loom` binary under a pseudo-terminal
(`creack/pty`), write keystrokes to the master side, read the ANSI stream
back. Real binary, real escape sequences, no external dependency, fully
scriptable from Go. This is the natural home for `make tui-e2e`: it tests
the shipped artifact rather than a model in a test harness.

**L3 — tmux.** Run the server and the TUI in panes of a detached tmux
session; drive with `send-keys`, observe with `capture-pane -e` (which
preserves ANSI). Slower and depends on tmux, but it is the only layer
that survives *across agent turns*: a session started in one turn is
still there in the next, so an agent can genuinely sit down and use the
program, poke at it, and come back. It also naturally covers the
two-process story (does the server actually start with the TUI?) that a
single PTY does not.

## The agent-facing interface

The harness is only useful to an agent if it is a handful of verbs, not a
Go API. Something like `scripts/drive.sh` (or a small `loom-drive`
binary) over an L3 session:

```
drive start [--seed N] [--cols 120 --rows 40]   # boot server + TUI
drive keys  "/models" Enter                     # send-keys, literal + named
drive wait  --for "Baseten" --timeout 5s        # predicate on pane content
drive snap  [--name models-open]                # capture pane -> golden file
drive stop
```

`wait` is the load-bearing verb, and the reason to build this rather than
paste tmux invocations. The temptation is `send-keys` then `sleep 2` then
`capture-pane`, which is exactly the failure this project has already
been bitten by: a sleep that usually works reads as a pass until the day
it doesn't. Waiting on a *predicate over pane content* with a timeout,
and failing loudly on timeout with the pane dumped, is the difference
between a suite and a coin flip.

## Snapshots: text first, images on failure

The instinct is screenshots. For an agent, ANSI-preserving **text** is
strictly better: diffable, greppable, reviewable in a pull request, and
cheap in context, where a PNG costs a great deal and cannot be diffed.
So the golden artifact is `capture-pane -e` output, and the agent reads
it directly.

Images still earn their place for humans, on failure only: render the
captured ANSI to PNG (any of the terminal-to-image renderers will do) and
attach it beside the text diff. That keeps visual review available
without paying for it on every green run.

## Known hazards to design against

- **Resize churn.** A pane that reflows produces a diff unrelated to the
  change. Pin the geometry and refuse to run if the terminal disagrees.
- **Async streaming.** Provider deltas paint incrementally, so a capture
  taken mid-stream is legitimately different each run. Snapshot on a
  settled predicate ("the strand shows Finished"), never on a timer.
- **Cursor and styling noise.** Normalize trailing whitespace and cursor
  position before diffing, or every capture differs from itself.
- **The suite that always passes.** The lesson already recorded in the
  notebook — check the log, not the pipeline exit code — applies double
  here, because a TUI harness that silently captures an empty pane will
  happily compare it to another empty pane forever. Assert the pane is
  non-trivial before comparing it.

## Why it is worth building

Beyond regression coverage, this closes the loop the whole project is
about: an agent that can open Loom, drive it, see what a person would
see, and fix what it finds. That is the same promotion ladder code mode
describes, pointed at the harness itself.
