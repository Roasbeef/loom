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
| Etui ASCII width and left alignment | Separate etui branch at `7365d47`, including the second-pass four-byte scan; 1,002 Erlang and 948 JavaScript tests passed. |
| Detached code-mode worker | `9adddf030` projects the preceding router before retaining it. The actual admission regression halves unrelated payload growth in flattened words; all 81 code-mode tests passed. |
| Warm Gleam language server | `d219796fc` hashes canonical inventory values, eliminating restarts from key-order rewrites. All 46 manager tests and five additional real downloader/warm-server runs passed. |
| JSON string codec | `1d0f8d05c` scans four safe bytes together and avoids the encoder's slice wrapper. All 140 Erlang core tests passed; both new boundary tests pass on JavaScript, whose nine baseline failures remain. |
| Reproduction | Existing terminal driver plus `scripts/web_view_perf.sh` and `scripts/json_perf.sh`. Matched comparisons used Gleam 1.19.0 and OTP 29. |
| Dependency integration | Both source pins and generated manifests select `7365d47`, now published in [etui #7](https://github.com/Roasbeef/etui/pull/7). Local validation used a command-scoped Git URL rewrite; the public commit is now available from the unchanged GitHub URL. |
| Full Loom gate | Earlier `d219796fc` exited 0. The new JSON candidate at `c9ff4bba3` remains pending: full runs failed broker cancellation grace and web patch count, while a separate task ran 26 CPU-load workers. The failed and isolated logs are retained; assertions and deadlines are unchanged. |
| Independent review | One fresh report-only pass for each body of work found no actionable issue. The second pass ran worker admission and ASCII boundary regressions; the LSP pass traced fingerprint/keeper invariants, and the JSON pass checked byte boundaries, generated JavaScript and binary ownership. Fable/Opus were unavailable; fresh inherited-model contexts were used. |
| Pickglass follow-up | Owner-requested [issue #6](https://github.com/Roasbeef/pickglass/issues/6) proposes bounded CLI allocation counters, coverage/units, export and teardown tests. |
| Public review | The owner authorized publication on 2026-10-05. Drafts [Loom #873](https://github.com/Roasbeef/loom/pull/873) and [etui #7](https://github.com/Roasbeef/etui/pull/7) are open. Etui's hosted test passed; Loom conflicts with current `main` and has no reported checks yet. Rebase and remeasurement follow the other merges. |

The repeated local comparison removed 83.3% of reductions and 78.8% of
allocated words for 100 unchanged operator views. At 2,048 streamed frames,
the combined terminal changes removed 64.2% of reductions and 53.0% of
allocated words per frame. The six-agent 120x40 styled-cell/cursor witness
matched byte for byte through forty scroll frames. These are fixture results,
not a percentage claim about the installed daemon or terminal.

The JSON codec fixture removed 68.2%/37.5% of plain-string encoding/decoding
reductions and 24.6%/18.3% for escaped strings. Allocation was nearly flat.
Its contribution to the terminal fixture was another 1.5% reduction in work,
so the isolated codec percentages must not be applied to the whole app.

The live code-mode configuration measures 480,696 flattened bytes, against
1,024 for the predecessor router its wrapper requires. Narrowing the wrapper
removes that redundant environment on admission and managed-task transfer.
This is an expanded term-copy estimate; original heap sharing, literal and
binary sharing, and live RSS savings remain separate measurement questions.

## What to do next

1. Let the other merges land, then rebase Loom #873 and rerun the
   integrated gate with normal remote dependency resolution. Keep existing
   deadlines and leave another task's CPU load alone unless authorized.
   `make check` previously exited 0 at `d219796fc`, with etui `7365d47`;
   the JSON change has 140 passing core tests and a clean independent
   review. The current integrated gate remains pending.
2. Review the two draft PRs in dependency order, etui before Loom. The owner
   has authorized their publication, superseding the earlier approval block.
   No merge or deployment is authorized by that instruction.
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
counting an ASCII prefix would break rendering. The four-byte scan checks
every byte and keeps the same fallback and single-byte tail.

The async execution wrapper retains only its predecessor router. Its prepared
configuration continues to own required launch inputs; request identity,
policy, workflow custody, step rewriting and the fixed deadline are unchanged.
Do not strip the supervisor's registry merely because its expanded size is
large: that child restart callback still needs its executable tool registry.

The package inventory hashes canonical table and string values, not the
compiler's map iteration order. Every supported key and value still contributes;
real package, version or git-commit changes invalidate the lease. Manifest and
project configuration hashes remain complete source digests. Keep the existing
path admission, missing-file identity and metadata read bounds.

JSON chunks check every byte for quote, backslash and C0 controls, then resume
the single-byte path on any exception. Flushes still end at ASCII boundaries
and validate UTF-8. Keep the existing parser's string ownership; a direct
returned subbinary shortcut could retain a much larger backing input.

Keep the buffer experiments out of the candidate. Cell equality checks cost
more reductions; repeated-cell and row reuse did not offer a consistent CPU
and allocation improvement. Their private measurements are in the report.

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

The previous integrated candidate full-gate log is
`/private/tmp/loom-cpu-20261005/check-full-round3.log`. `make check` returned
exit 0 at source revision `d219796fc`, with etui `7365d47`. It passed all
package gates, including 2,874 client, 1,231 terminal and 657 web-view tests,
conformance and Go checks. House lint reported zero errors and 2,109 census
warnings. Doc-check passed separately with zero errors and 190 historical
citation/staleness warnings. Earlier failed full logs and isolated cases remain
beside the green log; their failures were not hidden or assertions relaxed.

The JSON candidate at `c9ff4bba3` has not passed the integrated gate.
`check-full-round4.log` exited 2 at broker cancellation grace; that case passed
unchanged in isolation. `check-full-round4-rerun.log` exited 2 at web delivery
patch count, and its first isolated run instead timed out at actor startup.
A baseline-JSON control and a second unchanged candidate run passed. The
report records these distinct outcomes and the concurrent separate load task:
26 `yes` workers using about 1,206%
aggregate CPU. Do not infer a proven cause from that coincidence or replace
the current gate result with the older green log. Doc-check passed for this
body with zero errors and 188 historical warnings.

`make check` is the full local gate; capture its own exit status. It does not
include `make doc-check`. Run format, lint and doc checks before publication.
A changed terminal/client shipment also needs the repository's signoff lanes
before merge. Darwin-only testing cannot prove Linux enforcement: the local
run has explicit Linux witness skips and a missing rust-analyzer prerequisite.
The local run also skipped code-mode seed-dependent fixtures. No
`signoff/linux` or hosted-CI success is claimed here, and no merge is
requested or authorized by this handoff.
