# Current handoff

This edition records the October 8, 2026 large-result terminal wrapping fix
on `fix/linear-code-wrapping`, checked against implementation `1488a4e7b`
and base main `ae262a813`. Rewrite it after the next body of work. Current
claims were checked against that tree and the validation in the
[wrapping report](review/tui-large-result-wrap-2026-10-08.md).

The source checkout's unrelated files were preserved. The work is isolated
in `.worktrees/linear-code-wrapping`; the resident terminal and daemon were
profiled and observed, but were not replaced or restarted.

## Where the tree is

| Work | Current evidence |
| --- | --- |
| Large-result terminal wrapping | Measured grapheme cursors eliminate repeated suffix scans. |
| Complete expanded output | Million-character source and wire-to-frame Ctrl-G regressions pass. |
| Local validation | All affected gates pass, exit 0 in 452 seconds; no undeclared skip. |
| Independent review | No actionable findings; four regressions and 888 differential cases passed independently. |
| Compile/export reuse | PR #917 merged as base `ae262a813`; its PR check rollup is green. |

The previous edition's instruction to finish PR #917's CI is obsolete:
[that PR](https://github.com/Roasbeef/loom/pull/917) merged October 8 and
its queried checks succeeded. Its timing results remain historical
observations in the [compile report](review/compile-hill-climb-2026-10-07.md),
not newly measured performance of this branch. Main's merge workflow was
still running when inspected; a green merge run is not claimed.

The terminal was CPU-bound after code mode had returned. A private result
held 1,091,874 characters; quoting it yielded one 1,248,958-character code
row. Replaying that value through the fixed renderer and wrapper completed
in 0.533 seconds. The source and the program's complete result remain
available; no truncation or wire change was introduced.

## What to do next

1. Publish and inspect hosted CI for the terminal fix's exact PR head.
   **Exit:** the published head passes its required checks. The selector
   reports full Linux signoff is not required for this terminal-only change.
2. Fix [issue #924](https://github.com/Roasbeef/loom/issues/924) in its own
   PR. **Exit:** advertised LSP SQL imports compile from the selected seed,
   workspace LSP servers have their required offline dependencies and working
   toolchain paths, and failed servers cannot produce a false-clean
   diagnostics result. Its amendment supplies a same-run reproduction.
3. Settle browser access to complete large results. **Exit:** a bounded page
   preview offers the agreed complete-output access. The current browser
   cap remains 300 lines or 8,000 characters; this terminal fix does not
   alter that UI or its protocol.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Consume code rows once.** The invariant belongs in `tui/markdown` and its
reduction-count regression. Continuations share unconsumed graphemes and
subtract consumed widths. Rebuilding a remaining string before the next row
would restore the quadratic failure mode.

**Keep complete terminal results.** The complete-value regressions enforce
text and style preservation. A small viewport does not justify discarding
source text; the bounded frame displays a portion of its full row cache.

**Judge evidence by its scope.** The profiler's allocation count measures
churn, not retention. A disposable replay proves the changed algorithm;
it does not prove the installed client recovered. The repository's
[execution rules](execution.md) define the affected gate and review standard.

## Deliberately open

Issue #924 and browser full-result access are newly requested work. Paging,
output limits and resident process replacement are outside this terminal PR.
None of these is unfinished work somebody forgot.

## How to verify

Run the commands in the [wrapping report](review/tui-large-result-wrap-2026-10-08.md).
`make check-affected BASE=ae262a81374542b7cdbf63b3983a48c77c5a2e01` includes
static gates, prepared shipments, the complete client and TUI suites and
skip census. `LOOM_TEST_PARALLEL=8` is the measured local run's setting.

**Judge each gate by its own exit code.** **Keep code-mode worktrees outside
`/tmp`.** **Do not replace the installed client merely to benchmark a fix.**
See [execution](execution.md) for the remaining process and signoff hazards.
