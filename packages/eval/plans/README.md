# Operator plans

Four frozen plans over the committed task set `tasks/loom-history-v1/` (21
regression tasks mined from Loom's own fix commits). Arms live beside them in
`plans/arms/`, one file per arm id. Every plan passes `eval validate` and
`plan.check`, and `committed_plans_validate_test` keeps it that way.

| Plan | Lane | Profile | Arms | K | Cells | What it answers |
| --- | --- | --- | --- | --- | --- | --- |
| `plans/smoke-record-live.json` | live | quick | baseline | 1 | 3 | Records tapes and measures a trial's dollars. |
| `plans/smoke-replay.json` | replay | quick | baseline | 1 | 3 | Does the harness still make the same requests? |
| `plans/aa-live.json` | live | full | `control-a`, `control-b` | 3 | 126 | Does the instrument stay quiet when nothing differs? |
| `plans/degrade-live.json` | live | full | `baseline`, `no-tests` | 3 | 126 | Does it notice a planted degradation? |

The smoke pair is one plan in two lanes: the replay plan is the record plan
with the lane changed, so the tapes the first run writes are the ones the
second reads (`<tapes>/<task id>/<index>.jsonl`).

## What you need

- A clone holding the commits the tasks name. Run from this checkout and the
  logical repository `loom` resolves to it; otherwise add `--repo
  loom=/path/to/clone`. A clone that lacks a task's commit, or whose tree
  differs, is refused rather than measured.
- A `loom.toml` whose `main` role routes the model under test, and the
  environment variable it names for the key. The two live plans spend real
  money; the smoke replay needs no key.
- The jail helper (`make sandbox` builds `packages/sandbox/loom-exec`, the
  `--helper` default) and the offline code-mode cache (`make codemode-seed`).

Every command below runs from the repository root. `make eval-run` changes into
`packages/eval`, so the paths in `ARGS` are relative to it. A run directory is
`$HOME/.loom/eval/runs/<plan id>/` unless `--out` says otherwise; add `--out`
to repeat a plan, because the same plan under the same `--out` resumes instead
of starting again.

## Commands

Smoke: record three trials, then replay them. Read the dollars off the first.

```
make eval-run ARGS="run plans/smoke-record-live.json --tasks tasks/loom-history-v1 --arms plans/arms --config $HOME/.loom/loom.toml --record $HOME/.loom/eval/tapes"
make eval-run ARGS="run plans/smoke-replay.json --tasks tasks/loom-history-v1 --arms plans/arms --config $HOME/.loom/loom.toml --tapes $HOME/.loom/eval/tapes"
```

The A/A plan, then the degradation plan:

```
make eval-run ARGS="run plans/aa-live.json --tasks tasks/loom-history-v1 --arms plans/arms --config $HOME/.loom/loom.toml"
make eval-run ARGS="run plans/degrade-live.json --tasks tasks/loom-history-v1 --arms plans/arms --config $HOME/.loom/loom.toml"
```

Repeat the A/A two more times under other output directories (`--out
$HOME/.loom/eval/aa-2`); the plan id is the same and each run is a fresh draw
from the model.

Rebuild a report from a finished or interrupted run directory, without
running anything:

```
make eval-run ARGS="report $HOME/.loom/eval/runs/<plan id>"
```

An interrupted run resumes by repeating the `run` command: finished cells are
skipped and a `Running` row with no successor is closed as an infrastructure
fault.

## What the numbers can see

The 21 tasks fall 13 / 5 / 3 into tune / validate / holdout under the salt
`loom-history-v1`, so the holdout panel is three tasks and says
`Underpowered`; only the whole-plan comparison is a result, and the
validate-minus-holdout gap needs at least two tasks in each split to form at
all.

The minimum detectable effect is the first line of every report. At T = 21 and
K = 3 it is about 0.25 when the arms pass about half the time on every task
(the worst case: the design's standard error is largest there), and shrinks
toward 0.2 as tasks become all-pass or all-fail. The default target effect is
0.10, so a comparison the data cannot decide reads `Underpowered`, not
`Indistinguishable`: this design cannot show that two arms differ by less than
a quarter. That is the intent, and it is why a four-point difference is never a
finding here.

## Expected verdicts

**`aa-live`: neither `Improved` nor `Harmed`.** The two arms are the same
configuration. Their ids must differ for the plan to pair them, so each
withholds one tool name that does not exist (`inert-marker-a`,
`inert-marker-b`); nothing a session sees changes. Expect `Underpowered`, with
an effect near zero. An `Improved` or `Harmed` here is a false alarm, and
three of three clean runs is the acceptance bar, since the decision rule's
false-alarm rate is bounded at 0.06 on synthetic data
(`verdict_never_improves_under_aa_test` in `evalstat`) and a live run is how
that bound meets a real model's noise.

**`degrade-live`: `Harmed`, if the drop is large enough to power.** The
`no-tests` arm prefixes every task with "Do not run any tests; answer from
reading the code alone." For `Harmed` the effect must be below zero by at
least half the MDE, the interval wholly below zero, more tasks worse than
better, and the task-level sign test under 0.05. Because the minimum detectable
effect is about 0.25, a drop of 0.3 or more should read `Harmed`; a drop of
0.1 is real and will read `Underpowered`. Neither is a bug: the report's first
line is what says which one you were able to see. If the model's pass rate does
not move when it stops running tests, that is a finding about the model on
these tasks and is not evidence against the instrument.

**`smoke-replay`: the same pass rate as the recording, no divergence.** A
divergence is a `VerifierFailed` row whose side info names the request that
differed. A single arm has no comparison, so the report prints the arm table
and no verdicts.

Beyond the verdicts, the report now carries, under each comparison, the
bootstrap interval (2000 resamples, seeded by the plan id, so re-rendering a
ledger gives the same interval); the validate-minus-holdout gap, flagged
"memorised" when it is positive beyond its own interval; pass@k and pass^k for
k = 1..K per arm; and a dominance ruling per candidate (the outcome verdict
first, then cost, turns and tool errors as higher-is-better scores). When the
sign test can no longer reach its level, the runner stops admitting cells and
the header says "stopped for futility after N pairs"; the missing cells make
the verdicts `Incomplete`, which is the honest account of a run that chose to
spend less. Each scored trial also keeps an ATIF trajectory at
`<run>/<task>/<arm>/<index>/attempt-<n>/trajectory.json`.

## Cost

A plan's `max_dollars` is a ceiling, not an estimate. The runner admits a trial
only while the cap, less measured spend, less the worst case of trials in
flight, covers one more worst case. A trial's worst case is
`max_requests_per_trial * price(3 * context_window + max_output_tokens)` at the
main model's pricing card (`budget.worst_case_dollars`); a cap below one worst
case admits nothing and the report says "budget exhausted after 0 trials".

To estimate a plan:

1. Run `smoke-record-live` and read `mean $` for `baseline` in the report's
   Arms section.
2. Multiply by the plan's cell count (21 tasks x 2 arms x K = 126 for each live
   plan). Add a margin for tasks harder than the three smoke tasks; compare the
   result with the worst-case figure the cap implies, since a trial that runs
   to its 40-request ceiling costs several times a typical one.
3. Set `budgets.max_dollars` to that, and re-stamp the plan (below).

The committed cap of 150 dollars for 126 trials is a placeholder of about 1.19
dollars a trial. It is a bound on a mistake, not a prediction.

## Editing a plan

Plan and arm ids are digests of their content, so an edited file is refused
until its id says what the file now holds. The refusal names the right
digest:

```
cd packages/eval && gleam run -m eval -- validate plans/aa-live.json
```

prints `plan content changed: id <old> but content digests to <new>`. Put
`<new>` in the file's `"id"`. Do the same for an arm file, and also rename it
to `<new>.json`; then put the new arm id in the plans that name it.

Two edits are expected before a real run:

- **The commit.** `harness.git_commit` is the harness the plan claims, stamped
  when the plan was written. A `full` plan refuses a dirty tree. Set it to
  `git rev-parse HEAD` of the tree you run from, after committing. The runner
  checks this before any trial: a `full` plan is refused unless `HEAD` equals
  the stamped commit and, for `"posture": "clean"`, `git status --porcelain`
  is empty (a `quick` plan prints the mismatch on standard error and runs).
  So re-minting means commit, stamp that commit in a copy of the plan kept
  outside the checkout (committing the stamp would move `HEAD` past it), and
  run from that tree.
- **The target of `no-tests`.** Its `TaskPrefix` is aimed at the catalogue
  entry `main` with `model_id` `main-model` on `anthropic-messages`. A profile
  matches only an exact model, so change `provider` to your entry's `name`,
  `model_id` to its `model_id` and `api` to its wire API, or the run is refused
  before any trial starts with "the catalogue holds no model ...". The
  baseline and the two controls name no model and need no edit.
