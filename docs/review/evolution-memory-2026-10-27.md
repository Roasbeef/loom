# Evolution callback memory

A live TLS Pickglass census found fifteen idle processes holding 226.69 MiB
of process allocation. Bounded state probes identified five evolution capability
cells, five live generation owners, and five notification runners. The daemon
reported build `9b862164196deb91aabe22375003369c16a48d6d`; this repair starts at
`e4fb0b5e54b27207e928e8f1d86041d6c988c725`. No production installation, restart,
forced collection, or application hotpatch was performed.

## What the processes own

Each capability cell held an evolution `Door` with about 18 MiB of flattened
state. Proposal, evaluation and invocation callbacks each retained the whole
`Machine`. The local source-path wrapper also captured that machine to call
its snapshot field, so one machine already contained a second set of sibling
capabilities. Each local operation closure in turn held its native `Config`.
Sharing within the builder did not keep those environments shared when the
doors were copied into their cell or borrowed by a tool call.

Each generation owner exposed about 12 MiB of flattened state. Its stage and
recovery callbacks each captured the same complete machine. Each notification
runner allocated about 13 MiB, while its exposed `Live` state flattened to
192 bytes. Its initializer read `config.clock`, copying the stage and recovery
closures into a process that only needed their owner's address and clock.
The runner's application state alone cannot account for every process root;
the source trace and isolated startup regression establish that extra copy.

The probes returned sizes, record tags and function identities. They did not
print transcripts, credential values, process dictionaries or closure contents.
The state RPCs ran sequentially in diagnostic processes with a 64 MiB heap
ceiling and a one-second state-request timeout. Ordinary process counters and
Pickglass captures preceded those state copies.

## The repair

`serve.local_evolution_machine` projects the snapshot function before wrapping
source-path validation. `serve.open_evolution` projects snapshot, evaluation,
stage and program execution before constructing long-lived callbacks. Its
private recovery and invocation helpers receive only the operation they call.
The local snapshot callback holds the plane opener rather than the native
host configuration. The public snapshot API still delegates through the same
caller-policy and native-retirement path.

`live.start` projects the clock before spawning the notification runner. The
runner still leases from the same generation owner and preserves its original
link, notice order and close protocol. No actor, shared table, cache, dependency,
public interface or protocol was added. Authorization, evidence persistence,
selection fences, generation leases and native retirement remain in their
original paths.

## Regression measurements

Both new regressions failed on unchanged production code before the repair.
The real session assembly receives an inert 128-entry marker secret store.
`captured_occurrences` unfolds closure environments, counting exact marker
terms rather than random UUID sizes or refcounted binary bytes.

| Door callback | Before | After |
| --- | ---: | ---: |
| Proposal | 896 | 0 |
| Candidate evaluation | 1024 | 256 |
| Inspection | 0 | 0 |
| Catalogue | 0 | 0 |
| Invocation | 896 | 128 |
| Trace | 0 | 0 |

Evaluation retains one native configuration and one source `Settings` snapshot
for isolated prompt trials. Invocation retains one native configuration.
The whole door's marker multiplicity falls from 22 to three, an 86.4% reduction.
The earlier startup-diagnostics regression still requires exactly one source
settings snapshot, so removing required data cannot satisfy these checks.

The notification fixture pads only stage and recovery callbacks with 8,192 heap
tuples. It records allocation before asking either actor for state, then
identifies the runner by its application-state tag and retires both children
through `live.close`. Its census is restricted to new links of the test caller,
so concurrent sibling fixtures cannot enter it.

```text
before: evolution notice startup bytes: 3920/372288
after:  evolution notice startup bytes: 3920/3920
```

Three isolated real session assemblies used the same helper, offline seed,
settings builder, dummy provider URL, OTP 29 and two schedulers for control and
candidate. Each control used baseline production sources with the same test
support; candidate sources and build were restored afterward. No model request
was made. Allocation was recorded before state inspection.

| Property, bytes | Control, three runs | Candidate, three runs |
| --- | --- | --- |
| Door flattened state | 576840 / 576840 / 576840 | 64832 / 64864 / 64832 |
| Owner flattened state | 377728 / 377728 / 377728 | 51072 / 51104 / 51072 |
| Runner startup allocation | 372288 / 372288 / 372288 | 3920 / 3920 / 3920 |
| Runner flattened state | 192 / 192 / 192 | 192 / 192 / 192 |

The door's copy cost falls by about 88.8% and the owner's by about 86.5% in
this fixture. Whole-session process allocation varies with startup and GC
scheduling, so the process census is supporting evidence rather than a claim
that all memory outside these three processes is equal.

These are term-copy costs and allocated process capacities. They do not prove
an installed RSS reduction, and the fixture's small configuration does not
predict the live daemon's absolute savings. The live fifteen-process figure
includes unused capacity and garbage. A future authorized update needs fresh
OS, OTP and Pickglass cuts over comparable session and workload states.

## CI follow-up

The macOS full checks exposed a miner fixture that read HOME through Linux
procfs and a TUI stream throughput miss. The miner fixture now uses the same
portable home lookup as neighboring eval tests; its actual historical mining
experiment passes on macOS without adding a skip.

An allocation and call-time profile of the exact stream fixture identified
repeated JSON parsing. The live lane parsed each envelope to validate version
and reply identity, then its event decoder parsed the same bytes again. The
lane now passes its parsed value to package-internal event decoders. Text entry
points, duplicate-key rejection, frame bounds, version checks and correlation
rules are preserved.

A new reductions regression fails the old implementation at 607,500 versus
321,983 reductions for the event decoder alone. With one parse, pushed decoding
uses 327,889 versus 320,121 reductions; correlated presentation decoding uses
249,084 versus 233,479. The regression allows only 25% overhead for live checks.
The original stream fixture still requires 2,000 deltas/sec and the same memory
bounds. Matched one-scheduler untraced cuts improve from roughly 15,700 to
16,000 deltas/sec to 18,500 to 20,100; profiled string-parser calls fall from
806,758 to 404,358. These fixture measurements are not installed RSS claims.

## Validation

The marker and startup regressions pass, and all 185 focused evolution module
tests pass, including recovery, lease, queue, retirement and remote-machine
behavior. Full affected gates, real evolution end-to-end, independent review,
hosted CI and Linux signoff are recorded on the PR when their runs finish.
The separate SQLite JSON-decoding allocation lead remains outside this repair.
