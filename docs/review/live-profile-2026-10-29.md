# Live Loom CPU and memory profile, October 29, 2026

The current local Loom process tree has three separate optimization targets:
large native children, repeated SQLite/catalogue work, and process heaps in a
running daemon that predates the evolution callback repair. The measurements
below rank experiments; they establish no new leak or installed savings.

## Running versions and scope

Measurements ran around 18:11 to 18:20 America/Los_Angeles on October 29, 2026,
during the user's existing activity. No synthetic model calls were added.

- Production daemon: PID 96649, Loom 0.3.2,
  `fcbc7d9b468f8381a5ada5579d5b23a690e4ea65`, booted October 28 at 17:01.
  Both the installed launcher and the live `host/build_identity.current`
  reply confirm that commit.
- Native client: PID 28061, Loom 0.3.2,
  `3cf6bdc09c281e39dd126d5b7daa6c9d7eb4308d`, booted October 22.
  Its physical launcher's identity was read; client identity was not queried
  through the live build API in this pass.
- Daemon and client: OTP 29, ERTS 17.0.5, eight-byte words. Pickglass reports
  sixteen normal and sixteen dirty CPU schedulers for the daemon, four and
  two for the client.
- Source navigation: initially clean detached checkout
  `678aefa489da9d4bd9fa5c633b7a072097a7821c`. The storage source paths cited
  below have no diff from the running daemon's commit. The evolution callback
  repair is present in the checkout and absent from the running daemon.
- Pickglass: existing local build
  `9a55ad95aaa79ffdd5ca8f526a05ef156f37582a`, attached through the previously
  enrolled TLS inspector for the daemon and the client's private loopback
  profiling endpoint. Pickglass's own capture build fields are `unknown`;
  the independently checked identities above supply the missing provenance.

This is a local-machine profile. Remote orchestrators were not measured.
Neither process was restarted or force-collected. No production code was
installed or hotpatched, application state or closure environments walked,
credentials printed, or old process terminated. Pickglass temporarily loads
its diagnostic agent and tracing machinery and reports detachment/unloading
at the end. OTP microstate accounting was enabled for ten seconds and its
previous disabled setting restored; the restoration is recorded in the log.

## OS inventory

These are per-process RSS cuts, with shared resident pages counted in each
process. The subtree sum is an operating budget, not unique physical RAM.
Physical footprint is the display from macOS `footprint`, with its own
accounting and a separate observation time. Its MB values are retained as
printed rather than relabeled MiB.

| Owner | Processes | RSS at recorded cut | Physical footprint |
| --- | ---: | ---: | ---: |
| Production `loomd` | 1 | 1082 to 1108 MiB over initial window | 1011 MB |
| Native client | 1 | 47 to 68 MiB over initial window | 76 MB |
| `gopls`, PID 94835 | 1 | 2087.27 MiB | 1029 MB |
| Jevelin MCP servers under daemon | 6 | 408.95 MiB combined | Not collected |
| Code-mode web-search satellites | 2 | 129.38 MiB combined | 54/55 MB and 56 MB |
| Old private test daemons, parent PID 1 | 18 | 1484.90 MiB combined | Not collected |

The active daemon/client roots and their descendants total 3889.13 MiB RSS
at the subtree cut. This includes `gopls`, MCP servers, four `loom-exec`
helpers, small shell/runtime children and a transient Go process. The eighteen
old fixture daemons are outside that subtree. Their private homes and state
paths identify six headless fixtures and twelve ACP fixtures from the older
`2bfc` checkout, consistent with the previously documented native-fixture
ownership bug. Reparenting and age alone do not authorize killing them.

`gopls` is a live descendant of `loom-exec` PID 67662, itself below the daemon's
`erl_child_setup`. Its native sample is predominantly waiting, and its recent
CPU was zero at the subtree cut. Its large RSS and smaller footprint do not
prove a reachable Go heap of either size. No existing debug listener was found,
so this pass did not obtain a Go heap profile. `gopls stats` was inspected only
through its help; running it would load a separate workspace and populate its
cache, so it was not used as a measurement of this server.

The two satellite VMs run with distribution disabled. They were measured by
OS counters and footprint, without changing their launch configuration to make
Pickglass attach. The native client yielded one running/runnable sample out
of 4000 in its ten-second Pickglass window. It supplies no useful CPU ranking.

## CPU attribution

The initial OS window lasted 33.442 seconds. The daemon accumulated 13.36 CPU
seconds, or 39.95% of one core; the client accumulated 0.43 seconds, or 1.29%.
Each satellite accumulated about 0.01 seconds. This window overlapped ordinary
OTP census collection, so observer work is included and was not subtracted.

A final OS-only window, after all profilers detached, lasted 15.095 seconds.
The daemon used 0.77 CPU seconds (5.10% of one core); the client, `gopls`
and satellites used less than the displayed 0.01-second resolution. Activity
changed between windows, so the difference from 39.95% is not a measurement
of profiler overhead or an optimization.

The separate thirty-second Pickglass window selected sixteen processes by
reductions from its top-200 census. It achieved 62 Hz per process, recording
24582 samples: 746 running/runnable and 23836 waiting. Three selected processes
exited during the window. These are sample shares among the selected active
stacks, not whole-daemon CPU percentages. Long BIF/NIF work can be undersampled,
and stacks are limited to eight frames.

| Path present in active samples | Samples | Share of 746 |
| --- | ---: | ---: |
| `sqlight.query` / `esqlite3.q` | 298 | 39.9% |
| `esqlite3.fetchall1`, flat | 231 | 31.0% |
| Catalogue query callback | 139 | 18.6% |
| `storage/sqlite.handle_open` | 93 | 12.5% |
| `storage/sqlite.do_get_register` | 71 | 9.5% |
| Read-only snapshot SQLite query callback | 50 | 6.7% |
| `web_view/operator_page.view` | 47 | 6.3% |
| Lustre VDOM diff | 39 | 5.2% |
| Proposal row rendering | 31 | 4.2% |

Rows overlap; they must not be summed. Catalogue work includes
`storage/domain.sources` and `client/daemon/manager.source_paths`. Native
sampling also observed SQLite preparation/schema work. That sample supports
query activity but does not isolate preparation as a measured fraction of CPU.

A later ten-second microstate window was mostly idle across the scheduler
pool. Normal schedulers spent 1.353% of their aggregate time active; within
that active time, emulator work was 64.5%, GC 5.2%, and `other` 28.4%. Dirty
CPU GC added a separate 0.233 seconds of thread time. This is a different
activity window and includes the lightweight observer. It does not establish
GC as the primary CPU cost or justify changing GC policy.

## Allocation attribution

Two independent, sequential Pickglass traces counted heap words in selected
functions. Function totals exclude traced callees but include untraced
callees. They exclude off-heap binaries, ETS, native/NIF allocation and work
in processes that were not selected. They are cumulative allocation, not
retained bytes. The two traces cover different windows and function scopes;
their totals must not be added or compared as an optimization result.

The top-eight trace observed 15.410 seconds and 188159272 allocated bytes
(179.44 MiB). Of those, `core/json` accounted for 149619112 bytes, or 79.5%.
`parse_string_body` allocated 29670736 bytes; `skip_whitespace` allocated
18445000. `storage/sqlite.do_get_register` ran 4080 times, about 265 calls/s,
and attributed 7350816 bytes excluding separately traced callees.
`scan_window_pages` ran 79 times, and `json_of_blob` ran 1135 times.

Although the first trace requested catalogue and web modules, its selected
processes executed only traced JSON and session-storage functions. Their
absence from this trace is a coverage limit. The earlier CPU window supplied
the reason to trace the catalogue owner explicitly.

The focused catalogue-owner trace, PID `<0.179.0>`, observed 10.823 seconds
and 64307224 allocated bytes (61.33 MiB):

| Function/work | Calls | Attributed bytes |
| --- | ---: | ---: |
| `sqlight.query` | 3176 | 345328 |
| `catalogue.get` / `find` / `display_record` | 930 each | Function-local totals only |
| `domain.sources` | 16 | 640 |
| `manager.source_paths` | 16 | 512 |
| Source validation callback in `domain.sources` | 336 | 8064 |
| Source lookup callback in `manager.source_paths` | 336 | 1274200 including untraced callees |
| Profile-name validation anonymous callback | 4754 | 26090736 |
| `catalogue.is_profile_name` | 601 | 4517240 excluding traced callback |

The small local counts for orchestration functions do not represent their
whole downstream cost. The 3176 queries are about 293/s across all work in
this owner, not all attributable to source enumeration. The 336 callbacks in
each of the two source stages establish repeated source lookups directly.
The profile-name callback's 26.09 MB includes its untraced string/list work;
it is an allocation target, not a comparable amount of retained memory.

All called functions in both successful allocation traces had readings, with
no invalidated modules. An initial broader module request was refused because
one requested module was not loaded; it supplied no profile result. The valid
capture uses only names observed in the live stack sample.

## Daemon memory owners

Ordinary OTP allocation increased from 875.18 to 885.85 MiB across an
11.444-second census window. Process allocation was 724.46→734.26 MiB,
binaries 96.44→97.30 MiB, code 30.74 MiB and ETS about 2.15 MiB.

The separate first Pickglass cut reported 914.27 MiB total and 762.23 MiB
process allocation at 18:13:11. The final cut at 18:18:28 reported 876.29 MiB
total and 720.58 MiB processes, while binaries were 100.96 MiB. Process count
moved from 920 to 854. These natural changes disprove a claim that every
short-window increase is monotonic growth; they are not a controlled savings
experiment.

The top-200 process census attributes 389.43 MiB to one `weft/actor` startup
shape and 162.92 MiB to one `weft/state_machine` startup shape. This is generic
actor machinery, not attribution to weft as the source of a bug. Eighteen
large processes alone total 315.06 MiB: four state machines near 21.41 MiB,
six actors near 18.98 MiB, two actors near 18.24 MiB, and six owners near
13.18 MiB. Those identities persist into the final census. Bounded metadata
finds the largest owners waiting, without a significant mailbox backlog;
no complete closure/state roots were inspected.

Allocator instrumentation at its later cut reported:

| Allocator | Carrier capacity | Scanned allocated blocks |
| --- | ---: | ---: |
| `eheap_alloc` | 801.83 MiB | 756.48 MiB |
| `binary_alloc` | 284.28 MiB | 97.18 MiB |
| `ll_alloc` | 37.00 MiB | 25.67 MiB |

Carrier capacity is neither RSS nor reachable payload. This identifies heap
allocation as the largest category and a substantial binary-carrier gap; it
does not prove that tuning allocators would release resident pages.

The repeated 18.98/13.18 MiB shapes resemble the evolution callback copies
already reproduced and repaired in #1138. The live build predates that repair.
Without a fresh state/closure attribution, resemblance is supporting evidence,
not proof that all eighteen owners are evolution processes or that all their
bytes can be eliminated. The earlier [callback proof](evolution-memory-2026-10-27.md)
contains the isolated ownership and negative controls.

## Ranked next experiments

1. **Reduce repeated catalogue work.** `storage/domain.sources` at
   `packages/storage/src/storage/domain.gleam:320` reads each source through
   `catalogue.get`; `client/daemon/manager.source_paths` at
   `packages/client/src/client/daemon/manager.gleam:6233` reads it again.
   Each `get` selects the registration and then two display layers
   (`packages/storage/src/storage/catalogue.gleam:507` and `:900`). Source
   membership/path resolution does not need the displayed name and subtitle.
   First reproduce with an offline catalogue and a fixed source count, then
   use the smallest internal query projection that preserves current domain
   membership, path validation, pagination, error behavior and serialization.
   Keep authorization fresh. Require fewer queries and allocated bytes per
   enumeration with identical returned sources, including invalid-member and
   missing-record failures. No new authorization cache is indicated.

2. **Remove repeated Unicode/list work from ASCII profile validation.**
   `packages/storage/src/storage/catalogue.gleam:3260` converts the name to
   graphemes, measures grapheme length, scans the alphabet, and constructs the
   digit grapheme list inside its per-character predicate. The grammar is
   bounded ASCII. Compare an equivalent byte walk on an isolated fixture,
   retaining rejection of Unicode, invalid first characters and overlength
   input. Measure the validator alone and the full catalogue read; its large
   allocated-byte total does not imply a large CPU or RSS reduction.

3. **Measure the existing callback fix in the installed workload.** The narrow
   operation projection is already in `client/serve.local_evolution_machine`
   and `open_evolution` (`packages/client/src/client/serve.gleam:7204`, `:7299`),
   and the runner clock projection in
   `packages/client/src/client/evolution/live.gleam:285`. A separately
   authorized update and matched session/workload census should precede any
   new production retention patch. Preserve existing runtime lifetimes and
   measure RSS, footprint and OTP counters independently.

4. **Profile native children before changing lifetime policy.** `gopls` is
   the largest individual RSS owner and the six MCP servers are a material
   fixed cost. The LSP manager intentionally keeps one server for the current
   session/project until eviction or session teardown
   (`packages/client/src/client/lsp/manager.gleam:30`, `:652`, `:992`). Quiet
   CPU is not evidence that its workspace is unused. Obtain a Go heap profile
   in an approved diagnostic launch and measure retained workspace/type data
   versus free runtime capacity. Trace MCP session ownership and teardown
   before proposing shared servers or idle eviction. Neither sharing nor new
   timers is justified by this census alone.

5. **Keep JSON decode and web rendering as measured secondary targets.**
   JSON dominates the traced heap allocation, while proposal rendering and
   Lustre diff appear in active samples. Use a fixed transcript/register
   replay to attribute repeated decodes to callers before modifying the total
   JSON parser (`packages/core/src/core/json.gleam:459`, `:655`). Trace the
   operator process explicitly before estimating web savings; the current
   allocation selection did not include it. Any leaf memo experiment must
   preserve action identities, approval state and freshness.

The old test daemons are a separate cleanup opportunity of about 1.45 GiB
summed RSS. The native-fixture repair and prior proof are recorded in
[running-memory-2026-10-28.md](running-memory-2026-10-28.md). Cleanup requires
checking each current native birth identity and authorized scope; it is not
part of the captures or a production daemon optimization.

## Evidence and limits

Raw local artifacts are under `/private/tmp/loom-profile-20261029/`:

- `inventory.json`, `process-tree.json`, `descendants-sanitized.json`,
  `os-timeseries.json`, and `os-uninstrumented.json` for OS identity/counters.
- `footprint-<pid>.txt`, `daemon-native-sample.txt` and
  `gopls-native-sample.txt` for OS diagnostics.
- `daemon-standard.term`, `client-standard.term` and their `.json`/`.log`
  summaries for ordinary OTP counters, safe stack frames, ETS counts and
  allocator carriers.
- `daemon.pgcap`, `daemon-final.pgcap` and `client.pgcap` for Pickglass censuses.
- `daemon-cpu.json`, `client-cpu.json` and corresponding logs for stack samples.
- `daemon-allocation.pgcap`, `catalogue-allocation.pgcap`, corresponding logs
  and JSON summaries for allocation counts.
- `daemon-metadata-msacc.term`/`.json`/`.log` for bounded metadata, build
  identity, microstate deltas and restoration evidence.

Pickglass captures are gzip JSONL. Generated parseable-term files replace
printed PID syntax with binaries for offline JSON conversion; raw terms remain
available. No process dictionaries, provider settings, transcript contents,
message bodies, cookies or closure environments were exported.

These windows have different selected processes and concurrent real work.
They are suitable for selecting a benchmark, not for claiming an optimization
percentage. No production implementation or performance regression test was
changed in this profiling pass.

Validation: every Pickglass capture parses as gzip JSONL with matching header,
footer and record counts. Both speedscope files parse, and recomputed function
allocation totals equal their reported 188159272 and 64307224 bytes.
`git diff --check` and `make doc-check` pass; doc-check reports zero errors
and 229 advisory warnings. No production code changed, so application test
suites were not rerun for this measurement-only report.

An independent report-only review recomputed the capture totals, checked the
running/source revisions and traced the catalogue/validator call paths. It
found no actionable attribution or factual corrections.
