# Idle CPU and memory investigation

Status: profiling and two local page-memory repairs are complete. Replacement
of the Darwin tracking mechanism is pending owner approval. The memory repair is saved locally
at `c5776c1d3`; it has not been published or installed. No installed process was stopped, forced through garbage collection,
patched, or restarted. The operator described this workload as idle; the live
daemon still had three resident sessions and six declared strands. This is an
observational baseline, not a controlled before/after comparison.

Source inspection uses `490792538d18577ee001402ef7377998ce1b12b3` on
`perf/idle-resource-cost`. Both installed helpers report build
`dd43362c86b43000e69e291550a41c21f5ffc13b` from their shipment. The tracker
source is unchanged between that build and the inspected head. Pickglass does
not identify the daemon's application revision, so the helper's revision is
not proof of the daemon's loaded BEAM code.

## The helpers keep scanning while their children wait

Over a 15.104-second observation, helper PID 14812 accumulated 1.90 CPU seconds
and PID 95483 accumulated 1.78 CPU seconds: 12.58% and 11.79% of one core.
Their RSS was 17,888 and 17,824 KiB. The long-lived children were a code-mode
BEAM process and `gleam lsp`, respectively. Waiting children still count as
running executions to the helper.

`sandbox/internal/jail/tracker_darwin.run` captures the entire host process
table every 20 ms for each execution. Native samples of both helpers show
repeated `sysctl` calls among otherwise blocked threads. The tracker needs
parent links to remember descendants for later cancellation, including children
that leave the original process group. It is doing lifecycle work while the
payload has no tool request to execute.

A diagnostic Go-test overlay started one unmodified tracker and slept in 20 ms
increments. It ran for 12.05 seconds and recorded 1.16 seconds of CPU samples
(9.62% of one core). Fresh table acquisition accounted for 59.48% of those CPU
samples; scheduler synchronization and garbage collection account for much of
the rest. Each benchmark iteration allocated 899,429 bytes over an average
20.519 ms, about 41.8 MiB/sec. These are cumulative allocations, not retained
memory. Profiling and the benchmark's own timer add overhead, so this is a
reproduction of the cost rather than an exact attribution of every live cycle.

Three existing startup benchmark runs reported 179 to 187 microseconds and
925,140 to 925,141 bytes per operation. The synthetic 1,200-row traversal alone
took 14.65 to 14.86 microseconds with zero steady allocations. Optimizing that
traversal again would leave the expensive acquisition and periodic wakeups.

The proposed next experiment is a kqueue fork/exit watch, with fresh startup
and cancellation captures and explicit treatment of failed registrations.
Changing the descendant-discovery mechanism needs owner approval before a
prototype is added. This is not a proposal to lengthen the sampling interval.
[Apple's event header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/event.h)
states that `NOTE_TRACK` and `NOTE_CHILD` are unsupported on modern macOS, so
automatic recursive tracking cannot be assumed. A prototype must prove its
idle benefit and exercise new descendants, reparenting, PID reuse, independent
roots, cancellation, and shutdown before any equivalence claim.

## Daemon CPU is smaller and mostly waiting

The same 15.104-second OS observation measured 0.52 daemon CPU seconds (3.44%
of one core). A separate ten-second Pickglass counter probe reported 0.1%
scheduler utilization across the VM's 16 schedulers. These windows and counters
are different measurements.

A 15-second Pickglass sample covered 16 selected processes, with 15 running or
runnable samples and 14,993 waiting samples. SQLite reads, JSON processing, and
web transport appear in the active samples. Fifteen active samples are too few
to rank small optimizations reliably, and native/NIF work is under-sampled.
The `core@json` counter probe did observe idle work, including 4,000 calls to
`parse_string_body` in ten seconds, but it does not establish a memory leak.

## Memory owners and bounded findings

The Pickglass census reported 252.6 MiB total BEAM allocation: 166.0 MiB process
capacity, 36.0 MiB binaries, 28.4 MiB code, and 1.9 MiB ETS. Its process census
covered all 370 processes; detailed capture rows are capped at 200. A separate
OS footprint cut reported 334,251,280 bytes (318.8 MiB), while RSS was about
455 MiB. The counters describe different allocation and residency properties.

The largest application allocations included an 8.7 MiB page socket and a
7.2 MiB gateway. A bounded read of their application states found 72 and
137,308 flattened words, respectively. The page's application state omits its
actor handler and selector roots, so its small state does not prove that the
remaining allocation is garbage. No collection was forced on the live node.

Baseline source inspection found an admission-lifetime defect in
`client/daemon/ui_socket.websocket`: its message handler captures `admit`,
which captures the original resolved attachment even after `Pending` changes
to `Serving`. The page's `upgrade` authorization closure also passes the whole
attachment to `authorize`, although the check only needs the registry and
immutable identities. Both baseline paths retain an unrelated runtime and effects.
The local repair makes the admission callback belong only to
the pending phase and projects the authorization inputs before constructing
the callback. Repeated authorization, parser-permit transfer, original gateway
binding, and close ordering must remain unchanged. The real-upgrade regression varies an unused runtime hook by 8,192 messages.
It proves that the hook still returns every message, that the page's relay is
admitted by the original gateway, and that closing the socket releases that
attachment. Its explicit collection is confined to its own fixture socket.
The production node was never collected.

Before the repairs, the inflated socket occupied 973,624 bytes after collection,
against 55,328 bytes for the empty-payload fixture. With pending ownership fixed
but broad authorization restored, gateway attachment growth was 60,938 words
with the payload and 3,558 without it. Each capture therefore independently
violates its own bound. Restoring only the broad pending handler capture, while
keeping narrow authorization, also fails the socket bound.

Three fresh fixture VMs after both repairs and the reviewed cleanup measured
the empty socket at 6,032 bytes and the inflated socket at 6,216 to 22,192 bytes.
Gateway attachment growth was 388 words without the payload and 388 to 414 words
with it. Post-collection process bytes
include unused capacity; these figures establish bounded socket retention and
callback copy cost, not a measured daemon-wide RSS reduction.

Independent review approved the production changes and identified a temporary
ticket service in the new fixture whose original HTTP parent exits normally.
The corrected fixture starts and monitors its own service before running the
body, catches body failures through a managed run, then unlinks, kills and
witnesses that exact service's exit before reporting the outcome. Its test-only
PID accessor reads the opaque handle's subject through the generated record
header; no production inspection or lifecycle API was added. The reviewer
approved this cleanup delta.

A separate, pre-existing candidate remains in `admit`: the component's
`Transport.sessions` callback captures the full attachment, although `listed`
uses only registry and digest. The component stores this transport. Its retained
size and a bounded component regression remain unmeasured; this local patch
establishes the socket and gateway bounds above, not elimination of every
component capture.

A ten-second allocation probe on the page socket's loaded encoding/transport
modules attributed 10,736 bytes across 11 sends. Two probes on selected idle
processes recorded no calls to their matched modules; that is limited probe
coverage, not zero allocation for the daemon.

The largest separate OS memory owner is the idle `gleam lsp` child: 1,316,560
KiB RSS (1.26 GiB), with no CPU time accumulated during the 15-second cut.
This is outside BEAM and outside Pickglass's accounting. Its size alone does
not distinguish compiler caches from a leak. A controlled LSP session/project
comparison and an idle-retirement policy are separate follow-ups; terminating
the operator's language server was not part of this measurement.

## Local validation

The full surrounding suites pass: 12 session-socket, 63 page-socket, 18 relay,
and 183 UI-route tests (276 total). The final focused regression also passes
after strengthening the hook-delivery witness. The complete 12-test socket suite passes again after the cleanup correction.
Client lint has zero errors and 731 census warnings. Documentation checks have
zero errors and 214 warnings. Formatting and whitespace checks pass. The local
helper benchmarks pass. Hosted CI, Linux signoff, publication, installation,
and a matched live before/after measurement are outside this validation.

## Local evidence

Raw captures remain outside Git under `/private/tmp/loom-idle-2026-10-19-*`:
the initial `.pgcap`, census, CPU speedscope file and summary, allocation
captures and summaries, OS footprint, and bounded state sizes. Native samples
are `loom-exec-14812-idle.sample.txt` and `loom-exec-95483-idle.sample.txt`.
The isolated tracker overlay, benchmark, CPU profile, memory profile, and test
binary use the `loom-idle-tracker-*` prefix. The overlay changes no source in
the installed helpers or tracked repository files.
