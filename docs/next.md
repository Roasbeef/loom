# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; keep historical measurements in their evidence reports.

## Image follow-ups and Herdr, October 19

The image fix is based on Loom source `47d4b54a6` and pins etui
`43969f88075a17044640e5e7cc43682b86a988ab` ([etui PR #10](https://github.com/Roasbeef/etui/pull/10)).
The original reported image turn reached Gemini; its later text follow-up
returned to GLM with a placeholder. Follow-ups now retain vision while images
remain in the strand's projected context. Historical image limits and active
run protection remain separate. Navigation or compaction can remove those
pixels and return the strand to text.

Herdr supports standard Kitty graphics after removal of its bespoke API.
The corrected probe accepts its positive `libghostty` reply, and a native
private-session capture verified Loom's 480 by 280 demo image transmission.
Non-empty `NO_COLOR` still suppresses previews. See the [scoped evidence and
remaining gates](review/image-followups-herdr-2026-10-19.md).

Next: finish the exact-head affected gates, hosted CI and Linux signoff for the
Loom PR. The independent review found no substantive issues. No installation,
restart of the operator's daemon, or merge is authorized by this task.

The following resource and Mermaid handoff is preserved historical context;
those claims were not re-audited by the image fix.

Baselined October 19, 2026 against main
`698a693de5f7a22a65f7081ab0fce4f7523624dd`, with the approved fixture follow-up
on `test/admin-read-budget`. The merge, source diff, independent review and
named local results were checked for this edition. Hosted validation of the
follow-up remains pending; no current fully green CI claim is made here.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Resource optimization | PR [#1023](https://github.com/Roasbeef/loom/pull/1023) merged at `698a693de`, with parents `f46b2e161` and `4fd4477f9`, tree `feb0b62a82d94c2084fe7c01a4a9ce0f322d0e8f`. |
| Merge authorization | The operator explicitly authorized merging the published resource revision with the known macOS admin HTTP fixture failure and putting its adjustment in a follow-up PR. This exception does not make the failed run green. |
| Admin-read follow-up | Only the private test helper gives admin snapshot reads a five-second HTTP-head wait. Ordinary routing probes retain one second; the forty-second fixture deadline and every response assertion remain intact. Independent review approved the exact patch. |
| Local follow-up validation | All 191 router tests passed on the merged-main base, direct exit zero in 42.37 seconds. Formatting is clean; client lint reports zero errors. |
| Deployment | No installation, daemon restart, hotpatch or forced collection was performed. Installed CPU and RSS benefits remain unmeasured. |

The previous edition still described #1023 as awaiting merge. GitHub now confirms
the merge above. Its CI run tested the earlier integration `878de0cd` with main
`361ffa9f4`; the actual merge also includes the subsequent remote-approval fix
in `f46b2e161`. The clean merge tree is verified, but the earlier CI evidence
must not be presented as validation of that new tree.

The resource run passed every hosted Linux job and its real census, plus macOS
E2E. Its second macOS package shard nevertheless failed one admin HTTP read
after membership revocation had returned success and the catalogue showed no
grant. The fixture timed out before receiving the response head. Its advisory
badge was green; the underlying runner exited one. The approved follow-up
aligns this functional read probe's wait with the five-second registry calls it
awaits. The log does not prove why the response was late.

All three real remote-daemon scenarios, including partition, passed in that
macOS shard without skips, as did the previously failing admin timer, idle-poll
and LSP deadline fixtures. The earlier broad native client run remained red:
two failures and a distribution-test cancellation. Focused LSP and distribution
repetitions passed; partition repetitions were mixed because the fixture's
file-write and eight-second command preconditions raced observation. Those
results are preserved and are not a passing full native affected gate.

The [profiling report](review/live-frame-resources-2026-10-19.md) records the
capture boundaries and three matched renderer VM pairs. At 200 by 50 cells,
full paints allocate 15.4% fewer words and use 11.7% fewer reductions; forty
scrolling updates allocate 13.6% fewer words and use 8.8% fewer reductions.
Every complete styled-cell, cursor and scrolling-frame witness matches.
These are fixture measurements, not installed CPU or RSS savings.

## What to do next

1. Publish and finish the approved admin-read fixture follow-up.
   **Exit:** its exact published head passes the complete hosted Linux and macOS
   checks, actual advisory runner outcomes and executed skip censuses. Keep the
   change confined to fixture tolerance and its validation record; add no
   retries, skipped tests, authentication changes or production timeouts.
   The operator accepts hosted CI as Linux evidence while the separate signoff
   host is offline. The known-failure merge exception applied to #1023 only.
2. Coordinate any installation and restart with the operator.
   **Exit:** explicit lifecycle authorization, then matched session, connection
   and activity measurements. Publication does not update a running process.
3. Attribute remaining CPU and memory only from bounded captures.
   **Exit:** identify a reachable owner and compare the same workload before
   proposing another repair. Terminal Unicode measurement and text painting
   remain visible; daemon SQL and filesystem samples do not establish one sole
   bottleneck. Separate language-server memory has no new measured repair.
4. Retain the Mermaid follow-ups from the prior validation record.
   **Exit:** the recorded browser checks pass in Firefox and Safari or their
   differences are filed. The [TUI note](design-notes/mermaid-terminal-graphics.md)
   separates the existing text renderer from the unimplemented PNG exploration.

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
