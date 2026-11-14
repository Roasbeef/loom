# Session hot-path measurements, November 4, 2026

Source: `ae8d2539f5ee06b86ec5a53e0d1c7815f2e3ed18`, branch
`perf/session-hot-paths`, isolated sibling worktree. This run completes the
corrected full workloads that were left pending in #1150, #1151 and #1152.
It changes no production code, interface or durability policy.

## Method and evidence

From `packages/runtime`, the following commands ran serially, each exiting 0:

```sh
gleam run -m pending_read_bench
gleam run -m register_read_bench
gleam run -m commit_cost_bench
```

The host snapshot reported Darwin arm64, 16 CPUs, 128 GiB RAM and Gleam
1.19.0. A post-run Erlang probe reported OTP 29 / ERTS 17.0.5 and 16 online
schedulers; individual benchmark VM scheduler configurations were not recorded.
Observed post-run UTC was 2026-11-04T02:12:09Z. The one-minute load snapshots ranged from 8.10 to
11.19, substantially below the earlier 120+ load, but this was not an idle
or CPU-isolated host. Compilation occurred before the in-module timers.
All benchmark value, sequence, leaf, branch and count assertions passed.

The [measurement data](data/session-hotpaths-2026-11-04.json) retain every
pending/register sample, commit-case elapsed time and integer-millisecond
latency histogram, environment, exit status and load snapshot. Histogram
counts sum to 202,800 commit samples across 24 cases. Histograms preserve
the distribution, not temporal sample order. Quantiles use nearest rank
(`ceil(n*p)-1`, zero based); throughput is commits divided by case elapsed
time. Two independent calculations agree on the reported values.

Full stdout/stderr and the tested summary/export programs remain local under
`.notes/measurements/session-hotpaths-2026-11-04/`. The committed data let the
summary quantiles be recomputed without those scratch logs. This is one
serial invocation of each benchmark, not independent host-isolated trials.

## Pending-entry scope has a crossover (#1150)

Each cell below is median milliseconds per 50 loader iterations, across seven
samples. Each loader either scans/decodes the namespace or fetches its owned
keys individually. SQL here means SQLite `:memory:`, not file durability.

| Unrelated | Owned | Memory scan / point | SQLite scan / point |
| ---: | ---: | ---: | ---: |
| 0 | 0 | 0 / 0 | 1 / 0 |
| 0 | 1 | 0 / 0 | 2 / 1 |
| 0 | 32 | 1 / 6 | 7 / 20 |
| 0 | 128 | 5 / 21 | 20 / 86 |
| 100 | 0 | 3 / 0 | 16 / 0 |
| 100 | 1 | 3 / 0 | 21 / 1 |
| 100 | 32 | 4 / 5 | 28 / 22 |
| 100 | 128 | 10 / 22 | 44 / 85 |
| 1000 | 0 | 49 / 0 | 241 / 0 |
| 1000 | 1 | 48 / 0 | 206 / 1 |
| 1000 | 32 | 52 / 6 | 221 / 20 |
| 1000 | 128 | 56 / 21 | 164 / 80 |

The result is not a uniform speedup. With 128 owned keys and no unrelated
backlog, SQLite points take 86 ms versus 20 ms for a scan (4.3 times as long).
With 1000 unrelated keys and 32 owned keys, points take 20 ms versus 221 ms
for a scan. The latter improvement does not erase the former regression.
At zero owned keys, point loading performs no storage query; 0 ms is also
the clock's quantization, not proof that a query has zero cost.

All entries carry the same encoded 1 KiB payload. The baseline always runs
before the point path, and the cases share a seeded backend. These synthetic
points do not define a reliable adaptive threshold or actual queue-width
prevalence. The production change also isolates unrelated malformed payloads,
which is a separate correctness property rather than a timing result.

**Recommendation:** retain the scoped-read characterization, record the
wide-owned-queue regression explicitly, and measure real ownership/backlog
distributions before choosing another optimization. A bounded multi-key read
that preserves scoped validation is worth a separate design discussion. No
threshold, new storage interface or bulk-read implementation is selected here.

## Register paths remain small synthetic loads (#1151)

Each control load reads and decodes five real control-register values. The
benchmark alternates direct/writer order across seven samples and verifies
values and assigned sequences outside timing. It excludes listings, pending
payloads, entries, planning and commits.

| Backend | Direct median [min, max] ms | Writer median [min, max] ms |
| --- | ---: | ---: |
| Memory, 500 loads | 5 [4, 6] | 10 [10, 11] |
| SQLite `:memory:`, 500 loads | 30 [29, 48] | 38 [37, 49] |

These are elapsed observations, not isolated actor or CPU costs. They do not
measure a whole runtime turn or show that a cache is warranted. The separate
cache-pressure cases warm 65 keys, then read each key five consecutive times;
four reads after a cacheable miss can hit, so width 65 is not an all-miss case.
Direct cases always precede writer cases there.

For SQLite, the 4 KiB width-1 medians were 27/33 ms direct/writer per 2500
reads; width 65 was 47/53 ms. Oversized 300,000-byte values bypass the decoded
cache and took 462/459 ms at width 1, and 465/462 ms at width 65, per 325
reads. No cache-hit, SQL-query, CPU, reduction or GC counters were measured.

**Recommendation:** use these results to bound the synthetic path, not to
attribute actual turn CPU. A real-cycle read/commit census and a scoped grouped
read experiment should precede any read-eliding cache or API decision.

## Corrected append-chain costs (#1152)

Each case uses 200 commits per caller, independent per-caller keys and a fresh
store. Each commit appends to that caller's previous leaf and updates the leaf
with a sequence expectation. Deadline-bounded workers join before timing ends;
final entry, leaf, full-branch and aggregate count validation follows timing.
Case elapsed time includes worker startup, reads and commits. Commit latency
includes storage mailbox wait and execution, but excludes its preceding read.
The runtime writer, model, tools and subscribers are absent. Workers become
runnable as Weft starts them, not through a simultaneous-start barrier.

Values separated by slashes are repetitions 1, 2 and 3. Every repetition is
retained, including the first memory case's startup outlier.

| Backend | Callers | Commits per repetition | Commits/s | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | --- | --- | --- | --- |
| Memory | 1 | 200 | 8333 / 100000 / 100000 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Memory | 8 | 1600 | 114286 / 114286 / 106667 | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 1 / 1 |
| Memory | 32 | 6400 | 83117 / 85333 / 79012 | 0 / 0 / 0 | 1 / 1 / 1 | 1 / 1 / 1 |
| Memory | 128 | 25600 | 38965 / 41357 / 39144 | 1 / 1 / 1 | 5 / 5 / 5 | 6 / 7 / 7 |
| SQLite file | 1 | 200 | 3448 / 4167 / 3846 | 0 / 0 / 0 | 1 / 1 / 1 | 1 / 1 / 1 |
| SQLite file | 8 | 1600 | 4420 / 4233 / 3397 | 1 / 1 / 1 | 2 / 2 / 3 | 3 / 3 / 4 |
| SQLite file | 32 | 6400 | 4208 / 3883 / 3113 | 4 / 4 / 4 | 8 / 9 / 10 | 9 / 12 / 23 |
| SQLite file | 128 | 25600 | 3710 / 3175 / 2687 | 17 / 19 / 21 | 32 / 40 / 53 | 42 / 56 / 88 |

Increasing caller count yields queueing in this workload. The changing SQLite
tails across repetitions cannot be assigned solely to concurrency: host
activity, fixed backend ordering, cache state and run-to-run effects remain
confounds. Millisecond quantization makes zero percentiles and 2 ms total
cases especially coarse. No sync wait, fsync, device cost or CPU attribution
was collected. No group batching was executed, so no batching benefit was
measured and commit throughput must not be presented as agent runs/second.

**Recommendation:** keep production group commit deferred until runtime
contention prevalence and a controlled design comparison justify it. A batch
interface still requires an approved protocol-change proposal preserving
individual results, sequence expectations, lease fencing and ordered
post-durability publication. The full corrected benchmark is no longer blocked;
those design and attribution questions remain open.

## Verification

A fresh `make check-runtime` in this worktree exited 0 with all 221 tests
passing. Formatting, documentation and prelude checks also passed. The
continuation changes only measurement data and documentation, not package
source. Logs remain beside the raw measurement outputs.

The independent data audit recomputed all 100 distribution summaries and
matched all retained samples and all 24 commit histograms against stdout. It
found one low-severity provenance wording issue, since corrected: the online
scheduler count came from a post-run probe, not each benchmark VM. No high-
or medium-severity findings were reported. These checks do not supply the
actual-cycle, CPU or sync attribution deliberately left open above.
