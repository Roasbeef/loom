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
  Report, Corroboration}` — seed in, verdict out. A `Failed` verdict
  carries a `Corroboration`: the seed is replanned and re-run up to
  three times, and `Reproducible` means every run failed while
  `Unstable` means the same script under the same schedule reached
  different verdicts. Both, plus the run's own `[timing]` evidence, are
  folded into `Failure.detail` so every existing printer shows them.
- `conformance/simulation/script.{Script, Op, Settle, Intervention}` — the
  semantic half: what the session is *asked* to do. `Script.subagent` is
  the multi-strand coda: an optional brief that spawns a subagent strand
  and sends its findings back to main. `Script.parallel` *chooses* the
  batch mode — `Parallel` when set (a parallel script always carries a
  two-call batch, so the overlapping frontier is real), `Sequential`
  when not. It names both rather than inheriting `api.default_options`,
  which now ships `Parallel`; inheriting would make every seed a
  parallel seed and lose half the oracle's coverage.
  `Script.escalate` drives the durable escalation machinery — the first
  clearance raises an escalation scoped to exactly that call, approves
  it, and restarts the strand driver so the same durable coordinates
  re-clear with the grant, all under the fault schedule.
- `conformance/simulation/fault.{Fault, Schedule}` — the taxonomy of things
  a session must survive without anyone noticing.
- `conformance/simulation/random.Rng` — a splittable SplitMix64; the only
  source of choice.
- `conformance/simulation/vclock.Clockwork` — the one logical clock and its
  timer wheel.
- `conformance/simulation/control.Control` — the counters, one-shot claims,
  and runtime handle that outlive the session tree. Also
  `control.Attempted`, the three-way outcome of running an action on a
  disposable process: `Answered`, `Raised` (the carrier died — surfaced
  immediately as a one-task `weft` run's `Crashed` outcome, so it costs
  no wall-clock time), and `Expired` (a real millisecond budget ran out,
  via `weft.deadline`). `Raised` and `Expired` are equally uninformative
  about whether the action happened, and callers must treat them alike.
  It is also the rendezvous a live-triggered intervention uses to hand
  its decision to the runner: `await_intervention` registers a trigger
  and blocks, and `take_pending_interventions` is what the drive loop
  drains on every pass to find something to fire (#57).
- `conformance/simulation/{store, surface, invariant, wire}` — the
  instrumented session, the scripted effect surface, the named per-run
  checks, and the framing properties.

## Relationships

- **Depends on**: every Gleam package it tests — `core`, `storage`,
  `session`, `machine`, `runtime`, `provider`, `broker`, `tools`, and
  `client` (whose promoted `client/wiring` the wiring and e2e suites
  prove) — plus `gleam_erlang`, `gleam_otp`, and `weft` (the one-task
  bounded run behind `control.attempt`). This is deliberate and unique.
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
  runtime handle, the seam arm/quiet protocol, the harness-conduct
  record behind `Report.waits`, and the atomic intervention claim) and
  `vclock.Message` (now, schedule, advance, park). Both are calls. The
  runner also subscribes to `runtime/writer.Event.Committed` indirectly
  through the instrumented store's commit counter.
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
  during a child's effects exercise the boot-all-strands recovery path —
  and, since the M3 escalation-boundary wave, also the parallel frontier
  (`parallel-tools`), the escalation dance
  (`escalation-raised`/`escalation-consumed`), and the partial crash
  (`strand-restart-during-effect`). Terminal detection prefers the
  operation-keyed `operation-result/{op}` record and reports a violation
  when a terminal is reachable only through `strand.last_result`.
- **Wire**: `simulation/wire` generates byte streams straight into
  `broker/framing`'s deframer — no helper involved; the jailed e2e drives
  the real `loom-exec` through the broker.

## Invariants

- **Faults are transparent by definition.** A schedule may crash the tree
  at a commit boundary, kill it mid-effect, restart a single strand
  driver mid-effect (`RestartStrand` — the partial crash the reaper must
  survive), refuse a commit as stale, fault a read, steal the lease, drop
  or delay a doorbell, starve an effect, or lose an effect process — and
  none of it may change what the session ends up having done. Anything
  that legitimately changes the outcome (a provider that refuses, a user
  who aborts) is scripted into *both* runs so it cannot be mistaken for
  damage.
- **Starved provider owners end with their consumers.** The simulation's
  one-shot timeout owner monitors the effect process that requested it. A
  killed effect therefore removes both the owner and its unused terminal
  capability instead of leaving a synthetic process behind the conformance
  run.
- **A composition-layer service is proved absent, not merely
  well-behaved.** `conformance/triggered_rules_test` is the end-to-end
  for issue #27: real wiring, real gateway, real adapter, real runtime,
  a real supervisor over the real scanner, and only the HTTP transport
  scripted. Its isolation row kills the scanner while a turn is in
  flight — an absent scanner being the strongest available form of "an
  expensive scan cannot delay a settlement" (design §10) — and asserts
  the transcript is exactly what the script implies, request for
  request, before showing the rule still fires off the durable marks
  once the supervisor has replaced it. The one piece of stage machinery
  is a transport that waits for the durable fired-mark from the second
  turn on, which settles the scenario's only race — was the steer
  durable before the checkpoint that drains it — without touching
  anything under test.
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
- **The wall clock is a deadlock backstop, and says so when it fires.**
  `control.attempt` is how anything reaches into a tree that may be
  mid-restart. It runs the action inside a one-task `weft` run bounded
  by `weft.deadline(within_ms)`; that budget is real milliseconds — it
  cannot be logical, because the action blocks on a real OTP call and
  the runner is the process waiting on it. What used to reach that
  budget routinely was the carrier *dying*; that is now surfaced
  immediately as weft's `Crashed` outcome (mapped to `Raised`) and costs
  no clock, which leaves the budget bounding only a wedge nothing is
  expected to reach. Every `Expired`, every `Raised`, and every scripted
  intervention claimed but never seen to land is recorded through
  `control.note_wait` into `Report.waits` and named in the failure the
  run reports. Neither `Raised` nor `Expired` is evidence the action
  failed: an admission whose reply was lost may already be durable, and
  every caller asks the durable state rather than concluding (issue #44,
  and the same ambiguity #6 records).
- **A failing seed says whether it is repeatable.** `run`, `examine`, and
  `check` replan the failing seed — same script, same schedule, since
  `plan` draws only from the seed — and re-run it up to three times
  before reporting. Shrinking is skipped for an unstable seed, because
  "does this smaller schedule still fail?" is answered by coin toss
  there. An unstable verdict is not an all-clear: a genuine race in the
  code under test is unreproducible too, so what it licenses is
  comparing *rates*, never dismissing the run.
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
  would be. The drive budget counts consecutive silent passes, not the
  operation's lifetime: every writer commit proves durable progress and
  replenishes it. Charging progress against the stall allowance made loaded
  Linux runs fail at moving seeds even though each immediate replay passed.
- **One clock, one era.** The storage backend's timestamps, the strand
  driver, the effect scripts, and id minting all read the same `Clockwork`.
  Separate real clocks across runtime, tools, and broker drift, and that
  drift once made the broker refuse every call as past deadline (spec-gaps,
  M2 item 1).
- **Every check has a name.** "The simulation failed" is not a bug report.
  Boundary checks run inside the commit path so a violation is caught at
  the transaction that caused it; terminal checks run once the strand is
  idle.
- **An intervention that does not land is a violation, not a shrug.**
  `surface.apply` honors the `Result` of `api.steer_quietly` and
  `api.follow_up`: every `api.ApiError` reaches it having written
  nothing, so a refusal is a turn the transcript has permanently lost
  and it is recorded through `control.note` — `Report.violations`, which
  `sound` fails the seed on. Two refusals are deliberately exempt and
  marked instead of noted: an `AtTerminalCommit` steer, where the run the
  item would attach to is already closed and refusal is the documented
  outcome, and an admission whose reply the surface did not observe,
  which is not evidence the commit failed. The recording lives on an
  error path and touches no schedule, so the seed corpus keeps its
  meaning as a before/after oracle. The runner takes the intervention's
  in-memory one-shot claim, while the instrumented store derives the same
  identity from the queued message's opaque signature and folds a reserved
  write-once fact into the admission transaction. A retry after a lost reply
  can therefore ask whether the payload is already durable: a landed first
  attempt closes the debt, while an absent fact permits a new carrier without
  admitting the turn twice. When queue admissions and an abort share one
  logical trigger, `surface.fire_due` preserves the queue admissions' script
  order but sends the abort after them. The abort API is an asynchronous cast;
  sending it first made seed 584's fault-free transcript depend on whether the
  Linux or macOS scheduler processed the cast before the next synchronous
  admission.
- **A live intervention's decision belongs to the runner, never to the
  effect that reached its trigger** (#57, diagnosed under #44). A
  `DuringTurn`/`DuringCall` trigger is reached from inside a real effect
  process, and a `RestartStrand` fault reaping that process before
  `control.attempt`'s own bookkeeping ran meant some lost admissions
  carried no `raised@`/`expired@` tag at all — a silent dangling
  `intervening@path` instead of one with a cause attached. So
  `surface.intervene` no longer admits: it only asks whether the script
  has anything due at this trigger and, if so, calls
  `control.await_intervention` and blocks without an independent timeout.
  This rendezvous carries a payload, not a loss-tolerant wake-up: resuming the
  effect while its trigger remained queued would let the admission land after
  the settlement it must precede. The runner's drive loop
  (`service_interventions` in `runner.gleam`, called from `pump_strand`
  on every pass) drains `control.take_pending_interventions` and fires
  each one through `surface.fire_due`. The block is
  what keeps a live-triggered steer landing before the settlement that
  follows it: the effect does not resume until the runner reports the
  admission durable, so the ordering `steer-during-effect` depends on is
  still by construction, not by luck — only the process carrying the
  admission moved, from the effect to the runner, which is never a
  target of any fault in the taxonomy. If that runner-owned carrier loses its
  writer call during restart, `surface` reads the transaction's atomic fact
  directly from the raw durable session: it settles an admission that already
  landed, or retries one that did not. There is no post-commit counter for a
  crash to overtake. The `intervening@path` / `intervened@path` bracket remains
  as a tripwire for any future path that spends a claim without making the
  payload durable.
- **`terminal/last-result-once` is fenced across commit visibility** (#58).
  The memory actor can publish a terminal transaction before the
  instrumented wrapper records its side counters, while the runner reads
  that inner actor directly. `CommitStarted`/`CommitSucceeded` hand the
  accounting fence atomically to the post-commit seam, keeping `seam_quiet`
  false through successful bookkeeping; `CommitFailed` releases refused
  commits. The deterministic `simulation_store_test` probes immediately
  after the raw commit becomes visible and checks both success and failure.
  The production terminal transaction and the exact once oracle are
  unchanged. See `docs/architecture/simulation.md`, "What this does not
  cover".
- **The perf smoke asserts, it does not merely print.** `storage_suite_test`
  holds the `scan_branch` p50 to `perf_p50_ceiling_us` (15 ms) rather than
  to the 5 ms M0 target it reports against — shared CI hardware has
  produced a *max* above 5 ms on a run whose p50 was 3.1 ms. What that
  bound proves is that the scan still costs single-digit milliseconds on
  the machine that ran it; what it does not prove is the M0 target, and
  the `EXPLAIN QUERY PLAN` assertions next to it remain the precise guard
  on which index the scan uses.
- **The deframer must be total** and is property-checked as such: chunking
  is irrelevant, damage is reported rather than silently survived, and
  truncation carries the partial bytes for a rest that never comes.
- **`let assert` is permitted in this package's `src`**, unlike everywhere
  else (spec §0.2). A suite or runner whose fixture will not construct has
  nothing to say; the module docs state the exemption where it is used.
  Lint R4 (`panic`/`let assert` outside tests) now gates the whole tree at
  **error** level, and it reaches this package's `src` the way it reaches
  everyone's — so the exemption is named rather than implied:
  `lint/policy.harness_packages` lists `conformance`, and `lint.check`
  applies it from the path. Nothing else in the tree is on that list, and
  adding to it is a decision to be argued in `packages/lint/CLAUDE.md`'s
  Staging section, not a prefix that grows quietly. The ninety `let
  assert`s here were a third of the whole lint census and carried no
  signal, which is what kept the one rule the root `CLAUDE.md` states as
  policy from being enforced anywhere.

  The exemption covers the **construct and not the message**. Part IV rule
  3 admits `panic`/`let assert` only "always with an `as \"message\"`"
  naming the invariant; none of the ninety sites here carries one, R4
  checks presence rather than message, and the checker for that half is a
  separate rule nobody has written yet (issue #73, item F). So this list
  excuses `let assert` in a test harness — it does not excuse a bare one.

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
