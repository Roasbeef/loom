# Current handoff

This edition is baselined on source
`cc9ec305da544c45609c959ed933d797930cac16` and the render implementation
`669a8274e`, followed by generated digests at `b6f0a54e`, measured on
October 6, 2026 (America/Los_Angeles). Work is isolated on
`codex/perf-live-render-20261006`. The source, installed identities, local
validation and GitHub state below were checked during this pass.

Read [the live investigation](review/beam-render-2026-10-06.md) for workloads,
counters, limits and private artifact locations. The
[October 5 investigation](review/beam-cpu-2026-10-05.md) records the previous
optimization; its gate results describe that older source. Rewrite this
handoff after the next body of work.

## Where the tree is

| Body of work | Verified state |
| --- | --- |
| Previous optimization | [PR #873](https://github.com/Roasbeef/loom/pull/873) is merged at `bf4334140911296e3f393482f8d5c5c7c454e764`. The previous edition's open-PR status and merge instructions are obsolete. |
| Installed applications | Daemon PID 53549 and active terminal PID 67235 embed `11454cba77ca96acc6b3be85f1da72ba469dd976`, before #873. Repeated completion-table work is consistent with that older build; it does not disprove the merged memo. |
| New render fix | Done/Pending step bodies avoid unused refusal preprocessing. Reasoning preview blankness checking now runs inside its existing text-keyed leaf memo. Failed-step rendering retains its work and behavior. |
| Measurement | A bounded Pickglass allocation probe attributes 56.5% of matched cumulative words to step bodies and previews. Large-text unchanged-render fixtures remove about 99.97% and 99.75% of reductions respectively. These are fixture results, not installed CPU or RSS savings. |
| Regression coverage | All 811 web-view tests pass sequentially and at parallelism eight. Other runners report 265 web-client, 47 focused UI-socket, 2,945 full client and 97 conformance passes. The three new regressions fail against the original modules and pass against the candidate. Existing shipped-server and seeded LSP skips remain; see the investigation. |
| Static validation | Lint returned zero errors and 2,175 warnings; final doc-check returned zero errors and 196 warnings. Generated-client and prelude checks pass. Changed Gleam files pass formatting. |
| Remaining gate | `make check-web_view` fails on nine unchanged formatter files. A whole-tree census finds 119 unchanged files. A private formatter-only patch is prepared; the owner has been asked whether to include the separate scope. The complete affected gate is not green. |
| Independent review | One fresh report-only review found no actionable issue, passed 70 concurrent regression executions, and verified profiler cleanup on callback failure. |
| Hosted validation | No candidate branch has been pushed and no candidate CI has run. The baseline CI run [37538889208](https://github.com/Roasbeef/loom/actions/runs/37538889208) failed in the macOS gate's Skip census step; this is not a candidate result. |
| Publication and installation | The candidate is committed locally. It has not been pushed, opened as a PR, installed, or measured in the running applications. |

The previous edition left the daemon's installed revision unknown. Reading
both launchers now pins it independently of the Pickglass capture. No
application was restarted, hotpatched or forced through collection. The
client node is unnamed; native sampling supplies partial client evidence,
but distributed Pickglass attachment requires a profiled client launch.

## What to do next

1. Resolve the formatter scope and run the complete affected gates against
   this pinned source. The prepared patch is
   `/private/tmp/loom-live-20261006/formatter-only.patch`. Exit: each required
   command returns its own zero status, or its unresolved failure is recorded
   without calling the branch ready. Keep formatter repair in a separate
   prerequisite commit if the owner chooses it.
2. Publish only when directed, with the investigation's fixture limits and
   inherited gate failures in the description. Exit: exact-head hosted checks
   and the affected selector's review/signoff requirements are satisfied.
3. Follow [updating](updating.md) for an approved shipment and graceful daemon
   transition. Both the merged previous optimization and this candidate need
   an installed identity check. Terminals retain their old client tree until
   reopened. Exit: the chosen releases are running and the same active, idle
   and released workloads are measured before and after the transition.
4. Profile a client started with its profiling option, then select the next
   reachable cost from its caller and allocation evidence. Exit: a bounded
   matched observation identifies the next operation without inferring a
   cause from opaque native JIT stacks.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Render ownership.** Keep memos at leaves and project closure inputs before
construction. A value used inside a memo must participate in its references.
Lustre 5.7.1 discards nested entries when an outer memo hits. The
[previous investigation](review/beam-cpu-2026-10-05.md) records editor-refusal
invalidation and the leaf-cache regressions; the
[current investigation](review/beam-render-2026-10-06.md) records preview
invalidation and its empty-placeholder serialization difference.

**Dispatch before preparation.** A Done or Pending tool step does not need a
refusal sentence. Dispatch on standing before assembling it. Failed steps
keep their whitespace, escaping, ordering and fallback behavior. The new
`render_work_test` regressions measure the work boundary rather than elapsed
time thresholds.

**Capacity and ownership.** Flat size, process allocated capacity, cumulative
allocation, RSS and physical footprint are distinct metrics. The two live
cuts observed different activity on the same old build and establish neither
a leak nor candidate savings. Follow
[daemon memory evidence](design-notes/daemon-memory.md) and
[BEAM memory review](../skills/beam-memory-review/SKILL.md) for attribution.

**Verification.** [Execution](execution.md) owns gates and signoff. A suite
run directly can establish test coverage while its package gate remains red
on formatting. Every command needs its own exit code; a successful log tail
is not evidence that the preceding gate passed.

## Deliberately open

- Installed resident-memory savings and the remaining ownership census in
  [#454](https://github.com/Roasbeef/loom/issues/454) remain unmeasured. The
  issue was checked open during this pass.
- SQLite bursts remain workload-dependent and outside the two render changes.
- Full client attribution needs a named profiling node and a matched workload.
- Formatter scope, full affected validation, publication and installation
  remain pending.

None of these is unfinished work somebody forgot. The measurement gaps need
matched installed workloads; source allocation reductions do not close them.

## How to verify

Run `make affected BASE=cc9ec305d` to reproduce the selector. It requires fmt,
lint, doc-check, prelude-check, client-check, and the web-view, web-client,
client and conformance package gates; it reports signoff not required for
this change. `make check` remains the full local gate.

The private fixture runner and alternating control/candidate logs live under
`/private/tmp/loom-live-20261006/`. Reuse the same toolchain and compiled
dependencies, keep timing untraced, and compare complete rendered output.
Blank previews differ by an empty 20-byte memo placeholder; they display no
content or handler, and transitions through the real patch cache are tested.

**Samples are not elapsed CPU shares.** Pickglass stack sampling is biased
toward reduction safe points; the allocation window covers selected processes
and module patterns. Neither reports whole-application savings.

**Natural capacity is not reachable size.** Avoid forcing collection or
walking state between matched observation cuts. Keep VM allocation, binary
payload, allocator capacity and OS residency separate. Read
[execution](execution.md) for the remaining validation hazards.
