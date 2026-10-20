# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain historical measurements in their evidence
documents rather than carrying old validation forward.

Baselined October 19, 2026 against source `12f791346` on
`perf/idle-resource-cost`, from `origin/main` at
`490792538d18577ee001402ef7377998ce1b12b3`. Claims below were checked against
this tree, saved local logs, or the GitHub state named explicitly. This is a
scoped idle-resource handoff, not a fresh audit of every architecture wave or
an assertion that this branch's hosted gates have finished.

The web Mermaid rows and steps were added on October 19, 2026 by
[PR #1018](https://github.com/Roasbeef/loom/pull/1018) (`feature/web-mermaid`),
rebased onto `ae1b65159` after #1020 merged, and checked against a real
browser drive. They do not re-audit the idle-resource claims.

## Where the tree is

| Work | Verified state |
|---|---|
| Earlier resource PR | [#1008](https://github.com/Roasbeef/loom/pull/1008) merged at `4e81e0cc0d341f2e54d820c5033f7adaa6b5e053`. Its evidence does not validate this branch. |
| Idle helper CPU | The baseline's 20 ms host process-table acquisition reproduces the live helper cost. Notification-driven discovery removes those reads while idle. |
| Page memory ownership | Admission owns its callback only in `Pending`; repeated authorization captures registry and identities rather than a resolved attachment. |
| Local validation | Both production changes passed independent review. The final sandbox race suite passes. Before the batching correction, conformance passed 111 tests and real jailed code mode passed 414; final-helper E2E remains required. The surrounding page suites passed 276 tests. |
| Publication | The owner authorized a PR with end-to-end verification. Affected repository gates are running; hosted CI and strict Linux signoff remain pending at this documentation commit. No installation or restart occurred. |
| Web Mermaid fences | A `mermaid` fence keeps its source as page text and renders in an opaque, script-only frame run by the `web_mermaid` package (protocol-change/091). Flowchart and sequence diagrams render in Chrome in both themes; invalid, oversized and refused source falls back to source. `scripts/web_mermaid_check.sh` passes all 21 checks against a seeded daemon. |

The [idle resource report](review/idle-resources-2026-10-19.md) contains the
process census, CPU and allocation measurements, memory ownership paths,
negative controls, review correction, and remaining measurement limits.
Three sequential baseline/candidate OS-accounting pairs reduced median idle
tracker CPU from 5.56% to 0.35% of one core (93.7%). Baseline allocation was
926,261 to 936,643 bytes per benchmark interval; candidate runs recorded zero.
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
4. Drive the Mermaid check in Firefox and Safari once. **Exit:** the same 21
   checks pass, or the differences are filed. Terminal rendering stays a
   separate discussion; the
   [TUI note](design-notes/mermaid-terminal-graphics.md) is research only.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Notifications are discovery hints, not kernel ownership.** The
[ADR-006 addendum](adr/006-macos-seatbelt-boundary.md) preserves Darwin's
lifecycle skip, birth-check/signal race and rapid-daemonization gap. Startup
registers the gated root before capture; cancellation captures independently.
A new descendant watch queues another snapshot, closing the registration gap.
Notifications batch for the original 20 ms interval, avoiding a snapshot per
fork during active bursts. Close interrupts that delay.
A failed live queue returns to polling; failed startup refuses the execution.

**Authorization remains fresh and gateway ownership remains original.** The
[client package account](../packages/client/CLAUDE.md) documents the narrow
page callback and pending-only admission lifetime. Saving memory must not
cache authorization or redirect an admitted relay to another gateway.

**Memory counters describe different properties.** The
[BEAM review guidance](../skills/beam-memory-review/SKILL.md) and
[idle report](review/idle-resources-2026-10-19.md) distinguish allocation,
application-state words, post-collection capacity, binary ownership and RSS.

**Mermaid generates markup only in the separate frame, and mocked vendors do
not establish rendering.** [Protocol-change/091](../protocol-change/091-isolated-mermaid-diagrams.md)
keeps SVG and vendor diagnostics out of the session page. The controlled-promise
tests could not see that Mermaid 12 picks ELK for flowcharts (broken under
Bun's IIFE build, hence the dagre pin) or that a frame without a matching
`color-scheme` is painted on white. A change to the renderer, its
configuration or the frame document needs a run of
`scripts/web_mermaid_check.sh`; the [validation
record](review/mermaid-web-rendering-2026-10-18.md) has the trail.

**Mermaid frames are created near the viewport; the renderer stays
`no-store`.** With 24 diagrams, caching `mermaid.js` saved about 0.5 s and
100 MB, while creating frames only within a viewport of the visible area cut
live frames from 24 to 2 and Chrome's growth from 1,018 MB to 423 MB. Each
frame's own renderer heap is the cost, not the transfer. Re-open caching only
with a remote-daemon measurement that shows transfer dominating.

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
- ELK layouts are unsupported in the Mermaid frame; a `flowchart-elk` header
  falls back to source. Network fonts, links and interactive callbacks are
  deliberately not enabled.

## How to verify

Run `make check-affected` from the publication base, with its shipped-artifact
preparation and strict skip census. `make e2e` and `make e2e-codemode` exercise
the actual helper; `go test -race ./...` in `packages/sandbox` covers the new
tracker races. The notification regression must fail if only its queued rescan
is removed. `make signoff-remote` remains the Linux publication gate.

For the Mermaid path, build with `make gen-client server-shipment`, start
`scripts/web_seed/seed.sh` on private ports (`WEB_SEED_PORT`,
`WEB_SEED_FAKE_PORT`) with its own state directory, and pass the operator URL
to `scripts/web_mermaid_check.sh`. Run it in one shell invocation: a harness
that reaps the process tree between commands also kills agent-browser's
daemon and its tab.

**Do not rebuild a package while its tests use its build artifacts.**
**Check each gate's own exit status and saved failure/skip diagnostics.**
An advisory badge does not establish a passing underlying macOS check. See
[execution guidance](execution.md) for the remaining verification rules.
