# Next

Read this first for current work, settled boundaries, and remaining acceptance
criteria. Rewrite it after the next body of work. Measurements and detailed
review evidence belong in their own documents.

Re-baselined on September 9, 2026 against merged PR #340 (`93d50830`) and
its rendering follow-up on `codex/render-costs`, plus the responsive changes
pane on `codex/responsive-diff`. PR #340's head `107b3851`
passed all 16 checks, including Linux signoff, before the merge. The follow-up
has its own verification and must not inherit that commit's signoff.

## Where the tree is

| Body of work | Current state |
|---|---|
| Domain lifecycle | PRs 337–339 and 340 are in the baseline. The rendering follow-up changes no process or admission custody. |
| Human controls | Host-owned priority steering and normal queued turns, operation-bound Escape, and current tool/notes/diff presentation landed in PR #340. |
| Installed tools | Generic PATH discovery and ripgrep work. Explicit read-only workspace mounts can expose Go/Xcode support trees under existing policy; the distribution guide documents configuration. A disposable configured session passed real jailed Go tests, Apple Git and ripgrep; the owner's configuration is unchanged. |
| Rendering | Rebuilt compact groups reuse layout for unchanged speaker/text lines at the same width. Replaced projections discard old keys. No package or dependency was added. |
| Changes pane | `/diff` keeps the conversation beside captured edits from 140 columns, falls back to one panel below that width, and preserves independent scrolling. This follow-up has its own verification below. |
| Measurements | Validated 532-record replay is about 3.3× faster, with 60% less process CPU and 29% fewer profiled heap-word allocations. Settled process heap is unchanged; this is not a live-client CPU or daemon-memory result. See the performance guide. |
| Release acceptance | Joined shipped tests, SQLite/resource decisions, scheduling and memory-off observations retain their separate tracker scope. |

### What the previous edition got wrong

The previous edition treated the reconstructed original-session replay as valid
conversation evidence. It actually rendered rejected wire events: the envelope
version and initial snapshot were wrong. The old replay times and 22.2%
sanitizer attribution are withdrawn in
[the execution note](design-notes/developer-experience-execution.md).
The direct sanitizer equivalence checks and text timings remain valid.

The corrected replay admits all 532 records, rejects failure notices and produces
537 byte-identical baseline/head frames. A checked developer driver now enforces
admission before timing. [The performance guide](performance.md#reuse-settled-transcript-layout)
records the workload, retained-memory cost, allocation units and measured limits.
An independent advisor review found no actionable issue in the cache or tests.
The complete local gate passed, including 1,515 client and 275 TUI tests.
The rebuilt client passed a real-terminal probe for edits, notes, code mode,
diffs, Escape and steer, against the unchanged merged daemon.

The responsive changes follow-up passed the complete local `make check`,
including 1,515 client and 281 TUI tests, and `make doc-check` with existing
warnings. Its independent advisor review found no actionable issue. The rebuilt
client passed a real-terminal resize from 160 to 100 columns and back, retained
the pane through a new turn, and closed it with `/diff`. The same disposable
session passed the edit, notes, code-mode, configured-tool, Escape and steer
flow. These local results do not constitute remote signoff for this follow-up.

The previous installed-tools wording also omitted an existing option: trusted
configuration can grant explicit support-tree reads without changing protocol
020. [The distribution guide](distribution.md#installed-tool-support-trees)
shows that path. Automatic broad host reads remain an owner policy decision.

## Remaining video-review scope

The full original UX acceptance list is not complete. `/diff` now has its
responsive right-hand pane and narrow fallback. Its changed-file navigator and
consolidated worktree diff are missing. Editing already queued input and the proposed explicit
completion/running-job summary are also missing. The cgo/SDK probe, joined
reconnect/control exercise, reading and selection under live output, complete
latency distributions and daemon-memory plateau remain unverified. See the
[acceptance accounting](design-notes/developer-experience-execution.md#acceptance-still-open-from-the-video-review).
These are remaining accepted UX work, not work closed by PR #340 or the rendering
optimization.

## What to do next

1. **Choose the desired installed-tool configuration.** Explicit read-only
   support mounts passed real jailed Go, Git and ripgrep in a disposable session.
   The owner can adopt that configuration. Generic access without naming
   directories remains a separate policy decision: record broad local reads
   before implementation and retain restricted writes and shared confinement.
   **Exit:** the selected policy works in the owner's intended environment; any
   changed enforcement boundary passes exact-head signoff.

2. **Treat source-file splitting as a separate decision.** The requested survey
   is complete and report-only. No broad module refactor is authorized by this
   usability work. **Exit:** the owner selects any follow-up scope before files
   are split; preserve gateway actor ordering and runtime state-machine custody.

3. **Keep release dependencies explicit.** **#247** owns the SQLite binding
   decision; **#241** hosted macOS latency; **#246** the joined authority, fault,
   pressure and crash matrix; **#244** recurring schedules, detached timers and
   recovery; **#245** memory-off/no-distillation evidence. All remain open at
   this audit. **Exit:** each issue's own acceptance on the final dependency set.
   The short local measurements in this branch do not close those issues.

4. **Keep follow-ups narrow.** **#335** owns remaining gate reliability symptoms
   and **#248** dependency fingerprint/re-resolution problems. **#296** remains
   about bundled ERTS in jailed PATH, not generic PATH discovery; **#286** owns
   refused-extension visibility and **#283** idle helper retirement. **Exit:**
   reproduce each specific symptom before patching it. Do not infer closure
   from an unrelated green run. History-index issue **#324** remains closed.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens. Listing and preview do not resume work. A terminal
never resends an uncertain mutation: [ADR-009](adr/009-record-terminal-attempt-custody.md)
and [ADR-010](adr/010-retain-one-unsent-terminal-command.md) separate retained
attempt identity from the one unsent command.

**Original custody evidence decides retirement.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains the
native port until observed exit. Timeout, closed channels and a late `noproc`
do not prove transitive cleanup. The manager's domain replacement follows the
same rule, as documented in [sessions](architecture/sessions.md).

**Admission and heavy work have different owners.** The registry acknowledges
a bounded parked reservation; domain/session builders do heavy work outside
its handler. A caller's five-second timeout remains an uncertain call outcome,
not cancellation of an accepted operation. Do not add an unbounded postponed
request queue to solve the closing-domain window.

**Authority is server-owned and checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define activation,
membership and human origin. Workspace memory is owner-private; sharing uses
session-only scope and explicit transcript acceptance.

**The current jail base is an allowlist.**
[Protocol 020](../protocol-change/020-minimal-jail-root.md) owns minimal roots,
read-only toolchain regions and the compatibility host view for a readable
root of `/`. [Protocol 004](../protocol-change/004-sandbox-policy-explicit-mounts.md)
owns explicit mounts: merge identical derived mounts during assembly, refuse
invalid or protected-path overlaps during validation. There is no `GrantMount`;
[#243](https://github.com/Roasbeef/loom/issues/243)'s approval-policy question is
separate. Darwin ancestor metadata grants remain recorded in
[ADR-006](adr/006-macos-seatbelt-boundary.md).

**Socket admission runs after initialization and keeps a transfer barrier.**
The ownership and ordering are documented in
[`session_socket`](../packages/client/src/client/daemon/session_socket.gleam).
Do not move cross-actor admission back into the websocket initializer or let
the upgrading HTTP process release its reservation before transfer is attempted.

**Routine teardown is scoped to its own step.** A code-mode satellite uses
`broker.abort_step`; operator abort retains operation-wide meaning. Background
jobs may own sibling steps. [ADR-005](adr/005-budget-pooling-granularity.md) records
the identity and abort decisions; [effects](architecture/effects.md#background-jobs)
describes the resulting ownership.

**Pure decisions stay portable; process machinery goes through Weft.**
`core`, `machine` and `prompt` have no I/O or external functions. See
[the style guide](gleam-style.md) and [the Weft mapping](weft.md).
Production SQL is generated, with connection policy centralized in
`storage/sqlite_policy`.

**Only the gate script posts signoff.** `scripts/signoff.sh` produces the
`signoff/linux` verdict for a pushed commit; do not post a success by hand.
Keep runner hostnames in environment/configuration rather than repository
artifacts. A merge status applies to its exact commit, not a later edited tree.

## Deliberately open

None of these is unfinished work somebody forgot.

- Host-held input retains protocol 018's transient lifetime. This work changes
  ordering and visibility, not durable queue storage or process custody.
- Exact last-result reconciliation is safe but latest-wins. A missing or
  unrelated result cannot establish retirement across arbitrarily skipped
  operations; request pushes and reconnect handling remain the normal path.
- **#243** remains the shipped approval-policy question. Broad local reads and
  a user's approval route are separate decisions. **#85** remains optional
  microVM work and is not a prerequisite for the current usability scope.
- Background-job retention, foreground-to-job conversion, and other existing
  jobs design work remain in the [jobs note](design-notes/background-jobs.md).
  Closed delivery issues **#240** and **#183** are not reopened by this branch.

## How to verify

```sh
make binaries
LOOM_TEST_PARALLEL=8 make check
make release release-client
make doc-check
make signoff SIGNOFF_ARGS=--dry-run
LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote
```

For focused control regressions, use `bash scripts/test.sh client --match
gateway_test`; the TUI request-boundary regressions use the same runner with
`tui --match generation_stream_test`. `gleam dev history <authorized.jsonl>`
in `packages/tui` runs the repeatable saved-history layout measurement.

Push the exact head before remote signoff and use one gate at a time in its
owned checkout. Capture the gate command's exit status directly. Do not run
performance comparisons alongside builds or test suites. Keep enforced
code-mode state outside `/tmp`, which the jail replaces with scratch tmpfs.
Preserve the original user session and unrelated checkout state. See
[execution](execution.md) for the remaining operational rules.
