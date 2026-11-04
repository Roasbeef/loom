# Live Loom CPU and memory profile, October 30, 2026

The active daemon now runs `ccb7957596f2c39c3b080e14ff392d9e7db4401b`,
including the evolution callback and catalogue source-read repairs. Its quiet
baseline is substantially smaller than the October 29 daemon, but the current
run also includes a busier period. Different builds, process ages and workloads
prevent attributing the difference to either repair.

## Identity and collection

Production PID 52485 started at 17:50:27 America/Los_Angeles. The physical
release is `/Users/roasbeef/.local/lib/loom/server.sdukr8NH`; both its launcher
and live `host/build_identity.current` identify Loom 0.3.2 at `ccb795759`.
The source checkout is clean at that same commit before this report. The VM
uses OTP 29, ERTS 17.0.5, eight-byte words and sixteen normal schedulers.

The observer is the existing local Pickglass build at
`9a55ad95aaa79ffdd5ca8f526a05ef156f37582a`, using the enrolled TLS inspector.
Pickglass's capture build fields are unknown; the independent live identity
supplies the application provenance. Captures cover existing activity only.
No model calls or synthetic load were added.

This round made no installation, restart, forced collection, hotpatch,
application-state or closure walk, or process cleanup. Pickglass temporarily
loads diagnostic modules, then records detachment and unloading after each
profile. Ordinary counters were collected separately. Microstate accounting
was enabled for ten seconds and restored to its prior disabled setting.
No message contents, process dictionaries, cookies or credentials were exported.

## OS memory and CPU

The initial OS-only window ran from 19:01:40 to 19:02:11, after the first
Pickglass census detached. It lasted 31.206 seconds. The daemon accumulated
2.04 CPU seconds, or 6.54% of one core, with RSS between 344.69 and 360.38 MiB.
The subsequent macOS footprint was 335 MB, with a recorded peak of 465 MB.
Footprint units are retained as printed rather than relabeled MiB.

At the last cut of that baseline, the daemon subtree totaled 735.42 MiB RSS:

| Owner | Count | Summed RSS |
| --- | ---: | ---: |
| Production daemon | 1 | 349.22 MiB |
| Jevelin MCP servers | 3 | 198.97 MiB |
| Code-mode satellite | 1 | 61.91 MiB |
| Gleam language server | 1 | 73.91 MiB |
| Helpers and remaining native children | 11 | 51.41 MiB |

Shared resident pages are counted in each process, so the subtree sum is not
unique physical RAM. The satellite's separately collected footprint was 55 MB.
No native Loom terminal client was running; the unrelated aegis test VM was
excluded. The satellite runs without a distribution endpoint, so it received
OS measurements rather than Pickglass attachment. Remote nodes were not profiled.

A later uninstrumented window, after the first two CPU profiles and allocation
traces detached, lasted 16.675 seconds. The daemon accumulated 10.59 CPU seconds
(63.51% of one core). RSS ranged from 413.11 to 441.48 MiB and ended at
435.52 MiB; the footprint was 422 MB. Its subtree then totaled 913.08 MiB RSS.
The intervening workload changed, so these windows establish activity variation,
not profiler overhead, a leak, or an optimization percentage.

The OS window aligned with the subsequent thirty-second active CPU profile
lasted 40.182 seconds and included profiler setup and teardown. It accumulated
31.99 daemon CPU seconds (79.61% of one core), with RSS from 412.50 to
458.77 MiB. Unlike the two OS-only windows, this window includes observer work.

## Sampled CPU paths

The first 45-second Pickglass profile selected sixteen processes by reductions
from the top-200 census. It recorded 45,008 samples, of which only 43 were
running or runnable. Of those, 19 ended in file metadata reads and nine in
file reads. Three stacks included configuration polling and five included
SQLite queries. This window is too sparse for a firm bottleneck ranking.

The sixty-second repeat recorded 60,000 samples, with 324 running or runnable.
SQLite query stacks appeared in 159 (49.1%), including 106 (32.7%) through
`storage/sqlite.do_get_register`. File-server stacks appeared in 75 (23.1%).
Snapshot reads, register enumeration and strand polling also appeared.
Rows and paths overlap; percentages must not be added.

The thirty-second active capture recorded 23,352 samples, with 684 running or
runnable and four selected processes exiting during observation. Its measured
active stacks included:

| Path | Samples | Share of 684 |
| --- | ---: | ---: |
| SQLite query | 306 | 44.7% |
| Register point read | 174 | 25.4% |
| Snapshot query callback | 82 | 12.0% |
| Operator page rendering | 38 | 5.6% |
| Lustre client-message encoding | 34 | 5.0% |
| Lustre VDOM diff | 33 | 4.8% |
| Proposal row rendering | 25 | 3.7% |

These rows overlap. The observed active-workload target is session register and
snapshot reads, with web rendering as a secondary path. Catalogue source reads
were not established as the dominant path in this round.

These profiles sample selected processes at reduction safe points, not all VM
CPU time. Long BIF/NIF calls can be undersampled, stack depth is limited to eight,
and sampled shares are not wall-clock CPU percentages. A five-second native
sample also observed waiting schedulers, filesystem calls and occasional SQLite
work; it supplies no independent quantitative attribution to Gleam callers.

## Function allocation

The fifteen-second top-eight trace observed 15.269 seconds and counted
10,308,512 heap bytes, or 9.83 MiB and about 0.64 MiB/s, in its selected functions.
It matched 2,222 functions; all 232 called functions had readings, with no reload
or invalidated counter. The capture lists 200 rows; the omitted 32 carry zero
allocated words, so listed bytes sum to the reported total.

| Module | Attributed heap bytes | Share |
| --- | ---: | ---: |
| `core/json` | 7,489,712 | 72.7% |
| `sqlight` | 1,358,840 | 13.2% |
| `storage/internal/snapshot_sqlite` | 745,016 | 7.2% |
| `storage/sqlite` | 690,368 | 6.7% |
| `client/config_watch` | 24,576 | 0.2% |

The selected processes executed 782 `sqlight.query` calls, 446
`sqlite.do_get_register` calls, five snapshot captures and sixteen configuration
observations. The top function was `core/json.parse_string_body`, with 1,875,512
attributed bytes. Catalogue and daemon-manager functions requested by this trace
were not called in the selected processes; absence here is a coverage limit.

A separate file-server trace counted 191 handled calls, including 136 metadata
reads and 54 whole-file reads, over 15.096 seconds. Its 26 called functions
allocated 42,112 heap bytes (41.13 KiB); every counter was read. The filesystem
work seen in the first CPU window does not establish a substantial heap cost.
This process's call counts do not identify all originating callers.

Allocation counts are cumulative heap words multiplied by the target's word
size. They exclude off-heap binaries, ETS, native/NIF memory and unselected
processes. Function totals exclude traced callees and include untraced callees.
They measure allocation, not retained state or RSS, and independent trace
windows cannot be added or treated as a matched performance comparison.

The active-workload trace requested fifteen seconds and observed 17.165 seconds.
It counted 373,587,768 heap bytes (356.28 MiB, about 20.76 MiB/s) across 631
called functions; every called function had a reading and no module reloaded.
The top-200 rows retain 372,978,632 bytes, with 609,136 bytes in 431 omitted rows.
Unlike the earlier trace, these omitted rows have nonzero allocation, so module
figures computed from the listed rows are lower bounds.

The listed JSON functions account for at least 245,241,952 bytes (233.88 MiB,
65.6% of the total). The selected processes made 5,574 `sqlight.query` calls,
2,064 register point reads, 22 snapshot captures, 865 `strand_runtime.read_decoded`
calls, 1,470 `gateway.push_to_subscribed` calls and 85 `manager.source_paths`
calls. Function-local allocation includes 12,381,968 bytes for `read_decoded`,
6,996,832 for `push_to_subscribed` and 11,614,664 for `source_paths`, including
their untraced callees. These totals do not establish their inclusive costs.

The register cache recorded 2,311 `read` calls and 104 `decode_blob` calls.
Most selected cache reads therefore avoided a JSON decode in this window;
a large JSON allocation total does not imply that this cache was ineffective.
The trace provides function totals rather than parent-child stacks, so it does
not assign the remaining JSON work among register misses, snapshot decoding,
protocol encoding and other callers. Its module scope also differs from the
earlier allocation trace. The higher rate is activity context, not a regression
percentage.

## VM memory owners

The initial Pickglass census reported 269.49 MiB total VM allocation,
173.29 MiB processes, 42.20 MiB binaries, 30.90 MiB code and 2.18 MiB ETS.
Its process count was 402. Ordinary OTP counters at a later cut reported
300.45 to 302.82 MiB total, 184.90 to 187.37 MiB processes, about 62 MiB
binaries, 30.57 MiB code and 2.08 MiB ETS. That census had 424 processes.
The counters are sequential observations rather than an atomic inventory.

The ordinary process census's largest owner allocated 7.86 MiB. The largest
forty owners were waiting with empty mailboxes. Across the whole census,
one process had one queued message and every other observed queue was empty.
The initial top-200 Pickglass grouping attributed 63.72 MiB to the generic
weft actor startup shape and 25.30 MiB to the state-machine shape. These
framework entrypoints do not identify the application closure retaining a value.
No reachable-state claim follows from their allocated heap capacity.

| Allocator | Carrier capacity | Scanned allocated blocks |
| --- | ---: | ---: |
| `eheap_alloc` | 224.73 MiB | 192.72 MiB |
| `binary_alloc` | 91.09 MiB | 61.93 MiB |
| `ll_alloc` | 37.50 MiB | 25.62 MiB |

Carrier capacity, allocated blocks, process capacity and physical residency
measure different properties. The gaps above do not establish a leak or prove
that allocator tuning would release resident pages. Raw microstate counters
are retained with the ordinary census; their thread-state durations, especially
`other`, are not substituted for measured OS CPU time.

The closing Pickglass census reported 348.28 MiB total, 236.60 MiB process
allocation, 57.49 MiB binaries, 30.93 MiB code and 2.20 MiB ETS, with 503
processes. Its largest listed process allocated 12.65 MiB. Natural activity
changed both process count and heap capacity during collection; none of these
cuts measured exact reachable payload or justified forced GC.

## Next experiments

The best supported follow-up is a fixed register/snapshot replay. The active
stacks reach `storage/sqlite.do_get_register` at
`packages/storage/src/storage/sqlite.gleam:3395`, while the allocation trace
places most counted heap work in `core/json`, including `parse_string_body`
at `packages/core/src/core/json.gleam:655`. Snapshot capture starts at
`packages/storage/src/storage/internal/snapshot_sqlite.gleam:35`.
These observations identify a path to measure, not the identity of every
JSON caller or proof that every register read reparses JSON.

The existing register cache already reuses exact persisted blobs and deliberately
keeps SQLite row selection fresh. The active trace shows much more reuse than
decoding. Reproduce that work with a fixed workload and trace
`storage/internal/register_cache.read` and `decode_blob` alongside the storage
and JSON functions to distinguish cache hits, misses, bypasses and other callers.

Include `runtime/strand_runtime.read_decoded` at
`packages/runtime/src/runtime/strand_runtime.gleam:3287` and
`client/gateway.push_to_subscribed` at
`packages/client/src/client/gateway.gleam:5074` to separate typed payload
decoding, copying and event serialization from the JSON parser itself. Measure
query count, reductions, allocation and returned values under identical inputs.
Preserve current sequence, corruption and authorization behavior; this round
does not justify a broader cache or parser replacement.

Configuration polling is a lower-priority experiment. Each configured session
starts a watcher at `packages/client/src/client/serve.gleam:5688`; its one-second
read/fingerprint loop is in `packages/client/src/client/config_watch.gleam:191`
and `:234`. The file-server trace does not prove every call came from these
watchers. A fixed multi-session fixture could establish how cost scales while
preserving detection of atomic replacements and same-path edits. The present
small heap count does not justify a shared watcher or new lifetime policy.

The October 29 report recorded roughly 1.08 GiB daemon RSS, 875 to 886 MiB
ordinary VM allocation and much larger generic actor heaps on `fcbc7d9b`.
Those historical measurements are useful context, not a matched control for
today's newer, younger daemon. No new production retention defect or installed
savings percentage is established by this round.

## Evidence and validation

Raw artifacts and the offline arithmetic validator are preserved in
`.notes/profiles/2026-10-30/` in this worktree. They include sanitized process
inventory, OS time series, footprint/native samples, ordinary OTP counters,
Pickglass censuses, speedscope CPU profiles, allocation captures and their logs.
The files were also collected under `/private/tmp/loom-profile-20261030/`.

The offline `analyze.py` validates all five gzip JSONL captures, including
header/footer counts and SHA-256 digests, and parses all three speedscope files.
It recomputes allocation totals where all allocated words are listed and records
the active trace's omitted allocation separately. `git diff --check` and
`make doc-check` are the documentation gates for this observation-only round.
Application test suites were not rerun because no production code changed.
Independent review and final gate outcomes are recorded below.

Independent report-only review found no actionable issues. It separately parsed
the five captures and three speedscope files, reproduced the OS/sample/allocation
arithmetic, checked the cache inference against source, and retained all
attribution limits. Final documentation checks pass with zero errors; the
228 doc-check warnings are advisory. No implementation changes were made.
