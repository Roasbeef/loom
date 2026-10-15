# Current handoff

Baselined October 14, 2026 after integrating main `806d0cd20` on
`perf/preparation-reuse`.
Runtime commit `c4c6d1414` optimizes repeated checkpoint reloads while
retaining lost-doorbell recovery. The plan remains `docs/issue-plan.md`; execution and
verification rules remain `docs/execution.md`.

## Where the tree is

The branch starts from main `7f82bb498`, which includes helper concurrency
through #978 and Darwin discovery through #986. Their historical integration
boundaries remain in the [main handoff](https://github.com/Roasbeef/loom/blob/7f82bb498f5990a0382873ac84521b50802e21cd/docs/next.md).
Main integration also includes provider disconnect diagnostics through #989.
Its privacy, retry and terminal-validation boundaries remain in the
[pinned upstream handoff](https://github.com/Roasbeef/loom/blob/806d0cd20/docs/next.md).
This round does not revalidate historical hosted or Linux results.

Preparation-value reuse at `6435d874b` removes the duplicate point read after
listing preparation registers. The earlier [resource report](review/loom-live-resource-profile-2026-10-14.md)
records its live diagnosis and separate fixture result. The installed daemon is
still `13508cb5895e338aa60109259f66c025d81447c6`; no installed binary, state or
configuration was changed during this work.

## Completed checkpoint optimization

The previous handoff ranked repeated loads as an unimplemented next experiment.
The candidate now records a scalar `PollWait` frontier when a pass parks on a
live effect. Accepted ticks still totally decode strand/op/configuration control
registers and read the leaf. An unchanged frontier with a live effect and no
queued observation can continue waiting without loading the large preparation,
pending queue and tool payloads.

Quiet admissions advance `op.state` atomically with their payload. Configuration
and leaf changes are checked independently. Doorbells, effect completions,
retries and recovery clear the frontier and take the full drive. Restart begins
without a frontier. The short/idle periods and generation-stamped timer chain
remain intact. No payload cache or public interface was added.

The [checkpoint report](review/poll-reload-2026-10-14.md) and
[aggregate data](review/poll-reload-2026-10-14.json) preserve the matched SQLite
comparison against `23532b5f9`, which already contains the first preparation fix.
Across five separate three-second held-summary windows, median VM CPU fell from
880 ms to 8 ms and reductions from 55,785,005 to 58,576. Two allocation runs
eliminated 1,208,675,408 bytes in the selected reload/decoder roots while control
reads continued. End-of-window VM allocation stayed about 69 MiB in both
versions. RSS differed with allocator history; retained-memory savings and
live-daemon savings are not established.

## Verification

The final runtime gate passed all 206 tests and the projection/provider capture
benchmarks. Runtime lint passed with zero errors. Three new regressions prove
that preparation reloads stop during unchanged waits and resume for quiet
steering, leaf changes and configuration changes before provider completion.
The unchanged baseline fails the no-reload assertion. A mutation that ignores
changed controls makes the quiet-steer regression expire, proving that recovery
assertion cannot pass only because eventual provider completion reloads state.
Independent adversarial review found no actionable issues.

The private State layout grew from 21 to 22 fields, with the frontier appended
to preserve existing projection slots. The projection benchmark's layout guard
and synthetic constructor were updated together; its full final gate passes.
The benchmark uses a provider-owned release subject, so it releases and drains
the held request before checking observations. Full repository tests, hosted CI
and Linux signoff have not been run for this candidate.

## What to do next

1. Investigate remaining retention, then publish the scoped performance PR.
   The owner now authorizes publication and merge once ready. Exit: independent
   review, hosted CI, normal/containerised Linux signoff and a clean skip census
   for the exact final head. Keep `caffeinate` running through completion.
2. After owner authorization to update and restart the installed daemon, capture
   Pickglass CPU and allocation cuts under a comparable web workload. Exit:
   identify the installed head, workload and observation coverage and report
   live CPU, allocation and RSS separately.
3. Re-profile before selecting another optimization. UTF-8/string-run scanning
   remains a measured CPU lead; supervisor heap ownership remains an attribution
   lead. Rendering probes did not establish a new bottleneck.

## Rulings already made

**Durable control is the backstop.** Every accepted tick still reads the
control registers. Hints never become a freshness authority. Queue payloads and
operation-state sequence changes share a transaction; independent leaf and
configuration changes remain visible. The code and `poll_frontier_test` own
this rule.

**Remember a frontier, not a preparation.** The driver retains only identities
and sequences while parked. It does not add a decoded payload cache or carry
live observations past their owning event. Retry and deferred-permit waits keep
their original planning path.

**Keep CPU, allocation and retention separate.** The reports state the measured
windows and roots. Zero calls to those roots does not mean zero VM allocation,
and capacity/RSS snapshots are not reachable-state sizes.

## Deliberately open

The live daemon remains unchanged. Production CPU and retained-memory savings
need an approved deployment and a matched capture. Parser tuning, supervisor
sharing and additional rendering changes are outside this implementation.
None of these is unfinished work somebody forgot.

## How to verify

```sh
LOOM_TEST_TIMEOUT_SECONDS=30 bash scripts/test.sh runtime --match poll_frontier
make check-runtime
make lint-runtime
make doc-check
bash scripts/poll_reload_perf.sh /path/to/built/checkout label cpu
bash scripts/poll_reload_perf.sh /path/to/built/checkout label allocation
```

Read each command's own exit status. The measurement wrapper uses a fresh,
single-scheduler VM and a synthetic SQLite database, with CPU and allocation
runs separated. Both baseline and candidate require the same committed test
fixture. The report preserves raw-log and restored baseline locations. See
`docs/execution.md` for broader gates and their known hazards.
