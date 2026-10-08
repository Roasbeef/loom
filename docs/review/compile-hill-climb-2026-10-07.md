# Compile-time investigation, October 7, 2026

The distribution build fell from 92.476 to 74.457 seconds in one matched
control/candidate pair, a reduction of 18.019 seconds (19.5%). Both runs
completed with exit 0. This measures the complete distribution build and its
smoke tests; it does not establish a median or an installed update duration.

## Toolchain and comparison

Both runs used the clean application tree at
`9127107f6989f7e636d36d2d1b95b774514473a7`, with identical application sources
to base `f342975625f692a81dd6cfcd07eaedc100098a80`. The control used the base
Makefile; the candidate used the committed Makefile. Both ran sequentially in
the same isolated worktree with `DIST_DEBUG=1` and the same dependencies.

The compiler was an immutable copy of Gleam 1.19.0, SHA-256
`fa41094adf67780a3078bb494bb8c7b1ab0bc586752c97adacde9d6cab4cc9e0`,
with Erlang/OTP 29 and ERTS 17.0.5 on macOS arm64. Its directory was first
on PATH. Earlier setup runs with mixed caches and an unpinned executable are
excluded from this comparison.

The commands were `make -f /private/tmp/loom-compile-hill-climb/Baseline.Makefile
-j1 dist` and `make -j1 dist`. The baseline file was extracted from the base
commit. Raw logs and the pinned compiler remain under
`/private/tmp/loom-compile-hill-climb`; these temporary files are not durable
repository artifacts.

## What caused the repeated work

Gleam 1.19 emits Erlang abstract forms. Its
[shipment exporter](https://github.com/gleam-lang/gleam/blob/v1.19.0/compiler-cli/src/export.rs)
removes the production build directory before compiling the shipment. A
second export therefore rebuilds the dependency closure even without source
changes.

The previous distribution graph exported the TUI once for the bundled client
and again for the slim client. The new graph stages both clients from the
fresh export produced by the bundled-client prerequisite. Standalone
`make tui-shipment` still exports afresh. There is no persistent shipment
cache or changed compiler optimization setting.

| Stage | Control | Candidate |
|---|---:|---:|
| Server production compile, compiler-reported | 32.28 s | 35.86 s |
| First TUI export, compiler-reported | 14.98 s | 15.82 s |
| Second TUI export, compiler-reported | 21.97 s | Eliminated |
| Complete distribution, wall time | 92.476 s | 74.457 s |

The single TUI export still costs roughly 15–22 seconds in these runs. The
server's development build also serves warning checks and the release probe;
it was retained. Removing necessary validation was not part of this change.

## Abstract-form profiling

The initial profiler invocation targeted a stale generated-Erlang directory
and reported zero modules. That observation was invalid. The profiler now
fails with exit 2 when its abstract-form input directory is absent or empty,
and both skill entry points describe this behavior.

After the final build, the production client profile measured 5,215 ms of
compiler CPU over 134 modules; its largest module was the gateway at 501 ms.
The TUI profile measured 3,082 ms over 92 modules; its largest modules were
view_set (250 ms), interaction (242 ms), and render (223 ms). These are
abstract-form compilation CPU measurements, excluding dependencies, FFI,
Gleam parsing, packaging and release wall time. They do not show a single
module dominating the whole shipment duration.

A small TUI function-boundary experiment did not improve the measured export
and was discarded. No application-source optimization is retained.

## Validation and limits

Both full distribution runs passed the server and client release smoke tests
and archive validation. The server booted using its bundled runtime, proved
authenticated readiness, rejected missing authentication, exercised session
admission and shared-domain distillation, and drained cleanly. Code mode
registered from the bundled toolchain. The client booted with its bundled
runtime and verified its release identity.

All 471 BEAM and application metadata files in the fresh TUI export matched
the staged slim and bundled clients byte for byte. Every checksum listed in
the candidate distribution's SHA256SUMS was independently verified.

All 61 Python script tests passed in a native rerun. The first sandboxed run
failed four installation-pruning tests because process inspection was
unavailable; that failed run is preserved. Launcher profiling tests passed.
The documentation gate returned exit 0 with zero errors and 195 warnings
after the evidence and handoff rewrite. A fresh independent review found no
reachable issue in the distribution ordering or profiler failure handling.

Full `make check`, hosted CI and Linux signoff were not run for this build-only
change. macOS could verify code-mode registration, but the smoke test explicitly
could not prove a jailed offline bundled-toolchain compilation because the
kernel lacked the required unprivileged network namespace. Nothing was pushed,
merged, installed or restarted.
