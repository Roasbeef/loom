# Investigation handoff: daemon memory per session

Status: **supervisor and provider captures repaired locally**; see the September
16 addendum for the current evidence and limits. Earlier sections describe their
own builds and workloads.

Historical status: **owner found and repaired**; see "2026-09-07, second pass"
of this note. The first pass, recorded below unchanged, established the size
and the shape of the step from OS numbers alone. The second pass took the BEAM
cuts it asked for and named the term.

The release was built from the source later committed as `e4fbac8a`; its base
at measurement time was `44a337bc`. Rebasing onto `44d2a5fc` did not change the
runtime sources involved in session admission. The test used the bundled ERTS
17.0.5 server on macOS 15.5 and a fresh state root inside the worktree.

## Result

Each admitted idle session added about 944 MiB to one `loomd` process. The
increase happened before a provider request, and a second session produced the
same step. The daemon's RSS stayed flat during a ten-second idle sample, so the
measurements establish a deterministic per-session allocation. They do not yet
distinguish reachable state from retained BEAM allocator carriers.

| Cut | RSS from `ps` | Physical footprint |
|---|---:|---:|
| Daemon listening, no session | 76,096 KiB | about 74 MiB |
| One idle session | 996,112 KiB | 956 MiB |
| Two idle sessions | 1,958,880 KiB | 1,900 MiB |
| Two sessions after one provider turn | 2,081,424 KiB | 2,019 MiB |

The real turn used the checked-in Baseten example and returned `E2E_OK` to two
terminals attached to the same session. It added about 119 MiB above the
two-session cut. That later increase is separate from the admission bug.

## What the OS measurements establish

After one admission, `footprint` attributed 933 MiB to dirty, untagged
`VM_ALLOCATE` regions. After the second, that category reached 1,875 MiB.
Ordinary malloc allocations remained about 22 MiB. `vmmap` showed several
fully resident 128 MiB regions. The catalogue, session database and WAL
mappings remained small, and only the admitted session databases were open.

A second fresh daemon using the same release and config stayed near 77 MiB
before admission. Thus release startup, the model catalogue and the loaded OTP
applications are insufficient by themselves to produce the large footprint.
Provider response accumulation is also insufficient as an explanation because
the first 944 MiB step preceded every provider request.

The OS data does not name the Erlang process, binary, ETS table or allocator
carrier which owns the pages. Do not patch provider streaming, SQLite cache
policy or garbage collection from these measurements alone.

## Reproduction

Build the self-contained artifacts, then use a fresh state root under the
worktree. Code mode refuses capability sockets under `/tmp`, so the state and
workspace directories must not live there.

```sh
make binaries codemode-seed server-shipment release release-client

profile_root=$(mktemp -d build/loom-memory-profile.XXXXXX)
mkdir -p "$profile_root/state" "$profile_root/workspace"

build/release/loom-client/bin/loom \
  --server "$PWD/build/release/loom/bin/loomd" \
  --workspace "$PWD/$profile_root/workspace" \
  --state-dir "$PWD/$profile_root/state" \
  --config "$PWD/docs/examples/loom-baseten.toml"
```

Record the daemon PID before opening a session. Sample the same PID after each
explicit admission:

```sh
daemon_pid=12345
ps -o pid=,ppid=,pgid=,%cpu=,rss=,etime=,command= -p "$daemon_pid"
footprint -p "$daemon_pid"
vmmap -summary "$daemon_pid"
```

The live acceptance used `/sessions`, pressed `n` twice, and took a footprint
after each new session. Two clients then selected the second record and proved
`2 present` before the provider turn. Every terminal and provider wait had an
outer timeout.

## Next experiment

Start the same release as a named diagnostic node. Capture `erlang:memory/0`,
the largest process heaps and mailboxes, ETS sizes, and
`instrument:carriers/0` at three cuts: listening, one session admitted, and the
same session after an idle minute. A diagnostic node boot with `-sname` was
confirmed during this investigation, but it was stopped before admission when
the investigation was handed off.

Repeat the three cuts with these catalogues:

1. No configured models.
2. One configured model.
3. The four-model Baseten example used above.

If `erlang:memory/0` grows with the OS footprint, sort all processes by
`process_info(Pid, memory)` and inspect the leading processes' heap sizes,
binary references and mailbox lengths. If BEAM totals remain small while
`instrument:carriers/0` grows, identify the allocator class and whether its
carriers remain reusable after the session retires. Use `tprof` in
`call_memory` mode only after those totals name a module or startup phase.

The investigation closes when one repeatable cut identifies the owner of the
roughly 944 MiB step and a matched before-and-after run proves the repair. The
repair must preserve one-daemon session isolation and cannot add a production
diagnostics endpoint solely for this investigation.

## Separate resource question

[Issue #283](https://github.com/Roasbeef/loom/issues/283) covers idle culling
for reusable `loom-exec` helpers. The daemon footprint reproduced here appears
without a live helper and scales with session admission, so helper retirement
must remain a separate change unless BEAM accounting supplies contrary
evidence.

## 2026-09-07, second pass: the owner, named

Status: **repaired**. The step is a term whose *flat* size doubles at every
hook-wrapping layer, copied into every process a session assembly spawns.

### What the BEAM cuts said

The prescribed cuts were taken with `scripts/daemon_memory_probe.sh`, which
boots the built release under a distribution name and collects
`erlang:memory/0`, ETS totals and per-process heaps from a separate node over
`rpc`. Nothing runs inside the daemon and no diagnostics endpoint was added.

Before the repair, with the offline release-smoke configuration (no models),
two admissions of which one is then stopped:

| Cut | RSS | `erlang:memory` total | of which `processes` | `ets` | `binary` |
|---|---:|---:|---:|---:|---:|
| Listening, no session | 92 MB | 55.8 MiB | 15.7 MiB | 1.07 MiB | 0.07 MiB |
| Two admitted, one stopped | 1,281 MB | 646.7 MiB | 597.7 MiB | 1.38 MiB | 2.93 MiB |
| After 60s idle | 547 MB | 618.8 MiB | 569.9 MiB | 1.38 MiB | 1.35 MiB |
| After a forced full collection | 644 MB | 542.8 MiB | 495.7 MiB | 1.38 MiB | 1.09 MiB |

That settles the four candidates the first pass left open. It is **process
heaps**: `processes` carries the whole step, ETS never leaves 1.4 MiB, and refc
binaries never leave 3 MiB. Allocator carriers were never measurable here —
`instrument:carriers/0` lives in OTP's `tools` application, which is not in the
release's closure, so every call answered `undef` — but the question they were
meant to answer is settled without them: the VM's own live total moves with the
resident set at every cut, before and after the repair, so there is nothing for
unaccounted carriers to explain. The gap between the two (1,281 MB resident
against 647 MiB live) is allocator retention and lag, and it shrinks with the
live number rather than independently of it. The step is also **reachable**,
not uncollected garbage —
496 MiB of it survives `erlang:garbage_collect/1` on every process. No single
process owns it and no process carries a raised `min_heap_size`; the cost is
spread over the twenty-odd processes one session assembly spawns, at 20–120 MiB
each. There is no `vm.args` in the release, no `ERL_FLAGS`, and no `spawn_opt`
anywhere in the tree, so no VM flag was ever a candidate.

### The term

Walking the heaviest process states (`scripts/mem_dig.erl`, injected into the
target node for one census) named it. Every heavy state descends the same way:

```
tuple/16 state                     261.9 MiB   (a supervisor's child specs)
 ...
 tuple/7 effects                    26.185 MiB
  tuple/12 hooks                    21.999 MiB
   fun {module,client@memory}       14.667 MiB
    tuple/12 hooks                  14.667 MiB
     fun {module,client@notes}       7.335 MiB
      tuple/12 hooks                 7.332 MiB
       fun {module,client@scheduleseam}  4.890 MiB
```

`runtime/effects.Hooks` has twelve function slots and is composed by wrapping:
`client/memory`, `client/notes`, `client/agency` and `client/scheduleseam` each
return `effects.Hooks(..hooks, slot: fn(…) { … hooks.slot(…) … })`. The closure
captures **`hooks`**, the whole record, while the new record separately carries
the other eleven slots. In place that costs nothing, because both references
share one structure. But BEAM does not preserve sharing when a term is copied
into another process — and every child spec, every `weft` actor and every
state machine of a session assembly is such a copy. Under flattening each layer
therefore *doubles*: four wrappers turn a base `Effects` of about 1.6 MiB into
26 MiB per copy, and twenty processes into most of a gigabyte. The halving down
the descent above is that doubling read backwards.

This is why the step was deterministic, why it arrived before any provider
request, why it scaled exactly with admission, and why the first pass saw dirty
untagged `VM_ALLOCATE` pages with ordinary malloc flat: process heaps come from
`mmap`, not from `malloc`.

### The repair

Four lines, one per wrapping site: bind the slot being wrapped to a local and
capture *that*, never the record it came from.

```gleam
let inner = hooks.run_start

effects.Hooks(..hooks, run_start: fn(operation) {
  list.append(inner(operation), injected(read(), clock))
})
```

The composed behaviour is identical — the same slot, the same call, the same
order — but the closure environment now holds one function instead of twelve,
so flat size grows by a constant per layer rather than doubling. Same cuts, same
configuration, same script, after the change:

| Cut | RSS | `erlang:memory` total | of which `processes` |
|---|---:|---:|---:|
| Listening, no session | 89 MB | 55.8 MiB | 15.7 MiB |
| Two admitted, one stopped | 317 MB | 223.1 MiB | 175.2 MiB |
| After 60s idle | 212 MB | 199.4 MiB | 151.6 MiB |
| After a forced full collection | 225 MB | 182.2 MiB | 135.5 MiB |

The admission step falls from 1,189 MB of RSS to 228 MB, and the reachable
heap a session adds falls from about 291 MiB to about 80 MiB. One copy of the
`Effects` record costs 6.6 MiB instead of 26.2 MiB. With the four-model Baseten
example — the catalogue the first pass measured at 1,900 MB for two sessions —
the same two admissions now reach 653 MB.

### What remains

The residue is the same shape, one layer down and an order of magnitude
smaller. `client/gateway.tap_provider` and its preview sibling each build an
`effects.PreparedProviderSurface` whose `request` and `prepare` closures both
capture the surface they wrap, so two layers of provider wrapping double twice:
`prepared_provider_surface` is now the heaviest child of `Effects` at 2.8 MiB
per copy. Removing it needs the two closures to share one captured value rather
than a one-line change, and 2.8 MiB per copy is not yet worth that shape, so it
is recorded rather than taken.

Two smaller notes for whoever measures next. `erlang:memory/0` reports what is
live; the resident set lags it by tens of seconds and by allocator retention,
so the OS number alone will keep suggesting a leak where there is none — read
both. And `scripts/mem_dig.erl` allocates on the target node while it walks, so
it runs after every cut rather than between two of them; an earlier run that
interleaved it reported a 398 MiB `erpc` process that was the probe itself.

### The general rule

In Gleam, `Record(..existing, field: fn(...) { existing.field(...) })` is the
idiomatic way to wrap one slot of a record of closures, and it is a memory
trap whenever the record crosses a process boundary. Capture the slot, not the
record. `make lint` does not check this today; the four sites are commented so
the next reader of any of them meets the reason.


## 2026-09-14: imported-hook composition multiplies the effects again

The earlier repair did not cover `client/hookserve.wire`. Its three hook
wrappers captured the entire `Hooks` record and its two tool wrappers captured
`ToolSurface`. When the effects cross into supervisor and worker processes,
those captures copy unrelated closures along with the one function being used.
An isolated diagnostic release found 25.666 MiB of flattened hooks in a
44.660 MiB effects value after three ordinary model turns. One imported-hook
wrapper accounted for 6.438 MiB, of which 6.425 MiB was its captured record.
The supervisor state had a flattened copy size of 446.685 MiB.

Bind each wrapped function before creating its closure. This preserves the
hook ordering, refusals, accounting, and replay behavior while removing the
unrelated slots from each capture. The same inspection found two smaller
instances: the compaction projection captured `wiring.Config` to read only its
session, and the output observer captured `ToolRun` to read four identity
fields. Both now bind those inputs before constructing the callback.

### Measurement and limits

The baseline diagnostic release was built from `77b39805`. For the first
comparison, the same release had only `client@hookserve.beam` replaced by the
module compiled on `fix/hook-memory-retention`, based on `7cacb150`. Each
isolated daemon admitted two offline sessions, stopped one, then stopped the
remaining resident before admitting a model-backed session. Three prompts
asked the same configured model to inspect a toy Python project and run its
tests, add empty-input handling and tests, then review and run the tests again.
The resulting edits passed independent Python test runs. Model responses and
tool sequences differed, so this measures two comparable workloads rather
than an identical replay or a general latency improvement.

All figures below are MiB reported by `erlang:memory/0`, not OS RSS.

| Cut | Baseline total | Hook-wrapper fix total | Baseline processes | Hook-wrapper fix processes |
|---|---:|---:|---:|---:|
| Two offline admissions, one stopped | 422.728 | 225.771 | 371.607 | 175.471 |
| After three model-backed turns | 1511.755 | 695.782 | 1446.404 | 638.783 |
| Subsequent idle observation | 1510.979 | 683.070 | 1446.270 | 626.951 |
| After explicit diagnostic collection | 1097.795 | 495.390 | 1042.732 | 441.312 |

The explicit collection was a separate experiment on the isolated daemons,
after the normal observations; it is not an automatic production behavior.
The roughly 54% lower total after the three turns belongs to the hook-wrapper
change alone. The final three-module patch has not had the model-backed
comparison repeated. The existing user's daemon was neither collected nor
restarted, so its exact retained owners remain unmeasured. Substantial process
memory remains in the isolated workload and needs a fresh census after this
repair; the measurements do not establish that every excessive capture is gone.

Regression tests enlarge unrelated hook slots, configuration fields, and tool
arguments and assert that the affected callbacks' flattened copy sizes stay
constant. The size probe is test-only `erts_debug:flat_size/1`; no production
FFI or public interface was added. Restoring the old imported-hook capture,
compaction projection capture, and output-observer capture independently made
the corresponding assertions fail, and restoring the fixes made them pass.
The final client gate passed all 1,800 tests. Independent review checked the
capture boundaries and the negative/positive test results.


## 2026-09-16: supervisor restart inputs and provider facades

The installed daemon still retained large session supervisor states after a
full diagnostic collection. One supervisor reported 81.633 MiB of allocated
process memory. A read-only, external inspection of its state found 157.273 MiB
of flattened copy cost, descending through a runtime startup callback, its
`Config.strand_options` builder, and a 15.718 MiB `Effects` value. The largest
provider descendant was 7.330 MiB, with successive gateway wrapper captures
of 3.665 MiB and 1.832 MiB. The inspected daemon ran build `2b09671`; the repair
branch starts at `7662215415a74de5b4ca7a0547b637a21d20e41d`.

These measurements describe different quantities. `process_info(memory)` and
`erlang:memory/0` report allocated memory, including unused process heap
capacity. A full collection removes collectable garbage but does not make
those counters an exact reachable-term size. `erts_debug:flat_size/1` measures
copy cost with sharing removed; `erts_debug:size/1` accounts for sharing in
the inspected term. An RPC copy can already have lost the original sharing.
The earlier sections' use of "live" or "reachable" for the entire post-GC
process-memory total was too strong.

### Repairs and regression evidence

The runtime now projects `Options` and `Config` fields before constructing
restart closures. Publication and the booter need the subagent classifier,
not the entire effects-bearing driver builder. The factory needs that builder,
not the writer's subscribers and callbacks. A regression starts real session
trees and grows a writer-only subscriber list by 4,096 entries. The original
supervisor state adds 983,040 flattened words; the repaired state adds 98,304.
On this 64-bit OTP 29 build, the marker's contribution falls from 7.5 MiB to
0.75 MiB. Two copies remain because OTP stores both initial specifications and
the active child map. This is a fixture measurement, not the installed daemon's
memory reduction.

`extension/hooks.wire` now captures each of its five wrapped hook functions
and two wrapped tool functions individually. Growing an unrelated hook made
the original `run_start` wrapper grow from 495 to 20,976 flattened words.
The repaired wrappers retain constant copy cost for that unrelated payload.
The test also checks that the payload remains reachable through its own slot.

Provider observation now composes one projected preparation capability and
its timeout. Both outward facades use that capability, while a relay's startup
state holds only the preparation function it can call. The previous first
wrapper added 41,047 words for a 4,096-element marker. Each repaired layer adds
less than 1,024 words in the fixture, including the preview layer. Existing
request/prepare entry points, parked publication, cancellation, and drain
ordering remain in place. Preview observer construction still happens in the
observer process.

An isolated post-repair probe also compared shared and flattened word counts.
The same 4,096-element provider payload passes through ordinary, preview, and
ordinary observation layers:

| Provider surface | Shared words | Flattened words |
|---|---:|---:|
| Base | 8,214 | 40,990 |
| One ordinary observer | 8,248 | 41,058 |
| Then one preview observer | 8,257 | 41,120 |
| Then another ordinary observer | 8,269 | 41,188 |

Each layer adds 62 or 68 flattened words in this fixture. Its small shared
size alone would have hidden the earlier duplication. The separately started
supervisor fixtures reported 21,960 and 602,176 allocated bytes after a full
collection for zero and 4,096 subscribers. Their externally copied states
contained 3,821 and 102,125 flattened words. Those counters need not agree:
heap capacity and copying affect them differently.

### R12 audit and the remaining candidates

The source audit classified all 90 warnings at the branch base: 11 confirmed
retention boundaries, 35 candidates requiring a size measurement, nine small
sites, and 35 dismissals. The confirmed set comprises the four runtime warnings
and seven extension hook/tool warnings repaired here. The repair also covers
an unflagged booter capture, the provider facade chain, and one small capture
in the relay's returned begin callback. R12 falls to 78 warnings; its syntactic
scope and warning severity are unchanged.

The remaining candidates include job and schedule door layers, code-mode
workspace closures, and extension routing. Their process lifetimes make them
worth measuring, but the audit does not establish their contribution to the
installed daemon. Request-scoped capability plans, simulation callbacks,
small one-field handles, and local predicates do not justify a mechanical
warning cleanup. The complete base-line inventory and per-site dispositions
are recorded in the [review inventory](../review/closure-retention.md).

### Mailboxes, temporary work, and the next measurement

An OTP 29 `+recv_opt_info` check of generated runtime, provider, relay, and weft
code traced receives to `gleam_erlang_ffi`. Its generic selector and subject
receives report `NOT OPTIMIZED`: the fresh-reference relationship is hidden
across the FFI boundary. The match-any flush is reported as always fast. These
diagnostics identify a potential scan cost, not a demonstrated backlog. The
inspected loops are tail recursive and normally reuse selectors. Provider and
relay work already has request-scoped owners, deadlines, and cancellation;
no measured temporary allocation owner justifies another worker layer here.

After installing the repair and starting fresh session trees, compare the
same empty, admitted, idle, and post-collection cuts. Record process-memory
and mailbox lengths before inspecting selected state terms. Restrict state
copies to one owner at a time: the external probe's second large copy exceeded
its 512 MiB heap limit, although its first state trace completed. No probe
module was loaded into the installed daemon. The live source of the retained
graph is identified, but this patch has not yet been installed or measured
against that daemon's current sessions.

Keep ordinary observations separate from explicit diagnostic collection.
Heap-size flags, periodic GC, and `persistent_term` do not address these
unnecessary copies and were not added. Shared storage would need its own
lifetime and update-cost argument. The next acceptance measurement is the
actual admitted-session cost after the repaired build starts those trees.


### Validation

The full `make check` gate passed with exit status zero, including 140 runtime,
222 provider, 1,852 client, and 558 TUI tests. Documentation checks passed with
zero errors. Lint reports zero errors, 804 warnings, and 78 R12 findings.
The default gate reports unseeded code-mode/extension, opt-in packaged-daemon,
and platform-specific skips; those extra lanes were not exercised here.
Independent source review found no production correctness issue. Its two test
and comment-format findings were corrected before the final gate.


## 2026-09-16 refreshed daemon and socket captures

The installed daemon's BEAM code checksums match the initial repair in
`runtime/api`, `runtime/supervisor`, `client/hookserve`, `client/gateway`, and
`client/wiring`. After the operator updated and restarted it, an ordinary
observation at 01:02 UTC on September 17 reported 1,311.180 MiB total VM memory,
1,263.032 MiB process memory, and 10.722 MiB binaries. Allocator instrumentation
was available in this build: eheap carriers occupied 1,274.016 MiB, with
1,260.211 MiB scanned allocation. This was an active workload, without an
explicit collection. It is not a matched before/after measurement of the
preceding patch: the resident process counts and workload differ.

A bounded external inspection of one large gateway found a 45.803 MiB
flattened state. One connection contributed 21.863 MiB through authentication
callbacks. Each callback retained a 10.931 MiB attachment containing the
resolved instance, runtime, effects, and hook/tool closures. The WebSocket
handler also captured that attachment even after its admission phase ended.
The inspection printed sizes and term shapes, not credential or transcript
values, and loaded no probe module into the daemon.

`session_socket.upgrade` now projects the attachment into a private record
containing the immutable gateway binding, original parser permit, and registry
handle before constructing transport callbacks. The hub was already selected
by the router. Permit transfer, gateway monitoring, and repeated registry
authorization still use the original identities and owners; no authorization
answer is cached. Reader failure retains its incarnation-checked stop path.

A real WebSocket regression varies an unused runtime hook payload by 8,192
list elements. Before the repair, the hub's attachment growth rose from 3,576
to 118,264 words. The repaired capture passes the bounded-growth assertion,
and all ten socket transport tests pass. This proves independence from the
unused runtime payload, not an installed total-memory reduction. Fresh
installed socket and admission measurements remain necessary.

The follow-up full `make check` completed with exit status zero: 1,853 client,
558 TUI, and 304 code-mode tests passed, including the real TUI end-to-end
fixture. The opt-in shipped-daemon fixtures and Linux-only MCP death check
remain skipped on this macOS run. Documentation checks report zero errors;
lint remains at zero errors, 804 warnings and 78 R12 findings. Independent
review of the follow-up found no correctness defect.


## 2026-09-16 production verification after PR #438

A non-collecting observation of the installed `eadc0587` daemon measured
960.9 MiB RSS, 1,124.645 MiB BEAM allocation, and 1,074.903 MiB process
memory. Binary memory was 12.333 MiB; ETS accounted for 1.041 MiB. Process
heaps dominate this cut. Workload and collection history differ from the
previous observation, so the lower total is not a causal PR-wide saving.

The socket fix is visible in production: each of five transport callbacks in
three inspected connections flattened to approximately 0–1 KiB. The earlier
whole-attachment callback flattened to 10.931 MiB. This validates the capture
boundary directly without attributing the whole daemon delta to it.

Static supervisors still allocated 244.920 MiB, factory supervisors 81.714
MiB, and state machines 126.773 MiB. One supervisor child specification
contained a 10.946 MiB flattened Effects value, including 5.038 MiB of hooks.
An advisor/wiring descendant retained a 0.981 MiB configuration dominated by
a 23-entry tool registry. These are copy-cost measurements, not additive
estimates of reclaimable resident memory. Narrowing hook inputs and measuring
restart closure fanout are the next candidates; neither saving is proven yet.

A 60.121 MiB actor exposed only 18 KiB of application state through
`sys:get_state`. In pinned Weft 0.4.4, that interface omits the loop handler,
shutdown callback, selectors and timers. The difference therefore cannot be
classified as garbage without inspecting those roots or collecting in a
controlled experiment. No forced collection, restart, hot patch or target-side
probe-module load was performed for this observation. Existing attached clients
predated PR #438, so their measurements cannot validate the new client build.

The optional [BEAM memory review skill](../../.claude/skills/beam-memory-review/SKILL.md)
records this distinction and a repeatable ownership and copy-cost review.


## 2026-09-17 resident assembly host capture

The live investigation identified two persistent `instance_host` processes
allocating approximately 45.7 MiB each. Their retained builder closures captured
the daemon manager book, including two earlier resident instances. This is a
reachable ownership defect; the allocated heap totals are not a prediction of
what this repair will reclaim.

`manager.prepare_domain_slot` now binds the command subject and assembly
callback before constructing the builder. `prepare_shared_domain` likewise
projects `domain_build` before constructing its persistent builder. Domain
service lookup still occurs inside assembly with the same session and operation
identity. The host's publication, failure, and custody protocols are unchanged.

The regression opens three real hosts, each publishing an 8,192-element list.
On the original capture, the first host state flattened to 369 words and the
second to 16,996 words, exceeding the permitted 256-word variation. With the
projected inputs, the bounded-growth assertion passes for both later hosts.
The expanded regression also detects the domain-host variant: before its
projection, the second domain host flattened to 16,868 words versus 240 for
the first. Both host types pass after projection. All 27 manager tests pass,
including publication and retirement coverage. This establishes independence from earlier resident payloads. It does not
measure installed RSS or total VM savings; the production daemon has not been
updated for this repair.


## 2026-09-19: the remaining cost is copies of `Effects`, not one bad capture

An observation of the installed daemon (build `a65aa2f0`, 22h41m resident, six
sessions attached) was taken through the profiled node's attach line with
`scripts/mem_report.erl`. No collection was forced, no probe module was loaded
into the daemon, and every measurement is an `rpc` call of a standard OTP
function.

| Quantity | Value |
|---|---:|
| RSS (`ps`) | 2,242,736 KiB |
| `footprint` untagged `VM_ALLOCATE` | 2,120 MB |
| `footprint` all `MALLOC` classes | about 45 MB |
| `erlang:memory` total | 2,599.003 MiB |
| of which `processes` | 2,531.528 MiB |
| `system` | 67.475 MiB |
| `binary` | 29.043 MiB |
| `code` | 17.018 MiB |
| `ets` | 1.304 MiB |

`instrument:carriers/0` was available in this build: `eheap_alloc` held
2,577.766 MiB of carriers against 2,552.325 MiB of scanned allocation, and all
allocators together held 2,700.078 MiB. ETS was 63 tables and 1.131 MiB, there
were 28 ports, and 437 live processes carried 2,518.178 MiB of heaps. Nothing
outside process heaps is material at this scale.

Grouped by initial call, heaviest first:

| Group | Total | Processes |
|---|---:|---:|
| `weft@actor` loop | 1,365.037 MiB | 104 |
| `gleam@otp@static_supervisor` | 575.629 MiB | 15 |
| `weft@state_machine` loop | 311.397 MiB | 38 |
| `gleam@otp@factory_supervisor` | 192.948 MiB | 12 |
| `gleam@otp@actor` | 28.033 MiB | 65 |

### Which sessions own it

That table names shapes of process, not owners, so the processes were regrouped
by the ancestor just below the daemon's own supervision spine, which partitions
them by session assembly. The figures below are one cut, taken about thirteen
minutes after the `erlang:memory` numbers above; an earlier cut of the same six
assemblies totalled 2,322.687 MiB against this one's 2,324.358 MiB, so the
workload moved them by well under one percent.

| Session | Heap | Processes | Heaviest roles |
|---|---:|---:|---|
| 1 | 514.451 MiB | 76 | weft actors 314.302 over 19; static supervisors 96.046 over 2; factory supervisors 31.631 over 2 |
| 2 | 415.257 MiB | 51 | weft actors 259.289 over 18; static supervisors 95.896 over 2; factory supervisors 34.794 over 2 |
| 3 | 409.874 MiB | 46 | weft actors 253.397 over 16; static supervisors 95.733 over 2; factory supervisors 31.631 over 2 |
| 4 | 375.437 MiB | 40 | weft actors 229.060 over 15; static supervisors 96.053 over 2; factory supervisors 31.631 over 2 |
| 5 | 316.142 MiB | 38 | weft actors 168.234 over 15; static supervisors 95.792 over 2; factory supervisors 31.631 over 2 |
| 6 | 293.197 MiB | 38 | weft actors 149.458 over 15; static supervisors 96.082 over 2; factory supervisors 31.631 over 2 |

Six assemblies hold 2,324.358 MiB over 289 processes. Six further
`weft@state_machine` processes, one per session, are 15.818 MiB each to the
byte — the clearest single sign that these are per-instance copies of one value
rather than divergent state.

**Corrected on 2026-09-20.** There are twelve of those, not six: two per
session, and they are two different modules that happen to retain the same
value. Six are `client/internal/instance_owner` and six are
`client/schedulescan`. The 2026-09-20 section names the field in each.

### The cost is concentrated in 85 processes

Per-process memory does not spread evenly, and an average over a session's
processes misleads:

| Bucket | Processes | Heap |
|---|---:|---:|
| at least 100 MiB | 1 | 117.533 MiB |
| 50 to 100 MiB | 10 | 560.265 MiB |
| 20 to 50 MiB | 36 | 1,182.665 MiB |
| 10 to 20 MiB | 38 | 607.361 MiB |
| 5 to 10 MiB | 4 | 34.860 MiB |
| 1 to 5 MiB | 10 | 27.729 MiB |
| under 1 MiB | 360 | 15.357 MiB |

The 85 processes above 10 MiB carry 2,467.8 MiB, which is 96.9% of the total,
while the median process is 0.011 MiB.

### How much of that is live

A forced collection was not run on the installed daemon, so live and merely
uncollected heap cannot be separated outright. One distinction is available
without collecting anything: a hibernating process has already been compacted
by the VM, so for those processes the reported memory is live data. Thirty-five
processes were hibernating and held 575.663 MiB; 424 were awake and held
1,970.107 MiB.

The generational split says more, and reading it correctly matters.
`process_info(Pid, garbage_collection)` does **not** carry `old_heap_size`; that
key is in `garbage_collection_info`. Asking the first one reports a zero old
generation for every process, which inverts the conclusion, since the old
generation is exactly the part a minor collection never examines. Over all 440
processes in a later cut totalling 2,611.821 MiB:

| Region | Size |
|---|---:|
| young generation | 1,532.316 MiB |
| old generation | 546.674 MiB |
| heap fragments | 532.390 MiB |

Mailboxes were empty and stacks negligible throughout, so none of this is
backlog. The six hibernating supervisors have their whole heap in the young
generation with no old generation and no fragments, which is what compaction
leaves behind. A representative awake `weft@actor` at 53.727 MiB, by contrast,
holds 6.355 MiB young, 29.219 MiB old and 18.152 MiB of fragments.

What this does and does not license: a full sweep would examine the 1,079 MiB
of old generation and fragments that minor collections leave alone, and the
fragments in particular are merged at the next collection. But data reaches the
old generation by surviving a minor collection, so much of that 547 MiB is
likely live. The 1,079 MiB is the heap a full sweep would look at, not a
reduction it would deliver.

### What one assembly process retains

One bounded `sys:get_state` on a single hibernating session supervisor, with
every measurement taken on the probe node rather than in the daemon, names the
value. Only one such copy was taken for the whole investigation: an earlier
probe that walked a second large state exceeded its own heap.

```
tuple/16 state                          105.144 MiB
 map/11 (eleven children)                52.572 MiB
  child -> fun client@serve index 143    13.898 MiB
   tuple/7 runtime                       12.874 MiB
    tuple/7 effects                      12.869 MiB
     tuple/12 hooks                        6.963 MiB
      fun client@wiring index 8            1.946 MiB
       fun client@wiring index 6           0.981 MiB
        tuple/23 config                    0.981 MiB
         tuple/3 registry                  0.961 MiB
```

The state flattens to 105.144 MiB against 52.572 MiB of children because OTP
keeps both the initial child specifications and the active child map. The
heaviest child specification is 13.898 MiB, descending through a `client/serve`
startup closure into a 12.874 MiB `Runtime` and a 12.869 MiB `Effects`. Within
that, `Hooks` is 6.963 MiB and **no single slot dominates it**: the heaviest is
1.946 MiB of 6.963. That even spread is what a record looks like after the
earlier repairs have done their work, and it is why no further capture
narrowing was taken here.

The `wiring.Config` that PR #456 stops capturing is 0.981 MiB of that
descent, almost all of it a 0.961 MiB tool registry. The repair is correctly
shaped and worth having; it is also about 7.6% of one `Effects` copy, so it was
never going to move a 2.6 GB total on its own.

The heavy `weft@actor` processes were identified from their backtraces, read
over `rpc` with `process_info(Pid, backtrace)` rather than by copying their
states. They are `client/gateway` actors, and the `runtime` field of
`gateway.State` holds an `api.Runtime`, which carries the session, the session
id and the whole `Effects` graph. The gateway dispatches operations, so it
needs that runtime; this is ownership, not a mis-scoped capture.

### The candidates this closes

The 0.961 MiB registry figure settles the list the R12 audit carried forward,
because all three candidates live inside that registry:

- **Extension routing.** The observed daemon had one installed extension
  declaring one tool, so `extension/dispatch.tool_for`'s capture of the whole
  dispatch configuration is multiplied by one, and its registry entry is a
  fraction of 0.961 MiB. The shape is real and would matter to a host with many
  extension tools. It cannot contribute materially here.
- **Job and schedule door layers.** The multiplication factors are real — five
  copies of `jobseam.Wiring` per door, nine of `scheduleseam.Wiring` — but both
  records are a few dozen words over operator configuration, and both sit
  inside the same 0.961 MiB. They multiply kilobytes.
- **Code-mode workspace closures.** `client/codemode.workspace_seam_with_access`
  captures its `Config` in three schedule closures and its `Access` in four
  filesystem closures where a projection would do. The resulting `Workspace`
  belongs to one code-mode execution and is dropped with it, so it is absent
  from a census of resident sessions by construction.

None of the three was patched. Each is dismissed by a measurement rather than
by argument.

### What is still unattributed

Two things in this census are not explained.

The single largest process, a `weft@state_machine` at 117.533 MiB, has no
attribution. In pinned weft 0.4.4 `sys:get_state` omits the loop handler,
shutdown callback, selectors and timers, which is where an actor's retention
lives, so the interface that would name it returns the wrong part of the
process.

**Withdrawn on 2026-09-20.** That process is now attributed: it is the session
admission registry, and `sys:get_state` names it outright, because 77.152 MiB of
its 117.5 MiB is the `#(state, data)` pair that the call does return. The
caution about the omitted fields is correct in general and was wrong about this
process in particular. The 2026-09-20 section below has the measurement.

The live-versus-uncollected split of the 424 awake processes holding
1,970.107 MiB is unknown. Settling it needs a forced collection, which was
deliberately not performed on a daemon holding real sessions.

### Two options, neither yet justified

The next reduction has to remove copies rather than shrink them. Two shapes
would do that, and the measurement above supports neither over the other.

The first is a per-session owner for `Effects`: hold the graph in one process
and hand each child a handle it resolves on use. This reaches
`runtime/effects.Effects` and `runtime/api.Runtime`, which are WP-E's assembly
surface as consumed by the client. **Neither type is enumerated among the
frozen contracts of spec Part 1** — Part 1 freezes the core types, the storage
behaviour, the pure machine signatures, the effect-plane wire protocol, the
provider gateway and the client protocol. A `protocol-change/NNN.md` would
still be the right way to propose this, as a matter of judgment, because the
value crosses a package boundary that every session assembly depends on, not
because Part 1 compels it. Its costs: every effect call gains a message round
trip or a table read on a hot path, the owner becomes a per-session
serialization point and a new failure domain needing its own restart custody,
and recovery plus the interleaving harness need scenarios for an owner dying
mid-dispatch.

The second is an idle-hibernate policy in `weft/actor`, which needs no
interface change at all. The evidence for it is the generational split: awake
assembly actors carry most of their heap outside the young generation, and
hibernation is a full sweep followed by a shrink. Its costs: hibernation forces
a full sweep on every wake, so a frequently messaged actor would thrash; the
policy needs an idle threshold nobody has chosen; and weft is a sibling
repository, making this a cross-repo change with its own release.

An attempt to size that option on a locally built daemon did not succeed, and
the reason is worth recording. A release daemon was started with its own state
directory and an overridden `HOME`, one session was admitted through the
release's own control-plane acceptance and left idle for 45 seconds, and the
same 152 processes were measured before and after a major collection of every
one of them. Memory went from 73.969 MiB to 78.590 MiB — a collection that cost
4.6 MiB rather than returning any. Per role: the five static supervisors were
unchanged at 22.331 MiB, already compact; seven weft state machines fell from
17.200 to 14.249 MiB; thirteen weft actors *rose* from 23.428 to 28.282 MiB,
because a full sweep sizes a fresh heap by a growth policy rather than to the
live data exactly.

The experiment measured the wrong condition rather than refuting the option.
A freshly admitted offline session has run almost no minor collections, so it
has promoted almost nothing into an old generation and has no accumulated
fragments; there is nothing for a sweep to find. The installed daemon's actors
reached their old generations over 22 hours of real model turns. Sizing this
option therefore needs a local daemon driven through many real provider turns,
not an idle one, and that is a longer experiment than a census. Until it is
run, an idle-hibernate policy in `weft/actor` is not justified by measurement.

## 2026-09-20: the largest process is the admission registry

The 117.5 MiB `weft@state_machine` that the previous section left unattributed
is the daemon's session admission registry, `client/daemon/manager`. Its
`Book.slots` dictionary (`packages/client/src/client/daemon/manager.gleam:651`)
holds one `Slot` per resident session, and each slot's `phase` field
(`manager.gleam:257`) carries `Occupancy.Running(instance)`
(`manager.gleam:234`), where `instance` is a whole `client/serve.Instance`
(`packages/client/src/client/serve.gleam:464`) and therefore a whole
`api.Runtime` and the `Effects` graph beneath it. Six resident sessions put six
of those in one process. Nothing about the registry is unusual: it is the
largest process in the daemon because it is the only one that holds one copy per
session rather than one copy, which is also why the per-assembly grouping could
not place it — it belongs to all six assemblies at once.

This is the same value the 2026-09-19 section already named, counted six times
in one heap. It is not a further capture to narrow, and no new retention bug is
reported here.

### How it was observed

The daemon was the same incarnation as the 2026-09-19 census: PID 53978, build
`a65aa2f0`, started 2026-09-18 18:40, 1d05h41m resident at the first read, six
sessions attached. Observation only. No collection was forced on it, no module
was loaded into it, and every measurement is an `rpc` call of a standard OTP
function from a separate hidden probe node attached through the release's own
`loom-profile` arrangement, which puts the profile cookie in the probe's `HOME`
so that it never appears on a command line.

The VM at this observation, beside the day before:

| Quantity | 2026-09-19 | 2026-09-20 |
|---|---:|---:|
| `erlang:memory` processes | 2,531.528 MiB | 2,643.775 MiB (`processes_used`) |
| `system` | 67.475 MiB | 78.349 MiB |
| `binary` | 29.043 MiB | 39.953 MiB |
| `code` | 17.018 MiB | 17.018 MiB |
| `ets` | 1.304 MiB | 1.302 MiB |
| live processes | 437 | 455 |
| process heaps | 2,518.178 MiB | 2,629.825 MiB |

Grouped by `proc_lib` initial call, `weft@actor` holds 1,497.314 MiB over 108
processes, `gleam@otp@static_supervisor` 575.629 MiB over 15,
`weft@state_machine`'s loop 309.131 MiB over 37, and
`gleam@otp@factory_supervisor` 193.022 MiB over 14. The shape of the daemon has
not changed in a day; it grew by about 112 MiB, all of it in process heaps.

### The process

| Quantity | Value |
|---|---|
| pid | `<0.131.0>`, so created at daemon boot, before any session |
| `registered_name` | none |
| `initial_call` | `{proc_lib, init_p, 3}` |
| `$initial_call` | `{weft@state_machine, '-start/1-anonymous-1-', 0}` |
| process dictionary keys | `'$initial_call'`, `'$ancestors'` |
| `current_function` | `gleam_erlang_ffi:select/2` |
| `current_stacktrace` | `weft@state_machine:run/1`, under `proc_lib:init_p/3` |
| `status` | `waiting` |
| `trap_exit` | `true` |
| `message_queue_len` | 0 |
| `stack_size` | 10 words |
| `reductions` | 641,721,867, rising 181,964 over 30 seconds |
| `memory` | 117.508 MiB |
| `heap_block_size` | 15,401,305 words (117.524 MiB) |
| `heap_size` | 13,519,608 to 14,422,717 words (103.1 to 110.0 MiB across reads) |
| `old_heap_size`, `old_heap_block_size` | 0 |
| `mbuf_size` | 232 to 638 words |
| `minor_gcs` | 0 |
| `fullsweep_after` | 65535 |
| `min_heap_size` | 233 words |
| links | 13 |
| monitors | 12 |
| `monitored_by` | 26 |

The spawn chain in `$ancestors` is pids 130, 129, 125 and 86, all daemon-boot
processes of a few kilobytes, so the chain records weft's startup rather than a
supervision path. The thirteen links are twelve weft witnesses, one per live
slot, plus the spawn parent, and the twelve monitors are those same witnesses.
That fan-out of twelve identified this as a per-slot registry before its state
was read at all.

### The field

One `sys:get_state`, reduced to sizes and constructor names in the expression
that received it. The state element of the pair is the atom `ready`, which is
`manager.Phase.Ready`; the data element is the eleven-field `Book`
(`manager.gleam:644`):

| `Book` field | Shape | Flat size |
|---|---|---:|
| `catalogue` | `tuple/2` | 0.000 MiB |
| `assembly` | `tuple/5 assembly` | 0.001 MiB |
| `limit` | integer | — |
| `epoch` | 64-byte binary | — |
| `next` | integer | — |
| `slots` | `map/6` | **77.138 MiB** |
| `failed_operations` | `map/0` | 0.000 MiB |
| `domains` | `map/6` | 0.011 MiB |
| `commands` | `tuple/3 subject` | 0.000 MiB |
| `parent` | pid | — |
| `authority` | `map/6` | 0.002 MiB |

The whole pair flattens to 77.152 MiB, of which `slots` is 77.138 MiB. Every
other field is at most 0.011 MiB, `assembly` among them: the four assembly
closures cost about a kilobyte, so the capture narrowing of PRs #438 and #441 is
holding here.

The six slots are 12.880, 12.879, 12.877, 12.851, 12.836 and 12.814 MiB, mean
12.856 MiB, and within each one the size sits in a single field:

| `Slot` field | Shape | Flat size |
|---|---|---:|
| `domain_id` | 41 to 80-byte binary | 0.000 MiB |
| `host` | `tuple/4 host` | 0.000 MiB |
| `operation` | 66 to 67-byte binary | 0.000 MiB |
| `phase` | `tuple/2 running` | **12.813 to 12.879 MiB** |
| `watch` | reference | 0.000 MiB |
| `results`, `faults`, `failures` | `tuple/3 subject` | 0.000 MiB each |

Descending the heaviest slot reaches the graph the earlier sections describe,
this time through the registry rather than through a supervisor's child
specification:

```
map/6 (six slots)                        77.138 MiB
 tuple/9 slot                            12.880 MiB
  tuple/2 running                        12.879 MiB
   tuple/16 instance                     12.879 MiB
    tuple/7 runtime                      12.878 MiB
     tuple/7 effects                     12.872 MiB
      tuple/12 hooks                      6.965 MiB
      tuple/5 tool_surface                3.943 MiB
      tuple/4 prepared_provider_surface   1.964 MiB
```

The registry holds the instance because `Resolve` hands it back: `resolve` reads
`Slot(phase: Running(instance), ..)` out of the dictionary and replies with it
(`manager.gleam:1473`).

### The memory is live, and it is not binaries

Two readings that these numbers rule out, both of which a census can reach for
by default.

It is not garbage waiting for a major collection. `minor_gcs` is 0 while
`old_heap_size` and `old_heap_block_size` are both 0 and `min_heap_size` is 233
words against a 15,401,305-word block. A process heap only grows during a
collection, so this heap has been collected many times, and `minor_gcs` counts
minor collections *since the last full sweep* — zero means the most recent
collection was a full sweep, which is also why there is no old generation to
report. Between 103.1 and 110.0 MiB survived that sweep, and 77.152 MiB of it is
the reachable `#(state, data)` pair. Forcing a collection on the operator's
daemon would not have added to this, and it was not done.

It is not off-heap binary pinned by a small reference, and the key that suggests
otherwise is a trap worth recording. `process_info(Pid, binary)` reports 664,553
references totalling 71.946 MiB for this process, which reads like 72 MiB of
pinned payload. Those references point at **982 distinct underlying binaries**:
the mean reference count from this one process is 676.7, the median is 54,486 and
the maximum is 256,557, so the key sums each binary's size once per reference and
overcounts by roughly three orders of magnitude. The whole VM's `binary` figure
of 39.953 MiB bounds the real payload. The sizes are small — 8 bytes minimum, 21
median, 38 at the ninetieth percentile, 113.5 mean, 44,572 maximum, with 615,551
of the references at 64 bytes or less. What the heap holds is a structure
containing about 664,000 references to a few hundred short strings, which is the
expected shape of six copies of a tool registry, a hook registry and an assembled
prompt. **Sum `process_info(Pid, binary)` by distinct pointer, never by
reference.**

### It grows per resident session, not per turn

| Cut | Process memory |
|---|---:|
| 2026-09-19 census | 117.533 MiB |
| 2026-09-20, three separate attaches | 117.508 to 117.512 MiB |
| 2026-09-20, 30 seconds apart on one attach | 117.509 MiB, then 117.509 MiB, over 181,964 reductions |

Over 23 hours of real model turns, during which the daemon's process heaps grew
by about 112 MiB, this process did not move. The growth law is one `Slot` of
about 12.86 MiB flat per resident session, inserted at admission
(`manager.gleam:2071`) and deleted when the reservation drains
(`manager.gleam:2818`), or about 19.6 MiB of process heap per session once the
heap block is counted. It is constant in turns, constant in conversation length,
and linear in resident sessions.

That makes it capacity-bounded rather than a leak. `Book.limit` is the daemon's
`--capacity`, which defaults to 8
(`packages/client/src/client/daemon/main.gleam:203`) and is refused outside 1 to
1024 (`main.gleam:230`). The operator's `~/.loom/loom.toml` sets no capacity, so
the default applies: this process's ceiling on the running configuration is about
8 × 12.86 MiB of state, and the six observed slots are three quarters of it. A
daemon configured near the maximum would give this one process room for about
13 GiB.

### The twelve processes beside it

Reading three of the twelve state machines at 15.81 to 15.82 MiB settles what
the 2026-09-19 section guessed at, and shows they are two modules rather than
one:

- **`client/internal/instance_owner`**, six of them. The data is the three-field
  `Book` (`packages/client/src/client/internal/instance_owner.gleam:96`) and its
  whole size is `cleanups`, a `map/7` keyed by the seven `Part` variants
  (`instance_owner.gleam:30`). One of the seven cleanup closures, a
  `client/serve` function, is 12.834 to 12.848 MiB of the 12.836 to 12.850 MiB
  total, because it captures the whole `api.Runtime` in order to drain it. The
  other six cleanups are free. This is the one shape among today's readings that
  looks narrowable: a closure that retires the runtime needs the drain door, not
  the runtime graph. It was not patched, and it is worth about one `Effects` copy
  per session.
- **`client/schedulescan`**, six of them. The data is the two-field `State`
  (`packages/client/src/client/schedulescan.gleam:362`) whose `runtime` field is
  an `api.Runtime` of 12.811 MiB, reached with no closure in between. The scanner
  runs scheduled turns, so it needs the runtime; this is ownership, as the
  module's own documentation says.

Both are per-session, so the daemon holds a per-session `Effects` copy in the
registry's slot, in the instance owner's cleanup closure, in the schedule
scanner's state, in the session supervisor's child specifications twice over, and
in the `client/gateway` weft actors. The registry is where all six sessions'
copies land together.

### What would bound it

Described, not implemented, and none of it justified by this measurement alone.

The narrowest change is to stop storing the value in the registry.
`Occupancy.Running` could carry the instance's owning pid or a `Subject` rather
than the `serve.Instance`, and `Resolve` (`manager.gleam:1473`) would ask that
owner instead of reading a map. The reference already exists: the slot holds
`host` and a monitor on the builder. The costs are real and on a hot path.
`resolve` becomes a call with a deadline where it is now a dictionary read, a
dead owner turns a prompt `Unavailable` into a timeout, and every caller that
wants one field of the instance gains a round trip. This is the narrow form of
the per-session `Effects` owner the previous section describes, scoped to one
consumer.

A weaker variant is to store a projection: if the callers of `resolve` need only
some of `serve.Instance`'s fifteen fields, the slot can hold that subset. This
needs a survey of those callers first, and it removes nothing if any one of them
wants the `api.Runtime`.

The general option the previous section sets out — one owner per session for
`Effects`, with handles resolved on use — subsumes both, and would collapse the
registry's six copies along with every other copy without touching the
registry's shape. Nothing here changes the argument for or against it.

### What this does not settle

The gap between the 77.152 MiB reachable pair and the 103.1 to 110.0 MiB of used
heap is about 30 MiB, and it was not split. Three things contribute and none can
be separated from outside the daemon: the fields of weft's `Self` that
`sys:get_state` does not return, which for this machine are the selector, the
event handler, the injected queue, the postponed list and the timer book;
garbage allocated since the last full sweep; and a representation difference,
because the daemon holds those 664,000 short strings as reference-counted
binaries while a copy over distribution rebuilds each one on the receiving heap,
so a flat size measured on the probe node is not the daemon's own layout. The
first could be sized with a probe module inside the daemon, which was not run
against a daemon holding real sessions.

No local reproduction was built. The growth law was measured directly on the
installed daemon — six slots, sized individually, varying by 0.5%, with the
process flat over 23 hours of turns — so the local step was not needed to settle
it. What a local daemon would still add is the slope measured at one and two
sessions rather than inferred from six slots plus the insert and delete sites,
and a forced collection to split the 30 MiB gap. Both want a daemon driven
through many real provider turns, which is the same experiment the previous
section says an idle-hibernate policy needs.




## 2026-09-20: option A evaluated — the cost was nine references, not one big value

This section evaluates the first of the two options above, a per-session owner
for `Effects`. An owner process is not needed. The prior question had an
answer: six of the nine references to the expensive value did not need it.
Narrowing those six cut the per-session cost of an admitted session by 56% on
a locally built daemon, with no new process, no new external function and no
interface change.

Everything below was measured on a release daemon built from this worktree,
started with its own `--state-dir` and its own `HOME`, both under the
worktree, against `scripts/release-smoke.toml` — a configuration whose one
model endpoint is `http://127.0.0.1:1`, so no request can leave the host and
no credential is involved. The operator's installed daemon was not touched,
attached to, or read.

### Two BEAM facts the arithmetic rests on

A copy between processes preserves no sharing for ordinary heap terms, but two
kinds of term are shared outright. Both were confirmed on this host and
runtime (OTP 29, ERTS 17.0.5, macOS arm64) with a small Erlang module that
sends a term to a fresh process and reads its heap growth:

| Term sent | Flattened words | Receiver's heap growth |
|---|---:|---:|
| A list of 2,000 cells over one literal tuple | 22,000 | 3,952 |
| The same shape built at run time | 22,000 | 28,457 |
| A 200 KiB refc binary | 8 | 0 |
| Two closures capturing one run-time-built value | 44,009 | 46,189 |

Literals live in a module's constant area and are not copied. Refc binaries
are shared. Run-time-built structure is duplicated, and duplicated **once per
closure that captures it**, even when those closures sit in one record and
share it perfectly in place.

The last row is the shape of this problem. The first two rows are why option
2a as written does not apply: a tool's description and its JSON schema are
compiled literals or refc binaries, so they were never being copied. Measured
directly, the five core tools' whole definitions flatten to 2,307 words, of
which 2,050 are schemas and 40 are descriptions. There is no static bulk to
move into `persistent_term` or into a binary. Nothing about the copy is
static, so nothing about it can be made shared that way.

### Where the 3.797 MiB went

One admitted session on the local daemon. Its `Effects` flattens to
3.797 MiB, against 3.143 MiB with sharing preserved. Field by field:

| Field | Flattened | What it holds |
|---|---:|---|
| `clock`, `entropy`, `timers` | under 0.001 MiB each | small |
| `provider` | 0.845 MiB | two relay closures at 0.422 MiB each |
| `tools` | 1.688 MiB | four closures at 0.422 MiB each |
| `hooks` | 1.264 MiB | three slots at about 0.413 MiB, eight negligible |
| total | 3.797 MiB | |

Every one of those 0.41–0.42 MiB figures is the same value: the session's
`wiring.Config`, which is 0.422 MiB of which 0.410 MiB is the tool registry.
Nine closures hold it, so a copy of `Effects` pays for it nine times.

The registry's own 0.410 MiB is the same shape one level further down. Per
tool, largest first: the three `schedule_*` tools at 0.044 MiB each, the six
`agent_*` tools at 0.028 MiB each, `code_mode` at 0.020 MiB, then a tail under
0.012 MiB. In each case almost all of it is the tool's `run` field, a closure
over that plane's seam, duplicated once per tool in the family. Static
definition data is the small remainder: the largest schema in the registry,
`fs_edit`'s, is 0.007 MiB.

This matches the installed daemon's shape at a smaller scale. There, `Effects`
is 12.872 MiB with `hooks` at 6.965, `tool_surface` at 3.943 and
`prepared_provider_surface` at 1.964; the registry is 0.961 MiB. The local
daemon's `hooks` is much lighter because a smoke configuration installs no
advisor, no extensions and no imported hooks, so it composes fewer layers.

### Which of the nine references were real

Reading each of the nine call sites, six need no registry:

- `tools.replay_still_safe` reads one registration's replay declaration.
- `tools.execution_mode` reads one registration's scheduling constraint.
- `tools.clear` reads one registration's replay declaration and refuses a
  name nothing registered. It touches no other field. The policy
  requirements a reader might expect it to need belong to execution, which
  reaches them through `tool.dispatch` inside `run_tool`.
- the `threshold`, `overflow_preparation` and `structural_decision` hooks ask
  one question between them, through `reference_projection` and
  `recall_projected`: whether this host registered `history_search` at all.

The other three are ownership rather than mis-scoped capture.
`provider.request` and `provider.prepare` render the wire tool array, and
`tools.run` dispatches through the registry.

### The change, and what it cost

`tool.declarations` projects a registry to one `Declaration` per name, and the
three declaration-reading slots take that. The three compaction slots take a
two-variant `HistoryRegistration` read once where the registry already is.
Neither projection can go stale: the registry a session runs under is fixed
for the life of the `Effects` record built from it, and `client/serve` builds
both together in one assembly with no path that replaces one under the other.

This is a type change and six call sites. It adds no process, no
serialisation point, no restart relationship, no `@external`, and no change to
any interface frozen in spec Part 1 — `effects.Effects`, `effects.ToolSurface`
and `effects.Hooks` are untouched.

### Before and after

Same harness, same configuration, same host; two release builds differing only
in these commits. N sessions were admitted over the daemon's own control
plane and left resident. Figures are `erlang:memory/0` in MiB and `ps` RSS in
KiB, so they are allocated memory rather than a reachable-term size.

| Sessions | `processes` before | after | total before | after | RSS before | after |
|---:|---:|---:|---:|---:|---:|---:|
| 0 (listening) | 15.68 | 15.68 | 56.02 | 56.03 | 103,808 | 101,984 |
| 1 | 85.13 | 41.30 | 132.31 | 88.82 | 169,008 | 124,864 |
| 3 | 236.86 | 106.50 | 284.46 | 154.44 | 290,320 | 173,504 |
| 6 | 436.22 | 199.40 | 484.78 | 247.67 | 483,376 | 246,336 |

Per resident session, process memory falls from 69.5–73.7 MiB to
25.6–30.6 MiB: a 63.1%, 58.9% and 56.3% reduction at one, three and six
sessions. At six sessions the whole VM falls 48.9% and RSS 49.0%.

The `Effects` value behind that: 3.797 MiB flattened before, 1.309 MiB after.
`hooks` falls from 1.264 to 0.037 MiB and `tools` from 1.688 to 0.427;
`provider` is unchanged at 0.845, the two remaining copies that dispatch a
request.

The repository's own `scripts/daemon_memory_probe.sh` agrees. Run against both
builds with its two-admitted-one-stopped acceptance, one resident session's
process memory went from 93.583 MiB to 52.016 MiB at the intermediate stage
where `tools.clear` had not yet been narrowed.

### What this does not establish

No provider turn was driven. The smoke configuration cannot serve one, and the
`Effects` copies this change removes are created at admission and do not grow
with a turn — the first pass of this investigation established that the step is
deterministic and arrives before any request. A turn-driven measurement is
still the right way to size the *other* option, idle hibernation, because that
one depends on heap that accumulates over real work.

The installed daemon's reduction is not measured. Extrapolating its 12.872 MiB
`Effects` by removing six copies of its 0.961 MiB registry predicts about
7.1 MiB, a 45% cut rather than the local 66%, because its `hooks` carries
layers a smoke host does not install. That number is an inference and needs an
installed before/after to become a measurement.

The figures are allocated memory. A process's heap includes unused capacity,
and `erts_debug:flat_size` counts words a same-node copy may share for short
strings held as refc binaries, so the flattened figures over-state a copy in
that one respect. The process-memory table above is the load-bearing evidence;
the flattened figures explain it rather than stand in for it.

### What is left, and whether an owner process is now worth it

`Effects` still costs 1.309 MiB per copy: three references to one 0.41 MiB
graph. Two routes remain and neither is taken here.

The first is the multiplication *inside* the registry. The three `schedule_*`
tools each hold a whole `Schedules` seam and the six `agent_*` tools each hold
a whole `Agency`, which is this same bug one level down. Narrowing there
divides the leaf, and the leaf is what all three remaining copies pay for, so
it is the higher-leverage of the two. A second candidate at the same level:
`provider.request` and `provider.prepare` reach the registry only through
`tool_specs`, which reads `name`, `description` and `schema` and never `run`
or `requirements`, so a name-keyed spec projection would cut most of their
0.845 MiB. That one is a bigger change than the six call sites here, because
those closures also need `gateway`, `facts`, `session` and the fallback
counts, so it means splitting `Config` rather than swapping an argument.

The second is the per-session owner process this section set out to evaluate.
It would remove the remaining three copies, and it is still the more expensive
shape: a serialisation point on the hot path for every effect call, a new
failure domain needing restart custody, message copies of whatever it returns,
and recovery and interleaving scenarios for an owner that dies mid-dispatch.
Against a remaining 1.309 MiB it is not justified. It becomes worth
re-examining only if the registry-internal narrowing above is taken and the
residue still dominates a census.

### Rerunning this

`scripts/daemon_memory_probe.sh <config> <out>` is the committed harness, and
it was repaired in this work. It had been reaching the daemon with
`net_adm:ping/1`, which answers `pang` on a macOS host whose short hostname
resolves to an address the machine does not answer on, and the script
swallowed the failure and wrote only the OS numbers. It also ran the daemon
under the operator's `HOME`, so it measured a registry built from their
`~/.claude`. Both are fixed; `DIG=1` adds the heaviest-state walk.

The per-field `Effects` breakdown above came from a throwaway sibling of
`scripts/mem_dig.erl` that finds every `{effects, _, _, _, _, _, _}` tuple in
a process state and reports `erts_debug:flat_size` and `erts_debug:size` for
each field, for each slot of the three closure-bearing fields, and for each
capture in those slots over 4,096 words, then does the same for the
`{registry, _, _}` it finds. It is a dozen lines of pattern matching over
`mem_dig`'s existing `children/1` walk and was not committed. Admitting more
than one session needs something other than `client@release_probe_test`, which
asserts zero residents at start: a few frames of `sessions.create` and
`sessions.list` over the daemon's control websocket, built from
`host/websocket`, `host/endpoint` and `host/bootstrap`, is enough.
