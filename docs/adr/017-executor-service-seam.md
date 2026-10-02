# ADR-017: the executor service sits at the execution, one per session, inside the broker package

**Status**: accepted · **Date**: 2026-10-02 · **Supersedes**: nothing ·
**Spec ref**: Part 2 WP-G (the broker), Part 1.4 (effect-plane wire, unchanged) ·
**Issue**: #696

## The question

Issue #696 asks for a Gleam executor service that owns admission, inventory,
lifecycle and diagnostics for execution, while the Go helper `loom-exec` keeps
confinement and native cleanup. The goal it names is one explicit execution
model, not one implementation language.

Four questions have to be answered before any code, and they constrain one
another:

1. At what height does the service attach: behind the pool, around a single
   execution, or above the broker?
2. Where does one service live: per session, per daemon, or in a second VM?
3. Which package holds the modules?
4. Where does the pure transition core live, given that `core`, `machine` and
   `prompt` are held to a portable subset?

The architecture page, [`docs/architecture/executor.md`](../architecture/executor.md),
carries the inventory, the state model and the phase plan. This record keeps
only what was decided, what it costs, and what was refused.

## Measured before deciding

A survey read the broker, the helper machine, the pool, every caller of the
pool and the Go helper, and ran the helper under the real jail in the
development container (bwrap present; `loom-exec --self-test` reports ten
layers enforced and one skipped, the cgroup pids ceiling). Five findings shaped
the decision, and each contradicts a premise of the issue.

- **There is no execution object to wrap.** An execution is a `RunningExec`
  payload inside a helper phase, identified by a per-helper counter that never
  leaves the module. The three custody dimensions the issue asks for already
  exist as `Availability` crossed with `Retirement`. What is missing is a
  registry above `exec`.
- **Admission is caller-side polling by a documented ruling.** The broker
  checks a helper out inside its serial handler and checks one in only on
  settlement, so a service that queued would wait on a mailbox it blocks.
- **Custody is per session.** The writer lease is released only after the
  `Helpers` cleanup has shown a native exit for every helper the session
  owned, and `exec_exit` is not a witness of that
  (protocol-change/014).
- **Four defects are latent on the BEAM side and one in Go**: a relay never
  learns that its helper actor died, a busy helper can be re-lent, a late `Run`
  can start an unwatched execution, a deliberately killed helper permanently
  loses its slot, and the Go helper stalls on a large stdin. The architecture
  page gives the evidence for each.
- **The Go helper holds no orchestration worth moving.** It is a stateless
  316-line frame loop. What both languages duplicate is codecs and a tag
  vocabulary.

## Decision

### D1. The seam is at the execution

The broker keeps policy composition, tokens, budgets, abort epochs and its
`Active` rows. Where it now checks a helper out, runs the execution, relays
events and checks the helper in, it calls a `Dispatcher`, a record of three
functions (`start`, `cancel`, `stdin`) defined in `broker/dispatch`. The service
behind it owns checkout, run, relay, settlement and checkin, and holds the
registry of live executions.

`start` refuses synchronously with the pool's own `AllBusy(size)`. The caller's
retry loop stays the queue. The service sends exactly one settlement message per
execution id, on which the broker reclaims budget and token.

Because the broker keeps its handle, no call site outside `broker.gleam` and
`serve.gleam` changes in the first phase. Code mode's fifteen sites and the
seven clearance sites are untouched.

### D2. One service per session effect plane, in process

The service wraps the pool that session already owns. In local mode it lives
inside `loomd`. There is no daemon-wide service, no daemon-wide helper ceiling
and no second VM. The `Helpers` custody hook becomes
`executor.close(service, waiting: 5000)`, which drains executions and then closes
the pool, so the existing proof of retirement is unchanged.

### D3. The modules live in `packages/broker` until the standalone phase

`broker/dispatch` (the seam type), `broker/execution` (the pure core),
`broker/executor` (a `weft/actor` holding the registry, the diagnostic ring and
the incarnation), `broker/relay` (a `weft/state_machine` per execution) and, for
two phases, `broker/direct` (today's dispatch, relay and checkin moved
unedited). `broker.gleam` imports the seam type and never `executor.gleam`. A
thin `packages/executor` is created in S4, when an entrypoint first has to boot
without the client, and it holds the entrypoint and a version census and not the
service.

### D4. The pure core is in `broker`, not `core` or `machine`

`broker/execution` imports no process library, so its `step` function is
property-tested without spawning anything. It lives beside the types it reuses,
`ExecResult` and `ExecFailure`, which `core` would otherwise have to duplicate.
Lint rule R6 binds `core`, `machine`, `prompt` and `session_view`, and does not
bind `broker`.

### The rollout

The service lane is opt-in. `LOOM_EXECUTOR_LANE=service` selects it, and
`DirectLane` is the default, because the issue's rollout rule is that a new
path starts opt-in. S2 flips the default to `ServiceLane` once the failure
matrix passes. S3 deletes `broker/direct`, the setting and the variable. Each
lane constructs its own pool and the lane is read when a session opens, so a
switch never shares a helper and rollback before S3 is the variable at session
open.

### What is not decided here

No protocol change is made in any phase. The witnessed kill, the busy-helper
fix, the census and the tag generator are all BEAM-side or build-side. The
decision on moving more Go into Gleam is the subject of a later record, ADR-018,
which S5 will write from measurement. Its expected verdict is to keep Go and to
generate the shared contract.

## What it costs

- **One extra hop.** A call now crosses the dispatcher and a relay owned by the
  service. The baseline probes (architecture page, "Baselines") exist so that
  the cost is measured. If the round trip moves by more than noise, this record
  is wrong about the price.
- **About 250 lines move out of `broker.gleam`**: `dispatch`, `relay` and the
  checkin half of `reclaim`. `Active` loses `helper`, `relay_pid` and `monitor`,
  and gains an `ExecutionId`.
- **A temporary duplicate relay of about 110 lines** in `broker/direct`, for two
  phases, with a named deletion in S3.
- **Two new fields on the pool's entries**: a generation, minted at `spawn_new`
  and returned by `checkout`. The pool's own fences stay keyed by pid.
- **A weaker backpressure claim than the issue asked for.** Ports are active, so
  the BEAM side buffers. The bound is helper-side (`output_bytes` per stream),
  and jobs whose output is the wire stay uncapped. S2 proves that cancel stays
  responsive under a flood and does not claim a bound the design cannot give.
- **No restartable in-session service.** The pool and broker are fatal children
  captured by value and the service joins them. A killed service leaves custody
  `Failed(Helpers)`, and that is tested as a negative.
- **A diagnostic ring of 64 settled executions and zero retained output bytes**,
  both pinned by test and neither a knob.

## Alternatives considered

**A seam at the pool.** Attach behind `checkout` and `checkin` (`BrokerConfig`).
This is the cheapest option and needs no change to any caller. It was refused
because it sees lend and return and nothing else. Output, exit, cancel and
deadline would still be observed in the broker, so the registry would be fed
from outside and the service would be a pool under a new name. A synchronous
checkout that queued would also deadlock the broker.

**A seam at the runner.** Replace the tool runner (`tool.broker_runner` and
`wiring.escalating_runner`). This sits above policy and tokens, so it would need
every one of the seven clearance sites and code mode's fifteen to learn a new
handle, and escalation would have to be re-threaded through it.

**A daemon-wide service.** One executor for all sessions, sharing helpers. It
would let a helper serve session A and then B, and then "A's jails are joined"
could only be proven from `exec_exit`, which is not a join witness. The only way
to keep protocol-change/014's proof under sharing is to retire helpers per
session, which removes the sharing. The existing bound on cross-session
capacity is session slots times a pool ceiling of sixteen. If the memory
baseline shows that too loose, the remedy is idle retirement (#283).

**`packages/executor` now.** A package that depends on `broker` cannot be called
by `broker.gleam`, so the seam type would live in `broker` regardless. The package
would hold only the implementation, and would cost a manifest, a weft path
dependency, a documentation pair, CI wiring and a lint policy for no behaviour.
S4 earns it.

**A second VM.** Run the service in its own Erlang node beside the daemon. The
helper is already out of process and the kernel is the boundary, so a second
VM adds no isolation. It would cost a transport and a trust model, which
the issue assigns to #697 and tells this work not to define.

**Put the pure core in `core` or `machine`.** This would make it compilable to
JavaScript. It was refused because the core needs `ExecResult` and `ExecFailure`
from `broker/exec`, and moving them would mean either duplicating them or moving
`exec`'s types out of the package that owns them. Nothing is gained that a
property test does not already give.

## What would prove this wrong

The seam is wrong if the first phase's equivalence test needs a lane-specific
expectation: the broker's own tests and the real-helper integration tests run
under both lanes, and the enforcement report for the same fixture is compared
byte for byte. A case that needs its own expectation means the execution-level
seam leaks semantics. The per-session decision is wrong if the memory baseline
shows that sixteen helpers per session across the session slots is unaffordable
and idle retirement cannot close the gap. The price is wrong if the round-trip
probe moves by more than noise. Each fails visibly, as a failing test or a
number, and none is a change to the mechanism of the other three decisions.
