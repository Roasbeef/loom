# Continued allocation improvements

The production commits are e97af0e98 (linear turn merging), 857d2cdd9
(workspace capture) and 7c005ccce (discarded header). Generated assets are
8126a166a and the benchmark is 10ed5f88f. These private changes continue
the optimization work collected in PR #1110. Their measurement base is
4510d43863cfccaa383b0f451f25d20132406262, after the earlier request-preparation
fast paths. The integration owner rebases and validates the combined PR
separately. The installed daemon and Pickglass viewer were left unchanged.

## Linear Anthropic turn merging

Consecutive tool results share the user role. The previous encoder appended
each new result to a growing prefix, copying the earlier blocks repeatedly.
The new private merge traverses turns backwards and appends each earlier
original block list to the completed suffix. Each original block list is copied
at most once. Chronological role and block order remain unchanged, including
empty turns and the cache markers placed before the final frozen-prefix merge.
No request field or provider contract changes.

The benchmark builds complete requests with an initiating user prompt,
matching assistant tool calls and the corresponding results. Alternating-role
controls pair each assistant call with its result. Four rounds alternate the
baseline and candidate within one OTP 29 VM with one scheduler. Request values,
including body bytes, are compared outside timed loops; warmup precedes timing.
Untraced CPU/reductions and root-function tprof cumulative allocation run
in separate fresh monitored workers with identical warmup. Request copying
into each worker precedes measurement; all 500 encodes remain inside it.
Earlier result-only fixtures are excluded from final performance claims. The benchmark is scripts/anthropic_merge_perf.{erl,sh}; it needs built
provider tests and a saved baseline provider@adapter@anthropic.beam.

Four-round medians for 500 complete encodes per trial:

| Layout | CPU ms baseline / candidate | Allocated words baseline / candidate |
| --- | ---: | ---: |
| One result | 5 / 4.5 | 932,126 / 932,068 |
| Eight consecutive results | 11.5 / 13.5 | 2,995,458 / 2,981,335 |
| 64 consecutive results | 92 / 88.5 | 21,242,449 / 19,335,403 |
| 128 consecutive results | 186.5 / 158.5 | 45,903,000 / 38,319,991 |
| 128 results, frozen prefix | 151 / 148 | 42,010,000 / 38,268,681 |
| 128 alternating role results | 232 / 232 | 51,527,483 / 51,527,483 |

Normal 128-result encoding uses 15.0% less CPU and 16.5% fewer allocated words;
its reductions fall from 40,004,118 to 37,887,439. Normal eight-result encoding
is about four microseconds slower per request, with reductions rising from
2,971,402 to 3,066,865 despite 0.47% fewer words. This bounded small-batch cost
is accepted for linear scaling; there is no universal CPU improvement claim.
Frozen eight-result CPU remains 11 ms in both versions. The raw CSV records
all normal/frozen and alternating-role controls, including ordinary cases.

The earlier legal-exchange benchmark used one process for successive timing
and tracing passes. It recorded normal 128-result CPU of 140 to 149.5 ms,
a regression. Fresh workers remove that cross-trial heap-state dependency;
the different results show that measurement context matters. Both CSVs are
retained, rather than dropping the unfavorable run. CPU is VM-wide and timing
is workload-specific, with millisecond resolution. Run the script under the
existing scripts/with_timeout.py when a caller needs a process deadline.

Baseline source SHA256 is
7c6858388c21c7c5fa879109a6ac5b16ed726adbed3f70ccd061faf07b285775;
the freshly built baseline BEAM SHA256 is
eb800276cd55a344654a54732e4a1dce3f46cf43a5216d6dca6fe59c4b7bafe8.
The source matches the exact measurement base. Obtain the baseline by building
provider tests in an isolated checkout at that base, saving its adapter BEAM,
then building candidate provider tests with the same compiler and dependencies.
Run bash scripts/anthropic_merge_perf.sh with the candidate checkout and saved
BEAM path after other local builds and tests finish. Retained baseline files
are under /private/tmp/loom-anthropic-merge-baseline; the final isolated trial
log is /private/tmp/loom-anthropic-merge-fresh-worker-perf.log. The earlier
shared-process log remains /private/tmp/loom-anthropic-merge-legal-perf.log.
Committed raw trials are continued-performance-anthropic-2026-10-24.csv and
continued-performance-anthropic-shared-process-2026-10-24.csv beside this report.

## Narrow workspace read capture

workspace_seam_with_access used config.blob_root inside its read callback.
The callback travels with the workspace router into the satellite host and
capability plans/workers; it therefore copied unrelated host configuration.
Binding the same immutable blob-root string before constructing the callback
removes this path. Filesystem resolution, policy, authorization, ceilings,
errors and execution lifetime are unchanged. Other workspace capabilities
retain their actual dependencies, including emit's entropy callback.

A real default configuration, idle broker and workspace sent to a disposable
process give these flattened term sizes, in eight-byte words:

| Value | Baseline ordinary / padded | Candidate ordinary / padded |
| --- | ---: | ---: |
| Config | 162 / 61,602 | 162 / 61,602 |
| Read callback | 273 / 61,713 | 119 / 119 |
| Copied workspace | 561 / 62,001 | 407 / 407 |

Padding adds 4,096 valid unused toolchain mounts. The minimal ordinary saving
is 154 words, or 1,232 bytes. The exaggerated input establishes independence
from unrelated host fields; it does not represent an observed live workload.
The public-constructor regression uses its own valid mount padding, measures
the actual workspace after an actor copy, and fails against the saved baseline
at the intended callback-growth assertion. The unchanged host still holds its
mount table. No new process, cache, public API, FFI or dependency is introduced
by production code. Driver and raw measurements are retained under
/private/tmp/loom-blob-root-baseline and /private/tmp/loom-blob-root-{before,after}.log.

## Avoid the discarded expandable header

fold_row.openable previously constructed a flat header span before choosing
whether a row was flat or expandable. Expandable rows discarded it and built
the slotted header instead. Constructing the flat span only in its existing
branch preserves both output trees and event attributes.

For 1,000 unchanged reasoning-page renders, cumulative allocation falls from
72,323,255 to 71,938,455 words, about 0.53%. Thirty first paints fall from
27,040,710 to 26,990,059 words. Answer and sibling controls are effectively
unchanged. Actual compiled production modules supply these numbers; the earlier
generated-form diagnostic is not used as the candidate result. Visible HTML
and handler-key hashes match in all three scenarios, and unchanged patches
remain two bytes. This is a small allocation saving with no CPU or RSS claim.
Reproduce with scripts/web_view_perf.sh against identically built base and
candidate checkouts. Full production allocation trials are recorded in the
companion JSON; source/BEAM hashes are retained in
/private/tmp/fold-row-production-hashes.log.

## Validation and limits

All 326 provider tests, 90 client code-mode tests, 41 client workspace tests
and 1,332 web-view tests pass. Existing coverage includes normal/blob reads,
protected paths, host scopes, empty turns, frozen-prefix cache markers and
all 34 fold-row cases. New semantic adapter regressions also pass baseline
production; the copied-workspace regression rejects it. Affected format,
warning-free builds, client/web/provider lints and asset checks pass. The
stylesheet rebuild changes only its source digest, with identical CSS body.
Independent report-only review found no actionable production or benchmark
issue. Documentation checking passes with zero errors and 229 existing warnings.

Cumulative allocation and flattened copied words are separate metrics; neither
is live RSS or leak evidence. The complete-request benchmark measures encoding,
not transport or provider latency. Hosted checks and combined integration-head
validation belong to PR #1110 and are not inferred from these local results.
