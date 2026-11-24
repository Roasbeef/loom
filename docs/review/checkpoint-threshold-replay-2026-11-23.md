# Runtime checkpoint threshold replay

The strand driver evaluated the compaction threshold on every planner pass.
In the daemon that can fetch the session's hooks from their holder, read
`strand.config` through SQLite, and estimate the projected context. The
planner consumes the result at a running checkpoint. We now keep the call at
that boundary and supply `ThresholdNotExceeded` on other passes.

The planner still orders inbox work, checks the run's captured compaction
settings, and deduplicates threshold decisions by trigger. The runtime still
loads and projects the durable strand before planning.

## Fixed replay

The replay compares the actual baseline and candidate `build_inputs` functions
against the same planner. It starts a held assistant request over the real
SQLite store, then uses a deterministic hook that reads `strand.config` through
the writer and returns a fixed threshold signal. The baseline is
`1d90162d905f8012307b7c29f586f2be37d929e2`.

Starting, assistant, and cancelled-checkpoint passes drop one hook call.
A running checkpoint still makes one call and a crossed threshold changes its
action. The complete planner actions match across all four cases. A replay of
the baseline against itself fails the missing-call witness.

| Measurement, held assistant | Before | After |
| --- | ---: | ---: |
| SQLite queries for reload and plan | 8 | 7 |
| Caller heap words attributed to input building | 253 | 29 |
| Median reload and plan, µs | 545 | 525 |

Timing used six alternating rounds of 400 passes with one normal scheduler on
Darwin arm64 and OTP 29. The median reloaded pass fell about 4% in this run,
with overlapping ranges across rounds. The query count is exact. The
allocation trace measures cumulative caller heap words. The fixture does not
model the daemon's complete threshold estimator or measure resident memory.

Build the baseline runtime and save `runtime@strand_runtime.beam` from its
development build. Build the candidate runtime, then run
`bash scripts/checkpoint_threshold_replay.sh /path/to/runtime@strand_runtime.beam`.
