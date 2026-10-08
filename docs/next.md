# Current handoff

This edition records the October 7, 2026 compile/export iteration on
`perf/compile-hill-climb`, checked against implementation `2159d30b0` and
base main `7091d5a42`. Rewrite it after the next body of work. Every current
claim below is tied to the tree or the validation recorded in
[the compile-time report](review/compile-hill-climb-2026-10-07.md).

Work is isolated in `.worktrees/compile-hill-climb` and published through
[PR #917](https://github.com/Roasbeef/loom/pull/917). The original checkout's
unrelated files were preserved. Earlier profiling work remains in the
[context report](review/beam-context-cpu-2026-10-06.md),
[transfer report](review/beam-transfer-cpu-2026-10-06.md),
[render report](review/beam-render-2026-10-06.md) and
[October 5 report](review/beam-cpu-2026-10-05.md). Their unrelated project
milestones were not refreshed in this compile-time task.

## Where the tree is

| Work | Current evidence |
|---|---|
| Duplicate TUI export | Distribution stages both clients from one current export. |
| Dependency reuse | Reviewed pure Erlang versions reuse verified outputs in each production root. |
| Incremental exports | Unchanged TUI restores its verified shipment; changed/removed source uses Gleam's clean export. |
| Source optimization | Gateway and TUI boundary experiments showed no retained win; application source is unchanged. |
| Validation | Distribution smokes and checksums pass; 12 new regressions pass; full local gate remains red. |

The previous edition said no persistent cache existed and the owner choice was
pending. That is now false: the owner approved all three experiments.
`scripts/shipment.py` implements the retained reuse strategy. The development
warning check, release probes, profiling reader and smoke tests still run.
Gleam 1.19 continues to own compilation and production shipment assembly.

At `b4dbb0a4d`, one matched full distribution pair took 69.758 seconds with
fresh exports and 41.034 seconds with reuse, a 41.2% reduction. Both returned
exit 0, and all archive checksums were verified. All 477 TUI BEAM/application
files matched both staged clients. These are single observations on macOS
arm64 with pinned Gleam 1.19.0 and OTP 29, not medians or other-host guarantees.
The empty-cache seed was a 170.581-second outlier and is recorded separately.

Direct exports on `c25b61102` measured TUI 16.453 seconds fresh versus 0.676
seconds unchanged, and server 38.603 versus 26.394 seconds with dependency
reuse. Real added/changed TUI modules executed with their new values; the
removed module's BEAM disappeared. All 794 server BEAM files, 55 application
files and both entrypoints matched fresh output. The newly rebuilt native NIF
differed; whole-server reproducibility is not claimed.

The abstract-form profiler rejects missing or empty input with exit 2. The
initial zero-module observation was invalid and remains explicitly corrected
in the report. The newest module profiles show distributed cost, with no
single pathological module. A gateway helper extraction measured 694 ms of
compiler CPU against a 611 ms baseline and was restored exactly.

## What to do next

1. Finish hosted CI and Linux signoff for the published reuse head of **PR #917**.
   **Exit:** required checks pass on that exact head, with actual jailed offline
   bundled-toolchain validation distinguished from registration alone.
2. Resolve the existing local signoff-fixture limitation separately if the
   complete macOS gate is needed. **Exit:** the lane-log assertion and aggregate
   Python runner pass without removing tests or weakening their deadlines.
3. Revisit native compilation or source refactoring only with a new measured
   hypothesis. **Exit:** a matched build/export improvement with unchanged
   behavior and the affected package gates. Optional ccache is unimplemented.

Full `make check` at `b4dbb0a4d` returned exit 2 at the unchanged aggregate
20-second Python deadline (runner 124), before package gates. The focused
`test_a_red_run_brings_back_why` fixture returned exit 1 on both this branch
and pristine main. All 12 shipment tests passed independently. The exact-source admission guard
at `2159d30b0` was checked against both real downloaded dependency closures. This is not a
complete green local gate. Hosted status last inspected at old head `974a084ec`
had a successful Linux gate and a failed macOS gate; it says nothing about CI
for the newly published reuse commits.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Reuse verified declared inputs.** [Distribution](distribution.md) describes
the private cache and fresh bypass. Cache keys cover actual source contents,
the locked production closure, compiler/OTP bytes, environment and recipe.
Cached output digests are checked. Successful complete exports publish staged
dependency misses only after source/toolchain revalidation. The writer lock
also covers fresh invocations.

**Keep native and arbitrary hooks fresh.** SQLite and unknown builders disable
whole-shipment reuse and never enter the dependency reuse plan. Global rebar
configuration and file-valued compiler flags force the official fresh path.
Known pure versions require their exact reviewed source fingerprints throughout
the Erlang dependency closure, and are scoped to each checkout and production root; no
cross-root BEAM sharing, native cache, compiler flag change or extra dependency
was introduced. The independent review's native-input and C-prerequisite
findings were closed and the fixes rechecked.

## Deliberately open

Native SQLite compile time, further generated-code optimization and archive
compression remain measured opportunities rather than implemented changes.
The larger-buffer compression experiment showed too little improvement to
retain. None of these is unfinished work somebody forgot.

No merge, installation or resident-process restart has occurred. macOS smokes
prove bundled startup and code-mode registration; this kernel cannot prove
jailed offline execution with the bundled compiler.

## How to verify

Use `python3 -m unittest discover -s scripts -p test_shipment.py -v`,
`make doc-check`, and the full `make check`. Compare `DIST_DEBUG=1 make -j1 dist`
with `DIST_DEBUG=1 LOOM_SHIPMENT_CACHE=0 make -j1 dist` from a clean committed
tree and warmed reuse state. Both include release smokes and archive checks.

**Judge each gate by its own exit code.** **Archive creation requires a clean
committed tree.** **Run measurements sequentially with the same pinned tools
and rebuild scope.** Record cold-cache seeds, warm hits, native compilation and
whole-build noise separately. See [execution](execution.md) for the remaining
worktree, process-group and signoff hazards.
