# Current handoff

This is a scoped record of the final literate-lint sweep, baselined October 24,
2026 against `b5e9e0eb9` on `lint/wave-3c-client`. It records this work's measured
results, not a fresh audit of releases or unrelated feature work. Rewrite it
after the remaining validation or another body of work changes those facts.

The [previous handoff](next-2026-10-24-before-final-literate-sweep.md) described
the reconnect and startup repairs. Those claims retain their original dates
and were not revalidated here. It did not describe the later lint sweeps.
Earlier sweep delivery notes also overstated verification: a zero lint census
did not prove that the comment edits preserved compiling, executable code.
The repairs below address concrete mistakes found by the final audit.

Reasoning blocks now own one Lustre memo leaf, including source-derived line
counts, expansion, preview and body work. Its keys preserve changed source,
held text, elapsed time, fold controls, session and newest-row handoff. Normal
rows keep their existing leaves. An empty gateway entry cut now preserves its
attribution cache immediately, avoiding one unnecessary leaf query per strand.
Operation/result register reads and nonempty attribution keep their ordering.

| Work | Measured state |
| --- | --- |
| Literate sweep | The whole-tree lint command passed across all 29 packages: R11, R21 and R22 each have zero findings. All error-level rules are clear; 2,515 findings remain at warning level. |
| Global gate | `CaseStanza` and `FunctionDoc` join `finding.error_by_default()`. Sixteen rules gate globally. Tests prove R21/R22 fail an unknown package outside the retained `literate_packages()` ratchet. The ratchet includes all 29 packages and grants no exemption. |
| Code preservation | The 268 changed client sources match their pre-sweep code tokens except two trailing commas removed by formatting. A direct commit-parent audit of the four earlier sweep commits checked 596 source-file changes outside the intentional lint implementation. |
| Earlier sweep repairs | `89c61ec39` restores a duplicated `ext` transition parameter, duplicate `cap` monitor selection and discarded fold, and four unplanned expression refactors. The seven repaired files match their respective pre-sweep token streams. Grouping braces in `broker/policy` and `tools/fs` are layout-only. |
| Generated prelude | `a12c7b1a4` regenerates the two changed capability source digests. The public signatures did not change. The prelude gate and its stale-input self-test pass. |
| Local validation | Client builds with `--warnings-as-errors`. The extension gate passed 49 tests; the capability gate passed 216; the lint package passed 318. Whole-tree lint and doc-check pass, with warnings retained. These do not replace the incomplete full test run. |
| Full-gate blocker | `make check` compiles the seed but fails four install-pruning Python fixtures and the fake-origin signoff fixture. All five failures reproduce in a detached checkout of base `1dfef315fd`; the scripts are unchanged. They were not removed or relaxed. |
| Client test limit | After formatting and compilation, `make check-client` reached the ledger tests before the jailed test process ended with `SIGXCPU` (`exit=-24`). There is no complete client-suite result from this run. |
| Review | One independent report-only review found an inaccurate deployment copy-state comment. It was corrected and checked against the `facts.copy` encoder. Other false placement claims in the deployment render-budget helpers were corrected as well. |

Integration then brought in main `3e258a2f3`, preserving its attach-file key
lookup and pickglass behavior. The 269 changed client sources match that
incoming main's code tokens except two formatter-removed trailing commas.
The attach-file, authority-home and distribution-attach test modules passed,
as did the integrated format, whole-tree lint, documentation and prelude
gates. The lint totals remain zero errors and 2,515 warnings.

No installation, daemon restart or hotpatch was performed. A hosted CI verdict
for the final published head is still required before merge.

The full web-view gate passed all 1,330 tests. All 203 gateway-focused client
tests passed, including read counts at 1/8/64/128 strands, nonempty attribution
and once-only terminal outcomes. Both affected lints pass. An independent Astra
adversarial review found no actionable issue; it also checked the later
fixture unlink-before-kill repair. The new performance regressions fail for
the intended assertions on pristine production code.

1. Finish validation and publish the final sweep PR. **Exit:** the exact PR
   head passes the required Linux fan-in, including both client shards, and
   advisory logs are inspected rather than treating normalized job success
   as a passing test suite. Do not bypass the required gate to merge.
2. Record the local test restrictions separately from product failures.
   **Exit:** preserve the baseline reproductions and the CPU-limit result
   alongside the eventual CI result. Do not repair unrelated fixtures or
   skip tests merely to manufacture a green local command.
3. Resume the earlier feature work only from its own handoff and issues.
   **Exit:** revalidate the relevant claims against the current tree; this
   sweep does not install, release or redesign those features.

## Web, SQLite and request-preparation performance

A consolidated change set cuts reductions and copied words in the web lane
(one memo leaf per reasoning block, a bypass when no summary labels exist),
in idle gateway reads (an empty entry cut skips branch attribution) and in
request preparation (a within-budget image shortcut and an identity context
shortcut). The records are
[web-sqlite-performance](review/web-sqlite-performance-2026-10-24.md),
[no-label-performance](review/no-label-performance-2026-10-24.md) and
[request-preparation-performance](review/request-preparation-performance-2026-10-24.md).
They report reductions, copied words and CPU in single-scheduler fixtures. No
live RSS or installed-daemon effect was measured, and the request-preparation
fixture is not a claim about full prepare or transport cost. The earlier
terminal-profiling handoff is preserved in
[next-2026-10-24-before-web-sqlite-performance.md](next-2026-10-24-before-web-sqlite-performance.md).

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**The gate is global.** `packages/lint/src/lint/finding.gleam` owns the default
error rules. A package missing from the public sweep ratchet is still subject
to R21 and R22. The unknown-package tests pin that behavior.

**Comments do not authorize behavior changes.** Restoring source tokens,
compiling warning-free and running the relevant tests are separate checks.
A lint pass cannot detect a duplicated operation or prove a comment true.
Preserve existing explanatory prose when attaching helper documentation.

## Deliberately open

The full local gate and complete client test run remain unverified for this
head. The former has baseline fixture failures, and the latter hit a kernel
resource limit. Hosted CI is pending. None of these is unfinished work somebody
forgot; none is permission to call the corresponding gate green.

## How to verify

Run shipment-building package targets sequentially:

```sh
make check
make check-client
make check-cap
make check-ext
make check-lint
make lint
make doc-check
make prelude-check
```

**Read each command's actual exit status.** The full local check log is
`$TMPDIR/loom-wave3c-check-final.log`; the client gate is
`$TMPDIR/loom-wave3c-client-check-final.log`. Baseline Python reproductions are
`$TMPDIR/loom-wave3c-baseline-python.log` and
`$TMPDIR/loom-wave3c-baseline-signoff.log`. These are session-local evidence,
not committed artifacts or a substitute for CI logs.

**Use explicit worktree paths for semantic queries.** Loom's code-mode Gleam
LSP resolved the repaired `cap/runtime.serving`, `cap/strand.map_batches` and
`ext/internal/live_runtime.finish` callers in this worktree. Bare project
queries can describe the main checkout instead. See
[docs/execution.md](execution.md) for the remaining verification hazards.
