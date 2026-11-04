# JSON string cursor allocation, October 30, 2026

The [live profile](live-profile-2026-10-30.md) counted at least 233.88 MiB of
JSON heap allocation in its active trace. The follow-up keeps the change inside
the total parser: ordinary runs and simple escapes carry one starting cursor
and an unread suffix, rather than constructing a new cursor for every escape.
A cursor is reconstructed at a closing quote, Unicode escape or refusal.
The UTF-8 conversion also handles its error directly, without allocating an
error callback on each valid run.

The public API, accepted grammar, error reports, duplicate-key and depth checks,
and output-binary ownership are unchanged. There is no FFI, new dependency,
shared cache, lifetime policy or installed-daemon change.

## Matched measurement

The source baseline is main `c06d33430dacd1b62bd1b4d8b2584d8f97846dcf`.
Its JSON source is unchanged from the profiled `ccb795759`. The baseline BEAM
was built with Gleam 1.19.0 and OTP 29 / ERTS 17.0.5 before the parser edit and
has SHA-256 `6e1884f1359974e23595bc784e236364d3d10ca4e67f766d47edbd919997e6cb`.

`scripts/json_decode_compare.sh` follows the existing encoder benchmark's
baseline-renaming method: it recompiles the saved BEAM's abstract forms with
only the module name changed. Both implementations then run in one disposable
VM with one normal scheduler and one scheduler in each dirty pool. Eight
untraced timing rounds alternate their order. Allocation is measured separately
with root-only `tprof` call-memory tracing of `parse/1`.

Each table cell covers fifty decodes of the same input. CPU and wall time are
medians of eight rounds. Allocation is a separate counted pass, in heap words;
the target has eight-byte words. Concurrent host activity makes wall timings
variable, so allocation and reductions are recorded separately.

| Input | Bytes | CPU ms, baseline to candidate | Wall ms, baseline to candidate | Heap words, baseline to candidate |
| --- | ---: | ---: | ---: | ---: |
| Ordinary text | 114,002 | 28.0 to 28.0 | 44.49 to 45.85 | 5,350 to 4,900 |
| Escaped text | 102,002 | 101.5 to 93.5 | 145.63 to 132.77 | 23,604,650 to 16,404,150 |
| Dense escapes | 96,002 | 208.5 to 149.0 | 337.08 to 271.18 | 94,245,374 to 46,242,989 |
| Double dense escapes | 192,002 | 445.0 to 297.5 | 1,294.80 to 739.32 | 188,046,400 to 91,206,200 |
| Short strings | 10,753 | 33.0 to 32.0 | 51.13 to 43.14 | 14,889,784 to 13,422,550 |
| Transcript | 360,462 | 801.5 to 640.0 | 1,064.45 to 874.93 | 104,717,500 to 74,815,700 |

The transcript uses 28.6% fewer allocated words and 20.1% less VM CPU time in
this fixed fixture. Dense escapes use about 51% fewer words. Median reductions
fall 7.2% on the transcript and about 1.5% on dense escapes, while increasing
2.0% on escaped text and 6.2% on the short-string fixture. Their measured CPU
medians still decrease; fewer allocations and fewer reductions are distinct
claims. Ordinary text's CPU median is unchanged and its wall median rises 3.1%.

These are parser measurements, not an estimate of whole-daemon CPU, reachable
heap or RSS savings. A selected 96-byte decoded string still references its
1,048,679-byte input backing binary in both implementations. This pre-existing
ownership behavior is preserved, not repaired by the allocation change.

## Correctness and negative controls

The comparison checks 23,004 inputs against the saved implementation. It
compares complete values and complete corruption reports, not only acceptance.
The corpus includes every one-byte string payload, raw invalid UTF-8,
truncations, control/delimiter mutations at varied ordinary and multibyte
offsets, mixed simple/Unicode/surrogate escapes, escaped duplicate keys and
container depths 255, 256 and 257. No parse throws an exception; all results
agree. The result digest is
`1bc4fa20a28b85f18da7b593b1b1cc23c88cbafe186bd28c65c14131e10b208b`.

The complete native core suite passes all 169 tests. Core lint reports zero
errors and 33 advisory warnings.

Three qcheck tests add independently spelled encoded/decoded fragments,
nested object keys and values, exact refusal positions/contexts after prior
document content, and a generator census. They use 400 cases with fixed seed
7343. All forty JSON-focused native tests pass, including the existing
roundtrip, boundary, depth and duplicate-key witnesses.

Four compiled semantic mutants in an isolated VM are rejected: wrong cursor
offset arithmetic, omitted UTF-8 validation, accepted unknown escapes and an
omitted low-surrogate range check. The original candidate is then restored
and both generated properties pass again. No production process or source was
mutated. Supplying the candidate as its own baseline also fails the allocation
improvement guard. The real baseline/candidate comparison passes the guard:
no fixture's counted allocation increases, the transcript saves at least 20%,
and both dense fixtures save at least 40%.

The core package still compiles to JavaScript. A supplemental execution of its
entire JavaScript test suite reports 160 passed and nine failures on both the
candidate and an isolated baseline source tree carrying the same new tests.
All three cursor properties pass on both. The matching existing failures are
four identifier/random-tail tests, the JSON adversarial corpus, and four
msgpack integer/depth/roundtrip tests. The repository's core gate executes the
Erlang suite; this supplemental result is not represented as a green full
JavaScript suite. No tests or assertions were removed or weakened.

## Reproduction and remaining gates

Build the baseline core package with the same Gleam, OTP and dependencies and
save `build/dev/erlang/core/ebin/core@json.beam`. Build this candidate, then run:

```sh
bash scripts/json_decode_compare.sh "$PWD" /absolute/baseline/core@json.beam --expect-improved
LOOM_TEST_TIMEOUT_SECONDS=120 bash scripts/test.sh core --match json
```

Raw comparison rounds, parsed medians, saved BEAMs and semantic-mutation
receipts are in `.notes/benchmarks/json-cursor/` in the originating worktree.
The baseline source remains reproducible at the pinned commit; local raw
artifacts are not committed.

One independent Astra implementation review found no actionable issues. It
replayed all differential inputs, the three properties and four mutants,
verified baseline-renaming safety and independently recomputed the recorded
medians. Documentation checks report zero errors and 225 advisory warnings.

The PR carries the current broad native, E2E and exact-head hosted/Linux
outcomes, separately from these focused receipts. Readiness is not inferred
from the benchmark or independent review alone. No install, live restart,
forced collection, hotpatch or merge is part of this PR.
