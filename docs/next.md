# Current handoff

This is the post-merge CI repair, based on main
`d70c7d073c96a0afb8d28e676003e6bace147099` on
`codex/postmerge-fixture-repairs`. The [previous handoff](next-2026-10-24-before-postmerge-repair.md)
is preserved exactly; its local gates and performance measurements retain their
original observation cuts. The [repair report](review/postmerge-ci-repair-2026-10-24.md)
records reproduction, causal evidence and validation.

## What happened

PR #1110 merged as `141788049d93cfe97a427e350d75001bd88d091c` and PR #1111
as `d70c7d073c96a0afb8d28e676003e6bace147099` before their hosted checks
finished. #1111's older merge script continued after only its watcher child
was stopped. The remaining merge processes were subsequently terminated.
The user was notified. A merge is not a completed CI verdict.

Raw #1110 macOS artifacts contradict the normalized success badges. Shard 1
failed `client@evolution_retention_test:startup_padding_does_not_grow_evolution_trace_test`
with a 24-word excess. Shard 2 failed
`lsp@client_test:a_publication_without_the_barrier_does_not_settle_test`
with an empty diagnostic publication. Both `make check` commands exited one;
downstream packages did not run. The macOS fan-in skipped artifact downloads
and its strict skip census, despite its success badge. Those original failures
remain evidence even if another run passes.

## Repairs

Both changes are test-only. The real evolution-door fixture now counts its exact
startup marker through closure environments. Independently minted UUID integers
can vary by two BEAM words; twelve captured copies explain the unrelated
24-word difference. The repaired oracle requires zero markers in trace and
exactly one 4,096-marker snapshot in the whole door, preserving the intended
capture invariant without increasing a size tolerance. A small helper extends
the existing test-only FFI because Gleam cannot inspect closure environments.

The LSP fixture acknowledges the changed publication through its existing
`test/emit` request before starting the unchanged 60 ms settlement deadline.
The document-symbol barrier remains unanswered, and both the exact deadline
outcome and diagnostic assertions remain. Its separate positive test still
covers publication arriving after the barrier. The entire LSP package was
unchanged between pre-#1110 base `3e258a2f3` and this repair base: that fixture
race predates the optimizations. The retention fixture was introduced by #1110.

## Validation at publication

Five original focused runs passed for each intermittent fixture, followed by
controlled probes that reproduced each exact failure. Five repaired retention
runs and 200 repeated LSP cases pass. The full LSP gate passes all 194 tests,
including format, warning-free build and lint. Client scoped lint passes.

Negative controls restore broad Settings capture and allow settlement without
a barrier, respectively; each fails its strict repaired assertion. One fresh
independent report-only review found no actionable issue in the four-file
source delta, including the capture oracle and stream ordering.

The full local client gate completed with exit zero: 5,328 tests passed in
632.12 seconds. Its 57 visible prerequisite skips are not executed coverage.
Repair head `8f8e54db2` also passed hosted Linux checks with 5,328 client tests,
194 LSP tests and clean strict skip censuses. Hard macOS e2e passed 15 terminal,
four bootstrap, 112 e2e and 441 code-mode tests, with a clean terminal census.

Raw repair-run 40147468081 macOS shard 1 nevertheless failed the cross-node
worktree scenario, with 2,431 client tests passed and one failed. Both earlier
repairs explicitly passed. The child exited two, but EUnit truncated its nested
error; no underlying cause is established. Shard 2 completed the whole check.
The macOS fan-in skipped its strict census, so this run is not green.

Thirty fresh direct worktree scenarios and the original five-test remote-node
EUnit module pass locally. The fixture, support, distribution fixture FFI and
workspace package are unchanged since pre-#1110 base `3e258a2f3`; relevant
worktree lifecycle executable lines are unchanged too. This supports an
intermittent failure predating the optimizations, but does not identify its
cause. Test-only diagnostic logging now prints the existing complete scenario
error to stderr before returning the same error. Assertions, deadlines and skip
declarations remain unchanged; a subsequent failure must retain its child error.

The original #1111 audit is complete: its first macOS shard repeated the known
retention fixture failure, its second shard truly completed the whole check,
and its macOS strict census was skipped. Neither original merge is a passing
hosted-CI verdict.

## What remains

1. Update draft repair PR #1112, inspect its exact-head checks and raw
   macOS advisory artifacts, and merge only after actual validation is green.
   Preserve assertions, deadlines and strict skip accounting. No direct main
   push, silent retry, skipped test or speculative revert is authorized.
2. Validate the added failure diagnostic and run one bounded fresh hosted
   attempt after the positive local reproduction checks. If the remote worktree
   scenario fails again, diagnose its full child error before further retries.
   A completed success badge alone is insufficient.
3. Record the completed full client gate and hosted verdict separately from
   the reproduction and review evidence above. The quiet CI heartbeat remains
   active until there are no unresolved failures.

No installation, daemon restart, hotpatch, live state inspection or credential
search was performed. The enrolled inspector/viewer is unchanged.
