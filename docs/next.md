# Next

Read this first for current work, settled boundaries, and remaining acceptance
criteria. Rewrite it after the next body of work. Measurements and detailed
review evidence belong in their own documents.

Re-baselined on September 9, 2026 against `eb0bbe60` and the developer-experience
implementation on this branch. The local complete gate and terminal probes
were rerun. Tracker states below were refreshed. Older domain-admission Linux
signoff remains historical evidence; consult the exact current head's status
for its Linux result.

## Where the tree is

| Body of work | Current state |
|---|---|
| Domain lifecycle | The baseline includes PRs 337, 338 and 339: daemon simulation, parked admission during domain retirement, and the retirement corpus. This usability work does not change that custody boundary. |
| Human controls | The host owns priority steering and normal queued turns. Escape stops the observed operation and preserves pending input. Delayed aborts cannot cancel a successor. |
| Current presentation | Request identities separate live text; exact durable results reconcile missing ends. The TUI has compact tool groups, actual pending action, captured edit diffs, current notes and code-mode availability. |
| Installed tools | Generic PATH discovery works and ripgrep runs. Go/Git support is still blocked by the undecided filesystem read policy. No tool directory enumeration or replacement download was introduced. |
| Measurements | Saved-history initial layout improved. Reconstructed original-session replay identified avoidable sanitizer work. Repeated streaming CPU and daemon memory did not establish a reduction. See the execution note for values and limits. |
| Release acceptance | This remains distinct from usability acceptance. The joined shipped matrix, SQLite/resource decisions, scheduling and memory-off observations retain their own tracker scope. |

### What the previous edition got out of date

The previous edition named the three-interface recording evaluation as the next
work and suggested choosing one small improvement afterward. The evaluation is
complete, and the owner authorized implementing its full improvement list.
[The execution note](design-notes/developer-experience-execution.md) now records
that work, the tests, the measured limits, and the unresolved policy decision.
The original recorded session was never resumed for mutating test traffic.

The complete local gate passed, including 1,515 client and 272 TUI tests. A real
release terminal exercised file editing, current notes, code mode, diffs,
Escape, and steer. An independent review found three reachable ordering or
reconciliation gaps; the fixes have regressions which failed with the old
behavior restored. This does not claim that Go/Git acceptance is complete.

## What to do next

1. **Resolve owner-only host reads, then complete tool acceptance.** The owner
   wants installed tools to work without enumerating installation directories.
   Decide whether local owner-only sessions receive broad host reads while
   retaining restricted writes and shared-session confinement. Record an
   approved policy in a protocol change before implementation. **Exit:** real
   jailed Go, Git and ripgrep succeed using installed tools, without downloads,
   and the changed enforcement boundary passes the exact-head signoff.

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
