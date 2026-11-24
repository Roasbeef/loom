# Live Loom resource profile, November 23, 2026

The attention inbox ran in the live sample. Its session feed decoded the
latest result of each strand before reducing the row to its response budget.
That is the first new-feature path to replay. Two Go language servers were the
largest observed memory consumers among the daemon's descendants. Their RSS
varied substantially across the session, which makes a single high reading a
poor basis for a lifetime change.

## Build and workload

The authenticated node reported Loom 0.3.2 at
`c07f6af67e34bcd2fa271c443f86f94cabf0cf36`, PID 41481, OTP 29 and ERTS
17.1.1. The separate installed terminal client was PID 15507. The daemon
was serving its ordinary workload. No synthetic turns or feature requests
were injected. The inspector reused the local TLS resolver described in the
[November 9 profile](live-profile-2026-11-09.md), verified the daemon PID and
released its pins and unloaded its modules after each capture.

The report branch starts from `912cbfd59`. Eight first-parent merges separate the installed
build and that source revision, including #1333, #1342, #1343 and #1351. The
installed build includes the attention inbox and earlier distributed executor
work. The later advisor verdict, stream header and stuck-strand dismissal
changes are outside the live measurements.

## CPU and memory by owner

Clean OS windows exclude the Pickglass probes. CPU is the process CPU counter
delta divided by wall time, as a percentage of one core. RSS is sampled every
two seconds. Each footprint is a separate macOS reading.

| Owner | First window CPU | First window closing RSS | Closing window CPU | Closing window closing RSS | Physical footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Daemon | 14.09% | 542.38 MiB | 5.19% | 678.98 MiB | 769 MB |
| Terminal client | 8.29% | 66.22 MiB | — | — | — |
| Go language server 14775 | 0.00% | 1,951.48 MiB | 0.00% | 756.58 MiB | 739 MB |
| Go language server 28026 | 0.00% | 290.73 MiB | 0.10% | 290.77 MiB | 405 MB |

The daemon windows lasted 30.24 and 30.04 seconds. The larger language server
was about 48 minutes old at the intermediate process cut. The smaller one was
about 4 hours 25 minutes old. Each had a different `loom-exec` parent in the
daemon subtree. Both were present through the closing cut. Their summed RSS
fell from 2.19 GiB to 1.02 GiB. This establishes a significant external-process
cost and a reason to measure warm lifetime. Session ownership, active query
custody and the cause of the RSS drop were outside the census.

| OTP category | Opening bytes | Closing bytes |
| --- | ---: | ---: |
| Total | 706,810,738 | 726,472,869 |
| Processes | 576,689,272 | 598,294,200 |
| Binaries | 69,498,408 | 67,259,456 |
| ETS | 2,408,200 | 2,405,544 |
| Process count | 755 | 730 |

The largest reported process allocation was about 45.55 MiB at both cuts,
for a process reporting a factory-supervisor initial call. The opening
inventory returned metadata for 754 processes, with sampled mailbox lengths
of at most one. The inspector made no process-state or closure walk, and the
heap census measures allocated capacity. Two cuts across an uncontrolled
workload cannot establish reachable retention or a leak.

Pickglass pinned the 16 busiest eligible processes by reductions for 45 seconds
at 62 Hz. Of 45,008 observations, 59 were running or runnable. The inclusive
stack counts included 37 for `esqlite3:q/3` and 17 for
`client/config_watch.handle`. SQLite stack families included register listing
and snapshot queries. The small active count limits ranking precision.
Sampling at reduction safe points can undercount long native calls. Use the
OS windows for CPU utilization, and use these stacks to locate work to replay.

## Allocation and feature costs

Two later Pickglass windows counted calls, time and heap allocation in
selected modules on eight processes each. Calls can span actors, and the
output aggregates functions without caller stacks. Function totals include
untraced callees and exclude separately traced callees. The windows used
different module sets and represent separate workloads.

| Window | Observed seconds | Called functions | Cumulative allocated bytes |
| --- | ---: | ---: | ---: |
| Storage, gateway and OTP JSON | 16.1 | 173 | 8,847,760 |
| Attention and JSON | 22.7 | 128 | 12,034,408 |

All called functions had readings in both windows. These counters cover
process-heap allocation. Binary backing storage, retained heap, RSS and
physical footprint have separate ownership and units.

### Attention inbox

The attention window recorded seven calls to `client/attention_feed.feed`.
The module's 39 rows sum to 1,517,104 bytes, or 12.6% of the traced total in
that window. Its largest row was the callback in `last_results`, with
451,544 bytes across 36 calls. Read-evidence and stuck-strand construction
also appeared. Treat the module sum as measured work in this selection.
Storage actor work and browser work have separate owners.

The installed `feed` lists asks, finds, strand states and last results.
`last_results` lists the whole `StrandLastResult` namespace and decodes
every returned payload before the result is filtered and encoded. The home
route limits the requested set to 24 sessions, runs the resident fan-out
with a 2,000 ms deadline and checks each returned row against a 2,400-byte
outer limit. The feed has its own 2,300-byte shedding budget. The per-session
namespace work
can still grow with strand count. Main adds dismissal reads, so an
experiment on main must include dismissal and the existing count and
ordering contracts. See [attention feed](../../packages/client/src/client/attention_feed.gleam),
[daemon fan-out](../../packages/client/src/client/daemon/server.gleam)
and [control limits](../../packages/client/src/client/daemon/protocol.gleam).

There is a concrete extra-read candidate on both revisions. Once any stuck
strand qualifies, `read_evidence` batches leaf entries for every failed run
with a leaf, including failures that the row excludes because the strand is
running or is the primary or advisor strand. On main, dismissed failures are
also excluded from the row but can enter this batch. The same feed builds
the stuck list to decide whether to fetch evidence, then builds it again
for the result. The trace recorded 14 calls to
`stuck_strands/3` alongside the seven feeds. The lookup walks the strand-state
list before it checks the result kind. A replay with one visible stuck strand
and many excluded failures can measure the cost of those
reads and lookups while verifying an identical row. Preserve how a failed
evidence read affects the row when comparing alternatives.

The next measurement should use a fixed matrix of 1, 8 and 24 resident
sessions and vary completed strand count at each size. Keep visible asks,
finds, failed strands, response bytes and authorization fixed. Count writer
requests and returned rows at the writer boundary. Measure decodes and heap
words on the caller, along with peak fan-out across sessions. Compare complete
rows and counts before considering a narrower read.
The live sample identifies a cost center. It does not establish which
terminal results can be omitted while preserving the feed.

### Language-server lifetime

The session manager keeps one warm server per session and releases it on
switching roots, explicit stop or manager exit. A cold query can pay startup
and indexing again. The observed children are consistent with multiple
sessions keeping servers warm. The OS samples cannot determine whether either
helper had lost its owner. An isolated cold, warm, idle and release replay
should record the server PID, startup latency, footprint and exit witness for
each session. A lifetime adjustment needs to demonstrate reduced memory and
preserved readiness and cleanup. See [LSP manager](../../packages/client/src/client/lsp/manager.gleam).

### Configuration, JSON and distributed execution

- The config watcher reads and hashes its file every second for each session
  configured with a watch source. Unchanged bytes reuse the parsed view digest.
  The CPU sample confirms that this periodic path runs. Neither allocation
  window pinned a watcher that reported calls, so the sample gives no
  per-watcher allocation estimate. Measure read and hash counts with several
  sessions sharing a source before changing the watcher. Any change needs
  to preserve the two-read stability check. See [config watcher](../../packages/client/src/client/config_watch.gleam).
- The storage window attributed 2,459,520 bytes to the snapshot SQLite
  module and 2,164,808 bytes to the gateway module. OTP
  `json:unexpected_sequence/2` accounted for 2,030,976 bytes across 22 calls.
  Its second-window total was 7,616 bytes across 34 calls. In that window,
  `core@json` accounted for 8,925,176 bytes, or 74.2% of the traced total.
  The trace recorded 488 native adapter calls and 61 reference parse calls.
  These are independent function counts, so the reference count cannot be
  treated as a fallback rate. The variation in the error-row cost needs a
  fixed input replay with caller attribution before changing the JSON path.
  See [JSON adapter](../../packages/json_codec/src/json_codec_ffi.erl).
- The attempted trace of the untrusted gateway was refused with `no_match`
  and detached. This gives no executor or guest cost estimate. Browser
  rendering, remote executor hosts and microVM guests need separate process
  and workload measurements. A useful distributed replay would compare a
  local tool call, a relayed call and a guest-backed call at the same work
  size, then verify the host and guest release paths. See
  [microVM architecture](../architecture/microvm.md).

## Reproduction

Identify the installed daemon and terminal client by executable and PID.
Record process CPU-time and RSS cuts with `ps` across a clean 30-second
window. Record `footprint -p` independently. Use the enrolled TLS inspector
for aggregate `erlang:memory/0`, process counts and bounded
`process_info/2` metadata. Verify the daemon PID and build at both census
cuts. For Pickglass, use the standard `profile --top 16 --seconds 45` CPU
capture and separate `--allocation --top 8` windows with explicit module
patterns. The tool accepts at most eight allocation patterns. An initial
over-limit request and a later unmatched gateway pattern produced no
measurement. The successful captures end with `pins released` and
`detach=modules_unloaded`.

Raw counters, cleanup receipts and SHA-256 digests live under the worktree's
ignored `.notes/profiles/2026-11-23/`. The PR records aggregate results and
keeps local diagnostic material out of git.
