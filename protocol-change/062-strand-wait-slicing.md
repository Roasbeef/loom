# protocol-change/062 — slice `strand.wait` windows in the satellite stub

**Status**: ACCEPTED 2026-10-02, on the owner's confirmation after the merge · **Affects**: WP-N `cap/strand` `wait` ·
**Raised by**: code-mode orchestration use · **Implemented**: cap + tools (prelude regeneration), merged in #719 on the owner's authorization

## Problem

A program running under `code_mode` (seam: orchestration) can name a join
window larger than the harness's per-call wait ceiling. `client/agency`
clamps every `agent_wait`/`strand.wait` that reaches it to
`config.max_wait_ms` (30 s), by design — the ordering against
`client/codemode.default_call_timeout_ms` (120 s) is documented and pinned
(`client/test/client/codemode_test.gleam:the_wait_ceiling_wins_the_race_test`).
`cap/strand.wait`'s stub, however, forwards the program's `within_ms`
verbatim as one capability call, so a program that asks for
`within_ms: 880_000` against a child that takes two minutes observes the
join "complete" after 30 s with every long-running handle `Pending` —
not because the deadline the program named expired, but because the
harness's own per-call ceiling did. The program's requested deadline and
the observed behaviour disagree, and nothing in the answer distinguishes
"your window elapsed" from "my ceiling clamped your window".

This was observed with a real orchestration program: a single-child
review fan-out with `strand.map(assignments, within_ms: 880_000)` came
back `needs_attention` with no findings, because the child needed more
than 30 s.

## Proposal

Keep the harness contract exactly as it is — one bounded capability
call, clamped at `max_wait_ms`, answered with `Pending` rather than
hanging — and make the *satellite-side stub* honor the program's
requested window by slicing:

- `cap/strand.wait` now issues `strand.wait` capability calls of at most
  `max_wait_slice_ms` (30 s, matching the documented agency ceiling) at a
  time, re-joining only the handles that came back `Pending`, until all
  handles settle or the program's requested `within_ms` is spent.
- The final answer is unchanged in shape: one `Waited` per handle in the
  caller's order, `Ready` for settled handles, `Pending` with
  `waited_ms` accumulated across slices for those still unsettled at the
  program's own deadline.
- An empty handle list still makes no host call and answers `Ok([])`.
- Each slice remains one bounded capability call judged by the same
  Agency, the same `Caller`, the same lineage rules; a mid-sequence
  refusal settles in band exactly as a single refused join does today.

No wire field changes, no new capability, no change to the Agency or to
`agent_wait`. The harness-side ceiling continues to fire first on every
individual call, which is what keeps the ordering against
`default_call_timeout_ms` intact.

## Alternatives and cost

**Tell the program to re-join on `Pending` itself.** This is what the
recipe prose prescribes and it remains valid — `Pending` is still an
answer, and `strand.map` still stops admitting at one. But it makes the
parameter the program passes a lie: `within_ms: 880_000` names a window
the stub has no intention of honoring, and every orchestration program
that names a plausible review budget re-implements the same re-join loop
with the same accounting for accumulated `waited_ms`. The loop pays
nothing per capability call — `strand.wait` deliberately carries no
admission ceiling for exactly this reason
(`codemode/test/codemode/orchestration_test.gleam:the_uncapped_calls_are_uncapped_test`)
— so the slicing loop reintroduces no turn economics; it reuses the same
economics a hand-written program loop would have.

**Raise `max_wait_ms`.** Rejected: the 30 s ceiling is argued from
steering latency (a wait holds the strand's batch open, and a human
steering that strand is committed but undrainable until the batch ends)
and from the cross-package ordering against the satellite host's call
timeout. Raising it would trade a documented safety property for one
caller's convenience.

**The residual cost of slicing.** A child that never settles now holds
its slice of the strand for up to the program's full requested window
rather than returning after 30 s. That is what the program asked for,
but it is a real behaviour change: a program that previously got control
back after 30 s to inspect its roster or abandon the join now blocks
until its own deadline. `Pending` after 30 s remains available to any
program that wants it — by naming `within_ms: 30_000`. The execution's
own wall deadline remains the outer bound, as it does for every program
loop; a program naming a window beyond its execution budget is cut off
by the wall, exactly as a hand-written re-join loop would be.


**Why the slice bound is not a second ceiling.** `max_wait_slice_ms`
matches the shipped `max_wait_ms` but is not a second copy of it: the
loop measures each slice by the host's own reported `waited_ms`, so a
host whose ceiling is configured lower is accounted by what actually
elapsed, never by the slice this module requested. The bound governs
how many requests a long join is split into, not how time is counted.

**A cousin that stays as it is.** `execution.receive` bounds its own
`within_ms` at 30 s and the async host *rejects* a longer wait as
`invalid_argument` rather than silently shortening it — a program naming
an over-long receive gets an honest refusal to act on, not a quietly
clamped window, so that seam keeps its own behaviour and needs no
slicing of its own.

## Doc impact

`cap/strand`'s `wait` doc comment now states the slicing, the prelude
rendering is regenerated (`make gen-prelude`), and `packages/cap`'s
`CLAUDE.md`/`AGENTS.md` mention `max_wait_slice_ms`. `Pending` as an
answer the program may act on is unchanged and remains the contract for
`strand.map`, which still stops admission at the first unresolved child.
