# Current handoff

This edition is baselined on main `32846807b2678edebb7f07e1969f6047bf0b1692`
and the optimization source at `34c0db0f0a343a2cf4b41068d3fb001f3bf92317`,
measured on October 5, 2026 (America/Los_Angeles). The claims below were
checked against those builds, the actual gate logs and GitHub state.
The evidence-only commit following that source must receive its own final
remote-head signoff before merge.

The complete counters, workloads, observation limits and historical failures
are in [the investigation](review/beam-cpu-2026-10-05.md). Rewrite this handoff
after another body of work rather than carrying its status forward.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Same-day integration | All 49 other PRs in the owner's October 5 creation window merged before integration began. PR #873 was rebased onto `32846807b`; backup `backup/perf-before-merged-cohort-20261005` preserves the former head. |
| Web rendering | Leaf memos retain projected editor, answer and report inputs. The editor now also keys on upstream's refusal counter; a real-page regression and a failing mutation control verify draft-restoration invalidation. |
| Terminal | The growing paragraph no longer trims an already-trimmed parser head. Incremental/full-render tests and complete styled-cell/cursor witnesses pass. Upstream highlighting behavior remains. |
| Etui | Both pins and generated manifests select `7365d47`, merged through [etui #7](https://github.com/Roasbeef/etui/pull/7). Its ASCII path preserves the whole-string Unicode fallback. |
| Worker admission | The code-mode wrapper projects the predecessor router before closure construction while preserving upstream strand tools, tool gate and launch custody. The actual admission regression remains in the full client gate. |
| Warm LSP | Canonical inventory hashing subsumes upstream line sorting. The upstream reordered-inventory test and semantic version, git-commit and membership tests remain. |
| JSON | Four-byte safe scans and the direct encoder helper preserve total decoding, UTF-8 validation and string ownership. The full core suite passes. |
| Generated web assets | `make gen-client` regenerated the combined sources; CSS differs from main only in three source digests. Other upstream assets remain intact. |
| Local validation | Full `make check` returned its own exit 0 on `34c0db0f`: 140 core, 349 session-view, 750 web-view, 2,944 client and 1,241 TUI tests, plus the other package, conformance and Go gates. Lint has zero errors and 2,157 warnings. Separate doc-check returned 0 with zero errors and 190 warnings before this rewrite. |
| Independent review | A fresh report-only rebase review found no reachable issue in the conflict resolutions, memo inputs, upstream assets or terminal behavior. Earlier work also received separate reviews; these do not replace gates. |
| Hosted validation | Exact-source Linux client, fast, conformance, runtime/storage/session/events, static, bootstrap, jail, compiler and soak checks pass. Deliverables and the macOS lanes were still running at this edition's verification cut. Containerized Linux signoff remains pending. |
| Publication | [Loom #873](https://github.com/Roasbeef/loom/pull/873) is open and ready. The owner explicitly authorized rebasing, measuring and admin-merging it after validation. Nothing from this task has been installed into the running daemon or terminal. |
| Pickglass | The owner-requested [allocation CLI issue #6](https://github.com/Roasbeef/pickglass/issues/6) is now closed. The local allocation command completed a bounded installed-daemon profile with explicit coverage and word/byte counters. |

The previous edition's blocked client gate and missing Loom merge authorization
are no longer current. Main fixed the concurrent shareable stop/isolation race;
the unchanged test now passes locally in 57 ms and hosted Linux client passes.
The historical failed main control and failed hosted artifact remain in the
report, rather than being reclassified as a proven load flake.

## Measured combination

Fresh single-scheduler main/candidate/main/candidate comparisons used the same
Gleam 1.19.0 and OTP 29 toolchain. The web fixture removes 83.1% of reductions
and 78.6% of cumulative allocated words for one hundred unchanged views.
At 2,048 streamed frames, the terminal removes 65.0% of reductions and 52.5%
of words per frame. Six-agent paint removes 43.9% of reductions and forty
scroll events remove 35.8%; the styled-cell and cursor witness is identical.
JSON codec reductions fall 68.2%/37.5% for plain encode/decode and 25.1%/18.7%
for escaped strings, with allocation nearly flat. These percentages describe
the fixtures, not the installed applications. Traced allocation and untraced
timing were separate passes.

Natural-memory probes used separate observers, with no forced collection or
term walks before or between cuts. Web owner capacity after the render fixture
falls from 385,208 to 318,232 bytes; RSS is essentially flat. The terminal's
closed 2,048-frame owner capacities are essentially equal, 1,803,768 versus
1,803,800 bytes. An active one-shot cut gives the candidate a larger heap;
a longer stream shows phase-dependent capacity rather than monotonic growth.
Both owners have 2,918,416 bytes at 8,192 frames. Carriers, allocated blocks,
RSS and physical footprint vary separately and do not establish installed
resident-memory savings. [Issue #454](https://github.com/Roasbeef/loom/issues/454)
remains open.

The installed daemon changed release directory through another actor before
the later Pickglass cut. Its source revision is unavailable in that capture;
PID 40075 remains an unnamed terminal and PID 5645 is gone. These live cuts
cannot be used as matched candidate evidence. No production process was
restarted, hotpatched or forced through GC by this task.

## What to do next

1. Publish the evidence-only commit, verify its static gates and obtain the
   repository's exact-remote-head `signoff/linux`. Inspect any actual failure
   and preserve existing assertions and deadlines. Exit: the latest published
   head passes the required validation, with no unresolved correctness or
   performance regression. Historical green checks are insufficient.
2. Recheck main immediately before merging #873. Rebase and revalidate if a
   newer main changes the measured combination. The owner authorized
   `gh pr merge --admin --merge --match-head-commit` at the verified head.
   Exit: GitHub reports merged and its merge commit is in main's ancestry;
   then disable the existing integration watcher without archiving the chat.
3. Installation remains a separate operation. Follow [updating](updating.md)
   for an approved shipment and graceful daemon transition. Terminals retain
   their old client tree until reopened. Exit: the chosen installed identities
   and matched active/idle/released workloads are observed without disrupting
   busy sessions. Do not infer resident savings from the source fixtures.
4. Refresh the wider roadmap from current source and GitHub before choosing
   another feature. This investigation does not establish today's release or
   workspace-mode rollout state. Exit: any new work has its own current plan
   and validation boundary.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Render ownership.** Keep memos at leaves and project closure inputs before
construction. Lustre 5.7.1 discards nested entries when an outer memo hits.
A model input used inside a memo must participate in its references, including
the refusal counter. Constructor and patch regressions live in the web-view
render-memo tests; the [investigation](review/beam-cpu-2026-10-05.md) records
the cache and mutation evidence.

**Unicode fallback.** An ASCII optimization rejects the whole string if any
byte is outside printable ASCII. Following combining marks and variation
selectors can alter an earlier grapheme's width. Preserve the original fallback
and the boundary regressions in etui #7.

**Custody and copying.** Worker projection retains only the predecessor router;
prepared configuration still owns launch inputs. Do not remove a supervisor's
required executable registry because its flattened size is large. Flat size,
process capacity, cumulative allocation and OS residency are different metrics,
as described in [daemon memory evidence](design-notes/daemon-memory.md).

**Canonical identity.** Supported inventory keys and values all contribute to
the fingerprint. Versions, git commits and membership changes invalidate it;
key order does not. Keep path admission, read bounds, missing-file identity
and full project/manifest digests. The manager regressions cover these cases.

**Codec ownership.** Every chunk checks quote, backslash and C0 bytes. Flushes
validate UTF-8 at the same boundaries. Preserve copied string ownership; a
returned subbinary can otherwise retain a much larger backing input.

**Verification.** [Execution](execution.md) owns the gate and signoff rules.
Only the repository runner posts the Linux signoff. The rule requires the
actual published head, and admin merge authorization does not make a failed
test ready.

## Deliberately open

- Installed resident-memory savings and the remaining ownership census in
  **#454** are unmeasured by this source comparison.
- SQLite bursts remain workload-dependent; this work did not change them.
- Buffer equality and row-reuse experiments remain excluded because their
  CPU/allocation tradeoffs were not consistently favorable.
- Production installation and live workload matching remain separate from
  the authorized PR integration.

None of these is unfinished work somebody forgot. The first and last need
additional measurements and an operational transition, not another claim
based on flattened term size.

## How to verify

`make check` is the full local gate; `make doc-check` runs separately.
Use a clean isolated control and the same compiler/OTP for the bounded
`web_view_perf.sh`, `json_perf.sh` and `tui_perf.sh` comparisons. Record exact
build identities and equal-output witnesses; keep timing untraced. The raw
observations and scripts remain private under `/private/tmp/loom-cpu-20261005`.

**Each gate needs its own exit code.** The `cohort-check-full.log` local run
returned zero. A following `tail` is not evidence of that result.

**Darwin skips are not Linux proof.** The local gate explicitly skipped seed,
shipped-server, Linux enforcement and unavailable rust-analyzer fixtures.
`make signoff-remote` builds fresh prerequisites and runs the Linux lanes.
Verify its actual status on the final remote head before merge.

**Natural capacity is not reachable size.** Do not force GC before a retention
claim or insert state walks between matched observation cuts. Census allocations
belong on a separate observer; carrier capacity, allocated blocks, RSS and
physical footprint must stay separate. Read [execution](execution.md) and
[BEAM memory review](../skills/beam-memory-review/SKILL.md) for the remaining
measurement and validation hazards.
