# conformance

## Purpose

The shared test infrastructure and the one package allowed to depend on
every layer: the storage conformance suite that *defines* backend
correctness, the wiring and jailed e2e suites that prove the production
effect seam (`client/wiring`, which once lived here before its promotion),
and the deterministic simulation runner that turns a seed into a verdict.
WP-T. Modules live under `src` (not `test`) because backend packages import
them from their own test mains.

## Key Types

- `conformance/storage_suite.{Backend, run}` — one suite parameterized over
  a backend constructor. A backend passes WP-B's exit criteria only when
  `run` is green.
- `conformance/simulation/runner.{run, check, examine, soak, Verdict,
  Report}` — seed in, verdict out.
- `conformance/simulation/script.{Script, Op, Settle, Intervention}` — the
  semantic half: what the session is *asked* to do. `Script.subagent` is
  the multi-strand coda: an optional brief that spawns a subagent strand
  and sends its findings back to main.
- `conformance/simulation/fault.{Fault, Schedule}` — the taxonomy of things
  a session must survive without anyone noticing.
- `conformance/simulation/random.Rng` — a splittable SplitMix64; the only
  source of choice.
- `conformance/simulation/vclock.Clockwork` — the one logical clock and its
  timer wheel.
- `conformance/simulation/control.Control` — the counters, one-shot claims,
  and runtime handle that outlive the session tree.
- `conformance/simulation/{store, surface, invariant, wire}` — the
  instrumented session, the scripted effect surface, the named per-run
  checks, and the framing properties.

## Relationships

- **Depends on**: every Gleam package it tests — `core`, `storage`,
  `session`, `machine`, `runtime`, `provider`, `broker`, `tools`, and
  `client` (whose promoted `client/wiring` the wiring and e2e suites
  prove) — plus `gleam_erlang` and `gleam_otp`. This is deliberate and
  unique.
- **Depended on by**: nothing. It is the leaf, and stays one: `client/demo`
  copies the simulation's effect-surface shape rather than importing it,
  because this package's surface is test support, not a library.
- **FFI**: `conformance/test/support/internal/ffi_time` and `ffi_shell` —
  test-side only, for the jailed e2e harness.
- **Note**: the wiring adapter used to live in this package's `src`
  because only the test leaf could depend on every layer; when the client
  package became a real host it was promoted to `client/wiring`
  (spec-gaps, M2 integration item 7 — resolved).

## Traffic

- **Actor messages**: `control.Message` (counters, claims, notes, the
  runtime handle, the seam arm/quiet protocol) and `vclock.Message` (now,
  schedule, advance, park). Both are calls. The runner also subscribes to
  `runtime/writer.Event.Committed` indirectly through the instrumented
  store's commit counter.
- **Commits**: `simulation/store.instrument` wraps a real memory backend's
  `Storage` record so every commit passes through it — counted with a
  counter that survives writer restarts, optionally refused as
  `StaleExpectation` exactly as a concurrent admission would, and checked
  against the boundary invariants at the transaction that caused them.
  The same wrapper gives a memory session a **stealable lease**: a renewal
  that fails once at a chosen commit and succeeds afterwards, which is what
  a stolen-then-reacquired SQLite lease looks like from above.
- **Registers**: `simulation/invariant` reads `op.state`, `op.meta`, and
  `strand.*` through `machine/codec` to check placement and terminal
  register cleanup; `storage_suite` exercises every namespace generically.
- **Multi-strand traffic**: a share of seeds drive the subagent coda —
  `api.create_strand` (fork-in-place at the main leaf), the child's brief
  run to a terminal result, then `api.send_to_strand` delivering its
  findings back to main as a durable steer-or-start admission. Coverage
  now *requires* both the spawn and the cross-strand message, so crashes
  during a child's effects exercise the boot-all-strands recovery path.
- **Wire**: `simulation/wire` generates byte streams straight into
  `broker/framing`'s deframer — no helper involved; the jailed e2e drives
  the real `loom-exec` through the broker.

## Invariants

- **Faults are transparent by definition.** A schedule may crash the tree
  at a commit boundary, kill it mid-effect, refuse a commit as stale, fault
  a read, steal the lease, drop or delay a doorbell, starve an effect, or
  lose an effect process — and none of it may change what the session ends
  up having done. Anything that legitimately changes the outcome (a
  provider that refuses, a user who aborts) is scripted into *both* runs so
  it cannot be mistaken for damage.
- **Nothing is keyed by a counter.** A generation request is answered by
  the *phase* of its projected context — how many assistant messages are in
  it, plus a hundred once a summary is — and a tool execution by its
  scripted call id. Errored, aborted, and deferred responses never enter a
  projection, so a synthetic settlement written by recovery cannot shift
  the phase, and a script means the same thing under every schedule.
- **Answered-call checks scope to *executable* responses.** Faithful abort
  retention means an aborted entry can carry tool calls that never ran, so
  demanding a result for every call in every retained response is wrong.
- **Split-summary progress is counted at the commit boundary**, not at
  send time: a settlement lost with a halted strand must lead to another
  request rather than to a summary the ledger never paid for.
- **Fault addressing is ordinal, not temporal.** Commit-indexed faults name
  a global commit ordinal counted across writer restarts; effect-indexed
  faults name a dispatch ordinal. Neither is a wall-clock instant, so a
  schedule means the same thing on a loaded machine as on an idle one.
- **A simulated session never sleeps.** The clock moves only when the
  runner moves it, and by exactly one step: to the earliest registered
  deadline. Firing a deadline early is always safe — the driver re-reads
  its durable state on every pass, so an early wake costs one wasted
  planning pass. A deadline is removed when it fires, so a wake delivered
  to a dead process is simply lost, exactly as a real timer's message
  would be.
- **One clock, one era.** The storage backend's timestamps, the strand
  driver, the effect scripts, and id minting all read the same `Clockwork`.
  Separate real clocks across runtime, tools, and broker drift, and that
  drift once made the broker refuse every call as past deadline (spec-gaps,
  M2 item 1).
- **Every check has a name.** "The simulation failed" is not a bug report.
  Boundary checks run inside the commit path so a violation is caught at
  the transaction that caused it; terminal checks run once the strand is
  idle.
- **The deframer must be total** and is property-checked as such: chunking
  is irrelevant, damage is reported rather than silently survived, and
  truncation carries the partial bytes for a rest that never comes.
- **`let assert` is permitted in this package's `src`**, unlike everywhere
  else (spec §0.2). A suite or runner whose fixture will not construct has
  nothing to say; the module docs state the exemption where it is used.

## Deep Docs

- [docs/architecture/simulation.md](../../docs/architecture/simulation.md) —
  seed/script/schedule/verdict, keying, simulated time, the fault taxonomy,
  reproducing a failure.
- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  "The conformance suite is the definition of correct".
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-B/T" and "From
  the M2 integration (`conformance/wiring`, since promoted)".
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
  `make conformance` runs the suites; `make e2e` the jailed acceptance;
  `make soak` the long simulation run.
