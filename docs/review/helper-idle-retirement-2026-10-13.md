# Idle helper retirement, October 13, 2026

Baseline: `dc70d25d42da531284225bf399f40f82e13539d4` (main, v0.3.2).
Implementation: `0ae4589be`; matched benchmark runner: `6a7a018fb`.
The candidate adds a fixed sixty-second available interval to each helper pool.
A successful checkin starts the interval, checkout cancels it, and expiry uses
the existing orderly retirement path. A pool can shrink to zero. Borrowed
helpers and long-lived executions are excluded. No session eviction, policy
sharing, user configuration or installed-daemon change is part of this work.

## Ownership and races

Each helper's monotone inventory ordinal names a weft timeout. Queries and
checkins of an already-available helper do not refresh it. Weft's timer book
rejects callbacks from an earlier idle interval after cancellation. Separate
helpers and separate pools have independent deadlines. Native exit and the
original monitor's normal helper-owner exit both remain necessary before a
slot can be reused; failed retirement retains custody and capacity.

The existing pool constructor keeps its interface. An internal timer-source
constructor runs the same handlers with recorded callbacks in unit tests.
Production uses the wall clock and the fixed 60,000-ms duration. Tests and
benchmarks may accelerate timer delivery, but that does not measure sixty
seconds of production idling.

## Measurement

Clean baseline broker build completed before any implementation edit, and its
`broker@exec.beam` was saved. The runner renames only the module attribute,
preserves compile attributes and rejects remote self-calls before loading it
beside the candidate. Both versions use the same newly built native helper and
sandbox policy in unique isolated scratch workspaces. No live daemon or session
store is opened. To reproduce, build the baseline broker and save that BEAM,
then build the candidate broker and native helper and run:

```sh
bash scripts/helper_idle_perf.sh "$PWD" /path/to/baseline/broker@exec.beam 1 production
bash scripts/helper_idle_perf.sh "$PWD" /path/to/baseline/broker@exec.beam 2 accelerated
bash scripts/helper_idle_perf.sh "$PWD" /path/to/baseline/broker@exec.beam 3 accelerated
```

Three fresh OTP 29 VMs use one normal scheduler and alternate implementation
order. Each version has 21 warm batches of 2,000 checkout/checkin cycles and
105 actual jailed `/usr/bin/true` calls. Timing includes pool/helper exchange;
command timing ends at a successful exit event. It excludes provider, storage,
broker budget/token admission and the full user-tool round trip. Warm batches
use the production timer source. The Mac ran other work and was not established
as quiet; per-VM command medians change direction, so the pooled difference is
an observation rather than a stable regression estimate.

| Warm measurement | Baseline median | Candidate median |
| --- | ---: | ---: |
| Checkout/checkin cycle, batch average | 13.314 us | 14.554 us |
| VM CPU per cycle | 6.0 us | 7.5 us |
| Pool/helper actor reductions per cycle | 644.67 | 755.45 |
| Actual jailed short command | 15.914 ms | 16.139 ms |

Warm pool bookkeeping adds 1.240 us elapsed per cycle (9.3%) and about 1.5 us
VM CPU (25%). VM CPU is millisecond-quantized over each batch and includes the
driver; it excludes native helper CPU. Actor reductions increase 17.2%.
Command ranges overlap: baseline 14.236–19.780 ms, candidate 14.179–19.851 ms.
The 0.225-ms pooled command difference is small compared with the loaded-host
variation and is not a claim of uniform end-to-end overhead.

### Native memory and replacement cost

Each lifecycle trial borrows four helpers together, runs a real jailed command
on every helper, then returns all four. RSS is sampled only for their exact
owned-port OS PIDs. After expiry, the candidate must show empty inventory and
`spawned = retired = 4`, and all four OS PIDs must be absent. All seven candidate
trials passed both witnesses and returned zero native RSS. Controls retain all
four processes. Summed RSS can double-count shared pages and is not reclaimed
physical RAM or a whole-daemon RSS measurement.

| Lifecycle observation | Baseline | Candidate |
| --- | ---: | ---: |
| Production 60-second trial, four-helper summed RSS | 40.203 MiB retained | 39.969 MiB reclaimed |
| Six accelerated trials, plus production, candidate reclaimed RSS | — | median 39.984 MiB; range 39.547–41.766 MiB |
| Production first command after idle | 16.976 ms, warm helper | 58.540 ms, replacement helper |
| Six accelerated trials, first command median | 18.0165 ms, warm helper | 28.170 ms, replacement helper |

The production timer expires sixty seconds after checkin. Its observed watch
was 59.980 seconds because the watch starts after RSS and synthetic-GC probes;
the baseline control waits 61.001 seconds and retains its four helpers. The
other six trials accelerate only timer delivery to one second while using the
same retirement handlers. They validate repeated drain/regrowth, not production
minute-idle latency. Their candidate cold-command range was 24.360–31.306 ms.
The production pair adds 41.564 ms on the first call; this single loaded-host
pair does not establish a stable cold-start penalty. Keeping the scopes separate
prevents the accelerated median from concealing that production observation.

Only synthetic pool/helper actors receive full GC for the secondary BEAM
measurement. Both versions start at 38,560 allocated actor bytes. The baseline
retains 23,168 bytes after idling and collection; the candidate retains 3,920
bytes in the production trial and 5,792 with the injected source. These are
allocated process bytes after GC, not exact reachable state or OS RSS. The
principal measured saving is native process retirement.

The fixture uses `BestEffort`, with successful zero exit, no timeout/cancellation,
and explicit Seatbelt and network-confinement assertions on macOS. It records
all applied/skip layers and the helper's `degraded` flag (false in these trials).
The policy could not establish the address-space limit; the existing user
process count exceeded its process-limit request; Darwin also reports its
missing PID namespace, subreaper and stable process handle. An initial strict-demand
attempt refused these gaps and is excluded, as is an earlier exploratory driver
run. No existing test or production enforcement requirement was weakened. These
figures measure pool/jail performance, not complete kernel enforcement.

## Live CPU investigation

The running daemon remains `e289d93ab74ef88d35717757f5d6299b94441256`, version
0.2.0, PID 65976. It has neither the encoder nor repeated-register-decode
follow-ups installed. A ten-second Pickglass sample selected the twelve busiest
listed processes by reductions and counted 359 running/runnable observations
out of 10,008 observations. JSON object parsing appeared in about 73% of active
stacks; UTF-8 validation and string parsing were prominent. These are stack
sample shares at reduction safe points, not CPU-time percentages. Native work
is undersampled and stacks are limited to eight frames.

A separate five-second bounded allocation probe of eight selected processes
and the storage/JSON modules counted 154 `do_get_register`, 81
`do_list_registers`, 243 `handle_open` and 1,319 JSON `parse` calls. Root storage
handler allocation was 2,876,016 heap bytes excluding its traced callees; these
are cumulative allocations, not retained memory or RSS. The separately open
register optimization PR #972 addresses repeated decoding; this branch does
not incorporate it or claim its production savings.

An OS process snapshot showed the daemon at 8.4% CPU and one helper at 7.3%,
with WindowServer and browser/UI processes higher at that cut. A later
two-second `top` interval measured the daemon at 17.9% CPU (a fraction of one
core), while the host was 78.4% idle. These cuts do not measure peak utilization. Earlier passive
censuses found 34 helpers with approximately 517 MiB summed RSS. This is a
workload snapshot, not proof all helpers were idle or that all their RSS can be
reclaimed. Summed RSS can double-count shared pages. No live forced GC, restart,
hotpatch or process termination was performed.

## Validation

Seven deterministic idle-pool regressions and the native run → idle retirement
→ replacement → successful run regression passed, then passed again after
mutation checks. Three separately compiled faults were rejected by runtime
assertions: missing idle arming, premature inventory removal and a shared timer
name across helpers. The source was restored byte-for-byte before rebuilding.
Missing checkout cancellation alone is guarded in reachable delivery paths;
its cleanup semantics were verified against the pinned weft timer book rather
than claiming that an equivalent behavior mutation was killed.

The independent correctness review found no actionable issue. The independent
evidence review recomputed every reported median, range and sample count from
the three final VM logs and passed after one platform-skip wording correction.
Format and broker lint checks passed with zero lint errors. The full serialized
`LOOM_TEST_PARALLEL=8 make check` passed with exit code 0, including all 409
broker tests, 4,491 client tests, 1,365 TUI tests, the other packages, Go, lint
with zero errors and configuration checks. Documentation checks passed after
updating source citations moved by this change. Linux behavior and hosted CI
remain separate gates.
The initial strict benchmark refused unavailable platform layers and is not
counted as successful validation. No test was weakened, removed or newly skipped by this change. Existing
platform exclusions remain visible in the full-gate log.
