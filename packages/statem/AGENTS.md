# statem

## Purpose

Stateful, model-based property testing on qcheck. A test describes a system
as a `Spec` (abstract model, command generator, precondition, pure
`next_model`, and an `execute` hook that runs a command on the real system
and checks it); `statem.check` generates admissible command lists, runs them,
and shrinks a failing list to a short one that fails the same way. It is a
testing library: consumers take it as a dev dependency
(`statem = { path = "../statem" }`). Nothing in `src` performs I/O.

Portable by rule. No `@external`, no `gleam_erlang`/`gleam_otp`, no `panic`
or `let assert` in `src`: R6 holds this package to the same subset as
`core`, `machine`, `prompt` and `session_view` (`lint/policy.portable_packages`),
and its tests pass on both `--target erlang` and `--target javascript`.
Dependencies are `gleam_stdlib`, `gleam_yielder`, `qcheck` and `exception`
(the last is JS-capable, already qcheck's own dependency, and is how a crash
in a consumer callback is caught).

## Key types

One module, `statem`.

- `Spec(model, cmd, sut)` is a record of functions: `initial`, `command`,
  `precondition` (returns `Admission`, `Admit | Reject`), `next_model`
  (pure, symbolic), `new_sut` (one fresh system per execution), `execute`
  (`fn(sut, model_before, cmd) -> Result(sut, Violation)`), `finish` and
  `teardown`. Commands are plain data, never closures. `new_sut`, `execute`
  and `finish` run under `exception.rescue`: a crash is a `Violation` tagged
  `statem.crash`, which shrinks like any other (same-tag rule).
- `Violation(tag, detail)`. Shrinking accepts a candidate only if it fails
  with the original tag, so two bugs need two tags.
- `Config(test_count, seed, max_commands, max_shrinks, shrink_retries)` via
  `default_config(seed:)` and `with_*` (`with_shrink_retries(n)`, default 1:
  a candidate still fails if any of n executions fails with the original
  tag; retries spend `max_shrinks`). There is no random default seed.
- `Failure(cmd)` carries seed, run index, violation, original and shrunk
  lists, failing step, shrinks accepted, candidates run, and `ShrinkEnd`
  (`ShrinkConverged | ShrinkBoundHit`).
- `check`, `check_run` (one run from `(seed, run)` alone), `commands` (the
  list run `i` generates, nothing executed; equals that run's
  `Failure.original`), `replay` (one
  exact list; an inadmissible list is a `statem.precondition` violation),
  `report` (multi-line text for a `panic as`).

## How it works

Run `i` draws its list from the `i`th 32-bit draw of a qcheck stream seeded
with `config.seed`, so the derivation is integer-exact on both targets for any
seed (seeds equal modulo 2^32 collide, qcheck's own limit); `check` threads
the stream, `check_run` and `commands` walk it. The generator is a
hand-written `qcheck.Generator` threading the seed and the model, keeping
each command's whole shrink tree; a rejected draw is retried up to eight
consecutive times, then the list ends early. It never uses `qcheck.bind`,
which regenerates downstream values on a shrink.

Shrinking is its own greedy loop. The whole-list deletion is offered once,
first. Then each round tries deleting a contiguous chunk of n/2, n/4, ..., 1
commands (a halving schedule, not every size) at every offset, then replacing
one command by a child of its shrink tree. Candidates are replayed through
the preconditions from `initial` and dropped unexecuted if any rejects. Only
executions spend `max_shrinks` (each retry too); inadmissible candidates are
free against it but capped at a fixed 250000 per shrink so an infinite
hand-built tree terminates. Either bound ending the search with an
admissible candidate untried is `ShrinkBoundHit`. The search is one
self-tail-recursive function (`search`): a mutual recursion costs a stack
frame per candidate on JavaScript and overflowed on wide trees.

## Invariants that break things

- `execute` receives the model BEFORE the command; `next_model` is applied
  by the driver, never by `execute`.
- `new_sut` must return a system sharing nothing with earlier ones; it is
  called once per run and once per shrink execution. `teardown` runs on every
  path where a system exists, crashes included, and never escapes (its own
  crash is discarded). When `execute` returns `Error` or crashes, `teardown`
  receives the last good system, the one BEFORE the failing command.
- Commands that name state by value shrink badly (deleting the creator
  makes users inadmissible); name state by index or position.
- Call counts of `new_sut`/`teardown` are not observable in a package that
  may not use `@external`; the tests check freshness through a per-system
  step counter instead. The retry policy lives in `statem/internal/retry`,
  a pure function taking an injected `run(attempt_index)`, so tests drive it
  with a `run` that fails on chosen attempts; no test needs FFI.
- Not built, deliberately: parallel runs and linearizability, symbolic
  result variables, statistics, env-var seed overrides, a `qcheck.run`
  adapter, a `shrink_cmd` hook.
