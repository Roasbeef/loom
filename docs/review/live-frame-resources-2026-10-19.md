# Terminal frame allocation investigation

Status: the sparse-canvas implementation passed independent review, repeated
measurements and the native terminal package gate. Hosted CI and the remaining
affected gates are pending. No live
process was restarted, collected, or patched during this investigation.

The original native affected gate and Linux CI subsequently passed on
`83dc17659` against `a602b31ea`. Its raw advisory macOS shard failed; two
targeted retries also failed, and the retry budget is exhausted. The last
remote-subagent provider-script assertion and agency teardown failure each
passed three unchanged native repetitions. No test assertion or skip changed.
Main then advanced to `ba4f13214`; the reviewed renderer source blob is unchanged
through this rebase, and the combined revision needs fresh integration gates.

The source baseline is `3cd33073961be8d9b9205decd0b51bd98bfb253f`.
The installed terminal reports that same revision. The installed helper's Go
build metadata also reports it; that does not identify the daemon's loaded
BEAM revision. Pickglass reports the daemon application revision as unknown.
The source candidate changes only the private `repaint_canvas` function in
`packages/tui/src/tui/render.gleam`.

## Fresh observations

The daemon and terminal run OTP 29 / ERTS 17.0.5. A one-shot daemon capture
reported 308,314,857 bytes of total VM allocation, including 225,363,728 bytes
of process capacity and 31,090,432 bytes of binaries. The terminal capture
reported 35,330,589 bytes total and 11,241,272 bytes of process capacity.
These are allocation categories at different observation cuts, not retained
terms or OS resident memory.

A thirty-second terminal profile counted 439 running/runnable samples and
23,561 waiting samples. `render_frame` appeared in 225 of the active stacks;
`refresh_frame_cache` appeared in 197. Screen-cell writes, array updates and
Unicode width measurement account for much of that sampled work. The daemon
profile counted only 81 active samples and lost five selected processes during
the window. It showed register reads, JSON decoding and web-frame encoding,
but does not support a precise daemon-wide ranking.

A bounded allocation pass over six terminal rendering modules observed 263
full-frame calls in 20.1 seconds. It attributed 1,516,135,256 bytes of cumulative
heap allocation to the selected modules. The old blank canvas reached
`fill_all_rows` for 190,699,896 bytes and `fill_rev` for another 68,432,976 bytes.
Function totals exclude traced callees and include untraced callees. This is
neither whole-client allocation nor retained memory, RSS, or a leak measurement.

A separate twenty-second daemon pass over the selected SQLite, register-cache,
page-socket and Lustre encoding modules recorded 55,655,800 allocated bytes.
`json_of_blob` accounted for 38,441,200 bytes. The limited process and module
selection does not establish a smaller cache or a decoder rewrite as a useful
next fix.

## Preserve the default instead of materializing it

The renderer used `buffer_new_filled(screen, " ", style)` before painting each
frame. Etui applies that one-character string to the first column of each row,
then pads the rest with `empty_cell()`. Its bulk constructor nevertheless
materializes the entire rectangular array.

The replacement starts with `buffer_new`, whose sparse array already has the
same empty-cell default. The ordinary repaint phase writes nothing. The
alternate phase writes a dim blank in the first column of each row, preserving
the existing invisible markers used when detail collapse vacates cells. The
frame still starts blank; it never reuses content from an earlier frame. All
subsequent rendering, clipping and palette adaptation use the existing buffer
API. No dependency, FFI, cache, timer or interface was added.

## Verification

A fixture-only VM extracts the old and new private canvas function bodies from
their compiled BEAM modules. All 28 combinations produce identical complete
cells and ANSI: both phases; zero dimensions; one-column rectangles; 80 by 24
and 200 by 50 screens; and zero or nonzero origins. At 200 by 50 cells, the
flattened canvas representation falls from 281,875 words to 502 in the ordinary
phase, or 23,217 in the alternate phase. Flattened representation is a copying
metric, not physical sharing, process capacity or RSS.

The existing full-render benchmark drives the same decoded six-agent model,
pinned clock, Unicode text and screen on both revisions. Its witness covers
every styled cell, hyperlink, continuation marker and cursor in the initial
frame and all forty scrolling frames. The first baseline and candidate produce
the identical SHA-256 witness
`2B8F2BD8912B32050122070159CDEF6A1CFC80D0A57FD9362EAE599C746E3CF5`.
Three sequential baseline/candidate VM pairs at 200 by 50 cells report:

| Work | Baseline median | Candidate median | Reduction |
| --- | ---: | ---: | ---: |
| Full paint, allocated words | 581,536 | 491,819 | 15.4% |
| Full paint, reductions | 215,570 | 190,411 | 11.7% |
| Forty scroll updates, allocated words | 26,531,611 | 22,930,350 | 13.6% |
| Forty scroll updates, reductions | 10,726,568 | 9,778,230 | 8.8% |

Each timed run warms ten samples first. The first pair uses the existing
100-sample driver; two corroborating pairs use a temporary copy with twenty
timed samples to limit host load. Allocation remains three separately traced
samples per work item in every VM. All three pairs produce the same allocation
triples for their respective baseline or candidate. Only the renderer BEAM is
overridden for the baseline, so every dependency and fixture remains identical.
Interrupted comparison attempts are excluded.

The median of per-VM paint times falls from 2.339 ms to 1.937 ms, and scrolling
from 65.780 ms to 60.493 ms. Individual scroll medians range from 65.6 to 190.3 ms
on the baseline and 59.7 to 77.0 ms on the candidate. This host was not quiesced;
we rely primarily on allocated words and reductions rather than treating those
wall times as installed-client CPU or input latency. A separate 80 by 24 pair
also preserves the complete witness: paint allocation falls from 245,647 to
228,524 words, and scroll allocation from 12,213,416 to 11,539,714 words.

Existing padding tests compare styled-cell output across narrow and wide
screens, including links, Unicode and alignment. The detail-collapse test proves
vacated transcript rows become blank after scrolling. These assertions remain
unchanged. Independent review approved the implementation and reran the
28-case canvas comparison.

The first package invocation encountered an inconsistent local Go installation.
Pinning the intact cached Go 1.26.8 toolchain fixed that prerequisite. The
sandboxed package run then passed 1,473 tests and failed six: five native
process-identity/lifecycle tests under the restricted environment, plus the
stream-throughput threshold during overlapping benchmark load. The benchmark
controller and its labeled fixture VM were stopped before native validation;
partial repetition logs are excluded from the performance comparison. No
assertions or skip declarations were changed. The unchanged native
`make check-tui` then passed all 1,479 tests in 21.06 seconds, including a
10,570-delta/second stream drain. Client end-to-end coverage and the remaining
affected gates remain pending at this documentation revision. Terminal lint
reports zero errors and 239 census warnings.

## CI fixture shutdown ordering

The rebased native affected gate passed in 811 seconds: 4,876 client tests,
1,539 terminal tests, global static checks, lint and a clean skip census.
Every hosted Linux job also passed, including the Rust Analyzer fixture and
all eleven jail enforcement probes. macOS exposed the agency fixture race
again: its deadline test passed, then the still-linked agency holder read the
writer during shutdown and terminated the following test.

The approved test-only repair retains the holder's original PID and monitor.
Cleanup unlinks and kills that holder, requires its own `Killed` notification,
and only then closes the runtime. This follows the existing provider-fixture
cleanup pattern. Existing behavioral assertions and skip rules are unchanged.
All 209 agency tests passed with three schedulers; independent review approved
the ordering and monitor ownership. The repaired revision needs fresh full
native and hosted gates. The client-path selector also requests conformance
and Linux signoff. The operator has authorized hosted CI as the Linux acceptance
evidence while the separate host is offline; no separate host signoff is claimed.
The renderer source is unchanged.

## Repeat capture during elevated CPU

A newly opened terminal was sampled for another thirty seconds after our
benchmark was stopped. Full-frame painting appeared in 393 of 656 active
samples, with span rendering, array writes and Unicode measurement underneath
it. A subsequent twelve-second OS-accounting window, with profiling detached
and no benchmark running, measured 27.1% of one core in the daemon and 24.3% in
the terminal. These are observations during active work, not an idle baseline
or a candidate comparison. Other build/test VMs were active on the host.

The repeated daemon capture counted 160 active samples, mostly register SQL
and filesystem operations. Its long-lived registry process was then sampled
directly at 200 Hz: 24 running/runnable and 2,976 waiting observations in
fifteen seconds. That does not justify treating it as the sole daemon CPU
cause. A five-second native sample overlaps a diagnostic snapshot and includes
VM literal-copy collection work; it is not used as steady-workload attribution.

## Evidence and limits

Raw captures and logs stay outside Git under
`/private/tmp/loom-fresh-2026-10-19-*` and `/private/tmp/loom-fresh-render-*`.
The private-function comparison is `/private/tmp/loom-fresh-canvas-check.log`.
The existing driver is `scripts/tui_perf.sh`, with the `render WIDTH HEIGHT`
scenario in `scripts/tui_perf.erl`.

The running terminal has not loaded this candidate, so installed CPU and RSS
savings remain unmeasured. The original process-table polling repair is already
in the installed helper build; this PR does not count it again. Other terminal
costs, particularly Unicode measurement and painting text, remain. The observed
page-link failures have a separate diagnostic problem: `authorize_for` maps
all `FrameRefusal` values, including registry unavailability and stale session
incarnations, to `AccessRevoked`. That mapping does not identify which refusal
caused a particular disconnect and is unchanged here.
