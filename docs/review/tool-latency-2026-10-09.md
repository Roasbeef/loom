# Tool response latency baseline

Measured on October 9, 2026, in the isolated `5086/loom` worktree at
`91dbdef947ca9afa0bffeb77f82d0f6df92efb53` with the uncommitted benchmark
additions. Runtime: macOS, sixteen BEAM schedulers, Gleam 1.19.0, OTP 29,
ERTS 17.0.5. No installed daemon or client was restarted.

We extend the existing real-helper benchmark rather than introduce another
executor fixture. `make bench-tool-latency` runs the broker, executor service,
helper pool and real Seatbelt jail under production `PlatformEnforcement`.
The response probes assert successful completion, exact output byte counts,
and no truncation, including the response exactly at the 1 MiB ceiling.

## Results

Two consecutive runs completed in 3.362 and 3.229 seconds of benchmark time,
excluding build and emulator startup. Values below are milliseconds; p50 and
p95 use nearest rank. Each run has ten cold commands and thirty commands per
warm workload, following an untimed complete warm-up command.

| Probe | Run 1 p50 | Run 1 p95 | Run 2 p50 | Run 2 p95 |
| --- | ---: | ---: | ---: | ---: |
| Helper spawn to ready | 6.126 | 6.695 | 6.189 | 6.823 |
| Cold pool, no-op | 30.943 | 36.159 | 31.791 | 33.192 |
| Warm pool, no-op | 18.194 | 19.499 | 18.227 | 19.497 |
| Warm shell, five bytes | 20.695 | 25.002 | 20.650 | 22.122 |
| Warm shell, 4 KiB | 21.642 | 24.464 | 21.215 | 24.939 |
| Warm shell, 1 MiB | 23.168 | 26.776 | 23.256 | 27.899 |

Warm clearance medians were 0.144 to 0.177 ms in run 2. First output arrived
at 19.614 ms for the small shell response and 20.872 ms for 1 MiB. Settlement
after the last output took 1.054 and 1.172 ms respectively. These are
caller-observed intervals, not timestamps from inside the payload. The
[JSON record](tool-latency-2026-10-09.json) preserves samples, summary values,
and one representative complete enforcement report per workload. Original
JSONL files in `packages/broker/build` retain every report.

Seatbelt filesystem and network layers were present on every measured call.
The reports explicitly carried Darwin's accepted address-space, account-wide
process-limit and descendant-lifecycle gaps. The mode did not substitute
BestEffort when enforcement failed.

A one-off Python `subprocess.run(capture_output=True)` control executed the
same argv with `PATH=/usr/bin:/bin`, one discarded warm-up and thirty timed
commands, checking exit and exact output. Medians were 1.745 ms for no-op,
4.299 ms for the shell, 6.158 ms for 4 KiB and 7.366 ms for 1 MiB. This control
includes Python process/pipe costs and was run under the outer tool sandbox;
it is context rather than a precise subtraction from the BEAM/jail path.
The repeatable committed command is the real-jail benchmark above.

## What to optimize next

**Measure job completion observation first.** The production bash Auto path
runs `tools/bash.look`, which asks its job seam to wait for up to 500 ms.
`client/jobseam.poll_for` delegates to `jobs.await_job`, which uses
`weft/poll.fold_until` with doubling sleeps from 25 to 250 ms. It checks
terminal state after each sleep; completion does not wake the sleep. A fast
command can therefore spend more time awaiting observation than running in
the jail. The next experiment should time real `bash` Auto calls against
broker settlement on the same clock, including 20 ms, 100 ms and longer
commands. If that measurement confirms the delay, a weft-based completion
notification is preferable to reducing sleep intervals and increasing polls.

**Profile fresh jail setup before changing pooling.** A warm helper still
costs about 18 ms for a no-op while broker clearance costs about 0.15 ms.
This points to fixed execution setup/teardown rather than admission, but
does not attribute individual Go/kernel operations. Warm helper reuse already
exists. Reusing a payload jail would change isolation and needs a separate
design; these numbers do not justify it.

**Keep output optimization proportional to its measured cost.** Moving from
4 KiB to 1 MiB adds about 2 ms to the median here. This binary-stream workload
does not measure text assembly, durable storage, JSON encoding or transcript
rendering. Code-mode vetting, compilation and satellite startup also remain
outside this experiment. Multi-second delays need those layers measured,
rather than being attributed to these 18 to 23 ms executor round trips.

## Validation

Both real-jail benchmark runs returned exit 0. The broker build passed with
warnings treated as errors, and targeted lint reported zero errors and zero
warnings. An independent advisor-review pass over the working-tree benchmark
and Makefile found no actionable findings. It used the available independent
model because the skill's named Fable/Opus models were unavailable.

The broker regression suite returned exit 0 in 80.49 seconds, with all 401
tests passing. Two existing witnessed-kill probes reported their explicit
Darwin skip because they require Linux `/proc`. Linux,
the longer legacy fault/census benchmark, hosted CI and the full repository
gate were not run for this local benchmark addition. This establishes a local
macOS baseline, not Linux performance or installed-session latency.
