# Daemon allocation and repeated projection, October 2

This pass observed installed revision `a3dc253596ba24ebf308a1ea680712705b49b1d9`
on macOS, OTP 29.0.5 / ERTS 17.0.5, with 16 schedulers. The daemon was PID
74659; its profile launch enabled allocation tags and loopback distribution.
The baseline had no active tprof server or traced legacy processes. Profile
mode alone was not a continuously running call profiler.

## What the live memory represented

At 22:43:49 UTC, `erlang:memory` reported 493.5 MiB total, including 423.3 MiB
of process allocation, 24.8 MiB of binaries, 22.5 MiB of code and 1.6 MiB of
ETS. There were 289 processes and 26 ports. A separate native sample reported
532.8 MiB physical footprint, with a 660.9 MiB peak. These are different
counters and observation cuts, not interchangeable totals.

Two session-services supervisors each held about 35 MiB of allocated process
memory and two runtime roots about 14.4 MiB each. Their child trees carried
substantial allocation as well. Restart specifications legitimately retain
service construction inputs; they are not idle shells. The bounded runtime
state probe exposed an 8,347,632-byte flat-copy size, of which Effects
accounted for 5,503,800 bytes and the cached scan for 2,840,360 bytes. Its
largest Effects path ran through tool-surface wiring and the registry into
code mode and the LSP door. PR #721 already narrows those captures. This pass
used the older installed revision, so it is not a measurement of that PR's
installed savings.

An authorized major collection on six selected owners at 22:51:18 UTC lowered
VM allocation from 515,519,501 to 458,454,989 bytes. Process allocation fell
from 440,689,152 to 384,077,704 bytes. Two jobs actors fell from 19,513,776 and
27,652,424 bytes to about 950 KiB each; one advisor actor fell from 11,516,728
to 88,648 bytes. The two large services supervisors did not shrink. Individual
RPC elapsed times ranged from 77 microseconds to 5.2 milliseconds, including
transport overhead; those are not measured stop-the-world pause times.

One jobs actor's returned application state was only 469,704 flat bytes,
including 255 held terminal records and no pending records. Its heap grew
again after collection. This establishes reclaimable garbage or heap capacity
in those owners; it does not establish that every other heap root is small.
In particular, `sys:get_state` omits the actor loop's handler and other roots.
Flat-copy costs also discard same-process sharing and do not predict RSS.

The visible client, PID 18100, reported a separate 92.1 MiB footprint and
119.9 MiB peak. The second apparent loomd, PID 33146, was the code-mode
satellite under loom-exec rather than another daemon listener. Observer Web
was another process with its own allocation; it was not part of the daemon's
`erlang:memory` figures.

## What the CPU profiles established

A ten-second observation ending at 22:44:08 UTC saw 5,906 garbage collections.
The busiest sampled actor, the SQLite store, added 58,991,671 reductions; the
selected runtime driver added 2,448,827. A later three-second call-time profile
of the store recorded 58,910 microseconds of function time. JSON parsing and
bit-array operations accounted for about 44% of that recorded time, and the
SQLite NIF for about 16%. That window included 84 register reads, 14 entry
reads and 14 register-list requests. The profile identifies repeated decoding
work, but does not justify a new register cache without a matched workload
and ownership/invalidation analysis.

The selected runtime driver's three-second profile at 23:02:19 UTC contained
15 `project_for` calls and 15 `hooks.project_from_scan` calls, including 19,530
entry-projection iterations. It contained no `remember`, `extend_scan` or
`full_scan` calls. Every lookup therefore hit the unchanged cached leaf, but
rebuilt the same default projection anyway. The existing scan cache avoided
storage reads while leaving message projection, orphan healing, origins and
compaction metadata to be rebuilt on each poll and planning pass.

The orphan-healing forward search initially looked quadratic. In the observed
settled transcript, tool results followed their calls and the search usually
stopped immediately. A new global result index would add allocation to that
common case; it was not added.

All call profiles were bounded to three seconds and selected processes, with
cleanup checked afterward. Only the legacy/default trace session remained.
The explicitly authorized, size-only diagnostic module had a 64 MiB worker
heap cap and four-second deadlines, and was deleted afterward;
`code:is_loaded` returned `false`. No production source was hotpatched and no
candidate release was installed or restarted. A later observation-only cut at
23:24:35 UTC saw 683.0 MiB total VM allocation, 605.4 MiB in processes, and
368 processes. Session activity and process count had changed, so this is not
a matched comparison with the earlier cut and does not establish a leak.

## The cache change and matched isolated measurement

The private `CachedProjection` stores both the immutable scan and its pure
`hooks.Projected` result under one leaf key. A cache hit returns that result;
an append, fork, rewind or compaction still uses the existing join/rescan
rules. A new driver starts cold. Threshold hooks and request-local context
transforms still run at their original boundaries, and transformed request
messages never enter the cache.

The runtime implementation is commit
`e12aed81caa6f12341ebc91e3f0bbce292a9f50f`, based on main's merge of PR #721.
The baseline runtime source is identical between installed `a3dc2535` and
PR #721's `6a753b95`; its generated runtime artifact came from the latter's
validated build. Both builds used Gleam 1.19.0-rc2, OTP 29.0.5 / ERTS 17.0.5
and eight-byte words. The benchmark runs in its own non-distributed VM with
one scheduler. It recompiles generated abstract forms with private exports
inside that VM only, without replacing a build artifact or loading code into
the daemon.

Each fixture contains 300 settled four-message tool exchanges, or the same
1,200 messages copied into one compaction entry. The benchmark constructs the
cache through the actual private `remember` function, checks exact projected
value equality, warms 20 reads, then performs seven batches of 500 cache-hit
calls. Construction is excluded. Medians from the matched run:

| Fixture | Baseline reductions / 500 hits | Candidate reductions / 500 hits | Baseline elapsed | Candidate elapsed | Extra shared cache structure |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary, 1,200 messages | 14,684,907 | 1,505 | 57,498 us | 7 us | 67,296 bytes |
| Compacted, 1,201 projected messages | 6,618,194 | 1,505 | 23,237 us | 5 us | 38,640 bytes |

The candidate timing is close to timer granularity; reductions are the clearer
work comparison. These results measure this private cache-hit path, not total
daemon CPU. Same-process shared term structure grew from 403,536 to 470,832
bytes for the ordinary fixture, and from 269,320 to 307,960 for compaction.
The combined cache's flat-copy costs grew more, from 628,736 to 1,171,160 bytes
and from 465,752 to 950,768 respectively. This cache stays within the driver;
those flat figures describe the combined cache rather than the context which
must still travel with a provider request. Off-heap binary payload size, process heap capacity and
installed resident memory are not included in these term-size figures.

To reproduce after building the runtime tests in each checkout:

```sh
make check-runtime
escript scripts/projection_cache_bench.escript packages/runtime/build/dev/erlang --expect-cached
# Use the same script against a separately built baseline tree, omitting the flag.
escript scripts/projection_cache_bench.escript /path/to/baseline/packages/runtime/build/dev/erlang
```

The runtime-package gate runs the probe with `--expect-cached` inside a
30-second deadline. The work check rejects a 500-hit batch above 10,000
reductions, rather than gating on timing. It passed for the candidate and failed on the
baseline with `projection_recomputed` and 14,666,621 reductions. The runtime's
180-test gate also passed, including a direct provider-context regression
that verifies an appended answer and next prompt reach the next request while
transient hook messages do not leak into later requests or durable context.
Existing join tests cover append, fork, rewind/no-extension and compaction;
existing cold-open and interleave tests cover reconstruction after crashes.

## Keeping the cache out of provider workers

Independent review found that the provider worker read `state.reaper` inside
its closure. That captured the entire State, including the new cache, and
would have copied it into every effect worker. Binding the reaper before
constructing the closure removes that transfer without changing adoption,
begin or drain ordering. The required context in `RequestSpec` still travels
with the request.

The probe also intercepts the private spawn boundary in its own disposable VM
to inspect the actual closure constructed by `spawn_provider`. It never runs
the captured body, a provider request or effect adoption. For the same
1,200-message projected request, baseline worker-closure flat size was
136,958 words (1,095,664 bytes), versus 58,292 words (466,336 bytes) after
narrowing, about 57% less structure to copy. Adding 8,192 integers to an
unrelated tool closure grew baseline capture by 16,384 words; the narrowed
capture stayed at 58,292 words. The padded payload was still reachable in
State, which the probe asserts before measuring the worker.

A targeted mutation restored just the `state.reaper` read while keeping the
new projection cache. Cache-hit work stayed at 1,505 reductions, but the
closure grew from 204,761 to 221,145 words with padding, and the capture check
failed with `provider_captured_sibling_state`. Restoring the narrow binding
passed both checks. These are flattened closure-copy costs, not measurements
of installed worker heaps or resident memory. The runtime's adoption, restart
reaping and graceful shutdown tests also passed after the binding change.
An isolated stock Gleam 1.18.1 build passed the same probe, using its generated
Erlang source instead of the native compiler's abstract forms; its fourteen
batches also used 1,505 reductions, with equal 58,292-word worker closures.

## Remaining measurement boundary

The installed daemon still needs a matched comparison after deployment of
PR #721 and this cache change, with the same session histories, active effects,
connection count and observation cuts. The present pass explains much of the
allocation and proves avoidable repeated projection work. It does not claim
that the daemon's 500 MiB footprint has been eliminated or that its remaining
CPU is all projection work. Jobs/advisor temporary allocation and repeated
store decoding remain measured leads for a later pass.
