# Current handoff

Baselined October 12, 2026 against `e500bc260` on `codex/register-decode`.
Implementation is `7db1fdd27dda2105a8d918ae5d13d63ae988372c`; the matched
benchmark runner is `d60c39a5f`. PR #966 is merged. The installed daemon has
not been changed by this work.

The prior handoff described web-history and LSP follow-ups. Those descriptions
are historical context rather than this branch's validation boundary; see the
[baseline handoff](https://github.com/Roasbeef/loom/blob/e500bc260/docs/next.md).
The project plan remains `docs/issue-plan.md`.

## Register decoding

SQLite now reuses successful register decodes under exact persisted blob keys.
Every read still queries SQL; current sequence, presence, prefix/order and
corruption detection remain authoritative. The store-owned inventory holds at
most 64 blobs and 256 KiB encoded bytes, clears on overflow and every close,
and bypasses individually larger blobs. No public storage interface, lease,
CAS or authorization rule changed.

The [measurement report](review/register-decoding-2026-10-12.md) records three fresh VMs,
twelve alternating batches per implementation/case, VM CPU, actor reductions,
heap allocation, cold/warm latency and synthetic retained-memory observations.
Structured warm reads save 74.5% to 91.0% VM CPU and 99.1% to 99.8% actor
heap allocation. Retention is a tradeoff, not an RSS saving. Byte-overflow point
reads used 2.33 times baseline CPU; overflow, scalar and cold costs remain
visible in the report. Larger working sets are an explicit limitation.

Five focused regressions pass, including both limits, failed-close release,
external corruption and warmed reads across CAS refusal/lease replacement.
Two independent reviews signed off correctness and evidence, and both compiled
bound mutants are rejected. The final serialized `LOOM_TEST_PARALLEL=8 make check` passed exit 0 after
the complete regression suite landed, including all 286 storage tests, Go
checks and lint with zero errors. Documentation checks also passed.
The first attempt failed dependency acquisition with disk-full; an overlapping
narrow Make invocation also failed shared shipment packaging. Neither is a
passing gate, and no test was weakened or skipped.

## Live follow-ups

The installed daemon remains on `e289d93ab` in the observed cuts. Three passive
snapshots during this task showed VM allocation dropping from about 486 to
452 MiB and RSS from 634 to 622 MiB. These do not establish a leak or a
production saving from this branch. The earlier 4.49 GiB summed gopls child
RSS remains the main external-memory lead; summed RSS double-counts shared
pages. Preserve session/jail isolation when investigating server lifetime.

Published as [PR #972](https://github.com/Roasbeef/loom/pull/972). Hosted CI
is queued/running; it is not yet a passing gate. No recurring automation, installation, restart or merge
is part of this task.
