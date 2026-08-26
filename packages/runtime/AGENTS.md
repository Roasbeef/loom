# runtime

## Purpose

The orchestration plane's live half: the OTP tree that turns an open
session into a running one. One StorageWriter owns the commit path, one
strand driver per strand interprets the pure machine's actions against an
injected effect seam, and `runtime/api` is the session-facing surface —
open/recover, prompt, steer, follow-up, abort, close, plus the multi-strand
operations (create a subagent strand, message another strand, await its
result), the `fact.*` blackboard, and durable escalation decisions. WP-E,
extended by the M3 runtime wave.

## Key Types

- `runtime/api.Runtime` — the live session handle: the `SessionTree`, the
  `Session`, the `Effects` record, the strand name, and the `RunSettings`.
  It addresses **one strand at a time**; `api.on_strand` rebinds the same
  tree to a sibling, so every operation works for subagents too.
- `runtime/api.{CreateStrandError, Delivery}` — subagent creation, and
  whether a cross-strand message landed as a `Steered(entry)` on an open
  run or `Started(operation)` on an idle strand. `create_strand` is
  `validate` + `seed_strand` + `adopt_strand`; `adopt_strand` is exposed
  on its own because a crash between the seed commit and the brief commit
  leaves a strand nothing else can finish.
- `runtime/api.ApiError` — why an operation failed, and the two variants
  worth telling apart are `CommitFailed(error:)` and
  `SessionStolen(held_by:)`. The second is `tx.LeaseLost` classified at
  the admission surface (`commit_failure`): another writer owns the
  session, so nothing this runtime commits can land and the remedy is to
  reopen, not to retry. The admission ladder finishes on it rather than
  retrying — `retry_admission` decrements only on `Retry`, so spending
  four attempts against a fence that refuses all four would report
  `RaceLost` and name the wrong cause.
- `runtime/api.{put_reserved_fact, reserved_facts, reserved_fact_key}` —
  the harness-only door to the reserved corners of `fact.custom`, and the
  predicate naming them. Deliberately disjoint from `put_fact`/`facts`,
  which refuse and hide the same keys.
- `runtime/supervisor.SessionTree` — a rest-for-one supervisor over five
  children in order: the strand **registry**, the **StorageWriter**, the
  **StrandSupervisor** (a `factory_supervisor` of strand drivers, one per
  strand, restarted individually), the **subagent StrandSupervisor** (a
  second factory with its own tolerance, for strands a host's `subagent`
  predicate names), and the **strand booter** (a worker whose start lists
  the `strand.*` registers and starts a driver for every strand found,
  routing each to its factory).
- `runtime/supervisor.shutdown(tree, grace_ms:)` — the orderly stop
  `api.close` is built on: children terminated in reverse start order
  with reason `shutdown`, killed only if the grace is spent. The tree
  unlinks from its starter, so a host that wants to hear about its death
  monitors `SessionTree.supervisor` (`client/host` does).
- `runtime/lineage.{Lineage, CallSite}` — the durable ledger of who
  spawned whom, one `fact.custom` cell per spawned strand under the
  reserved `lineage/` prefix: parent edge, depth, the minting call site,
  the brief operation, the child's tools, an **absolute** deadline, the
  detach flag, and the durable reap mark. `is_descendant` is the walk the
  addressing rule is decided by, and it fails closed.
- `runtime/registry.Message` — the strand-name registry actor: strand name
  ↔ the process name its driver registers under.
- `runtime/writer.Message` — the writer actor's mailbox; `writer.Event` is
  the `Committed(ordinal, seqs, ts)` published to subscribers.
- `runtime/strand_runtime.Message` — the driver's mailbox.
- `runtime/api.Options.logger` / `runtime/strand_runtime.Options.logger`
  — the injected `telemetry/log.Logger` every strand of the session
  logs through (§0.2; `log.discard()` by default, so a runtime nobody
  configured is silent). `strand_runtime.start` scopes it to the strand
  it is starting, and each dispatched effect narrows it again to
  `{op, step}`.
- `runtime/effects.Effects` — everything the driver does to the world, in
  one injected record: `clock`, `entropy`, `timers`, `provider`
  (`ProviderSurface`), `tools` (`ToolSurface`), `hooks` (`Hooks`).
- `runtime/effects.{RequestSpec, ToolRun, ToolOutcome, Clearance,
  ExecutionMode}` — the shapes the seam is written in; `conformance/wiring`
  and `client/demo` fill them with the real gateway, broker, and registry.
  `ToolRun.strand` carries the dispatching driver's own durable name, so a
  tool can be judged against its lineage rather than against a name a
  model claims. `ToolRun.grants` carries what *this call's* clearance
  consumed — the far end of the channel `ClearanceQuery.grants` opens,
  and the reason an approval can change a policy decision at all. A
  replayed call carries none.
- `runtime/hooks.Registry` — the one seam production wiring, tests, and the
  simulation runner all build their `effects.Hooks` through: safe defaults,
  a pipeable setter per slot, `build` at the end.
- `runtime/hooks.Projected` — what a compaction decision is taken from:
  a strand's projected `messages`, how many leading ones a compaction at
  the head of the branch `carried` over (its summary plus its
  retained-tail copy), and that compaction's `previous_summary`.
  `hooks.project` reads one from a session; `hooks.uncompacted` wraps a
  plain message list.
- `runtime/hooks.{estimate_message, context_tokens, preparation,
  threshold, overflow}` — the compaction arithmetic: characters over
  four for a not-yet-priced message, pi's newest-durable-usage fold for
  a whole context, the one preparation builder, and the two signals
  built over them.
- `runtime/effects.OverflowQuery` — `{operation, strand}`, asked once
  when a settlement classifies as a run's first context overflow. It
  names the strand for the same reason `ThresholdQuery` does: a
  preparation is built from a *strand's* durable projection, and one
  `Effects` record serves every strand of a session.
- `runtime/escalation.{Escalation, CallScope, Status}` — the durable
  record of a broker denial awaiting a decision, its decision, and its
  single consumed re-execution. `CallScope` is the exact call identity
  (`{operation, strand, step, source index, call id}`) an approval is
  attributed to; only the clearance whose coordinates match can spend it.
- `runtime/api.{escalations, escalation, raise_escalation_for,
  approve_escalation, deny_escalation, consume_escalation}` — the durable
  escalation surface. `escalation(runtime, id)` is the bounded point
  lookup a parked call polls on (`client/escalate`), rather than listing
  and decoding the whole reserved prefix once a second.

## Relationships

- **Depends on**: `core`, `storage`, `session` (`runtime/hooks.project`
  reads a strand's durable projection straight from the session store),
  `machine` (drives
  `next_action` and reuses its codecs and queue helpers), `telemetry`
  (the injected logger and the correlation context — a leaf package
  over `core`, so this edge adds nothing transitively), `provider`
  (`stream.StreamHandle` and `retry.classify` — the spec DAG §0.1 writes
  `E → A,B,C,D`, so this provider edge is a divergence worth knowing
  about), `gleam_erlang`, `gleam_otp`.
- **Depended on by**: `client` (the gateway dispatches protocol commands
  onto `runtime/api`), `conformance` (the simulation runner drives sessions
  through `runtime/api`).
- **FFI**: one declaration, in `runtime/internal/ffi_sup` over
  `runtime_ffi.erl` — `sys:terminate/3`, the only graceful stop an OTP
  supervisor offers a process that is not its parent, and the one thing
  `gleam/otp/static_supervisor` does not wrap. Nothing else: time,
  entropy, and timers arrive through `Effects`, and everything effectful
  is injected, which is why the whole plane runs under a logical clock in
  simulation.

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
  - `registry.Message` (all calls): `Ensure(strand, reply_with)` — mint or
    return the process name a strand's driver registers under — plus
    `Lookup(strand, reply_with)` and `Known(reply_with)`. Senders:
    `runtime/supervisor`'s strand factory and booter, and `runtime/api`
    when it rings a doorbell or addresses a sibling strand.
  - `writer.Event.Committed` fan-out to subscribers — a simple typed
    pub/sub over process subjects, which `events/bus.bridge` and
    `client/gateway.commit_forwarder` adopt as their hint source.
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
  `api.create_strand` seeds a new strand's `strand.config` / `strand.leaf`
  / `strand.state` before starting its driver. The blackboard and
  escalations are `fact.*`: `api.put_fact` / `fact` / `facts` over
  `fact.custom`, and `runtime/escalation` and `runtime/lineage` store
  their records in `fact.custom` under the reserved `escalation/` and
  `lineage/` key prefixes — escalations guarded by the register's own
  seq, lineage cells last-write-wins.
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
  rest-for-one, so a writer crash restarts the writer *and* the whole
  strand factory, while a strand crash restarts only that strand.
- **Recovery boots *all* strands, not just `"main"`.** The booter lists the
  `strand.*` registers and starts a driver for every strand it finds, so a
  cold open, a writer crash (the factory restarts empty and the booter
  repopulates it), and a booter crash all converge on "list the store,
  start what is missing". Subagents created mid-session seed their
  registers first, which is why every later reboot finds them.
- **Process names are minted once per strand and outlive their drivers.**
  The registry sits first in the rest-for-one order, so it survives writer
  and strand crashes; a replacement driver registers under the *same* name
  and stays addressable, and doorbells resolve through `lookup` at ring
  time rather than caching pids. Only a whole-tree reboot starts it empty.
- **Inter-strand messaging is the queue machinery, not a mailbox.**
  `send_to_strand` durably enqueues a steer onto the target's open run — or
  accepts a fresh run when it is idle — and only then rings the doorbell,
  so the payload is durable before any ephemeral signal (design §4.6).
- **Doorbell loss is harmless by construction.** `Nudge` only wakes the
  strand early; the payload always travels in the commit. The periodic
  `PollTick` finds queued work anyway, and any commit racing the strand's
  own surfaces as a stale expectation, forcing a reload that sees it. The
  `_quietly` admission variants commit without ringing at all.
- **Effect processes are monitored by the driver and linked to its
  reaper.** An effect process that dies without reporting settles
  **in-band** — a transport failure response or a synthetic tool error —
  so the harness never wedges and never faults the strand on a worker's
  death. Each driver incarnation also spawns a *reaper*: a tiny trapping
  process, linked to the driver, that every effect links to at birth and
  that kills itself (taking the linked effects with it) the moment the
  driver dies. A strand-actor restart therefore cannot leak a live effect
  into the next incarnation — the exclusivity gate and the
  orphan-versus-live replay decision read the incarnation-local `live`
  list, and both are sound only because no effect outlives its
  incarnation.
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
- **A lost abort race re-delivers, it never halts the strand** (ORCH-L5).
  Exhausting the stale-retry ladder must not drop a fire-and-forget request
  (nobody would learn it was lost) and must not restart the strand for a
  transient race, so the driver re-sends `RequestAbort` to itself after a
  pacing delay and keeps running; every retry re-reads durable state, so
  the loop converges once the concurrent committers quiet down.
- **Interrupted effects stay registered, and settle faithfully.** Live
  effects are cancelled *after* the durable marker (pi §4.6 order) but are
  not deregistered: an effect that already delivered a real settlement
  still queued in the mailbox commits under its reserved ids as `aborted`
  **retaining its reported usage** (ORCH-M3), while one that dies unreported
  settles through the monitor as a synthetic zero-usage abort.
- **Four corners of `fact.custom` are reserved, and reserving hides as
  well as refuses.** `escalation/`, `operation-result/`, `lineage/` and
  `prompt/` are refused to `put_fact` and filtered out of `facts`, so no
  blackboard write can forge an approval, shadow a terminal result,
  rewrite a parent edge, or overwrite the pinned system prompt. Because
  the reservation also hides a namespace from its own owner, harness code
  reads and writes it through `reserved_facts` / `put_reserved_fact`,
  which refuse everything *outside* the reserved set — the two doors are
  disjoint so neither can be pressed into service as the other. The
  ledger prefix is `lineage/` rather than anything near the
  model-writable `agent/`: an integrity-critical namespace two letters
  from a model-writable one is one typo away from lineage forgery.
- **A model-spawned strand's crash loop cannot reboot `main`.** The tree
  carries two strand factories and `Config.subagent` decides, by name
  alone, which one starts a strand. The subagent factory sits *after* the
  primary one in the rest-for-one order, so its death restarts only
  itself and the booter. The runtime cannot tell a model-spawned strand
  from an operator-spawned one — lineage is a layer up — so the host
  injects the predicate, and the default says nobody is a subagent,
  which is exactly the single-factory behaviour that came before.
- **Escalations are registers, not entries.** An escalation is current
  mutable state (pending → approved → consumed) needing a bounded point
  lookup on the clearance path, and it must never move a strand's leaf or
  enter a context projection — a mid-batch denial cannot be allowed to
  reparent the conversation. Status transitions are CAS-guarded through
  the writer, so a lost race is a refused commit, never a double consume.
- **An approval is attributed, and consumed before its grants are used.**
  The record carries the exact `CallScope` its denial was raised for; a
  clearance loads only the approvals scoped to the call it is clearing
  (unscoped records match nothing — an unattributable grant must not
  widen anything), consumes them by CAS *first*, and passes into
  `tools.clear` only the grants whose consumption commit won. A lost CAS
  drops that record's grants and the clearance proceeds under the base
  policy; a crash after the consumption spends the approval without an
  execution. Both directions fail safe: one approval is worth at most one
  widened execution, of exactly the call a human approved. What the
  clearance won then travels onto the dispatch it authorized
  (`ToolRun.grants`), keyed by the call's own `{step, source index}`, so
  a carry left behind by a clearance whose dispatch never happened — a
  stale commit that re-plans, a fault — can never widen a different call.
  A **replay** carries no grants at all: its clearance belonged to a dead
  incarnation whose approval is already marked consumed, and re-widening
  from it is the one direction that would turn one approval into two.
- **Grant and denial payloads cross the runtime opaquely.** They are stored
  as JSON in the broker's escalation vocabulary and returned uninterpreted,
  which is what keeps the spec's `E → A,B,C,D` direction intact — there is
  no broker import here. `client/grants` does the decoding.
- **Hooks decide from durable state.** The `hooks.threshold` and
  `hooks.overflow` constructors derive their signals from the strand's
  *durable* projection (`hooks.project`, read straight from the session
  store rather than through the writer, which is what makes it callable
  from a hook), so a decision taken before a crash is taken again after
  it — the same rule the simulation hooks follow. A read that fails
  projects as empty, which reads downstream as "nothing to compact": a
  strand must not be halted because a token count could not be taken.
- **The threshold is computed on every pass, and that is a cost.**
  `PlannerInputs.threshold` is a value rather than a thunk (frozen, spec
  Part 1), so an open operation pays one branch scan and one projection
  per driver message. An idle strand never reaches `build_inputs`, and
  `hooks.threshold` checks `settings.enabled` before calling a
  projection at all, so compaction-off costs nothing; the scan stops at
  the newest compaction, so its size is bounded by the very thing it
  triggers. A memo keyed on the strand leaf's register seq is the
  available fix if it ever shows in a profile.
- **A context is counted the way the provider counts it.**
  `context_tokens` takes the newest settled assistant message's
  *provider-reported* usage and estimates only what came after it (pi's
  `estimateContextTokens`). An estimate-only fold drifts low against the
  provider — cache reads, thinking tokens, serialization overhead — and
  low is the dangerous direction: a run that believes it has room
  overflows instead of compacting.
- **Carried usage is never read.** A `CompactionEntry` carries a *copy*
  of its retained tail, so the assistant messages at the head of a
  post-compaction projection report the size of the context the
  compaction replaced. `Projected.carried` names them and the fold
  starts after them. Without the guard the threshold re-fires on the
  turn after every compaction, forever — pi guards the same way, by
  rejecting usage older than the latest compaction.
- **A retained tail never opens on a tool result.** `preparation` walks
  newest-first until the keep-recent budget is spent, then moves the
  boundary *later* until it lands on a user, assistant or custom
  message. A result severed from its call would open the tail as an
  answer to a question the model can no longer see; moving later — not
  earlier — keeps call and results together on the summarized side, so
  no orphan is created in either direction. A consequence worth naming:
  the cut always lands on a turn boundary, so this builder never
  produces pi's split-turn case and `is_split_turn` is always `False`.
- **One preparation builder serves all three triggers.** The threshold
  hook, the overflow hook, and a manual `Compact` command
  (`client/gateway`) all call `hooks.preparation`, so all three cut
  where the others cut and a change to the rule cannot apply to only
  some of them. A carried summary travels as `previous_summary` — input
  to the iterative-update prompt — rather than being handed back to the
  summarizer as transcript; its retained tail *is* re-summarized,
  because those messages survived one compaction and the next would
  otherwise drop them silently.
- **Close is an orderly shutdown, and the lease release does not depend
  on it.** `close` terminates the tree the way OTP terminates one —
  reverse start order, reason `shutdown` — so every strand driver is
  gone before the writer it commits through, and a close that was asked
  for is distinguishable in the logs from a fault. Durable state stops
  at a commit boundary either way, because commits are atomic in the
  storage actor. A tree that will not stop inside the grace is killed
  and the handle is closed regardless: a session locked out for a whole
  lease TTL is the worse failure. Nothing terminal is written; reopening
  recovers the open operation.
- **A hint with nowhere to go is a non-event, and never the writer's
  death.** Post-commit publication skips a subscriber whose owner is
  gone. Sending into an *unregistered name* crashes the sender, so
  without the guard a supervised, restartable subscriber held by name
  would make the writer — and the whole rest-for-one tree beneath it —
  hostage to that subscriber's restart window. Events are hints and
  pulls are truth (design §3.6), so dropping one costs latency and
  nothing else.
- **A lost lease stops the writer abnormally** so the supervisor reboots
  the tree, whose reopen path re-acquires or fails loudly. Renewal runs on
  an idle timer at a third of the TTL. A commit that races the renewal
  loses too, and arrives as `tx.LeaseLost`: `runtime/api` turns it into
  `SessionStolen`, and `runtime/strand_runtime` halts the strand on it
  rather than reloading, because reloading reads the same file and meets
  the same fence.
- **The names, not the pids, are the addresses.** The writer and each
  strand register under fresh process names so restarts keep them
  addressable.
- **Log context reaches an effect process because the closure carries
  it, not because anything is inherited.** `spawn_effect` takes the
  step-scoped logger as an argument, and the body that runs on the new
  process closes over it — Erlang `logger` metadata does not survive a
  spawn, so a driver that relied on inheritance would emit its most
  interesting lines uncorrelated. The spawned body additionally calls
  `log.adopt`, which stamps the same `{session, strand, op, step}` into
  that process's `logger` metadata so an OTP crash report *about* the
  effect process is correlated too. See `telemetry/context` for why the
  value is the mechanism and the metadata only the fallback.
- **What the drive loop logs, and at which level.** `info` for the
  durable state changes — `strand.started`, `operation.settled`,
  `operation.aborted`; `warning` for degraded-but-progressing —
  `retry.armed`, `effect.exited`; `error` only for `strand.halted`,
  which is the one thing the strand cannot recover from on its own;
  `debug` for `effect.dispatched` / `effect.settled`, which is per step
  and off by default. A tool that failed *in band* is a settlement like
  any other and stays at `debug`: that is the system working.

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the drive loop, the supervision tree, doorbells, the interleave
  harness.
- [docs/architecture/simulation.md](../../docs/architecture/simulation.md) —
  what the deterministic runner does to this tree.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-E": crash
  semantics, boot seeding, close-as-crash, injected entropy, minimal writer
  events. "From the M3 runtime wave": escalations as registers, opaque
  grant JSON, abort-race pacing, parallel dispatch's exclusivity.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
