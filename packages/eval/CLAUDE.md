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

- `cassette.recording(inner, root, sink)` forwards each request to `inner` and
  files a `Recorded(ordinal, digest, shape, events)` in the `Sink` (a weft
  actor, `start_sink`) when the terminal event passes through, before the
  consumer sees it. `cassette.finish(sink)` returns the `Tape`.
- `cassette.replaying(tape, root, log)` answers the n-th request with the n-th
  recording only if the digests match. Otherwise it delivers
  `RequestFailed("replay diverged at request n: ...")`, files a `Divergence` in
  the `Log` (`start_log`, read with `divergences`), and never hands back bytes
  recorded for another request. A request beyond the tape is a divergence with
  an empty `expected`.
- `normalise.view(request, root)` reduces a request to leaves (method, URL path,
  one leaf per JSON scalar) and a SHA-256 digest. Headers and the URL's host and
  query never contribute; keys naming secrets are dropped at any depth; paths
  under `root` become `<root>` and ISO-8601 dates and times become `<date>`.
  The tape keeps each leaf's length and a 12 digit fingerprint, so
  `normalise.summary` can name the first differing path without any prompt text
  on disk.
- Both transports honour the `Transport` contract the way the native ChatGPT
  transport does: one parked weft managed task per request, its scope pid the
  drain witness, nothing (including the inner `prepare_streaming`) running
  before the begin permit. A cancel before begin therefore starts nothing.
- `tape_to_jsonl` scrubs on the way out (the body joined and scrubbed whole, so a
  secret split across chunks is found; chunk boundaries survive only if nothing
  changed) and `tape_from_jsonl` is total. One JSON object per line, `"v":1`.

Hazards: the tape stores response bodies, so a model that echoes a credential is
the reason scrubbing lives in the encoder rather than the recorder. A line over
16000 graphemes cannot be scrubbed and is withheld. Replay is not byte-exact:
scrubbed bodies differ from what the wire carried. Ordinals count from one and
are reserved when a request begins.
