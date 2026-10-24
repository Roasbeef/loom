# Skip empty label projection

This follow-up starts at d675088f2 on codex/no-label-fastpath; source commit
8f41b7a63 contains the predicate, shortcut and regressions. The previous
performance branch stays fixed while its current-base PR is prepared elsewhere.
The live daemon, enrolled inspector and Pickglass viewer are unchanged.

## Change and invariant

The opaque block_summary.Labels book contains stored and live presentation
values plus pending/asked read bookkeeping. A real page can have forty wanted
keys without any label to draw. Previously turn_labels.apply still formatted
entry UUIDs and rebuilt the piece list on every render in that state.

The new public has_labels predicate checks whether either presentation book
is nonempty. It deliberately includes empty text and live generations that do
not yet identify an entry. Pending keys and refused reads do not count. When
there are no labels, apply returns the original pieces; all other states use
the unchanged projection path. No representation, wire contract, cache,
dependency or process lifetime changes.

The identity follows from existing lookup semantics: with both dictionaries
empty, stored, live and carried lookups yield no replacement; relabelled returns
the original block and swapped preserves every row. A disposable fixture proof
also covers wanted, asked and refused books, existing summarized rows and stale
digests. Positive controls exercise stored, carried-live and empty-text labels.
Independent review found no actionable issue. The regression tests use the
public book operations and preserve the existing populated-label cases.

## Matched measurements

Three alternating trials use OTP 29, one scheduler and the same page fixtures.
Each unchanged-render phase runs 1,000 iterations; first paint runs 30.
All visible-HTML and handler-key witnesses match across paired trials.
Baseline disposable VMs override exactly the two d675088f2 modules, block_summary
and turn_labels; candidate VMs use their newly built modules. Source hashes were
checked against git, and all other fixture/dependency modules are identical.
The exact executed loop is retained in /private/tmp/turn_label_production_perf.sh;
source/BEAM hashes are in /private/tmp/turn-label-production-{baseline,candidate}-sha256.log.
The populated control's source is /private/tmp/turn_label_present_perf.erl: it
adds all 37 fixture keys through receive_board and shared_set.summaries before
constructing the view/cache. Driver hashes are in
/private/tmp/turn-label-drivers-sha256.log. Ordinary scenarios also reproduce
with scripts/web_view_perf.sh against separately built baseline and candidate
checkouts using reasoning, answers and siblings.

| Unchanged renders, median | CPU ms before/after | Reductions before/after | Allocated heap words before/after |
| --- | ---: | ---: | ---: |
| No-label reasoning | 411 / 350 | 50,881,190 / 39,579,082 | 89,630,393 / 72,298,572 |
| No-label answers | 363 / 293 | 43,675,831 / 30,859,355 | 71,999,900 / 53,611,505 |
| Siblings | 42 / 41 | 6,948,091 / 6,929,227 | 10,942,178 / 10,922,069 |
| 37 stored labels | 413 / 397 | 51,584,112 / 51,676,949 | 94,188,617 / 94,172,209 |

No-label reasoning uses 14.84% less CPU and allocates 19.34% fewer words;
no-label answers uses 19.28% less CPU and allocates 25.54% fewer words.
Siblings change negligibly. The populated control keeps essentially the same
work (about 0.18% more reductions); its CPU variation is not a benefit claim.
First-paint allocation changes are small: reasoning 27,550,731 to 27,042,065
words and answers 40,093,326 to 39,534,954 words. CPU is 108 to 108 ms and
153 to 143 ms respectively. Full trial values are in the adjacent JSON report.

These are cumulative allocation and matched fixture timings. They are not
retained heap, unique binary ownership or installed RSS savings. The latest
five-second OS-only observation of unchanged daemon PID 1513 records 15.77%
of one core and RSS about 1.04–1.06 GiB; its workload is not paired with this
candidate. No install, restart, hotpatch, forced GC or credential search occurred.

## Validation

The nine focused turn-label tests pass, including the two new regressions.
The full session-view gate passes 685 tests in 4.30 seconds and web-view passes
1,332 tests in 34.23 seconds, both with exit zero. Lint reports zero errors
(session-view 262 warnings; web-view 182). Source and BEAM hashes after these
checks are byte-identical to the measured candidate.

The full JavaScript suite exits one with 605 passes and 78 failures. All 78
failure identities exactly match the retained baseline (603 passes and 78
failures); no failures were added or removed. Both new regressions also pass
when invoked directly from compiled JavaScript. This extra suite is not green,
and no tests were removed, skipped or weakened. Comparison evidence is
/private/tmp/turn-label-js-baseline-comparison.json. Documentation checking
passes with zero errors and 230 warnings before the documentation commit. The full terminal consumer gate also
passes all 1,603 tests with exit zero in 20.06 seconds. Source hashes match the
measured and tested candidate. Hosted CI and Linux signoff remain unverified.

The separate gateway investigation found no smaller safe read reduction through
current interfaces. Idle pulls already read each state/result key once. ExactKey
snapshot capture adds query/transaction overhead, while prepared-statement reuse
needs new binding and ownership machinery. Those changes are not included.
