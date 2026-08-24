# runtime

## Purpose

The orchestration plane's live half: the OTP tree that turns an open
session into a running one. One StorageWriter owns the commit path, one
strand driver per strand interprets the pure machine's actions against an
injected effect seam, and `runtime/api` is the session-facing surface —
open/recover, prompt, steer, follow-up, abort, close. WP-E.

## Key Types

- `runtime/api.Runtime` — the live session handle: the `SessionTree`, the
  `Session`, the `Effects` record, the strand name, and the `RunSettings`.
- `runtime/supervisor.SessionTree` — a rest-for-one supervisor whose first
  child is the writer and whose second is the StrandSupervisor
  (one-for-one over strand drivers; one driver, `"main"`, today).
- `runtime/writer.Message` — the writer actor's mailbox; `writer.Event` is
  the `Committed(ordinal, seqs, ts)` published to subscribers.
- `runtime/strand_runtime.Message` — the driver's mailbox.
- `runtime/effects.Effects` — everything the driver does to the world, in
  one injected record: `clock`, `entropy`, `timers`, `provider`
  (`ProviderSurface`), `tools` (`ToolSurface`), `hooks` (`Hooks`).
- `runtime/effects.{RequestSpec, ToolRun, ToolOutcome, Clearance}` — the
  shapes the seam is written in; `conformance/wiring` fills them with the
  real gateway, broker, and registry.

## Relationships

- **Depends on**: `core`, `storage`, `session`, `machine` (drives
  `next_action` and reuses its codecs and queue helpers), `provider`
  (`stream.StreamHandle` and `retry.classify` — the spec DAG §0.1 writes
  `E → A,B,C,D`, so this provider edge is a divergence worth knowing
  about), `gleam_erlang`, `gleam_otp`.
- **Depended on by**: `conformance` (the simulation runner drives sessions
  through `runtime/api`).
- **FFI**: none. Time, entropy, and timers arrive through `Effects`;
  everything effectful is injected, which is why the whole plane runs under
  a logical clock in simulation.

## Traffic

- **Actor messages**
  - `writer.Message` (all calls except `Subscribe`/`RenewTick`):
    `Commit(tx, reply)`, `GetEntries`, `GetRegister`, `ListRegisters`,
    `ScanBranch`, `ScanUsage`, `Stats`, `Subscribe(subscriber)`,
    `RenewTick`. Senders: `runtime/api`, `runtime/strand_runtime`, and the
    conformance harnesses.
  - `strand_runtime.Message` (all casts): `Nudge` (the doorbell),
    `PollTick` (the checkpoint poll, which also grants one deferred poll
    permit), `RetryDue`, `RequestAbort`, `ProviderDone(token, terminal)`,
    `ToolDone(token, outcome)`, `EffectExit(down)`.
  - `writer.Event.Committed` fan-out to subscribers — a simple typed
    pub/sub over process subjects; the `pg`-based EventBus proper is WP-K.
- **Commits**: every post-boot `Tx` in the session flows through
  `writer.commit`, whose mailbox *is* the serialization order. The driver
  commits exactly what the planner hands it — `Transition`/`Finish`
  transactions and `Dispatch` intent transactions — and treats
  `StaleExpectation` as "reload and re-plan".
- **Registers**: the driver loads `strand.config`, `strand.state`,
  `strand.leaf`, `op.meta`, `op.state`, and the sibling payload registers
  (`op.tool_args`, `op.preparation`, `pending.entry`) through
  `session`'s typed accessors, then writes back whatever the planner's
  transactions carry. `strand.last_result` is written and never read.
- **Wire**: consumes `provider/stream.StreamEvent` — zero or more `Delta`
  then exactly one `Settled` or `Failed` — from a `StreamHandle`, and
  `effects.ToolOutcome` from the tool surface.

## Invariants

- **One writer, structurally.** All commits are calls into one actor, so
  "transactions on one session are serialized" is a property of the process
  topology, not a convention. Reads route through it too, keeping a single
  storage path and one instrumentation point.
- **The drive loop is the machine's contract, verbatim**: load registers →
  build `PlannerInputs` with a fresh id generator each pass → `next_action`
  → commit and re-plan on `Transition`/`Finish`; on `Dispatch` commit the
  intent *then* start the effect; on `AwaitEffect(key)` resolve the key; on
  `Wait` schedule a timer or a poll permit; on `Fault` stop abnormally.
- **Crash recovery and cold start are the same code.** A restarted strand's
  first drive re-reads its registers and resumes (spec §3.1); the tree is
  rest-for-one, so a writer crash restarts the writer *and* every strand,
  while a strand crash restarts only that strand.
- **Doorbell loss is harmless by construction.** `Nudge` only wakes the
  strand early; the payload always travels in the commit. The periodic
  `PollTick` finds queued work anyway, and any commit racing the strand's
  own surfaces as a stale expectation, forcing a reload that sees it. The
  `_quietly` admission variants commit without ringing at all.
- **Effect processes are spawned unlinked and monitored.** An effect
  process that dies without reporting settles **in-band** — a transport
  failure response or a synthetic tool error — so the harness never wedges
  and never faults the strand on a worker's death.
- **`after_commit` is the crash seam.** It runs in the writer process after
  the commit is durable and published but *before* the committer's reply,
  so an observer that kills the writer produces exactly "commit N durable,
  committer never saw it succeed". Production passes a no-op. No terminal
  result is accepted while the seam is open.
- **Abort is strand-routed and idempotent.** The durable
  `cancel_requested` marker serializes with the strand's own transitions
  and live effects are cancelled by their owner; a pre-commit crash loses
  the request exactly as pi's no-live-task case does, and callers
  re-request.
- **Close is a controlled crash** (pi §4.7). The static supervisor offers
  no graceful external shutdown, so close kills the tree — commits are
  atomic in the storage actor, so durable state stops at a commit boundary
  — then closes the handle, releasing the SQLite writer lease. Nothing is
  written; reopening recovers the open operation.
- **A lost lease stops the writer abnormally** so the supervisor reboots
  the tree, whose reopen path re-acquires or fails loudly. Renewal runs on
  an idle timer at a third of the TTL.
- **The names, not the pids, are the addresses.** The writer and each
  strand register under fresh process names so restarts keep them
  addressable.

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the drive loop, the supervision tree, doorbells, the interleave
  harness.
- [docs/architecture/simulation.md](../../docs/architecture/simulation.md) —
  what the deterministic runner does to this tree.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-E": crash
  semantics, boot seeding, close-as-crash, injected entropy, minimal writer
  events.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
