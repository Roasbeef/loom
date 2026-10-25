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
- Task files are untrusted: `GitTree.repository` must be an absolute local
  path with no option-like segment or `::`; `prepare` must be one of three
  allowlisted gleam argvs. `tags`, `fail_to_pass`, `pass_to_pass` are sets
  (sorted, deduped, repeats refused on decode).
- `split.family` falls back to the task name, not its id; `assign` hashes the
  first four digest bytes.
- A ledger row's reward must agree with its outcome (`Passed` above 0, all
  others below 1) and its artifact paths must be safe relative paths or empty.
- `ledger.Outcome` is a local mirror of evalstat's five variants; keep them
  aligned by hand until the runner joins them.
- `eval validate <file>` (`src/eval.gleam`) runs these decoders and exits
  nonzero on refusal, using `client/internal/ffi_os.halt`.

## Miner

`eval/mine_cli` (`gleam run -m eval/mine_cli -- --repo <path> --out <dir>
[--package machine,core] [--limit N] [--commit <hash>] [--work <dir>]`) turns
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
--out <dir> --repo-url <url> --base-image <ref>`). Neither module runs a
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
  `atif.write(trajectory, path)` saves it. `trial.gleam` is not wired to
  these yet; the orchestrator joins them.
- `atif.scrub` is the replay lane's prefix rule (`sk-`, `xai-`, `ghp_`,
  `gho_`, `ghs_`, `ghu_`, `github_pat_`, `Bearer `), copied from
  `cassette.redact_text` because that function is private. It deliberately
  is not the 32-grapheme scrubber, which would mangle commit hashes and
  test names. Keep the two prefix lists aligned by hand.
- `harbor.render` is pure; `harbor.export(task, out_dir, options, runner)`
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
