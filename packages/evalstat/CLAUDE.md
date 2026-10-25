# evalstat

## Purpose

The statistics behind Loom's evaluation instrument (ADR-021, issue #236):
the estimators, tests and decision rule that turn paired trial rows into a
verdict of improved, harmed, indistinguishable or underpowered. It is the
one piece of the instrument whose correctness is mathematical, so it is
pure, stdlib-only and property-tested on fixed seeds, and both the
developer instrument (`packages/eval`) and the governed
`client/evolution/rollout.verdict` call the same functions.

Portable by rule. No `@external`, no `gleam_erlang`/`gleam_otp`, no
`panic` or `let assert` in `src`: R6 holds this package to the same subset
as `core`, `machine`, `prompt`, `session_view` and `statem`
(`lint/policy.portable_packages`). Randomness comes from a seeded PRNG in
pure Gleam, never from the runtime.

## Dependencies

`gleam_stdlib` only; `gleeunit` and `qcheck` for tests. Nothing in Loom
depends on it yet except `eval`.
