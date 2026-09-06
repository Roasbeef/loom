# Next

Read this first. This is the handoff for the single-daemon and multiplayer
work: the implemented boundaries, verified results, and remaining acceptance
requirements. Rewrite it after the next verified milestone rather than adding
another checkpoint above it.

Re-baselined on 2026-09-06 against `client/daemon-review-fixes` at `bc7ff235`.
The architecture and review claims below were checked against that tree;
verification names the commit actually exercised. The project plan remains
[issue-plan.md](issue-plan.md), with the active acceptance criteria in
[single-daemon](design-notes/single-daemon.md#the-acceptance-drive) and the
[multiplayer brief](design-notes/multiplayer.md).

## Where the tree is

One daemon manages sessions across workspaces. Restart restores catalogue
metadata; authorized explicit selection opens a runtime. The implementation
is present, but the broader release goal is not complete.

| Body of work | Current state |
|---|---|
| Contracts and session ownership, phases 0–1 | Protocols 014–016, reclaimable addresses, parked assembly and retained cleanup failures are implemented. Weft 0.4.4 is pinned. |
| Daemon lifecycle and routing, phases 2–3 | Singleton ownership, durable creation keys, bounded admission, lazy catalogue restore, current authority and snapshot transfer are implemented. |
| TUI and shared domains, phases 4–5 | Server-backed selection, uncertain submissions, multiplayer and detached maintenance have executable tests. Revived-domain cadence and synchronous control reconnect still need completion. |
| Default and release acceptance, phase 6 | The final reviewed slice has local full, multiplayer, soak and packaging passes. Its remote platform run remains pending publication. SQLite adoption and filesystem confinement remain open. |

The plan numbers its seven phases 0 through 6. Backwards compatibility and
legacy import were explicitly excluded; do not revive their historical cases.

### Review and branch scope

Draft [#237](https://github.com/Roasbeef/loom/pull/237) is frozen at `3ec78b9e`,
above lifecycle [#235](https://github.com/Roasbeef/loom/pull/235). The reviewed
follow-up branch is `client/daemon-review-fixes`, based on #237. It separates
production changes, generated SQL, dependency locks, fixture repairs, bounded
runner changes, acceptance targets and documentation into atomic commits.

Readiness is now a query, not authority to shut down the daemon. A snapshot
caller's expiring budget drops that transfer without declaring the reader
dead. Genuine reader failure requests exact-incarnation cleanup directly from
the registry captured by the attachment. Live admission and response checks
remain separate; neither consults root readiness first.

The review also repaired journal-mode verification, generated register-prefix
scans, hopeless helper-pool reporting, namespace publication ordering and
bootstrap FFI duplication. Unconfirmed helper retirement still retains its
slot. A timed-out test group receives its final signal before its leader is
reaped, including when a descendant ignores the initial termination signal.

The closing independent review found no high-severity finding. Its remaining
functional findings are not a release waiver: background authorization ticks
can close idle attachments on registry delay, revived domains retain a fenced
maintenance cadence, and control reconnect can block the TUI for five seconds.
The first two have active follow-up slices; the third remains required work.
Source enumeration is bounded but still performs per-row catalogue reads.
It must not be described as eliminating those reads.

The primary worktree, `.claude/worktrees/single-daemon`, retains unfinished
filesystem policy, planner, native helper and protocol 017 edits. Those edits
are excluded and must be preserved. `.claude/worktrees/daemon-candidate` is
the committed integration and verification tree; its dependency caches have
not been patched to manufacture a pass.

### Verification and corrections

At `68c53aa2`, the independently captured results were:

| Gate | Result |
|---|---|
| `make check` | Exit 0, 377.05 seconds; 1,309 client tests, 206 TUI tests; lint zero errors and 613 warnings. |
| `make doc-check` | Exit 0, zero errors and 135 warnings. |
| `make e2e-multiplayer soak-daemon` | Exit 0, 24.09 seconds; the paired latency assertion was unchanged. |
| `make dist e2e-client-bootstrap` | Exit 0, 55.98 seconds; server/client packaging, release smokes and real bootstrap fixtures. |

The subsequent production change is `e6023b7f`: attachment-local registry
access and checked UTF-8 decoding of realpath output. At its docs descendant
`bc7ff235`, the combined `make check dist e2e-client-bootstrap e2e-multiplayer
soak-daemon` gate exited 0 in 425.67 seconds. This independently verifies the
final production delta, including 1,309 client tests, 206 TUI tests, packaging,
bootstrap, multiplayer fixtures and the unchanged paired soak. Remote CI for
this follow-up remains pending publication.

Six one-at-a-time production mutations at `a72b3d70` each compiled, failed
their intended assertion, and passed after exact source restoration. The
[mutation evidence](review/single-daemon-mutation-gates.md) covers premature
execution, stale incarnation, duplicate admission, snapshot reconciliation,
retained-byte accounting and runtime drain before releasing the SQLite lease.
These examples are not an exhaustive crash-at-every-publication-step sweep.
Two remaining durable-boundary tests are being added: restart after a saved
reservation, and restart after database identity exists but before catalogue
confirmation. They must assert exact identity and writer custody, not row count.

The previous handoff's statement that Linux CI passed was tied to an older
run and was insufficient as a current branch verdict. At frozen `3ec78b9e`,
[run 34028143084](https://github.com/Roasbeef/loom/actions/runs/34028143084)
failed on both platforms: Linux hit the relay consumer's monitor-ordering
fixture; macOS hit the paired soak's unrelated-session latency bound. The
relay tests now confirm monitor installation before triggering retirement.
The paired assertion has not been relaxed. Local passes do not replace the
next Linux and macOS result, nor establish the earlier timing failure's cause.

The watchdog defect was independently reproduced on the original source and
retested on `615a26f3`. All nine watchdog self-tests passed. Earlier multi-hour
test gaps included host sleep; current wrappers have independent deadlines and
scoped idle-sleep prevention. A timeout remains a failure, never drain proof.

Historical live Herdr evidence showed two owner-authenticated terminals using
one daemon, model replies without a second keypress, session switching and
shared presence. It does not establish distinct-principal authorization or a
live drive of the current artifacts. Internal multiplayer fixtures exercise
real WebSockets, SQLite and native TUI loops with scripted providers; consult
[multiplayer architecture](architecture/multiplayer.md) for their exact scope.

## What to do next

### 1. Publish the reviewed slice and finish functional follow-ups

Record the final delta's own combined gate, publish it above #237 with native
`gh stack`, and send the exact head and evidence for review. Keep the PR draft
while acceptance remains incomplete. Complete idle authorization, maintenance
resumption, asynchronous TUI control recovery and the two durable crash tests
in independent slices, preserving live revocation and original cleanup proof.

Exit: the final combined tree has reviewed fixes, green platform gates and an
accurate stacked PR. This does not authorize merging the Loom stack or dropping
the remaining requirements below.

### 2. Adopt the SQLite retirement repair

Shipping dependencies still resolve sqlight 1.2.0 and Hex esqlite 0.9.0, not
the evaluated fork. [esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105)
at `45dbb48c` is open and unmerged at this checkpoint. The preferred adoption
route is a patched native Hex release; [ADR-002](adr/002-sqlite-binding.md)
records why an ordinary Gleam git/path dependency cannot build this rebar
package. Do not patch build caches, force garbage collection or publish a
parallel package to conceal that constraint.

The earlier evaluation observed 192 additional database/WAL descriptors over
16 cycles with the original binding and a stable 68 with the repair. Those
are historical evaluation results, not the current shipping artifact's
resource guarantee. Repeat the measurements without a code-path override.

Exit: the reproducible shipping dependency graph contains the fix, and combined
resource, release and platform acceptance verifies that graph.

### 3. Complete confinement and shipped acceptance

Application filesystem dispatch and the separate PrivateScratch work remain
unresolved. Authorization fixtures do not prove that a model in workspace A
cannot read daemon credentials or alter B's database through overlap. Do not
retry restricted native implementation work through another worker or tool,
and do not describe the excluded planner slice as implemented confinement.

Finish the joined shipped-daemon/native-client acceptance drive, including
concurrent startup, distinct principals, switching during live work, restart,
failure containment and resource pressure. Report platform skips explicitly.

Exit: the remaining [acceptance drive](design-notes/single-daemon.md#the-acceptance-drive)
has actual evidence for the final artifact. Neither green package tests nor a
helper's declared enforcement probes substitute for the application boundary.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens; listing and preview never resume work.

**Retirement requires original evidence.** Protocol
[014](../protocol-change/014-helper-shutdown-witness.md) retains the native
port until exit. Caller timeout, port closure and late `noproc` do not prove
transitive cleanup. Failed cleanup retains custody and capacity.

**Authority is server-owned and checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define membership,
revocation, activation and human origin. Workspace memory is owner-private;
sharing requires session-only scope and explicit transcript acceptance.

**Uncertain mutations are not resent.**
[ADR-009](adr/009-record-terminal-attempt-custody.md) retains attempt identity;
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) permits one unsent
command during reconciliation on an adopted attachment. Replay has no effects.

**Production SQL is generated; connection policy is centralized.**
`make gen-sql` owns schema/query outputs. `storage/sqlite_policy` owns shared
pragmas and typed database overrides. Raw SQL is acceptable in tests. Use Weft
for process machinery and keep Erlang limited to necessary host operations.

## Deliberately open

None of these is unfinished work somebody forgot. The acceptance gaps above
are required work, not optional roadmap entries. Broader extension, MCP,
compaction, scheduling and seeded-TUI follow-ups retain their existing design
notes and issue records; their current issue states were not re-audited here.
The source enumeration optimization and minor diagnostic-tail refinement are
separate from the functional failures named above.

## How to verify

```sh
LOOM_TEST_TIMEOUT_SECONDS=600 python3 scripts/with_timeout.py 900 -- make check
make doc-check
python3 scripts/with_timeout.py 600 -- make e2e-multiplayer soak-daemon
python3 scripts/with_timeout.py 600 -- make dist e2e-client-bootstrap
```

**Capture each gate's own exit code.** A successful log tail is not a test
result. Keep the candidate unchanged while its gate runs, and use isolated
worktrees for independent slices. Never build the excluded native edits in the
primary tree as if they were part of the published candidate.

**Bound waits and keep notifications live.** Use the bounded test runner,
scoped sleep prevention and an armed Substrate watcher. Record observed results
separately from suspected causes. Local CI attempts previously failed during
OTP installation or skipped unavailable macOS virtualization; neither was a
platform pass. [execution.md](execution.md) records the remaining hazards.
