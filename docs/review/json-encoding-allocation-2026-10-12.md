# JSON container encoding allocation, October 12, 2026

The portable Gleam encoder builds array and object fragments directly instead
of mapping encoded children, constructing per-field append trees and then
intersperse/joining another list. It reverses the input once and prepends into
the final fragment list with tail-recursive sibling loops. Emitted order stays
unchanged. Scalar formatting and string escaping use the existing functions.
There is no new FFI, dependency or public interface.

The reversal is deliberate: the earlier isolated Erlang prototype used direct
sibling recursion. Its 23% to 26% allocation result did not establish safe wide
container behavior on JavaScript. The Gleam implementation keeps sibling stack
usage bounded on both targets and trades some of that prototype's savings for
that property. Recursion through nested values remains unchanged.

## Comparison

Baseline is merged PR #949, `e289d93ab74ef88d35717757f5d6299b94441256`.
Its freshly built `core@json.beam` was saved before changing source. The saved
artifact's SHA-256 is
`36056de98dc3f7fc920e7d446119017b7dfe9326c220347e7ee1367b0bd27848`.
Candidate `packages/core/src/core/json.gleam` SHA-256 is
`2679e06c3f3b2e76a2ea4203a7cd95cf23186f7caa70093f090560f934c12d82`.
Both measurements use Gleam 1.19.0, OTP 29 and the same dependencies on
Darwin arm64. The measured compiler is the installed bundled Gleam binary,
SHA-256 `fa41094adf67780a3078bb494bb8c7b1ab0bc586752c97adacde9d6cab4cc9e0`.
The encoder implementation is commit `59c62c234`; the runner is `3ac324acb`.

The [runner](../../scripts/json_encode_perf.sh) starts a fresh single-scheduler
VM. It renames only the saved baseline module attribute, retaining its function
bodies and compiler attributes, so both encoders can run in one VM. Independent
review checked that this baseline contains no module-qualified self calls or
function references that would escape into the candidate.

Each of three fresh VMs runs eight timing batches of 200 encodes per fixture,
alternating which revision runs first. Each batch has ten warmups. The table
pools the 24 timing batches and takes the median of the three allocation
passes; allocation totals were identical across those passes. Timing traces
nothing. A separate pass traces only each encoder's `to_string/1` root for 100 encodes;
OTP charges untraced callees to that root. The table reports cumulative heap
words per encode, not retained bytes, binary payload bytes, native allocation
or RSS. Outputs are discarded between calls.

| Fixture | Output bytes | Baseline heap words | Candidate heap words | Fewer words | Baseline median µs | Candidate median µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 transcript objects | 1,736 | 5,773.20 | 4,682.24 | 18.9% | 23.75 | 20.70 |
| 128 transcript objects | 13,973 | 46,100.48 | 37,395.32 | 18.9% | 186.37 | 181.07 |
| 1,024 transcript objects | 112,558 | 376,242.42 | 299,040.62 | 20.5% | 2,144.98 | 1,548.57 |
| 10,000 integer array items | 20,001 | 150,016.00 | 90,010.00 | 40.0% | 428.81 | 432.72 |
| 10,000 object fields | 117,789 | 380,411.00 | 260,750.31 | 31.5% | 2,364.01 | 1,543.34 |
| Empty object | 2 | 12.00 | 8.00 | 33.3% | 0.060 | 0.040 |
| Scalar string control | 18 | 21.00 | 21.00 | 0.0% | 0.170 | 0.140 |

The host was busy. These are codec observations, not quiet-host results or
end-to-end tool latency. Observed transcript timing changes range from 2.8%
to 27.8%; the wide array's pooled median is 0.9% slower, within the observed
variation (baseline 417.75 to 460.62 µs, candidate 401.62 to 524.92 µs).
Sub-microsecond controls are too small to support a timing claim. Allocation is the established
benefit; repeat quiet-host timing before treating these latency differences as
stable. At eight bytes per heap word, the largest transcript fixture allocates
about 603 KiB less per encode in each pass. The raw counters are retained
rather than rounded into an exact allocation formula.

The [raw results](json-encoding-allocation-2026-10-12.txt) contain every batch.
To reproduce, build baseline core, save its BEAM, build candidate core, then run:

```sh
bash scripts/json_encode_perf.sh "$PWD" /absolute/path/to/baseline/core@json.beam
```

## Correctness and validation

The comparison checks identical encoded bytes for 398 values before measuring:
all C0 controls and ASCII characters beside multibyte and combining text in
keys and values, scalar numeric forms, empty/wide containers, hand-built
repeated keys, and every alternating nesting depth from 1 through 256. The
encoded corpus SHA-256 is
`0c776eb493a4570738b46e7bdcf12ce52bd15715f7e57925d74a4939e6757cf2`.
Existing generated roundtrip and codepoint string-oracle tests remain in place.

All 166 BEAM core tests pass. Three added tests pin exact delimiters/order,
20,000 siblings in both container types, and the accepted nesting bound. They
also pass when invoked directly from the generated JavaScript. Two isolated
JavaScript negative controls replace each sibling loop's comma with a
semicolon; the wide-container regression test rejects both. Production source
and build artifacts were not mutated.

The optional full core JavaScript suite is not green: candidate has 157 passes
and nine failures; a clean baseline core rebuild has 154 passes and the same
nine failures. Those existing failures concern numeric precision, non-finite
float parsing and msgpack depth/integer behavior. No test was removed or waived.

Independent implementation/invariant and measurement reviews found no
actionable issues. The complete gate passed with its own exit code 0:

```sh
PATH="/opt/homebrew/bin:$PATH" LOOM_TEST_PARALLEL=8 make check
```

This includes all 106 Python gate tests, every Gleam package (4,488 client and
1,365 TUI tests), the Go sandbox suite, house-rule lint (zero errors) and the
configuration-key self-test. The final run uses Homebrew Gleam 1.19.0,
SHA-256 `31e06a12c44481139bd60a4f1ac63c5c225c107eecda813f2db2e23e5719f799`.
`make doc-check` also passed with zero errors.

Two environment failures were diagnosed before that successful run. Sandbox
process restrictions made four installation-pruning Python tests fail; all
106 pass with normal process visibility. The inherited Codex PATH selected
bundled ripgrep under `/Applications`, outside the jail's granted roots, so
`TestSeatbeltJailedPathFindsHomebrewTools` failed. That unchanged test passes
with Homebrew first, both in isolation and in the complete gate. No source,
test or enforcement policy was weakened to obtain the passing run.

The installed daemon was not restarted or changed.
