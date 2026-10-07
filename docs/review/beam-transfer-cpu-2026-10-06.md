# Snapshot sizing CPU optimization, October 6, 2026

In this pass, we replace the snapshot metadata size walk's Unicode list with
a direct UTF-8 byte scan. Pickglass observed this work in the live daemon;
matched disposable-VM fixtures then measured the candidate against the
original module. Complete transfer-start fixtures use about 71% fewer BEAM
reductions for many small strings, 91% fewer for a large ASCII value, and
78% fewer for a large Unicode value. These are source fixture results. The
candidate has not been installed or measured in the running applications.

## Source and running identities

The CPU control is `52ebb1a4f`, and the implementation is `8d37bf994`, on
`codex/perf-live-render-20261006`. The worktree is
`.worktrees/perf-live-render-20261006`. Only the private string-size walk and
two tests with their test-side counter changed. The preceding render and CI
work is documented in [the render investigation](beam-render-2026-10-06.md).

The observed daemon remains PID 53549, installed from
`~/.local/lib/loom/server.bRY4moOX`; the active terminal remains PID 67235,
from `~/.local/lib/loom/client.CfFYJjsd`. Both embed revision
`11454cba77ca96acc6b3be85f1da72ba469dd976`, predating the previous merged
render optimization. No application was restarted, hotpatched, or forced
through collection. No conversation contents, dictionaries, mailbox contents
or credentials were read. The terminal is an unnamed node; it needs a
profile-enabled launch before distributed Pickglass can attribute its work.

## Observed caller and allocation

A fresh ten-second Pickglass CLI profile pinned eight busy processes at
100 Hz. It completed with 8,000 samples, only 15 running/runnable and 7,985
waiting. One running stack reaches `client@daemon@transfer:quoted_size/1`
and the Unicode decoder. Fifteen samples cannot rank broad CPU costs. A
five-second native sample of helper PID 20738 mostly shows condition-variable,
kevent and nanosleep waits; it supplies no evidence for a helper busy loop.

A separate five-second allocation probe pinned four busy processes and
matched `client@daemon@transfer` and `core@json`. It observed 5.02 seconds,
99 matched functions, 60 called functions, and an allocation reading for
every called function. All 60 readings were listed.

| Function or aggregate | Calls | Allocated words | Instrumented call time |
| --- | ---: | ---: | ---: |
| `transfer:quoted_size/1` | 2,374 | 484,592 | 12.72 ms |
| `core@json:clean_run/2` | 98,485 | 59,167 | 13.89 ms |
| All matched functions read | | 850,901 | |

The quoting walk accounts for 57% of the matched cumulative heap words in
this selected window. That percentage is neither whole-daemon allocation
nor CPU share. Call time is instrumented, not an untraced CPU measurement.
Words exclude off-heap binary payload, ETS and native allocations. Traced
callees have their own readings; untraced callee allocations accrue to their
traced caller. Both CLI probes returned zero and released their pins;
Pickglass reports that its agent modules were unloaded.

`client/gateway` calls `transfer.start` when assembling a snapshot;
`transfer.start` calls `encoded_size` before allocating serialized metadata.
That walk sizes every string value and object key, then refuses metadata
outside the existing 2 MiB conservative bound. The original quoting helper
constructed a codepoint list and folded it only to count encoded bytes. The
live probe observed four transfer starts and 2,374 quoting calls, so the work
is reachable through ordinary snapshot assembly.

## Preserved admission behavior

The private byte loop starts with two bytes for surrounding quotes. C0
controls still cost six, including controls which the JSON serializer writes
with shorter escapes. Quote and backslash cost two; every other UTF-8 byte
costs one. Four consecutive ordinary bytes advance together. Splitting a
multibyte sequence while counting cannot change its width: all its bytes are
above the ASCII escape range, and no substring is returned or decoded.

There is no new production FFI, public interface, dependency, wire format or
process machinery. Admission boundaries, the serializer, transfer deadlines,
fragment limits and custody remain unchanged. The loop still scans a whole
string before comparing its size with the remaining budget; this pass does
not introduce a new early-refusal policy.

The boundary regression compares against the old codepoint model for all 32
C0 controls, quote, backslash, ASCII, two-, three- and four-byte Unicode,
combining text, and eight prefix offsets across the four-byte chunk boundary.
It checks 320 string values and 320 objects with identical text as a key and
value: exact budgets admit, one-byte-smaller budgets refuse, and serialized
object bytes stay below the conservative estimate.

The work regression independently computes the expected size before tracing,
then counts calls to the Unicode decoder while sizing a large mixed string.
Its test-only OTP adapter requires exactly one matching function, traces only
the calling process and always stops its private session through `after`.
The candidate makes zero decoder calls. Overlaying the saved original module
makes this same test fail with 81,931 calls. The boundary regression is a
compatibility check; it intentionally also passes with the original algorithm.
All 13 transfer tests pass with the candidate. Forty executions of the two
new regressions also pass at parallelism eight. A disposable-VM verifier
checks that callback exceptions and those concurrent tests leave the trace
session inventory unchanged.

## Alternating control and candidate

Fresh single-scheduler OTP 29 VMs alternated control, candidate, control,
candidate, using Gleam 1.19.0 and the same compiled dependencies. The control
overlays only the saved original `client@daemon@transfer` BEAM. Each fixture
warms up before untraced reductions and timing; cumulative allocation is a
separate traced pass. The result term's fingerprint matches between both
implementations and across both repeats for every sizing and start fixture.

The many-small-strings fixture has 400 object fields with 34-byte ASCII
values. The large ASCII string repeats ordinary words to 120 KiB; Unicode
repeats a three-byte character, a four-byte character, and combining text to
80 KiB. The control string repeats all C0 bytes to 64 KiB. The refusal fixture
is a 2 MiB-plus-one ASCII value; surrounding quotes also count. Accepted
fixtures run 100 operations, and the refusal fixture runs ten. Transfer-start
fixtures use an empty snapshot cut, isolating metadata sizing plus real
serialization and transfer construction. They do not include storage reads,
network delivery, browser rendering or end-to-end turn latency.

| Fixture | Sizing reductions removed | Full start reductions removed | Full start words, control to candidate |
| --- | ---: | ---: | ---: |
| 400 small strings | 87.81% | 71.36% | 9,842,614 to 3,005,593 |
| ASCII, 120 KiB | 95.86% | 90.63% to 90.64% | 50,240,565 to 9,218 |
| Unicode, 80 KiB | 89.62% to 89.63% | 78.27% | 13,115,419 to 8,273 |
| C0 controls, 64 KiB | 83.39% | 8.21% to 8.26% | 826,168,417 to 800,277,215 |
| Refused oversized string | 95.87% | 95.87% | 83,886,359 to 239 |

Candidate sizing reductions repeat exactly: 1,472,006 for small strings,
3,073,312 ASCII, 2,049,314 Unicode, 6,554,916 controls, and 5,243,032 refusal.
Full-start counts repeat exactly except the control-heavy serializer, whose
collection costs vary slightly. All allocation totals repeat exactly.

Untraced full-start timings across the two runs are 58 to 72 ms versus
25 to 26 ms for small strings; 256 to 356 ms versus 34 to 35 ms ASCII;
87 to 90 ms versus 23 to 24 ms Unicode; 4,070 to 4,076 ms versus 3,896 to
4,008 ms controls; and 530 to 557 ms versus 21 to 22 ms refusal. Scheduler
and collection variation make reductions the stronger repeatable comparison.
The control-heavy result shows the limit directly: serialization still does
most of its work. Large-string savings do not predict typical installed turn
latency, total daemon CPU or resident-memory improvement.

## Validation and review

The implementation compiles warning-free and its two Gleam files pass the
pinned formatter. A fresh report-only independent review of
`52ebb1a4f..8d37bf994` found no actionable invariant, simplification or nearby
variant issue. It checked valid UTF-8 equivalence, unchanged conservative
budgets, and the counter's private-session cleanup and false-pass boundary.
That review was source-only and ran no workloads.

The prepared affected gate for this CPU diff against `52ebb1a4f` returned
its own zero exit status after 557 seconds. Whole-tree static checks, server
shipment preparation, all 2,947 client tests, all 97 seeded conformance tests
and the selected skip census pass. The formerly intermittent gateway
regression passes in this run; its earlier failures remain unexplained.
Lint reports zero errors and 2,176 warnings, and doc-check reports zero errors
and 196 warnings. The one added lint census entry is R18: the existing
`quoted_size` helper is now a three-line wrapper with one calling function
and two call sites. Its byte conversion is shared by values and keys; it
adds no failing rule. Linux signoff is required because the changed client
package also builds the daemon; none has run.

The whole branch also contains the separately approved CI repair. Its earlier
full local affected wrapper remains red on two undeclared existing Linux
`/proc` fixture skips on Darwin. The previous report records all local package
passing results and the intermittent gateway-test failures. Those results
predate this CPU source and do not certify it. No skip declaration was added,
no tests were weakened, and no candidate hosted checks or installation ran.

## Reproduction and remaining measurement

Use a non-login shell with
`PATH=/Users/roasbeef/.local/lib/loom/server/bin:/opt/homebrew/bin:$PATH`.
Verify Gleam 1.19.0 and OTP 29. The bounded probes were:

```sh
pickglass profile --pid 53549 --top 8 --seconds 10 --rate 100 \
  --out /private/tmp/loom-live-20261006-cpu-round3.speedscope.json
pickglass profile --pid 53549 --top 4 --allocation \
  --module client@daemon@transfer --module core@json --seconds 5 --format text
```

Private live logs share `/private/tmp/loom-live-20261006-cpu-round3`.
The fixture module, runner, saved original BEAM and four alternating logs are
in `/private/tmp/loom-live-20261006/` as `transfer_perf.erl`,
`run_transfer_perf.sh`, `transfer-control-ebin/`, and `transfer-perf-*.log`.
The focused test, negative control and prepared gate logs share the prefix
`/private/tmp/loom-live-20261006-transfer-`. Earlier affected logs were saved
in `/private/tmp/loom-live-20261006/affected-before-transfer/` before the new
run reused the worktree's `build/affected/` directory.

Obtain the required exact-head Linux signoff and resolve the full-branch
Darwin census before claiming readiness. Publication and installation need
separate direction. A named profiling client and a matched active workload
are still needed for direct client attribution and installed CPU savings.
The quiet live sample is insufficient to choose another broad hotspot;
SQLite bursts and the control-heavy serializer remain workload-dependent
costs outside this private sizing fix.
