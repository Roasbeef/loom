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
