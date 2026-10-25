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
  never ends a cell.
- `ledger.Outcome` is a local mirror of evalstat's five variants; keep them
  aligned by hand until the runner joins them.
- `eval validate <file>` (`src/eval.gleam`) runs these decoders and exits
  nonzero on refusal, using `client/internal/ffi_os.halt`.

