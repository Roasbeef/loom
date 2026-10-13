# Current handoff

Baselined October 13, 2026 on `codex/helper-concurrency`, starting from
`b28dd654e2cb05a5f05257ea149cddfc91ebfadb` on the open idle-retirement
[PR #975](https://github.com/Roasbeef/loom/pull/975). This is a separate,
stacked concurrency change. The parent main was `dc70d25d4` (v0.3.2).
The installed daemon remains untouched; no merge, installation, restart or
recurring automation was performed. The broader project plan remains
`docs/issue-plan.md`.

## Concurrent executions per native helper

The user explicitly requested a working concurrency implementation in a
separate PR. [Proposal 087](../protocol-change/087-concurrent-helper-executions.md)
records the protocol-4 wire changes, capacity semantics and shared failure
domain. Broker and helper must be rebuilt together. Capability-channel
cancellation keeps its existing encoding.

One Go helper and one BEAM owner carry at most four concurrent jailed
executions. Each checkout receives a registered single-use lease; stale
handles cannot dispatch, cancel or return another borrower's capacity. Each
execution has independent stdin, output and cancellation deadlines. The
configured pool size still bounds execution slots, including all quota held
by draining or unconfirmed helpers. A shared helper failure settles every
accepted sibling once. Idle retirement starts only when the last lease returns,
and still requires native exit plus the original normal owner-exit witness.

Stdin admission refuses overflow without blocking sibling controls and cancels
only the overflowing target. Terminal cleanup precedes the terminal report;
registry removal is serialized with that report to prevent a refill from
seeing stale full capacity. Linux cgroup cleanup is consequently on the
completion path. Its latency and Linux containment have not been validated
locally. Do not claim the Mac measurements establish Linux deployment readiness.

## Evidence and gates

The [measurement report](review/helper-concurrency-2026-10-13.md) and committed
runner compare three matched fresh-VM pairs against the complete protocol-3
idle-retirement stack. Four/eight slots use one/two helpers instead of four/eight
and save 37.27/73.28 MiB summed helper RSS (71.3%/69.8%). RSS double-counts
shared pages; payloads and driver are excluded. This is not a measured reduction
in the installed daemon's memory.

Sequential command medians are close to baseline (+0.35%/+0.86% at four/eight
slots). Submitted short-command batches are slower (+17.1%/+32.3%). Only the
memory fixture guarantees all payloads are alive simultaneously. Cold-start and
warm-cycle improvements are fixture measurements, not production percentiles.
No end-to-end distributed RPC, Go CPU or per-call allocation saving is claimed.
Both local and distributed workspace planes use the same changed pool.

Independent lifecycle review found one control-envelope mismatch; cancellation
now uses a fresh request ID, and the reviewer verified the correction. The
evidence review recomputed the results and checked overlap, PID ownership,
output/exit assertions and all 18 successful close witnesses. Three compiled
private broker mutants fail on stale dispatch, quota over-admission and premature
idle transition; shared source/build artifacts stayed byte-identical. A native
refill-order mutant also fails the deterministic regression. Final native
`go test -race ./...` passed every package. Documentation checks pass with zero
errors and existing warnings.

The complete `LOOM_TEST_PARALLEL=8 make check` rerun passed exit 0: 419 broker,
4,491 client, 1,365 TUI and every remaining package, native checks and lint
(zero errors). The first full run had 20 unchanged daemon-fixture readiness
timeouts before helper dispatch. The failed test and all three affected modules
passed focused reproduction at the original parallelism and deadlines; the full
rerun then passed without any code or timeout changes. The cause remains
unidentified, so this is not recorded as a diagnosed flake. Both runs are
preserved in the measurement report.

Implementation is committed as `8d21799a5` and published as
[PR #978](https://github.com/Roasbeef/loom/pull/978), targeting
`codex/helper-idle-retirement` while #975 remains open. Its diff contains only
concurrency. Hosted Linux/macOS CI is running and remains a separate gate.
There is no authorization to merge or deploy this PR.

## Follow-ups

Repeated register decoding is the separate open
[PR #972](https://github.com/Roasbeef/loom/pull/972), outside this branch. Prior
busy-period sampling found JSON parsing prominent, but stack-sample shares are
not CPU-time percentages. Re-profile the installed system after an explicitly
requested upgrade before attributing production memory or CPU savings to either
optimization. Further tuning of concurrency should compare short-command
throughput against its memory savings and retain the existing slot ceiling and
retirement custody guarantees.

A separate session timing investigation confirmed that independent log fetches
were written with sequential `gleam/list.map` around blocking `cap/proc.run`.
Their start offsets tracked the preceding command durations. That is program
sequencing; existing `cap/task.parallel_map` can express independent fetches
concurrently. Helper multiplexing does not automatically parallelize sequential
Gleam programs.
