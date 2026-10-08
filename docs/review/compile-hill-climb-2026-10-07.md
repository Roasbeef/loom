# Compile-time investigation, October 7, 2026

The initial iteration's distribution build fell from 92.476 to 74.457 seconds in one matched
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

## Publication and the next measured targets

[PR #917](https://github.com/Roasbeef/loom/pull/917) publishes this change. It
was rebased onto main `7091d5a42`, with only a handoff conflict. The reviewer
rechecked that the upstream profiling reader, `tom` dependency, launchers and
bundled profiling smoke tests remain intact. The older matched comparison
above remains historical; it is not a timing comparison of the rebased source.

A fresh rebased `make -j1 dist` at `2495ca8eb` returned exit 0 in 105.975
seconds, including version resolution and a 14.05-second development rebuild.
Its server and TUI production compiles reported 36.07 and 16.51 seconds.
This is a validation run with different rebuild scope, not a matched regression
comparison. Both release smoke tests and archive checks passed, including the
new profiling true/false reader checks. All 477 exported TUI BEAM/application
files matched both staged clients, and every distribution checksum matched.

Before rebasing, diagnostic PATH wrappers timed subprocesses without changing
compiler options on the pinned source. A 35.624-second server export spent
23.620 seconds in five dependency `rebar3` invocations: cowlib 5.429, esqlite
10.067, yamerl 1.192, gun 6.156 and hpack 0.776 seconds. Within esqlite, compiling
SQLite C took 8.970 seconds. A 16.075-second TUI export spent 11.897 seconds
rebuilding cowlib, yamerl and gun. Nested escript timings include these waits
and must not be added again. These observations identify dependency rebuilds
as the next target; they do not establish savings from a cache.

Canonical gzip-9 packaging of the existing server, bundled client and slim
shipment took 6.198, 2.232 and 0.988 seconds, respectively, in a diagnostic pass.
The slim probe used the shipment directly, rather than the final staging root.
Increasing tar copy buffers preserved the server archive's exact SHA-256 but
changed CPU only from 4.847 to 4.747 seconds in one pair; the streaming variant
used 4.970 seconds. Neither experiment was retained. Compression level and
canonical archive metadata remain unchanged.

The rebased full `make check` returned exit 2 when its aggregate Python runner
reached the unchanged 20-second deadline (runner exit 124). Package tests had
not run. The signoff fixture `test_a_red_run_brings_back_why` independently
failed its expected lane-log assertion on both the PR and pristine main, with
exit 1 in each focused run. Those scripts are unchanged by this PR. A broader
signoff-script diagnostic reached its own 120-second deadline. These are
unresolved local gate limitations, not green validation or proven flakes.
The rebased launcher checks passed in the native rerun after a sandboxed
fixture failure. Documentation checks returned exit 0 with zero errors and
198 warnings after the new evidence was added.

At the end of that iteration, optional ccache support would target SQLite's repeated C compile; reusable
production exports could also avoid repeated Erlang dependency compilation,
but require a freshness contract for changed and removed modules, dependencies
and toolchains. The owner was asked to choose before introducing a dependency
or cache pattern. Neither had been installed or implemented at that point. The owner subsequently
approved the three further compile/export experiments recorded below.


## Verified reuse iteration

The owner approved dependency reuse, incremental exports and measured source
optimizations. The retained implementation is `c25b61102`, with the global-hook
freshness guard at `b4dbb0a4d` and exact Hex-source admission at `2159d30b0`, still based on main `7091d5a42`. No application
source, manifest, compiler optimization or compression setting changed.

`scripts/shipment.py` leaves Gleam responsible for clean compilation, dependency
ordering and shipment construction. An unchanged TUI production closure can
restore a content-verified shipment. Source changes, including removed modules,
run the official clean exporter. Its scoped rebar3 adapter can restore the
reviewed pure Erlang dependency versions: cowlib 2.20.0, gun 2.6.0, yamerl 0.10.0
and hpack_erl 0.3.0. Each dependency key includes its transitive sources. Admission also requires
the exact reviewed source fingerprint throughout the Erlang dependency closure;
an edited recipe loses eligibility even if its version is unchanged.

SQLite's native build and unknown builders remain fresh and disable whole
shipment reuse, including on the server. The review identified that hashing CC
and default headers did not cover esqlite's pc plugin, linker and optional
system libraries. Excluding native reuse closed that finding and also removed
an unnecessary C compiler requirement for exporting the pure TUI. Global rebar
configuration and file-valued compiler overrides take the fresh path too.

The cache lives under ignored `build/shipment-cache`, scoped to this checkout's
absolute production paths. Keys cover actual source contents, the locked
production closure, compiler and OTP bytes, environment and recipe. Output
contents and file modes are verified before restoration. A writer lock covers
cached and fresh invocations. Dependency misses are staged privately and become
reusable only after the complete export succeeds and source/toolchain inputs
still match. `LOOM_SHIPMENT_CACHE=0` or the driver's `--fresh` bypasses reuse.
The release's development warning check, probes and smoke tests remain intact.

### Measurements

These native runs used the same pinned Gleam 1.19.0 and OTP 29 described above.
The direct exports used `c25b61102`; the full distribution pair used
`b4dbb0a4d`, `DIST_DEBUG=1`, `make -j1 dist`, identical source and environment,
and sequential execution. The fresh distribution added only the cache-bypass
variable, which is excluded from cache identities. Each row is one observation,
not a median or a guarantee for other hosts.

| Scope | Official fresh export | Reused inputs |
|---|---:|---:|
| Unchanged TUI export, wall time | 16.453 s | 0.676 s |
| Server export, native build retained, wall time | 38.603 s | 26.394 s |
| Complete distribution and smoke tests, wall time | 69.758 s | 41.034 s |

The complete distribution reduction in this pair is 28.724 seconds (41.2%).
The TUI's real temporary-module addition, body change and removal exports took
5.410, 6.975 and 5.850 seconds with dependency reuse. The added and changed
modules were executed in fresh Erlang VMs to assert values 1 and 2; the final
shipment contained no BEAM for the deleted module.

The empty-cache distribution seed also passed but took 170.581 seconds and is
excluded from the matched fresh/reused pair. A process snapshot showed high
filesystem-event activity on the host. That does not establish the entire
cause of the outlier. Earlier sandboxed trials also encountered rebar download
errors and are excluded from the native comparison.

Raw logs are `dist-reuse-clean-{seed,fresh,warm}.log`, with own exit codes and
wall times in `dist-reuse-clean-results.json`, under the same temporary evidence
directory. Direct-export logs use `reuse-final-*`. An initial diagnostic asserted
whole-server byte equality and failed only on the fresh native NIF; the next
comparison explicitly identified that difference. All 794 server BEAM files,
55 application metadata files and both entrypoints matched fresh output exactly.
The esqlite NIF is freshly rebuilt in both paths and differed byte for byte;
whole-server artifact reproducibility is not claimed.

### Source experiment and validation

On the current application source, abstract-form profiling measured 5,804 ms of
client compiler CPU over 140 modules and 3,175 ms of TUI CPU over 92 modules.
The largest modules were client gateway (631 ms) and TUI view_set (276 ms).
A gateway ablation baseline was 611 ms; stubbing run_command removed 292 ms,
apply_config 50 ms, captured_transfer 63 ms and begin_transfer 31 ms. Stubs are
diagnostic and were never production code. Moving the admitted command table
outside its authority callbacks measured 694 ms in the three-run module median,
so the source experiment was discarded and the original file restored exactly.
No source refactor demonstrated an end-to-end improvement worth retaining.

All three clean distribution invocations returned exit 0, including both
bundled release smoke tests, profiling-reader checks and archive validation.
Every listed archive checksum was independently verified. All 477 TUI BEAM and
application metadata files matched the staged slim and bundled clients. macOS
again verified code-mode registration, with jailed offline toolchain execution
explicitly unverified on this kernel.

All 12 shipment freshness regressions pass, covering additions, changes,
removals, transitive and symlink inputs, corruption, toolchain/flag changes,
failed and mixed builds, staged dependency publication, fresh bypass and native
or global-hook exclusion, including an edited transitive Hex recipe retaining
its version. The independent review's two findings were verified
against the code and closed; the reviewer rechecked the native/CC fixes.

Full `make check` on `b4dbb0a4d` still returned exit 2 at the unchanged aggregate
Python deadline (runner exit 124), before package gates. The signoff lane-log
fixture was independently reproduced on this branch and pristine main, so the
full local gate remains red. No tests were removed or deadlines weakened.
Hosted checks observed at the earlier PR head `974a084ec` had a successful Linux
gate and a failed macOS gate. Those are not CI results for the reuse commits;
new-head CI and Linux signoff remain outstanding. No merge or installation was
performed. After the exact-source admission guard, two real TUI exports returned
exit 0 in 17.479 seconds to populate reuse and 0.679 seconds for the verified hit
(`final-admission-tui-{seed,warm}.log`). Real client and TUI dependency inventories
confirmed eligibility for the expected pure versions and exclusion of SQLite.
