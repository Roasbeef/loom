# Context inventory CPU work

This report records the October 6, 2026 (America/Los_Angeles) fast-reasoning
workload and the context-inventory optimization based on it. The branch starts
at `8facdb0ea5f8c809fcb9be2e140afea64309f258`, after PR #903. Measurements use
Gleam 1.19.0 and OTP 29.0.5, with four alternating fresh single-scheduler VMs.

## Live attribution

The observed daemon was PID 15488 and terminal client PID 22726. Both installed
launchers report `3644b079059570cf7cc3c7fe98add693bb6adbcc`, before PR #903.
A ten-second interval with all probes detached consumed 11.57 CPU-seconds in
10.10 seconds for the daemon (114.5%) and 3.70 for the client (36.6%). This is
one active workload interval, not a matched installed before/after comparison.

Pickglass sampled the daemon's eight busiest selected processes for ten
seconds at 100 Hz: 488 running/runnable samples and 7,512 waiting. Context
breakdown callers appeared in 195 active samples, reasoning preview in 58,
and completed/pending tool-body preprocessing in 64. Families overlap. Samples
are shares of selected safe-point observations, not elapsed CPU shares; long
BIFs and NIFs are undercounted. The latter two paths are already fixed in #903,
which the installed applications do not yet contain.

A separate five-second allocation cut traced only four application modules on
four selected busy processes. It counted 453 inventory constructions, 211,551
`without_place` label parses and 227,734 `single_line` calls. The cut allocated
102,644,017 words (821,152,136 bytes at eight bytes per word). This is cumulative
allocation in the selected cut, not retained memory, RSS or total-node allocation.
The initial standard-library wildcard was refused; the successful cut excluded
it. Every completed probe detached and unloaded its agent modules.

The client was unnamed and had no profile credential home. Two native samples
show garbage collection and UTF-8/list/binary work but do not resolve the
application's JIT callers. No restart, installation, forced GC, hotpatch or
conversation-state walk was performed. Client caller attribution remains open.

## The change and its ownership

Every web heading render constructs the context panel, including its closed
inventory. The item grouping reads only the board's items and omitted count,
but previously normalized and regrouped all labels on each stream update.
The inventory now has one leaf memo over precisely those two values. The
callback captures no board, actions, model state or transport. Refresh/Compact
handlers, freshness and usage figures stay outside it. There are no nested
memo entries for an outer cache hit to drop, and labels remain text nodes.

The component process and Lustre's cache own the inventory; replacement inputs
replace its cache entry and stopping the component releases the cache. No
process transfer, ETS owner or additional lifetime mechanism was introduced.
Allocation measurements do not establish resident-memory savings.

## Matched synthetic control

The fixture redraws a real Lustre cache 100 times over 470 message items and
28 tool items. Reductions and timing are measured without call tracing;
allocation is measured separately with a private trace session. Control uses
the already compiled context module from `3644b0790`, whose source is
byte-identical to the pinned base's module. Every other loaded module comes
from the same candidate build. The control and candidate therefore differ
only in the context module under review.

| 100 redraws | Control reductions | Candidate reductions | Control words | Candidate words |
| --- | ---: | ---: | ---: | ---: |
| Unchanged panel | 22,322,905 | 247,288 | 22,205,931 | 446,519 |
| Changing heading, stable inventory | 22,322,093 | 240,763 | 22,210,463 | 451,060 |
| Changing inventory each draw | 22,556,753 | 22,538,634 | 22,556,521 | 22,559,921 |

Both alternating pairs repeated these work counts exactly. Stable inventories
remove 98.89% to 98.92% of reductions and 97.97% to 97.99% of allocated words.
Stable redraw timing was 104 to 112 ms in the control and 1.5 to 1.7 ms in the
candidate. The changing-inventory candidate took 115 to 116 ms against 109 ms
for the control: a cache miss does not provide the same gain, and these short
timings do not predict overall application throughput.

Raw initial HTML differs by the one 20-byte invisible `<!-- lustre:memo -->`
marker. Removing only that marker yields byte-identical HTML. Regression tests
exercise the actual patch cache, rather than relying on the initial HTML alone:
unchanged inputs avoid label parsing; labels, token counts and omission changes
refresh the inventory; action availability and headings update independently;
untrusted markup remains text. The new work regression fails against the
control. Forty concurrent runs pass with the trace-session inventory unchanged.

Private synthetic drivers, alternating logs and structured results live under
`/private/tmp/loom-context-perf/`. Live captures use the distinct prefix
`/private/tmp/loom-live-20261006-fast-reasoning-`. No session text was copied into
the synthetic fixture or this report.

## Verification snapshot

The complete web-view component gate passed all 868 tests in 27.36 seconds.
Focused regressions also pass after adding token-only invalidation. The fresh
independent review found one counter-boundary blind spot: initial construction
and the first redraw were built before counting. Both now run inside the
counter; main passes the initial positive assertion and fails the intended
zero-work redraw assertion. The reviewer found no production correctness,
simplification or nearby variant issue.
Package lint and documentation mirrors pass with zero errors. The final client slice review also found no outstanding issue after correcting
the UI dispatch. Publication gates are recorded in the PR after they run; these
local results do not certify an untested later head.

## Configured terminal profiling

The existing `[daemon] profile = true` setting now names terminal clients at
launch as well. Both developer and bundled client shipments carry the existing
`tom` 2.1.0 parser. The client reader checks only the typed profiling key; full
catalogue validation remains daemon-owned. Explicit `--profile` takes precedence.
Help, version, link-printing `ui`/`--ui` and other exit-only commands bypass
reader and credential creation. The independent review caught the previously
misclassified UI command, and exit-only regressions now cover both spellings.

The real-parser launcher regressions pass for enabled, disabled, wrong-typed
and malformed configurations. Quoted ordinary keys work. The existing parser
preserves Unicode escapes in keys literally, so the reader conservatively
rejects an escaped spelling rather than interpreting it differently from the
daemon. This change does not repair that existing parser limitation.

The bundled runtime built and its smoke check passed without host Erlang on
PATH. A synthetic demo client launched with a private HOME catalogue and no
`--profile` flag accepted one Pickglass CLI attachment; the capture completed,
its agent detached and its cookie directory disappeared after client exit.
No user daemon, session or installed application was involved. A ten-run fresh
bundled-reader measurement had a 140.44 ms median (136.99 to 152.21 ms). This is
launch overhead when a configuration may name the profiling key, not ongoing
sampling overhead. Naming the VM starts no trace or sampler. Cookie permissions
and loopback distribution retain their existing boundaries.

The complete terminal component gate passed all 1,242 tests in 29.85 seconds.
The existing release smoke additionally checks the shipped reader's true and
false cases. The final rebuilt-release smoke, full affected gate and exact-head
publication checks are recorded in the PR; earlier component results cannot
certify a later commit.
