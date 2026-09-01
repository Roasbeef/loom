# Design note: adopting weft

Status: **built through phase 2; loom#159 is the plan of record and
checklist, and `docs/weft.md` is the standing guide.** A
survey of where [weft](https://hex.pm/packages/weft)
(`github.com/Roasbeef/weft`) could replace hand-rolled concurrency
machinery in this tree, what it would cost, and the one migration that
must *not* happen. Findings come from a full sweep of every effectful
package, verified against the sources at the cited lines; line numbers are
as of `main` at `dd84063`. Since the survey: tier 1's first two items are
built (the recovery gate on `weft/actor.continuing`, the TUI's guarded
startup on a one-task run), and the phase-2 half was designed and
implemented upstream as weft PR #6 — see the addendum at the end.

## What weft is

Weft is a Gleam library of four modules: `weft` (owned, bounded task
fan-out — a scope process owns every worker by link topology, with
`limit`, `deadline`, external cancel, input-order `start` and
completion-order `fold`), `weft/actor` (a strict superset of
`gleam/otp/actor`: a `continuing` init message guaranteed to be handled
before the mailbox, `then_handle`, `hibernate_after`, `idle_timeout`,
`on_shutdown`, `trapping_exits`), `weft/state_machine` (a typed
gen_statem: state ADTs with exhaustive dispatch, `postpone`, state /
event / named timeouts, enter callbacks), and `weft/event_manager` (a
typed gen_event over closure-encoded heterogeneous handlers).

The fit with loom's dependency picture is exact and free: weft requires
`gleam_otp >= 1.3.0`, which is precisely what the tree already resolves
(`manifest.toml` pins 1.3.0), `gleam >= 1.18` matches the ground rules,
and every weft `start`/`supervised` returns `gleam_otp`'s own
`StartResult`/`ChildSpecification`, so a weft actor drops into an
existing supervisor unchanged. Weft is erlang-target only, which is fine
everywhere OTP is already allowed — and decisive where it is not, which
is the next section. Its vendored linter is this repo's own `packages/lint`,
so the two trees already share style DNA.

## The migration that must not happen: `machine`

The obvious-sounding move — port `machine/planner` onto
`weft/state_machine` — is ruled out, and it is worth writing down why so
nobody re-litigates it.

`core`, `machine` and `prompt` are the portable subset: no `@external`,
no `gleam_erlang`, no `gleam_otp`, gated at error level by lint R6. Two
properties rest on that rule (`docs/gleam-style.md` Part IV §5): the
operation state space stays property-testable without spawning processes,
and the three packages stay compilable to JavaScript. Weft imports
`gleam_erlang` and `gleam_otp` in every module and declares
`target = "erlang"`; one `import weft/state_machine` in `machine` closes
both properties at once.

The rulings are also not in tension, because the two state machines are
different kinds of thing. `machine/planner.next_action` is a *pure
function* `State × Inputs → Action` — the state lives in durable
registers, not in a process, and recovery is the same function over
restored registers. `weft/state_machine` is a *process behaviour* — its
state lives in a loop and dies with the pid. The machine is the decision;
weft is a way to host decisions in a process. What can move onto weft is
therefore never the machine but the **drivers**: the effectful actors that
interpret the machine's actions, which today hand-roll exactly the
process-level patterns weft packages (state-scoped timers, postponed
messages, deferred init, kill-then-join teardown).

## Where the wins are

The survey found roughly **1,450 lines** of hand-rolled machinery whose
pattern weft provides, across nine sites. Replacements are not zero lines
— a realistic net deletion is on the order of 600–900 lines — but the
deeper win is that four recurring bug-shaped patterns (stale-timer
staleness guards, pending-message lists, dual-dispatch init gates,
spawn/monitor/kill scaffolds) become library contracts with one owner.
Ranked by LOC-reduction-per-risk:

### Tier 1 — high confidence, self-contained

1. **`runtime/strand_runtime` recovery gate → `weft/actor.continuing`**
   (`strand_runtime.gleam:209` `RecoveryGate`, dispatch around `:433`,
   ~60 lines). The driver starts before the reaper's predecessor-drain
   claim resolves, so every handler opens with a
   `case state.recovery_gate, message` matrix: pre-barrier `Nudge` is
   dropped, pre-barrier `RequestAbort` is carried as a hand-held
   `abort_requested: Bool` flag, and `PredecessorsResolved` flips the
   gate. This is the deferred-init race `continuing` exists to close: a
   guaranteed-first injected message whose handler blocks on the reaper's
   handshake, after which the ordinary handler sees a mailbox that simply
   queued. The `abort_requested` flag is *deleted*, not relocated — the
   abort waits in the mailbox like any other message. The message universe
   during the gate is provably tiny (`PollTick` is not armed until after
   the gate clears), so the semantics match is exact. Bonus: the flag is
   one of R9's naked-`Bool` census entries, so this retires a lint warning
   too.

2. **`tui/connection.start_safely_within` → `weft` single-task run**
   (`connection.gleam:142-175`, ~35 lines). Hand-rolled
   spawn-unlinked / monitor / race-reply-against-DOWN / kill-on-timeout —
   exactly `weft.new([task]) |> weft.deadline(ms) |> weft.start` with the
   outcome vocabulary (`Completed`/`Crashed`/deadline-`Abandoned`) the
   surrounding comments already reason in. The load-bearing invariant —
   a crashing initialiser must not take the terminal down — is weft's
   core guarantee: workers link to weft's scope, never to the caller.

3. **`broker/exec` timer bookkeeping → `weft/state_machine`**
   (`exec.gleam:328-329` message variants, `:399-404` handshake arm,
   `:693-747` cancel escalation and staleness guards, ~130 lines of the
   ~180 the file spends on timers). The helper actor is a
   `AwaitingHello → Ready → Dead` machine whose `CancelDeadline(exec_id)`
   carries an id purely so the handler can detect a stale fire, and whose
   `HandshakeDeadline` handler re-checks the phase for the same reason.
   `with_state_timeout` makes both guards structural: the timer dies with
   the state that armed it. **Carve-out:** the `HeartbeatTick` is a
   periodic liveness probe, not a one-shot timeout — none of weft's three
   timeout kinds model "fire every N ms regardless of activity", so it
   stays hand-rolled (a self-re-arming event timeout is a forcing, not a
   fit). The `run_cleanup` idempotency flag and the monitor-based janitor
   at `:1674` also stay: `on_shutdown` cannot run on an untrappable kill,
   which is the exact case the janitor defends.

### Tier 2 — strong pattern match, denser invariants

4. **`codemode/launch` node-report holder → `weft/state_machine`**
   (`launch.gleam:350-448` plus the types, ~118 lines). A raw
   `spawn_unlinked` + `receive_forever` loop over
   `Pending | Running | Done` with a hand-kept `waiting: List(Subject)`
   of askers to flush on settlement and a final bounded receive so the
   janitor's second `destroy` is answered from memory. The `waiting` list
   is `postpone` on `Ask` (redelivered on the transition to `Done`); the
   lingering receive is a state timeout on the terminal state. Two
   teardown-ordering invariants in the comments (`Cleared`-after-teardown
   cancels; teardown-while-`Running` cancels) are the port's test gate —
   the existing two-`destroy` race test must pass unchanged. Not an
   OTP-visible process today, so the port also gains `sys` compliance.

5. **`runtime/strand_runtime` effect reaper → `weft/state_machine`**
   (`:1488-1616`, ~130 lines of loop/selector scaffolding). `reap` and
   `await_drain` are two mutually-recursive loop bodies over the same
   selector differing only in per-state policy — gen_statem's exact
   shape, hand-rolled. States `Reaping`/`Draining`, adopted-effects list
   as machine data; the synchronous `Adopt` acknowledgement stays a
   `process.send` inside the handler. The reaper guards the drain barrier
   that writer-lease release and recovery ordering rest on, so the
   invariant review is the cost, not the mechanics. Note the reaper must
   remain a *standalone* trapping process that outlives a killed driver —
   `on_shutdown` could never play this role, which is why the target is
   `weft/state_machine`, not an actor hook.

6. **`conformance/simulation/control.attempt` → `weft` single-task run**
   (`control.gleam:597-650`, ~55 lines). Same spawn/monitor/deadline/kill
   shape as the TUI's; `Answered`/`Raised`/`Expired` is weft's outcome
   taxonomy with local names. The port must preserve the comment trail
   explaining why this one function reads the wall clock inside an
   otherwise logical-clock package, or a future reader will "fix" it.
   Broad blast radius across the simulation runner despite the small diff.

### Tier 3 — biggest LOC, needs a spike first

7. **`provider/gateway.guard_request`/`guard_cancelling` →
   `weft/state_machine`** (`provider/gateway.gleam:495-770`, ~276 lines) and
8. **`client/provider_relay` four-state forward/cancel guard**
   (`provider_relay.gleam:314-669`, ~320 lines, the same grace-timer arm
   copied at three sites). Both are the README's `Connecting`/`Backoff`
   example at production scale: mutually-recursive functions standing in
   for states, one grace timer per state armed by hand. The multi-source
   inbox (pump events, monitors, consumer-down) is *not* a blocker —
   `weft/state_machine`'s `selecting` replaces the default selector, so
   monitors fold into the machine's message type the same way
   `request_selector` builds them today. Two real cautions: these
   functions are synchronous phases inside an already-spawned worker, not
   a long-lived server, so the port either restructures the worker as a
   machine or accepts one more process per request; and this is PR #133's
   freshly-landed custodian/drain-witness territory
   (`protocol-change/010`), where the race table was written against the
   current topology. Spike on `gateway` first; `provider_relay` follows
   only once the pattern proves out. The same verdict covers the
   provider-await two-phase timeout duplicated at
   `strand_runtime.gleam:1879` and `internal/provider_custodian.gleam:192`
   (~220 lines): textbook state-timeout shape, wrong process packaging to
   adopt blindly.

9. **`client/mcp.start` server bring-up → `weft.start` + `partition`**
   (`client/mcp.gleam:299-324`, ~30 lines). Today each server handshake blocks
   the next, so N misconfigured servers pay their timeouts serially at
   boot. `weft.start` returns outcomes in input order, so the documented
   "in catalogue order" contract holds; verify nothing depends on
   *temporal* startup order of stdio subprocesses before parallelizing.
   More a latency win than a LOC win.

## Where weft deliberately does not fit

Recording the rejections so the next survey does not repeat them:

- **`events/bus`** — `pg`-backed cross-process group membership; its own
  CLAUDE.md already explains why an in-process handler list (which is
  what `weft/event_manager` is) was rejected. Different problem.
- **`runtime/writer` subscriber fan-out** — raw `Subject`s with no
  per-handler state and no failure to isolate; `event_manager` would add
  a process for nothing. In fact the survey found **no** current
  `event_manager` fit anywhere in the tree — loom's fan-outs are either
  `pg` groups or homogeneous subject lists.
- **`provider/custodian`** — monitor-based adoption of a *dynamically
  growing, heterogeneous* set of already-running owners, with
  `Leaf`/`Transitive` drain semantics and a poisoned-exit signal. Weft's
  fan-out owns a known list of closures started together; no primitive
  matches. At most, its raw receive loop could sit on `weft/actor` for
  `sys` compliance — no logic would simplify.
- **`codemode/launch` janitor, `broker/exec` janitor** — both defend
  against untrappable kills, which `on_shutdown` structurally cannot see.
  Keep the monitors.
- **`mcp/client` in-flight expiry table** — N independent per-call
  deadlines in a dict; weft's timeouts are scoped to one machine's one
  current state, so a port would just rebuild the dict beside the machine.
- **`broker/broker.clear_awaiting_helper`, `runtime/api.await_result`,
  `client/agency.wait_loop`** — blocking retry/poll loops in the caller's
  own process, deliberately (the broker one documents why moving it into
  the actor would deadlock). Weft has no synchronous-backoff primitive.

## Costs and the adoption path

The costs: a new dependency at v0.1.0 whose API may still move (though
loom would be its first serious consumer, which is influence, not just
risk — e.g. the periodic-timer gap in finding 3 and the per-call deadline
table in `mcp/client` are upstream feature candidates); one more thing
`docs/gleam-style.md` Part III's actor guidance must acknowledge; and the
usual truth that a library contract is only as good as its tests — weft's
kill-then-join and ordering contracts are tested, but nothing here has
run under loom's conformance simulation yet.

The path that de-risks it: adopt in tier order. Tier 1 (recovery gate,
`start_safely`, broker timers) is three small PRs, each deletable in an
afternoon and each independently reversible, and together they exercise
all three weft modules loom would use (`actor`'s `continuing`, the run
engine, `state_machine`'s state timeouts). Only after those hold under
`make check` and the e2e gates does tier 2 touch the reaper and the
code-mode holder, and only after a gateway spike does tier 3 commit to
the ~800-line provider/client guard consolidation. If only tier 1 ever
lands, the dependency still pays for itself in retired staleness guards.

## Addendum: weft#5, measured and then built

Roasbeef/weft#5 (managed tasks with transitive drain proof) generalizes
exactly the ownership protocols PR #133 shipped here by hand — the
strongest evidence being that `protocol-change/010`'s proposed API is
implemented verbatim in `provider/stream.gleam`, and the
publish-parked-owner-then-begin dance appears six times across the tree
(`provider/custodian.prepare`'s protocol, `gateway.prepare`,
`gateway.start_request`, `gateway.register_attempt`,
`provider_relay.guard`, `runtime/internal/provider_custodian.prepare` —
the last is `prepared_task` almost word for word). A second census pass
measured what an implemented weft#5 would subsume:

| File | Deletable | Restructured | Untouched |
|---|---:|---:|---:|
| `provider/custodian.gleam` (465) | ~410 | ~55 | ~0 |
| `provider/stream.gleam` (1282) | ~300 | ~150 | ~830 |
| `provider/gateway.gleam` (1335) | ~370 | ~280 | ~685 |
| `client/provider_relay.gleam` (803) | ~620 | ~140 | ~40 |
| `runtime/strand_runtime.gleam` reaper + await | ~135 | ~120 | ~75 |
| `runtime/internal/provider_custodian.gleam` (354) | ~100 | ~100 | ~115 |
| `runtime/internal/drain_registry.gleam` (224) | 0 | ~15 | ~200 |
| **Total** | **~1,935** | **~860** | **~1,945** |

The deletable band is the generic witness machinery; the restructured
band is loom's terminal-arbitration policy riding on the primitive; the
untouched band is real domain (SSE parsing, wire vocabulary, fallback
walking, credential scrubbing) plus the one genuinely irreducible piece:
`drain_registry`, which sequences **across driver generations** — a chain
of scopes for the same logical strand — where weft's model is
single-generation by design.

The census also surfaced the mismatches loom#159 lists in full: the
grace-bounded `CancellationUnconfirmed` third outcome, the
leaf-versus-transitive owner split, dynamic mid-run adoption, ownerless
`immediate` streams, recursive poison propagation, the reaper's
survive-the-caller lifetime, and push-versus-pull delivery into an actor.
**Weft PR #6 implements the issue plus most of that list**: `prepared_task`
/ `prepared_leaf`, `DrainProofLost` and `CancellationUnconfirmed`
outcomes, `cancel_grace` (one window per teardown, bounding the wait at
the price of the exit verdict), the scope's exit reason as the drain
verdict (poison propagates by monitor, no translation code), detached
runs whose scope survives a dead holder and drains before exiting, and
`start_relayed` as the push adapter. Composition — a nested detached
scope as a publishable owner — is its answer to nested ownership;
dynamic adoption and the periodic timeout kind stay open upstream.
Phase 2 here stays gated on that PR merging and publishing.

What landed in this tree so far, per loom#159's tier 1:

- `runtime/strand_runtime` — the strand driver is now a `weft/actor`; the
  `RecoveryGate` dual-dispatch matrix and its hand-carried
  `abort_requested` flag are deleted in favor of a guaranteed-first
  `AwaitPredecessors` message that blocks on the ledger claim. One
  deliberate semantic change: an abort that arrives during the barrier is
  now handled *after* the first post-barrier drive rather than instead of
  it — equivalent because an abort racing a dispatch is already the
  ordinary case, at the cost of one possibly wasted dispatch in that rare
  race.
- `tui/connection.start_safely_within` — the spawn/monitor/kill scaffold
  is a one-task `weft` run with a deadline; the `StartReport` type is
  gone and the behavior-pinning tests pass unchanged.
- `broker/exec` — the helper is a `weft/state_machine` whose state is
  its lifecycle (`AwaitingHello | Idle | Running | Cancelling | Dead`).
  The handshake deadline is a state timeout on `AwaitingHello` and the
  cancel escalation a state timeout on `Cancelling`, so the execution id
  the cancel timer carried for stale-fire detection, the phase re-check
  in the handshake handler, and the hand-cancelled `cancel_timer` field
  are all gone. The heartbeat tick stays hand-rolled (no periodic
  timeout kind), as do the cleanup flag and the janitor. Mutation-tested:
  removing either state timeout fails exactly its escalation or
  handshake test.
- `codemode/launch` — the node-report holder is a `weft/state_machine`.
  The hand-kept `waiting` list is `postpone` on `Ask`, replayed on the
  transition to `Done`; the lingering bounded receive is a state timeout
  on `Done` armed once torn down; the naked `torn_down: Bool` is a
  two-variant type. weft has no unlinked start, so an unlinked trampoline
  starts the machine to keep the holder alive for the janitor's second
  `destroy`. The two-destroy race test passes unchanged.
- `conformance/simulation/control.attempt` — a one-task run with a
  deadline; `expired_when_silent` is deleted and its wall-clock comment
  trail moved onto the arms that now express it. Mutation-tested against
  the expiry test.
- `client/mcp.start` — server bring-up fans out over a weft run bounded
  by the catalogue length; input-ordered outcomes keep the catalogue-order
  contract. The link-topology caution in tier 2 item 9 was measured and
  found empty: `start_client` already severs the client actor from its
  caller two unlinked spawns down, so no relink was needed.
- `runtime/strand_runtime`'s reaper loop (tier 2 item 5) is deliberately
  **not** ported to `weft/state_machine` in phase 1: phase 2c
  re-expresses the reaper on managed tasks, and restructuring it twice
  would be waste.

Phase 1 is therefore complete except for the reaper, which phase 2 owns.
The tree stays on weft 0.1.0 through this pass; the move to the managed
task surface is phase 2's first commit.

## Addendum: phase 2, built

Phase 2 landed on branch `weft/managed-adoption`, developed against the
sibling weft checkout as a path dependency and to be switched to the hex
range once 0.4.0 is published. What weft had to grow first, and what each
loom site became:

**Weft additions, all additive** (weft `main`, 0.3.0 through the working
version): `managed` tasks whose `begin` receives a `Ledger` and publishes
owners while the run is live (`adopt`, `adopt_leaf`), many owners per
task with an aggregate proof and a single seal; `adopt_under` /
`adopt_leaf_under`, which stage a child beneath a parent owner so it is
asked to stop only once the parent has exited; `start_witnessed` (a run
with no consumer, its scope's exit the whole report, behind a `Witnessed`
handle with `witness_pid` / `cancel_witnessed`); `cancel_when_exits`; a
pid that is both watched and adopted answering both watches; `unlinked`
start on the actor and machine builders; `with_selector` on a machine
step; and `weft/poll` for bounded foreground waits. Two review fixes rode
into 0.2.0 before merge: a cancel helper that was never dismissed when
its owner exited, and a dead-on-arrival leaf owner that vanished from the
account.

**2a — the custodian is a facade over a witnessed run** (`provider/
custodian.gleam`, 465 → 296 lines, public API unchanged). The worker is a
leaf owner whose cancel is its stop message; its exit and the consumer's
exit are cancel causes; every child is published beneath the worker;
ownerless adoption is a permit check against a leaf that exits at once;
a lost proof cancels the run (`CancelSiblings`). Two behaviour changes
were measured and accepted: the witness asks owners itself at teardown,
so an owner may hear its cancel twice (cancel capabilities are idempotent
by protocol-change/010; the gateway test that pinned exactly-once now
pins "every cancel names the primary and no fallback starts"), and the
poisoned exit reason is weft's `weft_drain_proof_lost` rather than a
kill (every judgement in the tree treated the two alike already).

**2c — the effect reaper is a witnessed run** (`runtime/strand_runtime`,
351 lines of ledger and loop deleted, 151 added). Effects adopt
themselves as leaf owners with their stop capability; a provider effect
publishes its stream owner beneath itself so the effect's exit cancels
the stream; the drain ledger monitors the scope pid; the claim moved into
the driver's `continuing` handler naming the scope. A lost proof cancels
the run and exits abnormally, which the ledger reads as it read the
self-kill.

**2b — the guards are state machines.** `provider/gateway`'s request
guard (nine phases, three state timeouts, 593 lines of loop deleted and
983 written back, most of it the matrix and its prose; one pre-existing
coverage gap closed by a new test), `client/provider_relay`'s guard (the
grace as a state timeout, the request deadline as an event timeout, the
observer queue as data, +229 net), and `runtime/internal/
provider_custodian`'s parked worker (four states, `Parked` real, the
selector widened on the permit with `with_selector`, +336 net). The
prepare/publish/begin dances survive at the three sites as the
machines' `Parked` state rather than as a shared helper: each site's
permit carries something different (a custodian, a custodian plus an
acknowledgement, a bare permit), and the census found the shared helper
would net nothing.

**The rest of the census** (a fifteen-package sweep, one reader per
package, spot-checked): the tui image read and the code-mode served call
became one-task runs with a deadline; the exec helper's ready-waiter list
became `postpone`; the launcher's four waits, `api.await_result` and the
satellite accept loop became `weft/poll`; the simulation's starved owner
became a witnessed run. Kept, as named rejections: `cap/task` (a clean
fit, but `cap` is the satellite-side prelude with no weft dependency, and
adding one puts weft into the offline build seed — a distribution
decision); `broker.clear_awaiting_helper` and `client/agency.wait_loop`
(they charge attempts against the injected logical clock, which
`weft/poll` cannot run on); `client/escalate.park` (injected sleep);
`mcp/client`'s per-call expiry table; the two untrappable-kill janitors;
`events/bus` on `pg`; `weft/event_manager` fits nothing in the tree.

**The line count, honestly.** Source under `packages/*/src` moved by
+4,046 / −2,855 across the whole adoption (net +1,191 over seventeen
files), and the three guards account for most of the growth. The survey's "deletable"
figures counted mechanism without counting what an exhaustive port
writes back: every `case state, message` pair, the unreachable ones
included and commented, and the literate prose each arm carries. What
shrank is the number of places a race is decided (one ledger, one timer
book, one cancellation order), the lint census (R8 moved-pyramid 7 → 5 in
the gateway, R11 dense-stanza 2 → 0, R9 naked-bool retired at four
sites), and the test surface (weft carries 131 tests for the contracts
loom used to keep by hand, and the mutation results above are the
evidence that loom's own tests still watch the seams).

**Mismatches from loom#159, resolved:** grace-bounded acknowledgement —
kept as a loom seam: no `cancel_grace`, each layer's report timer stays,
the witness keeps waiting; leaf vs transitive — upstream; dynamic
adoption — upstream (`managed`/`adopt`); ownerless work — loom seam (the
immediate leaf); recursive proof loss — upstream (the scope's exit
reason); scope lifetime — upstream (a scope survives its holder's death
and drains); push consumption — upstream (`start_relayed`), unused
because the witnessed shape fit better; periodic timeout kind — still
open upstream, three sites re-arm by hand; per-key deadline tables — a
standing rejection.

**Verification** ran at each step: every package gate, the full
`make check`, a 200-seed soak on the 2c tree, and a real session driven
through the terminal against a Baseten catalogue — a plain prompt, a
sub-agent spawn and wait, and a code-mode program in a jailed satellite —
with no lost-proof or unconfirmed event in any server log.

