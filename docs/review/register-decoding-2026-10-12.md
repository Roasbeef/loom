# Repeated register decoding, October 12, 2026

A bounded store-owned inventory removes repeated JSON parsing when the working
set fits. Across the structured fixtures, warm reads used 74.5% to 91.0% less
VM CPU time and 99.1% to 99.8% less traced actor heap allocation. The inventory
retains decoded values, and workloads that repeatedly overflow it regress.
These results justify a targeted optimization, not a claim of lower whole-daemon
RSS or uniformly faster register reads.

## Implementation and invariants

Baseline: `e500bc260`, current main after merged PR #966. Implementation:
`7db1fdd27dda2105a8d918ae5d13d63ae988372c`. The installed daemon was unchanged.

`storage/internal/register_cache` holds successful `RegisterValue` decodes under
exact complete blob keys. Every get/list still executes its original SQL query
and row decoder. The query supplies current sequence, absence, key order and
prefix selection. External same-sequence edits and corrupt bytes cannot hit an
old value. Failed commits cannot admit tentative data because only reads fill
the inventory. Writer lease and CAS checks remain unchanged.

The inventory holds at most 64 distinct blobs and 262,144 encoded bytes. An
admissible miss that exceeds either limit starts a fresh inventory. Larger
individual blobs bypass it. Close clears it even when lease release fails and
the closed actor remains alive to remember the failure. Replaced/deleted values
can stay until rollover or close. Encoded limits are not decoded heap limits.

## Reproduction and measurement

Build the baseline storage package, save its `storage@sqlite.beam`, then build
the candidate with the same toolchain and dependencies:

```sh
bash scripts/register_decode_perf.sh "$PWD" /absolute/path/to/baseline/storage@sqlite.beam
```

The runner renames the saved baseline module from its abstract forms, preserving
compile attributes; that module has no remote self-calls. Both implementations
run real SQLite actors with identical persisted values, queries and result
validation. Inputs differ between rows, so eight rows are eight distinct payloads.
Three fresh OTP 29 / ERTS 17.0.5 VMs use one normal scheduler (`+S 1:1`), with
four rounds alternating implementation order in each VM. There are twelve
batches per implementation and case. Timing captures no trace; the first cold
read(s) and warm repetitions are separate.

VM CPU uses `erlang:statistics(runtime)`, the sum of runtime across VM threads,
in milliseconds ([OTP reference](https://www.erlang.org/doc/apps/erts/erlang.html#statistics/1)).
It includes the synthetic driver and validation, not only the actor. CPU batches
use at least 500 repetitions for the smaller cases to reduce timer quantization.
Actor reductions are separately sampled around the original timing batch.
Root-only `tprof` call_memory on `handle_open/2` measures cumulative actor heap
allocation in a separate batch, avoiding nested double counting. It excludes
refcounted binary payloads and native SQLite allocation. JSON parse counters in
another separate batch verify zero decodes for warm hits and unchanged decode frequency
for misses. Neither reductions nor allocation words are CPU-seconds.

Elapsed times include synchronous actor exchange and caller-side validation;
list validation performs key/value lookup work too. They are verified fixture
round trips, not user-tool latency. This Mac was running other agents and tests;
it was not a quiet host. Figures below are pooled medians, normalized per query.
The tables below summarize all three VM runs and retained actor measurements.
The runner emits the detailed counters needed to reproduce the comparison;
the large raw JSON export is not checked into the repository.

## Warm results

| Fixture/query | Rows; max blob bytes | VM CPU us, baseline → candidate | Actor heap bytes, baseline → candidate | Elapsed us, baseline → candidate |
| --- | --- | ---: | ---: | ---: |
| scalar/point | 8; 1 | 28.0 → 25.0 | 3,488 → 2,544 | 28.4 → 29.9 |
| scalar/list | 8; 1 | 69.0 → 67.0 | 33,256 → 25,000 | 76.0 → 81.4 |
| structured4k/point | 8; 4,077 | 110.0 → 28.0 | 340,024 → 2,560 | 125.9 → 27.2 |
| structured4k/list | 8; 4,077 | 637.0 → 104.0 | 2,725,544 → 25,128 | 802.3 → 124.0 |
| structured16k/point | 8; 16,298 | 303.0 → 46.0 | 1,338,424 → 2,560 | 364.4 → 41.6 |
| structured16k/list | 8; 16,298 | 2,363.0 → 212.0 | 10,712,744 → 25,128 | 3,008.3 → 221.2 |
| dense/point | 4; 40,982 | 606.0 → 67.0 | 4,529,624 → 2,560 | 744.0 → 72.8 |
| dense/list | 4; 40,982 | 2,304.0 → 216.0 | 18,241,332 → 12,872 | 3,077.2 → 209.0 |
| entry_overflow/point | 80; 149 | 31.0 → 29.0 | 17,608 → 18,197 | 30.1 → 26.3 |
| entry_overflow/list | 80; 149 | 784.0 → 825.0 | 1,458,344 → 1,497,040 | 1,196.8 → 1,230.3 |
| byte_overflow/point | 8; 65,450 | 1,125.0 → 2,625.0 | 5,332,024 → 5,332,438 | 1,465.6 → 3,127.7 |
| byte_overflow/list | 8; 65,450 | 30,875.0 → 32,437.5 | 48,571,226 → 56,491,194 | 35,778.6 → 35,766.0 |
| oversized/point | 1; 300,023 | 1,500.0 → 1,500.0 | 7,520 → 7,808 | 2,217.1 → 2,222.4 |
| oversized/list | 1; 300,023 | 1,500.0 → 1,500.0 | 8,512 → 8,880 | 2,223.1 → 2,226.0 |

Structured warm hits eliminate JSON parse calls. Actor reductions fall 98.4%
to 99.5%; remaining VM CPU includes SQLite, binary hashing/equality, actor
messages, result copying and driver verification. A dense-array fixture also
saves about 89% to 91% VM CPU and 99.9% actor heap allocation. Scalars have
little parsing work: measured latency regressed about 5.5% to 7.0% despite
fewer reductions and allocated words.

Overflow is a real cost. Eight distinct 65,450-byte blobs cannot fit: point
queries used 2.33 times baseline VM CPU and 2.13 times elapsed time. Overflowing
lists allocated 16.3% more actor heap and used 5.1% more VM CPU, while their
pooled elapsed median was essentially unchanged. Eighty small distinct entries
also overflow the count limit; list queries used 5.2% more VM CPU and 2.7%
more actor heap. There is no general-purpose eviction policy or extra tuning
knob. Limits prioritize bounded retention and the observed repeated-read lead;
a persistently larger working set is a documented limitation.

Oversized individual payloads bypass reuse. Their VM CPU was unchanged in these
batches, with 3.8% to 4.3% more traced heap allocation from tuple/continuation
plumbing. The absolute extra allocation was 288 to 368 bytes per query.
Cold admissions also have a cost: structured4k point-read medians were
108.7 → 111.5 us, and structured16k list medians 2,829.0 → 3,015.5 us.
These short loaded-host timing batches do not establish a stable cold latency
percentage. The runner reports cold counters separately from warmup.

## Retained memory

After each warm trial, only the isolated synthetic actor receives full GC.
Its allocated process memory is measured, then its synthetic state is copied
and measured with `erts_debug:flat_size`. The latter flattens sharing and is
not exact reachable memory. Neither counter is OS RSS. No collection or state
walk targets the installed daemon.

| Candidate fixture | Post-GC actor allocation | Flattened state words |
| --- | ---: | ---: |
| scalar | 4,032 bytes | 117 |
| structured4k | 230,544 bytes | 9,293 |
| structured16k | 973,312 bytes | 36,173 |
| dense | 1,574,224 bytes | 65,717 |
| byte_overflow point | 973,312 bytes | 71,861 |
| byte_overflow list | 1,574,224 bytes | 71,861 |
| oversized | 2,888 bytes | 28 |

Baseline actors were 2,888 bytes after GC and held 20 flattened state words.
All successfully closed candidate actors returned to 2,888 allocated bytes and
34 flattened state words, including the empty inventory representation. Dense
JSON demonstrates why a 256 KiB encoded bound is not a 256 KiB heap bound.
These fixtures do not establish a universal retained-memory maximum.

## Live observation and validation

The installed build was still merged PR #949, `e289d93ab`, not the new encoder
or register optimization. A fresh ten-second bounded Pickglass stack profile
again found UTF-8 validation at the top of flat samples and object parsing in
about 80% of active observations. Sampling covers selected processes at
reduction safe points, with native calls undersampled; those are sample shares,
not CPU-time percentages.

Three passive live cuts during this task showed VM allocation falling from
509,112,575 through 479,432,895 to 474,294,671 bytes, and daemon RSS from
664,453,120 through 658,636,800 to 652,656,640 bytes. The earlier profile's lower RSS remains relevant, but these
cuts do not show monotonic growth or prove a leak. The prior OS census found
three gopls children summing to 4.49 GiB RSS, a separate memory lead; summed
RSS can double-count shared pages. No daemon restart, hotpatch, forced GC,
state walk or child termination was performed.

Five focused regressions pass: external same-sequence replacement and corruption,
oversized/overflow totality, failed-close release, independent entry/byte bounds,
and warmed reads across failed CAS and writer lease replacement. Two compiled
cache-bound mutants are rejected in every final benchmark VM. The correctness
reviewer signed off the implementation and its added tests. The independent
evidence reviewer recomputed every reported median from all three VM logs and
signed off the runner, report and raw data. The final serialized
`LOOM_TEST_PARALLEL=8 make check` passed with exit code 0,
including all 286 storage tests, the other packages, Go checks, lint (zero
errors) and configuration-key checks. Documentation checks also passed.
Hosted CI remains a separate gate after publication.
The initial full gate stopped on dependency Git acquisition with disk-full;
a later narrow Make invocation overlapped shared shipment artifacts and failed.
Neither is counted as passing validation, and no test was weakened or skipped.
