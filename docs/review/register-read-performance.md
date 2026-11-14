# Register-read performance investigation

The [November 13 follow-up](bulk-register-reads-2026-11-13.md) records the separately
approved protocol 114 bulk API and its pending-payload integration. It does not
batch these general typed control-register reads or change the cache policy.
The measurements below retain their original source and workload scope.

Latest measurements: [November 4 corrected full run](session-hotpaths-2026-11-04.md).
The five-register, 500-load medians are now 5/10 ms on memory and 30/38 ms on
SQLite `:memory:` (direct/writer). The older values below remain historical,
not the current benchmark result. No CPU or whole-turn attribution is made.

Issue: #1151. The corrected benchmark measures typed control-register and cache-pressure reads; it does not measure CPU, SQL query counters, or a complete runtime turn.

## Source-derived read counts

At baseline **ccb795759**, `strand_runtime.load` reads `StrandState` first. For an active operation, `load_operation` then reads `OpMeta`, `OpState`, `StrandConfig`, and `StrandLeaf` sequentially, before listing `OpToolArgs` and `OpPreparation`. A `RunIntent` also lists `PendingEntry`; structural intents do not. A tools or deferred phase can additionally fetch its source entry. These counts are conditional on successful prior reads; this is not an instrumented turn count. See `packages/runtime/src/runtime/strand_runtime.gleam`, `load`, `load_operation`, `load_batch_source`, `load_deferred_source`, and `load_pending_for`.

The shared working-tree candidate replaces that pending listing with one point read per referenced inbox or staged-tool-result ID, K reads (including K = 0); its successful full run load is thus five control point reads, two listings, and K pending point reads, plus conditional entry reads. This candidate is a concurrent change and is not what the baseline benchmark measured.

The unchanged live-effect poll frontier does not perform this full load: it checks strand state, operation state, configuration, and leaf in order, short-circuiting on a changed state. The unchanged case therefore performs four point reads, not the baseline's five point reads plus three listings. It still performs typed payload decoding for the state and configuration. See `poll_drive` and `poll_wait_unchanged`.

SQLite `do_get_register` executes one `SELECT seq, value` per call, including a decoded-cache hit. Its list operation executes a namespace query; `do_get_entries` executes one point query per requested entry ID. These are counts derived from source, not measured SQL statements. Both paths route through the writer actor and the backend actor when called by the strand; direct storage calls omit the writer crossing. The time or CPU attributable to either actor cannot be inferred from these counts.

## Cache and correctness constraints

The SQLite cache keys the exact selected persisted blob; it retains at most 64 successful decoded blobs and 256 KiB of encoded bytes, clearing inventory on overflow. Oversized values bypass it. SQLite still fetches the current row and sequence on every lookup, so an external edit or a previously failed write cannot make an old decoded value masquerade as the current one. Sequence and namespace are not supplied by the cache. This does not measure decoded heap size, which may exceed encoded size. Runtime-specific decoding still occurs after storage decoding. See `packages/storage/src/storage/internal/register_cache.gleam` and `sqlite.do_get_register`.

A writer-owned write-through cache would need a sound coherence story for external edits, lease replacement, failed or uncertain commits, deletes, and fence loss. A lease protects commits, not a claim that every future read may skip SQL. Do not substitute a cache hit for the current persisted read without establishing those properties.

## Candidates and evidence gaps

A bounded grouped read could reduce writer/backend round trips while retaining independent fresh row selections and current validation; snapshot and ordering semantics must be specified, particularly in the presence of interleaved commits. A smaller projection could avoid transferring values in key-only inventories, but malformed payload behavior and callers' expectations must be checked before dropping decoding. A write-through cache is more invasive because it introduces coherence and lease-fence obligations. None has been implemented or approved. Measure the matched paths and real runtime cycle before selecting one; elapsed latency alone cannot establish CPU consumption.

## October 30 measurement history

An earlier run was superseded after adding payload and sequence checks and typed control reads; its elapsed values are not used here.



On macOS arm64, run from `packages/runtime`: `gleam format dev/register_read_bench.gleam && gleam run -m register_read_bench` (exit 0). This working tree contains the concurrent pending-read candidate, not a pristine baseline checkout; the benchmark calls storage and writer directly and does not exercise that candidate. SQLite is `:memory:`.

The typed control workload seeds real StrandState, OpMeta, OpState (a starting run with default settings), StrandConfig, and StrandLeaf cells. It reads all five in driver order and applies the corresponding machine/leaf decoders 500 times per sample. Seven samples per path alternate direct/writer order. Before timing it verifies each payload and commit-assigned sequence through both paths. It excludes listings, pending payloads, entries, planning and commits. This is a warm synthetic control-register load, not a full drive or operation cycle.

The separate cache-pressure workload seeds 65 distinct FactCustom strings per size. Before timing, it verifies all 65 expected payloads and commit-assigned sequences through both paths, warming the backend cache. Each timed read asserts presence; equality checks are outside timing. Each sample reads five times consecutively per key, 500 key iterations for small/mid (2,500 reads) and 65 for large (325 reads). Width 1 repeats one key; width 65 cycles them. The source-derived cache expectations are that width 65 exceeds 64 entries for small strings and 256 KiB for 4 KiB strings, but each cacheable miss is followed by four same-key hits, so this is not an all-miss workload. The 300,000-byte values individually bypass the cache. No cache counters were measured. FactCustom direct samples always precede writer samples, sharing the warmed backend, so order and cache state confound comparison. The timing run asserted registry and store close results but sent an asynchronous writer exit; it did not verify writer termination before close. The current benchmark instead monitors, unlinks and stops the writer, waits for its down message, then closes the registry and store. This changes teardown only, outside all timed regions.

Medians for 500 typed control loads: memory **5 ms direct / 12 ms writer**; SQLite **42 / 45 ms**. These are caller-observed elapsed times, not CPU or isolated actor-crossing costs. SQLite control ranges 34–64 ms direct and 41–62 ms writer. The earlier draft showed substantially different elapsed results, reinforcing the need for replicated controlled runs. SQLite 300 KB uncached values took median 837/693 ms per 325 reads for width 1 and 756/619 ms for width 65; this repeated-string payload is not representative of all JSON shapes. Ordering and variability prevent attributing the difference to a path or decoding mechanism. Source-derived SQL counts above are not measured counters. CPU, reductions, GC, file I/O, full-cycle reads/commits, and behavior after external edits, failed writes or lease replacement were not measured. Related investigations: #1150 and #1152.

Raw final output, milliseconds:

```text
memory size=64 width=1 path=direct reads/sample=2500 elapsed_ms=[3, 2, 3, 3, 2, 3, 3]
memory size=64 width=1 path=writer reads/sample=2500 elapsed_ms=[8, 9, 8, 8, 9, 9, 8]
memory size=64 width=65 path=direct reads/sample=2500 elapsed_ms=[3, 2, 3, 3, 2, 3, 3]
memory size=64 width=65 path=writer reads/sample=2500 elapsed_ms=[8, 9, 9, 10, 9, 8, 8]
memory size=4096 width=1 path=direct reads/sample=2500 elapsed_ms=[2, 3, 2, 3, 2, 3, 2]
memory size=4096 width=1 path=writer reads/sample=2500 elapsed_ms=[9, 8, 8, 9, 7, 8, 8]
memory size=4096 width=65 path=direct reads/sample=2500 elapsed_ms=[3, 2, 3, 2, 3, 2, 3]
memory size=4096 width=65 path=writer reads/sample=2500 elapsed_ms=[8, 7, 8, 7, 8, 8, 8]
memory size=300000 width=1 path=direct reads/sample=325 elapsed_ms=[0, 1, 1, 2, 0, 1, 1]
memory size=300000 width=1 path=writer reads/sample=325 elapsed_ms=[4, 2, 3, 1, 2, 2, 3]
memory size=300000 width=65 path=direct reads/sample=325 elapsed_ms=[0, 1, 0, 1, 0, 0, 1]
memory size=300000 width=65 path=writer reads/sample=325 elapsed_ms=[2, 2, 2, 2, 1, 2, 1]
memory control path=direct sample=1 loads=500 elapsed_ms=6
memory control path=writer sample=1 loads=500 elapsed_ms=12
memory control path=writer sample=2 loads=500 elapsed_ms=13
memory control path=direct sample=2 loads=500 elapsed_ms=5
memory control path=direct sample=3 loads=500 elapsed_ms=5
memory control path=writer sample=3 loads=500 elapsed_ms=13
memory control path=writer sample=4 loads=500 elapsed_ms=11
memory control path=direct sample=4 loads=500 elapsed_ms=6
memory control path=direct sample=5 loads=500 elapsed_ms=5
memory control path=writer sample=5 loads=500 elapsed_ms=12
memory control path=writer sample=6 loads=500 elapsed_ms=11
memory control path=direct sample=6 loads=500 elapsed_ms=6
memory control path=direct sample=7 loads=500 elapsed_ms=5
memory control path=writer sample=7 loads=500 elapsed_ms=11
sqlite-memory size=64 width=1 path=direct reads/sample=2500 elapsed_ms=[33, 43, 134, 199, 72, 67, 137]
sqlite-memory size=64 width=1 path=writer reads/sample=2500 elapsed_ms=[121, 155, 58, 59, 45, 45, 44]
sqlite-memory size=64 width=65 path=direct reads/sample=2500 elapsed_ms=[60, 68, 59, 101, 35, 31, 49]
sqlite-memory size=64 width=65 path=writer reads/sample=2500 elapsed_ms=[126, 65, 42, 46, 40, 36, 46]
sqlite-memory size=4096 width=1 path=direct reads/sample=2500 elapsed_ms=[257, 38, 33, 36, 170, 46, 43]
sqlite-memory size=4096 width=1 path=writer reads/sample=2500 elapsed_ms=[52, 76, 165, 188, 72, 84, 194]
sqlite-memory size=4096 width=65 path=direct reads/sample=2500 elapsed_ms=[187, 173, 176, 65, 62, 59, 62]
sqlite-memory size=4096 width=65 path=writer reads/sample=2500 elapsed_ms=[69, 70, 70, 66, 64, 56, 51]
sqlite-memory size=300000 width=1 path=direct reads/sample=325 elapsed_ms=[508, 857, 837, 569, 684, 873, 842]
sqlite-memory size=300000 width=1 path=writer reads/sample=325 elapsed_ms=[539, 682, 693, 587, 890, 728, 886]
sqlite-memory size=300000 width=65 path=direct reads/sample=325 elapsed_ms=[884, 547, 614, 756, 1530, 972, 751]
sqlite-memory size=300000 width=65 path=writer reads/sample=325 elapsed_ms=[773, 1570, 719, 534, 493, 581, 619]
sqlite-memory control path=direct sample=1 loads=500 elapsed_ms=37
sqlite-memory control path=writer sample=1 loads=500 elapsed_ms=41
sqlite-memory control path=writer sample=2 loads=500 elapsed_ms=45
sqlite-memory control path=direct sample=2 loads=500 elapsed_ms=34
sqlite-memory control path=direct sample=3 loads=500 elapsed_ms=46
sqlite-memory control path=writer sample=3 loads=500 elapsed_ms=43
sqlite-memory control path=writer sample=4 loads=500 elapsed_ms=43
sqlite-memory control path=direct sample=4 loads=500 elapsed_ms=42
sqlite-memory control path=direct sample=5 loads=500 elapsed_ms=42
sqlite-memory control path=writer sample=5 loads=500 elapsed_ms=61
sqlite-memory control path=writer sample=6 loads=500 elapsed_ms=54
sqlite-memory control path=direct sample=6 loads=500 elapsed_ms=44
sqlite-memory control path=direct sample=7 loads=500 elapsed_ms=64
sqlite-memory control path=writer sample=7 loads=500 elapsed_ms=62
```


## Teardown verification

After the timing run, the writer shutdown was changed to monitor and stop the writer and wait for `ProcessDown` before registry and storage close. The following command, run from `packages/runtime`, exited **0**:

```sh
gleam format dev/register_read_bench.gleam dev/register_read_bench_smoke.gleam && gleam check && gleam run -m register_read_bench_smoke && gleam format --check dev/register_read_bench.gleam dev/register_read_bench_smoke.gleam
```

The smoke wrapper calls the benchmark's actual `smoke()` and `run_backend(Memory)`, including the same writer teardown and asserted close results. It completed all memory workload samples; stderr ended with `Running register_read_bench_smoke.main`. It does not exercise SQLite or an in-flight lease renewal. Smoke timings are not used as performance evidence, and the full SQLite benchmark was not rerun under high host load.

## Independent integration receipt

The primary ran `gleam run -m register_read_bench_smoke` against the final
shared memory workload and shutdown path (exit 0). Output is retained in
`.codemode/tmp/session-hotpath-primary/register-smoke.log`. The complete
runtime gate also passed all 221 tests, with runtime lint, whole-tree
formatting, documentation and prelude checks passing. The first runtime
run's two timeout observations and unchanged successful rerun are recorded
in [the pending-entry record](pending-entry-performance.md). These receipts
do not replace an independent full timing run or establish SQLite renewal
behavior. The November 4 full run exercises corrected SQLite teardown too;
actual-cycle attribution and a grouped-read or cache decision remain open
in #1151.
