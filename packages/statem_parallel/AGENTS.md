# statem_parallel

## Purpose

Parallel model-based testing on `statem` and qcheck: does a concurrent system
behave like its sequential model when several callers use it at once? A
`Spec` describes the model and the system; `check` generates a `Case` (a
sequential prefix and two or three branches), runs the branches at the same
moment, and asks `statem/linearize` whether the histories have an order the
model agrees with. A failure is shrunk to a small case and reported with the
failing history and where the search for an order got stuck. Testing library:
consumers take it as a dev dependency. BEAM-only (`gleam_erlang`,
`gleam_otp`, `weft`), so it is deliberately NOT in `lint/policy.
portable_packages`; the pure checker lives in `packages/statem` for that
reason.

## Key types

- `Spec(model, cmd, sut, response)`: `initial`, `command`, `precondition`
  (`statem.Admission`), pure `next_model`, `new_sut`, `run(sut, cmd) ->
  response`, `postcondition(model, cmd, response) -> Result(Nil,
  statem.Violation)`, `teardown`. `run` is called from several processes at
  once and must be safe for that; `sut` is a shared handle (subject, pid
  client), never a value. `new_sut`, `run`, `postcondition`, `next_model`
  and `teardown` are rescued: a crash is a `statem.crash` violation
  (teardown's is dropped), so teardown runs on every path.
- `Case(cmd)(prefix, branches)`.
- `Config` via `default_config(seed:)` and `with_*`: `test_count` (100),
  `branches` (2, clamped 2..3), `max_prefix` (6), `max_branch` (4, clamped
  1..6), `max_shrinks` (500), `shrink_retries` (10), `repeat` (3),
  `shrink_stop`, `deadline` (10 s, the parallel phase only), `search_budget`
  (checker nodes, 100_000). No random default seed.
- `Failure(cmd, response)`: seed, run, violation, original and shrunk
  `Case`, `Evidence` (`InPrefix(step)`, `Raced(histories, explanation)`,
  `Unrecorded`), shrinks accepted, executions, `statem.ShrinkEnd`.
- `check`, `check_run`, `generate_case` (a case from `(seed, run)` alone),
  `report(failure, describe)`.

Violation tags: the spec's own for a prefix failure; fixed ones for the
rest, so a shrink stays on the failure it found: `statem.not_linearizable`,
`statem.undecided`, `statem.timeout`, `statem.crash`.

## How it works

Run `i` takes the same per-run seed as `statem` (`statem.run_seed`). The
prefix is drawn with `statem.grow`; each branch is drawn from the model after
the prefix, as if alone. A case is admissible only if every command's
precondition holds in every interleaving of the branches
(`internal/interleave` enumerates them while there are at most 10_000;
past that the longest branch is trimmed). An inadmissible draw, or one that
left fewer than two branches, is redrawn up to eight times, then trimmed
command by command, so generation always ends with an admissible case.

An execution builds one system, runs the prefix call by call checking each
response against the model (a prefix failure races nothing), then
`internal/runner.race`: one weft task per branch, `limit` set to the branch
count (weft's default is the scheduler count, and a barrier between more
branches than slots deadlocks), each task parks on a go subject until the
coordinator has all of them, then calls in order reading weft's monotonic
clock (milliseconds) around each call. The weft deadline kills and joins
what has not finished; an unfinished branch is `statem.timeout`, a crash
outranks it. The prefix is NOT deadline-bounded. The histories go to
`linearize.check` with the post-prefix model.

The seed fixes the case, never the interleaving. `repeat` runs a generated
case several times before it counts as passing; `shrink_retries` accepts a
candidate if any attempt fails with the original tag (`statem.first_failure`).
Shrink candidates, in order: drop a branch (while more than two), merge two
branches, delete one command from a branch, delete from the prefix, move a
branch's first command to the end of the prefix. Each must be admissible.

## Invariants that break things

- `run` shared across processes: a `sut` that is a plain value is copied
  into each branch process and nothing races.
- Millisecond instants: calls that fit in one millisecond are treated as
  overlapping, which hides ordering constraints but cannot invent a failure.
- A racy bug may need `repeat` and `shrink_retries` above one; tests that
  make a race near-certain (a two millisecond pause between a read and a
  write) still keep both.
- A crash that kills the system's own linked process kills the test
  process; crash `run`, not the actor, in tests.
- Not built, deliberately: symbolic result variables, coverage labels,
  scheduler instrumentation beyond the start barrier, a deadline on the
  prefix.
