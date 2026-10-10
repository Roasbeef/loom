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
on `codex/perf-text-hygiene`. Production changes are confined to
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
