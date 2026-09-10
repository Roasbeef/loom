# Next

Read this first for current work, settled boundaries, and remaining acceptance
criteria. Rewrite it after the next body of work. Detailed review and test
accounts belong in their own documents.

Re-baselined September 10, 2026 against merged PR #343 (`822c5c8b`) and the
UX implementation at `8eb73e59`. PR #343 is merged and #335 is closed.
The UX work is on `codex/ux-followthrough`; local validation does not establish
GitHub checks, Linux signoff, review approval, or merge authorization.

## Where the tree is

| Body of work | Current state |
|---|---|
| Human controls | Priority steering, ordinary queued turns, and operation-bound Escape are in the baseline. Bare `/queue` now fetches and edits complete held input by identity and revision. |
| Changes pane | `/diff` observes the attached workspace through jailed Git, including net staged/unstaged and untracked changes. File navigation, explicit refresh, wide side pane, and narrow fallback are implemented. |
| Completion | The latest card and `/summary` report captured operation outcomes, edits, and actual tool/command results, with current queue counts and a separate live-job observation. |
| Rendering | The existing settled-layout cache and independent conversation/diff scrolling remain. No new performance claim is made for the additional views. |
| Gate recovery | PR #343 is merged; #335 was closed with its existing acceptance evidence. The direct `make replay-simulation SIM_SEED=n` target remains available. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules, and memory-off observations retain their own open issues. |

### What the previous edition got wrong

The previous handoff still directed the next session to merge #343 and close
#335. Both actions completed on September 10. It also described file navigation,
worktree diffs, queued-input editing, and completion summaries as unimplemented.
Those flows are now implemented and locally exercised together. The remaining
acceptance list below does not silently inherit success from those tests.

### Current verification

All local gate stages passed, using the initial full gate and the affected and
remaining stages after integration fixes. Final results include 1,531 client
tests, 310 TUI tests, 77 conformance tests, and 127 lint-package tests. Native
helper format, vet, build, and tests passed. The native terminal was rebuilt,
and its real-daemon fixture passed. House-rule lint reports zero errors and
649 warnings; documentation checks report zero errors with existing warnings.
The initial failures and their repairs are recorded in the review below.

Opt-in shipped bootstrap fixtures were not enabled, and real code-mode build
fixtures reported their absent seed. Those skips are not shipped acceptance or
Linux signoff. The new joined Git/queue/job scenario ran without a skip.

The focused backend tests cover queue revision conflicts, admission races,
original-author restrictions, retained images, reused request IDs, real jailed
Git, observation cancellation, and the live-job roster. The wire conformance
suite checks 48 fixtures. Terminal regressions cover namespace-safe drafts,
uncertain saves, async worktree correlation, unrelated errors, file identity,
scrolling across resize, and partial or unavailable completion evidence.

The joined `joined_queue_worktree_and_completion_drive` test passed with a real
daemon, websocket, terminal model, broker, and Git repository. Five exact
provider requests exercise a successful edit, actual bash exit 7, a live
background job, and the next turn consuming the exact edited multiline prompt.
The terminal also selects external and untracked Git changes. The provider is
a deterministic fixture and the display backend is virtual; this does not prove
an external provider network or every interactive terminal layout.

One independent review found four reachable integration errors: a live-job
read classified as a mutation, a duplicate synchronous worktree reply, queue
identity reuse across sessions, and unrelated errors clearing pending views.
Each was corrected and covered. See [the review](review/ux-followthrough.md).

A later direct native run exposed a missed worktree patch-cache invalidation.
Keyboard selection, mouse selection, and delivered observations now invalidate
that projection, and the cache records its actual board and selection. Native
160-by-48 and 100-by-30 checks and the strengthened joined fixture passed.
The same run found that the pinned etui setup leaves terminal flow control
active on this macOS host, consuming the editor's Ctrl+s shortcut. Disabling
flow control in the disposable pane confirmed the cause; a production terminal
setup repair remains outstanding before treating native queue editing as ready.

## What to do next

1. **Integrate the UX follow-through.** Inspect the feature branch's exact
   head and required CI/review state. **Exit:** merge only with the required
   authorization and checks. The previous permission to merge #343 does not
   apply to this change.

2. **Finish the remaining video acceptance.** Exercise reading and selection
   under sustained output across layouts, the joined reconnect/held-tool/multiple
   queue scenario, and broader SDK/framework builds. Measure command-to-ack
   latency distributions and owner-attributed daemon memory plateau separately.
   **Exit:** the [acceptance accounting](design-notes/developer-experience-execution.md#acceptance-still-open-from-the-video-review)
   has direct evidence for each selected flow. The source-splitting survey
   remains report-only; no broad module refactor is part of this work.

3. **Keep release dependencies explicit.** **#247** owns the SQLite binding;
   **#241** hosted macOS latency; **#246** the shipped authority/fault/pressure
   matrix; **#244** schedules and timer recovery; **#245** memory-off evidence.
   All were open at this audit. **Exit:** each issue's own acceptance on the
   final dependency set.

4. **Keep maintenance follow-ups narrow.** **#248** tracks dependency
   re-resolution; **#296** bundled ERTS in jailed PATH; **#286** refused extension
   visibility; **#283** idle helper retirement. **Exit:** reproduce the specific
   symptom before changing its owner. History-index issue **#324** remains closed.

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
This work does not modify the owner's installed configuration.

**Portable decisions and process ownership keep their boundaries.**
`core`, `machine`, and `prompt` remain free of I/O and external functions.
Process machinery follows [the Weft mapping](weft.md); the existing library
supplies observation cancellation without a new Weft API.

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
bash scripts/test.sh client --match joined_queue_worktree_and_completion_drive
bash scripts/test.sh client --match domain_observation_test
bash scripts/test.sh tui --match queue_editor_test
bash scripts/test.sh tui --match worktree_view_test
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
