# Daemon and Darwin helper resource use, 2026-10-01

Status: the combined resource tree passed full local signoff and the isolated
typed Jev fixture at `16e866c8efd94b11127cf931bd46acaf2b675578`.
The resource changes have not been installed in the normal daemon;
hosted CI on [PR #689](https://github.com/Roasbeef/loom/pull/689) remains
outstanding. This wave builds
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

## Gateway membership and supervisor restart inputs

The remaining source trace found one explicit gateway-state owner that did
not use executable registrations: `gateway.State.registry` listed registered
names and checked membership for operator configuration and history recovery.
The private state now projects an optional name-keyed dictionary before
initialization. Public `Options.registry` and `with_registry` still accept the
same registry, and runtime effects still own executable tools. Availability
remains sorted; an absent registry still refuses active-set edits, while a
configured empty registry allows an empty selection. This removes the separate
state slot's executor path, not every registry path reachable through Runtime.

The async-run worker previously read a heartbeat through captured Settings,
and the hub worker read its session, workspace, catalogue and code-mode issue
through the same complete record. Those values are now projected before their
restart closures are built. Runtime and hub execution inputs retain their
existing restart ownership. No borrowed-runtime lifetime, public interface
or supervision strategy is changed.

The four new gateway regressions and the existing cases passed together:
126 tests, own exit zero. The actual isolated actor-state measurement varied
only the separately supplied registry; its runtime fixture had no tool
executors. Registry size grew from 202 to 90292 flat words, while state stayed
758 words. Restoring the original executable-registry field made state grow
from 946 to 91036 words and failed the regression. Source was restored before
the successful complete gateway run. Temporary scalar prints were removed.

Availability uses a real completed credited metadata capture. Configuration
asserts the exact absent-registry refusal and successful empty selection.
Manual compaction submits a real durable branch through the operator command
and captures the provider's frozen preparation: registered plus active history
produces source references, while inactive or unavailable history preserves
the original result. Its private provider fixture permits summary generation;
existing default and scripted fixtures retain their prior policy.

The pinned weft 0.4.5 initializer transfers selected builder fields into its
loop and discards the initializer callback. Gateway's retained handler is the
top-level `handle`, so startup Options do not reintroduce the removed registry
field through a handler environment. A fresh independent review found no
remaining invariant, simplification or reachable nearby-variant finding in
these additions. These results isolate retained paths; they do not predict
installed process or RSS savings. The final combined release signoff passed.

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

A fresh independent review found no production regression, no high or medium
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
query assertions are unchanged. An independent review covered both test-only corrections
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

## Full release verification

The final combined tree at `16e866c8efd94b11127cf931bd46acaf2b675578`
passed `make signoff SIGNOFF_ARGS=--dry-run` in 517 seconds, own exit zero.
All six source/test lanes, release/update verification and the declared-skip
census passed on the clean, frozen head. Its client suite ran 2636 tests,
the TUI suite 1052, followed by the configured simulation soaks. The helper
reported eleven enforced self-test layers. The macOS `/proc` and
rust-analyzer prerequisites remained the only declared skips.

The final self-contained release then passed the same typed Choice fixture
through generated discovery, jailed compilation, installed Jevelin dispatch
and durable result capture. It returned `logs`, confidence 0.9 and 10 input /
3 output tokens, with the expected dummy bearer absent from model requests.
Only its disposable daemon and session were shut down. The reported Seatbelt
filesystem and network enforcement and degraded macOS resource/lifecycle
limits remained explicit.

The earlier signoff below covers the first resource slice, before the private
gateway and restart projections. It is retained as evidence of that boundary,
not substituted for the final combined head.

`make signoff SIGNOFF_ARGS=--dry-run` exited zero in 764 seconds on
`bede55e54b8765af7785ece8cd122fa833c4ac32`, with a clean, frozen tree.
All six source/test lanes and release/update verification passed. The client
suite ran 2629 tests, the TUI suite 1052, the cap suite 168 and conformance
91, followed by the configured simulation soaks. The helper reported eleven
enforced self-test layers. The skip census contained only the two declared
macOS prerequisites: the real stopped-process MCP fixture needs `/proc`,
and the Rust language-server fixture needs a runnable rust-analyzer.

A separate scripted session booted that self-contained candidate release,
discovered `cap://mcp/jev`, read the generated structural API, compiled a typed
Choice program in the real code-mode jail and called the installed Jevelin
server against a local HTTP fixture. It retained a successful durable tool
result with Choice `logs`, confidence 0.9 and the fixture's 10 input / 3 output
tokens. Both build and satellite reported active Seatbelt filesystem and
network enforcement. Their macOS memory, process-count and process-lifecycle
limits remained degraded. The candidate shut down cleanly without touching
the normal daemon. This is fixture integration evidence, not a new live Jev
inference claim. The first attempt used an overly deep private state root;
the socket-path validation rejected it before dispatch, and a shallower
private state root allowed the same release and program to complete.

## Final matched release observation

Installed main `31db7c68387859da416eff53ed41913cd2ac8f31` and the final
candidate `16e866c8efd94b11127cf931bd46acaf2b675578` ran with fresh private
HOME directories and the same smoke configuration and control-plane fixture.
Each admitted two sessions, stopped the first and observed the remaining resident after
15 seconds idle. Neither run forced collection or copied retained state.

| Cut | Main total / processes, MiB | Candidate total / processes, MiB |
| --- | ---: | ---: |
| Listening | 55.554 / 15.055 | 55.433 / 14.755 |
| Two admitted, one stopped | 82.312 / 33.321 | 79.024 / 29.693 |
| After 15 seconds idle | 76.473 / 27.491 | 74.952 / 25.614 |

Idle BEAM allocation was 1.521 MiB lower in total and 1.877 MiB lower in
process memory. RSS was 118848 KiB for main and 113072 KiB for the candidate,
a 5776 KiB difference in this run. These are single matched fixture cuts;
their small tool graph and collection history do not establish savings in
the owner's larger normal session. They also do not isolate either new
projection from the rest of the resource changes.

## Normal daemon before the owner's restart

The owner installed merged PR #688 at
`5fbcda3ad473338d810376177d85153f23900106` and ran profiled daemon PID 90442.
Its single resident session had two idle strands, no working strands and no
pending approvals. An observational cut allocated 244.374 MiB total BEAM
memory, including 198.842 MiB of process memory. The adjacent OS sample was
280496 KiB RSS. Allocator carriers totaled 278.031 MiB; ETS held about
1.145 MiB. These are distinct counters, not interchangeable memory totals.

The process census grouped 87.402 MiB into weft actors, 56.199 MiB into static
supervisors, 22.056 MiB into state machines and 13.984 MiB into factory
supervisors. The largest actor had a 5157867-word old-heap block with
2790546 used words, about 18 MiB of spare capacity in that block. Two large
hibernated supervisors instead had nearly full heaps: 5224481 used words in
5224493 capacity, and 2137444 in 2137456. This makes their restart-specification
ownership a useful next investigation. It does not identify a particular
callback as the measured owner. No collection, state copy or retained-root
walk was used to make this comparison.

A three-second idle sample recorded 5634 aggregate reduction credits across
192 matched processes. The largest delta was 4351 in one waiting actor with
an empty mailbox. Reduction credits are not elapsed CPU time. They do not
justify a scheduling change or a whole-daemon CPU savings claim.

The current daemon's Jev discovery failed before spawning because
`JEV_API_KEY` was absent from its credential store. Its missing Jev server
therefore does not explain the measured memory. Earlier live Jev success
belongs to the previously recorded release and launch environment. The owner's restart booted PID 20976 at `31db7c68387859da416eff53ed41913cd2ac8f31`,
which also contains the newly merged code-mode prompt work. Its log now
reports `mcp.ready` with `jev=4`. An active cut during one working strand
allocated 292.694 MiB total BEAM memory and 248.596 MiB of process memory;
RSS was 290080 KiB. This changes build, activity, collection history and
MCP availability at once. It cannot isolate the cost of MCP or prove a
restart memory saving. The same original session and its two strands remained
resident. The resource branch itself was not installed.

A later cut of the same restarted daemon found both strands idle: 258.328 MiB
allocated BEAM memory, 211.883 MiB of processes and 307600 KiB daemon RSS.
The separate installed Jevelin process used 69360 KiB RSS. Their summed RSS
is about 368 MiB, which explains the rough combined magnitude without assigning
Jev's separate runtime to Loom's process heap. It does not prove an Activity
Monitor footprint equivalence or isolate startup from workload history.


## Live typed Jev on the restarted normal daemon

A fresh disposable session on PID 20976, source `31db7c683`, discovered the
structural `cap://mcp/jev` module from the model-visible code-mode description,
read that module and compiled the typed Choice program in the real jail.
Live `jev-1.13.0` returned Choice `logs`, confidence 1.0 and 298 input / 31
output tokens. The credited durable session snapshot retained a successful
code-mode tool result, and both build and satellite reported Seatbelt
filesystem and network enforcement. Their platform resource and process
limits remained degraded. No model request contained the API key.

Only the disposable verification session was stopped, returning to `saved`;
the normal daemon and original user session remained running. This verifies
the owner's credential-bearing restart and installed typed MCP path, not
installation of the new resource branch. Memory cuts taken before this test
are not replaced with cuts after its additional workload.

## Remaining limits

Directory-administration capture is deferred because changing its borrowed
runtime and restart ownership requires a separate lifecycle argument. The
remaining daemon memory is not fully attributed. Darwin retains its declared
sampled process-lifecycle gap: process birth checks cannot be atomic with
signals, and rapid reparenting between samples can evade observed ancestry.
Fewer allocations do not strengthen those kernel guarantees.

## Rebase and job fixture ordering

The branch was rebased onto main `7d37ec86`. Range comparison preserved every
resource patch; only the duplicate MCP codec serialization commit was omitted,
because main already contains it. Fresh exact-head hosted Linux checks passed.

The first local signoff at `a8de3bc3` had one web operator-page connection timeout;
its other lanes and release verification passed. Five focused repetitions of that
exact test passed. The repeated full gate passed that case but exposed an existing
job-stop/reopen fixture race. Both affected production files were unchanged by
this resource wave.

`kill_job` acknowledges a requested cancellation before committing Draining.
The fixture immediately launched a replacement, which could sweep the earlier
Running record and deliver a notice. It also checked absence of a notice after
observing Lost, although reaping writes Lost before delivering the notice. These
were incomplete fixture preconditions and completion ordering, not evidence that
the resource projection changed cancellation behavior.

The fixture now polls the original actor to establish Draining, then lists jobs
through the replacement to establish completion of its entire injected sweep.
Both barriers already occur in adjacent tests. No production API, persistence,
retry, timeout, or assertion was weakened. A temporary 100-ms delay after the
kill acknowledgement forced the schedule: the old fixture compiled and failed
its silence assertion; the ordered fixture compiled and passed. Restored
production source also passed. The initial control attempt caught an unused
state-read helper; retaining its existing call kept the final comparison
warning-free. Full current-head signoff and hosted CI will be checked before
merge.
