# Live daemon resource profile, October 14, 2026

Pickglass attached to the installed `loomd` built from
`13508cb5895e338aa60109259f66c025d81447c6`, running OTP 29 / ERTS 17.0.5.
The launcher records this commit; Pickglass itself reported unknown build
metadata. Five session owners and ten strand owners were present in the first
capture. The owner confirmed that the active UI was the web view; no terminal
client was running for this workload.

The candidate is runtime commit `6435d874b` on baseline `7f82bb498`, changing
`packages/runtime/src/runtime/strand_runtime.gleam` and its regression.
No installed daemon was restarted or hotpatched, and no forced GC or live
process-state walk was requested. Raw captures remain local because they carry
process and owner identities. Only aggregate counters and function names appear
here.

## Live CPU and allocation

A ten-second sample selected sixteen processes by reductions per second.
Of 10,000 observations, 230 were running/runnable and 9,770 waiting. JSON
parsing appeared in 192 of the 230 active observations. A second ten-second
sample during the owner's reported spike counted 772 running/runnable and
9,228 waiting observations, with JSON parsing in 643 active observations.
The OS CPU cut immediately before that second sample was 119.3%, with
608.23 MiB RSS. These percentages are sample shares, not a daemon-wide CPU
attribution. Stacks are limited to eight frames and sampled at reduction
safepoints, so long NIFs can be underrepresented.

The first selected-module allocation probe covered `core@json`,
`storage@sqlite` and `session_view*` in eight processes. Its requested five
seconds took 9.05 seconds as observed by the profiler. It counted
209,169,539 heap words (1,673,356,312 bytes), with all called-function counters
readable. Leading allocation totals were:

| Function | Calls | Allocated bytes |
| --- | ---: | ---: |
| `core@json:parse_string_body/2` | 1,434,880 | 474,630,480 |
| String-body continuation | 1,349,036 | 269,820,840 |
| `core@json:skip_whitespace/1` | 1,420,236 | 164,748,776 |
| `core@json:parse_escape/2` | 929,228 | 154,217,264 |

A follow-up three-second probe selected four processes and traced the register
cache and SQLite modules. It observed 3.09 seconds. Of 296 register-cache reads,
22 entered the expensive `decode_blob` continuation, accounting for
1,366,858,968 bytes of heap allocation while it ran. This includes its untraced
JSON callees. The 274 smaller reads followed the cache lookup path. A read-only
SQL query of payload lengths, without retrieving payload contents, found one
1,577,693-byte `op.preparation` register in the active session inventory. It
exceeds the cache's 262,144-byte admission ceiling.

The scoped storage/codec call trace exhausted its 100,000-event budget after
613 ms of a requested two seconds. Its leading exclusive costs were the
register point-read and list-read decode continuations. This truncated trace
identifies callers; it does not establish a steady-state request rate.

## Memory census

| VM allocation category | First cut (MiB) | Later cut (MiB) |
| --- | ---: | ---: |
| Total | 438.36 | 468.89 |
| Processes | 323.97 | 349.70 |
| Refcounted binaries | 65.61 | 70.34 |
| ETS | 1.96 | 1.97 |

The first census counted 849 processes and included detailed rows for 200.
The largest listed process allocation was 15.91 MiB in a provider request
worker; several actor and supervisor allocations followed. These are allocated
heap capacities, not exact reachable-state sizes. Categories overlap and must
not be summed. The two cuts cover a changing active workload and establish
neither a leak nor an optimization result. Allocator carriers and physical
footprint were not separately measured in this round.

## Removed work

`strand_runtime.load_operation` previously listed preparation registers to
collect their keys, discarded the decoded values and point-read the first key
again in `load_preparation`. Every reload therefore decoded and transferred
an oversized preparation twice. The candidate decodes the first value already
returned by the listing and retains every listed key for terminal cleanup.
The first-value ordering, total structural decoder and empty-list behavior
remain. Each reload still queries storage; no new cache or stale-value lifetime
is introduced. There is no public interface change.

The end-to-end regression supplies a large synthetic branch-summary
preparation through a counted memory store. It proves that the summary provider
receives the complete preparation, navigation completes and terminal cleanup
removes the register, with zero preparation point reads. Against an unchanged
baseline archive, the same test completes those behaviors but fails its
zero-read assertion with six point reads.

## Matched SQLite measurement

The comparison runs the regression's operation sequence against real SQLite:
two seed turns followed by a generated navigation summary, with 1,360,000
bytes of synthetic message text in the frozen preparation. Both versions use
the same fixture, toolchain, single-scheduler VM and cache bounds. Each run
starts a fresh VM and database. Timing and allocation tracing run separately.
Five timing runs alternate baseline and candidate; two allocation runs per
version trace only `storage@internal@register_cache:decode_blob/1` in the
fixture and its descendants. Its untraced JSON callees are charged to that root.

| Measure | Baseline | Candidate | Reduction |
| --- | ---: | ---: | ---: |
| Median operation-sequence elapsed time | 1.452695 s | 0.802891 s | 44.73% |
| Timing range | 1.443699–1.478596 s | 0.776128–0.926613 s | — |
| Register-decode heap words, run 1 | 200,097,078 | 99,410,433 | 50.32% |
| Register-decode heap words, run 2 | 200,097,214 | 99,412,968 | 50.32% |
| Preparation point reads | 6 | 0 | 100% |

Heap words are cumulative allocation, with eight bytes per word on this VM.
They exclude retained heap, off-heap binary payloads and native memory.
The reduction is for this synthetic operation sequence, not live daemon CPU
or RSS. The installed daemon still requires an approved update and a matched
live capture before claiming production savings.

## Reproduction and verification

Local raw captures use `/private/tmp/loom-profile-20261014-*.pgcap`.
The unchanged baseline archive is
`/private/tmp/loom-profile-20261014-baseline`; the synthetic SQLite fixture is
its `packages/runtime/test/support/preparation_perf_fixture.gleam`.
The runner and alternating raw results are in
`/private/tmp/loom-profile-20261014-bench/`. The runner takes a built checkout,
the checkout holding the compiled fixture and either `time` or `allocation`.
These local scratch artifacts are not part of the release.

```sh
pickglass attach --state-dir "$HOME/.loom" --once --out before.pgcap
pickglass profile --state-dir "$HOME/.loom" --top 16 --seconds 10 \
  --rate 100 --format pgcap --out cpu.pgcap
pickglass profile --state-dir "$HOME/.loom" --allocation --top 4 --seconds 3 \
  --module 'storage@internal@register_cache' --module 'storage@sqlite' \
  --format pgcap --out cache.pgcap
LOOM_TEST_TIMEOUT_SECONDS=90 bash scripts/test.sh runtime --match preparation_listing
make check-runtime
make lint-runtime
```

The candidate passed the focused regression, all 203 runtime tests and the
runtime package gate, including its projection measurements. Runtime lint
passed with zero errors. Independent adversarial review found no actionable
correctness, simplification or nearby variant findings in the changed path. The unchanged baseline failed only the new
zero-point-read assertion in the focused comparison. Full repository tests,
hosted CI and Linux signoff have not been run for this candidate.
