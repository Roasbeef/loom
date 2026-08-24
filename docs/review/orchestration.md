# Adversarial review — orchestration layer (machine + runtime)

## Scope and method

Read-only adversarial review of the orchestration plane:

- `packages/machine`: `operation`, `classification`, `planner`, `queue`,
  `acceptance`, `strand`, `internal/build` (codec skimmed).
- `packages/runtime`: `strand_runtime`, `writer`, `supervisor`, `api`,
  `effects` (surface), plus the WP-T interleave harness and the dedicated
  recovery/doorbell tests.

Oracle: pi's `harness.md` Part 3 (§3.1–§3.13) and Part 4 (§4.1–§4.9) read
in full, the Loom implementation spec §1.3/§3.1, `spec-gaps.md` (WP-D/E),
and `protocol-change/002`. Focus per the brief: transition FIDELITY and
TOTALITY in the pure machine; RECOVERY CORRECTNESS and the effect sandwich
in the runtime; and whether the interleave harness proves what it claims.

Method: traced `classify` precedence and every `next_action` phase branch
against its pi row; traced the drive loop against the §4.5 recovery table
for each crash position and each cancellation reconciliation branch;
checked the effect-token / reserved-id handling and the doorbell/stale-
expectation loss-safety; and audited the interleave scenario library for
the states it never reaches.

Bottom line: the machine is a careful, largely faithful transcription; I
found no confirmed state-corruption or lost-committed-result defect in the
core transition logic. The real findings are a public setting that silently
does nothing, a ledger-accuracy divergence under the abort race, and a
material gap between what the interleave harness claims and what it
exercises.

Counts: HIGH 1, MEDIUM 2, LOW 3.

---

## HIGH

### H1 — The interleave harness never crash-tests the highest-risk recovery paths (CONFIRMED, test adequacy)

`packages/runtime/test/runtime/interleave_test.gleam` +
`packages/runtime/test/support/harness.gleam:87-150,388-399`.

The crash scheduler (`interleave` → kill after every armed commit `k`) is
the mechanism the spec relies on to prove convergence (WP-E exit criteria,
implementation spec §1.3/§3.1). Its scenario library is exactly five runs:
`simple`, `tools`, `steer`, `abort`, `retry`. Consequently the enumerate-
every-boundary kill loop is **never run over**:

- deferred responses (`AwaitingDeferred`, poll suspend/effect_pending,
  orphan-poll replacement at the same poll number — `planner.gleam:2121-2357`),
- compaction/threshold/overflow (`Compacting`, `enter_threshold_compaction`,
  the overflow `resumeAfter` one-shot — `planner.gleam:824-854,1146-1229`),
- structural summary generation (`Generating`, split-turn `SummaryRequest`,
  `advance_orphaned_summary` — `planner.gleam:3110-3290`),
- navigation (summarized/unsummarized terminal transaction —
  `planner.gleam:3414-3627`).

Those are precisely the states whose recovery rows (§3.2 deferred table,
§3.9 structural, §4.5 orphan table) are the subtlest in the whole spec, and
they get *zero* crash coverage. The dedicated recovery test
(`recovery_test.gleam`) covers only one non-boundary crash: a `Never` tool
mid-flight. `spec-gaps` WP-E-1 states mid-flight interruption is "exercised
by dedicated kill-the-tree tests"; for the assistant-effect, deferred-fetch,
and summary-request effects there is **no** such dedicated test — their
`effect_pending → orphan` recovery is only ever entered synthetically inside
`plan`, never with a real killed process.

Two additional interleavings the harness structurally cannot reach even for
the covered scenarios:

- **concurrent enqueue during a live effect.** `steer_scenario` admits its
  steer *after acceptance and before `api.nudge`* (`harness.gleam:123-132`),
  so it is drained at the first checkpoint and never races a live assistant
  `effect_pending`. The §3.4 property "settlement cannot overwrite steer/
  write acceptance with a stale snapshot" — implemented via the
  `commit_then` `StaleExpectation` reload in `strand_runtime.gleam:580-586`
  — is therefore never actually driven by a concurrent enqueue.
- **abort during the terminal commit** (the `terminal first → abort returns
  NoActiveOperation` race of §4.6): the abort scenario aborts mid-tool, not
  at the finish boundary.

Why it matters: an adversarial review cannot certify the deferred/structural
recovery rows as sound, because the one harness built to falsify them is
pointed elsewhere. Fix direction: add interleave scenarios for a deferred
poll, a threshold compaction, an overflow→compaction→resume, a summarized
navigation, and a steer/follow-up admitted while an assistant effect is in
flight; add a dedicated kill-the-tree test that kills during an assistant
`effect_pending` and during a deferred fetch (not at a commit boundary), the
way `recovery_test` does for a tool.

---

## MEDIUM

### M2 — `settings.tool_execution` (Parallel) is silently a no-op (CONFIRMED, fidelity)

`planner.gleam:1584-1756` (`advance_batch`, `request_batch_work`);
`RunSettings.tool_execution` defined at `operation.gleam:144-151`.

`request_batch_work` dispatches only the **first** unfinished frontier call
and then `AwaitEffect`s on it; `advance_batch` consumes one tool observation
per pass. Neither ever reads `settings.tool_execution`. Confirmed by grep:
the only readers of `Sequential`/`Parallel` are the codec, the ADT, and the
`api` default — the planner's tool logic never branches on the mode. So a
run configured `Parallel` still clears→dispatches→settles→materializes one
call at a time, exactly like `Sequential`.

pi §3.8 Parallel mode issues clearance+intent for **all** calls in source
order and lets their effects settle independently ("effects and post-effect
hooks settle independently; each complete outcome stages immediately in
completion order"). The `ToolKey` doc comment ("In parallel mode this names
the first pending call; any pending call's observation satisfies it") shows
the runtime side was built to support concurrency the planner never drives.

Not a correctness/state defect — source-ordered materialization makes the
tree identical either way — but a public, durably-persisted setting does
nothing, and the design's "capability" goal for parallel tool execution is
unmet. Fix direction: in `request_batch_work`, when
`settings.tool_execution == Parallel`, fold over the frontier issuing an
intent for every `CallPlanned` (in source order) before parking on the
outstanding set, rather than stopping at the first.

Failing-test sketch: a two-tool batch where each tool blocks until the
recorder shows the *other* tool has started; under `Parallel` it should
complete, under the current code it deadlocks (call 2 never dispatches
until call 1 settles).

### M3 — Abort discards a genuinely-settled response's usage and content (CONFIRMED behavior; partly acknowledged)

`strand_runtime.gleam:443-496` (`abort`, `cancel_live_effects`),
`:310-350` (`provider_done` drop path); reconciliation at
`planner.gleam:1415-1517` / `settle_cancelled_poll:2590-2638`.

`abort` commits the marker then `cancel_live_effects` demonitors + kills
every live pid and sets `live: []`. If a provider effect had already
delivered a real `ProviderDone(Settled, usage=U)` that is still queued
behind `RequestAbort` in the mailbox, the later `provider_done` finds
`take_live == None` and **drops it** ("Not live any more … Drop it").
Reconciliation then re-enters the same `effect_pending` state, sees no live
effect (`has_live == False`, `strand_runtime.gleam:641-652`), reports
`ObservedAssistantOrphaned([])`, and commits a **zero-usage** synthetic
`aborted` response (`settle_orphaned_assistant`, `synthetic_response`
zero-usage at `planner.gleam:4001-4024`).

pi §4.6 is explicit that a really-started effect "settles under its reserved
ids as `aborted`, **retaining reported usage**." Loom's kill-then-reconcile
loses both the billed usage and the partial content. Because error/aborted
responses are dropped from projection, the transcript does not diverge — but
the ledger under-counts real, billed tokens, contradicting spec §3.4
("usage events mirrored to the ledger are the billing source of truth").

Acknowledged in part: `spec-gaps` WP-E-1/E-5 and the interleave doc exempt
the abort scenario from ledger assertions. That exemption is the reason this
would not be caught, not a reason it is correct. Fix direction: on abort,
drain an already-delivered settlement for a still-live token before clearing
`live` (settle it as aborted under the reserved ids with its real usage),
rather than unconditionally killing and synthesizing zero-usage.

---

## LOW

### L4 — Deferred handle `api` validity is checked against the response's own api, not the captured request api (CONFIRMED, minor)

`classification.gleam:268-273` (`handle_valid`) with
`settle_assistant`/`settle_poll` building `ClassifyCtx.expected_api =
message_api(message)` (`planner.gleam:1119,2383`).

pi §3.2: a deferred handle is valid only when its `{provider, modelId, api}`
equals the **captured request** identity. `ModelIdentity`
(`strand.gleam:20-22`) carries only `provider`/`model_id` — the request api
is not captured durably — so `expected_api` is taken from the settled
message itself. The check thus degenerates to `handle.api ==
response.api`, which cannot detect a handle whose api differs from the
original request when the response reports that same api. The stricter poll
path (`in.deferred_source == Some(handle)`, full equality) is unaffected;
only the initial suspend's validity is weakened. Fix direction: capture the
request api into `GenerationContext`/`DeferredState` (protocol-change to
`ModelIdentity` or the context) and compare against it.

### L5 — `abort_commit` exhaustion halts the strand and silently drops the abort (SUSPECTED, edge)

`strand_runtime.gleam:457-488`.

After 8 `StaleExpectation` losses the abort marker commit returns
`Error(..)` → `Halt`, which `stop_abnormal`s the strand. The
fire-and-forget `RequestAbort` message is then gone, so the user's abort is
lost (they must re-request, undocumented at this layer), and a running
operation is disrupted by a restart that also spends supervisor restart
tolerance. Eight consecutive stale races require sustained concurrent strand
commits and is very unlikely, but the failure mode (silent abort loss +
tree-tolerance pressure) is worse than simply yielding and letting the next
poll/re-request retry. Fix direction: on exhaustion, `Continue` (leave the
op running, abort not yet durable) instead of `Halt`; callers re-request as
§4.6's no-live-task case already expects.

### L6 — Acceptance parents prompts on a non-CAS-guarded leaf (SUSPECTED, latent M3)

`acceptance.gleam:152-229,414-428`; reads `ctx.leaf` outside the writer,
commits with expectations `= {strand_state_seq, op absent}` only — no
`strand.leaf` seq expectation.

The read-then-commit gap is closed only by the `strand_state` CAS. Every
current leaf-mover (acceptance, settlement, terminal) also bumps
`op.state`/`strand.state`, so the CAS catches them. But pi §3.11's "tree
write, lane idle → insert entry, upsert leaf" moves `strand.leaf` **without**
touching `strand.state`; such a concurrent idle write between the leaf read
and the acceptance commit would mis-parent the prompt entries with no CAS to
reject it. Not reachable in M1 (no idle tree-write API exists yet), latent
for WP-C-full (M3). Fix direction: when idle tree writes land, add a
`strand.leaf` seq expectation to the acceptance transaction (pi gets this for
free from the single lane mutation line; Loom's out-of-writer read needs the
explicit CAS).

---

## Checked and sound

The following were traced against pi and found faithful:

- **`classify` normative order and precedence** (`classification.gleam`):
  cancelled-control wins over everything (so a cancelled overflow/tool/stop
  all settle aborted); overflow is checked before retryable-error and never
  yields a tool plan; `Length` below `intended_output_limit` with the
  `0`-disables-the-rule guard; deferred-valid vs deferred-invalid;
  `aborted`-under-`running` reported as corruption (invariant 19), not
  fallen-through.
- **Overflow one-shot** (`overflow_recovery_used`): set `True` only on the
  overflow `resumeAfter`, reset to `False` by every projecting-input drain,
  second overflow → `failure_drain` (`planner.gleam:1146-1229`,
  `868-871`). Empty-preparation overflow → failure drain; non-empty →
  compaction, both normalizing the response to `error`.
- **Threshold dedup** (`after_inbox`/`enter_threshold_compaction`): checked
  once per trigger via `threshold_checked`; `resume_after` marked checked so
  decline/empty/success/crash cannot recheck; threshold genuinely runs at
  a `may_finish` boundary; overflow `resumeAfter` deliberately left
  unmarked.
- **Checkpoint procedure order** (`checkpoint_action`→`after_inbox`):
  writes → steer → threshold → generate(clears `skip_inbox_once`) →
  follow-up(only at `may_finish`) → run-end → finish, matching §3.12
  step-for-step; `skip_inbox_once` set on every projecting drain and by a
  non-terminating tool batch, so one-at-a-time cannot become all-item across
  a crash (`spec-gaps` WP-D-6 surprises confirmed).
- **Failure drain** (`failure_drain_action`): drains writes then steer then
  follow-up; projecting input clears the failure into `need_assistant`;
  unprojected custom writes preserve provenance; empty inbox → finish failed
  with no hook/request.
- **Terminal transaction** (`finish`): deletes op-owned meta/state/tool-args/
  preparation/pending, records `LastResult`, clears `current_operation`
  while preserving `pending_next_run`, guarded by op.state **and**
  strand.state CAS so a concurrent `nextRun` can't be clobbered
  (`planner.gleam:3635-3667`); `run_pending_ids` covers inbox ∪ drained ∪
  staged.
- **Tool batch** (`tools_action`/`materialize`/`stage_result`): contiguous
  outcome-ready prefix materializes in source order, every call reaches a
  result entry (planned→cleared/refused, effect→settled/orphaned, cancelled→
  synthetic), `terminate` forced `False` under cancel, tool-usage rows minted
  at materialization, args deleted at batch completion, `may_finish` vs
  `need_assistant`/`skip_inbox_once` split on `every_terminates`.
- **Cancellation reconciliation** (`reconcile_run`): `effect_pending`
  assistant/deferred settle (or synthesize) aborted first then reconcile;
  tools reconcile through the ordinary machinery; ready/retry/structural/
  starting/checkpoint/failure-drain phases drain writes then finish aborted;
  structural work not yet published is discarded; `ReplaySafe` under cancel
  is **not** replayed (`recover_tool:1842-1845`).
- **Orphan recovery reserved ids** (`strand_runtime` `resolve_key` +
  planner): assistant/tool/deferred/summary orphan tokens compared
  structurally; safe-replay re-executes persisted args under the same result
  id via an empty-write CAS-fence `ToolReplay`; `Never`/absent →
  synthetic interruption; deferred orphan replaced under fresh ids at the
  **same** poll number.
- **Doorbell / stale-expectation loss-safety**: `Nudge` loss covered by the
  `PollTick` re-plan; a concurrent commit surfaces as `StaleExpectation`,
  and `commit_then`/`plan` push the unconsumed observation back to the front
  before reloading, so no observation is dropped
  (`strand_runtime.gleam:540-591`); the doorbell-drop tests confirm the poll
  finds accepted runs and steers.
- **Effect-worker death settles in-band** (`effect_exit`): a monitored
  effect that dies without reporting becomes a transport-failure response or
  synthetic tool error, never a strand fault; already-removed pids ignored.
- **Backoff** saturates at exponent 20 (`backoff`/`power_of_two`); retry
  attempt counting (`attempt < max_attempts`) matches for both assistant and
  summary generation.
- **Writer**: single-committer serialization, `after_commit` crash seam runs
  post-durability/pre-reply (the exact "commit N durable, committer
  unobserved" boundary), lease-loss → `stop_abnormal` → supervised reopen;
  rest-for-one tree restarts strands on writer crash.
- **`next_action` totality**: the state×intent mismatch, missing
  `batch_source`/`deferred_source`/`preparation`/`pending` payloads, and
  unexpected observations all route to `Fault(report)` rather than crashing,
  honoring the protocol-change/002 pure-total-planner contract.
