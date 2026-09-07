# Investigation handoff: daemon memory per session

Status: **owner found and repaired**; see "2026-09-07, second pass" at the end
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
