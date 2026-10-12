# Completion latency, October 11, 2026

In this work, we measure the full tool-response path and remove completion
polling from production job waits. Main is pinned at
`4417fdb6a073865660bf029495a9ecf08bc9e315`, the merge of distributed runtime
PR #923. The executor owns the whole workspace tool surface, so the shared
`workspace_plane` assembly is the optimization boundary for both placements.

The [executor baseline](tool-latency-2026-10-09.md) measured warm jailed
commands at 18 to 23 ms. That excluded job completion, session persistence and
provider encoding. The additional benchmark brackets `bash` at the scripted
provider: immediately before returning a tool invocation, and when the next
request carries its successful result. Every result must equal `ready\n`;
all 21 invocations and paired timestamps must exist. The first observation is
reported separately, followed by twenty warm observations. An explicitly
requested benchmark fails if enforcement or shipment prerequisites skip it.

## Paired measurements

Darwin arm64, Gleam 1.19.0, OTP 29 / ERTS 17.0.5. Both distributed daemons run
on this Mac over pinned TLS distribution. The baseline shipment was built at
`df640eb55`; the optimized source is `a6a1f6598`. Boot and session opening are
outside the samples. Each warm call still creates a fresh jail and commits
its job and conversation state. Timings include fixture HTTP and provider
response encoding; they are not a subtraction of independently timed phases.

| Workload | Placement | Before p50 / p95 | After p50 / p95 | Median reduction |
| --- | --- | --- | --- | --- |
| `printf 'ready\n'` | local | 95 / 99 ms | 51 / 53 ms | 46% |
| `printf 'ready\n'` | distributed | 99 / 117 ms | 52 / 60 ms | 47% |
| `sleep 0.2; printf 'ready\n'` | local | 403 / 410 ms | 261 / 267 ms | 35% |
| `sleep 0.2; printf 'ready\n'` | distributed | 406 / 413 ms | 261 / 324 ms | 36% |

The [raw observations](tool-completion-latency-2026-10-11.json) include every
warm sample and each first-call observation. The delayed candidate overlapped
the full repository gate, and its distributed samples include a 473 ms
outlier. Twenty observations describe this run, not a production tail-latency
SLO. The short baseline's local daemon also had distribution configured,
although its tools ran locally. Other hosts, Linux jails, cross-host RTT,
large transcripts, contention and provider APIs need their own measurements.

## Why the change works

Production `jobseam` previously used doubling sleeps from 25 to 250 ms while
waiting for terminal state. A short command that missed one poll paid the
next sleep even after the executor had settled. Long calls paid the larger
backoff, which the 200 ms command makes visible.

`jobs.await_completion` obtains an ownership-checked current poll and a
completion witness from the jobs actor. The first live waiter creates one
linked weft actor; later waiters share it. It holds no caller subjects or
timeouts. Terminal processing attempts persistence, then stops the witness.
A caller monitors it, waits within its remaining budget, and polls the
actor again on DOWN or timeout. The authoritative poll decides the answer;
process death itself cannot report success. Late monitor installation still
produces DOWN, and jobs-owner death takes down its child witness. Refusal
also stops it before dropping the held job. Already-terminal records require
no witness. Injected-clock callers retain `await_job` and their existing
`rest` semantics.

Persistence failure behavior is unchanged: `commit` attempts the write but
still updates memory on failure. The witness therefore proves processing
and write-attempt ordering, not successful durability during owner failure.
No tool schema, wire message, persisted record, jail policy or frozen
interface changes.

## Profiling and verification

A bounded [Pickglass capture](tool-completion-pickglass-2026-10-11.txt) sampled
sixteen selected processes of a disposable local candidate node for five
seconds. It completed with 4,948 samples, 62 runnable and 4,886 waiting.
This is a selected-process stack census, not a CPU-time profile of every
transient effect worker; one target exited, stack depth was eight, and long
BIF/NIF activity is undercounted. It supports investigating wait latency,
but the paired workload measurements establish the improvement. The initial
capture failed when fixture teardown retired the node; the successful run
held the node alive through capture completion. Profiled timings are excluded
from the table.

The 57 job tests pass, including pending output and cursor continuity,
strand isolation, a blocked terminal write and owner death after verifying
the caller's completion monitor is installed. The blocked-write test confirms
a caller cannot return a terminal answer before persistence is attempted.
It also monitors the witness directly while the terminal write is blocked,
then requires its shutdown after the write is released. Moving witness
shutdown before persistence makes this assertion fail; restoring the ordering
passes. This distinguishes notification ordering from the actor serialization
which alone could keep the final reread behind the write.
The independent advisor review found no reachable correctness defect; its
two test-coverage observations were corrected before the final targeted run.
The full repository gate and exact-head hosted/Linux signoff are separate
checks, recorded on the PR rather than inferred from these focused results.

A subsequent independent review by both requested models found no actionable
correctness defect. Both identified the original blocked-write test's narrower
coverage; both verified the direct-monitor test correction above.

An eight-second [Pickglass call trace](tool-completion-calls-2026-10-11.txt)
of `storage@sqlite` and `client@jobs` completed during a disposable delayed
workload: four selected processes, 17,699 calls, 31,528 events and 284.63 ms
of traced time. Storage reads, JSON decoding and transcript scans exceed the
commit subtree in that selection. The selected processes are pinned, and
untraced callees and descheduling count toward their traced callers; this is
neither total node CPU time nor a decomposition of each tool response. It
points the next investigation toward repeated reads and transcript projection.
The profiled workload's timings are excluded from the comparison table.

A separate 101-sample Darwin process-table measurement on this host found
1,431 rows, with median 161 microseconds and p95 514 microseconds per scan.
Eliminating the duplicate tracker startup scan would therefore save little
of the remaining full-path latency. No tracker change was made.

## Reproduce

```sh
make bench-tool-latency
make bench-tool-roundtrip
LOOM_BENCH_TOOLS_WORKLOAD=delayed make bench-tool-roundtrip
```

`LOOM_BENCH_TOOLS_OUT` selects the full-path JSONL output, relative to
`packages/client` unless absolute. It appends one row per placement. Use a
new path for each candidate. `LOOM_BENCH_PROFILE=1` makes the local fixture
publish a disposable loopback node and private cookie-file path, wait five
seconds before work and retain the node twenty seconds after work. Attach
Pickglass with its printed `--node` and `--cookie-file`, using a bounded
capture. Never copy the cookie into command arguments or report artifacts.
