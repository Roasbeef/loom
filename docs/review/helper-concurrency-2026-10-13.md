# Concurrent native helper measurements

October 13, 2026. Compare the complete idle-retirement stack at
`b28dd654e2cb05a5f05257ea149cddfc91ebfadb` with the protocol-4 implementation
at implementation commit `8d21799a5` on `codex/helper-concurrency`. This is stacked on [PR #975](https://github.com/Roasbeef/loom/pull/975).
The installed daemon was not rebuilt, restarted, collected or changed.

## Result

Packing four execution slots into each native helper reduces active helper
memory substantially in this Mac fixture. It also slows short parallel command
batches. Sequential command medians remain close to the baseline. These results
support a memory tradeoff, not a general throughput improvement.

| Median | 1 slot, baseline → candidate | 4 slots, baseline → candidate | 8 slots, baseline → candidate |
| --- | ---: | ---: | ---: |
| Native helpers | 1 → 1 | 4 → 1 | 8 → 2 |
| Summed helper RSS, KiB | 13,472 → 13,008 | 53,520 → 15,360 | 107,520 → 32,480 |
| Pool + unique helper actors after GC, bytes | 12,120 → 15,136 | 33,672 → 15,024 | 63,424 → 27,272 |
| Cold checkout + first batch, ms | 58.851 → 54.719 | 49.868 → 34.526 | 74.794 → 46.891 |
| Warm sequential command, ms | 19.284 → 19.138 | 18.886 → 18.952 | 19.426 → 19.594 |
| Warm N-command batch, ms | 18.946 → 19.131 | 21.240 → 24.869 | 25.353 → 33.532 |
| Warm checkout/checkin cycle, µs | 13.9015 → 10.6670 | 15.9185 → 10.0305 | 16.6435 → 11.3265 |
| VM CPU per warm cycle, µs | 7.0 → 6.0 | 9.0 → 5.5 | 9.5 → 6.5 |
| Actor reductions per warm cycle | 637.7130 → 639.3015 | 761.9765 → 637.3580 | 895.1935 → 671.1175 |

Four slots save 37.27 MiB summed helper RSS, or 71.3%; eight save 73.28 MiB,
or 69.8%. Summed RSS can count shared pages repeatedly. These are helper-only
synthetic measurements, excluding payload descendants and the driver. They do
not establish physical RAM savings or a reduction in the running daemon's
memory. Post-GC actor memory measures retained allocation, not allocated bytes
per call; only the synthetic actors were collected.

Submitted short-command batches cost 17.1% more at four slots and 32.3% more at
eight. Eight-slot candidate samples range from 27.384 to 87.908 ms, versus
23.757 to 37.612 ms on the baseline. Sequential medians increase 0.35% and
0.86%, respectively, with overlapping ranges on this active development host.
Cold batches improve 30.8% and 37.3% in this fixture because fewer native
processes need starting. Neither result establishes a production percentile.
Warm-cycle CPU covers the benchmark VM; it excludes Go helper CPU and does not
measure total tool CPU. No end-to-end distributed RPC latency or Linux latency
was measured. Local and distributed workspace planes share the changed pool,
but this benchmark exercises the local helper boundary directly.

## Method and reproduction

Use `scripts/helper_concurrency_perf.sh RUNNER_ROOT BASELINE_ROOT CANDIDATE_ROOT ROUND`
against two already-built complete roots. The runner starts a fresh OTP 29 VM
with one scheduler per version. Three sequential matched pairs alternate order
baseline/candidate, candidate/baseline, baseline/candidate. Wire versions are
never mixed by replacing an executable beneath a built broker.

The short-command batches submit N commands before awaiting their results;
these tiny payloads can finish during admission, so only the memory barrier
proves N simultaneously live payloads.

Each version tests ceilings of one, four and eight execution slots. Each fixture
runs a cold batch, 100 warmup checkout/checkin cycles, seven batches of 2,000
warm cycles, 35 sequential commands, five parallel batches and one memory
barrier. Across three pairs this yields 18 cold batches, 126 warm microbatches,
630 sequential commands, 90 parallel batches and 18 memory barriers. Each
version/slot combination has three cold and memory samples, 21 warm
microbatches, 105 sequential commands and 15 parallel batches. Tables use pooled
sample medians, not the median of per-round medians.

Every command has distinct stdout on its own subject and must exit zero without
timeout or cancellation. All memory-barrier payloads emit their distinct start
markers and remain alive behind a filesystem gate before RSS is sampled. Thus
the concurrent count cannot be satisfied merely by executing short commands
sequentially. Native PIDs come from the fixture VM's ports; the expected count
is asserted. Closing each pool must succeed and every owned helper PID must
disappear. All 18 close witnesses passed.

The policy is identical across versions and uses BestEffort on macOS. The
runner explicitly asserts Seatbelt filesystem and network layers. Reports say
`degraded=false`, but also list unavailable address-space, process-count and
Darwin process-lifecycle layers. The host already exceeded the requested
process count. These skips remain platform limitations; the measurements do
not prove stronger descendant containment.

All three runner invocations returned exit 0. Raw logs stay outside the repo:
`/private/tmp/loom-helper-concurrency-perf-{1,2,3}.log`. The committed runner and
this compact report are the review artifacts.

| Artifact | SHA-256 |
| --- | --- |
| Baseline native helper | `417bae11f21468f26abb9d47e1c0ac13dc439216ac49a0c12da7fb5f00fe6082` |
| Candidate native helper | `28784777b05d204a0834a960814d88c13029aa3291fc3a01b276a24d3320d98e` |
| Baseline broker beam | `c14dec4b1d20f9ac115ccf27e0b2a3cf0223c208c72e47038f718eea835bdc2d` |
| Candidate broker beam | `962a9b06ad5c1199662e454c41e2c3911e38027271d98dd67ed9bc3a90e8611f` |

## Correctness and remaining platform evidence

The protocol and ownership changes are described in
[proposal 087](../../protocol-change/087-concurrent-helper-executions.md).
Per-checkout leases fence stale handles; per-execution IDs route controls and
output; the configured ceiling still bounds all reserved execution quotas,
including failed retirement. Physical helper failure settles its accepted
siblings. The last returned lease starts idle retirement.

Independent lifecycle review found one control-envelope conformance mismatch.
Cancellation now mints a fresh envelope ID while preserving the execution ID
as its target; the reviewer verified the correction. No reachable high- or
medium-severity correctness issue was found. The final native `go test -race
./...` passed every package.

Native cleanup now precedes terminal delivery, followed by a registry-locked
terminal write/removal. This prevents an immediate refill from seeing a
completed execution as a busy slot. A deterministic delayed-write regression
rejects the earlier ordering. Moving Linux cgroup cleanup onto this critical
path may add completion latency; it was not measured on Linux. Linux
containment and latency require their own validation before relying on these
Mac results for deployment.

Three private broker mutations compiled successfully and failed the intended
assertions: removing the stale-lease gate, counting physical helpers instead of
reserved execution quotas, and treating a partial lease return as idle. The
private baseline passed the controlled tests, and shared source/build artifacts
remained byte-identical. Together with the native refill-order mutation, these
checks demonstrate that the new regressions reject the protected failure modes.
The evidence review independently recomputed the table and inspected the
barrier, PID ownership, output/exit checks and all close witnesses.

The first full gate stopped at the client package: 4,471 tests passed and 20
failed at an unchanged daemon fixture's five-second readiness wait, before
helper dispatch. The first failed test then passed in 0.114 seconds, and all
25 tests in the three affected modules passed together at parallelism eight
with their original readiness deadlines. This establishes non-reproduction,
not a diagnosed flake. The unchanged full rerun passed exit 0, including 419 broker, 4,491 client,
1,365 TUI and all remaining packages, native checks and lint (zero errors).
No source, test or readiness deadline was changed between runs. Logs are
`/private/tmp/loom-multiplex-full-check.log`,
`/private/tmp/loom-multiplex-client-move-repro.log` and
`/private/tmp/loom-multiplex-client-group8-repro.log`.

The successful full gate log is
`/private/tmp/loom-multiplex-full-check-2.log`. Documentation checks also passed
with zero errors. Hosted Linux/macOS CI remains a separate gate.
