# Helper startup optimization follow-up

October 13, 2026. Follow-up to [PR #978](https://github.com/Roasbeef/loom/pull/978)
and the [original concurrency report](helper-concurrency-2026-10-13.md).
The comparison baseline is idle-retirement commit `b28dd654e`; the original
multiplexed stack is frozen at `19ed2fffcc72b6702c89c89a4391980403258c13`.
All experiments use local isolated fixtures. The installed daemon is unchanged.

## Attribution

The broker submits four calls in a median 70 microseconds and eight in 183
microseconds in the diagnostic cohort. Native acquisition initially ran in the
frame-reading loop. A disposable native phase profile of 261 starts measured
median startup of 2.637 ms, including 1.169 ms in Darwin tracker initialization,
0.788 ms in fork/start, 0.332 ms in planning and 0.164 ms in pipe/environment
setup. These instrumented phase timings identify work; they are not production
latency percentiles.

Tracker initialization read the full process table twice: once as a preflight
and again for initial capture. The child start gate remains closed through both.
Reusing the successful preflight for capture removes a duplicate kernel read
without caching a snapshot across executions or changing the tracking interval.
The isolated tracker benchmark measured 750.186 → 368.198 microseconds,
1,901,539 → 975,704 allocated bytes and 22 → 19 allocations per initialization.
These are tracker-only results, not per-tool or total-daemon allocation savings.
Raw measurements are `/private/tmp/loom-tracker-start-{baseline,candidate}.log`;
the baseline is pinned tracker source from `19ed2fff`, and the candidate changes
only initial snapshot reuse. The committed `BenchmarkProcessTrackerStartup`
reproduces startup/join allocation on Darwin with `go test ./internal/jail
-run '^$' -bench '^BenchmarkProcessTrackerStartup$' -benchmem -benchtime=500x
-count=3` from `packages/sandbox`. Baseline reproduction overlays the pinned
tracker source into the same package. The phase-profile raw log is
`/private/tmp/loom-helper-native-start-profile.log`; that disposable overlay
adds stderr timing around the baseline acquisition stages.

## First optimization cohort

Three rotated three-way rounds compared the complete original, frozen
multiplexed and snapshot-reuse stacks in fresh VMs. Four-slot batch medians were
25.701 / 36.500 / 28.705 ms; eight-slot medians were
30.029 / 31.464 / 27.478 ms. The candidate improved four-slot batches relative
to frozen multiplexing in every round, but retained a 9–12% gap against separate
helpers. Host load varied from 20.15 to 62.45, and eight-slot comparisons against
the original were mixed. The candidate retained about 71% lower summed helper
RSS. These results motivated overlapping native acquisition rather than adding
more helper processes.

Raw logs are outside the repository:
`/private/tmp/loom-helper-concurrency-threeway-{1,2,3}.log` and
`/private/tmp/loom-helper-concurrency-threeway-summary.txt`.

## Concurrent acquisition cohort

The bounded startup worker reserves its registry entry before acquisition.
Starting, live, cleanup and reporting obligations all count against four slots.
Early stdin coalesces lazily within the existing 16-MiB limit; EOF and byte order
transfer before later live input. Early cancellation reaches the real acquired
jail, and shutdown joins starting workers as well as live jails. Cancellation
can still permit side effects before acquisition returns; no no-effect promise
is made.

Three further rotated rounds used 15 submitted parallel batches per fixture,
with the same one/four/eight-slot comparisons. Pooled batch medians were:

| Slots | Separate helpers | Original #978 | Concurrent acquisition |
| --- | ---: | ---: | ---: |
| 4 | 25.984 ms | 31.184 ms | 26.964 ms |
| 8 | 34.484 ms | 37.680 ms | 31.835 ms |

Concurrent acquisition improved pooled medians by 13.5% and 15.5% relative to
original #978. Eight-slot batches were faster than separate helpers in every
round. Four-slot comparisons varied (+23.7%, +6.3%, −19.9%), and their candidate
p95 was 33.375 ms versus 28.698 ms for separate helpers. A 102.927-ms candidate
outlier prevents a claim that all overhead disappeared.

This version also retained more helper RSS: four slots used 20,496 KiB versus
17,440 KiB for original #978 and 54,144 KiB for separate helpers; eight used
42,432 / 34,368 / 112,288 KiB. Thus summed helper RSS savings were approximately
62%, rather than the earlier approximately 71%. The following fresh-snapshot experiment isolates that transient heap cost;
this asynchronous version is an intermediate comparison, not the final choice.

Raw logs:
`/private/tmp/loom-helper-concurrency-final-async-threeway-{1,2,3}.log` and
`/private/tmp/loom-helper-concurrency-final-async-threeway-summary.txt`.
There are 27 cold, 189 warm, 945 sequential, 405 parallel, 27 memory, 135 startup
and 27 close records. Every admission, output, exit, overlap, enforcement and
native-disappearance assertion passed. RSS excludes payloads and the driver and
can count shared pages repeatedly. Forced collection applies only to synthetic
BEAM actors; no native or installed-daemon GC is forced.

## Correctness and CI

The first hosted run exposed a Linux-only stdin fixture that omitted the
protocol-4 target. It now names execution 2. The Linux held-terminal regression
also demonstrated that holding the registry mutex over a write blocked other
spare slots. A portable regression now catches the same bug. Reporting entries
retain custody until their writes return, with no registry mutex held over I/O;
only full-capacity admission waits for a reporting obligation before retrying.
The original full-capacity immediate-refill regression remains intact.

The macOS e2e job failed before assertions while fetching Hex's `pc` plugin;
artifact upload also reported DNS `ENOTFOUND`. This is recorded separately from
the concrete Linux assertions. The updated head must pass fresh hosted checks;
no failed gate is waived.

Independent changed-slice review found no reachable correctness issue in
snapshot reuse, pending input/cancellation transfer, acquisition reservation,
spawn-failure reporting, or shutdown custody. Focused native race regressions
passed. The final capture-mutex review also found no reachable issue in lock ordering,
freshness, independent ledgers or shutdown. Final full gates are recorded below;
hosted checks must be bound to the pushed head.

## Bounding fresh snapshot allocation

A disposable dose-response experiment kept four launch workers, fresh reads and
the requested 20-ms interval, while bounding only overlapping kernel-table
acquisition and traversal. Three rotated rounds compared unrestricted capture,
a bound of two and a bound of one. Every VM exited zero, without forced GC.

| Pooled metric | Unrestricted | Two captures | One capture |
| --- | ---: | ---: | ---: |
| Four-slot helper RSS, KiB | 20,880 | 19,632 | 16,816 |
| Eight-slot helper RSS, KiB | 41,936 | 36,000 | 33,648 |
| Four-slot batch, ms | 21.271 | 21.396 | 21.406 |
| Eight-slot batch, ms | 24.143 | 24.058 | 24.280 |

Observed overlapping capture scopes fell from peaks of four–seven to exactly
two or one. Four-slot shutdown HeapSys fell from roughly 19.86 MB to 15.86 MB to
11.63 MB. Cumulative allocation stayed around 346 MB: the bound controls live
buffer overlap and retained runtime footprint, rather than skipping capture
work. Shutdown MemStats were sampled after ordinary joins; live RSS was sampled
behind the payload barrier. These are distinct measurements.

One-capture batch differences versus unrestricted capture were +1.67%, +1.30%,
−0.55% for four slots and +2.91%, −0.43%, −5.35% for eight. This did not show a
repeatable material latency penalty. A process-local mutex is therefore the
smallest production implementation: acquire it around a fresh table read and
captureTable, then release it. Each tracker keeps its own ledger; no snapshot
is cached or shared across capture requests. The lock order is capture mutex
then tracker mutex, and shutdown holds neither while joining. All four launch
workers, policy planning and forks remain concurrent.

Raw dose-response logs:
`/private/tmp/loom-native-snapshot-threeway-{uncapped,cap2,cap1}-{1,2,3}.log`.

## Final production comparison

Three rotated rounds compare complete stacks in fresh VMs, with 15 parallel
samples per slot count and version per round. All actual binaries and the
active toolchain report Go 1.26.8; the host is Darwin arm64, OTP 29 with one
BEAM scheduler. Host load ranged from 6.70 to 11.41.

| Pooled median | Slots | Separate helpers | Frozen #978 | Final |
| --- | ---: | ---: | ---: | ---: |
| Parallel batch, ms | 4 | 21.055 | 24.883 | 21.056 |
| Parallel batch, ms | 8 | 24.831 | 27.909 | 23.343 |
| Sequential command, ms | 4 | 18.970 | 19.348 | 18.873 |
| Sequential command, ms | 8 | 19.116 | 19.175 | 18.136 |
| Cold first batch, ms | 4 | 49.828 | 37.474 | 33.543 |
| Cold first batch, ms | 8 | 73.273 | 44.887 | 40.166 |
| Summed helper RSS, KiB | 4 | 53,712 | 16,416 | 16,336 |
| Summed helper RSS, KiB | 8 | 109,312 | 31,408 | 34,192 |
| Actor post-GC bytes | 4 | 33,672 | 15,024 | 15,024 |
| Actor post-GC bytes | 8 | 63,424 | 27,272 | 27,272 |

Final parallel medians improve 15.38% and 16.36% against frozen #978. Against
separate helpers, four slots are effectively equal (+0.005%) and eight slots
are 5.99% faster. Four-slot per-round comparisons against separate helpers are
-0.64%, -0.15%, +1.69%; eight-slot comparisons are -7.01%, -2.22%, -8.29%.
This removes the repeatable slowdown in this fixture, not a general guarantee
of zero overhead. All three rounds improve against frozen multiplexing at
both slot counts.

Helper RSS remains 69.59% / 36.50 MiB lower at four slots and 68.72% / 73.36 MiB
lower at eight slots than separate helpers. Against frozen multiplexing,
four-slot RSS is 0.49% lower, while eight-slot RSS is 8.86% / 2.72 MiB higher.
The bound recovers most of the intermediate asynchronous version's footprint,
with that remaining eight-slot cost stated explicitly. Native counts remain
one/four/eight versus one/one/two. These are summed helper RSS measurements,
not total application or daemon memory.

Four-slot nearest-rank p95 is 23.092 / 29.036 / 22.868 ms; maxima are
23.495 / 30.862 / 23.253 ms. Eight-slot p95 is 27.318 / 36.342 / 24.890 ms;
maxima are 33.680 / 48.155 / 28.420 ms. One frozen four-slot sequential sample
completed in 3.107274 seconds without timeout or cancellation. Its cause is
unclassified and the raw range retains it; the final four-slot sequential
maximum was 21.825 ms.

All 27 cold, 189 microbatch, 945 sequential, 405 parallel, 27 memory, 135
startup and 27 close records passed. Assertions cover admission, unique
routing, barriers, zero exits, no timeout/cancellation, enforcement, expected
native counts and native PID disappearance. Microbatch CPU counters cover only
BEAM threads/driver, excluding native and payload CPU, so no total CPU saving
is claimed. There is no end-to-end distributed RPC or Linux latency result.

Reproduce with `scripts/helper_concurrency_perf.sh RUNNER_ROOT ORIGINAL_ROOT
FINAL_ROOT ROUND FROZEN_ROOT`, for rounds 1, 2 and 3. Build each complete root
against its own source and retain its helper/broker pair; ORIGINAL_ROOT is
`b28dd654e`, FROZEN_ROOT is `19ed2fff`, and FINAL_ROOT is this implementation.
The runner rotates all three versions and records platform, toolchain and
actual binary versions/hashes before each fresh VM. No installed daemon is used.

Raw logs: `/private/tmp/loom-helper-concurrency-production-threeway-{1,2,3}.log`
and `/private/tmp/loom-helper-concurrency-production-threeway-summary.txt`.
Final native SHA256 is
`b141ed54d8007817795d2739d0546ef72749da17dfd9f696c9c636446833a4af`;
broker SHA256 remains
`962a9b06ad5c1199662e454c41e2c3911e38027271d98dd67ed9bc3a90e8611f`.


## Final local validation

Frozen final source passes `go test -race ./...` across the native helper
packages (direct exit 0, `/private/tmp/loom-native-final-full-race.log`).
Independent source and evidence reviews found no remaining actionable issue.
The evidence review recomputed the final statistics from all three raw logs.

The first final `LOOM_TEST_PARALLEL=8 make check` exited 2, with one client
failure and 4,490 client passes: the LSP observation fixed-deadline test expired
waiting for a cancellation notification. Its fake in-VM transport never
acquires a native helper, so the changed native paths are unreachable there.
All 17 observation tests passed focused reproduction at unchanged deadlines
and parallelism (direct exit 0). The fixture can expire its whole-collection
150-ms budget before its silent request becomes pending, but the first log
does not prove that caused this occurrence. The cause remains unclassified.
No assertion or timeout was changed. Raw logs are
`/private/tmp/loom-helper-startup-full-check.log` and
`/private/tmp/loom-helper-startup-lsp-repro.log`.

The unchanged `LOOM_TEST_PARALLEL=8 make check` rerun passed direct exit 0,
including all 4,491 client tests, remaining packages, native checks and lint.
Raw log: `/private/tmp/loom-helper-startup-full-check-rerun.log`.
Final documentation checking also passed exit 0 with zero errors and existing
warnings: `/private/tmp/loom-helper-startup-final-doc-check.log`.
Fresh hosted CI remains a separate gate on the pushed head.

## Hosted census follow-up

Run [38493712617](https://github.com/Roasbeef/loom/actions/runs/38493712617)
on `03cac66dbb651a6e8365714bc2d6b0fa0db83a7a` reported success for every substantive Linux
and macOS job. The advisory macOS check hid an underlying test cancellation,
detailed below. Its Linux aggregate failed the census on the existing shipped
deployment-status enforcement skip. The ordinary runner lacks the enforcement
prerequisite; this was not a native assertion failure or a diagnosed flake.

The CI-only fix from [PR #979](https://github.com/Roasbeef/loom/pull/979),
original commit `0d2b9405a`, is reused here. It pairs the precise ordinary-runner
declaration with the exact deployment-status fixture in the delegated Linux
jail job. That step joins the verified cgroup and uses an empty skip allowance,
so both executor-up/down assertions must execute. Its log is always uploaded.
No provider changes or fixture assertion changes are included.

Independent review found no actionable issue. Replaying the four actual Linux
check logs fails with the old policy and passes with the corrected policy.
Empty skip allowance still rejects those skipped inputs; removing the deployment
marker makes the new declaration fail as stale. Controls are preserved under
`/private/tmp/pr978-census-controls/`. Workflow YAML and shell syntax passed,
as did all three skip-reporting self-tests.

After building an isolated server shipment, the real local deployment fixture
passed exit 0 and its empty-allowance census passed exit 0:
`/private/tmp/pr978-deployment-enforced-local-ready.log`. An earlier local attempt
failed because the server shipment did not yet exist; its prerequisite error is
retained in `/private/tmp/pr978-deployment-enforced-local.log`. The installed
daemon was not rebuilt or restarted. Native source is unchanged from the full
gate and benchmark; fresh hosted CI must verify the new workflow head.

## Advisory test-peer cleanup

The successful advisory macOS job conclusion did not establish a passing
underlying suite. Its downloaded `check-macos.log` ended with broker test-group
cancellation and exit 1: 388 tests passed before a linked controlled peer
crashed. After sending synthetic `WireClosed(0)` on shutdown, the peer
unconditionally recursed, then its five-second idle receive assertion fired
while unrelated retirement tests were running. This is a concrete fixture
ownership defect, not a native helper regression or a waived test failure.

The peer now returns normally on shutdown. All four existing multiplex tests
retain its original monitor and require a specific normal `ProcessDown` before
returning. Links, receive deadlines and existing behavioral assertions remain.
Independent changed-slice review found no actionable issue; all four focused
tests passed unchanged concurrency. A private compiled mutant restoring the
old recursion fails the new monitor witness within one second (exit 1), while
the shared source and build artifacts remain corrected. Mutant log:
`/private/tmp/pr978-peer-mutant/result.log`; focused log:
`/private/tmp/pr978-peer-cleanup-focused.log`.

A preliminary direct Erlang evaluation reproduced the idle crash in its log
but still exited zero because its evaluation process traps exits. That probe
is diagnostic evidence only, not a failing regression control. The compiled
monitor-witness mutant above is the negative control.

The first full gate after this correction passed broker but failed the client
web-operator page's existing 20-second connection wait, with 4,490 other client
passes. Focused unchanged reproduction passed in 169 ms (exit 0), and the
cause remains unclassified. Logs: `/private/tmp/pr978-peer-cleanup-full-check.log`
and `/private/tmp/pr978-web-operator-repro.log`. No timeout or assertion changed.
The unchanged full `LOOM_TEST_PARALLEL=8 make check` rerun passed direct exit 0,
including all 419 broker and 4,491 client tests, remaining packages, native checks
and lint: `/private/tmp/pr978-peer-cleanup-full-check-rerun.log`. Native production source and
the benchmarked helper/broker binaries are unchanged. Fresh hosted validation
must inspect underlying advisory results as well as job conclusions.

## Integrated validation checkpoint

The concurrency branch now includes merged register decoding from main
`e86d6fddd` and the updated idle-retirement branch. Production helper, broker,
protocol and benchmark sources remain unchanged from the measured implementation;
independent integration review verified that storage matches main exactly.

The integrated full run's LSP cancellation fixture again expired before its
expected notification. The fixture now establishes its server/document before
the unchanged 150-ms deadline, collects only the positioned reference target,
and requires that request was seen. Cancellation, no shutdown and subsequent
shared-lease success remain asserted. All 17 focused observation tests and
independent changed-slice review pass. Raw logs are
`/private/tmp/pr978-main-integrated-full-check.log` and
`/private/tmp/pr978-lsp-precondition-focused.log`. Earlier failures remain
recorded; no production deadline or interface changed.

The branch also carries #975's reviewed held-provider pre-admission and advisory
scheduling corrections, recorded in its [report](helper-idle-retirement-2026-10-13.md).
The delayed-admission positive/old-bound comparison proves that fix without
relaxing the overall fixture, hold or recovery bounds. Fresh complete local
and hosted gates are required for the final integrated head before landing.

The full `LOOM_TEST_PARALLEL=8 make check` with `LOOM_BOOTSTRAP_E2E_SERVER`
set to the isolated #978 shipment, the dummy fixture provider key, and the same
advisory observation policy passed direct exit 0 on the integration through
`2e712451f`. This exercises shipped fixtures alongside the package tests, rather
than relying on their unset-server declines. Log:
`/private/tmp/pr978-final-real-server-full-check.log`. Later current-main
Responses integration remains a separately checked slice and fresh hosted gate.
