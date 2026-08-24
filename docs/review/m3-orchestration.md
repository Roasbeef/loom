# Adversarial review — M3 orchestration surface (multi-strand runtime + machine wave)

## Scope and method

Read-only adversarial review of the M3 orchestration wave:

- `packages/runtime`: `api` (multi-strand operations, blackboard, durable
  escalations), `registry`, `supervisor` (booter, strand factory),
  `strand_runtime` (abort settlement fidelity, parallel dispatch,
  clearance/grants), `escalation`, `hooks`, `writer`, `effects` — read
  line by line.
- `packages/machine` M3 changes (commit `5efcf4b`): parallel batch
  dispatch in `planner`, abort usage retention (`settle_assistant` /
  `settle_poll` cancelled paths), `request_api` capture
  (`operation`/`codec`/`classification`), the leaf expectation in
  `acceptance`; plus the surrounding unchanged transition table where the
  changes touch it (`tools_action` → `materialize`, `reconcile_run`,
  `structural_action`, `deferred_action`, `queue`).
- `packages/conformance/src/conformance/simulation`: the multi-strand
  coda (`runner` subagent spawn/cross-message, the `invariant`
  weakening, `script`'s subagent share).

Oracle: `docs/architecture/orchestration.md`, `docs/spec-gaps.md`
(WP-D/E and "From the M3 runtime wave"), the packages' CLAUDE.md files,
and `docs/review/orchestration.md` (the M2-era review, whose
checked-and-sound claims were re-verified where M3 touched them).
Verification was by precise interleaving walkthroughs over the actual
code (both strand drivers and every commit serialize through one writer
actor, so interleavings are enumerable by hand); findings are marked
CONFIRMED when a concrete interleaving or code path exhibits them, and
SUSPECTED with the unverified step named.

Counts: **HIGH 1, MEDIUM 4, LOW 5, NIT 3.** No CRITICAL. The M2 review's
four fixed findings (ORCH-M2 parallel no-op, ORCH-M3 abort usage,
ORCH-L4 request api, ORCH-L5 abort halt, ORCH-L6 leaf CAS) were verified
genuinely fixed for the paths they name; two of the findings below are
the same bugs surviving in paths the fixes did not reach.

---

## HIGH

### H1 — Escalation grants can clear two executions under one approval (CONFIRMED, security)

`strand_runtime.gleam:1347-1394` (`clear_tool_call`), `:1432-1459`
(`consume_escalations`).

The clearance path is: read all approved escalation records with their
seqs (`approved_escalations`), call `tools.clear` **with the grants**,
and only if the verdict is `Cleared` commit each record to `consumed`,
CAS-guarded by the seq it was read at. A lost CAS is swallowed:

```gleam
case writer.commit(state.writer, plan_tx) {
  Ok(_) -> Ok(Nil)
  Error(tx.StaleExpectation(..)) -> Ok(Nil)   // line 1455
  ...
```

and the function then proceeds to
`KeyObservation(ObservedToolCleared(...))`, so the call dispatches and
executes with arguments cleared under the grant.

Interleaving (two strand drivers, one writer; every step is an ordinary
serialized read or commit):

1. Strand A reads escalation E: `Approved`, seq 5.
2. Strand B reads E: `Approved`, seq 5.
3. A's `tools.clear` runs with E's grants → `Cleared`. (In production
   wiring clearance goes through the broker, so this window is wide.)
4. B's `tools.clear` runs with E's grants → `Cleared`.
5. A consumes E (CAS on 5 succeeds).
6. B's consume gets `StaleExpectation` → **treated as `Ok(Nil)`** →
   B's call dispatches anyway.

Both tool executions ran under the single approval — exactly the
double-spend the register CAS exists to prevent, and a direct violation
of design §5.3's "one re-execution per approval" and the package
invariant "a lost race is a refused commit, never a double consume". The
CAS protects the *record*; the *capability* was already exercised at
step 3-4, before the CAS. The same shape arises intra-session between a
subagent and its parent (M3 makes concurrent strands the normal case).
`escalation_test` covers only the sequential lifecycle, so nothing
catches this.

Fix direction: consume **before** clearing — read, CAS each record to
consumed, and only pass into `tools.clear` the grants whose consume
commit succeeded (this also matches the documented "consumed before
dispatch, fails safe" ordering); or, keeping the current order, on
`StaleExpectation` re-read the record and, if another strand won, throw
the clearance verdict away and re-run clearance without the grants
instead of proceeding.

---

## MEDIUM

### M1 — A strand-actor restart leaks its live effect processes: duplicate concurrent execution and a broken exclusivity gate (CONFIRMED)

`strand_runtime.gleam:1033-1081` (`spawn_provider`/`spawn_tool` —
unlinked, monitored by the current incarnation only), `:678-687`
(`wake`'s owner-alive check), `:1325-1342` (`tool_may_start` reads only
process-local `state.live`).

Effect processes are spawned **unlinked** and tracked only in the
driver's in-memory `live` list. When the strand actor halts without the
tree dying — any `Halt`: a transient `BackendFault` on one of the
several reads per pass, a corruption report, fuel exhaustion, a read
failure inside `provider_done`'s ownership check (`:391`) — the factory
restarts the driver with `live: []` while the effect process keeps
running. The restarted incarnation then reads `effect_pending`, finds no
live effect, and takes the **orphan** path (`resolve_key`,
`AssistantKey`/`ToolKey`), even though the effect is not orphaned at
all. Consequences, each confirmed by walkthrough:

- a `ReplaySafe` tool is re-executed via `ToolReplay` **while its first
  execution is still running** — "safe to run again" is being stretched
  to "safe to run concurrently with itself", which no registration
  promised (two bash invocations mutating one worktree at once);
- an assistant request is synthetically errored and **retried while the
  original request still streams** — the original's tokens are billed by
  the provider but its settlement is dropped by `wake`'s owner check
  (the old incarnation's subject is dead), so the ledger never sees
  them: the same usage-loss ORCH-M3 fixed, reintroduced through the
  restart door;
- the exclusivity gate evaporates: `tool_may_start` consults only the
  new incarnation's empty `live` list, so an `Exclusive` tool can be
  cleared and started beside the previous incarnation's still-running
  `Exclusive` tool. The M3 claim "no other tool starts while it runs"
  holds only within one actor incarnation;
- a hung tool's process leaks forever (nothing ever kills it).

The whole-tree crash case is fine — that is what the orphan machinery is
for, and the harness tests it. The gap is specifically the
*partial* crash (strand restart under a live tree), which no test
exercises. Fix direction: kill (or adopt) the previous incarnation's
effect processes on driver init — e.g. spawn effects linked with
`trap_exit` in a per-strand holder that dies with the driver, or record
effect pids in an ETS/registry row the replacement driver reaps before
its first orphan report.

### M2 — Abort discards a genuinely-settled structural summary: reserved usage id never written (CONFIRMED)

`planner.gleam:3058-3104` (`structural_action` cancelled arm),
`:2963-2976` (`reconcile_run` catch-all for `Compacting`),
`strand_runtime.gleam:315-368` (`provider_done` ownership drop).

The ORCH-M3 fix ("an effect that already delivered a real settlement
still queued in the mailbox commits under its reserved ids … retaining
its reported usage" — runtime CLAUDE.md) works for assistant, poll, and
tool effects precisely because their reconcile paths **park**: with the
killed-but-registered effect still in `live`, `resolve_key` returns
`KeyWait`, the handler yields, and the queued real settlement (or the
monitor's Down) is consumed as the observation.

Structural work never parks. Under cancelled control `structural_action`
goes straight to `finish` (standalone/navigation hosts) or through
`reconcile_run`'s catch-all to `drain_writes_then_finish_aborted`
(in-run `Compacting`) — synchronously, inside the same `RequestAbort`
handler, **before** the mailbox's queued `ProviderDone(Settled)` for the
live `SummaryEffect` can be handled. The terminal transaction clears
`current_operation`; when the settlement is then processed,
`current_operation_owns` returns false and it is dropped (`:329-331` —
the comment even names "a cancelled structural … finish" as the intended
drop case). The `SummaryRequest.usage` id reserved in the intent is
never written: real billed tokens vanish from the ledger, contradicting
the invariant the M3 wave just established for every other effect kind.

Fix direction: mirror the run paths — when the state is
`Generating(SummaryEffectPending(request: Some(..)))` under cancelled
control, `AwaitEffect(SummaryKey)` first (the runtime already parks on a
live summary effect and reports `ObservedSummaryOrphaned` only when none
is live), settle `ObservedSummaryReturned` by committing the usage row,
and only then finish aborted.

### M3 — An approval is burned by the first passing clearance of *any* tool on *any* strand (CONFIRMED behavior, design-level)

`strand_runtime.gleam:1356-1386`: every clearance loads **all** approved
escalations session-wide, hands all their grants to the tool surface,
and on any `Cleared` verdict marks **all of them** consumed — including
clearances that would have passed with zero grants, for tools and
strands unrelated to the denial that raised the escalation.

With M3's parallel dispatch and sibling strands this is no longer a
corner: approve an escalation for strand A's denied bash call while
strand B's `read` clearance (which needs nothing) is in flight, and B's
clearance silently consumes the approval; when A's re-execution clears,
the grants are gone, the call is denied again, and the user must
re-approve — with the record showing only `consumed`, attributing
nothing. `api.approve_escalation`'s doc states "the next tool clearance
on any strand consumes the approval", so part of this is deliberate, but
the M2-era design predates multiple concurrent clearance paths; as built,
grant delivery to the call it was approved for is not merely
best-effort, it is likely to misfire whenever anything else is running.
(Escalation records also carry no op/strand/call attribution — the
gateway review logs the same gap from the other side, spec-gaps WP-L
item 1.)

Fix direction: scope escalations to the denial's call identity (tool
name at minimum; ideally `{op, step, index}` recorded at raise time),
consume only records whose scope matches the clearing call, and leave
non-matching approvals alone.

### M4 — No crash-schedule coverage for any of the new M3 machinery (CONFIRMED, test adequacy)

The M2 review's H1 (the interleave harness's five scenarios never reach
deferred/compaction/structural/navigation recovery) is still open — and
the M3 wave widened the uncovered surface:

- `interleave_test.gleam` still enumerates exactly `simple`, `tools`,
  `steer`, `abort`, `retry`. No kill-at-every-commit run ever crosses a
  **parallel** batch (two `CallEffectPending` at once, staged-out-of-
  order recovery), an escalation consume, or a multi-strand session.
- The simulation's multi-strand coda drives subagents under the fault
  schedule (good — boot-all-strands recovery is genuinely soaked), but
  `runner.execute` always runs `ctx.runtime.settings` =
  `default_options`' `Sequential`, and neither `script.gleam` nor the
  surface ever raises an escalation, so no seed can hit a parallel
  frontier or an approve/consume race either.
- Parallel dispatch's only concurrency evidence is two happy-path
  runtime tests (`parallel_tools_test`) plus pure-machine
  `parallel_test`; abort-during-parallel-batch, crash-during-parallel-
  batch, and exclusive-after-restart (M1 above) have no test.

H1 and M1-M3 of this review are all bugs that live exactly in those
unswept interleavings. Fix direction: a parallel-tools interleave
scenario with deterministic commit count; a simulation script knob for
`tool_execution: Parallel` and an escalation op; a strand-restart (not
tree-kill) fault in the schedule.

---

## LOW

### L1 — Queue admission turns a benign finish race into a hard error (CONFIRMED)

`api.gleam:353-375` (`enqueue`), `:1058-1080` (`read_op_meta` /
`read_op_state` → `require`). `enqueue` reads `strand.state` (sees
`current_operation: Some(op)`), then reads `op.meta`/`op.state` in
separate writer calls. If the strand's terminal transaction commits
between the reads (it deletes both op registers and clears
`current_operation` atomically), the second read returns `Ok(None)` →
`ReadFailed("op.state is missing for the open operation")` → `Done`,
**not** `Retry`. The caller gets a spurious storage-shaped error for
what is really "the run just ended"; in `send_to_strand` this bypasses
the busy/idle retry loop entirely instead of falling through to the
accept path. No message is lost (the caller is told), but the error is
wrong in kind. Fix: map missing-op-registers during admission to `Retry`
so the loop re-reads and takes the `NoActiveRun` branch.

### L2 — `send_to_strand` cannot deliver to a cancelling strand and mislabels the refusal (CONFIRMED)

`api.gleam:662-690` with `queue.gleam:403-423`: under
`CancelRequested` steer admission refuses `NoActiveRun`, but
`current_operation` is still set, so the accept attempt refuses
`StrandBusy`; `send_attempts` alternates the two four times with no
backoff and returns `RaceLost` — a misleading verdict (no race was
lost; the target is draining an abort) for a delivery that could have
been parked durably as a next-run item (`queue.enqueue_next_run`
exists and is admitted in any state). Fix: on
steer-refused + accept-busy, either enqueue as next-run or surface a
distinct "strand cancelling" error.

### L3 — `settle_poll` still validates the handle api against the response's self-report (CONFIRMED, contained)

`planner.gleam:2475-2484`: the ORCH-L4 fix threads the captured
`request_api` through `settle_assistant`, but the poll settlement still
builds `expected_api: message_api(message)` — the machine CLAUDE.md's
"never against the api the response reports about itself" is untrue for
polls. Contained today because rung 3 is followed by the strict
`in.deferred_source == Some(handle)` full-equality check (`:2517`), and
the source handle descends from the properly-validated first suspend, so
a smuggled handle still cannot become the next source; the weak check
only mislabels some invalid-handle failures as valid-then-mismatch. Fix:
persist the api in `DeferredState` (it already carries the captured
configuration) and use it, or note the poll-path exception where the
invariant is documented.

### L4 — A crash inside `create_strand` leaves a durable strand no driver serves (CONFIRMED walkthrough; window is host-crash-shaped)

`api.gleam:545-568`: seed commit, driver start, and brief acceptance are
three separate steps. If the calling process dies (or `start_strand`
fails) after the seed commit, the strand exists durably with no driver
and no brief: a later `create_strand` retry gets `StrandExists` with no
affordance to finish the half-creation, and — worse for liveness —
`accept_quietly`/`send_to_strand` against it **succeed durably** while
nothing ever drives the run: the checkpoint poll that makes doorbell
loss harmless is the driver's own timer, and no driver exists until the
next whole-tree reboot lets the booter repopulate. Fix:
`ensure_strand_running` (idempotent, already exists) from the admission
path when the target strand has registers but no live driver; and let
`create_strand` treat `StrandExists`-with-no-driver as "resume: start
driver, accept brief".

### L5 — `tool_done` lacks the ownership guard `provider_done` has (SUSPECTED, defense in depth)

`strand_runtime.gleam:424-454` versus `:315-331`. `provider_done` drops
an outcome whose operation is no longer the strand's current one;
`tool_done` performs no such check. Today this is unreachable — every
path that ends an operation with a registered tool effect first parks on
`ToolKey`/`has_live_tool`, so the outcome is always consumed before the
terminal — but the reasoning is global and fragile: any future cancel
path that synthesizes without waiting (M2 above is exactly that shape
for summaries) would let a late `ToolDone` push a stale
`ObservedToolSettled` that the *next* operation's first plan receives,
faulting the strand (`unexpected_observation`). The unverified step:
that no such path exists today — I found none, but proved it only for
the current planner. Fix: mirror the `current_operation_owns` check.

---

## NIT

- **Settlement transactions never expect `strand.leaf`.** Acceptance now
  CASes the leaf (ORCH-L6 fix, verified on all three intents), but every
  mid-operation leaf mover (`settle_writes`, `materialize`,
  `place_pending`, structural publication) parents entries at the loaded
  leaf guarded only by the op-state seq. Safe iff nothing else moves an
  open strand's leaf — true in this plane, but the invariant lives in
  the session/gateway layer ("tree write, lane idle"); worth an explicit
  cross-reference where `op_tx` is defined.
- **`put_fact` is blind last-writer-wins** (`expected: []`) on a
  blackboard explicitly pitched for multi-agent coordination; two
  strands racing a read-modify-write silently lose one update. A
  seq-expecting variant would make CAS available to hosts.
- **`abort_usage_test` wins its race by pacing, not by construction:**
  the rendezvous guarantees the abort precedes the settlement in the
  mailbox, but the kill-vs-settle race (effect must send before
  `interrupt_live_effects` runs) is won only because the fake settles in
  one hop while the driver does several storage round-trips first. Fine
  today; will flake if the drive loop ever gets faster than the fake.

---

## Checked and sound

Each item traced by walkthrough against the architecture doc, spec-gaps,
and pi's recovery/abort rules; M2-review claims re-verified where the M3
diff touched them.

- **Crash between `strand.config` seed and driver start / booter
  convergence.** The seed is one atomic transaction over all three
  registers, each expecting absence, so no partial strand can exist; the
  booter's "list `strand.*`, start what is missing" and
  `ensure_strand_running`'s start-then-recheck (`supervisor.gleam:
  227-254`) make booter-vs-`create_strand` and double-`create_strand`
  driver races converge on one driver (the loser's `start_child` error
  is followed by an alive check). Two `create_strand` calls for one name:
  exactly one seed commit wins; the loser gets `StrandExists`. Registry
  names are minted once and survive strand/writer crashes (registry is
  first in rest-for-one); after a registry crash the whole tail restarts
  and re-registers under fresh names, and doorbells resolve by lookup at
  ring time, so no stale-name sends. (The undriven-strand liveness gap is
  L4; durability is sound.)
- **`send_to_strand` loses nothing and double-admits nothing.** Steer
  and accept each commit exactly once or return; a `StaleExpectation`
  retry re-plans with a fresh entry id whose predecessor was never
  written; exhaustion returns `RaceLost` explicitly. The busy/idle
  alternation (steer-refused → accept → accept-busy → steer) converges
  or reports. Delivery-then-nudge ordering matches the durable-payload
  doctrine; a dropped nudge is found by the target's poll.
- **Child terminal results.** `await_strand_result` is a pure durable
  read of `strand.last_result` matched by op id — idempotent, reboot-
  proof, never consumed; "consumed twice" is impossible and "never" only
  if the caller stops polling (overwrite requires a subsequent accepted
  run on that strand, which only the caller initiates).
- **Abort settlement fidelity, run paths (the settled-before-kill
  window).** `interrupt_live_effects` kills after the durable marker but
  never deregisters; a settlement already sent is ordered before the
  kill's Down (same-pid signal order), consumed via `take_live`, and
  committed as `aborted` with real content and usage
  (`settle_assistant`/`settle_poll` `CancelledClassification`,
  `settle_writes` with `message_usage`; `advance_batch` preserves a live
  tool result and forces `terminate: False`). An unreported death
  settles through the monitor synthetically. **No double settlement is
  reachable:** the orphan observation requires `has_live == False`,
  which within an incarnation happens only after the single settlement
  or Down consumed the entry (one wake per effect process; a post-
  `take_live` Down finds no entry); across incarnations `wake`'s
  owner-alive check drops any late delivery, so the synthetic committed
  by recovery can never be followed by the real one attaching anywhere.
  The `current_operation_owns` re-read is stable against TOCTOU because
  only the strand's own actor commits its op transitions. The
  deliberate drop of a post-terminal settlement is exactly the
  structural case flagged as M2.
- **Abort re-delivery (ORCH-L5 fix).** Exhausting the 8-attempt stale
  ladder re-sends `RequestAbort` to self after a poll-interval pace and
  keeps running (`strand_runtime.gleam:500-506`); every retry re-reads
  durable state; idempotence via `AbortAlreadyRequested`. No silent
  loss, no restart.
- **Parallel dispatch (ORCH-M2 fix).** `request_batch_work` works the
  first still-planned call while earlier calls are pending, parks only
  when nothing is plannable; clearances and intents issue in source
  order; `stage_result` keys on the token's `source_index` and the
  call's own reserved `result_entry`, and `take_live` matches full
  structural token equality, so an out-of-order settlement cannot attach
  to the wrong call; `materialize` places only the contiguous
  outcome-ready frontier run, parented in source order, and moves the
  leaf to the newest placed result. Crash with mixed
  pending/staged calls recovers correctly: staged results survive in
  `pending.entry`, pending calls orphan one at a time (the live replay
  parks `ToolKey` for the others), and materialization stays ordered. A
  `ReplayNever` (or cancelled, or registration-revoked) call never
  replays: `recover_tool` requires stored `ReplaySafe` ∧ current
  `replay_still_safe` ∧ `Running`. The exclusivity gate is correct
  within a driver incarnation (checked at clearance, the only path that
  starts new work while effects are live; the cleared-observation replay
  after a stale commit cannot interleave a settlement because both are
  handled in one actor turn). Its restart hole is M1.
- **`request_api` capture (ORCH-L4 fix).** Admission's `api` is
  persisted in `GenerationEffectPending` (codec round-trips it,
  `requestApi` required by the total decoder — a pre-M3 register without
  it decodes as corruption and faults visibly rather than guessing),
  threaded to `settle_assistant` in both the running and reconcile
  paths, and compared as `{provider, model_id, api}` in `handle_valid`.
  The default hook's `api: "unknown"` fails closed (real handles refuse
  to validate until production admission supplies the api — documented,
  spec-gaps M3 item 1). Poll-path caveat is L3.
- **Acceptance leaf expectation (ORCH-L6 fix).** All three request kinds
  funnel through `acceptance.plan`, which now emits
  `expect_leaf(strand, leaf_seq)` beside the strand-state CAS and
  op-absence expectations; `leaf_seq: None` correctly demands absence
  for an unseeded register. Both in-repo committers supply the read seq
  (`api.accept_quietly` via `read_leaf`, the simulation runner's
  `accept_directly` via its leaf cell).
- **Escalation record lifecycle.** `may_become` admits only
  Pending→{Approved,Rejected} and Approved→Consumed; every transition in
  `api.decide_escalation_value` is CAS-guarded and a lost race re-reads
  and reports `EscalationWrongStatus` — concurrent approve/deny/consume
  of the *record* cannot double-apply (the pre-CAS *use* of grants is
  H1, a different window). `raise_escalation` CASes on absence, so
  duplicate ids refuse. The documented crash window — grant consumed,
  then the strand dies before the intent commit — is genuinely
  fail-safe: the re-cleared call runs under base policy, nothing widens
  silently (spec-gaps M3 item 3), at the cost of a re-approval.
- **Reserved `escalation/` prefix.** `put_fact` refuses the prefix
  before building the transaction; `facts` filters it from listings;
  labels live in the separate `fact.label` namespace; nothing else in
  the reviewed surface writes `fact.custom`. Crafted keys
  ("escalation" without the slash, case variants) neither collide with
  escalation reads (exact-prefix listing) nor bypass the guard for real
  escalation keys. A corrupt escalation record faults the clearance path
  loudly rather than being skipped — consistent with the
  no-partial-trust rule.
- **Machine leaf/terminal bookkeeping under the new paths.** The
  terminal transaction still CASes both op-state and strand-state and
  preserves concurrently admitted `pending_next_run`;
  `run_pending_ids` covers inbox ∪ drained ∪ staged, so an aborted
  parallel batch's staged-but-unmaterialized results are deleted with
  the operation; `materialize`'s batch-completion path deletes tool-args
  keys.
- **Observation hygiene across operations.** A queued observation
  consumed by a `Finish` is discarded with the commit; `provider_done`'s
  ownership check drops post-terminal provider outcomes, so a stale
  observation cannot be replayed into the next operation
  (tool asymmetry: L5). `commit_then` and `KeyWait` both push an
  unconsumed real observation back to the front before reloading —
  unchanged from M2 and still correct with the new
  `ObservedToolCleared` flow (a cleared verdict survives a stale intent
  commit and re-dispatches against the reloaded state without re-running
  clearance or re-consuming grants).
- **Simulation coda accounting.** The `calls_answered` weakening is
  semantically right: aborted/errored responses retain their content
  under faithful abort (including call blocks that never planned a
  batch), never execute, and are projection-dropped; executable
  responses (including truncated `Length` tool-use) remain fully
  checked, and id-collision is still caught by the exactly-once count.
  The subagent coda's `spawn_child`/`deliver_cross` retry loops re-read
  durable state before every retry (the same lost-reply discipline as
  `admit`), the `sub|` fingerprint prefix keeps strand projections
  disjoint, and terminal-register invariants extend to the subagent
  strand when it exists.
- **Writer and supervisor.** Unchanged from M2 in all load-bearing
  respects (single-committer mailbox, `after_commit` post-durability
  pre-reply, lease-loss abnormal stop, rest-for-one order with the
  registry first); the one M3 change — the booter as fourth child — is
  sound: its whole effect runs in its start function under supervision,
  and a booter failure fails the tree loudly rather than half-booting.

## Out of scope, noted for other reviewers

- The gateway's own acceptance-plan construction and escalation
  attribution (client reviewer; spec-gaps WP-L items 1-2).
- Whether the session layer enforces "tree write only while idle"
  (session reviewer) — this plane's settlement transactions assume it
  (see NIT 1).
- Killing the broker-side sandboxed child when the runtime's tool effect
  process is killed (M1 aggravates this, but enforcement is WP-G/H).
