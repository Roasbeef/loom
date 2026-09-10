# Next

Read this first for current work, settled boundaries, and remaining acceptance
criteria. Rewrite it after the next body of work. Measurements and detailed
review evidence belong in their own documents.

Re-baselined on September 10, 2026 against merged PR #342 (`e50e6351`) and
the gate-recovery implementation in PR #343 (`0bf37c63`). PR #341
(`8f0d79ff`) and PR #342 are merged. The follow-up's complete local gate,
GitHub checks and twenty-run Linux acceptance passed as recorded below. A result for one commit does not sign off another.

## Where the tree is

| Body of work | Current state |
|---|---|
| Domain lifecycle | PRs 337–340 are in the baseline. This follow-up changes no production process, admission or retirement custody. |
| Human controls | Host-owned priority steering, normal queued turns, operation-bound Escape, and tool/notes/diff presentation are merged. |
| Rendering | PR #341 reuses settled speaker/text layout at the same width and discards old keys when projections are replaced. |
| Changes pane | PR #342 keeps the conversation beside captured edits from 140 columns, falls back to one panel below that width, and preserves independent scrolling. |
| Installed tools | PATH discovery, ripgrep and explicitly configured read-only support mounts are available. Disposable jailed probes passed Go tests, Apple Git, ripgrep and a basic cgo/SDK build. The owner's configuration is unchanged. |
| Measurements | The recorded 532-entry replay produced 537 equivalent frames, about 3.3× faster with 60% less process CPU and 29% fewer profiled heap-word allocations. These remain replay measurements, not live-client CPU or daemon-memory evidence. |
| Gate recovery | Lifecycle observations now authenticate disposable same-epoch connections. A read timeout cannot retire the fixture's separate mutation connection. `make replay-simulation SIM_SEED=n` selects one generated session case. |
| Release acceptance | Joined shipped tests, SQLite/resource decisions, scheduling and memory-off observations retain their separate tracker scope. |

### What the previous edition got wrong

The previous edition described rendering and responsive changes as follow-ups
awaiting integration. Both are now merged. PR #342 was merged with explicit
owner authorization after Linux gate failures; its local acceptance did not
establish a passing final Linux signoff. The recovery-fixture failure is part
of #335, and the separate conformance timeout remains an observation to
classify if it returns.

The recovery fixtures treated a timed-out read as a reason to retry on the
same control connection. That owner retires on an in-flight deadline, so the
next read receives `Disconnected`. The new test observation boundary probes
the original endpoint and epoch once per lifecycle wait. Authentication and
status reads consume one fifteen-second deadline, and the observation requests
closure before returning. Mutations retain their original connection. It does
not launch a daemon or retry uncertain mutations. Controlled-peer regressions
check owner retirement, replies beyond the former two-second limits, and
closure while the observation caller remains alive.

The older invalid-replay correction remains documented in
[the execution note](design-notes/developer-experience-execution.md): the
original reconstruction rendered protocol errors, and its timings and 22.2%
sanitizer attribution were withdrawn. [The performance guide](performance.md#reuse-settled-transcript-layout)
records the corrected workload and its limits. Production client, TUI, broker
and host sources are unchanged by the gate-recovery follow-up.

### Current verification

The complete local `make check` passed on `0bf37c63`, including 1,516 client
tests, 281 TUI tests and zero house-rule lint errors.
`make replay-simulation SIM_SEED=33` passed independently, and documentation
checks passed with existing warnings.

The controlled-peer shared-deadline regression passed. Restoring either short
authentication or read deadline makes it fail, as does removing explicit
observation closure. Independent review identified the need to keep the test
caller alive while checking closure; the regression now does so.

Thirty focused Linux recovery runs and twenty consecutive complete
`scripts/e2e_client_bootstrap.sh` runs passed on `0bf37c63`, with
`LOOM_TEST_PARALLEL=8` and all eleven expected Linux enforcement layers.
Every complete run recorded thirteen fixture commands exiting zero, with no
skips. The earlier standalone sequence lacked delegated cgroups and does not
count. All fifteen GitHub checks passed on the same code commit, including
both platform gates and the 200-seed soak.

The identity-recovery fixture intentionally waits for the crashed writer's
natural lease expiry. These native-VM fixtures have no simulation seed. The
single-seed target is for the generated session simulation; its failure
report prints the seed and corroboration verdict before EUnit truncates the
panic. #335's two acceptance criteria are met. PR #343 records integration
status and checks for the final documentation commit; this handoff does not
claim a separate final-head remote signoff.

## Remaining video-review scope

The original UX acceptance list remains open beyond the merged changes.
`/diff` has its responsive right-hand pane and narrow fallback; its changed-file
navigator and consolidated worktree diff are missing. Editing already queued
input and the proposed completion/running-job summary are also missing.
Broader SDK/framework builds, joined reconnect/control exercise, reading and
selection under live output, complete latency distributions and daemon-memory
plateau remain unverified. See the
[acceptance accounting](design-notes/developer-experience-execution.md#acceptance-still-open-from-the-video-review).

## What to do next

1. **Finish #343's integration and close #335.** The code commit passed the
   full local gate, GitHub checks and twenty complete Linux bootstrap runs.
   **Exit:** merge the reviewed change with the final head's required checks
   satisfied and close #335 with the recorded evidence. Classify a future
   simulation failure from its full seed/verdict report; repeating native-VM
   fixtures does not reproduce BEAM interleavings from a seed.

2. **Continue the remaining UX scope deliberately.** The missing changes-pane
   navigation, queued-input editing and completion summary are separate from
   this fixture fix. Explicit read-only support mounts passed disposable tool
   probes; adopting them in the owner's configuration is still an owner
   choice. **Exit:** each selected flow works in the intended environment.
   The source-file splitting survey remains report-only; no broad split is
   authorized by the usability work.

3. **Keep release dependencies explicit.** **#247** owns the SQLite binding
   decision; **#241** hosted macOS latency; **#246** the joined authority, fault,
   pressure and crash matrix; **#244** recurring schedules, detached timers and
   recovery; **#245** memory-off/no-distillation evidence. All remain open.
   **Exit:** each issue's own acceptance on the final dependency set.

4. **Keep follow-ups narrow.** **#248** owns dependency fingerprint/re-resolution
   problems. **#296** concerns bundled ERTS in jailed PATH; **#286** refused
   extension visibility; **#283** idle helper retirement. **Exit:** reproduce
   each specific symptom before patching it. History-index issue **#324**
   remains closed.

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
make replay-simulation SIM_SEED=33
make signoff SIGNOFF_ARGS=--dry-run
LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote
```

The bootstrap script requires the current `binaries` and `server-shipment`
artifacts. Run it directly for the complete shipped-fixture acceptance;
ordinary package checks report skips when their supplied executable is absent.
For focused control retirement, use `bash scripts/test.sh client --match
tui_daemon_read_deadline_is_not_a_mutation_outcome_test`.
`gleam dev history <authorized.jsonl>` in `packages/tui` runs the repeatable
saved-history layout measurement.

Push the exact head before remote signoff and use one gate at a time in its
owned checkout. Capture the gate command's exit status directly. Do not run
performance comparisons alongside builds or test suites. Keep enforced
code-mode state outside `/tmp`, which the jail replaces with scratch tmpfs.
Preserve the original user session and unrelated checkout state. See
[execution](execution.md) for the remaining operational rules.
