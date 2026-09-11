# Next

Read this first for current work, settled boundaries, and remaining acceptance.
Rewrite it after the next body of work. Detailed review and measurements belong
in their own documents.

Re-baselined September 10, 2026 against merged main `3ce454e6` and the local UX
polish commits through `429c66c6`. Source, local gates, and the relevant
GitHub merge, run, and issue states were checked for this edition. The candidate
has not been pushed; the hosted results below establish its base only.

## Where the tree is

| Body of work | Current state |
|---|---|
| Human controls | Queue editing, priority steering, worktree observations, and completion summaries are merged in #344. |
| Markdown skills | #346 is merged in `3ce454e6`; discovery, explicit activation, paged completion, and model-selected loading are shipped in the base. |
| UX polish | General developer defaults, actionable tool failures, partial reviewer recovery, failure context, bounded history, automatic wide diff, selection, and current-state presentation are implemented locally. |
| Local verification | One full `make check` passed: 4,191 Gleam tests, native helper checks, prelude verification, and house-rule lint. Installed native acceptance and matched measurements are recorded in the linked reports. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules, and memory-off observations retain their separate issue acceptance. |

### Corrections to the previous edition

The previous handoff still called for merging the corrected skills release.
PR #346 merged at 01:06:23 UTC on September 11, with head `3f9aa9b3`, into
`3ce454e6`. All fifteen required checks and Linux signoff passed on that head;
main run `34549303602` also passed. The glaml metadata correction remains pinned
at `084857e`; replacing that fork waits for an upstream release.

The previous edition also left sustained-output selection, the joined queue
and reconnect flow, ordinary SDK access, and local resource attribution open.
The new [acceptance ledger](review/ux-polish-acceptance.md) records installed
fixtures for those flows, including actual cgo, authenticated read-only GitHub,
and batched code-mode results. [The resource report](review/ux-polish-resources.md)
separates daemon and TUI measurements, correlated receipts, and retained state.
These deterministic fixtures do not establish external-model reliability,
physical keypress latency, or a long-duration memory plateau.

One independent [review](review/ux-polish-review.md) found three P2 issues in
older-page acceptance and summary aggregation. All were corrected and covered
by regressions. A bounded follow-up checked protocol 028 and the fixes with no
remaining production finding. The native fixture separately exposed a prompt
refused behind automatic inspection; the existing one-unsent-command mechanism
now retains it until the authenticated read completes.

## What to do next

1. **Validate and publish the UX candidate when requested.** The work remains
   local on `codex/ux-polish`. **Exit:** review the acceptance and resource
   reports, then run hosted checks and required Linux signoff on the exact
   published head before normal merge. Local results do not replace that gate.

2. **Keep release dependencies explicit.** **#247** owns SQLite, **#241**
   hosted macOS latency, **#246** the shipped authority/fault/pressure matrix,
   **#244** schedules and timer recovery, and **#245** memory-off evidence.
   **Exit:** each issue's own acceptance on the final dependency set. The short
   local resource fixture does not close a hosted or long-duration claim.

3. **Keep maintenance follow-ups narrow.** **#248** tracks dependency
   re-resolution, **#296** bundled ERTS in jailed PATH, **#286** refused extension
   visibility, **#283** idle helper retirement, and **#345** the etui fork stack.
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
jail roots. The September 10 addendum to protocol 020 makes host reads and
tool networking the development default, while workspace writes and protected
masks remain. Read-scope and network flags independently select lockdown.
Restricted profiles use discovered code-mode resources and explicit mounts,
not a language-manager allowlist.
Skill discovery uses the configured daemon home; it does not grant access to
referenced resources.

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

**Failure context does not replace drain proof.** [Protocol 028](../protocol-change/028-provider-failure-context.md)
preserves bounded local causes and request bounds through cancellation. Context
is redacted before persistence, classification uses the underlying error, and
unconfirmed cleanup remains terminal. Retry-After reaches persisted machine
retries; configured role fallback retains its existing immediate scheduling.

**History retention is a payload bound.** Older pages retain at most 600 entry
descriptors and 16 MiB of encoded payload. Source identity anchors the viewport;
selected transcript cells remain frozen while live metadata progresses. Compact
presentation caches rebuild from retained entries and clear on replacement.
[The acceptance ledger](review/ux-polish-acceptance.md) records the regressions.

## Deliberately open

None of these is unfinished work somebody forgot.

- Completion remains latest-wins. A missed operation start or evicted ancestor
  makes captured evidence partial; the terminal does not invent a complete turn.
- The worktree pane presents bounded observations. It is not an atomic snapshot,
  filesystem watcher, staging interface, or commit action.
- Provider context identifies locally observed initiators and bounds. It does
  not infer the remote provider's internal cause. Immediate configured role
  fallback is distinct from persisted machine retry backoff.
- **#243** remains the shipped approval-policy question; **#85** remains optional
  microVM work. Neither is a prerequisite introduced by these UX changes.
- Background-job retention and conversion remain in the
  [jobs note](design-notes/background-jobs.md). Closed delivery issues **#240**
  and **#183** are not reopened by a current roster.

## How to verify

```sh
make check
make doc-check
make codemode-seed
make release-smoke
bash scripts/test.sh client --match developer_environment
bash scripts/test.sh provider --match failure_context
bash scripts/test.sh runtime --match retry_hint
bash scripts/test.sh tui --match history_view
bash scripts/test.sh tui --match completion_summary
```

The full local gate ran with the real native helper and prepared code-mode
seed. Platform-specific prerequisites and opt-in shipped bootstrap fixtures keep
their own coverage; an ordinary package pass does not imply Linux shipment
acceptance. Native acceptance uses an isolated installation and disposable
sessions. The owner's active daemon and session remain untouched.

**Capture each command's own exit status.** A successful log reader is not a
successful gate. **Use one build/gate at a time per checkout.** Keep enforced
code-mode worktrees outside `/tmp`, where the jail replaces sockets with scratch.
Run resource measurements without overlapping builds. See [execution](execution.md)
for the remaining operational rules.
