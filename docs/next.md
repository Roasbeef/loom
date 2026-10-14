# Current handoff

Integrated October 13, 2026 with main `e86d6fddd`, which includes merged register
decoding PR #972. The original performance baseline remains
`dc70d25d42da531284225bf399f40f82e13539d4` (v0.3.2). Idle helper retirement is on `codex/helper-idle-retirement`, with
implementation `0ae4589be`. The installed daemon remains 0.2.0 at `e289d93ab`;
no installation, restart, hotpatch or merge was performed.

The previous main handoff covers broader project work and remains available
at [the baseline](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
The project plan remains `docs/issue-plan.md`. This rewrite records the current
branch's evidence rather than carrying older gate claims onto a new head.

## Idle helper retirement

Issue #283 is implemented with a fixed sixty-second idle interval per available
helper. Successful checkin starts a weft named timer; checkout cancels it.
Observation, duplicate checkins and activity elsewhere do not extend it. Pools
shrink to zero and spawn replacements lazily. Borrowed work is untouched,
including long-lived execution. Native exit and normal helper-owner retirement
must both be witnessed before capacity is reused; failed retirement retains
custody and capacity. No wire protocol, user configuration or public constructor
changed. Both local and distributed workspace planes use this pool mechanism.

The [report](review/helper-idle-retirement-2026-10-13.md) and benchmark runner
record three fresh matched VMs. Four used helpers reclaim about 40 MiB summed
RSS on retirement; the real sixty-second trial confirms native exit. Warm
checkout/checkin costs about 1.24 us extra; actual short-command medians overlap
under loaded-host variation. The production trial's first command costs
58.540 ms with replacement versus 16.976 ms with a retained helper. One pair
cannot establish a stable minute-idle startup penalty; accelerated trials are
reported separately. Summed RSS includes shared pages and is not physical RAM
or a production daemon saving.

Seven deterministic regressions and one real-helper regression passed. The
independent correctness review found no actionable issue; the evidence review
recomputed all medians and signed off after correcting a platform-skip wording.
Three compiled mutation checks were rejected by runtime assertions; source
was restored exactly and the eight regressions passed again. The full serialized
`LOOM_TEST_PARALLEL=8 make check` passed exit 0, including 409 broker, 4,491
client and 1,365 TUI tests, all other packages, Go, lint and configuration
checks. Documentation checks passed. Hosted CI remains pending. No test was
weakened or skipped to enable performance measurement. The isolated Mac fixture
uses BestEffort with explicit Seatbelt and network-confinement assertions and
records unavailable resource/lifecycle layers.

## Live follow-ups

The new busy-period profile again found JSON object parsing in roughly 73% of
active stack observations. A separate five-second probe counted 154 register
lookups, 81 register lists and 1,319 JSON parses in selected processes. Sample
shares are not CPU-time percentages. OS utilization varied by cut; a later
short interval measured the daemon at 17.9% CPU with the host 78.4% idle.

Repeated register decoding [PR #972](https://github.com/Roasbeef/loom/pull/972)
is now merged on main and included by integration. Its report and cache tests
remain the evidence for that separate optimization. Re-profile after an explicitly
requested upgrade before attributing production savings. There are no recurring
automations for this task. The branch has passed local validation and independent reviews and is published
as [PR #975](https://github.com/Roasbeef/loom/pull/975). The owner authorized landing #975, then #978 on main after exact-head checks
and sufficient review. Fresh integrated validation remains required before merge;
no installation or daemon restart is authorized.

## Integration gates

The conflict with current main affected only this handoff document. Source
changes from register decoding merged automatically. Old hosted run 38458267713
failed its Linux census on the missing deployment-status declaration; macOS
advisory failed downloading its artifact with DNS ENOTFOUND before tests ran.
The CI-only fix from #979 pairs the ordinary-runner declaration with exact
fixture execution under delegated Linux enforcement and an empty skip allowance.
No source or test assertion is weakened for those failures. Fresh `LOOM_TEST_PARALLEL=8 make check` passed direct exit 0 on the integrated
source: `/private/tmp/pr975-integrated-full-check.log`. Independent integration
review found no actionable issue and verified idle custody/timer behavior,
unchanged main register cache and strict deployment coverage. Fresh hosted
checks must attest to the published integration head before merging.

## macOS remediation checkpoint

Run 38503180456 passed all Linux checks at `450ad56e2`, including real idle
retirement/replacement and strict delegated deployment. macOS e2e exposed a
pre-admission accept budget that began before daemon bootstrap; initial accept
now shares the existing whole-fixture lifetime while all post-admission bounds
and closure/recovery assertions remain. Its real local fixture and negative
controls pass. Advisory serial client execution exceeded the unchanged package
budget; the step now uses the existing eight-way mode without changing its
deadlines, serial exceptions or discovery. The shared LSP fixture now establishes
its pending-request precondition before the unchanged short cancellation budget.
Independent reviews and the corrected full local gate pass (direct exit 0):
`/private/tmp/pr975-macos-fixed-full-check.log`. Fresh hosted checks remain
required on the published correction head; earlier green Linux gates do not
validate it. The delayed-start comparison passes with corrected admission and
fails with the old bound, as recorded in the measurement report.
