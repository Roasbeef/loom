# Current handoff

Baselined October 14, 2026 against `7f82bb498f5990a0382873ac84521b50802e21cd`.
Runtime commit `6435d874b` contains the measured preparation-read change below.
The project plan remains `docs/issue-plan.md`; verification procedure remains
`docs/execution.md`.

## Where the tree is

Main's baseline includes helper concurrency through PR #978 at `25c34d349`
and Darwin discovery through PR #986 at `7f82bb498`. The prior edition's
instruction to finish and merge #978 is therefore stale. The source commits
are present in this baseline; this profiling round has not rechecked their
historical hosted checks or Linux signoff. Their historical integration notes
remain in the [previous handoff](https://github.com/Roasbeef/loom/blob/7f82bb498f5990a0382873ac84521b50802e21cd/docs/next.md).

The fresh [resource report](review/loom-live-resource-profile-2026-10-14.md)
profiles the installed daemon at `13508cb5895e338aa60109259f66c025d81447c6`,
which predates those two merges. The owner confirmed that the workload uses
the web UI, so there is no terminal-client profile in this round.

## Measured runtime change

Two ten-second Pickglass CPU cuts attributed about 83% of selected active
stack observations to JSON parsing, including the owner's reported CPU spike.
Register-cache tracing localized the expensive work to oversized preparation
decoding. One active preparation was 1,577,693 encoded bytes, above the
existing 262,144-byte cache bound.

`strand_runtime.load_operation` listed preparation registers, discarded their
values and point-read the first key again. The candidate uses the first
listed value and preserves all listed keys for terminal cleanup. It adds no
cross-reload cache or storage API. The large summary-input regression completes
navigation and cleanup while requiring zero preparation point reads. The same
regression on the unchanged baseline fails with six point reads.

The matched SQLite fixture's median operation-sequence time fell from
1.452695 seconds to 0.802891 seconds over five fresh-VM runs per version.
Register-decode heap allocation fell by 50.32% in both allocation comparisons.
These are synthetic fixture results, not live daemon CPU or RSS savings.
The installed daemon remains unchanged.

## What to do next

1. Review and land the scoped runtime change. Exit: retain the successful
   summary-input, zero-point-read and cleanup regression; require any additional
   merge gates the owner selects. The runtime package gate passed all 203 tests,
   and runtime lint passed. Independent adversarial review found no actionable
   issues. Full repository tests, hosted CI and Linux signoff
   have not been run for this candidate.
2. After owner authorization to update and restart the installed daemon, repeat
   the live Pickglass census and CPU sample under a comparable web workload.
   Exit: report exact installed commit, observation windows and workload, and
   distinguish CPU, cumulative allocation, process capacity and OS RSS.

## Rulings already made

**Reuse a value already returned before adding retention.** Preparation values
are reused within one reload. Storage is still queried on each reload, its
listing order still selects the first payload and every listed key still reaches
terminal cleanup. The code and regression own this rule.

**Keep live evidence separate from fixture comparisons.** The resource report
records the live capture coverage and truncated trace. A changing live workload
and unmatched builds cannot establish an optimization's direction. Raw captures
remain private because they contain owner and process identities.

## Deliberately open

Production CPU and retained-memory savings are unmeasured until an approved
update and matched capture. The remaining JSON decode, runtime reload frequency,
supervisor memory and allocator capacity have not been optimized in this change.
No installed daemon update, restart, forced collection or state walk was done.
None of these is unfinished work somebody forgot.

## How to verify

```sh
LOOM_TEST_TIMEOUT_SECONDS=90 bash scripts/test.sh runtime --match preparation_listing
make check-runtime
make lint-runtime
make doc-check
```

Read each command's own exit status. The package gate passed with 203 tests;
the new regression failed on the unchanged baseline at its zero-point-read
assertion. The report preserves the local SQLite benchmark runner, fixture and
raw-result locations. Those scratch databases are synthetic and do not use the
live session store. See `docs/execution.md` for the broader verification rules.
