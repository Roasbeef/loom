# JSON decoding allocation, October 11, 2026

The live Pickglass capture identified JSON string decoding as an allocation
lead. This follow-up measures the decoder itself against PR #949 head
`13c3f96a49d195fbf11ab8973fd5e298baafe261`. The installed daemon is unchanged;
these are synthetic fixture results, not live resource or whole-tool savings.

## Change

`parse_string_body` now dispatches closing quotes, adjacent escapes, controls
and end of input before constructing a string slice. A nonempty ordinary run
is matched and UTF-8 validated directly, avoiding `cut`'s intermediate Result
pair and continuation. Successful runs consume their delimiter in the same
cursor update. Refusals stop at the original position.

Chunk accumulation and final concatenation are unchanged, as are numeric
parsing, nesting limits, duplicate-key rejection and all public interfaces.
The change adds no dependency, FFI or target-specific code. Independent Astra
review checked exact failure positions, UTF-8 validation and the final inline
simplification. Sol 6.1 independently checked the benchmark arithmetic,
measurement scope and retained evidence without finding an actionable error.
A stale description of the remaining numeric `cut` caller
was corrected.

## Method

`scripts/json_decode_perf.sh <built-checkout> <label>` runs a fresh OTP 29 VM
with one scheduler and an eight-byte word, using Gleam 1.19.0 artifacts. Each
fixture first verifies its decoded value, warms five calls, then measures fifty
calls. Timing and process reductions are untraced. A separate fifty-call pass
uses `tprof` call-memory tracing on `core@json:parse/1` alone, in the current
process, with child tracing disabled. Untraced callees are charged to that root.
This is distinct from the older all-function `scripts/json_perf.sh` profile.

Baseline and candidate alternated three times, sequentially, in fresh VMs.
The baseline core artifacts were built from the exact baseline source and
saved separately; candidate source was restored and rebuilt before measurement.
The adjacent JSON contains all 36 final observations, medians, timing ranges,
source digest, ownership observations and exploratory logs. No repository gate
ran during these comparisons. Other host activity was not controlled.

Cumulative allocated heap words are not retained memory, RSS or native and
refcounted binary payload allocation. Percentages describe these fixtures and
this tracing configuration. The live profile's per-function allocation totals
have a different scope and cannot be scaled by these percentages.

## Results

Medians of three runs, normalized to one decode. MiB means 1,048,576 bytes.

| Fixture | Encoded bytes | Heap allocation before → after | Reduction | Untraced time before → after |
| --- | ---: | ---: | ---: | ---: |
| Plain text | 114,002 | 960 → 856 bytes | 10.8% | 467 → 478 µs |
| Escaped text | 102,002 | 4.25 → 3.60 MiB | 15.3% | 1,192 → 1,230 µs |
| Dense adjacent escapes | 96,002 | 30.59 → 14.38 MiB | 53.0% | 4,830 → 2,292 µs |
| Dense escapes, doubled | 192,002 | 60.81 → 28.69 MiB | 52.8% | 9,642 → 4,999 µs |
| 2,048 short strings | 10,753 | 2.64 → 2.27 MiB | 13.9% | 452 → 377 µs |
| 128 transcript-shaped objects | 360,462 | 18.58 → 15.98 MiB | 14.0% | 10,730 → 9,217 µs |

The transcript fixture saves 2,726,000 measured heap bytes per decode and its
median time falls 14.1%. Dense escapes roughly halve both allocation and time;
doubling the dense input roughly doubles candidate work. Plain text saves only
104 heap bytes per decode; its output binary payload is outside this counter.
Plain and ordinary escaped text have slightly slower timing medians (2.3% and
3.2%) despite lower allocation. This is an allocation improvement with useful
fixture speedups, not a universal wall-time improvement.

Earlier experiments are retained separately: moving only empty-run dispatch
and cursor updates showed no meaningful allocation reduction on the original
escaped-text fixture. Native string-tree concatenation did not improve the
transcript allocation result. An incremental string accumulator increased
allocation. Those representations were discarded; the final change keeps the
existing chunk list and concatenation. An intermediate helper-based candidate
was inlined to reduce the diff and avoid extra JavaScript recursion frames.
Some exploratory runs overlapped each other; only the final sequential runs
support the table above.

## Correctness and ownership

The `equivalence` mode hashes complete parse results, including corruption
reports, for 882 deterministic document prefixes and byte mutations. Mutations
include control bytes, delimiters, invalid UTF-8 and incomplete escapes. Both
builds report zero exceptions and SHA-256:

```
27b8e2a1f3e4c1f1fcd85885f0695a3cb70ca0375dfb53766f711de3a4b1995d
```

The comparison complements the parser suite; it is not an exhaustive proof.
New regressions cover adjacent escapes, empty keys and values, duplicate empty
keys and exact codepoint offsets after multibyte text. The existing boundary,
surrogate, depth, generated roundtrip and malformed-input tests remain intact.

A separate ownership observation selects a 96-byte string from a 1,048,679-byte
document. Both builds retain the same 1,048,679-byte backing binary. The change
does not introduce this behavior or fix it; allocation savings do not establish
retention savings. Copy policy requires a separate workload and lifetime study.

Both JavaScript JSON modules pass 30 tests and fail the same existing
`adversarial_corpus_test`: JavaScript accepts `1e999` as `Float(Infinity)`.
Both new regressions pass on both builds. Both JavaScript builds report the
same 25 existing safe-integer warnings in core and its tests. This optional
comparison is not a green JavaScript suite. An initially oversized new
adjacent-escape fixture exhausted the JavaScript stack on both builds; its
portable regression uses 100 repetitions, while the BEAM benchmark retains
48,000 and 96,000 adjacent escape characters. No existing test was weakened.

Reproduce with the same compiler/OTP and built baseline/candidate checkouts:

```sh
bash scripts/json_decode_perf.sh <baseline-checkout> baseline
bash scripts/json_decode_perf.sh <candidate-checkout> candidate
bash scripts/json_decode_perf.sh <baseline-checkout> baseline equivalence
bash scripts/json_decode_perf.sh <candidate-checkout> candidate equivalence
```

The decoder source is committed at `9b1654af5`. The full local
`LOOM_TEST_PARALLEL=8 make check` passed with exit 0, including 163 core,
3,835 client, 1,331 TUI and 98 conformance tests, Go sandbox tests and zero
house-lint errors. `make doc-check` passed with 198 existing warnings and
zero errors. Current-head hosted/Linux gates are recorded separately in
PR #949 and the handoff. Neither a controlled decoder benchmark nor a local green gate attests
to a deployed daemon or an unobserved distributed network workload.
