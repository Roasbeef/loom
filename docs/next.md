# Next

Read this first for current work, settled boundaries and remaining acceptance
criteria. Rewrite it after the next completed body of work. Architecture and
historical measurements belong in their own documents, not in an accumulating
handoff.

Re-baselined on 2026-09-09 against `origin/main` at `11f32a12`, which includes
[PR #337](https://github.com/Roasbeef/loom/pull/337) and
[PR #338](https://github.com/Roasbeef/loom/pull/338). This edition also describes
the accompanying domain-retirement simulation. Active tracker items, the
changed lifecycle paths and their tests were checked again. Older resource,
latency and platform measurements were not repeated and do not establish
release readiness. Historical run details remain in the
[previous edition](https://github.com/Roasbeef/loom/blob/11f32a128193681430abed12be7b2eb30b654db4/docs/next.md).

## Where the tree is

| Body of work | Current state |
|---|---|
| Single-daemon lifecycle | One root owns the registry, catalogue and independent session custody. Restart restores metadata; an authorized explicit open starts work. See [sessions](architecture/sessions.md) and protocols 014–016. |
| Domain admission | An open during normal domain cleanup immediately reserves a parked session and returns `Opening`. Only the original domain witness's normal exit permits replacement. Cancellation, shutdown and failed cleanup remain fenced. |
| Daemon simulation | Creation-key recovery, pending lifecycle recovery and revocation run in the seed soak. The domain-retirement scenario adds opens before versus after cleanup release, duplicate-operation checks and durable convergence. |
| Filesystem confinement | Minimal jail roots and explicit mounts are implemented. The latest domain-fix Linux signoff ran all eleven enforcement probes with a clean skip census. |
| Live delivery and background jobs | Implemented; [#240](https://github.com/Roasbeef/loom/issues/240) and [#183](https://github.com/Roasbeef/loom/issues/183) are closed. Their remaining design and retention work is listed below. |
| Release acceptance | Still open. A green change gate does not complete the final SQLite/resource observations, joined shipped matrix, scheduling and memory-off evidence. |

### What changed since the previous edition

The previous handoff still asked for a daemon simulation and described its
closing-domain workaround as an unimplemented product fix. Creation/lifecycle
simulation and its budgeted soak landed in #337. Domain admission landed in
#338; `daemon_shipped_schedule_test.stop_saved` no longer polls domain occupancy
before the next explicit open. `Saved` remains a statement about one session,
not proof that its domain has retired.

The old history-index priority is also stale:
[#324](https://github.com/Roasbeef/loom/issues/324) is closed. Remaining gate
reliability symptoms belong to [#335](https://github.com/Roasbeef/loom/issues/335),
and a later green rerun does not identify the cause of an earlier failure.
The previous edition's integration-stack and last-red-platform narrative is
historical evidence, not a description of current merge readiness.

The proposed microVM work in [#85](https://github.com/Roasbeef/loom/issues/85)
is optional platform work. It is not a prerequisite for this daemon admission
repair or the next usability evaluation. Do not restart its earlier protocol
prerequisites without checking what is already implemented.

### Evidence for the admission boundary

The #338 head `81b8606b` passed `signoff/linux` in 441 seconds: all six lanes
passed, all eleven enforcement probes ran, and the skip census was clean.
The prepared local macOS client gate passed all 1,510 tests. An earlier local
run in the fresh worktree lacked the native helper; the prepared run passed
without changing test deadlines or production behavior.

`daemon_domain_test` holds the original domain cleanup callback while opening
and retrying a session. It checks bounded capacity, cancellation, shutdown and
failed cleanup. Restoring the old refusal makes the new admission test fail
with `Unavailable`. The cancelled-waiter test waits for that waiter to drain
before release; transfer of a cancelled dependent still draining was verified
by source inspection, not by that schedule.

The accompanying `simulation_domain_test` corpus covers both saved targets and
both duplicate counts. Every seed compares complete retirement before open
with an open acknowledged while cleanup is held. Restoring the old refusal
fails both the corpus and the soak at `domain/admission`; restoring the fix
passes. [Simulation limits](architecture/simulation.md#what-this-does-not-cover)
still apply: callback release order is controlled, BEAM message interleaving
is not, and this is not kernel or resource-load proof.

## What to do next

1. **Evaluate recorded use of the same task across three interfaces.** This is
   the next requested work. Preserve retries, pauses and the user's stated
   intent, and compare equivalent starting states. Turn timestamped friction
   into a short set of concrete behavior changes; use local logs where a
   recording cannot distinguish UI delay from model or backend delay.
   **Exit:** an evidence-backed priority list with an acceptance check for each
   proposed change. Do not infer a general product ranking from one task.

2. **Take a small functionality improvement supported by the evaluation.** The
   tracker triage found two narrow candidates:
   [#296](https://github.com/Roasbeef/loom/issues/296), bundled ERTS directories
   exposed in jailed shell PATH, and
   [#286](https://github.com/Roasbeef/loom/issues/286), refused extensions visible
   only in logs. [#283](https://github.com/Roasbeef/loom/issues/283), idle helper
   retirement, needs more lifecycle validation and should be a separate change.
   **Exit:** one observed problem repaired, with its shipped or focused
   regression. These are candidates, not approval to implement the whole list.

3. **Keep release dependencies explicit when release readiness becomes the
   objective.** [#247](https://github.com/Roasbeef/loom/issues/247) tracks the
   SQLite binding decision/adoption and gates final resource measurements.
   [#241](https://github.com/Roasbeef/loom/issues/241) tracks hosted macOS latency;
   [#246](https://github.com/Roasbeef/loom/issues/246) tracks the joined authority,
   fault, pressure and crash matrix. [#244](https://github.com/Roasbeef/loom/issues/244)
   owns recurring schedules, detached timers, VM recovery and ambiguous prompt
   behavior; [#245](https://github.com/Roasbeef/loom/issues/245) owns an explicit
   memory-off/no-distillation observation.
   **Exit:** each issue's exact acceptance on the final dependency set. The
   domain simulation does not substitute for those shipped observations.

4. **Improve gate reliability without hiding failures.** Keep named diagnostics
   and fixture repairs under [#335](https://github.com/Roasbeef/loom/issues/335).
   Toolchain/Hex re-resolution is separately tracked in
   [#248](https://github.com/Roasbeef/loom/issues/248).
   **Exit:** reproduce the relevant failure or leave precise evidence and an
   unresolved diagnosis. Do not enlarge waits or serialize tests merely to
   obtain a green result.

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

**The jail base is an allowlist.**
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

- The jobs plane still has a vocabulary-only `jobtools` translation, terminal
  `Held` retention to design, and a helper failure cause reduced to `HelperLoss`.
  Prelude cost and dedicated-pool sizing require measurements. Live job-output
  delivery can now build on the landed event bus. See the
  [jobs design](design-notes/background-jobs.md).
- Converting an overrunning foreground call into a job needs explicit opt-in or
  a policy decision; foreground approval does not authorize an unbounded job.
- Live delivery still has a non-durable held-prompt queue, per-frame authority
  checks rather than registry-pushed revalidation, and snapshot preview as a
  compatibility/catch-up path. See [live delivery](design-notes/live-delivery.md).
- The shipped approval route in [#243](https://github.com/Roasbeef/loom/issues/243)
  remains a product-policy question. A fake approval or a native execution
  error is not evidence for that route.
- Optional microVM support and moving filesystem tools into a jailed payload
  remain separate work. The old handoff also recorded a filesystem resolve/open
  race observation that was not re-audited here; it is not a verified new
  finding from this work.
- asdf/Nix wrapper layouts and the release-versus-transfer barrier's dedicated
  unit coverage were not revalidated in this wave. Keep their recorded limits
  in the protocol and socket documentation rather than treating these gates
  as proof for them.

## How to verify

Build helpers before package tests that use native execution. A fresh worktree
without them can report misleading lifecycle timeout fallout.

```sh
make binaries
make check-client
make check-conformance
make lint-client lint-conformance doc-check
make soak-daemon-sim SOAK_DAEMON_BUDGET_SECONDS=60
```

The full gate runs the shipped binary, enforcement probes and skip census:

```sh
make signoff SIGNOFF_ARGS=--dry-run
LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote
```

Push the exact head before remote signoff. Use one gate at a time in its owned
checkout and capture the gate command's exit code directly. A later `tail` or
status-print command is not that exit code. Do not use `/tmp` for an enforced
code-mode worktree: the jail replaces it with scratch tmpfs. Treat Hex download
errors separately from source/test failures, and preserve unrelated checkouts.
See [execution](execution.md) for the remaining operational rules.
