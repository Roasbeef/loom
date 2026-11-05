# Strand register decoding replay, November 5, 2026

The [November 4 profile](live-profile-2026-11-04.md) identified SQLite reads
and strand register decoding after the earlier JSON optimization. The parked
frontier already avoids repeated preparation loads; it still fetches and fully
decodes current strand state, operation state, configuration and leaf.

At source `0114f1dff2df8f3dcfa244a13dd838ab5b30dc62`, the only production
change is the private `machine/codec.get` field search. It walks directly to
the first matching key, removing the field-name closure and callback dispatch.
No register read, decoder, sequence check, timer, API or dependency is removed
or cached. Empty/missing searches and duplicate precedence keep their prior
answers. In particular, equal sequences never bypass corruption validation.

## Fixed production replay

The baseline is main `b103ddd2865d00c62940b5354a68c76d4cdca50d`. Its machine
codec and strand runtime sources match the profiled release `be9d81d843`.
The baseline BEAMs were saved before implementation. The codec SHA-256 is
`dd591ca727df2a05afae2afa59c35a804bd7f32d6ebd49a0316a9b4969104d00`;
the runtime SHA-256 is
`bd2d00910bf5df8e90afd35e7c9d163ad5313e0f66f366c40fa46faf0e0ae5e0`.

`scripts/strand_poll_replay.sh` uses Gleam 1.19.0 and OTP 29 / ERTS 17.0.5,
eight-byte words, and one normal scheduler in a fresh non-distributed VM.
It compiles both saved baseline and candidate codec forms with the same options
under isolated names. Only runtime aliases receive private exports, allowing
both sides to execute the real `poll_wait_unchanged` body. Every executable
runtime function AST must match the saved baseline. BEAM bytes alone are not
that guard: inferred type-variable names changed between builds while all
executable function bodies remained identical.

The existing `support/held_operation` fixture opens owned memory and SQLite
sessions, holds a fake assistant or summary request, and supplies the actual
writer, register payloads and parked frontier. Configuration has the fixture's
three tool names. The summary also carries its existing 1,360,000-byte
preparation in a separate register. Each successful observation resumes the
driver, releases the request, asserts settlement and closes/retires storage.
Exclusive run directories prevent reuse of a prior synthetic database.

Only the synthetic driver is suspended during measurement, preventing background
timer polls from changing the call count. The benchmark process makes exactly
1,000 unchanged poll calls per trial through real writer/backend actors; each
poll retains the four fresh register reads. There is no query-count reduction.
Eight timing rounds alternate version order. Four separate allocation rounds
also alternate order, using root-only `tprof.call_memory` on the benchmark
caller. CPU and reductions are VM-wide; allocation is attributed only to that
poll caller and its untraced callees, including reply-copy and decoding work.
No live process is inspected or modified by the replay.

## Results per 1,000 unchanged polls

Each cell is baseline / candidate. Work and allocation columns use millions
of reductions or words and are rounded to four decimals; percentages use the
unrounded medians.

| Backend / held request | VM reductions (M) | Reduction | Caller heap words (M) | Reduction |
| --- | ---: | ---: | ---: | ---: |
| Memory / assistant | 3.3012 / 3.0325 | 8.14% | 5.0390 / 4.9000 | 2.76% |
| Memory / summary | 3.1488 / 2.9472 | 6.40% | 4.7709 / 4.6657 | 2.20% |
| SQLite / assistant | 4.1278 / 3.8586 | 6.52% | 5.0843 / 4.9394 | 2.85% |
| SQLite / summary | 3.9329 / 3.7307 | 5.14% | 4.8089 / 4.7141 | 1.97% |

| Backend / held request | Median VM CPU (ms) | Median wall time (ms) |
| --- | ---: | ---: |
| Memory / assistant | 26.5 / 27.0 | 51.68 / 52.43 |
| Memory / summary | 28.5 / 28.0 | 53.62 / 53.47 |
| SQLite / assistant | 132.0 / 131.5 | 143.46 / 142.07 |
| SQLite / summary | 132.0 / 132.5 | 137.09 / 138.03 |

End-to-end CPU and wall timings are mixed. This experiment establishes lower
reduction and allocation counts, not a reliable elapsed-time improvement.
A separate loop decodes the captured strand/op/config payloads 10,000 times
per trial, without actor calls. Those 30,000 typed-decoder calls use about
12.1% to 14.4% fewer reductions; CPU medians are lower in that isolated loop.
The real actor/SQLite work remains in the complete polling replay above.

These measurements are fixture work and cumulative caller allocation. They
establish no retained-memory, RSS, physical-footprint or installed daemon-wide
saving. The baseline and candidate use the same writer, database and payloads
within each backend/request shape.

## Equivalence and negative controls

The replay checks 1,356 complete poll answers and read traces across both
backends: 433 assistant and 245 summary variations per backend. It preserves
sequences while varying malformed payloads, missing/unavailable replies,
changed sequences, key order, unknown fields and duplicates. A separate 1,272
comparisons check full typed values and `CorruptionReport` records directly
against the saved decoder. Counts include repeated cases across backends.

Four deliberately wrong variants are compiled only into isolated fixture
names: last duplicate wins, search only the first field, return null for a
missing field, and return unchanged without reading/validating. Every variant
is rejected for both backends and both held-request shapes. A compiler failure
or exception is not accepted as a killed mutant.

`--expect-improved` requires at least 2% fewer median VM reductions and 1% fewer
median caller words in every shape. It passes for the real comparison. Passing
the candidate as its own baseline exits 1 specifically at `no_improvement`;
this tests the combined guard rather than claiming each threshold was tested
independently. No elapsed-time assertion or test deadline is relaxed.

All 890 selected native tests passed without skip lines: machine 106, runtime
216, storage 379, session 73 and conformance 116. This includes frontier quiet
steering/configuration/leaf invalidation, recovery/corrupt-state behavior and
real jailed conformance paths. Three new fixed-seed qcheck properties run 300
cases each on Erlang and on Node, covering unknown fields, first-duplicate
precedence and complete refusal reports. The JavaScript build succeeds with
existing numeric-range/bit-array warnings in unchanged core code; the entire
machine JavaScript suite was not run. House lint has zero errors and 2,884
advisory warnings. PR validation records hosted outcomes separately.

## Reproduction

Build runtime in a clean checkout at `b103ddd28` with the same toolchain and
save `machine@codec.beam` and `runtime@strand_runtime.beam` from
`packages/runtime/build/dev/erlang/{machine,runtime}/ebin` into a baseline
directory. Build candidate runtime, then run:

```sh
bash scripts/strand_poll_replay.sh CHECKOUT BASELINE_BEAM_DIRECTORY --expect-improved
```

Raw final data, exact medians, baseline BEAMs, corpus digests, negative-control
logs and validation receipts are in this worktree's
`.notes/benchmarks/strand-poll/`. The final measured run is
`final-symmetric-replay.log`; the no-op control is `noop-symmetric.log`.
These files are intentionally untracked. Replaying at another load may change
timing and allocation observations; compare repeated rounds and retain the
negative control. No live restart, installation or hotpatch is performed.
