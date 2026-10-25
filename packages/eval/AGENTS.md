# eval

## Purpose

The evaluation instrument (ADR-021, issue #236): a developer tool that runs
a coding agent on versioned, content-addressed tasks under two or more arms
(prompt profile components, tool descriptions, model roles), grades each
trial with a hidden verifier run in a fresh jail after the agent is gone,
and reports a paired verdict through `evalstat`. It never ships in a
release and never promotes anything: the governed evolution plane in
`client/evolution` stays the only route from a candidate to a selection.

## Dependencies

`client` (the trial recipe and the jail), `evalstat` (statistics),
`provider`, `storage`, `session`, `runtime`, `tools`, `prompt`, `core`,
`weft` for process machinery, `simplifile` and `argv`. Like
`conformance`, it depends on `client` and is depended on by nothing.

## Codecs: task, arm, plan, ledger, split

Pure, total, content-addressed. Every file has `"v": 2`, rejects unknown
keys, and is decoded through `eval/wire` (object/field helpers shared by all
five). Canonical encoding is `core/json.canonical`; file sets are objects
keyed by path and decode sorted by path.

### Key types

- `task.Task` (types are the shared contract with the miner; do not change
  shapes): `id` is `client/mcp.sha256_hex` of the canonical encoding with
  `id` blank. `mint`, `verify_id`, `decode`, `to_json`, `load`. `load` also
  refuses a file not named `<id>.json`.
- `arm.Arm` / `Component` / `Target` / `Role` / `Knobs`: `Knobs.roles` and
  `thinking` use `provider/model.Role` and `ThinkingLevel`; `arm.Role`
  (`Any Main Subagent Advisor Summarize`) is the target role. The id hashes
  components and knobs only, never the name, and the keyed lists are sorted
  by key so build order is not identity. `refuse_unapplied` refuses any
  `Target.role != Any`.
- `split.Split` (`Tune Validate Holdout`), `assign(salt, family)`,
  `family(task)` (the first `family:<value>` tag, else the task id),
  `admissible` (refuses Holdout, message contains "holdout").
- `plan.Plan`: id, task/arm ids, K, `Lane`, `Profile`, salt, `Budgets`,
  `Harness` (commit + `Clean|Dirty`). `check` refuses a Full plan with a
  Dirty tree; `rows` is the denominator (task-major).
- `ledger.Row`: one attempt. `RowState` and `outcome` are tied (Running has
  none, Infra is Infrastructure, Scored is one of the four graded).
  `reconcile(plan, rows)` returns the latest attempt per cell or
  `plan row missing: <task>/<arm>/<index>`; strays are refused.

### Invariants

- Attempts are 1..3; `Infra` is terminal only at attempt 3; a `Running` row
  never ends a cell. `reconcile` checks each cell's rows in file order:
  attempt 1 first, k+1 only after `Infra` at k, nothing after `Scored`
  (`cell rerolled`), no duplicate or skipped attempts.
- `arm.mint` returns `Result`: it canonicalises (sorted keyed lists, deduped
  `disabled_tools`, repeated slots refused) before hashing, as `decode` does.
- Task files are untrusted: `GitTree.repository` is a logical name matching
  `[a-z0-9][a-z0-9-]{0,63}`, never a path (identity covers what the task
  means, not where a clone lives); `prepare` must be one of three
  allowlisted gleam argvs. `tags`, `fail_to_pass`, `pass_to_pass` are sets
  (sorted, deduped, repeats refused on decode).
- `split.family` falls back to the task name, not its id; `assign` hashes the
  first four digest bytes.
- A ledger row's reward must agree with its outcome (`Passed` above 0, all
  others below 1) and its artifact paths must be safe relative paths or empty.
- `ledger.Outcome` is a local mirror of evalstat's five variants; keep them
  aligned by hand. `report.to_stat` is the one place a ledger row becomes an
  `evalstat/trial.Trial`, and `eval/run` reuses it for the futility check.
- `eval validate <file>` (`src/eval.gleam`) runs these decoders and exits
  nonzero on refusal, using `client/internal/ffi_os.halt`.

## Miner

`eval/mine_cli` (`gleam run -m eval/mine_cli -- [--repo <name>=<path>]...
[--name loom] --out <dir> [--package machine,core] [--limit N] [--commit <hash>] [--work <dir>]`) turns
Loom's own fix commits into regression tasks. It is host-side and trusted,
like CI: no jail, runs through `client/secrets.host_runner()`. Modules:
`eval/eunit_ids` (pure reader of test output, both the `scripts/test.sh`
verbose shape and raw gleeunit), `eval/git` (argv builders, candidate
selection, diff splitting, the sabotage revert, `shell_quote`) and
`eval/mine` (the per-commit pipeline and the pure judgements).

### Pipeline

Per candidate `c` (one package, 1-2 `src/*.gleam`, 1-2 `*_test.gleam`; other
files under that package's `src/` and `test/` ride along, as do its
`CLAUDE.md`/`AGENTS.md`; no deletions): worktree at `c^`, apply only the test
patch, run the touched modules (`scripts/test.sh <pkg> --match <module>:`),
apply the fix, rerun. Fail-to-pass is failed-then-passed, pass-to-pass is
passed-both, both scoped to the touched modules. Zero fail-to-pass, any
failure after the fix, or a before run that reports no tests is a cull with a
reason. Then the sabotage census (revert the first changed code line, skipping blank, comment and import lines, of
the fix, rerun) is recorded as a `sabotage:caught|survived|not_applicable`
tag; it never gates.

### Rulings

- **No agent ever gets a git worktree.** A worktree carries the object store,
  so `git log --all` would show the fix. The miner's own before/after runs use
  `git worktree add --detach` under `$HOME/evalwt/` (never `/tmp`, where the
  code-mode jail replaces the directory) and remove it on every path. The task
  records `GitTree(repo, commit: c^, tree, prepare)` and the wave-2 runner
  materialises it with `git archive`.
- **Old parents get a vendored runner.** `scripts/test.sh` postdates a fifth
  of the history. When the parent lacks it, `scripts/test.sh`,
  `scripts/with_timeout.py` and `scripts/serial-tests` from the miner's
  checkout join the hidden verifier files (the verifier command is `bash scripts/test.sh`, so
  a parent without it has no way to run or name tests) and the task is tagged
  `runner:vendored`. They hash into the task id, which pins the runner that
  produced the recorded ids.
- **P2P is the touched modules, not the package.** `--match <module>:` ends in
  a colon so `lint_test` never selects `other_lint_test`. Several modules
  become one `bash -c` that runs all of them and exits nonzero if any failed.
- **The prompt never names a hidden test.** Subject plus body, unless the body
  contains an F2P function name or a touched test file's name, or the message
  exceeds 8 KiB; then subject only, tagged `prompt:subject-only`.
- **Verifier files are the post-images of every file the test patch touches**
  (fixtures and support modules included), read from the patched worktree.

### Hazards

- A before run that does not compile (the test calls the new API) is a cull,
  not an everything-failed F2P; those are feature commits.
- Candidates run sequentially; concurrent worktrees share ports and scratch.
- `eccdddad0`'s module has 9 tests: 2 F2P and 7 P2P. The 77 passed in the
  raw probe is the whole `machine` package.
- The host runner (`secrets.host_runner`) double-encodes non-ASCII argv under
  `scripts/test.sh`, whose emulator has a non-UTF-8 native file-name encoding.
  Repository and work paths must be ASCII.

## Repositories: names, not paths

`eval/repos.Repos` is the operator's map from a repository name to an
absolute clone path, built from repeated `--repo <name>=<path>` flags
(`repos.from_flags`) and completed by `repos.with_default` with
`loom=<git rev-parse --show-toplevel>` when no flag names `loom`. A path
enters the map only through `repos.check_path` (absolute, at most 1024
bytes, no NUL, no `::`, no segment starting with `-`); a name is checked by
`repos.valid_name`. `repos.resolve(repos, runner, name, commit, tree)` is
the only way a task's repository becomes a path: the clone must hold the
commit and `<commit>^{tree}` must equal the task's `tree`, so a wrong clone
is refused rather than measured. `materialise.run`, `prove.prove`,
`harbor.export` and `trial.Context.repos` all take the map; none records a
path. `mine.Config` carries `name` (recorded in tasks) beside `repo` (the
path mined, never recorded).

The committed task set `tasks/loom-history-v1/` is mined and proved under
this rule; `committed_task_set_is_portable_test` scans it for host paths and
decodes every file.

## Replay lane

`eval/cassette` implements `provider/http.Transport` twice, and `eval/normalise`
decides what counts as the same request. The lane's whole claim is that the
harness, given the same model outputs, makes the same requests; it says nothing
about model quality.

- `cassette.recording(inner, root, sink)` forwards each request to `inner`. A
  request is entered on the tape when it is *prepared* (`Open`), and filed when
  its terminal event passes through, before the consumer sees it. A request
  cancelled at any point, even before begin, is filed as a `Cancelled` recording,
  and `finish` closes still-open entries the same way, so ordinals are
  contiguous and `tape_from_jsonl` accepts every tape the recorder produces.
- `cassette.replaying(tape, root, log)` matches by digest, not position: each
  request takes the first recording with an equal digest that no earlier request
  took (the `Log` actor holds the taken set; the choice is made at prepare time,
  in the caller's order). Concurrent strands (primary, advisor, subagents,
  summarizer) therefore replay whatever order they arrive in. No match is a
  `Divergence` naming the nearest recording (longest agreeing leaf prefix, then
  same position), delivered as `RequestFailed("replay diverged at request n:
  ...")`; the tape's bytes never answer a different request. A recording marked
  `Redacted` is reported, not served.
- Responses are stored **verbatim**: signatures, encrypted reasoning, item ids
  and SHAs are echoed into later requests and must round-trip byte-exact.
  Redaction is only (a) the exact credential values the request's own headers
  carried (held in memory during the request, never stored) and (b) the
  prefixes `sk-`, `xai-`, `ghp_`, `gho_`, `ghs_`, `ghu_`, `github_pat_` and
  `Bearer `. Any change marks the recording `Redacted`. Of response headers only
  the status and `content-type` are stored. A non-UTF-8 body is left as is.
- `normalise.view(request, root)` reduces a request to leaves (method, URL path,
  one leaf per JSON scalar, each key JSON-encoded in its path) and a SHA-256
  digest. Headers and the URL's host and query never contribute; keys containing
  `key`, `secret`, `password`, `cookie`, `session`, `authorization`,
  `credential` or the singular `token` are dropped at any depth (`max_tokens`
  stays: it is a count). Paths under `root` become `<root>` only at a path
  boundary; ISO-8601 dates and times become `<date>` everywhere, **including in
  user content**, so text differing only in a date does not diverge. The tape
  keeps each leaf's length and a 12 digit fingerprint, so `normalise.summary`
  can name the first differing path without prompt text on disk.
- Both transports honour the `Transport` contract the way the native ChatGPT
  transport does: one parked weft managed task per request, its scope pid the
  drain witness, nothing (including the inner `prepare_streaming`) running
  before the begin permit.
- The sink and log are weft actors reached through `ask`, a monitored call that
  returns `Result`; a dead or wedged actor fails the request with
  `RequestFailed("replay lane unavailable: ...")` instead of crashing its task.
  (docs/weft.md names the missing weft primitive for a monitored call on a
  pre-existing pid; `ask` is the stand-in.) `close_sink`/`close_log` stop them.

Hazards: replay is not byte-exact for redacted recordings, which refuse to
replay. A request entered on the tape but never finished is a `Cancelled`
recording, and a replayed request that takes it receives a failure naming the
cancellation. Tape ordinals count from one in prepare order.

## Runner

`eval/run_cli` (`gleam run -m eval/run_cli -- run <plan.json> [--out DIR]
[--tasks DIR] [--arms DIR] [--config loom.toml] [--helper PATH] [--seed DIR]
[--tapes DIR] [--repo NAME=PATH]...`, or `make eval-run ARGS="..."`; `... -- report <run-dir>`)
runs or resumes a frozen plan and writes the report. Modules: `eval/budget`
(the dollar account), `eval/materialise` (starting tree to files),
`eval/arm_settings` (arm to session configuration), `eval/trial` (one
attempt to one ledger row), `eval/run` (plan, rounds, ledger, resume) and
`eval/report` (rows to `report.md` and `report.json`). Operator plans, and the
arms they name, are committed under `plans/` (see Plans, below). It also adds
`telemetry`, `machine` and `broker` to `gleam.toml`: `serve.open_instance`
takes a logger, and the base `Settings` literal names types from the other two.

### Flow

A run directory `<out>/<plan id>/` holds `plan.json`, copies of `tasks/` and
`arms/`, the append-only `trials.jsonl`, `notes.txt` (the budget stop) and the
report. `run.execute` refuses an arm it cannot apply before any trial starts,
then works in rounds, one per attempt number, cells as weft tasks
`budgets.concurrency` at a time. Round one, the only round that admits cells
nobody has tried, runs them in waves of whole tasks and asks
`evalstat.futility` before each wave (see Rulings). One writer actor appends
each row as a whole
line, so a crash leaves a parseable prefix; a `Running` row is written before
a trial starts. Resuming is the same call: a `Running` row with no successor is
closed as an `Infra` row (that attempt is spent) and finished cells are skipped.
Each attempt has its own root, `<task>/<arm>/<index>/attempt-<n>/`, holding
`work/` (the live tree), `state/session.db`, `frozen/` (the copy the grader
sees) and `verifier/`.

`trial.run_one` order: materialise (timed as `prepare`), apply the arm, open a
session through `serve.trial_settings`, prompt and wait under
`wall_ms_per_trial`, read usage and counts from the store, retire and confirm
retirement, copy the workspace to `frozen/`, grade, then export the trajectory.
Timeout is `AgentTimeout` (a failure, never retried, never graded); a final
assistant message that is a provider-reported refusal is `SafetyRefusal` (a
failure, counted, never retried, never graded); a materialise, open,
observation, retirement or grading fault is `Infra`. `Seams` (runner, open,
retire, grade) is how a test makes one fail or watches their order.

### Rulings

- **Budget.** `eval/budget` admits a trial when the cap, less measured spend,
  less the worst case of trials in flight, covers one more worst case
  (`max_requests_per_trial * priced (3 * context + output)`). The first refusal
  is permanent and recorded as "budget exhausted after N trials"; the unrun
  cells are missing, so the verdict is `Incomplete`. The replay lane is
  `Unmetered`. The per-trial guard (a weft actor on the gateway) only counts
  requests against the plan's ceiling; the dollar bound is the run's.
- **The report trusts only a reconciled ledger.** Any `ledger.reconcile`
  failure makes every verdict `Incomplete` with its reason. Line one is the
  minimum detectable effect; each non-baseline arm is compared with the first.
  Beside the clustered interval each whole-plan comparison prints the
  bootstrap one (`verdict.Bootstrap(2000, seed: plan id)`, so a ledger renders
  the same interval every time; the per-split panels skip it, it is not free).
  The report also carries the validate-minus-holdout gap per candidate (the
  difference of the two splits' mean per-task effects, the two clustered
  variances added, "memorised" only when the gap is positive and its whole
  interval is above zero, unavailable below two tasks in a split or with no
  spread), pass@k and pass^k for k = 1..K per arm (a task with fewer than k
  counted trials makes the cell say why instead of printing a number), and a
  `dominance.compare` ruling per candidate over the outcome verdict and the
  arm's mean scores plus `cost_inv`, `turns_inv` and `tool_errors_inv`
  (`1 / (1 + mean)`; a row lacking a score counts as zero).
- **Futility stops admission, never a verdict.** Before each wave of round one
  `run.futile_after` judges every candidate against the baseline with
  `evalstat.futility` over the pairs both arms have counted, every other pair
  still to come. A candidate the plan could not have decided at the start (a
  few tasks) is never stalled by what it has seen, and the run stops only when
  no candidate is still open and at least one stalled. The stop is recorded as
  "stopped for futility after N pairs" in `futility.txt` and the report header;
  the cells not run are missing, so the verdicts are `Incomplete`. Retry
  rounds two and three are not gated.
- **A refusal is a failure of the arm.** `core/message.StopReason` has no
  refusal variant: the adapters map one to `Errored` with a fixed
  `error_message`, and `trial.is_refusal` recognises those messages (a test
  holds the list to the Messages and Gemini adapters' own output, the
  Responses text is copied). Matching text is the only signal the stored
  answer carries; if an adapter changes its wording, change the list.
- **The trajectory never fails a row.** After judging, `trial.attach_trajectory`
  exports `atif.from_session_db` to `<attempt root>/trajectory.json` and records
  `trajectory.json` in the row's `artifacts.trajectory`. A failure is told at the
  head of `side_info` (a row keeps the end of its text, where the verifier's
  verdict sits) and `artifacts.trajectory` stays empty.
- **Tags.** The session tag is a digest of plan, task, arm, index and attempt,
  not production entropy: the roots are unique per attempt under the run
  directory, and a replay needs the same tag every time.
- **Arms.** `arm_settings.to_settings` applies roles, thinking (and routes every
  role again from the resulting catalogue) and withheld tools;
  `arm_settings.profiles` builds one profile per exact target. A `PromptPack`
  component is refused by name: the pack reaches a session only through the
  process environment (`LOOM_PROMPT_PACK`), `Settings` has no field for it,
  and trials share a VM. A `Settings` field in `client` is what lifts it.
- **Exact-file grading** is `trial.grade_expected`, a copy of
  `client/evolution/fixture.score`'s comparison, because that function takes
  the governed task set. `Program` verifiers go through `Seams.grade`;
  `run_cli` opens a jail (`verify.open_jail`) when a plan holds a `Program`
  task and passes `verify.grade` as the grader, and keeps
  `trial.refuse_program` ("program verifier not built") only for a plan that
  needs no jail.
- **Served models** come from the profile observer when the arm has profiles
  and from the recorded answers otherwise (digest empty then).

### Hazards

- Every test that opens a session needs `packages/sandbox/loom-exec` and
  `build/codemode-seed`; without them it prints `SKIP` on standard error and
  passes. Test roots live under `packages/eval/build/eval-test/`, never `/tmp`.
- `jail.selftest` in a row is "unprobed": the posture is read from the
  platform, not from a self-test of the helper.
- Replay tapes are looked up as `<tapes>/<task id>/<index>.jsonl`, so one tape
  serves every arm; a divergence is a `VerifierFailed` row naming the request.

## Plans

`plans/` holds four frozen operator plans over `tasks/loom-history-v1/`, the
arms they name under `plans/arms/<arm id>.json`, and `plans/README.md`, which
carries the expected verdicts, the cost method and the exact `make eval-run`
commands. `aa-live` is two arms that differ only by an inert withheld-tool
name (the arm id never hashes the name, so two copies of one arm cannot share a
plan); `degrade-live` is the baseline against a `TaskPrefix` that forbids
running tests; `smoke-record-live` and `smoke-replay` are one plan in two
lanes, so a tape recorded by the first is found by the second. At 21 tasks and
K = 3 the minimum detectable effect is about 0.25 at worst, so an undecided
comparison reads `Underpowered`. `committed_plans_validate_test` loads every
plan through `run.load`, validates every arm file, and holds the README to the
plans' names and commands. Editing a plan or an arm changes its id; the
refusal from `gleam run -m eval -- validate <file>` names the new digest. The
stamped `harness.git_commit` and the `no-tests` arm's catalogue target
(`main`, `main-model`) are placeholders an operator re-stamps.

## Verifier

`eval/verify` grades a retired trial by running the task's `Program` in a
fresh jail; `eval/prove` is mutation testing of a mined task's verifier; and
`eval/prove_cli` (`gleam run -m eval/prove_cli -- --tasks <dir>
[--repo <name>=<path>]... [--out <dir>] [--helper <path>] [--seed <dir>] [--best-effort]`) proves a
directory of tasks into `<out>/prove.jsonl`.

- `verify.open_jail(settings, root)` starts a two-helper pool, executor and
  broker (`workspace_plane.start_effect_plane`, the one-shot plane shape
  `serve.BuildPlane` names) over `root`, with `gleam` and `erl` located as
  code mode locates them and mounted read-only, then proves the pool can run
  `true` under `settings.demand` and keeps the kernel's enforcement report
  (`verify.enforcement`, `verify.demand_text`). A host whose helper skips a
  layer refuses here with the layer in the reason. Under `BestEffort` the
  only tolerated skip is `skip:cgroup-v2` (`verify.tolerated_skip`); any other
  skipped layer refuses the probe and every later run. There is no host
  fallback.
- `verify.grade(task, workspace, out_dir, jail, pristine)` treats the frozen
  `workspace` as adversarial. The copy at `<out_dir>/verify` is built by a
  walk that `lstat`s every entry and keeps regular files and directories only
  (symlinks, fifos, sockets and devices are dropped and counted in
  `side_info`), drops the top-level `logs/` and every `build/`, then lays the
  `build/` directories under `pristine` (materialise's host-prepared copy
  from before the agent ran, `Prepared.pristine`) over it. Hidden files are
  re-checked with `wire.safe_path`, every path component must be a real
  directory, and the target is unlinked before it is written. A `Program`
  whose argv runs a workspace path in command position (`bash
  scripts/test.sh`, `./run && ...`, read by `verify.command_paths`) is refused
  unless that path is among `Program.files`.
- The run clears `bash -o pipefail -c '( exec <argv> ) >logs/verifier/stdout
  2>…/stderr; tail -c 1 MiB … > stdout.tail …'` through
  `tools/tool.broker_runner` under `evolution_trial_policy(build_plane_policy
  (root), trials, copy)`: readable and writable roots are the copy alone,
  network off, scratch tmpfs, wall `timeout_ms` (capped at
  `task.max_timeout_ms` = 600 s, the jail's default wall), `HOME` outside
  every root. Host reads of `stdout.tail`, `stderr.tail` and `reward.json`
  `lstat` first, accept regular files only, and cap at 1 MiB / 64 KiB; a fifo
  or link is refused unread, never opened. Only those three are copied to
  `<out_dir>/verifier/`. The copy walk reads at most `verify.default_caps`
  (64 MiB per file, 1 GiB per copy; `grade_within` takes other caps for a
  test); a file over either is dropped and counted as `oversize` in
  `side_info`, and the grade continues. A task whose `timeout_ms` exceeds
  `task.max_timeout_ms` is graded 0 up front with the cap named, never run
  and never `Infra`.
- A pass is all of: exit status 0; every `fail_to_pass` and `pass_to_pass`
  id parsed as `Passed` by `eunit_ids.parse` over both tails (an unnamed id
  did not pass); and `reward.json`, when present, passing `Scoring`. Any
  fault is reward 0 with every fault named in `side_info`. A wall-stopped
  run is reward 0 with "verifier timed out" and `exit_status`
  `no_exit_status` (-1), never `Error`. Only a refusal, an execution failure
  or an unadmitted task is `Error` (the runner's `Infra`). `scores` carries
  the reward map plus `f2p`/`p2p` fractions; `side_info` (<= 8 KiB) is the
  faults, the drop counts, then a `telemetry/field.scrub_text` tail.
- `prove.prove(task, repos, root, jail, runner)`: `git archive` of the parent
  (no `.git`, tree id checked, `MinedCommit.parent` must equal
  `GitTree.commit`) under `<root>/<id12>/tree`, the task's `prepare` argvs
  plus a warm `gleam build` on the host, the source patch from `git diff
  parent fix -- . ':!packages/*/test/*' ':!*CLAUDE.md' ':!*AGENTS.md'
  ':!docs/*'`, then three grades with the tree as the pristine build: null
  (tree), gold (tree + patch via `git apply`), sabotaged (gold with
  `git.first_revert` applied). `verdict` admits only gold reward 1 with f2p
  = p2p = 1.0 and null reward 0 with f2p < 1.0; sabotage is a census
  (`mine.Sabotage`). `prove.jsonl` lines are `to_json` (`"v":1`, with
  `demand` and the probe's `enforcement`), or `{"file","error"}` for a proof
  that could not run.

### Residual limits

- Code reachable from a fail-to-pass test runs inside the test VM: it can
  print forged EUnit lines or halt the emulator with status 0, and output
  parsing cannot tell. The verifier's defence is the hidden test bodies the
  agent never saw and the pristine dependency build it compiles against, not
  the parse.
- The runner check (`verify.command_paths`) is token-based: an argv such as
  `bash -c "cd scripts && bash test.sh"` runs a workspace file it does not
  name as a path, and is not recognised. The argv is authored by the operator
  or the miner, never by the agent, so the check guards against a careless
  task, not a hostile one; the miner always writes `bash scripts/test.sh
  <pkg> …` and stages that file.

### Hazards

- Every mined task now vendors `scripts/test.sh`, `scripts/with_timeout.py`
  and `scripts/serial-tests` (`mine.runner_files`), because the verifier
  refuses an unstaged runner; tasks mined before this rule without the
  `runner:vendored` tag are refused at grade time and must be re-mined.
- The miner's after-fix run is made without the network (`mine.offline`,
  `unshare -rn`, when the host allows it); a fix whose tests pass with the
  network and fail without it is culled as "tests need the network, which the
  verifier jail has off: <ids>" (`mine.network_only_failures`). Tasks mined
  before this rule whose tests open sockets (the two `provider/http_test`
  commits) are refused at proof time with gold f2p = p2p = 0 and
  `{badmatch,{error,eperm}}` in the verifier output.
- `prove.package_for(task, argv)` reads the `pkg:<name>` tag first and falls
  back to `prove.package_of(argv)`, which also understands the miner's chained
  `bash -c "… 'scripts/test.sh' '<pkg>' … && …"` form; both `prove` and
  `materialise` use it to find the package a `prepare` step runs in.
- `scrub_text` redacts any 32-grapheme credential-alphabet run, which
  includes long test names in the output tail; the failing ids are listed
  unscrubbed above the tail for that reason.
- The verifier policy's limits are the pool defaults (`cpu_s: 300`); a
  verifier that needs more CPU time than that is killed by the rlimit, not
  the wall.
- Test roots live under `$HOME/evalwt/verify-test/`; the tests ask for
  `PlatformEnforcement` first and rerun under `BestEffort` only when every
  `skip:` in the refusal is `skip:cgroup-v2`, printing a `NOTE` line; any
  other refusal is a `SKIP`.

### Runner addenda

- `materialise` runs a git task's `prepare` argvs in the package the verifier
  names (`prove.package_of`, so `packages/<pkg>`) when the tree root is not a
  Gleam project, then a warm `gleam build` there when any step used `gleam`;
  both are inside the timed cold start.
- `run -- --record DIR` on a live plan taps the wire with `cassette.recording`
  per cell and writes `<DIR>/<task id>/<index>.jsonl` when the trial's findings
  are asked for (after retirement); the lane is `trial.Recording`, metered like
  `Live`. Both transports normalise `<root>` over the whole attempt root, since
  the system prompt names its home and state directories too.
- `Context.selftest` is what each scored row's `jail.selftest` carries: the
  CLI says `verify.open_jail probe: ...` when it opened a jail (the probe ran
  `true` under the demanded enforcement) and `trial.unprobed` otherwise.
- The program path is tested with the mined `eccdddad0` task
  (`test/fixtures/f97168ff....json`) through `trial.run_one` and the real jail;
  the gold case patches the frozen copy from inside the grader seam, so it
  needs the loom repository history and skips without it.

## Transcripts

`eval/transcripts` exports daemon sessions for the failure taxonomy
(`docs/review/eval-failure-taxonomy-2026-10.md`, design note section 9), and
`eval/transcripts_cli` is its command line (`export --state DIR [--db PATH ...]
--since ISO --out DIR`, `sample --dir DIR --n N --seed S`).

- `export` copies each `<state>/sessions/*.db` (plus `-wal` and `-shm`) under
  `<out>/.copies/`, opens the copy, writes `<out>/<stem>.jsonl` mode 0600, and
  deletes the copy on every path. An original is never opened. A copy that
  still carries a live daemon's unexpired writer lease is refused by its open
  and appears in `Census.failed`; stop the daemon first.
- A file is a header line (scrubber version and limits, primary model,
  session outcome), then `user`, `assistant`, `tool_call`, `tool_result`,
  `compaction`, `branch_summary` records in sequence order, then `usage`
  rows. Thinking and images are never read. An assistant record's `outcome`
  comes from `trace.join`, the only public reader of the operator mark, and is
  `unmarked` when absent.
- `scrub_json` is a copy of `client/evolution/trace`'s private one that also
  reads `-` as `_` in key names, since `secret_key` names `api_key` but
  headers spell `x-api-key`. Free text in a tool result is scrubbed by shape
  only: a short secret in prose or a JSON string inside result text survives.
- `sample` reads only headers, groups by model id and outcome, shuffles each
  group with `evalstat/prng.from_string(seed)` and deals round-robin.
- Tests build synthetic databases under `$HOME/evalwt/transcripts-test/`.

## Exports

`eval/atif` and `eval/harbor` write finished evidence in the formats other
tools read; `eval/export_cli` is the command line (`gleam run -m
eval/export_cli -- atif <session.db> <out.json>` and `-- harbor --tasks <dir>
--out <dir> --repo-url <url> --base-image <ref> [--repo <name>=<path>]...`). Neither module runs a
trial, builds an image or uploads anything.

- `atif.from_entries(entries, usage, model)` is the pure walk to an
  ATIF-v1.7 `Trajectory`: user turns and answers are steps numbered from 1
  with no gaps; a tool result joins the step that most recently issued its call
  id (ids repeat across messages, so the latest issuer wins) and an orphan is
  dropped; thinking blocks are never read; per-step metrics come from usage rows
  tied to that assistant entry, `final_metrics` from every row. The store holds
  no system prompt, so `with_system_prompt` is how a caller adds one.
- `atif.from_session_db(path)` copies the database and its `-wal` beside the
  original, opens the copy with a clock far past any lease expiry (so a lease
  copied from a live writer reads as expired in the copy alone), scans,
  closes and deletes the copy. The original is neither opened nor written.
  `atif.write(trajectory, path)` saves it. `trial.gleam` calls both after a
  trial is judged (see Runner, Rulings).
- `atif.scrub` is the replay lane's prefix rule (`sk-`, `xai-`, `ghp_`,
  `gho_`, `ghs_`, `ghu_`, `github_pat_`, `Bearer `), copied from
  `cassette.redact_text` because that function is private. It deliberately
  is not the 32-grapheme scrubber, which would mangle commit hashes and
  test names. Keep the two prefix lists aligned by hand.
- `harbor.render` is pure; `harbor.export(task, out_dir, options, repos, runner)`
  adds the one repository read, `git diff <parent> <fix>` split by
  `git.split_patch`, whose source half is `solution/gold.patch`. A git
  task's Dockerfile clones `--repo-url`, checks out the task's commit and
  deletes `.git`, so the fix is not in the container's object store.
  `--base-image` and the URL are charset-checked before they reach a
  Dockerfile line.
- `tests/test.sh` for a program verifier copies `tests/files/` into the
  workspace, runs the task's argv, and `tests/reward.py` (python3, which the
  Dockerfile installs when missing) reads EUnit result lines the way
  `eval/eunit_ids` does and writes `{"f2p": x, "p2p": y}`. An expected-files
  verifier compares bytes and writes `{"files": x}`. Both honour
  `LOOM_WORKSPACE` and `LOOM_VERIFIER_LOGS` (defaults `/app`,
  `/logs/verifier`), which is how the tests run the generated script on the
  host.

### Hazards

- `environment_mode = "separate"` is what the design asks for; whether
  Harbor then carries the agent's workspace into the verifier container is
  Harbor's rule, not checked here. Confirm with one oracle run.
- An inline program task has no reference solution; its `solve.sh` fails and
  says so.
- The exporter has not been run through Harbor's validator. By hand, once:
  `python -m harbor.utils.trajectory_validator <out.json>`.
- The Harbor agent adapter, any image build and any upload are out of scope.

## Seal and production

`eval/admit` is the only road from the instrument's tasks to the governed
plane, and `eval/production` reports what operators marked beside what the
holdout measured. The decision for the payload is in
`protocol-change/100` (task-set v2).

- `admit.prepare(pool, split, salt)` calls `split.admissible` first, so a
  `Holdout` request is refused (message names the holdout) before any task is
  read. It then keeps tasks whose `split.assign(salt, split.family(t))` is the
  requested split, orders them by id, converts each to a v2 task
  (`inline` + `expected_files` only) and lets `client/evolution/tasks.decode`
  judge every task alone and then the set. A task the decoder refuses (a
  `GitTree` workspace, a `Program` verifier, a prompt over 512 bytes) lands in
  `Admission.skipped` with that reason; an empty result is an error. The salt
  is the plan's `split_salt`, so a re-salted plan is a different split.
- `admit.submit(admission, door)` bounds the payload to 48 KiB (the operator
  door's argument limit) and calls `door`. `admit.door_argv` and
  `admit_cli` supply the production door: write the args file beside the
  state, run `loomd evolution --state-dir DIR admit_tasks SESSION --args FILE`,
  delete the file. The eval process holds no credential. CLI:
  `gleam run -m eval/admit_cli -- --split tune|validate --tasks DIR --plan FILE
  --session ID --state DIR [--loomd PROGRAM]`.
- `production.join(state_dir, since_ms, holdout)` copies every
  `<state>/sessions/*.db` (and `-wal`, `-shm`) beside itself, reads the copy
  with a clock past any lease, and deletes it; an original is never opened.
  Answers are `MessageEntry` assistant messages with `ts >= since_ms`; marks
  are `prompt/evolution-outcome/<entry id>` facts; profiles are
  `evolution/attempt/*` facts. The attempt journal carries no entry id, so an
  answer takes the profile of the latest attempt with a smaller storage seq
  and the same provider, model and API; none means the absent profile.
- `Unmarked` is excluded from `marked_rate` (`succeeded / (succeeded +
  failed)`) and shown as its own column. A malformed mark or attempt fact
  fails the whole join rather than being counted as unmarked.

### Hazards

- The mark decoder in `production` mirrors `trace.decode_outcome`, which is
  private; if the mark's shape changes there, change it here (the follow-up is
  to export that decoder).
- Concurrent strands on one provider, model and API can attribute an answer to
  a sibling strand's attempt; this matters only when a selection changes
  between them.
- `eval admit` does not exist for the holdout and there is no production CLI
  yet; `production.join` is a library call.
- Tests use `build/admit-test/` and `build/production-test/` under the package,
  never `/tmp`.
