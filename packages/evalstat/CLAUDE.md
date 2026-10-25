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
  `PairingError` (`MissingRow`, `DuplicateRow`, `UnplannedRow`, `SameArm`)
  that the decision rule turns into `Incomplete`. A pair with an excluded
  side is dropped whole and counted. `compare_task_ids` is the package's
  one task order: by code point, identical on both targets.
- `evalstat/binomial` — `log_choose`, `half_cdf`: exact log-binomial
  arithmetic for `n ≤ 1000`.
- `evalstat/mcnemar` — the task-level sign test that decides
  (`task_signs(differences) -> Signs(positive, negative)`, `sign_p_value`)
  and the pair-level McNemar count that is reported
  (`discordant -> Discordant(b, c)`, `p_value`).
- `evalstat/paired` — `differences`, `mean`, `clustered_se`, `interval`,
  `mde`, `needed_tasks`, `needed_tasks_for_variance`, `plugin_variance`
  (the binomial floor), `decompose -> Decomposition(between, within,
  lever)`, `arm_rates`. `z_alpha = 1.96`, `z_power = 0.84`.
- `evalstat/bootstrap` — `interval(paired, resamples, seed)`: the cluster
  bootstrap, tasks drawn with replacement and each contributing its
  observed `d_t` (not the nested form: redrawing trials inside a drawn
  task counts within-task variance twice). Percentile ranks symmetric
  about the ends. `default_resamples = 2000`.
- `evalstat/prng` — xorshift128 on 32-bit words (not xorshift64*: see the
  module doc for the JavaScript exactness argument), seeded from a string
  by salted FNV-1a. `from_string`, `next`, `below`, `unit`, `fnv1a`.
- `evalstat/passk` — unbiased `pass_at_k`, `pass_pow_k`, and the per-task-
  then-averaged `arm_pass_at_k` / `arm_pass_pow_k`; `k > n` is an `Error`,
  never zero.
- `evalstat/verdict` — `Verdict` (`Underpowered` carries a `reason`),
  `Policy(target_effect, interval)`, `Interval { Clustered |
  Bootstrap(resamples, seed) }`, `Stop { Continue | StopUndecided }`,
  `default_policy()` (target 0.10, clustered).
- `evalstat/dominance` — `compare(verdict, candidate_scores,
  baseline_scores) -> Dominance`: outcome first and lexical, then Pareto on
  shared score names for any arm not shown harmful (`Indistinguishable` and
  `Underpowered` alike); `Tradeoff` is reported, never resolved; no shared
  name or an `Incomplete` outcome is `Undecided`; a NaN score ranks below
  every number.
- `evalstat` — `paired_verdict(rows, baseline, candidate, expected,
  policy)`, `decide(paired, policy)`, `futility(rows_so_far, baseline,
  candidate, remaining_pairs)`, `futility_from_signs`. `alpha = 0.05`.

## Invariants that break things when violated

- **The plan is the denominator.** `expected` comes from the plan, never
  from the rows; a missing row is `Incomplete`, not a smaller `n`. A plan
  with no counted pair at all is `Incomplete("no counted trials")`.
- **Timeouts and refusals are failures.** Changing `trial.standing` is
  changing the instrument's claim; `timeouts_are_failures_not_excluded_test`
  guards it.
- **Every deciding clause weights tasks equally.** The effect, the
  clustered interval and the sign test are all over per-task differences
  `d_t`; a pair-level test can point the other way when pair counts differ
  across tasks (`one_heavy_task_cannot_flip_the_verdict_test`), so it is
  reported and does not decide.
- **A direction needs all five clauses**: effect on that side of zero,
  interval wholly on that side, more tasks on that side than the other,
  task-level `p < α`, and `|effect| ≥ mde / 2`. Under the clustered
  interval the last is implied by the second; it binds under `Bootstrap`.
- **Zero spread is never power.** `T < 2` or `SE = 0` is `Underpowered`
  with the binomial plug-in floor (`paired.plugin_variance`) behind `mde`
  and `needed_tasks` and a `reason` naming the case
  (`zero_variance_is_underpowered_test`). An `mde` of zero never reaches the
  power comparison.
- **Undecided splits on power.** Neither direction and `mde >
  policy.target_effect` is `Underpowered`; `Indistinguishable` means the
  design could have seen the target effect. At T = 30, K = 3 the MDE is
  about 0.19, so with the default target every undecided plan there is
  `Underpowered`, which is the intent.
- **The futility check only under-claims, and never decides.** The only
  stop is `StopUndecided`, taken when no allocation of the remaining pairs
  (each adding a task to one side or neutralising one on the other) could
  bring the task-level sign test below `α` in either direction. An early
  *decision* would need the interval too, which the remaining pairs can
  still move.
- **The bootstrap keeps the pairing** because `d_t` is paired, and its
  generator and task order are one stream on both targets
  (`prng_first_outputs_are_fixed_test`,
  `task_order_is_by_code_point_on_both_targets_test`).
- `α` is fixed at 0.05 with `z = 1.96`; another level needs the z table
  the cut list excludes. Multiple-comparison correction across more than
  two arms is future work.

## Dependencies

`gleam_stdlib` only; `gleeunit` and `qcheck` for tests. `eval` and
(wave 2C) `client` depend on it; it depends on nothing in Loom.
