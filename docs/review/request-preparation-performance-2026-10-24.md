# Request preparation fast paths

This follow-up is measured against ef988f849 and belongs in the same PR as the
web-rendering, SQLite-read and closure-retention changes. No daemon update was
performed. These measurements do not establish a reduction in live RSS.

## Invariants

The harness retains the existing admission.image_bearing classification, which
includes admitted images absent from projected context. A text-only request
with images still selects its vision route or receives placeholders. An
image-reading model retains its context. Only an image-free text context skips
the identity placeholder projection.

For image budgeting, active protection is bounded by the actual image total.
When a positive limit already contains that total, protection cannot overflow
it. Returning the original history avoids the reverse/current-turn scan.
Nonpositive limits retain their error; over-limit refusals and trimming use
the existing path and wording. No public API, wire format, dependency, FFI or
process lifetime changes.

## Matched trials

Four alternating rounds run 2,000 calls each on OTP 29 with one scheduler and
eight-byte words. Saved unchanged baseline BEAMs are renamed and loaded into
the same disposable VM as the candidate. Inputs and dependencies are shared;
full output equality is checked outside timed loops. Warmup precedes timing.
Untraced CPU/reductions and tprof root-function cumulative allocation are
measured in separate passes. Earlier trials overlapping package gates were
discarded; only the isolated log supplies the committed raw trials.

| Boundary and workload | CPU ms before/after | Reductions before/after | Allocated words before/after |
| --- | ---: | ---: | ---: |
| Text-only request, 128 messages | 10 / 6 | 5,198,014 / 2,514,640 | 3,902,000 / 1,086,000 |
| Text-only request, 1,024 messages | 52 / 15.5 | 36,752,012 / 15,058,115 | 23,614,000 / 1,086,000 |
| Image budget, 128 text messages | 2 / 2 | 2,611,636.5 / 2,572,015.5 | 518,000 / 6,000 |
| Image budget, 1,024 text messages | 14 / 10.5 | 20,640,927 / 20,492,015 | 4,102,000 / 6,000 |

The raw trial artifact is authoritative for exact medians. CPU's millisecond
resolution makes the shorter trials imprecise. These are complete request/2
construction and project/3 boundaries, not complete provider preparation or
transport latency. The request fixture has no operation metadata, so admission
uses its missing-metadata branch rather than scanning a full active run.
Image-reading and one-image text-only controls retain allocation and nearly
identical reductions; image-budget refusal/trim controls also retain allocation.

The driver is scripts/request_preparation_perf.{erl,sh}; run the shell script
with a built candidate checkout and a directory containing baseline
harness@provider.beam and provider@image_budget.beam. Obtain those by building
harness tests at ef988f849 and copying the two files from its
packages/harness/build/dev/erlang/{harness,provider}/ebin directories before
building the candidate. The candidate's harness test build supplies the new
request fixture. Baseline source hashes at ef988f849 are image_budget.gleam
86aeac78b19171db9acd717beca7d187615adfc5c9234e956f0de5e398f8ed38
and harness/provider.gleam
3d5efe836473fcf126cdafc699c7e9169bb5fd9d91c2ed8b39ebac0a7a25df86.
Fresh baseline builds precede production edits, with only the test fixture added.
Saved BEAM SHA256 values are image_budget
7563281ecfd3feb96609262577970f49bf6ae211ab9ee6c265f722b0f3cafecd
and harness/provider
98fb045dc2a735c691a1af1858bf2dcbfd4dca9527df60974289084294fedae8.
Manifests and dependency declarations are unchanged.
Baseline captures and the isolated log are retained under
/private/tmp/loom-request-fastpath-baseline and
/private/tmp/loom-request-fastpath-bench-isolated.log.

## Validation

All 324 provider and 29 harness tests pass, with format, warning-free builds
and affected lints. New regressions also pass unchanged baseline production,
providing semantic witnesses rather than asserting implementation structure.
Independent report-only review found no actionable issue. All 33 client vision
regressions pass, including admitted-image-only routing, held-batch protection,
post-compaction boundaries and returning an image-free projection to text.
Documentation checking passes with zero errors and 229 existing warnings.

## Deferred work

Provider-definition duplication in service restart specifications needs an
ownership/lifetime design, rather than schema encoding chosen to shrink a term
metric. Coherent SQLite read batching needs a read-order/snapshot contract;
the current safe shortcut removes empty attribution queries only. A label
comparator micro-optimization would save about 0.12% of whole-page allocation
with one live label and is deferred. None of these is claimed as solved here.
