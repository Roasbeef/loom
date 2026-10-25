# evalstat

## Purpose

The statistics behind Loom's evaluation instrument (ADR-021, issue #236,
`docs/design-notes/eval-instrument.md` §5): the estimators, tests and
decision rule that turn paired trial rows into a verdict of improved,
harmed, indistinguishable or underpowered. It is the one piece of the
instrument whose correctness is mathematical, so it is pure, stdlib-only
and property-tested on fixed seeds, and both the developer instrument
(`packages/eval`) and the governed `client/evolution/rollout.verdict` call
the same functions.

Portable by rule. No `@external`, no `gleam_erlang`/`gleam_otp`, no
`panic` or `let assert` in `src`: R6 holds this package to the same subset
as `core`, `machine`, `prompt`, `session_view` and `statem`
(`lint/policy.portable_packages`). Randomness comes from a seeded PRNG in
pure Gleam, never from the runtime, and the test suite runs on both
targets (`gleam test --target erlang`, `gleam test --target javascript`).

## Modules, in reading order

- `evalstat/trial` — `Trial(task, arm, index, reward, scores, outcome,
  cost)`, `Outcome`, `Cost`, and the failure ruling: `standing(outcome)`
  returns `Counted(Pass | Fail)` or `Excluded`. `AgentTimeout` and
  `SafetyRefusal` are failures; only `Infrastructure` is excluded.
- `evalstat/pairing` — `pair(rows, baseline, candidate, expected)` turns a
  ledger into `Paired(tasks, infrastructure_rows, dropped_pairs)` over the
  plan's `(task, index)` set (`plan(tasks, trials)` builds it), or a
  `PairingError` (`MissingRow`, `DuplicateRow`, `UnplannedRow`) that the
  decision rule turns into `Incomplete`. A pair with an excluded side is
  dropped whole and counted.
- `evalstat/binomial` — `log_choose`, `half_cdf`: exact log-binomial
  arithmetic for `n ≤ 1000`.
- `evalstat/mcnemar` — `discordant(paired) -> Discordant(b, c)` and the
  exact two-sided sign test `p_value`.
- `evalstat/paired` — `differences`, `mean`, `clustered_se`, `interval`,
  `mde`, `needed_tasks`, `decompose -> Decomposition(between, within,
  lever)`, `arm_rates`. `z_alpha = 1.96`, `z_power = 0.84`.
- `evalstat/bootstrap` — `interval(paired, resamples, seed)`: tasks with
  replacement, pair positions within each task with replacement, the same
  position for both arms. Percentile 2.5/97.5. `default_resamples = 2000`.
- `evalstat/prng` — xorshift128 on 32-bit words (not xorshift64*: see the
  module doc for the JavaScript exactness argument), seeded from a string
  by salted FNV-1a. `from_string`, `next`, `below`, `unit`, `fnv1a`.
- `evalstat/passk` — unbiased `pass_at_k`, `pass_pow_k`, and the per-task-
  then-averaged `arm_pass_at_k` / `arm_pass_pow_k`; `k > n` is an `Error`,
  never zero.
- `evalstat/verdict` — `Verdict`, `Policy(target_effect, interval)`,
  `Interval { Clustered | Bootstrap(resamples, seed) }`, `Stop`,
  `default_policy()` (target 0.10, clustered).
- `evalstat/dominance` — `compare(verdict, candidate_scores,
  baseline_scores) -> Dominance`: outcome first and lexical, then Pareto on
  shared score names; `Tradeoff` is reported, never resolved.
- `evalstat` — `paired_verdict(rows, baseline, candidate, expected,
  policy)`, `decide(paired, policy)`, `futility(rows_so_far, baseline,
  candidate, remaining_pairs)`, `futility_from_counts`. `alpha = 0.05`.

## Invariants that break things when violated

- **The plan is the denominator.** `expected` comes from the plan, never
  from the rows; a missing row is `Incomplete`, not a smaller `n`.
- **Timeouts and refusals are failures.** Changing `trial.standing` is
  changing the instrument's claim; `timeouts_are_failures_not_excluded_test`
  guards it.
- **The task is the cluster.** Every error estimate is over per-task
  differences `d_t`; `T < 2` is `Underpowered(mde: 2.0, needed_tasks: 2)`,
  never a zero variance.
- **A direction needs all three clauses**: `p < α`, the interval on that
  side of zero, and `|effect| ≥ mde / 2`. The sign test pools pairs across
  tasks while the interval is clustered, so they can disagree
  (`significant_sign_test_alone_is_not_a_verdict_test`). Under the
  clustered interval the third clause is implied by the second; it binds
  only under `Bootstrap`.
- **Undecided splits on power.** Neither direction and `mde >
  policy.target_effect` is `Underpowered(mde, needed_tasks)`;
  `Indistinguishable` means the design could have seen the target effect.
- **The futility check only under-claims.** Both bounds take the most
  extreme allocation of the remaining pairs; a gap the remaining pairs can
  close means `p` can reach one, so nothing is decided.
- **The bootstrap keeps the pairing**, and its generator is one stream on
  both targets (`prng_first_outputs_are_fixed_test`).
- `α` is fixed at 0.05 with `z = 1.96`; another level needs the z table
  the cut list excludes. Multiple-comparison correction across more than
  two arms is future work.

## Dependencies

`gleam_stdlib` only; `gleeunit` and `qcheck` for tests. `eval` and
(wave 2C) `client` depend on it; it depends on nothing in Loom.
