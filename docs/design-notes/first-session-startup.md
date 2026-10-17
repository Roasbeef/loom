# Time to a usable first session

This investigation measures daemon readiness, session creation, and client
startup separately, then follows a cold daemon through a resident session to a
real terminal client's attached composer. It builds on the historical
[startup and memory investigation](startup-and-memory.md).

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

Measurements use Linux x86-64, stock Gleam 1.19.0, OTP 29 / ERTS 17.0.5, a
four-CPU container quota and five available logical processors. The daemon's
default is five schedulers; the released client uses four. Parser-only timings
use one scheduler and report the runtime and loaded catalogue BEAM path.

Every run has a private HOME, state directory and nested Git workspace. Models
point at an unreachable loopback port; there are no model requests or operator
credentials. The smoke catalogue is 368 bytes. The second synthetic catalogue
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
and candidate use the same stock compiler/runtime. After the candidate build,
the daemon launcher was regenerated from its builder's actual heredoc to
include the reviewed IO fix; compiled BEAMs were unchanged.

## Results

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
The sampled growth ranges did not overlap in this series. Heap/GC timing is a
plausible explanation, but it has not been established. No retained-memory
saving is claimed; the observed increase remains a tradeoff to check on a
deployment host.

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

## Validation

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

## Reproduce

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
