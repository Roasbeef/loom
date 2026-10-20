# Active swarm CPU and memory, October 19, 2026

We profiled the running daemon with Pickglass, then measured two local repairs:
a wider JSON byte scan and narrower page callbacks. The installed daemon was
left running throughout. Offline measurements establish lower parser work and
a smaller observer component; installed CPU and RSS savings remain unmeasured.

The source baseline is `c444fca2511759619dd3eee324fe206c018eee02`.
The installed launcher's build commit is
`3cd33073961be8d9b9205decd0b51bd98bfb253f`, daemon PID 50242, OTP 29,
ERTS 17.0.5. The measured production files had no intervening changes between
that installed commit and the source baseline. The capture's build fields are
unknown; the commit came from the launcher's embedded metadata.

## Live observations

Pickglass declared five session owners and ten strand owners. Two saved
censuses reported 668 and 673 processes. Counts include transient observer
processes and are not an agent-concurrency census. The following figures are
natural cuts during active work, before either local repair was installed.

| Counter | First cut | Second cut |
| --- | ---: | ---: |
| BEAM allocated total | 443.6 MiB | 412.1 MiB |
| Process memory | 327.4 MiB | 289.8 MiB |
| Binary memory | 64.9 MiB | 70.9 MiB |
| ETS | 2.1 MiB | 2.1 MiB |

A separate readable census put individual gateways at 2.7 to 7.2 MiB and a
page socket at 7.8 MiB. These are allocated capacities, not reachable-term
sizes. Many large processes remain unattributed. Six OS observations over
10.13 seconds recorded RSS between 544.2 and 591.6 MiB and instantaneous CPU
between 29.0% and 95.1% of one core. Accumulated process CPU advanced 7.99
seconds during that interval. A separate three-second native sample recorded
a 501.9 MiB physical footprint, with a 570.5 MiB historical peak.

The 15-second CPU probe pinned the sixteen busiest listed processes. It
counted 417 running/runnable samples out of 14,423 observations, at 62 Hz per
process. `esqlite3:fetchall1/2` had 49.8% flat samples and `esqlite3:q/3`
14.8%; JSON parsing and UTF-8 validation were the next substantial group.
Widths describe safe-point samples, not CPU-time shares. Long NIF work is
under-sampled, and stack depth is limited to eight.

A selected storage-process call trace recorded 19,112 calls over five seconds.
Its traced exclusive total was 121.16 ms: SQLite step and statement finalization
accounted for 38.4% and 21.1%, and `storage@sqlite:json_of_blob/2` for 20.2%.
Those figures include descheduling inside a traced function and are neither
daemon CPU totals nor evidence that 65% of CPU can be removed by changing SQL.
The native sample also found SQLite preparation, GC and ordinary VM execution.

An eight-process allocation probe observed 114,840,768 cumulative heap bytes
over 6.92 seconds (five seconds requested). JSON string parsing, whitespace
and object parsing led. All 414 called functions had allocation readings;
the displayed table retained only the largest 200. A separate selected-process
probe observed 7,078,328 heap bytes over 5.18 seconds. These probes had different
targets and workloads and are not a before/after pair. None of these totals
measures retained memory, refcounted binary payloads, native allocation or RSS.

## JSON scanner

`core/json.clean_run` now checks eight ordinary bytes before recurring. The
original four-byte and single-byte paths remain for short runs, delimiters and
tails. Every byte receives the original quote, backslash and C0-control check.
UTF-8 validation, cursor updates, decoded values and corruption reports are
unchanged. An eight-byte-only experiment increased transcript reductions; we
retained the four-byte path rather than accepting that regression.

We ran the existing `scripts/json_decode_perf.sh` workload through separately
saved baseline and candidate BEAM files, alternating three times in fresh
single-scheduler VMs. The compiler was Gleam 1.19.0, with the same OTP and
eight-byte word size. Each input verifies its result, warms five calls and
measures fifty calls. Timing and reductions trace nothing; a separate pass
traces only `parse/1` for cumulative allocation. No repository build or gate
ran during the final paired measurements. The host's other work was uncontrolled.

Medians per decode:

| Fixture | Reductions before | Reductions after | Decrease | Time before | Time after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Plain text | 142,552 | 128,302 | 10.0% | 904 µs | 547 µs |
| Escaped text | 207,642 | 199,668 | 3.8% | 2,448 µs | 1,707 µs |
| Dense adjacent escapes | 228,871 | 228,833 | 0.02% | 4,349 µs | 3,282 µs |
| Dense escapes, doubled | 454,504 | 453,729 | 0.17% | 8,242 µs | 7,295 µs |
| 2,048 short strings | 64,396 | 64,392 | 0.01% | 594 µs | 544 µs |
| 128 transcript objects | 1,015,022 | 987,327 | 2.7% | 16,424 µs | 14,725 µs |

Reduction counts support the bounded work reduction on plain, escaped and
transcript inputs. Near-zero differences on dense and short inputs are noise,
not useful savings. Timing varied substantially on this busy host, so the
median timing differences do not establish production speedups. Root-only
heap allocation was unchanged for all six fixtures.

The 882-input equivalence run compared complete decoded results and corruption
reports, including raw-byte mutations and truncated documents. Baseline and
candidate both reported zero exceptions and digest
`27b8e2a1f3e4c1f1fcd85885f0695a3cb70ca0375dfb53766f711de3a4b1995d`.
Existing boundary tests cover escape and control bytes at offsets 0 through 15,
with multibyte text around them. The ownership probe still reports a 96-byte
selected string backed by its 1,048,679-byte input. The scanner does not repair
that pre-existing binary-retention behavior.

## Page callback ownership

`client/daemon/ui_socket.admit` previously retained the full resolved attachment
through `Transport.sessions` and, on an owner page, `Transport.logins`. The
component stores this transport; asynchronous reads can copy its callback again.
The callbacks now retain the registry, original credential digest and principal
identity they use. Each session-list read still calls `manager.authorized_page`;
each sign-in read still checks the page and calls `manager.signins` with the
original credential and current time. Role gating and task ownership are unchanged.

The authenticated page regression measures the linked Lustre component's
model, which owns its transport callbacks, as well as socket capacity and gateway
attachment growth. Test-only support identifies exactly one linked component
through Lustre 5.7.1's runtime record, with bounded lookups. No production
inspection API was added. The fixture grows only an unused `run_start` hook
from zero to 8,192 messages and verifies that the hook still returns its payload.

The original experiment measured the complete returned Lustre runtime state.
Three fresh VMs per version produced the same figures at that observation cut:

| Fixture metric | Original, empty hook | Original, large hook | Repaired, empty hook | Repaired, large hook |
| --- | ---: | ---: | ---: | ---: |
| Component flattened state, words | 19,006 | 191,308 | 9,280 | 9,550 |
| Collected socket capacity, bytes | 6,216 | 6,104 | 6,216 | 6,104 |
| Gateway attachment growth, words | 388 | 424 | 388 | 424 |

With the large hook, component flattened state falls 95.0%, from about 1.46 MiB
to 74.6 KiB at eight bytes per word. Payload-dependent growth falls from
172,302 words to 270 words, below the regression's 4,096-word allowance. Every
original run fails that bound and every repaired run passes at that cut. Relay admission
and close cleanup still run through the real authenticated socket.

A later concurrent client run exposed why the whole runtime state is unsuitable
for the regression bound: it varied from 9,301 to 21,265 words while startup
messages could change the VDOM and render cache independently of the unused
hook. The test now projects the pinned runtime's `model` field, containing
`component.Model.view.transport`, and retains the same 4,096-word allowance.
Five fresh full socket-module runs pass, with model sizes of 1,313 words for
the empty hook and 1,313 or 1,316 for the enlarged hook. The concurrent full
client shard observed 1,313 to 4,520 words, also within the unchanged growth
allowance. Restoring only the
original whole-attachment capture in `Transport.sessions` fails all three
isolated controls: 4,583 grows to 61,930 words, above the 8,679-word bound.
The historical whole-state figures above remain observations, not invariants
across render phases. The model measurement excludes the runtime's selectors,
VDOM and render cache; it does not establish their retained size.

Flattened state estimates a copy with sharing removed; it is not the component's
whole live heap or a daemon RSS measurement. The fixture observes an observer
page, so the sign-in callback narrowing is supported by source inspection rather
than this retained-state regression. Owner-page capabilities in `upgrade` still
capture attachment fields and require their own measured repair. A result from
`sys:get_state` also excludes the surrounding actor loop's other roots.

## Validation and remaining work

The complete core gate passes 166 tests. The socket, page-capability and relay
modules pass 12, 63 and 18 tests respectively, for 259 tests across those gates.
Formatting and `git diff --check` pass. Targeted core/client lint reports zero
errors and 766 warnings; documentation checks report zero errors and 211
warnings. These warning totals include existing repository findings.

Independent adversarial review found no blocking correctness or simplification
findings; it checked the eight-byte guards, fresh authorization, lookup failure
behavior and the original/candidate regression logs. Source commits are
`35a0957cb` (CPU) and `a0c42df95` (page ownership). The full client suite, full
repository gate, hosted CI, strict Linux signoff and an installed matched-workload
comparison have not run for these changes.

We did not force GC, restart, hotpatch or inspect application state on the live
daemon. The full-GC socket observation and component state read belong only to
the isolated fixture. Profiling attached diagnostic code through Pickglass's
bounded probe path and detached it afterward.

The next useful measurements are a matched installed workload after an
operator-approved update, allocation attribution of the remaining JSON callers,
and an owner-page fixture varying the same hook. SQL preparation reuse needs a
bounded connection/statement ownership argument before changing the binding;
the sample widths alone do not justify it. GC or allocator tuning is not
supported by the evidence gathered here.

The [machine-readable evidence](swarm-resources-2026-10-19.json) contains all
36 final JSON observations, timing ranges, source hashes, twelve page-memory
observations, OS cuts and census totals. Raw captures and logs remain local
under `/private/tmp/loom-swarm-20261019-*`; Pickglass opens the `.pgcap` files.
The fixed JSON workload is reproducible through `scripts/json_decode_perf.sh`,
and the page regression through:

```sh
LOOM_TEST_TIMEOUT_SECONDS=120 bash scripts/test.sh client --match admitted_page_socket_releases_its_startup_runtime
```
