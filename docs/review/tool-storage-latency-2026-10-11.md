# Transcript read latency, October 11, 2026

The bounded call trace in [the completion report](tool-completion-latency-2026-10-11.md)
identified repeated storage reads and transcript decoding as the next measurement
lead. Two changes remove unnecessary work: image-capable model admission no
longer projects the transcript, and SQLite kind-filtered branch scans fetch only
matching payloads through the existing covering index. Both local and distributed
execution use these paths. There is no wire, schema or frozen interface change.

## Paired measurements

The baseline is `90849fb1e7f00a0088daea03b84071b3479b4dc7`, which already
contains the completion-witness optimization. Candidate `4839fd7d8` adds the two read
optimizations. The benchmark fixtures are identical on both sides. Timing runs
were separate from our profiling and full repository checks; host exclusivity
was not established. All observations,
including the first call and tails, are in the [raw artifact](tool-storage-latency-2026-10-11.json).

| Measurement | Before p50 / p95 | After p50 / p95 | After repeat p50 / p95 |
| --- | --- | --- | --- |
| SQLite compaction scan, 1 MiB message text | 8.166 / 8.548 ms | 0.100 / 0.160 ms | — |
| Full tool round, local, 65,550-byte prompt | 62 / 70 ms | 51 / 58 ms | 47 / 50 ms |
| Full tool round, loopback TLS, same prompt | 70 / 80 ms | 50 / 53 ms | 51 / 62 ms |

The scan median falls 98.8%. In these earlier paired observations, full-round
medians fall 18–24% locally and 27–29% over loopback TLS. These are additional improvements over the earlier completion
optimization, measured with a larger prompt. The combined full-path comparison
does not attribute an exact number of milliseconds to either read optimization.

The standalone scan creates one compaction and exactly 128 newer messages of
8,192 bytes each. It persists them before timing, asks for the compaction with
an inclusive compaction stop and limit one, and checks its exact ID on every
scan. There are thirty warm samples; the first scan is separate. Run it with
`cd packages/storage && gleam run -m bench_branch`.

The full-path fixture runs `printf 'ready\n'` through a shipped daemon and real
jail, bracketed by scripted provider requests. Each placement has twenty warm
calls after its first call. The initial request checks the exact prompt; every
round checks successful tool output. Run `LOOM_BENCH_TOOLS_WORKLOAD=history make bench-tool-roundtrip`
with the same helper/toolchain prerequisites as the original benchmark. The
script waits on a bounded prompt prefix and then verifies the complete prompt;
it does not enlarge the provider fixture's expectation limit.

These measurements are from one Mac. Distributed placement uses a separate
executor over loopback TLS, not a physical network hop. Startup and provider
inference are outside the measured interval. Linux, cross-host RTT, contention
and growing transcripts remain separate measurement work.

## Semantics and query plan

Image admission checks `model.reading` before consulting durable operation and
branch state. Text-only models retain the existing image checks and route
selection. A regression test wraps the storage interface and requires zero
reads for both an explicitly image-capable model and the unknown-model fallback.
It failed against the baseline and passes with the reordered guard.

SQLite still resolves stops and clips cursor windows against the unfiltered
branch before applying `entry_type` in SQL. The pure branch refinement remains
the semantic backstop, and custom-type filtering remains there. Without a
custom-type filter, a page fetch is bounded by the remaining result limit.
Insertion derives index kind metadata from the same immutable entry as its
payload; rewrites cannot change that kind. Matching malformed payloads still
fail decoding. Payloads excluded by kind are no longer decoded or validated.

`EXPLAIN QUERY PLAN`, using the actual schema and both new SQL strings, reports
`SEARCH b USING COVERING INDEX ix_be_type` with branch, type and sequence bounds,
followed by `SEARCH e USING PRIMARY KEY (id=?)`. Neither direction uses a temp
sort or an entries table scan. This was checked with SQLite 3.50.4, also the
version in the bundled esqlite header. The raw artifact preserves both plans.
No additional index or migration was needed.

## Verification

The focused runs passed 265 storage tests, 43 wiring tests and 32 vision tests.
The new corruption regression fails on the baseline and passes on the candidate:
compaction-only reads succeed despite excluded malformed messages, while reads
that select those messages still return `CorruptRow`. Additional checks compare
exact IDs around 255, 256 and 257 matching rows in both directions. Shared
conformance cases cover stops whose kind is excluded, cursor clipping and
pagination through sparse matches in both orders.

Independent review found no remaining actionable defect after correcting a
comment stanza and a benchmark fixture count. Both sides of the scan benchmark
were rerun with the corrected 128-message fixture. The ordinary sandbox blocked
nine jailed conformance cases with permission errors; the full repository gate
is rerun outside that nested sandbox. Current exact-head gate status is recorded
on the PR, separately from these focused results and measurements.

## Integration and host-load limit

Main through PR #950 (`2ff7512ac`) was integrated at `0a178e7b9`. The sole
conflict was the handoff; the optimization source files had no overlapping
changes. Independent review verified the shared local/executor path. The
integrated full `LOOM_TEST_PARALLEL=8 make check` passed with exit 0, including
271 storage, 3,835 client, 1,331 TUI and 98 conformance tests, the other
packages, Go sandbox tests, house lint and configuration self-tests.

Three additional shipped history runs passed after the full gate finished:

| Integrated observation | Local p50 / p95 | Loopback TLS p50 / p95 |
| --- | --- | --- |
| Candidate, initial | 56 / 79 ms | 55 / 83 ms |
| Read optimizations removed, completion witness retained | 57 / 61 ms | 59 / 67 ms |
| Candidate, restored byte-for-byte | 65 / 74 ms | 74 / 82 ms |

The baseline replaced only `client/wiring.gleam` and `storage/sqlite.gleam`
with main's versions, then restored the exact candidate bytes. Every run has
twenty warm observations and separate first calls in the raw artifact.
A host snapshot immediately after the repeat showed load averages of
19.04 / 15.61 / 18.02 and multiple unrelated compilers and BEAM VMs consuming
CPU. It reported no thermal warning. This is evidence of a substantial
confound, not proof of the workload during each earlier sample. These runs
do not establish a repeatable integrated end-to-end improvement. The earlier
full-path reductions remain observations rather than a performance guarantee;
a quiet or isolated host is needed to quantify that claim. The regression
proves the removed admission reads, and the standalone scan measures the
decoding work avoided independently of whole-round scheduling.

An older Linux signoff also exposed two parallel TUI tests sharing and
deleting one credential path. Each of their three calls now owns a distinct
path, with assertions and parallel eligibility preserved. The entire 14-test
module passed 100 parallel runs. The exact failing Linux interleaving remains
inferred: twenty local baseline pair runs passed. Exact-head hosted CI and
Linux signoff remain separate from the successful local integration gate.
