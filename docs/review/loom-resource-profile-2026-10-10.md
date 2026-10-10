# Loom CPU and memory profile, October 10, 2026

The first change removes repeated codepoint-list construction from clean
terminal-safe text. A live browser process allocated about 258 MB in text
sanitization over 15 seconds; the active terminal client allocated 130 MB in
another 15-second window. The same pure `session_view/text_hygiene` function
serves both hosts. Matched disposable measurements show a substantial reduction
in its allocation and CPU work, including a smaller improvement through the
real browser view and Lustre diff path. The installed processes still run the
old code. Permanent resident-memory savings have not been established.

## Scope and builds

Source base: `c66bd27264cd8b1350ed8309be2388d22fa0d195`; candidate code: `0caf6b4b72fa445577da7d2f6992609bea5df5eb`
on `codex/perf-text-hygiene`. The first production change is confined to
`packages/session_view/src/session_view/text_hygiene.gleam`. The installed
daemon PID 90963 and active terminal PID 97352 use release `91dbdef947ca9afa0bffeb77f82d0f6df92efb53`.
Tests and benchmarks use Gleam 1.19.0 and OTP 29 / ERTS 17.0.5, 8-byte words. The disposable
benchmarks use one scheduler and one of each dirty scheduler. No installed
code was hotpatched, installed, or restarted. Diagnostic modules were loaded
only for bounded observation and then unloaded.

Pickglass captures and bounded shape/GC results are under
`/private/tmp/loom-profile-20261010/`. They contain sizes, identities, function
names, and counters; the probes do not print transcript or secret values.
The earlier census is in `/private/tmp/loom-memory-profile-20261009/REPORT.md`.
These directories are local investigation artifacts, not committed fixtures.

## Live observations

| Probe | Result | Interpretation |
| --- | --- | --- |
| Browser `<0.245503.0>`, 15.1 s allocation trace | 326.2 MB over sanitizer + selected Lustre functions; about 258.1 MB sanitizer | Cumulative traced process-heap allocation, not retention or RSS. |
| Active terminal, busiest 8 processes, 15.0 s | 130.1 MB in sanitizer | Confirms the same allocation path on the terminal host. |
| Terminal follow-up including `event_fold`, 15.0 s | 107.1 MB sanitizer; no `event_fold` calls | Stream-fragment copying was inactive in this window. |
| Daemon sampled CPU, top 16, 15 s | 34 running/runnable samples of 15,008; the rest waiting | This selected-process sample is mostly idle; it does not establish whole-node CPU percentages. |
| Selected full GCs, adjacent Pickglass captures | Total BEAM 397.2 → 339.0 MiB; processes 298.5 → 249.1 MiB; binaries 51.7 → 42.9 MiB; RSS 441.3 → 429.0 MiB | Active workload changed concurrently; these node totals are not a clean causal estimate. |
| Writer `<0.193.0>`, direct full GC | 19,130,592 → 13,768 bytes process memory | Most pre-GC memory was reclaimable heap capacity; bounded state shape was only 5,080 flat bytes. |
| Writer `<0.17998.0>`, direct full GC | 13,090,456 → 13,768 bytes | Same distinction between heap capacity and small state. |
| Web socket `<0.245502.0>`, direct full GC | 12,116,904 → 602,056 bytes; quickly regrew | High transient allocation, not a large `sys:get_state` root; loop roots are outside that returned state. |
| Later daemon snapshot | 356.3 MiB BEAM total; 40.3 MiB binaries | The resident workload remains variable after the GC probes. |
| Active terminal snapshot | 36.4 MiB BEAM total; OS RSS about 83 MiB | RSS and BEAM-accounted bytes measure different things. |

The temporary state probe bounded each worker to 8,000,000 heap words and an
8-second deadline, with a 2-second `sys:get_state` timeout. It walked at most
nine levels, forty tuple slots and the first thirty-two map entries. Its
largest-child paths are bounded samples, not exhaustive retention proofs.
An independently exited process was excluded from the GC comparison.

Real retained roots remain: the jobs actor held 2,041 job records (about
3.43 MB flat), the browser component held model/cache/VDOM structures (about
8.92 MB flat total), and a static supervisor returned about 16.25 MB flat.
The supervisor's process memory was about 7.0 MB; shared terms make flat size
overcount same-process storage, and `sys:get_state` itself copies terms.
These sizes do not justify deleting job history or removing supervision data.
The two small writers hold lease-renewal timers. `runtime/writer` does not
configure hibernation, and its normal renewal interval is shorter than the
shared 30-second residency threshold. Merely adding the shared threshold
would not make a leased writer sleep. A matched writer-residency experiment
should preserve periodic renewal and measure both reclamation and wake cost,
rather than changing the lease timer based on these snapshots.

The gateway's approximately 1.13 MB flat state includes runtime/effect hooks.
Its current source already has the tool-holder optimization, so the earlier
full-registry retention diagnosis cannot simply be repeated here.

## Candidate and correctness

`multiline` calls the existing `unchanged_prefix` scanner. If the prefix is
the complete string, the sanitizer has no rewrite to perform. It copies the
bytes using `string.concat([text, ""])` rather than building and reversing
UTF codepoint lists. Any CR, tab, escape introducer, control, or invisible
codepoint selects the unchanged original sanitizer.

The empty second segment matters: on the measured OTP, `list_to_binary([slice])`
can reuse a large backing binary, whereas `list_to_binary([slice, <<>>])`
owns the output bytes. The ownership regression constructs a 200-byte slice
of a 1 MiB binary and checks that the result references only 200 bytes.
This uses no new production FFI, dependency, or public interface.

The differential benchmark loads the saved baseline BEAM under another module
name and compares outputs for every valid Unicode scalar inside surrounding
text: 1,112,064 cases, all equal. Gleam tests cover unsafe ranges and complete
and incomplete CSI/OSC sequences, tabs, and CRLF. An EUnit trace regression
asserts clean text never enters the list-based sanitizer and includes dirty
text as a positive trace control.

## Matched measurements

The [sanitizer benchmark](loom-resource-profile-2026-10-10/text_bench.escript)
uses five repetitions of 2,000 calls after warm-up; its allocation pass uses
200 calls separately. [Raw output](loom-resource-profile-2026-10-10/text-benchmark.txt)
records the counters and runtime version. Traced heap bytes exclude external
refcounted binary payload allocations and are not total memory consumption.

| Input | Median baseline → candidate time | Baseline → candidate reductions | Traced bytes, 200 calls |
| --- | --- | --- | --- |
| Clean ASCII, 1,110 bytes | 78.913 → 6.629 ms | 27.62 M → 2.25 M | 14,373,064 → 24,000 |
| Clean mixed Unicode, 810 bytes | 43.883 → 10.745 ms | 12.00 M → 1.90 M | 6,308,824 → 3,931,200 |
| Escape at tail, 1,112 bytes | 78.993 → 83.430 ms | 27.56 M → 29.72 M | 14,350,400 → 14,371,200 |
| Escape at front, 1,105 bytes | 78.288 → 75.137 ms | 27.43 M → 27.43 M | 14,281,600 → 14,305,600 |

The clean ASCII fast path saves 91.9% reductions and 99.8% traced heap bytes;
Unicode saves 84.2% reductions and 37.7% traced heap bytes. Dirty text still
pays the old sanitizer cost, plus the scan before its first unsafe character.
The dirty-tail fixture uses 7.8% more reductions. The timings above are local
microbenchmarks and should not be projected onto whole-daemon CPU use.

The [browser benchmark](loom-resource-profile-2026-10-10/page_bench.escript)
runs `page_fixture.ready` through the actual `operator_page.view` and Lustre
cache/diff/JSON-patch path. Both versions have the same page, initial view
SHA-256, and empty patches. Five repetitions of 1,000 unchanged renders give:

| Metric | Baseline | Candidate |
| --- | --- | --- |
| Median time | 29.860 ms | 25.732 ms |
| Median reductions | 4,329,046 | 3,857,502 |
| Sanitizer traced bytes / 100 renders | 410,400 | 87,200 |
| View-wrapper traced bytes / 100 renders | 3,208,800 | 3,208,968 |
| Lustre diff traced bytes / 100 renders | 1,515,200 | 1,515,200 |

This fixture saves 13.8% elapsed time and 10.9% reductions end to end, and
78.8% sanitizer traced allocation. It is a small deterministic operator page,
not a replay of the user's active session. Raw [baseline](loom-resource-profile-2026-10-10/page-baseline.txt)
and [candidate](loom-resource-profile-2026-10-10/page-candidate.txt) outputs
include the identical view hashes.

Reproduction, after building the corresponding packages and saving the
base's `session_view@text_hygiene.beam` before building the candidate:

```sh
escript docs/review/loom-resource-profile-2026-10-10/text_bench.escript \
  packages/session_view/build/dev/erlang /path/to/baseline.beam
escript docs/review/loom-resource-profile-2026-10-10/page_bench.escript \
  packages/web_view/build/dev/erlang baseline /path/to/baseline.beam
escript docs/review/loom-resource-profile-2026-10-10/page_bench.escript \
  packages/web_view/build/dev/erlang candidate \
  packages/session_view/build/dev/erlang/session_view/ebin/session_view@text_hygiene.beam
```

## Verification and next experiment

Six focused sanitizer tests passed. A negative control loaded the old BEAM
and confirmed that it fails the new fast-path trace regression. JavaScript
compilation succeeded (existing core integer/bit-width warnings remain), and
an additional JavaScript old-versus-new scalar differential passed all
1,112,064 cases. Three direct JavaScript sanitizer tests passed. The existing
prefix split-law test fails on that target because its `bit_array.to_string`
test helper strips a leading BOM through TextDecoder: for BOM + LF both
sanitizers produce replacement-character + LF, but the helper drops the BOM.
No test was removed or changed to hide this unrelated pre-existing limitation.
The affected gate's static lane passed;
the first preparation failed fetching a Hex package under network restrictions.
The network-enabled retry finished RED in 585 seconds (make exit 2; client
lane exit 1). Session-view, browser and conformance package gates
passed (442, 942 and 98 tests respectively). The combined client/terminal lane
stopped at the client failure; a separate `scripts/check.sh tui` run passed
with exit 0 and 1,281 tests. The skip census found no undeclared skip. The client suite had
3,222 passes and one failure:
`client/workspace_test.the_blob_root_is_the_one_protected_entry_native_reads_open_test`,
line 900, expected `Refused`, got `Readable` from `jail_verdict` for `.blobs/b`.
Both focused candidate and saved unchanged-baseline sanitizer runs reproduce
that exact failure (each exits 1). No other production source changed in this
patch. The aggregate gate remains red; this result is not release signoff.
The failure concerns the modeled jail boundary and needs its own investigation;
this probe does not establish an actual jail escape. User scope confirmation
was requested before adding that investigation.

The required independent advisor-review pass found no actionable defect.
Its named Opus/Fable tiers were unavailable; the available inherited model
performed the independent report-only pass. Its nearby `event_fold.owned`
copying candidate was not active in the subsequent live probe and is deferred.

Next, disposition the existing affected-gate failure and measure a reviewed installed candidate with
the same session count, browser attachments, model catalogue, input sequence,
and active/idle/released observation cuts. That needs an intentional release
update with its session-lifecycle implications. Do not claim the current
patch permanently shrinks the installed daemon, or replace an allocation fix
with periodic full GC based on this variable workload.


## Follow-up: writer residency

Writer source and regressions: `6c70583079c39b86c9307cadf04d34726f6c5793`.

The next probe followed the two writers whose heaps collapsed under targeted
GC. The installed writers did not consistently regrow those large heaps in
later observations, so 32 MB is not a sustained daemon saving. Nevertheless,
the reachable cause is clear: an idle writer has no hibernation policy, and a
lease heartbeat normally arrives every 20 seconds. The common 30-second
receive timeout would never fire between those heartbeats.

The candidate uses existing Weft hibernation with the common threshold for
unleased writers, and the smaller of that threshold and half the renewal
interval for leased writers (at least one millisecond). The lease timer and
its cadence stay unchanged. A normal request or renewal wakes the same actor;
commit ordering, subscriptions and custody remain in the actor's state. No
new process machinery, production FFI, dependency or public interface is added.

The [leased benchmark](loom-resource-profile-2026-10-10/writer_matched.escript)
loads saved baseline and candidate writer modules into one disposable VM in
alternating order. Its post-commit callback promotes a temporary 500,000-item
list through two minor collections before dropping it. This deliberately
creates old-generation garbage, rather than reproducing the installed session.
It then issues 1,000 empty commits and observes a quiet writer without waking
it. Three runs per version produced the following [raw results](loom-resource-profile-2026-10-10/writer-matched.txt):

| Metric | Baseline | Candidate |
| --- | --- | --- |
| Idle process memory | 13,089,880 to 16,365,320 bytes | 4,256 bytes |
| Idle current function | receive/select | `erlang:hibernate/3` |
| Renewal times, 1,500 ms period | 1,501 / 3,002 ms | 1,501 / 3,002 to 3,003 ms |
| First request after quiet | 16 to 39 microseconds; 100 reductions | 22 to 39 microseconds; 168 reductions |
| 1,000 active commits | 2.994 to 4.886 ms; 106,012 to 106,244 reductions | 3.241 to 4.047 ms; 104,009 to 104,015 reductions |

The fixture demonstrates over 99.9% reclamation of an idle writer's inflated
heap. It does not establish whole-daemon memory savings. Hibernation has a
wake cost, including 68 additional reductions in this fixture. Millisecond
active timings are noisy, and these three repetitions do not establish an
active CPU improvement or a latency guarantee.

The [unleased benchmark](loom-resource-profile-2026-10-10/writer_unleased.escript)
uses the same temporary allocation and 1,000-commit fixture with a memory
session and a 31-second quiet wait. Its [raw results](loom-resource-profile-2026-10-10/writer-unleased.txt)
show baseline 16,365,320 bytes versus candidate 4,024 bytes, no renewals, and a
normal request waking the candidate in 31 microseconds versus 20 at baseline.
This separately exercises the default 30-second branch.

Reproduction requires a test build of runtime and a saved pre-change writer
BEAM. Each script accepts these three arguments:

```sh
escript docs/review/loom-resource-profile-2026-10-10/writer_matched.escript \
  packages/runtime/build/dev/erlang /path/to/baseline-writer.beam \
  packages/runtime/build/dev/erlang/runtime/ebin/runtime@writer.beam
```

Substitute `writer_unleased.escript` to run the longer unleased probe. The
leased script exports test fixture helpers only inside its disposable VM;
it does not change production exports or attach to the installed daemon.

All four writer renewal tests passed. The new regression observes actual
hibernation without system messages, wakes the writer with a normal request,
checks repeated renewal and sleep, and then verifies abnormal retirement on
lease loss. Loading the saved unchanged writer makes this regression fail
specifically on the missing hibernation assertion. The independent review
found no actionable timer or custody defect. Runtime's full local package
gate passed with 187 tests and conformance passed with 98. Corrected whole-tree
static checks passed: a moved code-tour line reference caused the initial
static failure and was repaired before the separate successful rerun.

The affected gate finished RED in 565 seconds (make exit 2). The client lane
exited 1 after 470.69 seconds: 3,221 passed, two failed, zero skipped. One is
the previously baseline-reproduced blob refusal failure. The other is the real
TUI end-to-end fixture: it exited with an undefined `tui/image_drain.drain`
while the investigation concurrently rebuilt the TUI shipment through
`make dist`. That overlap invalidates this run as evidence of a TUI regression;
an isolated rerun passed all five module tests, exit 0 in 18.10 seconds. The aggregate itself remains red.
The skip census found no undeclared skip. The static lane's original failure
is retained in that aggregate; the corrected static rerun separately exited 0.

The candidate distribution build passed server and client smoke, then refused
packaging because these new evidence files were uncommitted. No installed
release was changed. Daemon changes additionally require Linux signoff on a published
head; that signoff has not run. The earlier `make dist` smoke passed at
`6e311b94c866d10dd2e049279b845ff520037340`, which contains the sanitizer change
only. Those artifacts do not include this writer change. Installed clients
and daemon remain unchanged, and the resource optimization goal stays active.


After committing the evidence, `make -j1 dist` passed with exit 0 at
`6a7fe8734`. Server and client release smoke passed. The local
`dist/manifest-macos-arm64.json` identifies that build, containing both
optimizations. No installed process was replaced or restarted.


## Continued probes and local gate closure

The fixture repair at `36e115c7b` resolves the local gate failure without
changing production policy or removing an assertion. Production moved blob
storage under daemon state; `base_policy_for` deliberately no longer masks
workspace `.blobs`, and code mode's default store is `.codemode/blobs`.
The test still created `.blobs`, assumed its implicit protection, and read it
through a seam configured with the different default. The repaired fixture
explicitly protects its chosen store and passes that same root through
`codemode.into_blobs`. Both scopes still prove native/search reads, jail
refusal, other protected-path refusal and direct/symlink write refusal.
The original module had 40 passes and one failure; the repaired module has
41 passes. Independent review found the final fixture repair sound.

`make check-affected BASE=c66bd27264cd8b1350ed8309be2388d22fa0d195`
then passed, exit 0 in 563 seconds, without a concurrent shipment build.
Static checks, preparation and every selected package lane passed:
session-view 442, browser 942, runtime 187, conformance 98, client 3,223,
and terminal 1,281 tests. The skip census found no undeclared skip.
This supersedes the earlier local red results; Linux signoff remains open.

The [normal lease probe](loom-resource-profile-2026-10-10/writer-normal-lease.escript)
uses the same synthetic promoted-garbage fixture at the production 20-second
renewal interval, with an 11-second quiet observation and another 11 seconds
after a normal request. [Raw output](loom-resource-profile-2026-10-10/writer-normal-lease.txt)
shows baseline idle memory 16,365,320 bytes and candidate 4,256 bytes.
Both renew at 20,001 ms. The first wake takes 30 versus 31 microseconds and
100 versus 168 reductions. This is one normal-period repetition in a
disposable VM, not an installed workload comparison.

A fresh Pickglass census found 334.5 MiB total BEAM memory, 245.9 MiB process
memory, 41.7 MiB binaries and 533 processes. Bounded shape probes found a
strand cache of about 8.83 MB flat, of which 8.27 MB was its scan/projection,
and another of 2.90 MB flat with 2.33 MB scan/projection. These caches avoid
repeated durable scans; flat sizes count shared structure repeatedly and do
not establish equivalent unique resident storage. An active job waiter was
inside `jobs.await_job` and had no system state response. No cache, job or
history was trimmed, and no new GC was forced during this follow-up.

The busiest-eight allocation selection missed most browser rendering in this
window. Profiling browser `<0.245503.0>` directly found 19 renders in 15
seconds. The view wrapper allocated 29.09 MB excluding the explicitly traced
children, update 3.78 MB, and the selected Lustre diff functions about 8.02 MB.
A subsequent helper trace found 9.90 MB in `fold_row.step_body`, 4.36 MB in
`lane.item_element` and 2.38 MB in `transcript_image.ref`. These are cumulative
function allocations over different windows, not additive resident totals.
The current workload had much less sanitizer work than the earlier capture;
this is workload variation, since the installed code is unchanged.

### Browser image-key prototype

The lane currently calls `transcript_image.ref` before discovering that a row
has no drawable images. A [disposable prototype](loom-resource-profile-2026-10-10/lane_picture_prototype.escript)
moves that computation behind the existing session/drawn-image check. It
rewrites generated abstract forms only in a disposable VM. It has not changed
production source or the built distribution.

The [benchmark](loom-resource-profile-2026-10-10/lane_picture_bench.escript)
applies `lane_fixture.heavy(30, 1000)` to a real page and runs operator view,
Lustre cache and diff. Five repetitions of 1,000 unchanged renders give median
baseline 284.865 ms and 29,793,757 reductions versus prototype 258.615 ms
and 28,157,325 reductions: 9.2% time and 5.5% work reduction. Timings were
collected while package checks ran and should be treated accordingly.
The image-key function's traced allocation for 100 renders fell from
1,920,000 bytes to zero. Other per-module allocations varied with GC.

Both versions produce HTML SHA-256
`190E15FE3D48EB23F36D05338E13E9FDD6C3AEE547FF55D456430DD6F8E13B8A`
and empty unchanged-render patches. The raw Element-term hashes differ
because recompiling the lane changes closure identities; they are not a
rendered-output equivalence check. All eleven existing image-view tests also
pass with the prototype loaded, including image positions, slash-containing
step keys and observer/operator parity. [Baseline](loom-resource-profile-2026-10-10/lane-picture-baseline.txt)
and [prototype](loom-resource-profile-2026-10-10/lane-picture-prototype.txt)
outputs preserve the raw counters. Reproduction uses:

```sh
escript docs/review/loom-resource-profile-2026-10-10/lane_picture_prototype.escript \
  packages/web_view/build/dev/erlang/web_view/ebin/web_view@view@lane.beam \
  /path/to/prototype.beam
escript docs/review/loom-resource-profile-2026-10-10/lane_picture_bench.escript \
  packages/web_view/build/dev/erlang prototype /path/to/prototype.beam
```

### Separate blob-read limitation

The fixture repair does not prove that native reads reach the daemon's actual
blob store. Independent review noted that `fs.exempting_blob_root` removes
only exact blob-root masks, while daemon state protects ancestors such as
`workspaces` or `domains`. A [local diagnostic](loom-resource-profile-2026-10-10/blob_ancestor_probe.escript)
creates a fixture under `state/workspaces/domain/blobs`, applies an ancestor
mask and the production exemption/read resolver, and [confirms](loom-resource-profile-2026-10-10/blob-ancestor-probe.txt)
that the ancestor mask survives and native read returns `ProtectedPath`.
It performs no live daemon request and prints no contents. This is a separate
pre-existing read-path limitation, not a jail escape and not repaired by this
performance work. Its resolution needs its own boundary review.

The two production performance changes remain locally validated and packaged
at the previously recorded distribution SHA. The browser image-key change is
still a prototype. Linux exact-head signoff requires publishing the branch;
installed CPU and RSS comparison then requires an intentional release update.
Neither action has occurred, and the goal remains active.
