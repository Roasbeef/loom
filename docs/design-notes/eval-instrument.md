# Design: the evaluation instrument (steps 1–6, GEPA-ready)

Status: plan of record for issue #236's evaluation workstream, written
2026-10-25 against tree `f21afd07d`. ADR-021 records the decisions that
outlive this note; this note carries the argument and the wave plan.
Paths are relative to the repository root; `evo/` is
`packages/client/src/client/evolution/`. Every claim about existing behaviour
cites a line read at that tree. Two external studies fed it: GEPA and its
`optimize_anything` extension (arXiv 2507.19457, 2605.19633), and the
evaluation harness nanocodex carried before its commit `2d4a4c539` removed it
(cited below as `<path>@P`, P being that commit's parent). A mining probe on
`eccdddad0` (machine: 77 pass/2 fail with only the commit's test applied, 79
pass with its fix, 3.5 s warm) is the measured shape the miner is designed
around. No model API key existed in the container that wrote it, so every
live experiment below is an operator-run command.

## 0. Three premises I am correcting first

**P1. "Generalise `rollout.evaluate` or supersede it" is the wrong fork.**
`rollout.evaluate` is not an evaluator; it is a *budget-and-evidence
lifecycle*: admission (`rollout.gleam:304-334`), the per-arm fold
(`:263-267`), worst-case debits (`:103-111`, `rollout_host.gleam:415-460`),
retirement-before-scoring (`:408-412`) and durable evidence (`:273-280`).
The only two things wrong with it for our purpose are small and local: it
takes one sample per arm, and `verdict` (`:659-690`) is not a comparison
(`candidate_failed` ignores the baseline, `:676`). Everything else — the
10-task/20-trial/1 M-token ceilings (`:310-329`, `model_door.gleam:175-188`)
— is a *model-door* ceiling that is correct for a model spending the
operator's money and wrong for a developer instrument. So: the instrument
does **not** route through `rollout.evaluate`, and `rollout.evaluate` is
**not** generalised into an instrument. Both call the same pure verdict
function and the same jailed verifier, and the governed path keeps its
ceilings. The shared parts are three functions, not a framework.

**P2. "Ensemble" in Loom is already mostly a catalogue question, not a
profile question.** A profile is keyed by exact `(provider, model_id, api)`
(`provider/profile.gleam:137-167`); two strands on the same model get the same overlay
and nothing today sees a strand or role at composition time
(`provider/gateway.gleam:2227-2252`). But the roles that exist — `main`, `subagent`,
`advisor`, `summarize`, `vision` — already resolve to *different models* via
`[roles]` (`client/catalog`; `agency.Config.subagent_model`, client CLAUDE.md),
and a different model gets its own profile for free. So "different prompts
or tools per agent" is, for the first two waves, "a different `Settings`
per arm" (catalogue roles, profile map, `LOOM_PROMPT_PACK`), which needs no
core change and no protocol change. The per-role key inside one model is a
real gap, but it is protocol-change work (`prompt.encode_profile`'s strict
8-field v1 shape, `evolution/prompt.gleam:118-160`) and it is deferred, not
designed away: the arm type below carries the role axis so step 7 and the
later change slot in without a new abstraction.

**P3. "Sequential stopping under the request guard" conflates two budgets.**
The guard reserves `3 × context_window + output` tokens *per request*
(`rollout_host.gleam:232-240`) and prices that worst case against
`remaining.dollars` (`:249-258`). With a 200 k window one request reserves
600 k tokens and ~\$2.4 at Sonnet rates, so a \$2 per-comparison cap refuses
the *first* request. The guard is a per-trial safety net against a runaway
session; it cannot be the run budget. The instrument's run budget is
measured spend after each settled trial (from `storage.stats`,
`rollout_host.gleam:331-333`), and the guard allowance per trial is derived
from a declared `max_requests_per_trial`. Sequential stopping is then a
*decision-rule* question, answered in §5, not a guard question.

## 1. Where the instrument lives (Q1)

**Ruling.** Two new packages plus a thin seam in `client`.

| Package | Purity | Depends on | Holds |
|---|---|---|---|
| `packages/evalstat` | pure, stdlib only, **added to the R6 portable set** (`lint/portable.gleam`) | `gleam_stdlib`; dev: `gleeunit`, `qcheck` | estimators, tests, bootstrap, pass@k/pass^k, MDE, dominance, the `Verdict` decision rule, a seeded xorshift PRNG |
| `packages/eval` | effectful dev tool, **never in the release** | `client`, `harness`, `provider`, `storage`, `evalstat`, `simplifile`, `argv`; dev: `gleeunit`, `qcheck` | task codec, plan codec, ledger, miner, runner, jailed verifier, cassette, exports, CLI `gleam run -m eval` |
| `client` (existing) | — | + `evalstat` | `rollout.verdict` → `evalstat`; `rollout.Trial.score` returns a `Grade`; `serve.trial_settings` extracted `@internal` |

Why a package and not `client/dev/eval_dev.gleam`: the miner, ledger,
runner, verifier, cassette and exports are ~2,500 lines; one dev module
cannot own them, and anything under `client/src` ships in `loomd`.
`conformance` is the precedent for a package that depends on `client` and
never ships. Why `evalstat` is separate from `eval`: the governed
`rollout.verdict` must call it (so `client` depends on it; `client` cannot
depend on `eval`), and a pure stdlib package gives a seconds-long test loop
for the one piece whose correctness is mathematical. Why R6: the web view
could render a paired report tomorrow, and R6 is what keeps a host out
(`CLAUDE.md`, ground rules; `lint/portable.gleam:1-40`).

Registration cost: `Makefile` `PACKAGES` (line 6), `scripts/check.sh`
`packages=(…)` (line 7), `scripts/test.sh` `known=` (line 7), two
`CLAUDE.md`/`AGENTS.md` pairs, `make doc-check`. Python stays out: the
house rule, and every piece here either needs a jail or is a decision rule
that must be property-tested. The one Python exception is the Harbor
*agent adapter* (Harbor's API is Python), which is cut from this wave (§10).

Process machinery: the runner's per-cell concurrency is a `weft` run of
managed tasks (one task per trial, deadline = agent wall + verifier wall +
grace); the verifier wait is `weft/poll`; nothing hand-rolled.

**Cut list for Q1:** no `loom eval` subcommand in the shipped binary; no
SQLite ledger (JSONL + a pre-materialised plan file is enough for one
operator and is what Harbor/nanocodex pair rows on); no dashboard; no
Python.

**Cheapest falsifier:** if `gleam build` of `packages/eval` against a
cached `client` takes longer than a `client` rebuild, the package boundary
is buying nothing and the modules go under `client/dev/`.

## 2. Relationship to the governed `evolution.compare` path (Q2)

**Ruling.** The governed plane stays the only route to promotion. The
instrument *produces* and the governed plane *consumes*; they share three
things and nothing else:

1. **One trial recipe.** `serve.evolution_trial` (`serve.gleam:8054-8108`)
   builds a `Settings` for a fresh jailed session. Extract its body into
   `@internal pub fn trial_settings(settings, target, api, profiles, root, tag,
   base_policy) -> Settings` so `eval/trial.gleam` and the governed opener
   call the same function. The instrument opens with `serve.open_instance`
   (`:2284`) and retires with `instance_retirement`, exactly as the governed
   path does. The embedding `harness` (`harness.Embedded` refuses every broker
   execution, `packages/harness/CLAUDE.md` "Invariants") is **not** the trial
   runner: a coding task needs `bash`, `fs_*` and code mode in a jail.
2. **One grade type and one verifier.** `rollout.Trial.score` currently
   returned `trace.Outcome` at `f21afd07d`, three-valued, with no
   diagnostic. It becomes `fn(String) -> Result(Grade, String)` where
   `Grade(reward: Float, scores: List(#(String, Float)), side_info: String,
   verifier: VerifierRun)` (sketch in §3). The governed path's
   `fixture.score` adapts to `Grade(1.0 | 0.0, [], "", …)` so the exact-byte
   scorer keeps working; the jailed program verifier (§3) is the second
   implementation. `score` runs after `retirement.perform(trial.close)`
   (`:408-412`) in both.
3. **One decision rule.** `rollout.verdict` (`:659-674`) calls
   `evalstat.paired_verdict(cells, policy)` (§5) instead of
   `candidate_failed`. Scripted mode stays `Inconclusive` (`:661`); that
   ruling is correct and nothing here touches it.

How instrument evidence becomes citable: it does not, directly. An
instrument run writes a **report envelope** (JSON, content-addressed by
`mcp.sha256_hex` of canonical bytes, carrying plan id, task-set ids, arm
digests, model ids actually served, the `evalstat` verdict and every trial
row id). An operator who wants it beside a candidate submits it through the
existing operator door as an observation — but **it is labelled
`Purpose = InstrumentReport`, never `IndependentRollout`**, and `select`
still requires `IndependentRollout` evidence from the governed run on the
admitted set. Reason: the instrument runs outside the catalogue's authority
and budget; letting it stand in for the governed run would be exactly the
"separate promotion mechanism" #236's owner comment forbids. Cost: a
promotion candidate is run twice (instrument for search and sizing, governed
for the record). That cost is the design.

`rollout.evaluate` gains **one** generalisation: `Limits.samples: Int`
(1..5) so the fold runs K samples per task per arm with the same budget
machinery. That is a field in a non-frozen client type; the model door
(`model_door.gleam:88`) defaults it to 1 and caps it at 3. Nothing else
in `rollout.evaluate` changes shape.

**Cut list:** no second catalogue, no instrument-originated `approve`, no
"compare on an unadmitted task set" door, no rewrite of `rollout.evaluate`
into a generic engine.

**Cheapest falsifier:** run `evolution_prompt_acceptance_test` after the
`Grade` change with `samples: 1`; if its retained observation JSON
(`rollout.gleam:577-618`) differs anywhere except the new `grade` member, the
seam leaked.

## 3. Task model and the hidden verifier (Q3)

**Ruling.** One task type, version 2, content-addressed, with the
workspace and the verifier as sum types. Hand-written fixtures, mined
SWE-style tasks and Harbor imports are three *producers* of the one type;
the runner never branches on provenance (nanocodex `import/mod.rs@P:3-9`).

```gleam
/// eval/task.gleam — pure codec, no I/O.
pub type Task {
  Task(
    /// sha256 of `canonical(task)` with `id` blank; any edit is a new task.
    id: String,
    /// Human handle, informational only (never used for pairing).
    name: String,
    /// What the agent is told. ≤ 8 KiB.
    prompt: String,
    workspace: Workspace,
    verifier: Verifier,
    /// Taxonomy tags (§9) used for split quotas and reporting.
    tags: List(String),
    /// Where it came from; informational, hashed, never trusted.
    provenance: Provenance,
  )
}

pub type Workspace {
  /// ≤ 64 files, ≤ 256 KiB, as `tasks.Fixture.files` today.
  Inline(files: List(#(String, String)))
  /// A git tree. `tree` is `git rev-parse <commit>^{tree}` — already a
  /// content digest of the whole worktree, so no second hash is needed.
  GitTree(repository: String, commit: String, tree: String, prepare: List(String))
}

pub type Verifier {
  /// Exact bytes, the v1 scorer (`fixture.score`).
  ExpectedFiles(expected: List(#(String, String)))
  /// Hidden files staged after the agent is gone, then one argv run in a
  /// fresh jail. Reward is read from `/logs/verifier/reward.json`
  /// (Harbor's contract) or the exit status when the file is absent.
  Program(
    files: List(#(String, String)),
    argv: List(String),
    fail_to_pass: List(String),
    pass_to_pass: List(String),
    timeout_ms: Int,
    policy: Scoring,
  )
}

pub type Scoring { AllRewardsOne  AllRewardsPositive }

pub type Provenance {
  HandWritten(author: String)
  MinedCommit(fix: String, parent: String, subject: String)
  HarborImport(dataset: String, revision: String, task: String)
}
```

**Mined tasks, from the measured probe.** The miner (`eval/mine.gleam`,
host-side, trusted history, runs under `client/internal/ffi_os.run_capture`
as `secrets.host_runner` does, `secrets.gleam:455-474`) does, per candidate
commit `c`:

1. `git worktree add --detach <root>/<hash> c^` (never under `/tmp`,
   `docs/execution.md` §4).
2. Split `git diff c^ c` into `tests` (paths matching `packages/*/test/**`)
   and `src` (everything else except `CLAUDE.md`/`AGENTS.md`/`docs/`).
3. Apply `tests` only; run `bash scripts/test.sh <pkg> --match <module>` for
   each touched test module; parse the EUnit lines ` test: <module>@<file>.<fn>`
   (ANSI stripped). Failing ids = F2P candidates.
4. Apply `src`; rerun; F2P = failed-then-passed, P2P = passed-both, in the
   touched modules only. Zero F2P → cull ("feature, not fix" or flaky).
5. Emit `Task(workspace: GitTree(repo, c^, tree(c^), prepare: ["gleam",
   "deps", "download"]), verifier: Program(files: tests-diff-as-files,
   argv: ["bash","scripts/test.sh",pkg,"--match",module], …))`, prompt =
   commit subject + body with the test names removed (grep for every F2P
   function name and the test file basename; if the body names them, drop
   the body and keep the subject only, tagged `prompt:subject-only`).

P2P is **the touched test modules**, not the whole package: `client`'s full
suite is 630 s and would make every verifier run cost more than the agent.
Record the choice in the task's `side_info` so a reader knows a client
task's P2P is narrow. Wave-1 mining targets `machine`, `core`, `prompt`,
`provider`, `storage`, `lint` (seconds each; 95 candidates in the list);
`client`/`tui`/`session_view` (459 candidates) wait for a measured
per-module verifier cost.

**The hidden-verifier guarantee, mechanically.** Order is fixed and tested:
(a) the trial instance is closed and `retirement.perform` has returned `Ok`
(`rollout.gleam:408`) — the agent's processes are gone; (b) the workspace
directory is **copied** to `<root>/verify` (so a verifier can never mutate the
evidence directory, and the raw workspace stays for the artifact);
(c) `Verifier.Program.files` are written into the copy; (d) `argv` is cleared
through `tool.broker_runner(broker)` (`tools/tool.gleam:1222`) of the
*evaluating* session, under `serve.evolution_trial_policy(base, trials,
verify_dir)` (`serve.gleam:7994-8010`: readable/writable roots = that
directory only, scratch tmpfs, network as the base says). This is
`client/goalcheck`'s arrangement (`goalcheck.gleam:1-25`: operator-authored
is not exempt from Rule Zero) and nanocodex's join-then-stage (`670ebd961`,
`2fb5b258e`). The agent never has the test files in its tree, and the
verifier never runs in the harness VM.

**Never edit a task.** Enforced by construction: `id` is the digest of the
canonical bytes; the ledger pairs rows by `(plan_id, task_id, arm_id,
trial_index)`; a task file whose recomputed digest differs from its
filename is refused at load (`eval/task.load`), as `tasks.load` already does
(`tasks.gleam:116-119`) and nanocodex's `validate_package` (`task.rs@P:408`).
"Fixing" a task is minting a new id and retiring the old one from the plan.

**Mutation testing of verifiers (step 2).** `eval mine --prove` runs, per
task, three jailed verifier runs: gold (src patch applied) must score 1;
null (no patch) must score 0; and a **sabotaged** gold (the first non-blank
changed line of the src patch reverted) should score 0 — the third is a
census, not a gate, because some fixes are one line. A task is admitted to a
set only with gold=1 and null=0 recorded in its provenance.

**Cost.** A `GitTree` task costs a worktree, `gleam deps download` and a
warm `gleam build` *before* the agent starts (the cold-start time, §8); for
`client` that is ~240 s. The prepare runs on the host because it is the
repo's own build at a trusted commit (what CI runs), and it is what makes the
agent's jailed `gleam test` work with network off — the jail must see
`build/` warm and the toolchain mounts code mode already discovers
(`client/codemode.toolchain_mounts`).

**Cheapest falsifier:** inside one real trial (`make e2e-evolution`
posture), have the scripted model call `bash` with
`bash scripts/test.sh machine --match failure_test` on a prepared worktree
with network off. If it fails for a missing `gleam`/`erl`/hex package, the
toolchain-mount story is wrong and wave 1 ends with that finding instead of
tasks.

## 4. Arms, model variation, ensembles (Q4)

**Ruling.** An arm is an optimize_anything candidate: a map of named text
components plus the non-text knobs that select models, keyed so that a
GEPA step mutates components and never the knobs.

```gleam
/// eval/arm.gleam — pure.
pub type Arm {
  Arm(
    /// sha256 of canonical components + knobs; the pairing key.
    id: String,
    name: String,
    /// optimize_anything's `dict[str, str]`. Keys are fixed by `Component`.
    components: List(#(Component, String)),
    /// Not mutable by an optimizer.
    knobs: Knobs,
  )
}

pub type Component {
  /// `provider/profile.system_suffix` for the exact target.
  SystemSuffix(target: Target)
  /// `profile.task_prefix`.
  TaskPrefix(target: Target)
  /// `profile.descriptions[name]`; mcp_adapter's `tool_description_{name}`.
  ToolDescription(target: Target, tool: String)
  /// Whole pack text handed through `LOOM_PROMPT_PACK` (`system_prompt.gleam:156`).
  PromptPack
}

/// The exact-model key today; `role` is `Any` until protocol-change 101.
pub type Target { Target(provider: String, model_id: String, api: String, role: Role) }
pub type Role { Any  Main  Subagent  Advisor  Summarize }

pub type Knobs {
  Knobs(
    /// `[roles]` rows: role → catalogue model names, the ensemble axis.
    roles: List(#(model.Role, List(String))),
    thinking: List(#(String, model.ThinkingLevel)),
    /// Tool names withheld (`LOOM_DISABLE_TOOLS` posture).
    disabled_tools: List(String),
  )
}
```

`eval/arm.to_settings(arm, base: Settings) -> Result(Settings, String)`
renders the components into `provider/profile.new` values (one `Profile` per
distinct `Target` with `role: Any`), builds the profile map via
`gateway.with_profiles` (`provider/gateway.gleam:558`), writes the pack to a per-arm
file, and overrides `catalog.roles`. A component whose `Target.role` is not
`Any` is **refused** with "per-role profiles need protocol-change 101" — so
the axis exists in the data and step 7 can emit it, but nothing lies about
applying it.

**Agent role in Loom, for the record:** the primary strand (`main`),
Agency children (`sub:{parent}/{slug}-{digest}`, `agency.child_name`), the
advisor strand (`advisor`, `client/advisor.ensure_strand`) and the
`summarize`/`vision` routes. Per-role profile selection would need the strand
or role at `compose_profile` (`provider/gateway.gleam:2227`) and a 9th field in
`prompt.encode_profile` (`evolution/prompt.gleam:118-137`), hence a persisted-format
bump and protocol-change 101. Deferred.

**`profile.apply` stays append-only.** A replace mode is a different trust
boundary: 068 promised "Description changes affect prose only … registered
names, schemas … remain authoritative" and a replace lets a profile *remove*
the sentence that tells the model a tool is dangerous. For the instrument,
replacement is unnecessary: an arm that wants a different base description
is an arm with a different `PromptPack`/tool build, i.e. a different Loom
build, which is a **harness arm** (binary digest in `Knobs`, see §8), not a
profile. If step 7 later shows appended prose cannot express what wins, that
is protocol-change material with evidence behind it.

**Smallest first slice:** per-session arms only (`to_settings`), with
`PromptPack`, `SystemSuffix`, `TaskPrefix`, `ToolDescription` and `roles`
live; `Role ≠ Any` refused.

**Cheapest falsifier:** build two arms differing only in `roles.subagent`
and run one task that spawns a child; the child's `AgentMessage.model`
(`core/message.gleam:150`) must differ between arms and the parent's must
not. If both differ, the knob leaked into the main route.

## 5. Statistics (Q5)

All in `packages/evalstat`, pure, every function total, every randomised
test on a fixed named seed (`docs/gleam-style.md` Part III). Inputs are
plain data:

```gleam
/// evalstat/cell.gleam
pub type Trial { Trial(task: String, arm: String, index: Int, reward: Float,
  scores: List(#(String, Float)), outcome: Outcome, cost: Cost) }
pub type Outcome { Passed  VerifierFailed  AgentTimeout  SafetyRefusal  Infrastructure }
pub type Cost { Cost(tokens: Int, dollars: Float, turns: Int, tool_errors: Int, wall_ms: Int) }
```

**Estimators and tests (exact forms the implementer uses):**

- Per task *t*, arm *a*, with *n_t* trials and *c_t* passes:
  `p̂_ta = c_t / n_t`. Infrastructure rows are **excluded from n** and counted
  separately; `AgentTimeout` and `SafetyRefusal` **are failures** (nanocodex
  `16ac24599` is the anti-pattern; requeue-forever removes the hardest
  tasks from the denominator).
- Paired per-task difference `d_t = p̂_tB − p̂_tA`; mean `d̄`;
  `SE_paired = sqrt( Σ_t (d_t − d̄)² / (T(T−1)) )` (Miller 2024 §4; this is
  the clustered form with the task as the cluster, which is the right
  cluster when trials nest in tasks). Report `d̄ ± 1.96·SE_paired`.
- **Exact McNemar / sign test** on discordant *task-trial pairs*
  `(task, index)`: `b` = A pass & B fail, `c` = A fail & B pass;
  two-sided `p = 2·min( P[X ≤ min(b,c)], 0.5 )` with `X ~ Binomial(b+c, ½)`,
  computed with exact log-binomials (no normal approximation; `b+c` is tens).
- **Bootstrap over tasks, trials nested:** `B = 2000` resamples; each draws
  *T* tasks with replacement, and within each drawn task draws *n_t* trial
  indices with replacement **using the same indices for both arms** (keeps
  the pairing); percentile 2.5/97.5 of `d̄*`. PRNG: xorshift64* in pure
  Gleam, seeded by the plan id so a report is reproducible.
- **pass@k** (unbiased, Chen et al.): `1 − C(n−c, k)/C(n, k)`;
  **pass^k** (τ-bench reliability): `C(c, k)/C(n, k)`; both per task then
  averaged; both require `n ≥ k` and refuse otherwise (`Error`, never 0).
- **MDE** at α=0.05, power 0.8: `δ_min = (1.96 + 0.84)·SE_paired`, reported
  beside every comparison. With T=30 tasks and K=3 the honest number is in
  the 15–25-point range; the report prints it in the first line so nobody
  reads a 4-point win as a result (Miller: ~969 questions for 3 points).
- **Variance decomposition** (which budget to spend next):
  `Var(d̄) = [ (1/T)·Var_t(E[d|t]) ] + [ (1/T)·E_t( Var(d|t)/n_t ) ]`; the
  report says whether more tasks or more trials shrinks it faster.
- **Score vector and dominance.** `scores` is Harbor's `reward.json` map,
  all oriented higher-is-better (`cost_inv = 1/(1+dollars)`,
  `turns_inv`, `tool_errors_inv`). Outcome is first and lexical: an arm
  whose outcome CI excludes zero in the harmful direction is `Dominated`
  whatever its cost. Among arms not harmful on outcome, Pareto dominance on
  the vector; ties report `Indistinguishable`. A cheaper arm that is
  cheaper by *abandoning work* is caught because abandoned work fails the
  verifier (#807 workflow 4 is satisfied by the verifier, not by a cost
  rule).

**Decision rule** (`evalstat.paired_verdict`):

```gleam
pub type Verdict {
  Improved(effect: Float, ci: #(Float, Float), p: Float, mde: Float)
  Harmed(effect: Float, ci: #(Float, Float), p: Float, mde: Float)
  Indistinguishable(effect: Float, ci: #(Float, Float), p: Float, mde: Float)
  Underpowered(mde: Float, needed_tasks: Int)
  Incomplete(reason: String)
}
```

`Improved` requires `p < α` **and** CI excluding zero **and** `d̄ ≥ mde/2`
— the last so a "significant" 2-point win from a lucky design is reported as
`Indistinguishable`, which is what it is. Governed `rollout.verdict` maps
`Improved → Passed`, `Harmed | Indistinguishable → Failed`, the rest →
`Inconclusive(reason)`: the governed plane promotes only a demonstrated
improvement, and "not worse" is not enough to spend a selection on.

**Sequential stopping, compatible with P3.** Fixed `K` per cell declared in
the plan, with one deterministic early stop: after each completed task-pair
round, if the sign test's `p` cannot fall below α even if every remaining
pair is discordant in the favoured direction, stop and report
`Indistinguishable`/`Underpowered` (a futility bound that only ever
*under*-claims); and if every remaining pair going the other way could not
raise `p` above α, stop with the verdict. No optional stopping on "looks
good"; no mid-run `K` increase except by a new plan id. This is simple,
valid, and costs at most one wasted round.

**Mutation proofs (one per invariant family, named tests in
`evalstat/test/`):**

- `mcnemar_exact_matches_binomial_table_test`: five hand-computed (b,c)
  pairs from a statistics table.
- `pass_at_k_unbiased_vs_bruteforce_test`: qcheck over `(n ≤ 8, c, k)`,
  brute-force enumeration of subsets equals the closed form; mutate the
  formula to the biased `1−(1−c/n)^k` and the property fails.
- `bootstrap_keeps_pairing_test`: duplicating every task's trials in both
  arms leaves the CI centre fixed; breaking pairing (independent index
  draws) widens the CI — assert the ratio.
- `paired_se_is_clustered_test`: tasks with constant within-task outcomes
  give `SE_paired` equal to the between-task formula; shuffling trials
  across tasks changes it.
- `verdict_never_improves_under_aa_test`: qcheck, both arms drawn from one
  Bernoulli(p) per task on a fixed seed over 500 plans; `Improved` rate
  ≤ 0.06 (the A/A requirement, provable here without a model).
- `verdict_flags_planted_degradation_test`: arm B is arm A with
  `p − 0.3` on every task, T=30, K=3 → `Harmed` on ≥ 95 % of seeds.
- `timeouts_are_failures_not_excluded_test`.

These two last tests *are* the first two external acceptance criteria,
proven at the decision-rule layer now and re-run on live data later (§11).

**Cheapest falsifier of the whole section:** the A/A property at 0.06. If
the rule cannot hold α on synthetic data it will not hold it on a model.

## 6. Splits and the seal (Q6)

**Ruling.** Three splits, assigned by a deterministic hash, sealed by
*where the ids may be admitted*, not by a password.

- `split(task_id, salt) = sha256(salt <> task_id)` → first byte mod 10:
  0–5 `Tune` (GEPA's `D_feedback`), 6–7 `Validate` (`D_pareto`), 8–9
  `Holdout`. The salt is the plan's; one salt per **task family** so a
  mined commit and its sibling from the same file land in the same split
  (family = `packages/<pkg>/<first touched src module>`), which is the
  clustering that prevents a leaked near-duplicate.
- The seal: `evolution.compare` can name only a task set admitted into the
  *source session* by `admit_tasks` (`tasks.load`, `tasks.gleam:95-120`;
  `serve.evolution_compare`, `serve.gleam:7981-7804`). The instrument's
  `eval admit --split tune|validate` writes a v2 task set through the same
  operator door; `eval admit --split holdout` **does not exist** — the
  command refuses, and a lint-style test in `eval` asserts no holdout id
  ever appears in a `prompt/evolution-taskset/*` fact of any session under
  the state dir. Holdout runs happen only through `eval run --holdout`,
  which writes its own ledger and never admits. That is the mechanical
  version of "a holdout split `compare` cannot name": the model door has
  no way to spell it.
- Reporting: every report carries `tune`, `validate` and `holdout` panels
  and the **gap** `d̄_validate − d̄_holdout` with its own paired CI; a
  positive gap beyond its CI is printed as "memorised".
- Holdout vs production: `eval production --since <date>` reads reserved
  facts `prompt/evolution-outcome/<entry_id>` (`evolution/trace.gleam:490-515`) from
  *copies* of production session databases (writer lease, storage
  CLAUDE.md), joins each to the profile id journaled in
  `evolution/attempt/<hex>` facts (`serve.evolution_attempt`,
  `serve.gleam:7585-7618`), and reports marked-success rate per profile
  beside the holdout pass rate of the same profile id. `Unmarked` is
  **excluded** from the rate and counted in a visible `unmarked` column
  (answering #236's open question: neutral would reward profiles that make
  operators not bother to mark).

**Cost:** a holdout needs its own live spend and is never reused for
tuning; with 30 % of ~60 tasks it is 18 tasks and its MDE is large — the
report says so rather than hiding it. Re-salting is a new plan and is logged.

**Cheapest falsifier:** try `eval admit --split holdout` and try to name a
holdout id in a `cap/evolution.compare` call from a code-mode program; both
must refuse with the words "holdout".

## 7. Lanes (Q7)

**Ruling.** Two lanes, two different claims, one transport seam.

**Replay lane (harness/tool regressions).** `eval/cassette.gleam`
implements `provider/http.Transport` (`provider/http.gleam:145-151`) twice:
`recording(inner, sink)` tees every `HttpEvent` with the request's
*ordinal* and a **semantic digest**; `replaying(tape)` answers the *n*-th
request of a `(task, arm, trial)` with the recorded events **after
comparing the semantic digest**. A mismatch is not an error to paper over —
it is the lane's finding: "request 4 of task X diverged: system prompt
digest changed" with a redacted diff summary. The digest is
`prompt.fingerprint(system, tools)` (`evolution/prompt.gleam:248-272`) plus a
digest of the message list with these normalised: absolute paths under
the trial root → `<root>`, ISO dates → `<date>`, tool-use ids kept (they
come from the tape, so they recur). Determinism needs: `Settings` with a
`clock.stepping` clock, a fixed trial tag (today minted from
`token.production_entropy()` at `serve.gleam:7784`, so `trial_settings`
takes the tag as a parameter — part of the §2 extraction), and the agent's
tools running against a workspace prepared identically (the tree id
guarantees it). What the lane may claim: *the harness produced the same
requests and the verifier gave the same reward under the same model
outputs*. It may not claim anything about model quality and the report
header says so. It is what CI can run with no key.

**Live lane (model/prompt quality).** Real transport, real spend. Budget
defaults per plan: `max_requests_per_trial = 40`, derived guard allowance
per trial `40 × (3·context + output)` tokens and the priced equivalent;
run-level cap in dollars enforced on *measured* usage between trials
(P3); per-cell wall `20 min`; concurrency 2 trials (helper pool 2 per trial,
`serve.gleam:7929`). Quick profile: 8 tasks × K=1 × 2 arms (a smoke, no
verdict printed, only `Underpowered`); full: all tune+validate × K=3.

**Cut list:** no cassette for the scripted test-support providers (they
are already deterministic); no attempt to make replay byte-exact; no
replay of the verifier (it reruns for real, in the jail — it is cheap and it
is the thing being regression-tested).

**Cheapest falsifier:** record one task with the scripted loopback
provider from `evolution_prompt_acceptance_test`, replay it twice; the two
replays must produce identical ledger rows except `wall_ms`, and a
one-word change to the default pack must make the replay report a
divergence at request 1.

## 8. Run artifacts (Q8)

Location: `<state>/eval/runs/<plan_id>/` by default (`--out` overrides),
git-ignored; never under `/tmp`; never inside a workspace. One run:

- `plan.json` — the frozen pre-materialised plan (nanocodex `add`): every
  `(task_id, arm_id, trial_index)` row, task-set ids, split salt, budgets,
  lane, `harness: {git_commit, loomd_sha256 | "dev-tree:<dirty>"}` — a
  dirty tree is allowed in quick runs and **refused** in full runs
  (`harbor-comparisons/README.md@P:24-25`: a mutable local binary is
  ineligible for comparison).
- `trials.jsonl` — append-only, one row per attempt:

```json
{"v":2,"plan":"…","task":"…","arm":"…","index":0,"attempt":1,
 "state":"scored|infra|running",
 "outcome":"passed|verifier_failed|agent_timeout|safety_refusal|infrastructure",
 "reward":1.0,"scores":{"f2p":1.0,"p2p":1.0,"cost_inv":0.71},
 "side_info":"…≤ 8 KiB verifier tail…",
 "served":[{"provider":"…","model":"…","api":"…","profile":"…|null","digest":"…"}],
 "usage":{"input":…,"output":…,"cache_read":…,"cache_write":…,"dollars":…,"completeness":"complete|lower_bound"},
 "turns":7,"tool_calls":19,"tool_errors":2,"compactions":0,
 "timing_ms":{"prepare":241000,"agent":318000,"verifier":4200,"retire":900},
 "jail":{"posture":"bwrap-userns|seatbelt|none","selftest":"…"},
 "artifacts":{"session_db":"…","workspace":"…","trajectory":"…","verifier_stdout":"…"}}
```

  `attempt` and `state: infra` give nanocodex's append-only attempt history
  without a ledger process: an infra row is followed by a retry row with
  `attempt+1`, bounded at 3; `agent_timeout` is terminal. The pair key is
  `(plan, task, arm, index)`.
- Per trial directory: `session.db` (copied after close), `workspace/`
  (the frozen agent tree, before the verifier copy), `verifier/` (stdout,
  stderr, `reward.json`), `trajectory.json` (ATIF-v1.7, §10),
  `requests.jsonl` on the live lane (the cassette tape doubles as the API
  exchange log, scrubbed with `trace.scrub_excerpt`, `evolution/trace.gleam:464`).
- `report.json` + `report.md` — the `evalstat` verdict, MDE first line,
  panels per split, variance decomposition, Pareto table, and the list of
  trial rows the verdict used.

Cold start is `timing_ms.prepare` per trial and also summed at run level
(`cold_total_ms`), separate from `agent` (nanocodex
`AggregateRunTiming.cold_image_and_cache_ns`).

`composition digests` come from `gateway.with_profiles`' observer, which is
a no-op in trials today (`rollout_host.gleam:137-139`); the instrument
passes a real observer that appends to the row's `served` list.

**Cheapest falsifier:** `eval report` over a `trials.jsonl` with one row
deleted must refuse with "plan row missing" — the plan, not the ledger, is
the denominator.

## 9. Failure taxonomy (Q9)

**Ruling.** A document first, produced by a tool, labelled by people.

- `eval transcripts --state <dir> --since <date> --out <dir>` opens *copies*
  of session databases (`session.open_sqlite` takes a writer lease;
  `client_dev.gleam:15-17` carries the same warning), walks
  `storage.scan_entries` (`storage.gleam:365`) and `storage.scan_usage` (`storage.gleam:402`), and
  writes one JSONL per session with: user/assistant text through
  `trace.scrub_excerpt` (`evolution/trace.gleam:464`; thinking and images excluded
  as `trace.select` does, the trace section of `docs/architecture/evolution.md`), tool calls (name +
  argument *keys* + a 256-byte scrubbed argument digest preview), tool
  results (`is_error`, 512-byte scrubbed tail), compactions, usage rows,
  and any `prompt/evolution-outcome/*` mark. The scrubber's limits
  (`evolution.md:320-323`) are printed in the file header; the export is
  for the owner's eyes and is **not** committed.
- Labelling: the owner and an Opus reviewer label a stratified sample
  (≥ 40 sessions, stratified by model id and by marked outcome) with one
  primary category each. Starting vocabulary (to be replaced by what the
  data says): `wrong-tool-shape`, `refusal-loop`, `context-overflow`,
  `gave-up-early`, `wrong-test-run`, `edited-without-reading`,
  `hallucinated-api`, `jail-misread`, `verifier-irrelevant`.
- Output: `docs/review/eval-failure-taxonomy-2026-10.md` (a review-wave
  file, the existing convention), with counts, two scrubbed exemplars per
  category, and a **selection quota**: each category with ≥ 5 % of failures
  must have ≥ 3 tasks tagged with it in the tune split before hand-written
  tasks are written. Tags live in `Task.tags`; `eval report` prints pass
  rate per tag so a prompt change that fixes `refusal-loop` and breaks
  `wrong-test-run` is visible.

This is code (the export) plus a document (the taxonomy); the quota is
data in the plan. It does not become a lint.

## 10. #492: `loom run` and ATIF (Q10)

**Ruling.** The ATIF exporter is in this wave; `loom run -p` is **designed
for but not built** in waves 1–3.

- `eval/atif.gleam` is a pure walk `List(entry.Entry) -> Trajectory`
  (steps 1-based; `source` = system/user/agent; `tool_calls` from
  `AssistantToolCall`; `observation.results` from `ToolResultMessage`;
  `metrics` from the usage rows; `agent.model_name` from the entry's own
  `model`). It is cheap, it is what Harbor export needs, and it is the
  same walk `transcripts` uses. Validate with Harbor's
  `python -m harbor.utils.trajectory_validator` once, by hand, in the
  review.
- `eval harbor-export --set <id> --out <dir>` writes `instruction.md`,
  `task.toml` (schema 1.3, `[verifier] timeout_sec`,
  `environment_mode = "separate"`), `environment/Dockerfile` (FROM a pinned
  Loom builder image, `git checkout <commit>`, `gleam deps download`,
  `gleam build`), `tests/test.sh` (runs the verifier argv and writes
  `/logs/verifier/reward.json` with `f2p`/`p2p`), `solution/solve.sh` (the
  gold patch). This makes "Terminal-Bench ranks models like public
  leaderboards" a one-directional export today.
- `loom run -p PROMPT -m provider/model` is a ~150-line CLI over
  `eval/trial.run_one(settings, task_prompt, arm) -> TrialRow`, the same
  function the runner calls per cell. The runner is built first so that
  the CLI is a wrapper, not a second runtime path. Its own issue (#492)
  stays open with a comment pointing at `eval/trial`.
- The Harbor **agent adapter** (Python `BaseInstalledAgent` installing the
  release into the task container) is operator-side work after `loom run`
  exists; it is the one Python artifact and lives under
  `scripts/harbor/` when it comes.

## 11. External acceptance: what runs here, what runs later (Q11)

| Experiment | Here (no keys) | Operator later |
|---|---|---|
| A/A shows no significant difference | **Yes, at the decision-rule layer**: `verdict_never_improves_under_aa_test` (synthetic Bernoulli, 500 seeded plans, rate ≤ 0.06) and a replay-lane A/A (same tape, two arm ids) that must print `Indistinguishable` with effect 0 | `eval run plans/aa-sonnet.toml` (same arm twice, 30 tasks, K=3, ~\$40): verdict must not be `Improved`/`Harmed`; repeat 3 plans |
| Planted degradation flagged worse | **Yes**: `verdict_flags_planted_degradation_test`; plus a replay-lane run where arm B's pack deletes the "run the tests before answering" section — the divergence report fires (that proves the lane, not the model) | `plans/degrade.toml`: arm B appends "Do not run any tests; answer from reading alone." as `TaskPrefix`; expect `Harmed` |
| Terminal-Bench subset ranks like leaderboards | **No** (needs keys, Docker and the Harbor adapter) | After `loom run`: 20 TB-2 tasks × 3 models via Harbor; Spearman ρ against the public board ≥ 0.8 |
| Holdout predicts production `mark_outcome` | **Protocol only** (§6): `eval production` is written and tested against a fixture db with planted marks | Run after the first governed selection; report both rates and the unmarked column for 2 weeks of sessions |

What the scripted/replay lane honestly proves now: the lifecycle (as
`make e2e-evolution` already does, `evolution.md:470-477`), the verifier
isolation ordering, the ledger/plan invariants, the statistics, and
request-level harness regressions. It proves nothing about any model and the
report says so in its header, matching the repo's own position
(`evolution.md:313-316`).

## 12. Docs and decisions (Q12)

- **ADR-021 "Evaluation instrument beside governed evolution"**: the
  separation (instrument produces, governed plane consumes); pure stats
  held to R6; verifier after freeze in a fresh jail; content-addressed tasks
  with `GitTree`; splits and the seal by admission; two lanes and their
  claims; timeouts count as failures; what is deliberately not built
  (optimizer, per-role profiles, replace-mode descriptions, SQLite ledger,
  LLM-judged tasks). Consequences: every promotion is run twice; holdout
  spend is never reused.
- **protocol-change/100 "Task set v2 and sampled rollout evidence"**: 068
  lists `admit_tasks` among the commands whose payloads are recorded
  (068 "Interface impact"), and `tasks.decode` accepts only `version: 1`
  (`tasks.gleam:137-139`). v2 adds `workspace`/`verifier` sum types and the
  `grade` member in the `IndependentRollout` observation; `Limits.samples`
  and the `evalstat` verdict semantics are recorded there too, with the
  v1 → v2 decoder keeping v1 payloads valid.
- **protocol-change/101 (not in this wave; reserve the number)**: per-role
  profile key.
- **`docs/architecture/evaluation.md`**: the instrument's page; the
  `evolution.md` "Model evaluation and traces" section gains two
  paragraphs pointing at it and at the sampled verdict.
- `docs/next.md`: rewritten at the end of wave 1 with the measured
  per-package verifier costs and the toolchain-in-jail finding.
- Issue comments: #236 (the trace note's phases 1–2 are now the
  instrument; outcome absent = excluded; per exact id; overlay seam stays
  in `provider/profile`), #807 (workflow 4 mapping, two-run cost), #492
  (`eval/trial` is the headless runner; `loom run` is a wrapper; ATIF
  exists).

## 13. Wave plan (Q13)

Sub-agents share one tree; every slice names owner files and no-touch
files. Standard of proof everywhere: `make check-<pkg>` with the exit code
captured, `gleam format --check`, `make lint` (R10/R11/R13/R21/R22 gate), the
named mutation tests, `make doc-check`. Never `git checkout <file>`.

### Wave 1 — mergeable alone, useful alone (stats, task format, miner, seam)

| Slice | Owner files | No-touch | Cut list | Proof | Who |
|---|---|---|---|---|---|
| **1A `evalstat`** (hardest math) | `packages/evalstat/**`, `lint/portable.gleam` (add the name), `Makefile:6`, `scripts/check.sh` line 7, `scripts/test.sh:7` | everything in `client`, `eval` | no plotting, no CSV, no t-distribution tables beyond z, no Bayesian variant | the seven mutation tests in §5, `make check-evalstat`, R6 clean | **Fable** writes; Opus reviews mandatory |
| **1B `eval` task/plan/ledger codecs** | `packages/eval/src/eval/{task,arm,plan,ledger,split}.gleam`, `packages/eval/gleam.toml`, `CLAUDE.md`/`AGENTS.md` | `rollout*.gleam`, `serve.gleam`, `evalstat` | no runner, no SQLite, no CLI beyond `eval validate <file>` | total-decoder round trips; `task_id_changes_on_any_edit_test`; `holdout_admit_is_refused_test`; `plan_rows_are_the_denominator_test` | Sonnet |
| **1C miner** | `packages/eval/src/eval/{mine,eunit_ids,git}.gleam`, `packages/eval/test/eval/mine_test.gleam` | 1B's files (consume its types as published; agree the `Task` constructor in the brief) | no SWE-smith synthesis, no client/tui mining yet, no prompt rewriting by a model | reproduce the `eccdddad0` probe end-to-end (F2P = the two ids, P2P = 77); a feature commit with no F2P is culled; a fixture with ANSI-coloured EUnit output parses | Sonnet |
| **1D client seam** | `serve.gleam` (extract `trial_settings`, tag parameter), `rollout.gleam` (`Grade`, `Limits.samples`), `rollout_host.gleam`, `fixture.gleam` (adapter), `model_door.gleam` (samples cap), `evolution/models_test.gleam`, `evolution_prompt_acceptance_test.gleam` | everything else | no verdict change yet (that is 2C), no verifier yet | `make check-client` green; acceptance observation unchanged except `grade`; `samples: 2` doubles `reports` | **Fable** (8,151-line `serve.gleam`; Opus review) |

1A–1D touch disjoint files; 1B and 1C are in one package but different
modules and the brief fixes the `Task` constructor up front.

### Wave 2 — the instrument runs (runner, verifier, governed verdict, cassette)

| Slice | Owner files | Cut list | Proof | Who |
|---|---|---|---|---|
| **2A runner** `eval/{run,trial,budget,cli}.gleam`, `Makefile` `eval` target | no dashboards; quick/full only; concurrency fixed at 2 | scripted-provider run over 2 inline tasks × 2 arms × K=2 writes 8 rows + report; a killed trial becomes `infra` then a retry row; measured-spend cap stops admission (test with a priced fixture card as the priced fixture card in the governed acceptance test) | Sonnet, Opus review |
| **2B jailed verifier** `eval/verify.gleam`, `eval/prove.gleam` (hardest isolation) | no LLM judge; no host-side fallback when the jail is absent (refuse, print the selftest line) | ordering test: verifier files absent from `workspace/` and present in `verify/`; verifier cannot write outside `verify/`; `prove` on the `eccdddad0` task yields gold=1, null=0 inside a real jail (`make e2e-evolution` posture) | **Fable** |
| **2C governed verdict** `rollout.gleam` (`verdict` → `evalstat`), `record.gleam` (observation `grade`), `protocol-change/100.md`, `evolution/models_test.gleam` | no new door, no ceilings raised | synthetic reports: A/A → `Inconclusive(underpowered)`, planted harm → `Failed`, baseline-fails-candidate-passes → `Passed`; old asymmetric case (candidate fails once) no longer decides alone | **Fable**, Opus review mandatory |
| **2D cassette** `eval/cassette.gleam`, `eval/normalise.gleam` | no byte-exact replay; no live-lane claims | record/replay twice identical rows; one-word pack change → divergence at request 1; tape scrubbed (planted `sk-` token absent) | Sonnet, Opus review |

### Wave 3 — splits, exports, taxonomy, docs

| Slice | Owner files | Proof | Who |
|---|---|---|---|
| **3A seal + production join** `eval/{split,production}.gleam`, `eval admit` | holdout ids never in any `prompt/evolution-taskset/*` fact (test over a fixture state dir); production join on a fixture db with planted marks and attempts | Sonnet |
| **3B ATIF + Harbor export** `eval/{atif,harbor}.gleam` | ATIF step ids contiguous; tool results joined by `source_call_id`; a run validated once by the Harbor validator by hand | Sonnet |
| **3C transcripts + taxonomy** `eval/transcripts.gleam`, `docs/review/eval-failure-taxonomy-2026-10.md` | scrub test with planted secrets; the document with quotas | Sonnet exports; owner + Opus label |
| **3D docs** ADR-021, `docs/architecture/evaluation.md`, `evolution.md` paragraphs, `docs/next.md`, issue comments | `make doc-check` | Sonnet drafts, Fable edits |

### Wave 4 — operator-run and #492 (after keys)

A/A and planted-degradation live plans; two weeks of holdout→production;
`loom run -p` over `eval/trial`; the Harbor agent adapter; the first
client/tui mined tasks once per-module verifier cost is measured; then,
and only then, `eval/optimize.gleam` (step 7) as a loop over
`eval/trial.run_one` with `Arm.components` as the candidate dict,
`Grade.side_info` as ASI and `evalstat` on the `Validate` split for
acceptance — no new abstraction.

### Estimates

Wave 1 ≈ 3–4 agent-days wall (1A and 1D are the long poles); wave 2 ≈ 4
days (2B's jail work is the risk); wave 3 ≈ 2 days. The toolchain-in-jail
falsifier (§3) runs in wave 1 before 2B is briefed; if it fails, wave 2
starts with a `codemode.toolchain_mounts` slice instead of 2D.

## 14. The whole cut list, in one place

Not built in waves 1–3: the GEPA loop; per-role profiles (protocol-change
101); replace-mode descriptions; a SQLite ledger or coordinator process;
LLM-judged tasks; SWE-smith bug synthesis; byte-exact replay; a web
dashboard; `loom run`; the Harbor Python adapter; mining of `client`,
`tui`, `session_view` until the per-module verifier cost is measured;
raising any model-door ceiling; a second evidence authority.

## 15. Amendments from review

Independent reviews of each slice changed four rulings above. The code is
the authority; this section says where the note no longer describes it.

- **§5, the significance test.** The verdict's sign test runs on the sign
  of each task's paired difference, not on discordant trial pairs. The
  pair-level test was two-sided with no check of direction, so one heavily
  sampled task could carry a verdict its p-value pointed against. Effect,
  interval and task signs must now agree in direction. Pair-level McNemar
  counts are still reported.
- **§5, power.** A design with no between-task spread is `Underpowered`
  with a reason (the constructor gained a `reason` field), and its
  detectable effect comes from the binomial floor. A standard error of zero
  is not evidence of power.
- **§5, the bootstrap and stopping.** The bootstrap resamples whole tasks;
  the nested form counted within-task noise twice. Sequential futility can
  only stop a run as undecided (`StopUndecided`); there is no early stop
  with a verdict, because a stop that settles the sign test can still be
  contradicted by the interval.
- **§3, the verifier boundary.** The agent controls every byte of its
  frozen tree, so the verify copy keeps only regular files and
  directories, discards the agent's `logs/` and `build/`, and takes its
  dependency build from a pristine host-side preparation the agent never
  saw. A pass requires exit status zero, every fail-to-pass and
  pass-to-pass id observed passing, and the reward map; runner scripts are
  always hidden files. Code an F2P test reaches still runs in the test VM
  and could print forged EUnit lines; the defence is the hidden test
  bodies and the pristine build, not output parsing.
- **§7, the replay lane.** Tapes store response bodies verbatim and match
  requests by digest, not ordinal, so concurrent strands replay the same
  way; redaction is limited to the request's own credentials and known
  credential prefixes, and a recording redaction changed is refused at
  replay rather than served.
