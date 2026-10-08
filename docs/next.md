# Current handoff

This edition records the October 7, 2026 compile-time investigation on
`perf/compile-hill-climb`. The original measurements used application source
`f342975625f692a81dd6cfcd07eaedc100098a80`. Publication rebases the build-only
change onto main `7091d5a42`; those older timings are not measurements of
the newer application source. The implementation and measurements
are at `9127107f6989f7e636d36d2d1b95b774514473a7`; the following documentation
commit records the evidence. Work is isolated in `.worktrees/compile-hill-climb`.
The original checkout's unrelated untracked files were preserved.

Read [the compile-time investigation](review/compile-hill-climb-2026-10-07.md)
for commands, toolchain identity, timings and validation limits. The upstream handoff described the October 6 context and configured profiling
work; its evidence remains in [the context report](review/beam-context-cpu-2026-10-06.md),
[transfer report](review/beam-transfer-cpu-2026-10-06.md) and
[render report](review/beam-render-2026-10-06.md). The older October 5 evidence
remains in [its report](review/beam-cpu-2026-10-05.md). Their PR and hosted-check
status was not refreshed here and must not be treated as current. The upstream
profiling configuration, launcher checks and signoff requirements are retained.

## Where the tree is

The distribution now exports the TUI once and stages the slim and bundled
clients from that fresh export. Standalone `make tui-shipment` retains its
fresh export. Gleam 1.19's shipment exporter clears its production build
before compiling, so the former second export rebuilt the entire dependency
closure. No compiler optimization setting or application source changed.

The abstract-form profiler now rejects absent or empty input directories
with exit 2. The initial zero-module observation came from a stale directory
and was invalid; only the corrected Gleam 1.19 profiles are evidence.

One matched full distribution pair fell from 92.476 to 74.457 seconds,
19.5%. Both commands returned exit 0 and passed release smoke tests and
archive validation. All 471 TUI BEAM/application metadata files matched
both staged clients byte for byte, and distribution checksums were verified.
All 61 Python script tests passed in the native rerun; launcher tests passed.
An independent review found no actionable issue. The documentation gate
passed after this rewrite with zero errors and 195 existing warnings.

## What remains open

A single production TUI export still takes roughly 15–22 seconds. The
corrected profiles did not identify a module dominating the whole export,
and a small function-boundary experiment did not improve it. Future work
should measure Gleam generation, dependency compilation and shipment work
separately before choosing another source refactor. Do not infer a source
compiler regression from a whole-export wall time.

Full `make check`, hosted CI and Linux signoff remain unverified for this
branch. macOS smoke tests prove bundled startup and code-mode registration;
they do not prove jailed offline bundled-toolchain compilation on Linux.
[PR #917](https://github.com/Roasbeef/loom/pull/917) publishes the build change.
The first full gate was interrupted with exit 130 to rebase its stale source;
it establishes no complete-gate verdict. Fresh-base validation is pending.
No change has been merged, installed or used to restart a production process.

Keep necessary development warning checks and release probes when changing
the pipeline. Any persistent shipment cache needs an explicit freshness
contract; this change avoids that machinery by reusing the export only
within the same distribution invocation. Each gate must be judged by its
own exit code, as [execution](execution.md) requires.
