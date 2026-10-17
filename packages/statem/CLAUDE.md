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
Dependencies are `gleam_stdlib`, `gleam_yielder` and `qcheck`.

## Key types

One module, `statem`.

- `Spec(model, cmd, sut)` is a record of functions: `initial`, `command`,
  `precondition` (returns `Admission`, `Admit | Reject`), `next_model`
  (pure, symbolic), `new_sut` (one fresh system per execution), `execute`
  (`fn(sut, model_before, cmd) -> Result(sut, Violation)`), `finish` and
  `teardown`. Commands are plain data, never closures.
- `Violation(tag, detail)`. Shrinking accepts a candidate only if it fails
  with the original tag, so two bugs need two tags.
- `Config(test_count, seed, max_commands, max_shrinks)` via
  `default_config(seed:)` and `with_*`. There is no random default seed.
- `Failure(cmd)` carries seed, run index, violation, original and shrunk
  lists, failing step, shrinks accepted, candidates run, and `ShrinkEnd`
  (`ShrinkConverged | ShrinkBoundHit`).
- `check`, `check_run` (one run from `(seed, run)` alone), `replay` (one
  exact list; an inadmissible list is a `statem.precondition` violation),
  `report` (multi-line text for a `panic as`).

## How it works

Run `i` draws its list from `qcheck.seed(seed * 1_000_003 + i)`. The
generator is a hand-written `qcheck.Generator` threading the seed and the
model, keeping each command's whole shrink tree; a rejected draw is
retried up to eight consecutive times, then the list ends early. It never
uses `qcheck.bind`, which regenerates downstream values on a shrink.

Shrinking is its own greedy loop: delete a contiguous chunk (whole list,
halves, ..., single commands, at every offset), then replace one command by
a child of its shrink tree. Candidates are replayed through the
preconditions from `initial` and dropped unexecuted if any rejects; only
executed candidates spend `max_shrinks`.

## Invariants that break things

- `execute` receives the model BEFORE the command; `next_model` is applied
  by the driver, never by `execute`.
- `new_sut` must return a system sharing nothing with earlier ones; it is
  called once per run and once per executed shrink candidate. `teardown`
  runs after every execution that returns, not after one that crashes.
- Commands that name state by value shrink badly (deleting the creator
  makes users inadmissible); name state by index or position.
- Call counts of `new_sut`/`teardown` are not observable in a package that
  may not use `@external`; the tests check freshness through a per-system
  step counter instead.
- Not built, deliberately: parallel runs and linearizability, symbolic
  result variables, statistics, env-var seed overrides, a `qcheck.run`
  adapter, a `shrink_cmd` hook.
