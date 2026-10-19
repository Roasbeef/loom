# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain historical measurements in their evidence
reports rather than carrying old validation forward.

Baselined October 19, 2026 against source `284d656ad` on
`perf/live-resource-followup`, from `origin/main` at
`ba4f1321498ff4d1544197ffdffa35a7d83ae2c4`. The claims below were checked
against this source, saved local evidence, or the explicitly named GitHub
state. This is a scoped profiling handoff, not a new architecture audit.

Main advanced while the first integration run was pending. The original native
affected gate and Linux CI passed, but raw macOS shard results failed despite
advisory green badges. The two targeted retries are exhausted. The final
remote-subagent and agency failures passed three unchanged native repetitions
each; those passes do not establish their CI root cause. This rebase needs a
fresh integration run. The renderer source blob is unchanged from the review.

The Mermaid follow-up and rulings below preserve the upstream validation record.
This terminal-only change does not claim a new browser validation run.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Earlier idle-resource PR | [#1020](https://github.com/Roasbeef/loom/pull/1020) merged at `ae1b65159976bd50a65cfaa04f813a43816ee0ee`. |
| Installed build | The freshly observed terminal and helper report `3cd330739`. Pickglass leaves the daemon application revision unknown. |
| Full-frame allocation | `render.repaint_canvas` preserves the sparse empty-cell default and the existing first-column repaint markers. |
| Local validation | Native `make check-tui` passed all 1,479 tests. Terminal lint has zero errors. The exact-cell/ANSI comparison passes 28 canvas cases. Independent source review approved. |
| Web Mermaid | The upstream validation record retains the 21-check Chrome drive; Firefox and Safari remain follow-ups. |
| Terminal Mermaid | Upstream PR #1024 merged the bounded text renderer. Its PNG path remains research. |
| Publication gates | Remaining affected gates and hosted CI are pending at this documentation commit. No installation, restart or hotpatch was performed in this pass. |

The [fresh profiling report](review/live-frame-resources-2026-10-19.md) records
both live capture rounds, the allocation attribution, matched renderer
measurements and their limits. Three sequential baseline/candidate VM pairs at
200 by 50 cells reduce full-paint allocation by 15.4% and reductions by 11.7%.
Forty scrolling updates use 13.6% fewer words and 8.8% fewer reductions. All
complete styled-cell, cursor and scrolling-frame witnesses match. The report
separates these fixture results from installed CPU and RSS savings, which remain
unmeasured for this candidate.

The previous edition still described PR #1020 as awaiting publication and its
gates. That is now false: GitHub confirms the merge above. Its earlier idle
measurements remain historical evidence in the
[idle-resource report](review/idle-resources-2026-10-19.md), rather than current
running-instance numbers. The new installed helper also supersedes the earlier
observation of a helper still running the old process-table poller. We did not
install or restart it as part of this pass.

## What to do next

1. Finish the focused rendering PR and its affected gates.
   **Exit:** independent review, `make check-affected` and hosted checks refer to
   the exact published head. The selector currently requires client, terminal,
   lint and the global static gates, and says separate signoff is not required.
   Inspect raw advisory macOS results and the skip census before declaring CI
   green. Keep changes to authentication and dependencies outside this PR.
2. Continue attributing the remaining CPU only from bounded captures.
   **Exit:** identify a reachable owner and compare the same workload before
   proposing another fix. Unicode width scans and text painting remain visible
   in the terminal profile. Daemon SQL and filesystem samples do not establish
   one sole cause, and the selected registry process mostly waited.
3. Coordinate any candidate installation and restart with the operator.
   **Exit:** authorize the live lifecycle change, then compare matched session,
   connection and activity cuts. Publication does not update a running process.

4. Drive the Mermaid check in Firefox and Safari once. **Exit:** the same 21
   checks pass, or the differences are filed. The
   [TUI note](design-notes/mermaid-terminal-graphics.md) records the merged text
   renderer and separates it from the unimplemented PNG exploration.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**A blank frame need not materialize blank cells.** The
[terminal package account](../packages/tui/CLAUDE.md) records the sparse canvas
and alternate-phase marker invariant. A frame still begins empty; it never
borrows stale cells from an earlier one.

**Counters answer different questions.** The
[BEAM review guidance](../skills/beam-memory-review/SKILL.md) distinguishes
cumulative allocation, flattened copying size, process capacity, binaries and
RSS. Sample widths are shares of selected active stacks, not CPU percentages.

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

- Installed-client CPU and RSS savings for this candidate remain unmeasured.
- The interrupted benchmark attempts are excluded. All accepted pairs and the
  exact sampling method are named in the fresh report.
- The browser's “access revoked” banner conflates registry unavailability and
  stale incarnations with revoked authority. The inspected log tail did not
  identify the actual refusal for the reported page. This pass diagnoses that
  limitation and makes no authentication change.
- Remaining component callback retention and separate language-server memory
  from the earlier investigation have no new measured repair in this PR.

- ELK layouts are unsupported in the Mermaid frame; a `flowchart-elk` header
  falls back to source. Network fonts, links and interactive callbacks are
  deliberately not enabled.

## How to verify

Run `make check-affected BASE=origin/main` and inspect each gate's own status,
including the skip census. `make check-tui` is the focused package gate.
`scripts/tui_perf.sh . LABEL render 200 50` runs the complete renderer and
forty-scroll-frame comparison over the decoded six-agent fixture.

For the Mermaid path, build with `make gen-client server-shipment`, start
`scripts/web_seed/seed.sh` on private ports (`WEB_SEED_PORT`,
`WEB_SEED_FAKE_PORT`) with its own state directory, and pass the operator URL
to `scripts/web_mermaid_check.sh`. Run it in one shell invocation: a harness
that reaps the process tree between commands also kills agent-browser's
daemon and its tab.

**Do not rebuild a package while tests or benchmarks read its artifacts.**
**Do not overlap timing assertions with the comparison benchmark.**
The local default Go root was inconsistent; use the intact Go 1.26.8 toolchain
for reproducible native gates. Native process-identity tests need host process
observation, which the restricted sandbox refuses. See
[execution guidance](execution.md) for the remaining verification rules.
