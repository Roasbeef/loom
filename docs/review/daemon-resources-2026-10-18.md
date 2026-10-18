# Local daemon resource investigation — October 18, 2026

Two ownership changes remove unnecessary request retention and cross-process
copies. They are implemented and locally validated on `perf/daemon-resource-cost`.
The running daemon was observed without installing, restarting, hotpatching,
walking application state, or forcing collection in it. Daemon-wide CPU and RSS
savings remain unmeasured.

Source baseline: `928d0ae50dfe70277512a4c05116626c7c28d942`.
The call-worker change is `c470b82a0`; the provider change and measured candidate
are `2a99a8b448c3b79fc4ebe6b5a744a5a465fd5dc6`.

## Live observations

The operator confirmed that the large agent workload was on the local daemon.
Pickglass attached to PID 71417, OTP 29 / ERTS 17.0.5, with 16 schedulers. Its
installed release was `server.8mQc1HKZ`. The capture header did not identify a
source revision; the baseline above was established from the installed release
separately. The first capture declared one session and two strands, while the
process census showed many provider and satellite workers. Declared owner labels
are not a reliable worker count. These short captures do not establish that the
peak agent workload was sampled.

| Observation | During earlier workload, 01:59:16 CDT | After operator reported completion, 02:12:46 CDT |
|---|---:|---:|
| BEAM total bytes | 268,248,349 | 185,377,653 |
| BEAM process bytes | 164,151,152 | 84,020,008 |
| BEAM binary bytes | 52,501,696 | 49,770,488 |
| BEAM ETS bytes | 1,997,024 | 1,990,272 |
| Process count | 328 | 235 |

These are `erlang:memory/0` categories; the total includes the other rows. The
decrease happened on unchanged production code as the workload settled. It is
not evidence of savings from this branch. Separate, nonsimultaneous `ps` samples
reported 388,576 and 311,744 KiB RSS and 1.0% and 0.2% CPU respectively. A
`footprint` sample reported 360 MB physical footprint and 433 MB peak. Neither
RSS nor physical footprint is interchangeable with BEAM memory categories.

The 10-second top-16 stack profile achieved 62 Hz: 9,392 observations, of which
80 were running/runnable and 9,312 waiting. Flat active samples included
`esqlite3:fetchall1/1` (16), `gleam_erlang_ffi:select/2` (13), and
`gleam@bit_array:is_utf8_loop/1` (9). The 16 selected targets were a subset of
the process list; one exited. Safe-point stack sampling underrepresents long NIF
work. These counts are sampled attribution, not percentages of total daemon CPU.

The allocation trace requested five seconds and observed 5.106 seconds over
eight selected processes and four module groups: `core@json`,
`storage@internal@register_cache`, `storage@sqlite`, and `runtime@strand_runtime`.
Its counters read 253 called functions, 2,681,361 words (21,450,888 bytes).
The displayed top 200 functions were truncated. Leading cumulative allocations
were `read_decoded/4` (470 calls, 6,213,656 bytes), `handle_open/2` (1,011 calls,
2,423,848 bytes), `parse_string_body/2` (6,332 calls, 1,764,192 bytes), and
`do_get_register/4` (940 calls, 1,512,904 bytes). This measures cumulative heap
allocation in the traced scope, not retained bytes, binaries, RSS, or all VM
allocation. Polling/decoding remains a lead; this change does not alter it.

The live heap census motivated inspecting worker ownership. The particular
worker copies and retention below were proved with source inspection and
isolated fixtures; the stack profile does not attribute those costs directly.

## Call-worker copying

In [satellite.gleam](../../packages/codemode/src/codemode/satellite.gleam),
`route_cap_call`'s precheck closure captured the host `State`. The deferred
settlement callback in `dispatch_cap_call` also captured `State` to obtain its
command subject. Each spawned call worker could therefore copy unrelated host
fields, including all capability ceilings. The worker only needs the precheck,
router, command subject, and call identity. Projecting those values before
constructing the closures removes both broad captures, without changing
admission, routing, ceilings, or settlement.

The regression runs a real fake-peer capability round trip, serves the first
call, and rejects the second under the actual one-call ceiling. It varies
unrelated host ceilings from zero to 5,000, with the exercised ceiling first so
lookup cost stays fixed. A test-only probe records worker process memory before
and after collecting that synthetic worker. Both cuts matter: the precheck's
large capture can die before collection, while deferred settlement retains its
capture across the capability call.

Five alternating baseline/candidate pairs ran in fresh single-scheduler VMs
using the shipped OTP build, with 50 fixture repetitions per run. The baseline
archive contains the original production source and the candidate regression
fixture. Whole-fixture timing includes setup, capability calls, probe collection,
and cleanup; it is not user-visible tool latency.

| 5,000-ceiling fixture | Baseline | Candidate |
|---|---:|---:|
| Worker memory before collection, every run | 372,240 bytes | 2,728 bytes |
| Worker memory after collection, every run | 372,240 bytes | 2,728 bytes |
| Median VM CPU for 50 fixtures | 76 ms | 70 ms |
| Median elapsed for 50 fixtures | 179,650 µs | 174,660 µs |
| Reductions for 50 fixtures, every run | 1,759,649 | 1,659,099 |

Worker heap capacity falls 99.27%; median CPU falls 7.89%, elapsed 2.78%, and
reductions 5.71%. The zero-extra-ceiling control has approximately unchanged
CPU: median 68 ms for both. The 5,000 entries are a copying-growth control, not
an observed live configuration. Post-collection process memory is allocated
heap capacity, not an exact reachable-term size. Preliminary timing figures
are superseded by these final five pairs.

Restoring either broad capture independently makes the strengthened regression
fail its initial-memory bound. The untouched baseline also fails. Thus the test
detects both sources of copying, including the short-lived one.

## Provider request lifetime

In [gateway.gleam](../../packages/provider/src/provider/gateway.gleam), `Guard`
previously retained `Gateway`, `ProviderRequest`, and the request timestamp after
starting its fallback pump. The pump needs these inputs through request
preparation and fallback; subsequent guard states need control and accounting.
Moving the inputs into the private `Parked` phase makes the begin transition
transfer them to the pump. The guard's later state cannot retain those fields.
Public interfaces, prepare/begin ordering, adoption, cancellation, and drain
remain unchanged.

The regression parks a synthetic request with 5,000 blocks, then gates the fake
transport after checking that its encoded body contains all 5,000 markers.
It reads only that isolated guard's state size and releases the transport,
observes terminal delivery, and proves drain before checking the size bound.
No real provider or live daemon is involved. The baseline fails the active-state
bound; the candidate passes.

A separate synthetic driver compares 100- and 10,000-message requests under
the same shipped VM. It collects only its own guard and pump, checks the native
fixture is alive, then cancels and waits for normal scope drain.

| 10,000-message fixture | Baseline | Candidate |
|---|---:|---:|
| Parked application-state pair, flat words | 160,122 | 160,124 |
| Active application-state pair, flat words | 160,219 | 146 |
| Guard process memory after collection | 1,574,496 bytes | 9,192 bytes |
| Pump process memory after collection | 4,119,904 bytes | 4,119,904 bytes |
| Encoded request body | 299,023 bytes | 299,023 bytes |

The two-word parked increase is the phase payload. At 100 messages, active
state is 1,819 versus 146 words. `flat_size` covers the returned application-state
pair, not every process root. The pump still owns the required request and body;
shared binaries do not become uniquely freed merely because the guard drops
its reference. These numbers establish the guard's shorter lifetime, not a
99% reduction in total request memory or daemon RSS.

## Validation and review

- `make check-codemode`: exit 0, all 413 tests pass, including the real jailed
  code-mode build and satellite path after `make codemode-seed`. No `SKIP` lines.
- `make check-provider`: exit 0, all 319 tests pass. No `SKIP` lines.
- `make lint-codemode lint-provider`: exit 0, zero errors; 97 and 58 warnings
  respectively. The warnings are a census, not a claim that every candidate
  has been investigated.
- Package documentation mirrors and the effects architecture note are updated.
  `make doc-check` exits 0 with zero errors and 208 warnings, and
  `git diff --check` passes. These gates are separate from package gates.
- A fresh independent adversarial source review found no actionable findings
  in the ownership transitions, regressions, or nearby capture variants. The
  reviewer did not independently execute builds or benchmarks.

An earlier code-mode run collided with rebuilding its test FFI and failed on a
missing test helper export. It was superseded by the stable, complete 413-test
run above. The macOS cache seeder could not itself verify an unprivileged
network namespace; the final code-mode gate nevertheless ran its actual jailed
fixture. Full repository checks, hosted CI, and Linux signoff are not claimed.

## Evidence and reproduction

The [aggregate evidence directory](daemon-resources-2026-10-18/) contains
[worker results](daemon-resources-2026-10-18/worker-results.json),
[guard results](daemon-resources-2026-10-18/guard-results.json),
[live metrics and capture hashes](daemon-resources-2026-10-18/live-summary.json),
and the two isolated Erlang drivers. The worker driver invokes the actual
regression fixture, exporting its private helper only in that diagnostic VM.
The provider driver uses generated private tuple layouts for the recorded
source; update it if those layouts change. Neither driver is a stable API.

Build the selected package and tests before starting its driver, compile the
driver with `erlc`, and start a fresh `erl -noshell +S 1:1 -s <driver> main` with
the matching package/dependency `ebin` paths. For the candidate provider run,
candidate provider and gleeunit paths precede the shipped release paths. Never
replace artifacts while a test or driver using them is running.

Raw captures remain private, outside Git, under
`/Users/roasbeef/.codex/visualizations/2026/10/18/01a14dc3-2fef-72d0-b730-152ed82070c9/daemon-profile/`.
Their filenames are `loom-profile-20261018-{before,cpu,allocation,after-workload}.pgcap`.
Local gate logs use `/private/tmp/loom-profile-20261018-` followed by
`check-codemode-final.log`, `check-provider-final.log`, `lint.log`, and
`doc-check-final.log`. Capture contents and session identifiers are not committed.

## Remaining measurement

The local fixes are ready for publication and deployment review. A significant
daemon-wide CPU/RSS improvement is still an open acceptance criterion: deploy
only after operator authorization, then capture matched busy workloads with
the same requests, concurrency, runtime, and observation cuts. Record CPU,
cumulative allocation, process/binary memory, and RSS separately, including the
idle state after workers retire. The completion of the current run makes an
unmatched new idle capture unsuitable as proof of an optimization.
