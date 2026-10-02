# Live daemon memory, October 2

This pass profiles the installed `a3dc253596ba24ebf308a1ea680712705b49b1d9`
daemon and two terminal clients. The patch lives on
`codex/memory-lsp-query-handle`, based on that same commit. Measurements use
the bundled ERTS 17.0.5 and Gleam 1.19.0-rc2. Production source modules were
not hotpatched, installed or restarted.

## Which processes are running

The process command, parent chain, working directory and listener establish
the roles. Native numbers below are physical footprint from `vmmap -summary`,
not virtual address reservations or a sum of shared mappings.

| PID | Role | Physical footprint |
| --- | --- | ---: |
| 74659 | Daemon, state `~/.loom`, application listener 127.0.0.1:57704 | 524.9 MiB |
| 75618 | Attached Loom terminal client | 92.0 MiB |
| 18100 | Second attached Loom terminal client | 92.3 MiB |
| 33146 | `web_search` extension code-mode satellite | 56.6 MiB |

PID 33146 is the apparent second `loomd`. Its command starts `loom_satellite`
with the extension artifact, and its parent is `loom-exec` PID 81915. Its
working directory is the Subtrate checkout. It is not a second daemon serving
the same state directory. Both terminal clients use the same installed build;
their earlier native samples were 100.5 and 80.9 MiB, respectively.

The client samples show about 21.3 MiB of allocated native malloc regions
each, with VM_ALLOCATE varying from 56.4 to 76.0 MiB across the cuts. Both
clients were launched without `--profile`, so there is no live distributed
node to census. These samples identify the allocation region, not the BEAM
process retaining it. This pass does not establish a terminal leak or claim
that daemon-side LSP changes reduce terminal memory. A client launched with
`--profile` is required for the same owner/GC measurements there.

## Daemon allocation and targeted collection

Observation-only cuts placed VM allocation at 493–535 MiB during active
work. One saved cut reports total 524.448 MiB, processes 457.808 MiB,
system 66.640 MiB, binaries 21.921 MiB, code 21.976 MiB and ETS 1.554 MiB.
Most allocation is process heaps. The allocator carrier inventory was
580.109 MiB at this cut; carriers, allocated process capacity and physical
footprint are different counters.

The first serial process census found 281 processes, with 395.628 MiB of
process allocation: actors 186.084 MiB, static supervisors 98.446 MiB,
state machines 45.025 MiB and factories 26.697 MiB. It is not an atomic
snapshot, and its sum need not match a different `erlang:memory` cut.
The largest owners had empty mailboxes; that alone does not establish
whether their heaps contain live terms, garbage or unused capacity.

The operator explicitly authorized bounded state probes and targeted full
GC. Six selected processes produced the following allocations in bytes:

| Local PID | Owner | Before GC | After GC |
| --- | --- | ---: | ---: |
| `<0.185.0>` | Runtime root supervisor | 15,106,808 | 15,106,808 |
| `<0.192.0>` | Runtime factory | 7,998,056 | 6,665,216 |
| `<0.208.0>` | Service supervisor | 36,381,048 | 36,381,048 |
| `<0.215.0>` | Jobs actor | 30,403,040 | 973,320 |
| `<0.216.0>` | Advisor actor | 25,335,616 | 88,648 |
| `<0.218.0>` | Block summarizer | 11,170,768 | 6,665,264 |

The six collections reduced their process allocation by 57.712 MiB.
Large collectable allocation in jobs/advisor coexists with durable restart
inputs in supervisors. The jobs state held 202 records but had only 375,912
flat bytes; the advisor state had 29,192 flat bytes. `sys:get_state` does
not expose every actor handler closure, and post-GC process allocation is
not identical to reachable term size. There is no matched whole-VM or
resident-memory before/after result for these collections.

Probes used a monitored worker, a four-second wall bound, a one-second
state-call bound and a 64 MiB worker heap cap. The full service supervisor
snapshot exceeded the cap, so inspection changed to one child specification
at a time. Reports retained tags, callback identities and sizes, excluding
conversation text, tokens and configuration contents. The diagnostic module
was removed from the live VM after measurement; `code:is_loaded` returned
`false`.

## Confirmed LSP capture multiplier

The measured retention path is service supervisor child-start closure →
runtime Effects → tool surface → hookserve → wiring configuration →
registry. The sampled Effects cost 5,484,200 flat bytes, its tool surface
5,033,416 bytes, and the registry 4,975,488 bytes. Code mode legitimately
owns the complete query door. Each of the seven direct LSP tools also
retained that complete eight-callback door, although six call one slot and
rename calls two. Each door callback in turn retained a Manager containing
the full Config, including transport-only `Backend.connect`.

The fix projects each tool's required callback before constructing its
retained executor. The opaque caller-side Manager keeps reachability,
workspace/server identity, search, protected paths, timing and display roots;
the actor and keeper keep full Config and still own server startup.
Routing, restart lookup and repeated path admission are unchanged. Rename
retains preparation and after-write and keeps its write/notification order.

A separate probe VM received one bounded copy of the live door, reconstructed
the seven tools, then loaded candidate modules only in that separate VM.
The same runtime/configuration and matching compiler artifacts produced:

| Term | Original flat bytes | Both projections |
| --- | ---: | ---: |
| Manager query handle | 39,112 | 21,392 |
| Eight-slot door | 313,168 | 171,408 |
| Seven direct tools | 2,205,760 | 184,920 |

Projecting just the tools reduced the bundle to 326,680 bytes. Both changes
reduce its flat copy cost by 91.6%. The repeated measurement after rebuilding
with the matching Gleam compiler returned the same numbers. A distributed
copy can change sharing and closure representation; these figures describe
the compared terms in the probe VM, not the original processes' whole heaps.
They prove the capture reduction, not a prediction of RSS savings.

The independent review also found that `connect_jailed`'s abort closure kept
whole Jailed and built-jail records. Projecting `abort_step` and `step_id`
before the closure keeps environment lookup and preparation data out of the
returned transport. A scripted enforcement-probe regression grows only the
environment lookup payload while requiring equal transport flat sizes.
Its installed memory contribution remains unmeasured.

## Validation and remaining measurement

The tool sibling-slot and manager connect-payload regressions failed against
the original implementations and pass with the projections. Behavioral
coverage includes restart, eviction, admission, search, transport shutdown
and rename. The affected gate builds real helpers and the bundled server;
`make check-affected BASE=a3dc253596ba24ebf308a1ea680712705b49b1d9`
returned exit 0 in 576 seconds: 609 tools, 331 code-mode, 2,647 client and
91 conformance tests passed, with no undeclared skips. This full run preceded
the review's two-binding abort projection. After that projection, the final
manager suite returned exit 0 with 37 tests, including the new transport
regression; final format, lint, doc, prelude and client-asset gates also
returned exit 0. The abort regression fails the original implementation
(98,966 versus 658 flat words) and passes the projection.

The real jailed Gleam LSP and gopls tests ran successfully. Rust-analyzer
could not run because its Rust toolchain component is absent. The client
suite's MCP-process death observation has a declared macOS skip because it
requires Linux `/proc`. No hosted CI or Linux signoff was run. The default
Homebrew Gleam 1.18.1 produces baseline format drift; validation used the
bundled 1.19.0-rc2 matching CI instead.

The independent review found no correctness blocker in the query/tool
projections and verified that full startup custody remains in the actors.
Its focused follow-up also found no issue in the abort projection or test.

Installed closure/RSS savings require a fresh daemon running these commits
under comparable session and connection counts, followed by the same idle,
active, GC and released observation cuts. Terminal attribution separately
requires a profiling-enabled client. No live process was terminated to
obtain these measurements.

Raw diagnostic output and gate logs for this pass are under
`/private/tmp/loom-memory-20261002/`; that temporary directory is not a
durable repository artifact. This report records the load-bearing numbers
and methods independently of those files.
