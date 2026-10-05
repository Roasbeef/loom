# Current handoff

This edition records the CPU and allocation work measured on 2026-10-05,
against Loom `153fc6b60` and its pinned etui `4d5e466`. It concerns the
`perf/beam-render-cost` and `perf/ascii-width` branches. The installed daemon
still runs `153fc6b60`; both running terminals still use `553999027`.
No candidate was installed, no running VM restarted and no live module patched.

The complete evidence, units, profiler limits and reproduction commands are
in [the investigation](review/beam-cpu-2026-10-05.md). That report separates
local cumulative allocation savings from installed resident-memory claims.

## Where the work stands

| Change | State |
|---|---|
| Web editor completion data, recent-answer Markdown and settled reports | Leaf memo fixes and constructor/patch regressions committed. |
| Growing terminal paragraph | Redundant trim removed; incremental/full-render checkpoint regression extended. |
| Etui ASCII width and left alignment | Separate etui branch at `d55b562`; 1,001 Erlang and 947 JavaScript tests passed. |
| Reproduction | Existing terminal driver plus new `scripts/web_view_perf.sh`. Matched comparisons used Gleam 1.19.0 and OTP 29. |
| Dependency integration | Both source pins and generated manifests select `d55b562`. Local resolution used a command-scoped Git URL rewrite to the sibling repository; the committed public URLs are unchanged. The commit remains unpublished pending approval. |
| Full Loom gate | Integrated `make check` exited 0 with Gleam 1.19.0. Both initially failing LSP tests passed in isolation and in the full rerun; tests and deadlines were unchanged. |
| Independent review | One fresh report-only review found no actionable issue. Fable/Opus were unavailable; a fresh inherited-model context was used. |
| Public review | New branches and draft PR publication require explicit owner approval after automatic approval review rejected the export. No existing PR or remote branch was altered. |

The repeated local comparison removed 83.3% of reductions and 78.8% of
allocated words for 100 unchanged operator views. At 2,048 streamed frames,
the combined terminal changes removed 62.5% of reductions and 53.0% of
allocated words per frame. The six-agent 120x40 styled-cell/cursor witness
matched byte for byte through forty scroll frames. These are fixture results,
not a percentage claim about the installed daemon or terminal.

## What to do next

1. Preserve the green integrated baseline: `make check` exited 0 against
   the exact etui pin, resolved locally. The first full attempt failed two
   client LSP tests, which passed in isolation and the full rerun without
   source or deadline changes. After approved publication, verify a normal
   remote resolution as well. No local path dependency is committed.
2. Obtain the owner's explicit publication approval before pushing either
   topic branch or opening the two draft PRs. The automatic rejection was
   about exporting unpublished code/performance results to public GitHub,
   not about local profiling or fixes. Attach each created PR to the task.
3. Before installing, prepare a concrete source shipment and follow
   [updating](updating.md). Coordinate a graceful shared-daemon restart;
   terminals retain their old client tree until reopened. Do not force-kill
   a busy daemon or equate an installed tree with a switched running VM.
4. Repeat matched live stream, report and terminal-scroll workloads on the
   selected candidate. Capture process heaps, allocator carriers and physical
   footprint at the same cuts. No forced GC precedes a retention claim.
   Issue #454 remains open as a measurement objective here: this work does
   not establish installed resident-memory savings.
5. Refresh the wider roadmap from current source and GitHub before choosing
   another feature. This investigation did not audit the terminal revamp,
   workspace-mode issue queue or release state. The preceding handoff's
   broader snapshot was based on `556e419af` on 2026-10-04; it is available
   in Git history and must not be read as today's status.

## Rulings and implementation boundaries

The existing projection cache is already installed and was observed to hit:
the component projection rebuilt once while 110 views were rendered in one
three-second cut. Do not attribute the older projection-cache improvement to
this patch or introduce a second cache for it.

Keep render memos at leaves. Lustre 5.7.1 discards nested memo entries when
an outer memo hits. Project closure inputs before constructing the callback;
do not retain the whole page model to read two fields.

ASCII optimization requires a whole-string fallback. A following combining
mark or VS16 can change the preceding ASCII grapheme's width; independently
counting an ASCII prefix would break rendering.

No public interface, wire shape, dependency set or host scheduling policy
changes in this work. Session logic still belongs in `session_view`; frame
arrival wakes the host. The profile did not find an idle polling storm.

The broader settled decisions belong in their durable documents: terminal
behavior in [the terminal design](design-notes/terminal-design.md), workspace
authority in [065 by name](../protocol-change/065-web-workspace-mode.md),
strand-origin rollout in [updating](updating.md), executor custody in
[the executor architecture](architecture/executor.md), and merge verification
in [execution](execution.md). This edition does not reopen those decisions.

## Verification boundaries

The integrated full-gate log is `/private/tmp/loom-cpu-20261005/check-full-integrated.log`.
It passed all package gates, including 2,871 client, 1,231 terminal and 657
web-view tests. House lint reported zero errors and its existing census
warnings. Doc-check passed with zero errors and historical citation/staleness
warnings. The first failed full log and isolated LSP reruns remain beside it.


`make check` is the full local gate; capture its own exit status. It does not
include `make doc-check`. Run format, lint and doc checks before publication.
A changed terminal/client shipment also needs the repository's signoff lanes
before merge. Darwin-only testing cannot prove Linux enforcement: the local
run has explicit Linux witness skips and a missing rust-analyzer prerequisite.
The local run also skipped code-mode seed-dependent fixtures. No
`signoff/linux` or hosted-CI success is claimed here, and no merge is
requested or authorized by this handoff.
