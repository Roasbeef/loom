# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain historical measurements in their evidence
documents rather than carrying old validation forward.

Baselined October 19, 2026 against source `1f7ff1e47` on
`perf/idle-resource-cost`, from `origin/main` at
`490792538d18577ee001402ef7377998ce1b12b3`. Claims below were checked against
this tree, saved local logs, or the GitHub state named explicitly. This is a
scoped idle-resource handoff, not a fresh audit of every architecture wave or
an assertion that this branch's hosted gates have finished.

## Where the tree is

| Work | Verified state |
|---|---|
| Earlier resource PR | [#1008](https://github.com/Roasbeef/loom/pull/1008) merged at `4e81e0cc0d341f2e54d820c5033f7adaa6b5e053`. Its evidence does not validate this branch. |
| Idle helper CPU | The baseline's 20 ms host process-table acquisition reproduces the live helper cost. Notification-driven discovery removes those reads while idle. |
| Page memory ownership | Admission owns its callback only in `Pending`; repeated authorization captures registry and identities rather than a resolved attachment. |
| Local validation | Both production changes passed independent review. The final sandbox race suite passes. Conformance passed 111 tests; real jailed code mode passed 414. The surrounding page suites passed 276 tests. |
| Publication | The owner authorized a PR with end-to-end verification. Affected repository gates are running; hosted CI and strict Linux signoff remain pending at this documentation commit. No installation or restart occurred. |

The [idle resource report](review/idle-resources-2026-10-19.md) contains the
process census, CPU and allocation measurements, memory ownership paths,
negative controls, review correction, and remaining measurement limits.
Three sequential baseline/candidate OS-accounting pairs reduced median idle
tracker CPU from 5.20% to 0.48% of one core (90.7%). Baseline allocation was
939,326 to 948,481 bytes per benchmark interval; candidate runs recorded zero.
These are isolated tracker measurements on a host that was not quiesced, not
installed-daemon CPU or RSS savings. The report also records sampled profiles,
including their limited active sample counts.

The authenticated real-page regression varies an unused runtime hook by
8,192 messages. After both repairs, three fresh fixture VMs measured socket
capacity of 6,216 to 22,192 bytes with the payload, versus 973,624 bytes before.
Gateway attachment growth remains 388 to 414 words. Each broad-capture
negative control independently violates its bound. These results establish
fixture ownership and copying bounds, not a daemon-wide resident-memory delta.

The previous edition is preserved in
[the prior snapshot](next-2026-10-19-before-idle-resources.md). Its next step
still described PR #1008 as awaiting merge; that is now false, as confirmed by
GitHub. Its architecture-wave and older runtime claims were not re-audited in
this task and remain historical, with their owning specifications and reports.
The local `main` ref remains `e289d93ab`; use the fetched `origin/main` above
for publication comparisons. The latest main CI run, `39203768078`, completed
successfully for `490792538`, but is not this branch's validation.

## What to do next

1. Publish the focused CPU and page-memory PR and finish its gates.
   **Exit:** independent review, hosted CI including raw advisory macOS logs,
   and strict normal/containerised Linux signoff with a clean skip census
   refer to the exact published head. Revalidate after any source or base
   change. Keep installation and unrelated candidates outside this PR.
2. Obtain operator authorization for installation and a coordinated restart,
   then measure a matched workload. **Exit:** compare CPU, cumulative
   allocation, BEAM process/binary memory and OS RSS/footprint at matching
   concurrency and lifecycle cuts. A finished busy run compared with a new
   idle process cannot demonstrate savings.
3. Profile remaining owners only when a bounded workload supports a change.
   **Exit:** identify the allocating/retaining path and a failing ownership
   bound before proposing another repair. The report records an unmeasured
   component callback candidate and the separate language-server RSS owner.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Notifications are discovery hints, not kernel ownership.** The
[ADR-006 addendum](adr/006-macos-seatbelt-boundary.md) preserves Darwin's
lifecycle skip, birth-check/signal race and rapid-daemonization gap. Startup
registers the gated root before capture; cancellation captures independently.
A new descendant watch queues another snapshot, closing the registration gap.
A failed live queue returns to polling; failed startup refuses the execution.

**Authorization remains fresh and gateway ownership remains original.** The
[client package account](../packages/client/CLAUDE.md) documents the narrow
page callback and pending-only admission lifetime. Saving memory must not
cache authorization or redirect an admitted relay to another gateway.

**Memory counters describe different properties.** The
[BEAM review guidance](../skills/beam-memory-review/SKILL.md) and
[idle report](review/idle-resources-2026-10-19.md) distinguish allocation,
application-state words, post-collection capacity, binary ownership and RSS.

## Deliberately open

None of these is unfinished work somebody forgot.

- Installed-process before/after savings remain unmeasured. Live profiling did
  not stop, patch, collect or restart the operator's processes.
- Idle daemon CPU was about 3.44% of one core, but the bounded sample contained
  too few active observations to rank smaller decoding or SQLite changes.
- The separate idle `gleam lsp` child occupied about 1.26 GiB RSS. Pickglass's
  BEAM census does not account for it; its size alone does not prove a leak.
- `admit` has a component session-list callback that may retain a full
  attachment. Its retained size and a component-level regression are unmeasured;
  the socket/gateway fix makes no claim about that owner.

## How to verify

Run `make check-affected` from the publication base, with its shipped-artifact
preparation and strict skip census. `make e2e` and `make e2e-codemode` exercise
the actual helper; `go test -race ./...` in `packages/sandbox` covers the new
tracker races. The notification regression must fail if only its queued rescan
is removed. `make signoff-remote` remains the Linux publication gate.

**Do not rebuild a package while its tests use its build artifacts.**
**Check each gate's own exit status and saved failure/skip diagnostics.**
An advisory badge does not establish a passing underlying macOS check. See
[execution guidance](execution.md) for the remaining verification rules.
