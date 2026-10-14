# Current handoff

Baselined October 13, 2026 against `c37d9a892` on `fix/strand-tps`,
with main through `c47175004` integrated.
This edition covers per-strand generation timing. The installed daemon has
not been updated. Rewrite this file when the next body of work finishes.

The previous edition covered web history browsing and reported gates for its
own head. Those results do not validate this branch. Its evidence and open
history decisions remain in the
[prior handoff](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
The project-wide plan remains `docs/issue-plan.md`.

Main also includes the register-decode cache from merged PR #972. Its exact
blob keys, bounded store-owned inventory and corruption/lease regressions live
in the storage package. The [measurement report](review/register-decoding-2026-10-12.md)
records its performance evidence and limits. Its complete prior handoff and
live memory follow-ups remain in the
[register-decoding handoff](https://github.com/Roasbeef/loom/blob/e86d6fddd/docs/next.md).
Those branch results are historical evidence, not validation of this combined
head. No storage source conflict occurred during integration.

Main also includes the Responses validation diagnostics and deployment CI
correction from merged PR #979. Provider acceptance predicates and redaction
bounds remain as reviewed in that work; its diagnostic limits and provider-error
follow-ups are preserved in the
[Responses handoff](https://github.com/Roasbeef/loom/blob/c47175004/docs/next.md)
and `packages/provider/README.md`. The deployment-status fixture now executes
in the delegated Linux jail job with no skip allowance. This branch keeps main's
CI repair exactly once rather than duplicating the independently landed fix.
No provider or runtime source required manual conflict resolution.

## Where the tree is

The terminal and web view now share `session_view/generation_rate.State`,
a session-scoped ledger indexed by strand. Every observed strand owns its
request clock and last measured output rate, including background agents.
The header reads the selected strand through `session_view/model` accessors.
Switching focus neither clears a running clock nor borrows the parent's rate.

Live phase events and fresh coherent captures update the ledger. Captures
observe phases after transcript stream retirement, and reprojecting an older
capture on focus does not observe its phases again. Request identity survives
the active-only stream projection, so a lagging capture cannot turn a partial
background window into a complete measurement. Settlement consumes only its
strand's clock. Roster replacement prunes removed strands; a session change
clears the ledger.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**A partial observation cannot measure full-request TPS.** A client joining an
already running generation cannot know its original start from the current
wire data. The ledger can show elapsed observation time, but retains that
strand's previous complete rate, or no rate if none exists. The rule lives in
`generation_rate` and its regression tests. No protocol extension was added.

**Focus selects timing; it does not own timing.** The ledger belongs to the
shared session state. Both hosts use the same strand-specific accessors.

## How to verify

`make check-affected` selects the gates affected by the current diff against
main, together with the static gates and native prerequisites.
Full Linux signoff remains required for the combined head. Run `make signoff-remote` against the pushed head; the PR's exact-head
commit statuses are the record of hosted checks and Linux signoff.

`packages/web_view/test/strand_rate_test.gleam` drives the actual component and
header with an injected clock. It covers independent parent/child rates,
switching back, focusing a background generation midway through it, attaching
mid-generation, consecutive requests, and lagging captures. The shared ledger
suite checks clock consumption, new request identity and roster removal.

Mutation checks restored three old behaviors separately: reading main's rate
for every strand, resetting a clock on focus, and accepting a lagging background
phase. Each compiled and failed its corresponding header assertion. The
independent review's capture-ordering findings were fixed and rechecked.

**Read a gate's own exit code.** `check-affected` records each lane's status and
its skip census under `build/affected`. Native socket tests need the host's
normal permissions. Preparation must finish before package lanes start.
`docs/execution.md` carries the remaining gate and sandbox hazards.

## What to do next

1. Review and land the per-strand TPS PR once its exact-head affected checks,
   hosted checks and required Linux signoff pass. Exit: the reviewed head is
   merged. Deployment remains a separate operation.
2. Follow `docs/issue-plan.md` for the next project milestone. The queue-control
   PR is separate work and is not included in this branch.

## Deliberately open

An exact TPS for a request already running before attachment would require an
original start timestamp or duration from the server. The current client
conservatively leaves that request unmeasured. None of this is unfinished work
somebody forgot.

## Helper retirement integration checkpoint

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

Main advanced to `c47175004` with merged #979 during validation. Integration
conflicts only in this handoff; its Responses diagnostics/runtime regressions
and provider docs merge unchanged. The deployment coverage correction is now
also on main. Idle-retirement production source remains unchanged, and fresh
mergeable-head hosted checks must validate the integration before landing.

Main advanced to `99975fe00` with merged strand-rate PR #982. This integration
preserves its session-view, TUI and web-view sources unchanged. The conflict
affected only this handoff. Helper production and corrected fixture sources
remain unchanged from `53fec5003`; fresh hosted CI must validate this head.
No daemon installation or restart was performed.
