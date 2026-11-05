# Live Loom CPU and memory profile, November 4, 2026

The current daemon runs `be9d81d843c15dc543c314cc428919ee3d68c42c`, which
includes the JSON cursor optimization from PR #1153. SQLite register and
snapshot queries are the strongest sampled CPU candidate. In the separate
allocation window, strand runtime reads and planning dominate the selected
functions. The measured absolute load is modest; neither a leak nor a new
optimization's installed savings is established.

## Identity and collection

PID 99265 started November 3 at 17:59:30 America/Los_Angeles, about 28 hours
before collection. The installed release is Loom 0.3.2 at
`/Users/roasbeef/.local/lib/loom/server.CKG7h26D`. The launcher, daemon endpoint
and live `host/build_identity.current` agree on the build. The live JSON module
MD5 equals the shipped BEAM's MD5. Git ancestry confirms this release includes
merge `394b98d4`, the previous round's JSON optimization.

The VM is OTP 29 / ERTS 17.0.5, with eight-byte words and sixteen normal
schedulers. The observer is the clean local-interface Pickglass checkout at
`9a55ad95aaa79ffdd5ca8f526a05ef156f37582a`, using the existing TLS inspector.
The installed Pickglass rejected the local Tailscale interface before attachment;
the existing local-interface build attached successfully. Pickglass's capture
build fields are unknown; the independent live identity supplies provenance.

This round observes existing activity. No production restart, installation,
hotpatch, forced GC, application-state/closure walk, cleanup, synthetic load or
model request was performed. Pickglass's logs record released pins and unloaded
diagnostic modules after each profile/probe. No message bodies, credentials,
process dictionaries or complete closure environments were exported.

The raw captures, metadata-only counters, OS samples, logs and validator are in
this worktree's `.notes/profiles/2026-11-04/`. That directory is intentionally
untracked. Timestamps below use America/Los_Angeles; raw UTC timestamps fall
on November 5.

## OS CPU and memory

| Window | Duration | Daemon CPU seconds | CPU as share of one core | RSS range |
| --- | ---: | ---: | ---: | ---: |
| Before attachment, 22:24:40–22:25:10 | 30.012 s | 2.12 | 7.06% | 375.77–403.17 MiB |
| Aligned with CPU sampling, 22:27:38–22:28:30 | 52.014 s | 12.02 | 23.11% | 468.02–500.95 MiB |
| After allocation detach, 22:31:21–22:31:51 | 30.012 s | 3.94 | 13.13% | 478.72–503.34 MiB |

The middle window includes profiler setup, sampling and teardown. It is not an
uninstrumented CPU baseline. The first and last windows exclude daemon-side
profiling/counter collection. Changing workload and observer activity prevent
attributing the RSS difference to a leak, a repair or profiler overhead alone.
The CPU difference between windows likewise does not isolate profiler overhead.

The initial daemon subtree also contained a `du` process that used 20.12 CPU
seconds, or 67.04% of one core, over the same clean window. That CPU belongs to
the tool descendant, separately from the daemon's 7.06%.

At the final OS cut, summed subtree RSS was 857.12 MiB:

| Role | Count | Summed RSS |
| --- | ---: | ---: |
| Daemon | 1 | 499.42 MiB |
| MCP BEAMs | 7 | 149.08 MiB |
| Code-mode satellite BEAMs | 2 | 123.47 MiB |
| Native helpers | 4 | 59.75 MiB |
| Other native descendants | 20 | 25.41 MiB |

Shared pages are counted in each process, so this sum is not unique physical
RAM. Satellite identities changed during the round; counts belong to this cut.
The closing daemon footprint was 548 MB, with a recorded peak of 830 MB. One
long-lived satellite's footprint was 49 MB. These retain macOS's printed MB
units. No native terminal client was identified, and remote nodes were not
profiled.

## Sampled CPU

The 45-second profile selected the sixteen busiest processes by reductions from
the top-200 census. It recorded 45,008 samples: 153 running/runnable and 44,855
waiting. There were 945 samples without a stack, reported as hibernating or
exiting; the active summary above excludes waiting samples.

| Inclusive path | Active samples | Share of 153 |
| --- | ---: | ---: |
| SQLite query (`esqlite3.q/3`) | 92 | 60.1% |
| Storage actor `handle_open` | 59 | 38.6% |
| Register point read `do_get_register` | 36 | 23.5% |
| Snapshot query callback | 19 | 12.4% |
| Register enumeration `do_list_registers` | 16 | 10.5% |
| Catalogue query callback | 14 | 9.2% |

Rows overlap and must not be added. Of the SQLite samples, 83 ended in
`esqlite3.fetchall1/2`. This small active sample supports a candidate ranking,
not a precise whole-daemon CPU budget. Pickglass samples selected processes at
reduction safe points, undercounts long BIF/NIF calls and limits stacks to eight
frames. Sample shares are not wall-clock CPU percentages.

## Function allocation and register cache

The top-eight allocation trace asked for fifteen seconds and observed 15.355
seconds. It matched 2,140 functions in eight named modules; 340 were called and
all had an allocation reading, with no reload or invalidation. Total observed
heap allocation was 19,431,272 bytes: 18.53 MiB, or 1.21 MiB/s within this scope.
The top-200 rows omit 18,184 bytes across 140 functions. Module totals below
are therefore lower bounds; their shares use the complete reported total.

| Module | Listed heap bytes | Share of total |
| --- | ---: | ---: |
| `runtime/strand_runtime` | 12,364,304 | 63.6% |
| `storage/sqlite` | 3,326,584 | 17.1% |
| `core/json` | 2,015,048 | 10.4% |
| `sqlight` | 887,768 | 4.6% |
| `storage/internal/snapshot_sqlite` | 414,648 | 2.1% |

The largest function attribution is `strand_runtime.read_decoded/4`: 560 calls,
7,509,528 heap bytes (38.6% of total). `start_effect`'s traced callback accounts
for 1,554,624 bytes in two calls; `read_leaf/1` accounts for 868,208 bytes in
178 calls. `poll_wait_unchanged`'s callback runs 154 times. These are profiler
attributions, not proof that each named function directly allocates every byte.
They identify the next controlled measurement boundary.

A separate fifteen-second, node-wide counter probe observed 2,350
`register_cache.read/2` calls and 86 `decode_blob/1` calls, with zero invalidated
functions. Its denominator is calls entering the blob cache, not all register
lookups: absent SQLite rows return before the cache is called. Oversized blobs
and cache misses invoke `decode_blob`; successful cache hits bypass it. Most
observed blob-cache reads therefore reused decoded values. Calls aggregate all
processes in this separate window; they must not be mixed with the allocation
trace's eight-process subset or presented as its same-window count. Additional
JSON caching is not justified by these observations.

Allocation counts are cumulative heap allocation in the selected functions and
processes. They are not retained memory, RSS, off-heap binary retention or
whole-VM allocation.

## VM memory and process capacity

The initial Pickglass census scanned 787 processes and reported 473.51 MiB
of VM allocation. The independent counter cut later observed 831 processes and
499.16–503.19 MiB. The closing ordinary OTP cut observed 807 processes and
478.57–478.58 MiB: 384.56 MiB of process allocation and 46.23 MiB of binaries.
The counters are not an atomic global snapshot.

At the closing cut, translated process-start metadata groups allocated process
capacity as follows:

| Initial-call group | Processes | Allocated process memory |
| --- | ---: | ---: |
| `weft/actor` | 227 | 186.19 MiB |
| `weft/state_machine` (both start callbacks) | 131 | 86.47 MiB |
| Gleam static supervisors | 17 | 51.11 MiB |
| Gleam OTP actors | 71 | 14.92 MiB |
| Provider gateway request callbacks | 2 | 11.84 MiB |
| Gleam factory supervisors | 17 | 8.34 MiB |

The largest process used 10.65 MiB of allocated capacity. Its mailbox was empty;
the maximum observed mailbox length in the closing census was one. There is no
large mailbox backlog in these cuts. The initial-call group names do not
identify each process's complete retained roots or prove which field retains
memory. Waiting processes can contain reachable values, garbage and unused heap.

The closing allocator scan found 424.33 MiB of heap carriers with 393.10 MiB
of allocated blocks, and 85.30 MiB of binary carriers with 46.23 MiB of blocks.
Unscanned bytes were zero. Carrier slack is not a directly reclaimable RSS
estimate; allocated blocks are not a reachable-state measurement.

## Comparison and next measurement

The October 30 active trace had a JSON allocation lower bound of 65.6%; this
window has a 10.4% lower bound. Input counts, workload, process selection and
build changed. The difference does not quantify #1153's installed savings.
Its matched offline benchmark remains the evidence for that optimization.

The next useful experiment is a fixed replay of repeated strand wait/poll
reads. In the measured source, `poll_wait_unchanged` reads and validates strand
state, operation state, configuration and leaf before deciding that nothing
changed. `read_decoded` fetches a register then runs its typed payload decoder.
Measure actor-message copies and typed decoding separately while preserving
fresh sequence/operation checks and corruption refusal, including corruption
with an unchanged sequence. Avoid inferring that cached JSON removes these
remaining costs.

Pinned source: [poll_wait_unchanged, line 693](https://github.com/Roasbeef/loom/blob/be9d81d843c15dc543c314cc428919ee3d68c42c/packages/runtime/src/runtime/strand_runtime.gleam#L693)
and [read_decoded, line 3287](https://github.com/Roasbeef/loom/blob/be9d81d843c15dc543c314cc428919ee3d68c42c/packages/runtime/src/runtime/strand_runtime.gleam#L3287).
No implementation change is made by this report.
