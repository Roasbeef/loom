# The evaluation instrument

Loom has a developer tool that measures whether a change to the agent makes it
better: a prompt suffix, a tool description, a model assignment. It runs the
agent on versioned tasks under two or more configurations (arms), grades every
trial with a hidden verifier in a fresh jail after the agent is gone, and
reports a paired verdict that says "improved", "harmed", "indistinguishable" or
"underpowered". This page is for an engineer who is changing that tool or
running it. It says what each module owns, how one run moves through them, what
the verdict can and cannot claim, and which parts are not built.

The decisions are recorded elsewhere and this page does not repeat their
arguments. [ADR-021](../adr/021-evaluation-instrument-beside-governed-evolution.md)
holds the rulings that outlive one change.
[protocol-change/100](../../protocol-change/100-task-set-v2-and-sampled-verdict.md)
records the governed-side changes (the `samples` member, the shared verdict, the
raised turn and wall ceilings). The
[design note](../design-notes/eval-instrument.md) carries the argument and the
wave plan; its section 15 lists where review changed it, and this page lists a
few more places where the code now differs
([Where the code differs from the design note](#where-the-code-differs-from-the-design-note)).
Where the note and the code disagree, the code wins. The per-package guides in
[`packages/eval/CLAUDE.md`](../../packages/eval/CLAUDE.md) and
[`packages/evalstat/CLAUDE.md`](../../packages/evalstat/CLAUDE.md) are denser on
invariants; read the one for the package you are about to change.

## What the instrument is for, and what it is not

The instrument answers one question about a change: on this set of tasks, does
arm B pass more often than arm A, by more than noise and by more than the
design could have missed? It is a developer tool. It never ships in a release,
no other package depends on `eval`, and it has no command in `loom` or `loomd`.

It never promotes anything. The governed plane in
[`client/evolution`](evolution.md) is the only route from a candidate to a
selection, and it stays that way: an operator approves exact identities, and
`select` needs `IndependentRollout` evidence from the governed comparison on an
admitted task set. An instrument report is not that evidence. A candidate the
instrument favours is run again through `evolution.compare`. The cost is that
every promotion is run twice, once to search and size, once for the record.
That cost is the design; a second promotion mechanism is what issue #236's owner
comment forbids.

The two planes share three things and nothing else:

| Shared | Where it lives | Why shared |
| --- | --- | --- |
| One trial recipe | `trial_settings` at `client/serve.gleam:8140` | A trial is the same fresh jailed session on both paths. |
| One grade type | `rollout.Grade` (reward, named scores, bounded side information, the verifier run) | The exact-file scorer and the jailed program verifier both return it. |
| One decision rule | `evalstat` (`paired_verdict`, `decide`) | `evolution/rollout.gleam:1166` (`decide`) maps its verdict to the three stored words. |

### Two lanes, two claims

Every plan names a lane. The lane decides what a result may be used to claim.

| Lane | Model traffic | Costs | May claim | May not claim |
| --- | --- | --- | --- | --- |
| Replay (`plan.Replay`) | Recorded responses served from a tape | Nothing; needs no key | Given the same model outputs, the harness sent the same requests and the verifier gave the same reward | Anything about model quality |
| Live (`plan.Live`) | A real provider | Real spend, capped per run | A claim about this model on these tasks, at the size the verdict's minimum detectable effect allows | Anything beyond those tasks and models |

The report's header states the lane's claim, and `report.lane_statement` is the
one place that wording lives. A `--record DIR` on a live plan taps the wire and
writes the tapes a later replay plan uses; that lane is metered like `Live`
because the spend is real.

## The flow of one run

A run starts from a frozen plan and ends at a report. Each step has one owning
module, so a change to a step has one place to land.

| Step | What happens | Owner |
| --- | --- | --- |
| Plan | Every task, arm and trial index the run owes is written down before anything starts. A full plan on a dirty tree is refused. | `eval/plan` |
| Materialise | The starting tree is built with `git archive` (no `.git`, no object store). The commit's tree id is read back and compared with the task's. The task's `prepare` argvs run on the host, then a warm `gleam build`. A copy of every `build/` is kept as the pristine build. | `eval/materialise` |
| Trial | An arm becomes session settings. A session opens through `serve.trial_settings` and the agent runs under a request ceiling and the plan's wall. | `eval/trial`, `eval/arm_settings` |
| Retire | The session is closed and the retirement is confirmed. Nothing touches the workspace before this returns. | `eval/trial`, `serve.retire_instance` |
| Verify copy | The workspace is copied to `frozen/`. The grader then builds its own copy from that, keeping only regular files and directories, and lays hidden files and the pristine build in. | `eval/trial`, `eval/verify` |
| Jailed grade | The task's program runs in a fresh jail on the copy: network off, the copy as the only readable and writable root. | `eval/verify` |
| Ledger row | One line is appended per attempt, by a single writer. | `eval/run`, `eval/ledger` |
| Reconcile | The plan is the denominator. The ledger is held to it. | `eval/ledger`, `eval/report` |
| Verdict | Each non-baseline arm is compared with the first arm over paired rows. | `evalstat` |
| Report | `report.md` and `report.json`. The first line is the minimum detectable effect. | `eval/report` |

The order inside a trial is the guarantee, and each step exists because
skipping it has a failure it prevents. `trial.run_one` (`eval/trial.gleam:307`)
is the single entry. It never raises: a fault in the instrument rather than the
arm becomes an `Infra` row.

1. **Materialise** (`materialise.run`, `eval/materialise.gleam:73`). The cold
   start is timed on its own, as `timing.prepare`, apart from agent time.
2. **Apply the arm and start the request guard.** An arm that cannot be applied
   is refused here by name. A guard actor on the gateway counts requests against
   `max_requests_per_trial`; the dollar bound is the run's, not the guard's.
3. **Open and drive the session.** The agent is prompted and awaited under
   `wall_ms_per_trial`.
4. **Read everything the ledger needs before closing.** The store goes with the
   session, so usage and counts are read first.
5. **Retire and confirm.** A grader that ran while the agent could still write
   would be grading a moving target. Retirement is attempted even if observation
   failed; an unconfirmed retirement is an `Infra` row.
6. **Freeze and grade.** The workspace is copied to `frozen/`; the grader sees
   only the copy.

How the trial ends picks the outcome, in this precedence: a replay divergence
(a failure of the lane, recorded as `VerifierFailed` with the finding in
`side_info`), then a wall timeout (`AgentTimeout`, never graded, never
retried), then a provider fault (`Infra`), then the grade. Each earlier case
makes the later ones meaningless.

A run directory is `<out>/<plan id>/`, with `<out>` defaulting to
`$HOME/.loom/eval/runs`. It holds `plan.json`, copies of `tasks/` and `arms/`,
the append-only `trials.jsonl`, `notes.txt` (the budget stop, when there was
one), and the report. Each attempt works in
`<task>/<arm>/<index>/attempt-<n>/`, holding `work/` (the live tree),
`state/session.db`, `frozen/` and `verifier/`. Never place any of it under
`/tmp`: the jail replaces `/tmp` with a scratch tmpfs.

The runner works in rounds, one per attempt number, with cells as weft tasks
`budgets.concurrency` at a time (`run.execute`, `eval/run.gleam:146`). Because
a round's cells are independent, a retry can be a round, and the ledger's
sequencing rule is then true of the file by construction.

## Tasks and their identity

A task is one prompt, one starting workspace and one hidden verifier, addressed
by the SHA-256 of its canonical encoding with the `id` field blank
(`task.mint`, `eval/task.gleam:186`). Any edit to the prompt, workspace or
verifier is a different task. "Fixing" a task to make an agent pass is
therefore minting a new one; the old one stays in every ledger that measured
it.

The never-edit rule is enforced in two places. `verify_id` (`eval/task.gleam:200`)
refuses a task whose id is not the digest of its content, and names both digests
because the usual cause is a hand edit that forgot to re-mint. `load`
(`eval/task.gleam:228`) additionally refuses a file not named `<id>.json`, so a
copied or renamed file cannot pass as a catalogued task. Plans and arms follow
the same rule: a plan is addressed by its own digest, and `plan.load` refuses a
file whose content no longer matches its id.

The workspace and the verifier are sum types, so the runner never branches on
who produced a task. Hand-written fixtures, mined commits and Harbor imports
are three producers of one type; provenance is hashed and never trusted.

| Choice | Variants | Meaning |
| --- | --- | --- |
| `Workspace` | `Inline(files)` | A small fixture carried in the task. |
| | `GitTree(repository, commit, tree, prepare)` | A tree from a repository named by a logical `repository` name (`loom`), never a path. `tree` is `git rev-parse <commit>^{tree}`, already a digest of the whole tree. |
| `Verifier` | `ExpectedFiles(expected)` | Exact bytes, graded in process by `trial.grade_expected`. Reward is 1 or 0. |
| | `Program(files, argv, fail_to_pass, pass_to_pass, timeout_ms, scoring)` | Hidden files staged into a copy after the agent is gone, then one argv run in a fresh jail. |

A task file is untrusted input, because a Harbor import is someone else's file.
The decoder is total and rejects unknown keys. For a `GitTree`, the repository
must be a logical name matching `[a-z0-9][a-z0-9-]{0,63}` (so it can never read
as a git option or remote helper, and identity never depends on where a clone
lives; `eval/repos` maps the name to the operator's clone at run time, and
refuses a clone whose `<commit>^{tree}` differs from the task's `tree`), the
commit and tree must be 40-digit lowercase hex, and every `prepare` argv must be
one of three allowlisted commands (`prepare_allowlist`, `eval/task.gleam:477`):
`gleam deps download`, `gleam build`, `gleam build --warnings-as-errors`. A task
file therefore chooses among known builds of the repository's own tree and never
supplies a program to run on the host.

`ExpectedFiles` and `Program` look alike in a plan and are very different in
cost. An expected-files plan never opens a jail. A plan with any `Program` task
opens one jail for the whole run, and refuses to start if the host cannot supply
it (see [The verifier](#the-verifier-threat-model-and-defences)).

## The miner and the prover

The raw material is Loom's own history. A fix commit that adds its regression
test is a free experiment: the parent has a bug, the commit's test changes are a
hidden verifier that fails on it, and its source changes are the answer key.

### Mining

`gleam run -m eval/mine_cli` is host-side and trusted, like CI. It runs through
`secrets.host_runner()` with no jail, one candidate at a time, because
concurrent worktrees share ports and scratch directories and would turn a flaky
collision into a false cull. A candidate (`git.parse_candidates`) touches one
package, one or two `src/*.gleam`, and one or two `*_test.gleam`, with no
deletions; other files under that package's `src/` and `test/`, and its
`CLAUDE.md` and `AGENTS.md`, ride along. Anything else is a feature or a
refactor and is not a candidate.

For each candidate the miner makes a worktree at the parent under
`$HOME/evalwt/`, applies only the test patch, and runs the touched test modules.
It then applies the fix and runs them again (`mine.judge`, `eval/mine.gleam:137`):

- **Fail-to-pass (F2P)** is failed-then-passed. **Pass-to-pass (P2P)** is
  passed-both-times. Both are scoped to the touched modules, not the package,
  and the module match ends in a colon so `lint_test` never selects
  `other_lint_test`.
- A run is culled, with a reason in `census.jsonl`, when the before run did not
  compile or ran no tests (a feature commit whose test calls the new API), when
  any test fails after the fix, or when no test flipped from failing to passing.
- **Network-only tests are culled.** The after-fix run is made in an empty
  network namespace (`mine.offline`, `unshare -rn`) when the host allows it. A
  fix whose tests pass with the network and fail without it is culled as
  "tests need the network, which the verifier jail has off"
  (`mine.network_only_failures`, `eval/mine.gleam:593`). Two older
  `provider/http_test` commits predate this rule and are refused at proof time.
- The verifier files are the post-images of every file the test patch touches,
  fixtures and support modules included. The **runner is vendored**: the task
  always carries `scripts/test.sh`, `scripts/with_timeout.py` and
  `scripts/serial-tests` from the miner's checkout (`runner_paths`,
  `eval/mine.gleam:397`), tagged `runner:vendored`. The verifier refuses to run
  a script from the agent's workspace unless the task stages it, because an
  agent that owned `scripts/test.sh` would grade its own work. The files hash
  into the task id, which pins the runner that produced the recorded test ids.
  A task mined before this rule, without the tag, is refused at grade time and
  must be re-mined.
- **The prompt never names a hidden test** (`mine.prompt`, `eval/mine.gleam:181`).
  The prompt is the commit subject and body, unless the body contains an F2P
  function name or a touched test file's name, or the whole message exceeds
  8 KiB. Then it is the subject alone, tagged `prompt:subject-only`.
- **The sabotage census** reverts the first changed code line of the fix (not
  blank, not a comment, not an import) and reruns. The result is a
  `sabotage:caught|survived|not_applicable` tag. It never gates admission,
  because some fixes are one line.
- The verifier ceiling is four times the slower of the two measured runs, never
  under a minute and never over `task.max_timeout_ms` (`mine.timeout_for`,
  `eval/mine.gleam:259`).

A task also gets `family:packages/<pkg>/<module>` and `pkg:<pkg>` tags. The first
drives split assignment (see [Splits and the holdout seal](#splits-and-the-holdout-seal));
the second tells `prove` and `materialise` which package a `prepare` step runs in.

The miner records `GitTree(repo, parent, tree, prepare)`. No agent is ever handed
a git worktree: a worktree carries the object store, so `git log --all` would
show the fix.

### Proving

The miner's claim was made on a worktree it controlled. Before a task may
measure an agent, `gleam run -m eval/prove_cli` re-makes it the way the runner
will: from a `git archive` of the parent, prepared on the host, graded by
`eval/verify` in the same jail an agent's work is graded in
(`prove.prove`, `eval/prove.gleam:114`). Three trees are graded:

| Tree | Built as | Required |
| --- | --- | --- |
| Gold | Parent plus the commit's source patch (`git diff parent fix`, less test directories, guidance files and `docs/`) | Reward 1, with F2P and P2P fractions both 1.0 |
| Null | The parent, untouched | Reward 0, with F2P fraction below 1.0 |
| Sabotaged | Gold with `git.first_revert` applied | Should score 0; a census, never a gate |

`prove.verdict` (`eval/prove.gleam:202`) admits a task only at gold one and null
zero. The result is a line in `<out>/prove.jsonl` per task, so a set's admission
is a file a reader can check. A task whose proof could not run adds a
`{"file","error"}` line instead of stopping the others. The source patch is
recovered from the repository rather than carried in the task, because the task
must never carry the fix.

## The verifier: threat model and defences

`eval/verify` grades a retired trial by running the task's program in a fresh
jail. Its threat model is that the agent owns every byte of its workspace and
is adversarial towards its grader. Three things follow.

A verifier is operator-authored, and that is not the question Rule Zero asks.
Rule Zero is about where code runs, and a test command run inside the harness VM
would be a hole in the effect plane whatever its provenance. The verifier
therefore clears through the same broker seam the `bash` tool uses, over a real
helper pool, under a policy whose only readable and writable root is the copy it
grades, with the network off. There is no host fallback. A host that cannot
jail the verifier does not grade.

| Attack | Defence |
| --- | --- |
| A symlink, fifo, socket or device where a file should be | The copy walk `lstat`s every entry and keeps regular files and directories only. Everything else is dropped and counted in `side_info`. |
| A planted `logs/verifier/reward.json` | The agent's top-level `logs/` is dropped before the run. The reward file can only add a condition to a pass; it never grants one. |
| A forged dependency build (a doctored `eunit.beam` under `ebin`) | Every `build/` is dropped, and the host's pristine build, made before the agent ran, is laid over the copy. |
| A fifo or link where a hidden file goes | Hidden paths are re-checked with `wire.safe_path`, every path component must be a real directory, and the target is unlinked before it is written. |
| An agent-owned runner (`bash scripts/test.sh` read from the workspace) | A program whose argv runs a workspace path in command position is refused unless the path is among `Program.files` (`verify.command_paths`, `eval/verify.gleam:559`). |
| Output designed to make the host read a gigabyte, or to follow a link | Host reads `lstat` first, accept regular files only, and cap at 1 MiB for the stream tails and 64 KiB for `reward.json`. A fifo or link is refused unread. |
| A very large file or tree | Files over 64 MiB, or a copy past 1 GiB, are dropped and counted as `oversize` (`verify.default_caps`, `eval/verify.gleam:512`). The grade continues. |
| A verifier that wants more than the jail allows | `timeout_ms` above `task.max_timeout_ms` (600 s, the jail's default wall) is graded 0 up front and never run. |

The order is fixed and tested: the session is retired, then the copy is built,
then the hidden files are staged, then the program runs, then the artifacts are
copied out (`verify.grade`, `eval/verify.gleam:335`). The agent never has the
test files in its tree, and the verifier never runs in the harness VM.

**What a pass is.** All of these (`pass_faults`, `eval/verify.gleam:1083`):

1. The program exited with status 0.
2. Every `fail_to_pass` and `pass_to_pass` id is parsed as `Passed` from the
   output tails by `eunit_ids.parse`. An id the output never names did not pass.
3. The `reward.json`, when the program wrote one, passes the task's `Scoring`.

Any fault is reward 0 with every fault named in `side_info`. A run the wall
stopped is reward 0 with "verifier timed out" and exit status `-1`
(`no_exit_status`), never `Error`. Only a refusal, an execution failure or an
unadmitted task is `Error`, and the runner records that as `Infra`.

`side_info` is bounded at 8 KiB (`max_side_info_bytes`, `eval/verify.gleam:113`).
It is the faults, the drop counts, then a `field.scrub_text` tail. That scrubber
redacts any 32-grapheme credential-alphabet run, which includes long test names,
so the failing ids are listed unscrubbed above the tail.

**The jail.** `open_jail` (`eval/verify.gleam:205`) starts a two-helper pool, an
executor and a broker over the run directory, with `gleam` and `erl` located as
code mode locates them and mounted read-only. It then proves the pool can run
`true` under the demanded enforcement and keeps the kernel's enforcement report;
that report is what each scored row's `jail.selftest` carries. A helper that
skips a layer refuses the open with the layer named. Under `--best-effort` the
only tolerated skip is `skip:cgroup-v2` (`tolerated_skip`,
`eval/verify.gleam:154`); any other skipped layer refuses the probe and every
later run.

### Documented residual limits

These are known, written down, and not closed.

- **Forged output from code an F2P test reaches.** That code runs inside the
  test VM. It can print forged EUnit lines or halt the emulator with status 0,
  and output parsing cannot tell. The defence is that the hidden test bodies are
  ones the agent never saw and the pristine dependency build is what they
  compile against. It is not the parse.
- **The runner check is token-based.** An argv such as
  `bash -c "cd scripts && bash test.sh"` runs a workspace file the check does not
  see as a path. The argv is authored by the operator or the miner, never by the
  agent, so the check guards against a careless task, not a hostile one.
- **CPU, not wall.** The verifier policy's limits are the pool defaults
  (`cpu_s: 300`). A verifier needing more CPU time than that is killed by the
  rlimit, not the wall.
- **`jail.selftest` is "unprobed" for a plan with no program task.** No jail
  opened, so no probe ran.

## The statistics

All of it lives in `packages/evalstat`: pure Gleam, stdlib only, held to the R6
portable subset so it runs on both targets, with randomness from a seeded PRNG
(xorshift128 on 32-bit words, seeded from a string by salted FNV-1a). Both the
instrument and the governed `rollout.decide` call the same functions.

### The estimator and the decision rule

The unit of analysis is the task. For task *t*, the per-arm pass rate is
passes over counted trials, and the paired difference is `d_t`, candidate minus
baseline. Everything that decides is over the `d_t`, so every clause weights
tasks equally.

- **The plan is the denominator.** `expected` comes from the plan, never from
  the rows. A missing, duplicated or unplanned row is `Incomplete`, not a
  smaller *n*. A plan with no counted pair at all is `Incomplete("no counted
  trials")`.
- **Timeouts and refusals are failures.** `standing` (`evalstat/trial.gleam:115`)
  counts `AgentTimeout` and `SafetyRefusal` as failures. Only `Infrastructure`
  is excluded, and a pair with an excluded side is dropped whole and counted.
  Requeueing timeouts would remove the hardest tasks from the denominator.
- **The interval** is the clustered paired standard error with the task as the
  cluster, `d̄ ± 1.96 · SE`. A **cluster bootstrap** is available as an
  alternative policy (`Bootstrap(resamples, seed)`, 2000 resamples by default):
  it draws whole tasks with replacement, each contributing its observed `d_t`.
  The nested form, redrawing trials inside a drawn task, counts within-task
  variance twice.
- **The sign test** is the exact two-sided test on task signs
  (`mcnemar.sign_p_value`, `evalstat/mcnemar.gleam:71`): `min(1, 2 · P[X ≤ min(+, −)])`
  with `X ~ Binomial(n, ½)` over the non-tied tasks. The pair-level McNemar
  count is still computed and reported, and it does not decide.
- **The MDE** is `(1.96 + 0.84) · SE` (`paired.mde`, `evalstat/paired.gleam:151`):
  the smallest true difference this design would catch four times in five at
  α = 0.05.

A direction needs all five clauses: the effect is on that side of zero, the
interval lies wholly on that side, more tasks moved that way than the other,
task-level `p < α`, and `|effect| ≥ mde / 2`. Under the clustered interval the
last is implied by the second; it binds under the bootstrap.

| Verdict | Meaning |
| --- | --- |
| `Improved`, `Harmed` | All five clauses agree on a direction. |
| `Indistinguishable` | No direction, and the design could have seen the target effect (MDE at or below the policy's target, 0.10 by default). |
| `Underpowered(mde, needed_tasks, reason)` | No direction, and the MDE exceeds the target. The reason names the case. |
| `Incomplete(reason)` | A planned row is missing, duplicated or unplanned, or no counted trials remain. |

**Zero spread is never power.** With fewer than two tasks, or a standard error
of zero, the verdict is `Underpowered`. The MDE and the needed task count then
come from the binomial plug-in floor (`plugin_variance`,
`evalstat/paired.gleam:203`), and the reason says which case it was. An MDE of
zero never reaches the power comparison.

### Futility only under-claims

`futility_from_signs` (`evalstat.gleam:288`) asks one deterministic question of
the task signs so far and the pairs still to run: could any allocation of the
remaining pairs bring the sign test below α in either direction? If not, the
answer is `StopUndecided`. There is no early decision, because a verdict also
needs the interval, which the remaining pairs can still move. A stop could then
be contradicted by the full run. **The runner calls it between waves.** Round one
admits new cells a few whole tasks at a time, and before each wave
`run.futile_after` asks `futility` about every candidate over the pairs both arms
have counted. A candidate the plan could never have decided (a handful of
tasks) is not stalled by what it has seen, and the run stops only when no
candidate is still open and at least one stalled. The stop is written to
`futility.txt` and the report header as "stopped for futility after N pairs";
the cells never run are missing, so the verdicts read `Incomplete`. Retries of
cells already admitted are not gated.

### pass@k and pass^k

`pass_at_k` (`evalstat/passk.gleam:56`) is the unbiased estimator and `pass_pow_k`
is the reliability form, both per task and then averaged. `k > n` is an `Error`,
never zero. The report does not print them yet.

### A/A and degradation properties

These are properties of the decision rule, proved here on synthetic data
without a model (`evalstat/test/evalstat/verdict_test.gleam`). They are not
claims about any real model.

| Property | Test | Measured on its fixed seed |
| --- | --- | --- |
| Both arms from one Bernoulli per task (A/A) is not called either way more than 6% of the time, over 500 plans of T = 30, K = 3 | `verdict_never_improves_under_aa_test` | 7 of 500 (0.014) |
| A thirty-point drop on every task is `Harmed` on at least 95% of plans | `verdict_flags_planted_degradation_test` | bound is 475 of 500 |
| A fifteen-point drop, near the MDE, is `Harmed` on at least 30% of plans | `near_mde_degradation_power_test` | 199 of 500 (0.40) |
| One heavily sampled task cannot flip a verdict that the tasks point against | `one_heavy_task_cannot_flip_the_verdict_test` | |
| A timeout is a failure, not an exclusion | `timeouts_are_failures_not_excluded_test` | |

The fifteen-point row is the honest one for power: at the design's own scale the
rule misses a modest real effect more often than it catches it.

### Why most door comparisons are Inconclusive

The governed door caps a comparison at 20 trials, so `tasks × 2 × samples ≤ 20`
and at most ten (task, sample) pairs per arm. Protocol-change/100 gives the
arithmetic; the short version is below.

| Plan | MDE | Tasks needed for a 0.10 target |
| --- | --- | --- |
| One task, any K | undefined, always underpowered | none |
| `T · K = 10`, no spread | about 0.63 | 392 at K = 1 |
| `T · K = 10`, one sample moved | 0.28, the door's floor | none |
| T = 30, K = 3 (the instrument's own scale) | about 0.19 | 131 |

The door's floor sits above the 0.10 target. Through the door, "no direction"
is therefore always `Underpowered`, and `Indistinguishable` is unreachable. An
A/A comparison at the door is `Inconclusive`, naming the MDE and the task count
that would have sufficed. That is the statistic refusing to claim what ten pairs
cannot show. It is not a bug in the comparison, the verifier or the door. A
comparison the door can decide is one where nearly every task moves the same
way, and ten of ten is `Inconclusive` again because zero spread hands the
decision to the floor.

The same arithmetic is why the report prints the MDE as its first line: nobody
should read a four-point difference without the size of difference the design
could have seen. At T = 30, K = 3 the honest number is about 0.19.

## Splits and the holdout seal

A benchmark that is tuned against and then reported on measures how well the
tuner memorised it. Tasks fall into three splits by hash, not by choice
(`split.assign`, `eval/split.gleam:54`). The SHA-256 of the plan's salt and the
task's family gives a word from the first four digest bytes; modulo ten, 0 to 5
is `Tune`, 6 and 7 `Validate`, 8 and 9 `Holdout`. Four bytes rather than one
because a byte modulo ten is biased and would shave the holdout.

Assignment is by family so that two commits touching the same module cannot land
on opposite sides of the wall. `split.family` (`eval/split.gleam:85`) takes the
least `family:<value>` tag, so tag order cannot change the answer; a task with no
such tag is its own family keyed by its `name`. The name rather than the id,
because the name survives the edit that "fixes" a task by minting a new one.
Re-salting is a new plan and is logged.

**Be honest about what is built.** The pure parts exist: the assignment, the
family rule and the refusal in `admissible` (`eval/split.gleam:113`), which lets
`Tune` and `Validate` through and refuses `Holdout` with a message containing
"holdout". Everything that would make the seal mechanical is slice 3A and is not
built:

- There is no `eval admit` and no admission tool. Nothing calls `admissible`
  outside its own tests, and the governed door admits task sets through the
  operator's `admit_tasks`, which accepts only task set version 1.
- There is no `--holdout` run mode, and no test that scans session state for
  holdout ids.
- There is no production join (`eval production`). The validate-versus-holdout
  gap itself is in the report.

What the report does today is print a panel for each split over whatever tasks
the plan holds, each with its own verdict, and the validate-minus-holdout gap
between them. The holdout panel is therefore only
as sealed as the operator's discipline in choosing the plan's tasks. Holdout
spend is never to be reused for tuning. Two tenths of a small task pool is a
handful of tasks, so a holdout panel's MDE is large; its verdict says
`Underpowered` rather than hiding that.

## The replay lane

`eval/cassette` implements `provider/http.Transport` twice, and `eval/normalise`
decides what counts as the same request. The lane's whole claim is that the
harness, given the same model outputs, makes the same requests.

**Recording** (`cassette.recording`, `eval/cassette.gleam:456`) forwards each
request to the inner transport and tees the response onto a tape. A request is
entered when it is prepared, and filed when its terminal event passes through.
A request cancelled at any point, even before it begins, is filed as `Cancelled`,
and `finish` closes still-open entries the same way, so ordinals are contiguous
and every tape the recorder produces is readable.

**Replaying** (`cassette.replaying`, `eval/cassette.gleam:633`) matches by
digest, not position. A session runs several strands at once (primary, advisor,
subagents, summarizer), and the order their requests reach the transport depends
on the scheduler. Each request therefore takes the first recording with an equal
digest that no earlier request took. Ordinals survive only for reporting.

**Verbatim responses.** A thinking signature, an encrypted reasoning blob or a
commit hash in a response is echoed into a later request, and one altered byte
makes that request diverge. So a response is stored as received. Redaction is
limited to two things: the exact credential values the request's own headers
carried (held in memory during the request, never written), and the prefixes
`sk-`, `xai-`, `ghp_`, `gho_`, `ghs_`, `ghu_`, `github_pat_` and `Bearer `. Any
change marks the recording `Redacted`, and **a redacted recording is reported
at replay, not served.** Of the response headers only the status and
`content-type` are stored. A non-UTF-8 body is left as it is.

**Digest matching** (`normalise.view`, `eval/normalise.gleam:92`) reduces a
request to leaves (method, URL path, one leaf per JSON scalar, each key path
JSON-encoded) and a SHA-256 over them. What is out, deliberately:

- Headers, entirely, and the URL's host and query.
- Any object key containing `key`, `secret`, `password`, `cookie`, `session`,
  `authorization`, `credential`, or the singular `token`, at any depth.
  `max_tokens` stays, because it is a count.
- Paths under the trial root become `<root>`, but only at a path boundary, so
  `/w/t1` does not swallow `/w/t10`.
- ISO-8601 dates and times become `<date>` everywhere, **including inside user
  content**, so text that differs only in a date does not diverge. That is a
  limit of the lane, chosen on purpose.

**Divergence reports.** No match is a `Divergence` naming the nearest recording:
the longest agreeing leaf prefix, then the same position. It is delivered to the
harness as `RequestFailed("replay diverged at request n: ...")`, and the tape's
bytes never answer a different request. The tape keeps each leaf's length and a
12-digit fingerprint, never prompt text, so the summary can name the first
differing key path without writing a prompt to disk. In the ledger a divergence
is a `VerifierFailed` row whose `side_info` begins "lane finding:".

Tapes live at `<tapes>/<task id>/<index>.jsonl`, so one tape serves every arm of
that task and trial index. That is what lets a replay A/A run the same tape under
two arm ids. A tape is one JSON object per line, each with `"v":1`, and its
decoder is total.

Both transports honour the `Transport` contract the way the native ChatGPT
transport does: one parked weft managed task per request, its scope pid the
drain witness, nothing (including the inner `prepare_streaming`) running before
the begin permit. The recording sink and replay log are weft actors reached
through a monitored `ask`. A dead or wedged actor fails the request with
`RequestFailed("replay lane unavailable: ...")` instead of crashing its task.

## Exports and the failure taxonomy

None of these runs a trial, builds an image or uploads anything.

**ATIF.** `atif.from_entries` (`eval/atif.gleam:174`) is a pure walk from
conversation entries to an ATIF-v1.7 trajectory. Steps are 1-based and
contiguous. A tool result joins the step that most recently issued its call id,
since ids repeat across messages; an orphan result is dropped. Thinking blocks
are never read. `atif.from_session_db` (`eval/atif.gleam:280`) never opens the
original database: it copies the database and its `-wal`, opens the copy with a
clock far past any lease expiry, reads at most `max_entries` (8192) entries and
deletes the copy. `atif.scrub` applies the replay lane's prefix rule, not the
32-grapheme scrubber, which would mangle commit hashes and test names. Keep its
prefix list aligned with `cassette.redact_text` by hand. **The runner calls it**
once a trial is judged: `trajectory.json` lands in the attempt root and the
row's `artifacts.trajectory` names it. A failed export is told at the head of the
row's `side_info` and never changes the outcome or costs the row.

**Harbor.** `harbor.export` (`eval/harbor.gleam:198`) writes a task directory
Harbor reads. The one repository read is `git diff <parent> <fix>`, whose source
half becomes `solution/gold.patch`. A git task's Dockerfile clones `--repo-url`,
checks out the task's commit and deletes `.git`, so the fix is not in the
container's object store. `--base-image` and the URL are charset-checked before
they reach a Dockerfile line. `tests/test.sh` for a program verifier copies the
hidden files in, runs the argv, and a Python helper writes
`{"f2p": x, "p2p": y}` from the EUnit result lines; an expected-files verifier
writes `{"files": x}`. An inline program task has no reference solution and its
`solve.sh` fails and says so.

**The Harbor agent adapter** is the other direction: Harbor running Loom.
[`integrations/harbor`](../../integrations/harbor/README.md) is a Python package,
`loom_harbor.agent:LoomAgent`, that Harbor loads by import path
(`harbor run --agent loom_harbor.agent:LoomAgent -m provider/model`). It installs
a release into the task container, writes a one-model `loom.toml`, starts `loomd`
and drives it with `loom run -p`, and reports the run as an `AgentContext` plus an
ATIF trajectory. It lives outside `packages/` because it is not Gleam and not part
of `make check`; `make harbor-test` runs its tests. Two decisions belong here.
Isolation is an explicit `jail` option, `container` (the task container is the
boundary; `loomd --best-effort`) or `platform` (Loom's own jail must enforce every
probe or the trial is refused before it costs anything), and the posture, with
what `loom run` measured, is recorded in the results and the trajectory. And
because `packages/eval` never ships, the adapter converts the session database on
the host with a Python port of `eval/atif.gleam`, checked step for step against
this module on a database Loom's storage package wrote. The README lists what the
trajectory lacks (the system prompt and tool definitions, subagent strands) and
the Loom-side change that would close each, and what has not been verified: a real
container run, a real release, a real model.

**Transcripts and the taxonomy.** The failure taxonomy has to come from what
agents did before anyone writes a task to test for it. `transcripts.export`
(`eval/transcripts.gleam:125`) copies each session database under
`<out>/.copies/` (never `/tmp`), opens the copy, writes one JSONL per session at
mode 0600 and deletes the copy on every path. An original is never opened. A
copy that carries a live daemon's unexpired writer lease is refused by its open
and appears in the census as a failure, so stop the daemon first. A file is a
header (scrubber limits, primary model, outcome), then entries in sequence
order, then usage rows. Tool calls keep a name, the argument keys and a 256-byte
scrubbed preview; tool results keep `is_error` and the last 512 bytes. A missing
operator mark is the word `unmarked`, never a failure or a success.
`transcripts.sample` (`eval/transcripts.gleam:182`) reads only headers, groups
by model id and outcome, shuffles each group with a seeded generator and deals
round-robin.

The scrubber is a heuristic, and the header of every file says so: free text in
a tool result is scrubbed by shape only, so a short secret in prose survives.
The export is for the owner's eyes and is not committed.

The protocol that uses it is
[`docs/review/eval-failure-taxonomy-2026-10.md`](../review/eval-failure-taxonomy-2026-10.md):
export, draw a stratified sample of at least 40 sessions, label each with one
primary category (the owner and an independent reviewer, separately), and let
the counts decide. A category holding at least 5 percent of labelled failures
needs at least 3 tune-split tasks tagged with it before hand-written tasks are
authored. As written, that document is protocol only: no sessions have been
exported or labelled, and its results table is empty on purpose.

## Commands

All commands run from `packages/eval`, and none is part of a release. Flags take
one value each unless noted; an unknown flag or missing value is an error naming
it. Usage errors exit 2 on the miner, prover, exporter and transcripts CLIs.

| Command | Flags (required marked) | Notes |
| --- | --- | --- |
| `gleam run -m eval/mine_cli -- ...` | `--repo NAME=PATH` (repeatable; `loom` defaults to the current checkout), `--name` (default `loom`), `--out` (required), `--package a,b`, `--limit N`, `--commit HASH`, `--work DIR` | `--limit` of 0 or absent means no limit. `--work` defaults to `$HOME/evalwt/mine`. Writes `<out>/<id>.json` per admitted task and one `census.jsonl` line per candidate. |
| `gleam run -m eval/prove_cli -- ...` | `--tasks` (required), `--repo NAME=PATH` (repeatable), `--out`, `--helper`, `--seed`, `--best-effort` | `--out` defaults to `$HOME/evalwt/prove`; `--helper` to `../sandbox/loom-exec`; `--seed` to `../../build/codemode-seed`. `--best-effort` takes no value. Writes `prove.jsonl`. |
| `gleam run -m eval/run_cli -- run <plan.json> ...` | `--out`, `--tasks`, `--arms`, `--config`, `--helper`, `--seed`, `--tapes`, `--record`, `--repo NAME=PATH` (repeatable) | Defaults: `$HOME/.loom/eval/runs`, `tasks`, `arms`, `loom.toml`, `../sandbox/loom-exec`, `../../build/codemode-seed`. A live plan takes models from `--config` and keys from the environment. A replay plan needs `--tapes`. `--record` is for a live plan only. Re-running the same command resumes. |
| `gleam run -m eval/run_cli -- report <run-dir>` | none | Rebuilds `report.md` and `report.json` from a finished or interrupted run without running anything. |
| `make eval-run ARGS="run plan.json --tasks T --arms A"` | as above | `cd packages/eval && gleam run -m eval/run_cli -- $(ARGS)`. |
| `gleam run -m eval/export_cli -- atif <session.db> <out.json>` | positional | One trajectory. |
| `gleam run -m eval/export_cli -- harbor ...` | `--tasks`, `--out`, `--repo-url`, `--base-image` (all required), `--repo NAME=PATH` (repeatable) | A task that cannot be exported is reported on its own and the rest are written; the exit is nonzero if any failed. |
| `gleam run -m eval/transcripts_cli -- export ...` | `--state DIR` or `--db PATH` (repeatable; one is required), `--since` (required), `--out` (required) | `--since` is `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SSZ`, UTC only; an offset is refused rather than guessed at. |
| `gleam run -m eval/transcripts_cli -- sample ...` | `--dir`, `--n`, `--seed` (all required) | Prints one path per line; the same inputs give the same batch. |
| `gleam run -m eval -- validate <file>` | one path | Runs the same total decoders the runner uses on a task, arm, plan or ledger file, and exits nonzero on refusal. |

Test roots for anything that opens a session live under
`packages/eval/build/eval-test/` or `$HOME/evalwt/`, never `/tmp`. A test that
opens a session needs `packages/sandbox/loom-exec` and `build/codemode-seed`;
without them it prints `SKIP` on standard error and passes.

## Bounds

| Bound | Value | Owner |
| --- | --- | --- |
| Prompt | 8 KiB | `task.max_prompt_bytes` |
| Inline files, expected files | 64 files; 256 KiB across paths and contents | `task.max_inline_files`, `task.max_file_bytes` |
| Hidden verifier files | 256 files; 256 KiB total | `decode_program` |
| Name, tags | name 256 bytes; 64 tags of at most 128 bytes | `eval/task.gleam` decoder |
| Repository name; argv | name 64 bytes of `[a-z0-9-]`; argv 1 to 64 words, no NUL | `eval/task.gleam` decoder |
| Repository path (operator flag) | absolute, 1024 bytes, no NUL, `::` or `-` segment | `eval/repos.gleam` |
| Verifier wall | 1 to 600,000 ms | `task.max_timeout_ms` |
| Trials per cell | 1 to 1000 | `plan.check` |
| Concurrency | 1 to 256 | `plan.check` |
| Attempts per cell | 3; `Infra` terminal only at attempt 3; `AgentTimeout` is never retried | `ledger.max_attempts` |
| `side_info` | 8 KiB | `ledger.max_side_info_bytes`, `verify.max_side_info_bytes` |
| Stream tails, `reward.json` | 1 MiB each; 64 KiB | `verify.max_stream_bytes`, `verify.max_reward_bytes` |
| Copy walk | 64 MiB per file; 1 GiB per copy | `verify.default_caps` |
| Jail pool | 2 helpers; clearance wait 5 s; probe 30 s | `verify.pool_size`, `verify.clearance_ms` |
| Host commands | 30 min per materialise step; 5 min for a tree-id check or archive; 10 min per prove step | `materialise`, `prove.host_step_ms` |
| Request guard | `max_requests_per_trial` per attempt | the plan, `eval/trial` |
| Dollar admission | cap, less measured spend, less in-flight worst cases, must cover one more worst case (`max_requests_per_trial * priced (3 * context + output)`); the first refusal is permanent | `eval/budget` |
| ATIF entries | 8192 | `atif.max_entries` |
| Transcript previews | 256 bytes of tool arguments; 512 bytes of tool results | `eval/transcripts` |
| Statistics | α = 0.05, `z` = 1.96 and 0.84, 2000 bootstrap resamples, target effect 0.10 | `evalstat` |

The governed door's ceilings are different, and they are not the instrument's.
They bound a model spending the operator's money. After protocol-change/100:

| Door ceiling | Value |
| --- | --- |
| Trials | 20 |
| Samples per task and arm | 1 to 3 (the evaluator's own bound is 5) |
| Turns | 100 (`model_door.turns_ceiling`, `evolution/model_door.gleam:73`) |
| Wall | 480,000 ms (`model_door.wall_ceiling_ms`, `evolution/model_door.gleam:83`), 120,000 ms (`wall_margin_ms`) below the 600,000 ms code-mode call timeout |
| Tokens | 1,000,000, unchanged |
| Dollars | 2.0, unchanged |
| Retained output | 65,536 bytes |

`validate` (`evolution/rollout.gleam:398`) refuses a request whose trial budget
cannot hold `tasks × 2 × samples`, naming the product, before any trial opens.
A compare may now hold its budget for up to eight minutes instead of two and may
make up to a hundred provider attempts, within the same dollar and token caps.

## Recovery and failure behaviour

| Failure | What the instrument does |
| --- | --- |
| The run is killed mid-trial | A `Running` row was written first. On resume, a `Running` row with no successor is closed as an `Infra` row with the reason "interrupted"; that attempt is spent. Finished cells are skipped. The budget account starts with the ledger's recorded dollars (Infra rows included) debited from the cap, so the cap bounds spend across all attempts. |
| A trial hits a harness, jail or network fault | An `Infra` row, followed by a retry round at attempt + 1, up to 3. At attempt 3 the `Infra` row is terminal, and the cell is `Infrastructure`, excluded from the estimate and counted in the report. |
| The agent runs out of wall | `AgentTimeout`. Terminal, never graded, never retried, counted against the arm. |
| Retirement cannot be confirmed | An `Infra` row. The workspace is never graded. |
| The verifier cannot run the program at all | `Error`, so `Infra`. A run the wall stopped is instead a graded zero. |
| The host cannot supply the demanded enforcement | `open_jail` refuses with the skipped layer named. There is no host fallback. |
| The budget runs out | The first refusal is permanent, recorded as "budget exhausted after N trials". The unrun cells have no rows, and the verdict is `Incomplete`. |
| A row is missing, from another plan, outside the plan, or rerolled | `ledger.reconcile` (`eval/ledger.gleam:384`) refuses with `plan row missing: <task>/<arm>/<index>`, or names the stray or the rerolled cell. Every verdict is then `Incomplete` with that reason. |
| The process crashes while appending | One writer actor appends each row as a whole line, so a crash leaves a parseable prefix. |
| A replay diverges | A `VerifierFailed` row naming the request and the first differing key path. |
| An arm cannot be applied | `run.execute` refuses before any trial starts. A `PromptPack` component that does not decode, and any `Target.role` other than `Any`, are refused by name. |

The report trusts only a reconciled ledger. Any reconcile failure makes every
verdict `Incomplete`; nothing is estimated from a partial ledger, because
dropping the cells that never ran is the easiest way for a comparison to flatter
itself. The ledger's sequencing rule is strict: attempts start at 1, within an
attempt an optional `Running` row is followed by at most one finished row,
attempt k + 1 may begin only directly after an `Infra` row at attempt k, and
nothing may follow a `Scored` row. A scored trial that could be rerun and
re-appended would let a comparison keep the draws it liked.

## What this environment could and could not prove

The environment that built this had no model API keys and no cgroup v2. That
limits what was exercised, and it is worth being exact about it.

**Proved here:**

- The statistics' A/A and degradation properties, and the failure ruling, on
  synthetic data on fixed seeds.
- The decision rule's mapping onto the governed verdict, through the
  `models_test` cases protocol-change/100 lists.
- The codecs, the plan-as-denominator rule, the reconcile and sequencing rules,
  the budget account, and the report.
- The replay lane: record, replay, digest matching, redaction, divergence.
- The verifier's isolation and its ordering, in a real jail under best effort
  (every `skip:` being `skip:cgroup-v2`; the test prints a `NOTE` line). Any
  other refusal is a `SKIP`.
- The miner's pipeline against the `eccdddad0` probe, and a program-verifier
  trial through `trial.run_one` and the real jail, which needs the loom
  repository history and skips without it.

**Not proved here, so an operator runs them:**

- A live A/A plan (`packages/eval/plans/aa-live.json`: the same arm twice, 21
  tasks, K = 3) whose verdict must not be `Improved` or `Harmed`; repeat it for a
  few runs.
- A live planted-degradation plan (`plans/degrade-live.json`: arm B prefixes an
  instruction to run no tests) that must read `Harmed` if the drop is large
  enough to power. `plans/README.md` has the commands, the cost method and the
  minimum detectable effect the committed set gives (about 0.25 at worst).
- A Terminal-Bench subset ranked against the public board. `loom run` and the
  Harbor adapter now exist (`integrations/harbor`), but the adapter has not been
  run through a real Harbor trial: this environment had no Docker daemon, no
  release asset and no model key.
- The holdout-to-production comparison on real sessions, which needs slice 3A.
- The governed end to end under full enforcement, on a kernel with delegated
  cgroup v2, where `open_jail` runs under `PlatformEnforcement`.
- Harbor's trajectory validator on an exported file, once, by hand:
  `python -m harbor.utils.trajectory_validator <out.json>`; and one oracle run
  to confirm whether Harbor carries the agent's workspace into the verifier
  container under `environment_mode = "separate"`.
- The failure-taxonomy export and labelling, which needs production sessions.

## Deferred work and its homes

| Not built | Where it lands |
| --- | --- |
| Admission tool and the mechanical holdout seal; the production join | Design note slice 3A, `eval/split` plus a new `eval/production` |
| Per-role profile key (so `Target.role` can be applied) | protocol-change/101, reserved |
| Task set v2 admission through `admit_tasks`; refusing a repeated (fixture, expected) pair | protocol-change/100, "Task set v2 is deferred" |
| Refunding the unused part of a per-attempt reservation, so large-window targets can reach `Passed` | Follow-up to protocol-change/100 |
| `Program` verifiers in governed comparisons | ADR-021, deferred |
| `loom run -p` and the Harbor agent adapter | Built (`tui/run`, `integrations/harbor`); a real container run, an in-release ATIF export and strand-aware trajectories remain, see the adapter README |
| The GEPA search | A later `eval/optimize`, consuming `Arm.components` and `Grade.side_info` |
| The variance decomposition in the report | `eval/report`, calling `evalstat/paired.decompose` as it stands |
| Mining of `client`, `tui` and `session_view` | After a measured per-module verifier cost |
| Replace-mode tool descriptions, a SQLite ledger, LLM-judged tasks, byte-exact replay | Rejected (ADR-021 and the design note's cut list), not deferred |

## Where the code differs from the design note

The design note's section 15 already records four review changes: the task-level
sign test, the `Underpowered` reason, whole-task bootstrap resampling with
under-claiming futility, and the verifier boundary. These are further places
where the code is the authority.

- **No single `eval` command.** The note describes `eval mine --prove`,
  `eval run`, `eval admit`, `eval production` and `eval transcripts`. The tree
  has one module per command (`mine_cli`, `prove_cli`, `run_cli`, `export_cli`,
  `transcripts_cli`) and an `eval validate` verb. `admit` and `production` do
  not exist.
- **Run directory.** The note says `<state>/eval/runs/<plan_id>/`. The default is
  `$HOME/.loom/eval/runs/<plan id>/`, with `--out` to override.
- **Splits.** The note says the first byte modulo ten, with the family being the
  first touched source module. The code reads the first four bytes, takes the
  least `family:` tag, and the miner writes that tag as
  `family:packages/<pkg>/<module>`.
- **`prepare` is a list of argvs,** each on an allowlist of three, not the
  single argv in the note's sketch.
- **Report scope.** The report prints the MDE first, then each comparison under
  the clustered interval and again under the bootstrap (2000 resamples seeded by
  the plan id), a panel per split, the validate-minus-holdout gap (flagged
  "memorised" when positive beyond its own interval), pass@k and pass^k for
  k = 1..K, a dominance ruling per candidate, per-arm lines, per-tag pass rates
  and the served models. It does not print the variance decomposition.
- **`SafetyRefusal` is recognised by text.** `core/message.StopReason` has no
  refusal variant; the provider adapters report a refusal as `Errored` with a
  fixed message, and `trial.is_refusal` matches those messages. A trial whose
  last assistant message is one is a scored, counted failure, not an
  infrastructure fault.
- **Ledger artifacts.** A scored row records `session_db`, `workspace` and
  `trajectory` paths, relative to the attempt root; `verifier_stdout` is an empty
  string. The verifier's output is in `verifier/` under the attempt root.
- **No budget defaults.** The note proposes 40 requests, a 20-minute wall and a
  concurrency of 2. The plan carries these as required fields; the decoder only
  checks that they are positive and that concurrency is at most 256.

## Module ownership and reading order

Paths are relative to `packages/eval/src/eval/` unless marked.

| Modules | Responsibility |
| --- | --- |
| [`wire`](../../packages/eval/src/eval/wire.gleam), [`task`](../../packages/eval/src/eval/task.gleam), [`arm`](../../packages/eval/src/eval/arm.gleam), [`plan`](../../packages/eval/src/eval/plan.gleam), [`ledger`](../../packages/eval/src/eval/ledger.gleam), [`split`](../../packages/eval/src/eval/split.gleam) | The pure, total, content-addressed codecs and the rules that hold a ledger to a plan. Start here. |
| [`eunit_ids`](../../packages/eval/src/eval/eunit_ids.gleam), [`git`](../../packages/eval/src/eval/git.gleam), [`mine`](../../packages/eval/src/eval/mine.gleam), [`mine_cli`](../../packages/eval/src/eval/mine_cli.gleam) | The miner: test-output reader, git argv builders and diff splitting, the per-commit pipeline. |
| [`verify`](../../packages/eval/src/eval/verify.gleam), [`prove`](../../packages/eval/src/eval/prove.gleam), [`prove_cli`](../../packages/eval/src/eval/prove_cli.gleam) | The jailed verifier and the mutation test of a task's verifier. The hardest isolation code in the package. |
| [`materialise`](../../packages/eval/src/eval/materialise.gleam), [`arm_settings`](../../packages/eval/src/eval/arm_settings.gleam), [`budget`](../../packages/eval/src/eval/budget.gleam), [`trial`](../../packages/eval/src/eval/trial.gleam) | One attempt, from a starting tree to a ledger row. |
| [`run`](../../packages/eval/src/eval/run.gleam), [`report`](../../packages/eval/src/eval/report.gleam), [`run_cli`](../../packages/eval/src/eval/run_cli.gleam) | Rounds, the single ledger writer, resume, and the report. |
| [`normalise`](../../packages/eval/src/eval/normalise.gleam), [`cassette`](../../packages/eval/src/eval/cassette.gleam) | The replay lane. |
| [`atif`](../../packages/eval/src/eval/atif.gleam), [`harbor`](../../packages/eval/src/eval/harbor.gleam), [`export_cli`](../../packages/eval/src/eval/export_cli.gleam), [`transcripts`](../../packages/eval/src/eval/transcripts.gleam), [`transcripts_cli`](../../packages/eval/src/eval/transcripts_cli.gleam) | Exports and the failure-taxonomy tooling. |
| [`evalstat`](../../packages/evalstat/src/evalstat.gleam) and its [modules](../../packages/evalstat/src/evalstat/) (`trial`, `pairing`, `binomial`, `mcnemar`, `paired`, `bootstrap`, `prng`, `passk`, `verdict`, `dominance`) | The statistics and the decision rule, in the package's own reading order. |
| [`search`](../../packages/eval/src/eval/search.gleam), [`reflect`](../../packages/eval/src/eval/reflect.gleam), [`optimize`](../../packages/eval/src/eval/optimize.gleam), [`optimize_cli`](../../packages/eval/src/eval/optimize_cli.gleam) | The prompt search's Loom side: the log rows and their adapter, the reflective dataset and the gateway call, the effectful driver and the front files. |
| [`gepa`](../../packages/gepa/src/gepa.gleam) and its [modules](../../packages/gepa/src/gepa/) (`verdict`, `select`, `budget`, `prompt`, `judge`, `prng`, `log`) | The search itself as a stdlib-only library another project can embed: the replayable state machine (steps of one or several proposals, a strict screen, a perfect parent skipped, a truncated answer refused), the front and draws, the budget holds, the reflection prompt with per-slot background and a digest of rejected rewrites, the default acceptance rule and the log codec. The remaining upstream GEPA techniques are tracked in issue #1126. |

Dependencies point one way. `eval` depends on `client` (the trial recipe and the
jail), `evalstat`, `gepa`, `provider`, `storage`, `session`, `runtime`, `tools`,
`prompt` and `core`, with `weft` for process machinery. Nothing depends on
`eval`, and `gepa` depends on nothing in the tree. The
governed `client/evolution/rollout` depends on `evalstat` and never on `eval`.

When you change the package, three rules are worth knowing before you start. A
task, arm or plan shape is the shared contract with the miner and the ledger, so
changing a type changes identities and every stored file. `eval/trial` order is
the verifier's guarantee, so a new step goes where its failure mode says, not
where it is convenient. And `evalstat/trial.standing` is the instrument's claim
about timeouts; changing it is changing what the verdict means.
