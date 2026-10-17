# Time to a usable first session

This investigation measures daemon readiness, session creation, and client
startup separately, then follows a cold daemon through a resident session to a
real terminal client's attached composer. It builds on the historical
[startup and memory investigation](startup-and-memory.md).
The [resource-budget results](#resource-budget-and-retained-changes) describe
the final source; the earlier sections retain the investigation history.

## Changes

Session configuration loading used eleven independent parses of the same TOML
text. It now parses once per load and hands the document to each table's
existing decoder. Catalogue validation still precedes profile/model selection,
which precedes the remaining tables in their original order. Standalone text
parsers retain their error wording. Every load still reads the file again;
secret commands are resolved again on every open. Domain admission validation
and session resolution remain independent loads.

The release daemon uses OTP 29's dependency-aware concurrent application
startup. OTP owns dependency ordering and rollback. The generated main wrapper
still runs afterward, with its application-start call becoming an
already-started check. The VM retains its native PID, original UTF-8/binary IO
setup, profiling flags and distribution flags. A refused application prints
its named reason and exits nonzero before daemon readiness. The terminal
client's launcher is unchanged: its application-only measurements were noisy.

An earlier candidate offered OTP a fixed 25-module batch after successful
domain configuration validation. The resource-budget comparison below found
higher post-domain memory, so the hint and its direct OTP binding were removed.
The final source retains ordinary demand loading.

Three retained session callbacks now capture their required settings fields
before constructing the closure. Role resolution, context-window lookup and
hub restart keep their previous values and ownership.

The benchmark now separates create replies from residency and the first
workspace domain from later sessions. Scenario g adds the complete fresh
session pipeline. It also corrects Linux `wait4` RSS units, bounds control RPCs,
and records configuration and enforcement provenance. Historical JSON without
compatible provenance is refused by `--compare`; use `--against` to remeasure
both releases with the current harness.

## Measurement boundaries

Scenario a ends at the daemon's listening line. Scenario b launches the client
without a daemon and ends at the first synchronized terminal frame; scenario c
uses an already running daemon. Scenario d runs `sessions list`.

Scenario e records the create reply and observed residency from the same
create send, retaining the first-domain sample separately from sessions 2–10.
Residency uses 10 ms status polling. Scenario g starts a cold daemon, creates a
session over its authenticated control socket, waits for residency, then
launches the real client with that session selected and waits for the attached
composer. Its total includes the gaps between those stages. Overlapping
endpoint rows must not be added together.

Scenario g is a programmatic pipeline, not the interactive picker-to-New
journey. The pseudo-terminal answers the graphics probe rather than charging
its 200 ms timeout. Profiling and memory censuses run separately from timed
samples. Warmups populate the page cache: these are fresh processes and state,
not cold-disk measurements.

## Environment and controls

Earlier latency measurements use Linux x86-64, stock Gleam 1.19.0,
OTP 29 / ERTS 17.0.5, a four-CPU container quota and five available logical processors. The daemon's
default is five schedulers; the released client uses four. Parser-only timings
use one scheduler and report the runtime and loaded catalogue BEAM path.
The resource-budget comparisons below instead fix both CPU affinity and quota
at one CPU, with the same compiler/runtime and unchanged release flags.

Every run has a private HOME, state directory and nested Git workspace. Models
point at an unreachable loopback port; no operator credentials are available.
The async fixture's post-timing prompt may attempt that synthetic provider.
The smoke catalogue is 368 bytes. The second synthetic catalogue
contains 32 model definitions and is 5,858 bytes. Input hashes accompany the
results. The parser benchmark also fingerprints decoded values outside its
timer and requires them to remain identical across samples.

The container cannot provide all kernel sandbox features. The initial default
run reached the composer but logged degraded jailed operations. Comparisons
therefore explicitly select the benchmark's `--best-effort` mode for both
releases. For client autostart the benchmark uses the existing `--server`
option with a private exec launcher selecting that same posture and the
original helper. This does not change production defaults. These measurements
do not establish startup time with full kernel enforcement on a deployment
host.

The frozen baseline's production source is main `8f66fc6`; its launchers carry
the compression-experiment commit identities present during compilation,
whose changes were confined to experiments and documentation. Both baseline
and candidate use the same stock compiler/runtime. After the initial-wave build,
that daemon launcher was regenerated from its builder's actual heredoc to
include the reviewed IO fix; compiled BEAMs were unchanged.

## Initial-wave results

First, isolate application startup using two copies of the candidate release.
All 2,544 BEAM files match byte for byte; the only launcher difference is the
OTP startup mode, `serial` versus `concurrent`. Nine pairs alternate their run
order, using the smoke catalogue and the same scheduler settings.

| Endpoint | Serial median ms | Concurrent median ms |
|---|---:|---:|
| Daemon listening, scenario a | 465.4 | 438.1 |
| Daemon listening, scenario g | 464.6 | 446.9 |
| First session resident, from create send | 360.4 | 360.3 |
| Attached composer, from client launch | 566.6 | 564.1 |
| Cold daemon through composer | 1406.4 | 1394.8 |

The daemon-readiness improvement is about 6% in scenario a. The complete
pipeline's roughly 1% median difference is small beside the observed ranges;
this does not establish a comparable improvement in usable-session latency.
Residency and client work are not expected to improve when only the daemon's
application-start mode changes. Raw rows are in
`build/bench-startup-memory/concurrent-only.json`.

Next, compare both changes against the frozen baseline using the 32-model
catalogue, again with nine alternating pairs. Times are milliseconds:

| Endpoint | Baseline median | Candidate median | Baseline p95 | Candidate p95 |
|---|---:|---:|---:|---:|
| Daemon listening, a | 511.1 | 451.6 | 606.6 | 831.0 |
| Cold client first frame, b | 1018.9 | 1055.9 | 1193.2 | 1318.9 |
| Client attach first frame, c | 517.5 | 502.8 | 655.0 | 750.5 |
| One-shot sessions list, d | 341.3 | 341.6 | 368.6 | 369.5 |
| First session create reply, e | 21.7 | 21.8 | 24.8 | 40.2 |
| First session resident, e | 418.3 | 388.4 | 479.3 | 433.4 |
| Later session resident, e | 119.6 | 102.2 | 163.5 | 135.6 |
| First session resident, g | 413.5 | 379.4 | 697.4 | 448.6 |
| Attached composer, g | 601.7 | 595.3 | 627.9 | 656.2 |
| Cold daemon through composer, g | 1504.7 | 1437.9 | 1851.4 | 1635.7 |

Each row has nine samples per release except later-session residency, which
has 81 samples across nine runs in creation order. Those 81 samples are not
independent fresh-domain trials. With nine samples the reported p95 is the
maximum, not a stable tail estimate. Raw endpoint samples and the separate
censuses are in `build/bench-startup-memory/first-session-combined.json`.

First-domain residency improved about 7%, later residency about 15%, and the
complete pipeline's median about 4%. Client results remain mixed: cold-client
first frame was about 4% slower, attach about 3% faster, and one-shot time
essentially unchanged. The unchanged client launcher provides no basis for a
general client-startup improvement claim. The noisier tails and overlapping
ranges also prevent treating these percentages as deployment guarantees.

Memory did not improve uniformly. The median ten-session peak RSS was
274.2 → 279.0 MiB, and sampled growth per session was 17.0 → 18.4 MiB. The
separate profiled ten-session `erlang:memory/0` census was 259.3 → 260.9 MiB.
The sampled growth ranges did not overlap in this series. In three separate
matched ten-session diagnostic pairs, a second explicit major GC reduced
allocated process bytes to 131.20–131.21 MiB for the baseline and 131.03 MiB for
the candidate. All ten sessions remained resident. The largest copied
supervisor state was effectively unchanged, 895,777 versus 895,713 flat words.
This supports allocation history and collectable garbage rather than a new
retained configuration graph. Post-GC allocated capacity is not exact reachable
memory, and these diagnostic collections do not erase the ordinary RSS result.
No production GC was added; the increase remains a deployment-host tradeoff.

Finally, the parser-only benchmark used five warmups and 51 timed samples per
fixture/mode. Input and decoded-result SHA256 values matched between modes:

| Configuration | Eleven parses median µs | Shared parse median µs | Old p95 µs | Shared p95 µs |
|---|---:|---:|---:|---:|
| Smoke, 368 bytes | 567 | 49 | 1284 | 95 |
| 32 models, 5,858 bytes | 14561 | 1327 | 16415 | 1852 |

This reduces decoder elapsed time about 91% in both fixtures. It excludes
file reads, secret execution, profile selection, VM startup and runtime
assembly. The small smoke-file saving is roughly half a millisecond per load;
the larger fixture saves roughly 13 ms. Raw parser samples and fingerprints
are in `build/startup/decode-final.jsonl`.

## Further cold-session work

A separate bounded trace attributed roughly 349 ms of the first builder to
104 synchronous module loads. SQLite schema execution itself took about
0.5 ms; locks, custody and schema ownership were not changed. Absolute traced
timings are attribution evidence, not comparable endpoint benchmarks.

Several wider loading experiments were rejected. Eagerly loading 137 observed
Gleam modules initially improved complete cold-to-resident timing, but a second
series did not reproduce that gain. Taking the full union of the relevant
application inventories loaded 459 additional modules and raised resident RSS
from about 99 to 158 MiB without a reliable total-latency improvement. A TUI
batch also produced mixed timing and approximately 15% higher RSS. None of
those strategies changed production defaults.

The bounded domain hint instead uses the 25 most expensive observed Gleam
modules. At its placement after successful configuration validation, 22 were
still unloaded. Seven rotating smoke trials compared control, 25-module and
137-module variants, with one warmup each. All variants used the same disposable
compiled module and differed only in the requested loading set. Loading cost
was included in residency and cold totals; the asynchronous create reply was
measured separately.

The narrow batch cost 32 ms median. First residency fell 383 → 319 ms and
cold-to-resident total 890 → 797 ms; all seven paired comparisons improved on
both endpoints. Resident RSS medians were effectively equal, but the paired
median difference was +1.375 MiB, so this establishes no memory saving.

A second scratch comparison followed the actual TUI through its attached
composer, using seven alternating pairs per fixture:

| Fixture | Control residency ms | Hint residency ms | Control cold → composer ms | Hint cold → composer ms |
|---|---:|---:|---:|---:|
| Smoke | 377.8 | 345.0 | 1507.8 | 1495.3 |
| 32 models | 418.6 | 349.6 | 1565.3 | 1408.0 |

The smoke composer result was small and noisy, with five of seven pairs faster.
The larger fixture improved residency in all seven pairs and composer time in
six; the remaining composer pair regressed 0.9 ms. This supports a first-domain
optimization, not a separate client-startup claim. These scratch results use
an instrumented frozen release; final production measurements are reported
separately below. Raw evidence is in `build/startup/lazy-batch-results.json`
and `build/startup/lazy-composer-results.json`.

The closure changes have a separate copy-cost proof. In matched private
32-model sessions, built callback environments no longer held the complete
Settings record. Subagent closure flat size fell 3015 → 1191 words; context
lookup 4740 → 1728; the hub restart closure, including smaller nested captures,
152791 → 121432. Copied supervisor-state flat size fell 895889 → 796691 words.
This is one controlled shape observation, not an RSS or exact retained-memory
measurement. Runtime, registry, restart and cleanup capabilities remain present.

## Earlier batch-loading production comparison

This section records the earlier `f4d68de` release, which included the loading
hint. The resource-budget results below supersede its selection; these timings
are not final-code claims after removing that hint.


That server was built from `f4d68de` using the same compiler/runtime and
explicit best-effort posture. The control is the frozen initial startup wave
at `beb8117`; this comparison therefore measures the bounded domain hint and
three closure projections on top of the shared parser and concurrent launcher.
The TUI artifact is unchanged: all 2057 file fingerprints match. Nine paired
runs alternate order, with the same 32-model configuration and warm page cache.
No diagnostic GC runs inside these timed or ordinary RSS observations.

| Endpoint | Initial wave median ms | Final median ms | Initial p95 ms | Final p95 ms |
|---|---:|---:|---:|---:|
| Daemon listening, a | 449.5 | 432.0 | 476.8 | 742.2 |
| First create reply, e | 20.8 | 22.3 | 26.3 | 28.9 |
| First resident, e | 378.0 | 341.5 | 385.4 | 357.8 |
| Later resident, e | 99.5 | 90.9 | 106.6 | 101.8 |
| First resident, g | 373.7 | 338.0 | 383.3 | 352.4 |
| Client first frame, g | 466.4 | 462.5 | 491.9 | 512.8 |
| Attached composer, g | 566.6 | 561.6 | 595.0 | 610.3 |
| Cold daemon through composer | 1414.2 | 1357.3 | 1453.7 | 1430.3 |

First residency improved in all nine pairs in both scenarios. Complete
cold-to-composer time improved in seven of nine, with a paired median saving
of 56.4 ms. Later-session residency has 81 correlated samples in creation order,
not 81 independent cold trials; 62 improved. Create replies remain asynchronous
admission acknowledgements, not proof of readiness. Client timing remains
effectively unchanged. The domain hint runs after daemon readiness; the
readiness variation and 742 ms outlier establish no additional daemon speedup.
As above, p95 with nine observations is the maximum rather than a stable tail.

Ten-session peak RSS medians fell 283.7 → 236.8 MiB; every paired run improved,
with nonoverlapping ranges of 277.7–287.3 and 233.2–242.1 MiB. Sampled growth
per session fell 18.44 → 14.37 MiB, also improving in all nine pairs. Separate
profiled ten-session VM allocation was 292.8 → 232.6 MiB. These OS/VM allocation
measurements apply to this workload and its recorded observation cuts, not exact
reachable state or a universal per-session memory requirement. They accompany the
independent closure-copy proof rather than assigning every RSS byte to it.
Code allocation at the separate one-session g census was 17.958 → 17.968 MiB.

A second seven-pair comparison isolates the loader. Its control is a disposable
copy of the final production release with exactly one `startup.prepare()` call
removed from the validated `build_domain` continuation. The unmodified abstract
code recompilation matched executable chunks; the transformed copy retains the
same chunk set and every other file's hash and mode. All 8456 production and
control manifest entries remained unchanged after timing. This is an attribution
control, not another shipped build or a production disable switch.

Against that control, first residency improved 373.2 → 349.1 ms in all seven
pairs; the paired median saving was 23.5 ms, ranging 10.5–42.3 ms. Complete
composer totals were 1442.1 → 1391.2 ms, faster in six of seven, with a paired
median saving of 30.0 ms. Daemon readiness varied despite the hint running
later, so the whole total difference cannot be assigned to module loading.
Client timing was mixed. For the already-loaded production hint, 51 batches
of 100 calls measured 148 µs per call at the median batch mean and 707 µs at
the p95 batch mean. This is operation cost, not an individual-call tail or
domain lifetime. Sessions sharing an existing domain bypass the hint entirely.

The complete paired endpoint/RSS samples and artifact provenance are retained
in [the measurement data](../review/first-session-startup-2026-10-17.json).
The original benchmark output remains under
`build/bench-startup-memory/domain-loading-wave2.json` and
`build/bench-startup-memory/domain-loading-attribution.json`.

## Validation of the earlier iterations

Independent validation passed the six new populated-configuration, refusal-order,
rewrite and secret-rotation tests, the 21 secrets-module tests, and all 145
Python script tests. The broader focused parser/domain run passed 406 tests.
The actual resolver was observed calling `tom:parse/1` once. Six resolver
mutations, benchmark deadline/cleanup/provenance mutations, and launcher
failure/order/IO mutations were rejected. Formatting and client lint passed;
the lint reported zero errors and 733 warnings. Package documentation
mirrors match.

The real release launcher passed both disposable-copy checks: dependency
readiness and native PID preservation on success; callback failure rollback,
nonzero flushed Unicode diagnostics, no main entry, no endpoint and no crash
dump on failure, including under the C locale. These checks substitute a
fixture entrypoint only in the copy; the startup benchmark exercises the real
daemon and client entrypoints.

The full local client gate is not green. It reached a failure in the existing
agency real-satellite typed-endpoint fixture, then its remaining run was
stopped through the watchdog (runner 143; make 2). The cause was not isolated.
A subsequent exact-fixture run failed the same readiness assertion with both
candidate modules (68.75 seconds) and the eight frozen baseline configuration
and resolver modules (66.88 seconds), using identical test BEAMs, helper and
other dependencies. Both exited 1 without a skip or timeout. This places that
specific failure outside the new configuration slice; it does not establish
the root cause or a passing full baseline suite.
A broad secrets filter additionally selected an unrelated enforcement test;
the subsequent exact secrets-module run passed. Hosted gates and deployment
signoff remain required before merge.

The initial startup revision `beb8117` subsequently passed hosted Linux and
macOS gates, including the full client job and both advisory client shards.
The domain-loading follow-up received independent source review of admission,
custody, cancellation, native reply decoding and the bounded inventory.
Independent local checks passed 159 tests across loader, configuration,
resolution, diagnostics, domain custody, owned assembly, checkpoint and serve
coverage. One additional serve test failed because this container cannot
create the `bwrap` namespace needed for its jailed listing; the aggregate run
exited 1. No enforcement requirement or test was weakened. Formatting and
client lint passed with zero errors and 734 warnings; refreshed source
citations restored documentation checks to zero errors and 196 warnings.

The actual rebuilt release passed
`scripts/check_startup_module_inventory.escript`: all 25 unique modules exist,
have no `on_load` or `erlang:load_nif/2`, and load from the supplied artifact on
both cold and repeated calls. The checker detects both initialization forms
in the SQLite NIF positive control without loading it. Removing an inventory
BEAM from a disposable copy was rejected. Two private compiled mutations that
made native calls or all decoded replies succeed were rejected by the six
loader tests; restoring the original module passed all six again.


## Deferred asynchronous terminal startup

This candidate was removed after the resource-budget review. Startup latency
must improve without increased CPU or memory. A fixed one-CPU comparison found
higher cold-smoke CPU time and higher warm-client peak RSS; the resource
measurements below supersede the latency-only recommendation. The following
records the rejected candidate and its original evidence, not the shipped TUI.


The candidate started daemon discovery before workspace discovery and model
construction. The terminal prepared its own subjects, model and terminal
identity while one Weft task resolved the daemon. Joining consumed
both the result and final accounting before the existing control adoption and
session-opening path. Demo, remote and one-shot launches retain their order.

The original terminal remains the control owner. Normal terminal exit cancels
the resolver and closes its control connection, including a completed handle
that the terminal has not joined. Ordinary resolver refusals remain UI errors.
An unexpected worker crash or lost accounting terminates the terminal, matching
the former inline crash, so its guardian can close even an unpublished handle.
The resolver retains its existing shared 90-second startup budget; there is no
competing worker-killing timeout during handle publication.

This comparison freezes the server release byte for byte at `f4d68de` and
compares the unchanged earlier client artifact (launcher identity `9896b0b`)
against the client built at `b5808a3`, whose production change is `32227fb`.
Both use the same stock compiler, runtime and release settings. The earlier
client source is unchanged through `e1460e1`; intervening server improvements
are therefore present on both sides of this client-only comparison.

The dedicated diagnostic seeds a real selected session over the daemon's
control protocol. Warm attachment retains that resident daemon. Cold autostart
normally stops the seed daemon, then times the real client automatically
starting a replacement and reopening the saved session. Both end at the real
attached composer, with first frame recorded separately. Native PID, birth,
executable and state-directory checks prove which daemon served each run; cold
runs require a replacement identity. After the timer, a PTY prompt must become
a new durable user-message entry. Each daemon must log normal shutdown without
an unconfirmed retirement. These are selected-session journeys, not the
interactive picker-to-New path.

The same private fixtures, unreachable providers, answered terminal probe,
warm page cache and explicit best-effort enforcement apply. Client peak RSS
includes the post-timing input check and is not a composer-only memory sample.
The retained diagnostic and paired samples allow this series to be reproduced
without adding another production benchmark mode.


Seven alternating pairs per fixture/journey, after one warmup per artifact:

| Fixture / journey | Baseline composer ms | Async composer ms | Paired median saving ms | Faster pairs |
|---|---:|---:|---:|---:|
| Smoke / warm attach | 785.2 | 600.0 | 213.3 | 6/7 |
| Smoke / cold autostart | 2379.4 | 1870.6 | 534.1 | 6/7 |
| 32 models / warm attach | 1150.9 | 698.7 | 237.1 | 5/7 |
| 32 models / cold autostart | 1520.1 | 1399.3 | 21.9 | 4/7 |

These results contain substantial scheduling variation. Smoke cold paired
savings range from a 1273 ms regression to a 1218 ms improvement. The 32-model
cold composer improved in only four pairs; its first frame improved in three,
with a paired median regression of 15 ms. This does not establish a consistent
cold-start improvement across configurations, and the large observed savings
cannot all be attributed to overlap.

A separate three-pair smoke repeat on the same frozen artifacts measured warm
composer medians 591.7 → 550.0 ms, with a 50.2 ms paired median saving and two
of three pairs faster (the remaining pair regressed 6.5 ms). Cold-autostart
composer medians were 1335.5 → 1290.2 ms, with a 45.3 ms paired median saving
and all three pairs faster. This supports a modest improvement in this local
fixture while retaining the wider series' uncertainty. Whole-fixture client
peak RSS medians in the seven-pair series stayed within about 1 MiB; no memory
saving is claimed. The preceding daemon/session gains and these client results
use different endpoints and series and must not be added together.

All 80 main/repeat trials passed durable input and normal-shutdown checks;
all 120 distinct seed/replacement native identities had retired afterward,
with no remaining `/proc` entries. The release audit found only `tui.beam`
changed among 827 common BEAM modules, plus the new `tui@startup` module and
its opaque-type header. All other 826 BEAMs match byte for byte. The launcher
changes only its embedded commit; application and boot terms differ only by
the new module inventory. Before/after complete release fingerprints match,
and the server release is identical between both artifacts.

Validation passed the full TUI gate (1,450 tests), all 20 real-control TUI
daemon tests, formatting, TUI lint and documentation checks. Private compiled
mutations removing fatal ownership-loss cleanup or skipping final accounting
were both rejected by their regression tests. Independent source and data
reviews found no remaining correctness issue. Release smoke passed with the
bundled runtime and metadata without host Erlang. Hosted CI for the final
published head remains a separate gate; earlier-head successes do not validate
this client change.

[Raw samples, fingerprints and audit](../review/async-startup-2026-10-17.json)
and the [retained diagnostic](../review/async-startup-2026-10-17.py) include the
seven-pair series and independent repeat, with warmups retained and excluded
from summaries. Freeze the prior releases at
`build/bench-startup-memory/releases/startup-overlap-baseline`, rebuild only the
client into `build/release/loom-client`, and leave the server unchanged. Prepare
the 32-model fixture using the recipe below, then run:

```sh
env -u ERL_FLAGS -u ERL_AFLAGS -u ERL_ZFLAGS \
  python3 -B docs/review/async-startup-2026-10-17.py \
  --runs 7 --label client-overlap-final
```


## Resource budget and retained changes

Startup improvements must not trade higher CPU or memory for lower wall time.
The follow-up therefore used the same single-CPU affinity and quota for both
artifacts: all runtime threads stayed on CPU 0 and `cpu.max` was
`100000 100000`. Release flags were unchanged. The dedicated container ran no
other workloads during measurement. There was no production GC, larger heap,
extra CPU allowance or new cache.

The timer ends at the actual selected-session composer. A cgroup `cpu.stat`
delta covers the interval from just before client launch through that endpoint,
including the daemon, client, short-lived helpers and small observer work.
Separate `/proc` counters retain user/system and waited-child CPU, quantized
at 10 ms. Per-process `VmRSS` and `VmHWM` are read immediately after the
composer and before the durable input check. Whole-fixture client `wait4`
CPU/peak RSS additionally include that post-timing input and possible provider
refusal. Linux `wait4` peak RSS is not summed process-tree RSS. Warm-daemon HWM
includes its seed session. Combined RSS is a sum of sequential samples, not
an atomic snapshot or a simultaneous peak. Component HWMs are not
added together as a simultaneous peak, and the container's cumulative
`memory.peak` is not a per-trial memory result.

The 64-trial async resource comparison rejected the earlier latency-only
selection. Warm-client whole-fixture peak RSS increased by a paired median
328 KiB in smoke (six of seven pairs) and 1,260 KiB with 32 models (all seven).
The larger fixture's composer-time client HWM also increased in all seven
pairs, by a paired median 376 KiB. Cold-smoke cgroup CPU increased by a paired
median 153 ms (four of seven pairs). CPU results in the other cases were mixed.
The complete async slice was removed; the TUI source returned exactly to its
pre-experiment state.

A subsequent 32-trial original-baseline comparison of the remaining batch-enabled
release still failed the budget. Smoke daemon HWM rose 1,968 KiB and combined
composer RSS rose 2,012 KiB in all seven pairs, despite paired median CPU
savings of 84 ms. The 32-model case saved 55 ms of CPU and 4,760 KiB of daemon
HWM, but a larger-fixture saving does not erase a smoke regression.

A bounded factor experiment held the shared parser, projections, client,
compiler/runtime and inputs fixed. It changed only application startup mode
and the domain loading hint, using four warmups and four rotated blocks of
four variants. All 827 client BEAMs matched. Serial launchers changed only the
OTP startup API call, retaining IO setup, error handling and native identity.
The no-hint control changed one call in `client@serve`, using the original
compiler options and an executable-chunk roundtrip check. All other runtime
files matched; non-runtime smoke-support differences were recorded separately.

| Hint enabled minus disabled | Concurrent apps | Serial apps |
|---|---:|---:|
| Seed first-resident daemon HWM, paired median KiB | +1,906 | +2,246 |
| Cold composer daemon HWM, paired median KiB | +1,594 | +2,132 |
| Blocks with higher post-domain HWM | 4/4 | 4/4 |

Before the first domain, hint variants actually had lower ready HWM in this
experiment. The finding is the post-domain increase, not an increase already
present at readiness or a proven reachable-state leak. The factor results
support removing the batch. App concurrency alone was mixed in the factor
memory results; the final combined baseline comparison follows.

The final source removes the batch, its direct OTP binding, associated tests
and obsolete inventory checker. It keeps the shared document and three narrow
Settings projections. The unchanged client has all 827 BEAM modules identical
to the original pre-optimization baseline. The production server is rebuilt
from `72c6263` before the final confirmation, rather than shipping a transformed
control. The retained resource archive contains both rejected series, factor
controls, fingerprints, native ownership checks and the final confirmation.

Seven alternating cold-autostart pairs per fixture, plus one warmup per
artifact, compare that actual rebuilt release against the original
pre-optimization baseline. Baseline server launcher identity is `90c9de4`
(compression-experiment metadata, production code from main `8f66fc6`);
candidate server identity is `72c6263`. The unchanged candidate client reports
`9896b0b`; its 827 BEAMs match baseline client `b1f6f06`. This measures the
remaining changes together, rather than assigning each saving to concurrency.

| Candidate minus baseline, paired median | Smoke | 32 models |
|---|---:|---:|
| Cold launch to attached composer, ms | −214.6 (4/7 lower) | −86.1 (5/7 lower) |
| Cgroup CPU through composer, ms | −280.0 (4/7 lower) | −89.3 (4/7 lower) |
| Daemon composer HWM, KiB | −1,748 (7/7 lower) | −2,664 (7/7 lower) |
| Combined sampled composer RSS, KiB | −1,428 (6/7 lower) | −3,720 (7/7 lower) |
| Whole-fixture client wait4 peak RSS, KiB | −488 (6/7 lower) | −1,348 (7/7 lower) |
| Client composer HWM/RSS, KiB | +16 (5/7 higher) | −964 (7/7 lower) |

These results support lower measured workload medians under unchanged capacity,
not absolute resource neutrality. CPU increased in three of seven pairs for
each fixture; smoke combined sampled RSS increased in one pair. The smoke
client's composer HWM/RSS increased by a paired median 16 KiB despite unchanged
client BEAMs. No tolerance is assumed and that increase is not waived. Neither
component snapshots nor whole-fixture `wait4` prove simultaneous aggregate
peak memory or exact reachable state. Composer wall-time ranges overlap;
there is no all-run or all-platform speedup guarantee. These are warm-page-cache,
selected-session journeys with explicit best-effort enforcement, not a
full-enforcement deployment result or an interactive New-session measurement.
Final resource sampling gaps ranged from 0.56 to 16.42 ms; all observations
remain in the data.

All 32 final trials proved durable post-timing input admission, normal daemon
shutdown and CPU affinity. All 64 seed/replacement native identities retired.
Before/after release fingerprints match. The actual rebuilt server changes
only `client@serve` among 1,717 common server BEAMs relative to the earlier
batch-enabled build, and removes the two batch modules; the other 1,716 match.
The [resource archive](../review/startup-resources-2026-10-17.json) retains all
148 trials across the four series, warmups, paired summaries, original input
hashes, factor controls, source identities and independent artifact audits.
Historical artifact paths describe their contents at measurement time.

Final validation passed the full TUI gate (1,447 tests), 16 real-control client
tests, 134 catalogue tests, six configuration-document tests and seven domain
tests. Client format/build and lint passed, with zero lint errors; package
documentation mirrors match. The stock server release build, two native
launcher checks and release smoke passed, including authenticated transport,
session admission and clean shutdown. The offline bundled-toolchain compile
was not verified: this kernel refuses its unprivileged network namespace.
The earlier full-client failures described above remain limits on local
coverage. Hosted checks and full enforcement/code-mode signoff for the
published head remain merge gates. No operator daemon was installed or restarted.

To repeat the final resource experiment, freeze the original baseline and
build the candidate with stock `make release release-client`. Prepare the
32-model configuration below, then run in a quiet dedicated Linux container
with `--cpus=1 --cpuset-cpus=0`. Copy the
[resource diagnostic](../review/client-resource-compare-2026-10-17.py) to its
original scratch location so the separate
[factor diagnostic](../review/client-resource-factors-2026-10-17.py) can import
it unchanged. Both retained files are byte-identical to their recorded driver
hashes. The later `--candidate` CLI selector preserves earlier trial logic.

```sh
mkdir -p build/startup
cp docs/review/client-resource-compare-2026-10-17.py build/startup/client_resource_compare.py
cp docs/review/client-resource-factors-2026-10-17.py build/startup/client_resource_factors.py
env -u ERL_FLAGS -u ERL_AFLAGS -u ERL_ZFLAGS \
  python3 -B build/startup/client_resource_compare.py --runs 7 --cores 1 \
  --workloads cold-autostart --configs smoke,models32 \
  --baseline build/bench-startup-memory/releases/first-session-baseline \
  --candidate build/release --allow-server-difference \
  --label startup-resource-repeat-1core
```

The factor driver additionally requires the disposable controls and variant
manifest described in the archive. It is not an installable release or a
production configuration switch. Rebuilding an older rejected candidate
requires its corresponding historical source, not the final source.

## Reproduce earlier measurements

The commands below record earlier iterations. The inventory checker belongs
to `2fc8e04` and its corresponding batch-enabled release; it is intentionally
absent from the final source. Use the resource procedure and retained drivers
for the final CPU/memory comparison.


Build and retain the baseline before applying changes, then compare the rebuilt
candidate. Run timing commands sequentially on a quiet host. Scenario f needs
a separate session database and is excluded from this fresh-session work.

```sh
make codemode-seed release release-client
python3 -B scripts/bench_startup_memory.py --only abcdeg --runs 9 \
  --label before --snapshot before
# Apply changes and rebuild both releases.
make release release-client
python3 -B scripts/bench_startup_memory.py --only abcdeg --runs 9 \
  --against before --label after
python3 -B scripts/check_daemon_startup_launcher.py build/release/loom
escript scripts/check_startup_module_inventory.escript build/release/loom
```

For the bounded-domain follow-up, retain the initial startup wave's release as
`startup-wave1`, rebuild the final server, and use the unchanged client:

```sh
env -u ERL_FLAGS -u ERL_AFLAGS -u ERL_ZFLAGS \
  python3 -B scripts/bench_startup_memory.py --against startup-wave1 \
  --only aeg --runs 9 --best-effort --config build/startup/models32.toml \
  --label domain-loading-wave2
```

Use `--best-effort` on both benchmark commands only when explicitly selecting
that enforcement posture. `--config PATH` selects a larger synthetic
catalogue; keep every model's URL on unreachable loopback. To reproduce the
32-model fixture:

```sh
mkdir -p build/startup
python3 - <<'PY'
from pathlib import Path
models = []
for i in range(32):
    models.append(f'''[models.m{i}]
dialect = "anthropic"
base_url = "http://127.0.0.1:1"
api_key_env = "LOOM_RELEASE_SMOKE_UNUSED_KEY"
model_id = "model{i}"
context_window = 200000
max_output_tokens = 8192
''')
Path('build/startup/models32.toml').write_text(''.join(models) + '[roles]\nmain = ["m0"]\n')
PY
```

The parser-only comparison runs the eleven old decoders versus the shared
document readers, excluding file IO, profile selection and secret execution.
Use each release's `lib` directory and its OTP runtime on PATH; clear emulator
flag overrides so the script's single-scheduler assertion holds:

```sh
env -u ERL_FLAGS -u ERL_AFLAGS -u ERL_ZFLAGS \
  ERL_LIBS="$PWD/build/bench-startup-memory/releases/before/loom/lib" \
  escript scripts/bench_config_decode.escript legacy build/startup/models32.toml 51
env -u ERL_FLAGS -u ERL_AFLAGS -u ERL_ZFLAGS \
  ERL_LIBS="$PWD/build/release/loom/lib" \
  escript scripts/bench_config_decode.escript shared build/startup/models32.toml 51
```

Results, raw samples and profiling scratch remain under ignored
`build/`; no operator daemon is installed or restarted.
