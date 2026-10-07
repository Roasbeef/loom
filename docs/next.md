# Current handoff

This edition covers the CPU optimization in [PR #903](https://github.com/Roasbeef/loom/pull/903),
rebased onto `3644b079059570cf7cc3c7fe98add693bb6adbcc` on October 6, 2026
(America/Los_Angeles). The render implementation is `cc1f2e3ee`, its rebuilt
stylesheet is `1f2fbaaca`, the separately approved CI repair is `32fe4abbd`,
and the snapshot implementation is `f87ad3333`. Work remains isolated on
`codex/perf-live-render-20261006`, under `.worktrees/perf-live-render-20261006`.
The original checkout and its unrelated files remain untouched.

Every result below is tied to the revision or publication snapshot that was
checked. Read [the snapshot CPU report](review/beam-transfer-cpu-2026-10-06.md)
and [the render report](review/beam-render-2026-10-06.md) for the new-main
controls, earlier live attribution and historical gate failures. Rewrite this
handoff after the next body of work; GitHub carries the final PR verdict.

## Where the tree is

| Body of work | Verified state |
| --- | --- |
| Render implementation | Done/Pending avoid unused refusal text. Settled preview blankness uses the existing text-keyed leaf memo. All 866 current web-view tests pass. |
| Snapshot implementation | Direct UTF-8 byte sizing preserves conservative JSON admission. All 16 transfer tests pass, including the three lineage tests introduced upstream. |
| Remeasurement | A newly compiled control at `3644b0790` alternates twice with the rebased candidate in fresh OTP 29 VMs. Full-start reductions fall 71.36% for small strings, 90.63% ASCII, 78.27% Unicode and 7.99% to 8.19% C0 controls. Every transfer fingerprint matches. |
| Render work | Done/Pending reductions fall about 99.97%, settled reasoning 99.75% and blank reasoning 98.08%. The counts repeat exactly; nonblank output fingerprints match. Blank output retains its invisible 20-byte memo placeholder. |
| Regression controls | Current-main modules fail each of the three render work tests and the snapshot work test. Main makes 81,931 Unicode decoder calls; the candidate makes zero. The independent boundary oracle passes both implementations. |
| Trace ownership | Forty concurrent CPU regression runs and exception cleanup leave the trace-session inventory unchanged. The fresh independent review also ran thirty render and twenty transfer regressions concurrently. |
| CI prerequisite | The consuming grep repair preserves successful existing declarations under pipefail. All eighteen selector/runner tests pass. No test, assertion, deadline or skip declaration has changed. |
| Fresh independent review | One report-only pass over `3644b079..3a08106fc` found no actionable invariant, simplification or nearby variant issue. It checked the rebase integrations and stylesheet digests. |
| Current local full gate | The full affected command returns its own make status 2 (underlying 124) in 112 seconds: static and server preparation pass, then the unchanged 20-second Python-suite deadline expires in upstream signoff fixtures because this Mac lacks `flock`. Its census saw no package SKIP marker and does not certify the package tests. |
| Static checks | The rebased source passes formatting, generated assets, prelude, lint and doc graph: zero lint errors with 2,195 warnings; zero doc-check errors with 194 warnings before this rewrite. The final prose is checked separately before publication. |
| Previous published head | `cc52ef8826641184b8b8e168d6650c823f191fcb` passed exact-head Linux signoff and every hosted test job in [run 37552798786](https://github.com/Roasbeef/loom/actions/runs/37552798786). Its macOS fan-in failed solely on two existing undeclared procfs fixture omissions. |
| Rebased publication | PR #903 is out of draft at the owner's direction. The rebased head's hosted checks and restricted Linux signoff are pending at this publication snapshot. The old head's success cannot certify the new one. |
| Platform omissions | The owner has been asked to approve the two Darwin-only procfs declarations. They do not alter either test or the required Linux execution. No approval has arrived at this snapshot. |
| Installation | No candidate shipment, live restart or installed comparison was performed by this work. Installed CPU and resident-memory savings remain unmeasured. |

The previous edition's claims that no PR, hosted checks or Linux signoff had
run are now false. They described an earlier local stage. Its 811 web-view
tests and 13 transfer tests also predate the upstream reasoning and lineage
changes; the fresh results above replace them. The three upstream lineage
tests were retained during rebase, as was main's reasoning-row implementation.
The stylesheet was regenerated rather than taking an old asset over new sources.

The original live probes observed daemon PID 53549 and terminal PID 67235 on
installed revision `11454cba77ca96acc6b3be85f1da72ba469dd976`, predating the
previous merged [PR #873](https://github.com/Roasbeef/loom/pull/873). Those are
measurement-time identities, not a claim that a later user-initiated restart
could not have occurred. Pickglass attributed the reachable quoting caller;
its later quiet stack cut observed only 15 running samples out of 8,000.
The native helper sample mostly waited. Neither quiet cut justified a broad
CPU hotspot or busy-loop claim.

Two earlier full client runs failed an unchanged gateway lifecycle regression;
later full runs and the previous exact-head Linux signoff passed. The cause
remains unresolved. No assertion or timeout was weakened. Historical package
passes, local wrapper failures, hosted tests and Linux signoff remain separate
pieces of evidence in the two reports.

Main's previous handoff covered working-directory and LSP work in #889. Its
current source and design contract are preserved by this rebase. Historical
claims about that PR and other lanes were outside this performance pass;
refresh their own issue and branch before continuing them. The directory and
LSP ruling lives in [protocol-change/068](../protocol-change/068-working-directories-and-lsp-scope.md),
not in a status snapshot.

## What to do next

1. Complete PR #903's exact-head verification and merge under the owner's
   authorization. Exit: resolve the full local gate and platform census,
   obtain the rebased head's Linux signoff through the restricted endpoint,
   and verify current checks before merging. The separate consuming-grep
   approval does not authorize a new platform declaration.
2. Follow [updating](updating.md) for a separately authorized installation.
   Exit: verify installed revisions and compare the same active, idle and
   released workload before and after. Source fixture gains do not close
   installed memory measurement [#454](https://github.com/Roasbeef/loom/issues/454).
3. Obtain a named profiling client and a matched active workload for the next
   CPU pass. Exit: bounded caller evidence identifies reachable work. SQLite
   bursts and control-heavy serialization remain outside this private size walk.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Snapshot admission.** Count UTF-8 bytes without Unicode lists, but retain
the conservative budget. Every C0 byte costs six even when JSON uses a short
escape. The serializer and complete-string traversal remain unchanged. The
boundary oracle and work counter in `transfer_test` enforce both properties;
[the snapshot report](review/beam-transfer-cpu-2026-10-06.md) records controls.

**Render ownership.** Leaf memos own their dependencies. Every captured input
participates in its references, and unchanged text performs no preview trim or
Markdown parse. Lustre 5.7.1 drops nested entries when an outer memo hits;
[the render report](review/beam-render-2026-10-06.md) records why the memo
remains at the leaf and how blank/text transitions are verified.

**Dispatch before preparation.** Done/Pending have no refusal sentence to
display. Dispatch first. Failed retains whitespace, escaping, row order and
fallbacks. `render_work_test` measures the removed work boundary without elapsed
time assertions.

**Signoff ownership.** [Execution](execution.md) owns the gate. The restricted
SSH request is data, not an uploaded remote shell. The installed driver alone
posts a verdict after testing the exact published commit. Never hand-post a
status or bypass the gate to turn an earlier result into new-head signoff.

**Measurement boundaries.** Flat size, process capacity, allocation, RSS and
physical footprint are distinct. Different activity on one old build proves
neither leaks nor savings. Follow [daemon memory evidence](design-notes/daemon-memory.md)
and [BEAM memory review](../skills/beam-memory-review/SKILL.md).

## Deliberately open

- Installed CPU, RSS and retained ownership in #454 remain unmeasured.
- SQLite bursts, control-heavy serialization and direct client attribution
  need named, matched workloads.
- The intermittent gateway-test cause remains unresolved.
- Rebased exact-head publication checks, platform policy approval and merge
  remain pending at this publication snapshot; read PR #903 for later results.

None of these is unfinished work somebody forgot. Evidence gaps need matched
workloads; fixture reductions do not supply installed measurements.

## How to verify

Use a non-login shell with
`PATH=/Users/roasbeef/.local/lib/loom/server/bin:/opt/homebrew/bin:$PATH`.
Verify Gleam 1.19.0, OTP 29.0.5 and Homebrew `rg`. The entire branch selects the
full gate with `make check-affected BASE=3644b0790` because it includes CI
machinery. Each gate must be judged by its own exit code.

After publishing HEAD, run:

```sh
LOOM_SIGNOFF_HOST=gilgamesh-signoff SIGNOFF_PARALLEL=8 make signoff-remote
```

The restricted endpoint accepts only the validated signoff request. Optional
`SIGNOFF_ARGS=--dry-run` tests without posting. Do not use the ungated remote
mode or issue arbitrary shell requests to this endpoint.

Private new-main controls, four alternating runs, exact result fingerprints,
negative controls and trace-cleanup logs live under
`/private/tmp/loom-live-20261006/` with `rebase-` or `-rebase-` in their names.
The fresh full affected log is `/private/tmp/loom-live-20261006-rebase-affected.log`.
Original controls and live attribution remain in the reports' earlier records.

**Application-private tools can fall outside fixture grants.** Homebrew `rg`
is the supported path for the intentional Seatbelt test. Select the pinned
compiler rather than repairing files for an older formatter.

**Samples are not elapsed CPU shares.** Pickglass samples at reduction safe
points; selected process/module allocation is not whole-application CPU.

**Linux gate fixtures need Linux locking.** The new `test_signoff_gate` fixtures
reach the gate lock on this Mac without `flock`; its lock-wait loop then runs
until the test deadline. The named reproduction and bounded stack dump are
preserved. A separate 120-second diagnostic was stopped with status 143 after
per-test lock timeouts; it was not a passing gate. The previous integrated
head also hit the unchanged aggregate deadline; its nine deadline-wrapper tests
passed in isolation. These are distinct failures. Keep complete evidence and
run the current gate on Linux. Read [execution](execution.md) for the rest.
