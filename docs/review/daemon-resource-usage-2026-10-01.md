# Daemon and Darwin helper resource use, 2026-10-01

Status: source fixes committed and independently reviewed. Combined signoff,
release comparison and installed verification are in progress. This wave builds
on the [first closure-retention fix](daemon-memory-retention-2026-10-01.md).

## Measured boundaries

The normal installed daemon was PID 56416, source
`3819fec3d4ea999f51c6504b31c4d9b5d68c1501`. A new observational census
reported 465.697 MiB total BEAM memory, of which 418.577 MiB was process
memory. Both original sessions were idle, with four strands, no working
strands and no pending approvals. Mailboxes were empty. This is a later
snapshot of the first fixed release, rather than a matched leak measurement.
No forced collection or live retained-state walk was performed.

Bounded process metadata observations found one actor taking most reduction
credits in two windows, but sampled stacks found it waiting. Reduction counts
do not establish OS CPU cost, and these observations did not identify an
unnecessary actor handler. No change to its scheduling or lifecycle follows
from that incomplete attribution.

A sleeping Darwin execution still takes a fresh host process-table snapshot
every 20 ms. Its old traversal copied all kernel records into a second slice
and allocated child slices across the host before visiting the execution's
small subtree. That allocation was reachable in an actual long-running
`loom-exec`, independently of whether its payload was doing work.

## Ownership projections

`client/context_view.reader` constructs a private dictionary of tool names,
descriptions and schemas before retaining the context callback. The hub
still owns the executor registry through its execution surface. Reads capture
the strand configuration and leaf together, select the current active names,
and preserve ordering, duplicate replacement and unknown-name omission.
Startup separately projects the fallback context window and compaction
settings. The public one-shot APIs share the projected implementation.

`client/serve.with_code_mode_peers` retains the preceding router function
before constructing its wrapper. The preceding wrapper runs first; peer
interception binds the launching strand and delegates unrelated capabilities
to that router. The returned host intentionally retains its execution inputs.
The change removes the additional full-config path inside the callback.

| Surface | Light / heavy source words | Retained callback words |
| --- | ---: | ---: |
| Context reader | Registry 208 / 90298 | 628 / 628 |
| Peer router | Host config 161 / 45206 | 24 / 24 |

The returned peer host grew from 183 to 45228 words, as expected: removing
execution configuration from the host would break its responsibility. Restored
old captures failed the regressions, growing the context reader from 643 to
90733 words and the old peer wrapper from 183 to 45228 words. These flat-copy
counts prove independence from unrelated payload growth; they are not a
prediction of resident-memory savings.

## Fresh snapshot traversal

The Darwin tracker indexes parent heads and one-based sibling links within
the kernel snapshot. Reverse indexing preserves the snapshot's sibling order.
Traversal still starts from the original parent and remembered identities,
including descendants reparented since an earlier scan. Signal delivery still
checks the live birth time. Sampling remains every 20 ms; confinement,
deadlines and wire interfaces retain their existing behavior.

An independent fixed-table run measured:

| Traversal | Time per operation | Allocated bytes | Allocation count |
| --- | ---: | ---: | ---: |
| Original | 52334 ns | 186792 | 807 |
| Indexed | 16163 ns | 46672 | 6 |

Four alternating ten-second windows used the same real sleeping child and
host process-table API. All completed 500 scans; host tables had 1153–1157
processes. Original windows allocated 463.99–464.01 MB in approximately
109000 objects. Indexed windows allocated 400.10–400.11 MB in approximately
4700 objects. This is about 14% fewer bytes and 96% fewer allocation objects
in the full sampled fixture. Collections fell from 164–166 to 124.

The new traversal itself was about 3.2 times faster in that run. Whole-window
CPU times overlapped: original 868–931 ms, indexed 763–908 ms. The kernel
snapshot remains the dominant allocation, and host work varies. This evidence
does not establish a whole-helper or whole-daemon CPU percentage improvement.

## Correctness and verification

The code-mode suite passed 80 tests and the context suite passed eight tests.
Client lint exited zero with no errors. The native helper passed its race
suite, vet, build and eleven enforcement probes. Negative controls rejected
the old captures, omitted recursive traversal and bypassed birth checks.
The tracker tests cover deep unordered ancestry, reparenting, PID reuse and
real TERM delivery while an unrelated sleeping process remains alive.

A fresh Astra review found no production regression, no high or medium
finding, and no additional actionable nearby variant. It identified a low
test-oracle gap: metadata comparisons shared the projection under test. The
follow-up adds an independent expected value for the known fixture metadata.
The reviewer's own real-process rerun was denied the kernel process-table
sysctl by its sandbox; the escalated native suite is the execution evidence.

The combined signoff exposed two fixture ownership errors. Eight-way EUnit
ran typed MCP cases within `cap@mcp_codec_test` concurrently; they installed
different responses into one VM-global capability channel. Its declaration
in `scripts/serial-tests` now gives the module exclusive ownership, using the
same mechanism as the existing capability suites. All 168 cap tests pass at
the original eight-way setting. Assertions and production dispatch are unchanged.

The Go LSP fixture derived its writable cache grant from outer `GOCACHE`
without forwarding that variable to jailed Go. The granted path and actual
write path diverged under a private cache override. Forwarding the same name
aligns them. Both private and default caches pass; reverting only the forwarding
line reproduces the original symbol-not-found failure. Filesystem grants and
query assertions are unchanged. Astra reviewed both test-only corrections
and found no remaining issue.

## Matched release observation

The installed baseline at `3819fec3d` and the combined candidate at
`369c8a2fb` used the same release configuration and control-plane probe.
The probe source was unchanged across the rebase. Each boot used a fresh
private HOME, workspace and state root, admitted two empty sessions, stopped
the first and observed the remaining resident after 15 seconds idle. Neither
run forced collection or copied retained live state. The combined candidate
also includes the typed MCP work merged in PR #685.

| Cut | Baseline total / processes, MiB | Candidate total / processes, MiB |
| --- | ---: | ---: |
| Listening | 55.623 / 15.192 | 55.449 / 14.770 |
| Two admitted, one stopped | 82.646 / 33.457 | 80.464 / 31.136 |
| After 15 seconds idle | 76.841 / 27.656 | 74.032 / 24.687 |

The idle BEAM delta was 2.809 MiB in total and 2.969 MiB in process memory.
RSS moved from 113584 to 118240 KiB, so this run does not prove an RSS
improvement. Allocator carriers, collection timing and the small bare-session
tool graph differ from the normal daemon. The installed comparison remains
separate; callback flat-copy savings are not subtracted from either census.

## Remaining limits

Directory-administration capture is deferred because changing its borrowed
runtime and restart ownership requires a separate lifecycle argument. The
remaining daemon memory is not fully attributed. Darwin retains its declared
sampled process-lifecycle gap: process birth checks cannot be atomic with
signals, and rapid reparenting between samples can evade observed ancestry.
Fewer allocations do not strengthen those kernel guarantees.
