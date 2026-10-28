# Current handoff

## Responses completion and returned identity (issue #1139)

Source baseline: `6a2d8f4b4` on `codex/responses-done-arguments`, over main
`e4fb0b5e5` (October 27, 2026). The [validation record](review/responses-1139.md)
documents the reproduction, native parser comparison and remaining gates.

Function-argument done snapshots may supply the whole payload or extend the
streamed prefix. Only the missing suffix is emitted; conflicts still fail and
canonical item/terminal closure remains required. Subscription requests omit
`access_programs`, including existing configured overrides. API-key Responses
requests keep their explicit selection. Served-model headers and bounded
terminal access observations use the existing message fields and diagnostics;
neither can change replay options or the requested identity.

The final provider gate passed all 343 tests, the Responses suite passed 62,
and the catalogue suite passed 137. Eight semantic mutants were killed, and
independent review found no actionable issues. The broader local affected run
hit the unchanged eval mining test's `/proc/self/environ` assumption on macOS.
No assertion was weakened and no test was removed. Before merge, require the
exact final head's hosted checks and configured Linux signoff. Live OAuth
endpoint behavior remains unverified by this patch's deterministic fixtures.

The earlier handoff sections below retain their previous work records. Their
external CI and deployment claims were not revalidated for this scoped fix.

## Agent Client Protocol server (issue #1026)

`loom acp` makes Loom an ACP agent on standard input and output, on branch `acp/agent-server`. It is a client of the daemon like `loom run -p`; the effect plane is untouched. [The architecture page](architecture/acp.md) is the reference: the method mapping, the `_meta.loom` keys, the workspace gate, and the compatibility table for Harbor's generic ACP runner, which was driven unmodified against it over a real pipe.

Open, in the order they matter:

- **Per-session MCP servers** (`session/new.mcpServers`) are refused with `invalid_params`. They need a daemon command that registers direct tools for one session, cleared by the broker and torn down with it, and so a `protocol-change/NNN.md`. aegis's typed `submit_*` tools depend on this.
- **The guidance opt-out** (`_meta.loom.project_instructions=false`) is refused for the same reason: the daemon assembles `AGENTS.md` and `CLAUDE.md` at session start with no per-session switch. The canary-`AGENTS.md` acceptance test cannot be written until the daemon can honour it; the refusal is tested instead.
- **Loom as an ACP client** (a strand whose model is `codex-acp` or `claude-code-acp`, under the broker's clearance and budget) is the second direction in the issue and has no design note yet.
- Sessions are not stopped on SIGKILL or an early SIGTERM (no signal handler); see the lifetime section of the architecture page.
- `session/load` replays the retained window (the newest 100 records), not the whole history.
- The stdio path was verified by hand against SDK 0.12.1; the automated end-to-end drives the same `server.serve` through a pair of subjects. A subprocess-level test belongs with the release smoke.

## Responses recovery integration

[PR #1130](https://github.com/Roasbeef/loom/pull/1130) adds extended Responses reasoning and bounded recovery for missing streamed-part closures. It is rebased onto main `f4a7991c9` for the owner's requested immediate merge. All implementation commits applied cleanly; this handoff was the only Git conflict. The evaluation handoff below is preserved.

Main introduced protocol 100 and reserved 101 while this PR was open. This PR's proposals are now [102, extended thinking levels](../protocol-change/102-extended-thinking-levels.md) and [103, bounded Responses recovery](../protocol-change/103-bounded-responses-recovery.md). Only their identifiers and references changed.

Full hosted checks, raw macOS whole-check logs, executed strict skip censuses, independent review and Linux signoff passed on pre-rebase head `2259f628b`. The [final verification record](https://github.com/Roasbeef/loom/pull/1130#issuecomment-6427364166) preserves both the initial throughput failure and the unchanged passing retest. Those results are not a new full signoff of this rebased head. See the [source validation report](review/responses-stream-recovery-2026-10-26.md) for the implementation proof and limitations.

The recovery ceiling is three total generation attempts, with stricter existing bounds preserved. Stream validation remains strict; no partial response or tool call is accepted. Diagnostics retain only structural metadata, not content. `xhigh` and `max` reach both Responses builders; other adapters retain their prior high-equivalent wire mapping.

No production installation or daemon restart is authorized or performed. After a separately authorized update, apply the desired personal profile settings and verify a live request. If the stream error recurs, obtain the structural diagnostic and a redacted minimal event reproducer before changing validation; bounded recovery does not establish the upstream cause.

## Evaluation instrument handoff

This is the evaluation instrument for #236, on the `eval/*` stack of pull
requests over main `9b8621641`. The [previous
handoff](next-2026-10-25-before-eval-instrument.md) is preserved exactly. Its
two bodies of work, remote evolution slice 3 (closed) and the post-merge CI
repair (still open on draft PR #1112), are unchanged by anything here.
The evolution operator UI handoff from October 24 is preserved
as [its own file](next-2026-10-24-evolution-ui.md); the architecture pages it
describes are current.

Start with [ADR-021](adr/021-evaluation-instrument-beside-governed-evolution.md)
for the decisions, [the architecture page](architecture/evaluation.md) for
how a run works and which module owns each step, and [the design
note](design-notes/eval-instrument.md) for the argument; its §15 lists what
review changed. [protocol-change/100](../protocol-change/100-task-set-v2-and-sampled-verdict.md)
records the governed-path change.

## What landed

Two packages and a change to the governed plane.

- `packages/evalstat` holds the statistics and the decision rule, and is
  held to the R6 portable set. It provides a task-level paired effect with
  a clustered interval, an exact sign test on task signs with a direction
  check, and a cluster bootstrap. It reports the minimum detectable effect
  first and returns Underpowered with a reason, and futility can only
  under-claim. Seeded A/A and planted-degradation properties run on both
  targets.
- `packages/eval` is the developer instrument; it never ships and never
  promotes. It holds:
  - content-addressed tasks with logical repository names, and a miner
    over Loom's own fix commits;
  - a jailed prover (gold one, null zero) and a hardened hidden verifier;
  - a runner and paired report;
  - the replay lane;
  - ATIF, Harbor and transcript exports;
  - holdout-sealed v2 admission and the production join;
  - the first task set (`tasks/loom-history-v1`, 21 proved tasks);
  - operator plans in `plans/`.
- `packages/gepa` is the prompt search as a stdlib-only library, held to
  R6 so a project that is not Loom can embed it: a pure state machine the
  host drives with `next`/`apply`, whose log replays exactly, with the
  front and draws, the budget holds, the reflection prompt and a default
  acceptance rule inside it. `eval/search` is now the adapter (Loom's rows
  and JSON codec unchanged on disk), `eval/reflect` builds Loom's records
  over `gepa/prompt`, and `eval/optimize` keeps the effectful driver and
  asks the library for every decision. An embedder resumes with
  `gepa.replay_checked`, which holds every row to the request `next` made
  before it; the log is printable ASCII by code point so both targets
  write and read the same line, and `scripts/check.sh` now runs gepa's and
  evalstat's suites on JavaScript too. Its README's host loop is a compiled
  test; the module doc of `gepa` names where N-proposal reflection,
  further dispositions, a richer reply and merge lineage would go.
- The governed `evolution.compare` now decides with evalstat over the
  plan's rows, and takes K samples. The door's turn ceiling is 100 and its
  wall 480 s, kept under the code-mode call timeout. The dollar and token
  ceilings are unchanged. The evaluator identity moved to `rollout-2`, so
  evidence judged under the old rule cannot approve.

Every slice was implemented by a worker, reviewed independently, and fixed
before it landed. The verifier's adversarial review found four ways to
forge a pass or escape the copy; all four were closed and re-probed.

## What this environment could not prove

The container had no model API keys and no cgroup v2. Under bwrap the
jail enforced 10 of 11 self-test layers; only the pids limit was missing.
Strict platform enforcement refuses every jailed exec here, so the prover
and the jailed tests ran best-effort. That mode tolerates only a missing
cgroup-v2 layer, and `prove.jsonl` records the posture on every line.
Not yet run anywhere:

1. The live plans in `packages/eval/plans/`:
   - `smoke-record-live` (measures a trial's dollars and records tapes);
   - `aa-live` (must not be Improved or Harmed);
   - `degrade-live` (should be Harmed if powered; at 21 tasks and K = 3
     the detectable effect is about 0.25).

   Their stamped commit and the `no-tests` arm's target are placeholders
   to re-mint; `plans/README.md` says how.
2. `evolution_prompt_acceptance_test` under full enforcement. It is now a
   powered seven-task plan whose arithmetic is proven by a unit test.
3. Harbor: the trajectory validator over an exported ATIF file, and a
   Docker build of an exported task.
4. The failure taxonomy (`docs/review/eval-failure-taxonomy-2026-10.md`)
   is a protocol with an empty results table. Labelling needs real
   sessions.

## Next, in order

1. Run the smoke pair, then `aa-live` and `degrade-live`, and write the
   verdicts and dollars into `plans/README.md`. If A/A is not quiet, the
   instrument is wrong. Debug it before trusting anything else.
2. Export real sessions with `transcripts_cli`, label the sample, and add
   hand-written tasks for every category that is at least 5% of failures.
3. Mine `client`, `tui` and `session_view` once a per-module verifier cost
   is measured (`client`'s full suite is 630 s; mined tasks scope
   pass-to-pass to the touched modules).
4. Then GEPA (#236 phase 5). The candidate is `Arm.components`, and the
   actionable side information is `Grade.side_info`. Acceptance is
   evalstat on the validate split; the holdout gap guards against
   memorisation.

## Deferred, with homes

- Per-role profiles: protocol-change/101 (reserved).
- A `Settings` field for prompt packs. Today `PromptPack` arms are refused
  by name, because the pack reaches a session only through
  `LOOM_PROMPT_PACK`.
- A refusal variant on `core/message.StopReason`. Today `trial.is_refusal`
  matches the adapters' fixed refusal text, pinned by tests.
- Program verifiers in governed comparisons. That needs the jailed
  verifier reachable from `client`; protocol-change/100 says why.
- Refunding the unused per-attempt reservation. Until then, large-window
  targets are always Inconclusive through the door (protocol-change/100).
- Journaling the entry id in `evolution/attempt/*` facts, which would make
  the production join exact.
- The governed door's default program deadline (`within_ms`, 300 s) is
  shorter than its compare wall (480 s), so a program that keeps the default
  can lose up to the dollar cap to trials whose evidence it never sees. Never
  a false Passed. Clamp `wall_ms` to the execution's remaining deadline.
- `loom run -p` and the Harbor agent adapter (#492). `eval/trial` is the
  headless runner it should wrap.

## Watch

Once, under three concurrent builds and a full client run on four cores,
`scripts/test.sh eval` failed one test whose name was lost. 60 loaded
reruns of the cassette suite and every later full run passed. The likeliest
cause is the cassette's 5 s actor waits being starved. If it recurs, write
the log to a file before rerunning so the test name survives, and do not
retry it away.
