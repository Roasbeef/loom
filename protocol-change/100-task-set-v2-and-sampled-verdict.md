# protocol-change/100 — task set v2 and the sampled, paired verdict

**Status**: PROPOSED 2026-10-25, accepted under the owner's delegation of
protocol acceptance (2026-09-05, `docs/execution.md` §7); the review and
disposition section at the end records the primary review and the independent
critique · **Affects**: the `evolution.compare` request admitted at the code-mode
door (068 "Interface impact"), the retained `IndependentRollout` observation,
the meaning of its stored `verdict`, and the `admit_tasks` payload's version
word · **Raised by**: ADR-021 and `docs/design-notes/eval-instrument.md` §2
item 3 and §12 · **Implemented**: the door's `samples` member and the
observation's `sample`, `grade` and `limits.samples` members landed in
`cbacf03a4` (slice 1D) ahead of this proposal, which records them; the
verdict, the raised turn and wall ceilings, the evaluator fingerprint and the
stub's `samples` field land in this change (`client/evolution/rollout`,
`client/evolution/model_door`, `client/evolution/identity`, `cap/evolution`);
task-set v2 admission was reserved here and is decided below (slice 3A; `client/evolution/tasks`, `eval/admit`)

## Problem

Three facts about the governed comparison had drifted apart from what it
claims.

*The verdict was not a comparison.* `rollout.verdict` answered `Failed` when
any candidate-arm trial failed its grade and `Passed` otherwise, and read the
base arm not at all. A base that failed every task and a candidate that failed
one read as `Failed`; a base and candidate that both passed every task read as
`Passed`, which is a selection spent on no demonstrated difference. The word
`passed` in the catalogue therefore meant "the candidate never stumbled", not
"the candidate is better", while the operator's approval rule treats it as the
latter (`client/evolution/store.gleam:1542`, the one place a verdict gates an
approval).

*One trial per task is one coin flip.* The design note's statistics section
settles that the unit of analysis is the task and that several independent
samples of each task per arm are what separate a model's variance from a
task's difficulty. The compare request had no way to ask for them, and the
retained report had no way to say which sample a trial was.

*The task set format is at version one and is about to grow.* The evaluation
instrument's tasks carry a workspace (an inline file map or a Git tree) and a
verifier (exact files or a hidden program run in a fresh jail), as sum types.
`tasks.decode` admits only `version: 1` with a file map and expected files
(`client/evolution/tasks.gleam:138`), and 068 lists `admit_tasks` among the
commands whose payloads are recorded, so admitting the new shape is a protocol
change rather than a decoder edit. This proposal reserves that change's number
and wording and defers its mechanics.

## What was considered

**Keep the asymmetric rule and add samples.** Rejected: with `K` samples the
old rule fails a candidate for one failed sample out of `K`, so raising `K`
could only lower the pass rate of an unchanged prompt. The rule and the
samples cannot coexist.

**A per-trial pass count with a threshold** (`Passed` when the candidate's
pass count exceeds the base's). Rejected: it is a pair-level count with no
power argument, so a one-task difference on twenty trials would read as an
improvement, and the design note already rejects pair-level tests for the
instrument (`one_heavy_task_cannot_flip_the_verdict_test` in `evalstat`).
Two rules for one question is the "separate promotion mechanism" #236's owner
comment forbids.

**Raising the ceilings that bound the money** (`trials`, `dollars`,
`tokens`) so the door could run powered comparisons. Rejected: those are the
operator's spend, and the right fix for an underpowered plan is more tasks,
which the task set controls, not more samples. The design note's cut list
excludes raising them. The `turns` and `wall_ms` ceilings are a different
case, taken up under Decision: they bound time and attempts, not spend, and
as they stood they made `Passed` unreachable.

**Decoding the report back to compute the verdict later.** Rejected: nothing
reads the observation's members today, and keeping the decision typed inside
the fold is what lets the rule see every row without a second parser.

## Decision

### The compare request: `limits.samples`

`evolution.compare`'s `limits` object gains one optional integer member,
`samples`, the number of independent samples of every task to run on each
arm. Absent or `null` is one; the door admits one through three and refuses
anything else with `Bounds: samples must be from one to three`
(`client/evolution/model_door.gleam:262`). The six budget members stay
required, and `samples` is the only member besides them the door admits. The
capability stub `cap/evolution.Limits` gains the field with the same meaning,
`native_limits()` sets it to one, and `compare` always writes it, so a program
that never heard of samples asks for one.

The evaluator's own ceiling on `samples` is five, and `validate` refuses a
request whose trial budget cannot hold `tasks × 2 × samples`
(`client/evolution/rollout.gleam:439`, `validate`), naming the product, before any trial
opens. The door's cap is deliberately below the evaluator's: every sample is a
paid fresh runtime, and a model spending the operator's money gets the smaller
number.

### The retained observation

The `IndependentRollout` observation keeps `version: 1`. Three members are
added and none is removed or re-typed:

- `limits.samples` beside the six budget members, the count the comparison ran
  under;
- in every element of `trials`, `sample` (an integer from one through
  `limits.samples`) and `grade` (an object `{reward, scores, side_info,
  verifier}`, or `null` for a trial the fold stopped before scoring), beside
  the `outcome` word, which stays as the grade's three-word projection so a
  reader of older and newer observations sees the same word in the same place.

`version` stays one because nothing decodes an observation's members back.
`record.Evidence.observation` is a `String`
(`client/evolution/record.gleam:148`); `store.record_evidence` parses it only
as generic JSON to canonicalise and bound it
(`client/evolution/store.gleam:777`); the operator doors and `inspect` return
its exact bytes; the panel's board leaves it out. The additive members change
what a reader can learn and nothing a reader must parse. The first consumer
that decodes `trials` back into rows is the change that bumps the version, and
it will find every report it needs already carrying `sample` and `grade`.

### The verdict

`rollout.verdict` is `evalstat`'s task-level paired decision rule and nothing
else. The fold's own stops still come first and unchanged: an unconfirmed
teardown, a failed open, a budget exhausted mid-comparison, a trial that ran no
tool, a verifier defect, each ends the comparison `Inconclusive` with that
reason before any statistic is consulted, because such a trial says nothing
about its arm and must not be laundered into a row the rule counts or
excludes. Scripted-lifecycle mode stays `Inconclusive` unconditionally; this
change does not touch that ruling.

For a live comparison that ran to its end, every retained report becomes one
`evalstat/trial.Trial` row: the task id, the arm (`base` or `candidate`), the
sample less one as the plan index, and the outcome `Passed` when
`Grade.reward ≥ pass_threshold` (1.0) and `VerifierFailed` otherwise. The fold
has no other outcome to report: a trial that exhausts its budget stops the
whole comparison above, so no `AgentTimeout` or `Infrastructure` row is ever
built from a governed run, and a row the fold never graded is left out and
therefore reported missing. The expected set is the plan the fold was asked to
run, every admitted task times `limits.samples`, built from the request and
never from the rows that exist (`client/evolution/rollout.gleam:1041`,
`decide`). The policy is `evalstat`'s default: a target effect of 0.10 and the
clustered interval. The mapping onto the three stored words is:

| `evalstat` verdict | stored verdict | why |
|---|---|---|
| `Improved` | `Passed` | the one demonstrated improvement a selection may spend |
| `Harmed` | `Failed` | a demonstrated harm |
| `Indistinguishable` | `Failed` | a tie the design could have broken earns no selection |
| `Underpowered(mde, needed_tasks, reason)` | `Inconclusive("underpowered: …")` | the design could not have seen the target; the reason carries the minimum detectable effect and the task count that would have sufficed |
| `Incomplete(reason)` | `Inconclusive("paired task set is incomplete: …")` | a planned row is missing, duplicated or unplanned |

The old rule's two defects close by construction: the base arm is read, and a
single failed candidate trial decides nothing on its own
(`single_candidate_failure_no_longer_decides_test`).

### Read an `Inconclusive` as the rule working

At the door's ceilings almost every honest comparison is `Inconclusive`, and
the arithmetic says why. Twenty trials hold `tasks × 2 × samples`, so a door
comparison has at most ten (task, sample) pairs per arm: `T · K ≤ 10`. With
the binomial plug-in floor that stands in when the arms show no spread
(`evalstat/paired.plugin_variance`, `2 · p̄(1 − p̄) / K` at its largest
`p̄ = ½`), the standard error of the mean task difference is
`√(0.5 / (K · T))` and the minimum detectable effect is `(1.96 + 0.84)` times
that; with observed spread it is never smaller than `2.8 / (K · T)`, the
smallest a single moved sample can make it:

| plan | MDE | tasks needed for a 0.10 target |
|---|---|---|
| one task, any `K` | undefined: fewer than two tasks, always underpowered | — |
| `T · K = 10`, no spread (the door's whole trial budget) | ≈ 0.63 | 392 at `K = 1` |
| `T · K = 10`, one sample moved | 0.28, the door's floor | — |
| `T = 30, K = 3` (the instrument's own scale, not reachable here) | ≈ 0.19 | 131 |

The floor is above the 0.10 target, so through the door `Indistinguishable`
is unreachable: an undecided comparison is always `Underpowered`, and the
`Indistinguishable → Failed` row of the table above is defence in depth for
a caller with a larger budget (`powered_tie_is_failed_test` needs a hundred
tasks to reach it). An A/A comparison at the door, or any comparison that
does not move most of the tasks, is therefore `Inconclusive` naming the MDE
and the task count. That is the statistic refusing to claim what ten pairs
cannot show; it is not a bug in the comparison, the verifier or the door. A
comparison the door *can* decide is one where nearly every task moves the
same way: nine of ten tasks won with one tie is `Passed`
(`baseline_fails_candidate_passes_is_passed_test`), nine lost is `Failed`
(`planted_harm_is_failed_test`), and ten of ten is `Inconclusive` again
because the observed spread is zero and the plug-in floor takes over.

**Independence is assumed, not checked.** Every admitted task is one cluster
of the paired estimators, so the power above is the power of `T` *distinct*
tasks. `tasks.decode` refuses only a repeated task id
(`client/evolution/tasks.gleam:154`); seven tasks with byte-identical fixtures
and expected files are admitted and counted as seven clusters, and would turn
one task's evidence into a `Passed`. Only an operator can admit a task set,
and that operator owns the assumption. Refusing a repeated (fixture, expected)
pair is left to the task-set v2 work below.

### The door's turn and wall ceilings move so that `Passed` is reachable

The smallest plan that reaches `Passed` is seven tasks at one sample, the
base failing six and tying one, the candidate passing all: six tasks in one
direction is the smallest task-level sign test under α (`p = 2/64 ≈ 0.031`),
the tie gives the interval its spread (effect 0.857, lower bound 0.577, MDE
0.40), and `prompt_acceptance_plan_of_seven_tasks_is_a_demonstrated_improvement_test`
feeds `decide` exactly the reports such a run retains.

That plan could not run through the door as its ceilings stood. The door
admitted at most twenty aggregate turns, and a trial is at least two provider
turns (a tool call, which scoring requires, and the closing answer), so the
door admitted at most ten trials, five tasks at one sample. Five wins have no
spread and four wins with a tie reach only `p = 0.125`
(`five_tasks_cannot_be_a_demonstrated_improvement_test`), so **without this
change no comparison the door could request would ever have ended
`Passed`**; the `samples` ceiling does not help, since every sample spends
turns.

**Decision.** The door's `turns` ceiling rises from 20 to 100, the
evaluator's own bound (`rollout.validate`), and its `wall_ms` ceiling from
120,000 to 480,000; both become the defaults a request without `limits` runs
under, and `cap/evolution.native_limits()` names the same numbers
(`model_door.turns_ceiling`, `model_door.wall_ceiling_ms`;
`the_stubs_native_limits_are_admitted_by_the_door_test`). `trials` stays at
most 20, `samples` at most 3, and the `dollars` (2.0) and `tokens`
(1,000,000) ceilings are **unchanged**. Those two, not turns, bound the
operator's money: every provider attempt is debited against them before it
is dispatched, and an attempt with no usage report is debited at its worst
case, so the raised ceilings cannot raise the worst-case spend of one
comparison. **Cost.** A compare may now hold its budget for up to eight
minutes instead of two, and may make up to a hundred provider attempts
within the same dollar and token caps where it made twenty; an operator
reading the evidence sees more trials per comparison and a longer worst-case
wait, nothing dearer. The prompt acceptance fixture now runs the seven-task
plan above through the door (fourteen three-turn trials, 42 turns, seven
distinct expected files) and keeps its `Passed`, approve and select stages.

**Why 480,000 and not the evaluator's 900,000.** The compare runs
synchronously inside the one code-mode capability call that asked for it
(`codemode/evolution` answers `ServedHere`; the satellite runs it on a
worker under `weft.deadline(call_timeout_ms)`), and
`client/codemode.default_call_timeout_ms` is 600,000. A worker killed at
that deadline leaves the fold half-done: the provider spend is gone,
`store.record_evidence` never runs, and the open trial's retirement and
cleanup never run, which is the custody the fold exists to keep. The wall
therefore sits `model_door.wall_margin_ms` (120,000) below that timeout, so
the fold's own wall fires first and close, score, cleanup and the evidence
write still land inside the call;
`the_wall_ceiling_and_its_margin_fit_inside_the_code_mode_call_timeout_test`
reads both constants, so moving either without the other fails the build.
The program's own wall binds too: a `code_mode` call runs `within_ms`
(`client/codemode.default_within_ms`, 300,000, clamped to `max_within_ms`,
900,000), and the compare's answer reaches the program only if that wall
outlasts the compare. A program asking for a wall above 300 seconds **must**
raise the call's `within_ms` argument to cover `wall_ms` plus the build;
`cap/evolution`'s module doc says so. The previous ceiling of 120,000 sat
under all three bounds by accident of being small.

**When `Passed` is reachable at all.** The turn ceiling was the binding one
for the fixture's target, not for every target. The per-attempt guard
(`rollout_host.reserve`) reserves `3 · context + output` tokens, their
worst-case price and `4 · output` retained bytes before every attempt, and
nothing is credited back within a trial. A trial needs at least two attempts
(a tool call and the closing answer), so a target whose context window is
about 164k tokens or more cannot fit two reservations in the 1,000,000-token
cap, and one whose `max_output_tokens` is 16,384 or more spends the whole
65,536-byte output cap on its first attempt and is refused a second. Against
such a target every door comparison ends `Inconclusive` ("aggregate
reservation budget refused request") whatever the turn ceiling; the fixture's
target is 65,536 context and 1,024 output. This is safe and it is a
limitation: refunding the unused part of a reservation after each attempt
reports its usage is the follow-up, not done here, and the money ceilings are
not raised for it.

### Task set v2: inline workspaces and exact files, admitted

`tasks.decode` accepts two payload versions. **Version one** is unchanged
byte for byte: an array of tasks each with an id, a prompt, an initial file map
and an exact expected-file map, and its identity is the digest of the same
canonical bytes as before (`v1_task_sets_still_decode_test` pins one digest
computed outside the code). **Version two** carries, per task, exactly
`{id, prompt, workspace, verifier}` with the evaluation instrument's two tagged
sums:

- `workspace` is `{"kind":"inline","files":{path: text}}` or
  `{"kind":"git_tree",…}`;
- `verifier` is `{"kind":"expected_files","expected":{path: text}}` or
  `{"kind":"program",…}`.

Only `inline` and `expected_files` are admitted. A v2 task of those kinds
scores through the same `fixture.score` as a v1 task, the same bounds apply (ten
tasks, 256 KiB, 64 paths a map, 512-byte prompts, safe relative paths), and its
`rollout.Task` carries the same `fixture` and `criteria` digests as the v1 task
of the same bytes. A `git_tree` workspace is refused with `Bounds: git-tree
workspaces are not admitted to governed comparisons yet` and a `program`
verifier with `Bounds: program verifiers are not admitted to governed
comparisons yet`; an unknown kind or a member the kind does not define is
refused as malformed. The refusal is at **admission**, not at the scorer, so a
task set nobody can run never reaches the catalogue.

*Why.* The jailed program verifier lives in `packages/eval`, which `client`
cannot depend on (`eval` depends on `client`), and moving it would put a
sandbox runner in the governed plane's package. The governed plane has no
checkout to materialise a tree from either. Refusing early is the conservative
reading of "a task set the governed plane cannot score must not be admitted".

*Identity.* A set's id is the digest of its canonical bytes, and those bytes
carry the version word and, for v2, the tagged `workspace` and `verifier`
objects. A v2 set therefore never shares an id with the v1 set of the same
fixtures, and a change to any workspace file or expected file moves it
(`v2_identity_covers_workspace_and_verifier_test`). `TaskSet` gains a `version`
field, restored from the stored payload by `load`.

*Independence.* A v2 set refuses two tasks whose fixture and expected bytes
are both identical (`Bounds: tasks must be independent; a fixture and expected
pair repeats`), closing the assumption recorded above for new admissions. v1
keeps admitting them, because "v1 stays valid and means what it meant" outranks
the tidier rule; an operator who wants the check re-admits under v2.

*Who produces v2.* `eval admit --split tune|validate` converts the
instrument's tasks of that split to a v2 payload and submits it through the
existing operator door (`loomd evolution admit_tasks`), so authority stays in
the daemon. The holdout split is refused by name before any task is read; no
holdout id is ever put in a payload, which a test over a fixture state
directory pins (`holdout_ids_never_reach_a_taskset_fact_test`). Instrument
tasks without a governed form (a repository tree, a program) are reported as
skipped with the governed decoder's own reason.

*Follow-ups, not done here.* (a) Admitting `program` verifiers needs the jailed
verifier reachable from the governed plane, either by a seam in `client` that
`eval` fills or by moving the runner down. (b) The report envelope an
instrument run writes would be citable beside a candidate as an
`InstrumentReport` evidence purpose, never `IndependentRollout`
(`docs/design-notes/eval-instrument.md` section 2); no such purpose exists yet
and `select` still requires governed evidence. (c) The door's argument file is
read at most 48 KiB, so a v2 set near the 256 KiB admission bound cannot be
submitted by `eval admit`, which refuses it with its size.

### protocol-change/101 is reserved

Number 101 is reserved for the per-role profile key (a prompt profile keyed by
a role rather than by one exact model), named in the design note's cut list
and not designed here.

## What it costs

A compare request at the door's ceilings that used to answer `Passed` for an
unchanged prompt now answers `Inconclusive`, and an operator who approved on
that word can no longer. That is the point, and it is the whole cost to the
operator surface. The catalogue's three words are unchanged, so no reader of
evidence moves.

The evaluator fingerprint moves from `author-tests-and-live-rollout-1` to
`-rollout-2` (`client/evolution/identity.gleam`), because the meaning of a
stored `Passed` changed. The catalogue compares its own identity with a
candidate's or an evidence row's on every admission (`store.current`), so
evidence graded under the old rule, and the candidates it belongs to, answer
`Changed` ("candidate or evaluator identity changed") to `approve`,
`select` and a fresh `propose` of the same bytes; an operator re-proposes and
re-compares under the new rule. Nothing already selected is unselected.

`client` gains a dependency on `evalstat` (pure, stdlib-only, held to the
portable subset by lint R6) and a test-only dependency on `cap`, so the
door's tests can read the stub's `native_limits()`. The verdict's numbers travel in the
`Inconclusive` reason only; a later change that wants them beside a `Passed`
or `Failed` adds them to the observation and bumps its version.

`cap/evolution.Limits` grows a field, so a program that constructs it
positionally or by every label must name `samples`; the capability prelude and
the code-mode seed are regenerated and gated by `make prelude-check`.

## Verification

In `client/evolution/models_test`: `aa_comparison_is_inconclusive_test`,
`planted_harm_is_failed_test`, `baseline_fails_candidate_passes_is_passed_test`,
`single_candidate_failure_no_longer_decides_test`,
`expected_rows_come_from_the_plan_test`,
`live_samples_pair_per_sample_and_one_task_never_decides_test`, and
`powered_tie_is_failed_test`, which builds a hundred-task plan directly for
`rollout.decide` because the door's ten-task cap cannot reach a powered tie.
In `client/evolution/model_door_test` and `cap/evolution_test`:
`cap_limits_carry_samples_test`; in `model_door_test` also
`turn_and_wall_ceilings_match_the_evaluator_and_dollars_do_not_move_test`,
`the_wall_ceiling_and_its_margin_fit_inside_the_code_mode_call_timeout_test`
and `the_stubs_native_limits_are_admitted_by_the_door_test`. Mutations run against them: mapping
`Indistinguishable` to `Passed` fails the powered tie; `Harmed` to `Passed`
fails the planted harm; `Improved` to `Failed` fails the improvement; building
the expected set from the rows fails the plan test alone; dropping `samples`
from the door's decoder or the stub's wire fails the carry tests.

## Review and disposition

Protocol acceptance is delegated (owner, 2026-09-05). The primary review is
the orchestrator's read of this proposal against the design note's §2 item 3
and §5 and the slice's named tests; the independent adversarial critique the
orchestrator runs on the finished slice is recorded here when it lands, with
each finding's verification against the code and the correction it produced.
Disposition. The primary review accepted the `K = 3` question as moot (see
below) and the absence of an `AgentTimeout` source in the governed fold as
recorded, ruled the fixture's `Passed` unacceptable to leave failing, and
ruled the turn and wall ceilings raised with the dollar and token ceilings
unchanged. The independent adversarial critique then found, and the code
confirmed: (B1) a 900,000 wall outlived the 600,000 code-mode call that hosts
the compare, killing the fold with its custody unreturned, corrected to the
480,000 ceiling and its pinned margin above; (S1) the per-attempt reservation
makes `Passed` unreachable for large-window or large-output targets, recorded
above with its follow-up; (S2) `T · K ≤ 10` at the caps, so the earlier
"one reachable edge" at `K = 3` and its proposed variance floor were false
premises, removed, and `Indistinguishable` is recorded as unreachable through
the door; (S3) the independence assumption, recorded, and the fixture's seven
tasks given distinct expected bytes; the nits (the samples citation, the
`cbacf03a4` provenance, the `rollout-2` fingerprint, the native-limits
admission test) applied. Accepted with those corrections.

Slice 3A (task-set v2) disposition. The reserved wording became the decision
above. Rulings taken in review: the Program and git-tree refusals sit in the
decoder rather than the scorer, so no unrunnable set is stored; v1 keeps
admitting repeated fixture and expected pairs while v2 refuses them; the
payload's `name`, `tags` and `provenance` are not carried (only what the
governed plane acts on is hashed). Verified by mutation: accepting a v2
`program` verifier fails `v2_program_task_is_refused_for_governed_runs_test`
alone; opening the seal fails `holdout_admit_is_refused_by_name_test`; dropping
the split filter fails the payload and seal tests.
