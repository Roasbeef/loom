# Next

Read this first for current work, settled boundaries, and remaining acceptance
criteria. Rewrite it after the next body of work. Detailed review and test
accounts belong in their own documents.

Re-baselined September 10, 2026 against merged PR #344 (`329002f1`) and the
local Markdown-skills implementation through `5626d1b5` on
`codex/skill-discovery`. GitHub merge,
run and issue states were checked again for this edition. The skill change has
local verification and review; it has not been pushed or given Linux signoff.

## Where the tree is

| Body of work | Current state |
|---|---|
| Human controls | Priority steering, queued-input editing, operation-bound Escape, worktree diffs, and completion summaries are merged in #344. |
| Terminal input | The etui `ff80e0e` pin preserves the earlier fork stack and delivers Ctrl+s on macOS. #345 tracks upstreaming all eight remaining commits. |
| Markdown skills | Shared daemon discovery, YAML validation, paged slash completion, explicit activation, and model-selected loading are implemented locally. |
| Remaining acceptance | Sustained-output selection, the broader reconnect/held-tool/queue scenario, SDK builds, latency distributions and daemon memory measurements retain their own acceptance. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules and memory-off observations remain open. |

### What the previous edition got wrong

The previous edition still directed the next session to merge #344 and described
final-head hosted checks and Linux signoff as pending. The PR merged normally at
23:12:22 UTC on September 10 into `329002f1`. Hosted run `34538600106`, attempt 2,
passed at `f17e7465`; that same head passed `signoff/linux` in 456 seconds,
including all six lanes, eleven enforcement checks and the strict skip census.
These results establish the UX baseline, not the new skills change.

### Skill behavior and verification

[Markdown skills](skills.md) describes locations, invocation flags, refresh and
limits. Discovery deduplicates symbolic aliases and validates frontmatter with
`glaml`. The terminal gets metadata from the attached daemon. The model gets
names and descriptions in `load_skill`; selecting a skill supplies the captured
full document. Explicit `/name arguments` expands before queue admission.

The installed user library loaded 34 documents without warnings: 33 permit
slash invocation and 30 permit model selection. One installed document required
quoting its description because an unquoted colon made it invalid YAML; that
repair preserved its description and instruction body. No skill scripts were
executed by discovery.

The new `loaded_skills_complete_and_reach_the_model` fixture runs a real daemon,
websocket and terminal loop with a deterministic provider and virtual display.
It completes a slash command with Tab, submits arguments, modifies the source
file after capture, and proves the captured manual instructions reach the
provider. It then selects another skill through an actual `load_skill` call.
Unselected bodies are absent from earlier requests and present only after
activation. The resulting conversation retains both selected documents. This
fixture runs without a prerequisite skip; it does not test an external model
network or every native terminal layout.

The package gates passed across the initial full check and a continuation after
Hex API rate limiting interrupted dependency resolution. The continuation
passed 16 host, 1535 client, 315 terminal, 77 conformance and 127 lint-package
tests, plus the native helper format, vet, build and tests. The final whitespace
fix has focused client and joined end-to-end reruns. House-rule lint and the
documentation gate are recorded with the review in
[the skill review](review/markdown-skills.md). No single uninterrupted full-gate
success or remote skills CI result is claimed.

Real code-mode fixtures reported their absent seed, and opt-in shipped bootstrap
fixtures were not enabled. Their package results are not shipped acceptance.
One independent review found a trailing-whitespace mismatch between terminal
recognition and server expansion, and a malformed-flag test that reached the
wrong error. Both were corrected and the reviewer confirmed no open findings.

## What to do next

1. **Integrate Markdown skills when requested.** The current feature is local
   on `codex/skill-discovery`. **Exit:** publish the reviewed commits, pass the
   exact head's hosted checks and required Linux signoff, then merge through
   the normal gate. The earlier #344 merge authorization covered that PR.

2. **Finish the remaining video acceptance.** Exercise reading and selection
   under sustained output across layouts, the joined reconnect/held-tool/multiple
   queue scenario, and broader SDK/framework builds. Measure command-to-ack
   latency distributions and owner-attributed daemon memory plateau separately.
   **Exit:** the [acceptance accounting](design-notes/developer-experience-execution.md#acceptance-still-open-from-the-video-review)
   has direct evidence for each selected flow. The source-splitting survey
   remains report-only.

3. **Keep release dependencies explicit.** **#247** owns the SQLite binding;
   **#241** hosted macOS latency; **#246** the shipped authority/fault/pressure
   matrix; **#244** schedules and timer recovery; **#245** memory-off evidence.
   All remain open at this audit. **Exit:** each issue's own acceptance on the
   final dependency set.

4. **Keep maintenance follow-ups narrow.** **#248** tracks dependency
   re-resolution; **#296** bundled ERTS in jailed PATH; **#286** refused extension
   visibility; **#283** idle helper retirement; **#345** the etui fork stack.
   **Exit:** reproduce the specific symptom before changing its owner.
   History-index issue **#324** remains closed.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Queue edits do not resubmit.** [Protocol 024](../protocol-change/024-edit-queued-input.md)
keeps FIFO position, priority, author, timestamp, and images while comparing
held ID and revision in the gateway actor. Only the currently mutable original
principal can fetch or edit. A stale or drained item conflicts. Unknown saves
retain a locked draft and require an explicit read in the same session, epoch,
and incarnation; a new connection alone may reconcile it. Queue lifetime is
still transient under protocol 018.

**Worktree observation is owner-scoped and bounded.**
[Protocol 025](../protocol-change/025-worktree-observation.md) uses the attached
workspace's final policy and existing broker, demoting filesystem grants to
reads. The gateway acknowledges pending work and runs Git outside its handler
through Weft. The final push has no `reply_to`, retains the original request ID,
and rechecks authority. Omitted files, partial patches, and failed refreshes are
explicit. A pinned HEAD plus later filesystem reads is not an atomic snapshot.

**Completion evidence and current jobs have different timestamps.** The
terminal attributes history only between an observed operation source and its
result leaf. Missing starts or ancestors remain unavailable or partial.
[Protocol 026](../protocol-change/026-live-jobs-observation.md) queries the existing
jobs actor explicitly and includes starting, running, and draining jobs. Ordinary
conversation refreshes neither scan job history nor invoke Git.

**One daemon, explicit activation.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) keeps listing
and preview from resuming work. [ADR-009](adr/009-record-terminal-attempt-custody.md)
and [ADR-010](adr/010-retain-one-unsent-terminal-command.md) retain attempt
identity and one unsent command without retrying uncertain mutations.

**Original custody evidence decides retirement.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains the
native port until observed exit. Timeout, closed channels, and late `noproc`
are not cleanup proof. Domain retirement is recorded in
[sessions](architecture/sessions.md). Normal code-mode teardown remains scoped
to `broker.abort_step`; operation-wide abort keeps its separate meaning in
[ADR-005](adr/005-budget-pooling-granularity.md).

**Authority and jail roots remain server-owned.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md),
[016](../protocol-change/016-record-human-origin.md), and
[020](../protocol-change/020-minimal-jail-root.md) own activation, origin, and
minimal roots. Explicit toolchain/support mounts remain configuration choices.
Skill discovery uses the configured daemon home; it does not grant access to referenced resources.

**Portable decisions and process ownership keep their boundaries.**
`core`, `machine`, and `prompt` remain free of I/O and external functions.
Process machinery follows [the Weft mapping](weft.md); the existing library
supplies observation cancellation without a new Weft API.

**Skill metadata precedes instructions.** [Protocol 027](../protocol-change/027-markdown-skills.md)
shares one captured catalogue between the terminal and model. The model sees
names and descriptions until `load_skill` selects a document. Explicit slash
invocation captures that document before queue admission. Invocation flags
control the two entry points; loading grants no new tool permissions.

**Only the gate posts Linux signoff.** `scripts/signoff.sh` owns the verdict
for a pushed commit. Never post success by hand or treat an older commit's
signoff as evidence for a changed tree.

## Deliberately open

None of these is unfinished work somebody forgot.

- Completion remains latest-wins. A missed operation start cannot be reconstructed
  by guessing from the last user message, and a skipped result is not retirement
  evidence for an unrelated operation.
- Worktree boards are explicit observations, with a captured-edit fallback for
  preview, replay, or unavailable service. There is no filesystem watcher,
  staging UI, commit action, or write capability in this change.
- **#243** remains the shipped approval-policy question; **#85** remains optional
  microVM work. Neither is a prerequisite added by these UX flows.
- Background-job retention and conversion remain in the
  [jobs note](design-notes/background-jobs.md). Closed delivery issues **#240**
  and **#183** are not reopened by a current roster.

## How to verify

```sh
make check
make doc-check
bash scripts/test.sh host --match skill_test
bash scripts/test.sh client --match skills_test
bash scripts/test.sh client --match loaded_skills_complete_and_reach_the_model
bash scripts/test.sh tui --match skills_test
bash scripts/test.sh client --match joined_queue_worktree_and_completion_drive
make replay-simulation SIM_SEED=33
```

The ordinary gate builds current helpers and the native terminal. Opt-in shipped
bootstrap tests require `server-shipment` and their explicit environment; package
success with those prerequisites absent is not shipped-fixture acceptance.
Prepare `make codemode-seed` for real code-mode build coverage. Keep enforced
code-mode worktrees outside `/tmp`, where the jail replaces sockets with scratch.

Capture each command's own exit status. Use one build/gate at a time in its
checkout, and preserve the owner's session and unrelated work. Push the exact
head before any separately required remote signoff. See [execution](execution.md)
for the remaining operational rules.
