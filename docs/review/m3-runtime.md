# Adversarial review — the M3 runtime multi-strand wave

## Scope and method

Read-only adversarial review of the M3 runtime wave and the `machine`
changes that landed with it:

- commits `c4d7ff8` (boot every strand), `3212bca` (strand fan-out,
  escalations, hooks), `5efcf4b` (machine deferred review fixes),
  `80d9597` (conformance reach).
- `packages/runtime/src/runtime`: `api`, `registry`, `supervisor`,
  `escalation`, `hooks`, `strand_runtime`, `effects` — read in full.
- `packages/machine/src/machine`: the `5efcf4b` diff in `planner`,
  `acceptance`, `operation`, `internal/build`, plus `classification`
  and `queue` where the diff reaches them.
- `docs/spec-gaps.md` "From the M3 runtime wave", `docs/review/triage.md`
  rows ORCH-L4/L5/L6/M2/M3, and the call sites in `client/gateway` and
  `conformance/simulation/runner` that the changed `AcceptCtx` touches.

Oracle: pi's `harness.md` §3.8 (tools, sequential vs parallel), §3.11–§3.13
(queues, checkpoint, terminal transactions and `lane.lastResult`), and
Part 4 in full — §4.5 (driving and recovery) and §4.6 (abort
reconciliation) especially. Also read: `gleam_erlang`'s `process` and
`gleam_otp`'s `factory_supervisor` sources as vendored into
`packages/runtime/build`, because several safety claims in this wave rest
on what those functions do on failure rather than on Loom's own code.

Method: traced each hunt item to the code that would have to be wrong for
it to bite, then decided CONFIRMED (the code as written does it) versus
SUSPECTED (a reachability step I could not close by reading). For the
BEAM-signal claims I resolved the question by reading the vendored library
sources rather than reasoning from folklore. Where a claim held up I have
said so under "Checked and sound" rather than leaving silence to imply it.

Bottom line: the plumbing of this wave is good — the durable seeding
order, the boot-all-strands convergence, the abort settlement-versus-death
ordering, and the source-ordered parallel materialization all survive
adversarial reading. The findings cluster in two places instead: the
**escalation grant path**, where the security-relevant invariants the docs
state are not the invariants the code enforces; and the **api's own
error surface**, where several multi-step operations have no atomicity and
no way to report a partial failure.

Counts: HIGH 3, MEDIUM 7, LOW 7.

---

## HIGH

### H1 — An approved grant is session-global and is spent by whatever call clears next, on any strand (CONFIRMED, security)

`runtime/strand_runtime.gleam:1347-1394` and `1399-1426`;
`runtime/escalation.gleam:60-67`; `broker/escalation.gleam:32-35`.

`clear_tool_call` loads **every** approved escalation in the session and
passes the union of their grants into the clearance for the call it
happens to be working:

```gleam
grants: list.flat_map(approved, fn(cell) {
  let #(_seq, record) = cell
  record.grants
}),
```

Nothing scopes a grant to the call it was raised for. The record type has
`id`, `denial`, `grants`, `status` and no operation, strand, step, source
index, or tool name — and the broker's `Denial(reason, source, wanted)`
carries no call identity to attribute from either. So the sequence

1. strand `sub:1`'s `bash` call is denied; an escalation is raised,
2. a human approves it with a narrow, deliberate grant,
3. strand `main` reaches an *unrelated* tool clearance first,

hands `main`'s unrelated call the grant a human approved for `sub:1`'s
`bash`. If the broker composes policy from `Ctx.grants` — which is the
entire point of the grants channel — the widened policy applies to a call
nobody approved, in a different strand, for a different tool.

The api docstring states this as intended behaviour ("The next tool
clearance on any strand consumes the approval"), and `spec-gaps` WP-L
item 1 records the *attribution* gap for the protocol body. Neither
records that the missing attribution is also what makes the grant apply
to the wrong call. In a design whose first priority is security and
isolation, an approval that a human grants for one action and the system
spends on another is the wrong default even when documented.

The narrowing is cheap: carry `operation`/`strand`/`source_index` (or the
provider `tool_call_id`) on the record at `raise_escalation`, and filter
in `approved_escalations` before the union. Everything needed is already
in the `ClearanceQuery` at the point of use.

### H2 — "One re-execution per approval, by CAS" is not enforced: the CAS runs after the grant was already used, and losing it is swallowed (CONFIRMED, security)

`runtime/strand_runtime.gleam:1371-1386` and `1432-1460`.

The order in `clear_tool_call` is: read approvals → **call
`tools.clear` with the grants** → only then commit the consumption.
`consume_escalations` then treats a lost CAS as success:

```gleam
case writer.commit(state.writer, plan_tx) {
  Ok(_) -> Ok(Nil)
  Error(tx.StaleExpectation(..)) -> Ok(Nil)   // "a concurrent decision won"
  ...
```

Two strand drivers are two processes. Both can read the same `Approved`
record, both call `clear` with its grants, both receive `Cleared`, and
both dispatch. One consumption commit wins; the loser's
`StaleExpectation` is discarded and its tool runs anyway. The result is
two widened executions from one approval — precisely what the CAS was
introduced to prevent.

The claims this contradicts are explicit:

- `runtime/api.gleam:895-900`: "one re-execution per approval, by CAS";
- `runtime/escalation.gleam:22-24`: "a lost race is a refused commit,
  **never a double consume**";
- `packages/runtime/CLAUDE.md`: "Status transitions are CAS-guarded
  through the writer, so a lost race is a refused commit, never a double
  consume."

The only comment acknowledging the swallow reads it as benign ("a
concurrent decision won — the record is left as that decision made it"),
which is true of the *record* and false of the *execution*.

The single-strand case is safe only by accident of there being one
driver; M3 is the milestone that makes multiple drivers the normal shape.

Fix direction: consume first, then clear with the grants the consumption
actually won — which is also what "a grant is consumed *before* dispatch
so a crash spends it without execution" already asks for, one step
earlier than the code takes it. A losing CAS must then abandon the grant
and re-clear under the base policy, not proceed.

### H3 — `await_strand_result` can never observe a child's result once the child starts another run (CONFIRMED, correctness)

`runtime/api.gleam:473-508` and `702-709`; pi §3.13.

`await_result` polls `strand.last_result` and matches on operation id:

```gleam
case result_operation(last) == operation {
  True -> Ok(last)
  False -> await_result_wait(runtime, operation, timeout_ms)
}
```

`strand.last_result` is one register per strand, overwritten by every
terminal transaction (pi §3.13: "one bounded value per lane, forever …
until the next terminal transaction on the same lane overwrites it").
So:

1. parent calls `create_strand` and holds `op_1`,
2. `sub:1` finishes `op_1` — `last_result = op_1`,
3. anything sends `sub:1` another message before the parent's next 10 ms
   poll — `send_to_strand` from a sibling, a scheduler, the parent's own
   second brief — and `sub:1` accepts and finishes `op_2`,
4. `last_result = op_2`; the parent's `await_strand_result(op_1)` now
   spins to timeout and returns `Error(Nil)`.

`Error(Nil)` is the same value the caller gets for "still running", so
the parent cannot distinguish "my child's answer was overwritten" from
"my child is slow". The child's completed work is durable in the tree but
unreachable through the api that exists to retrieve it — and
`await_strand_result` is *the* documented parent half of the request/reply
pattern (`api.gleam:692-696`, design §4.6).

The durable semantics are pi-faithful; what is not faithful is building a
request/reply primitive on top of them with nothing else. pi resolves the
caller's live promise at the terminal transaction and treats
`lane.lastResult` only as the after-the-fact fallback for a process that
died. Loom has only the fallback. Options: subscribe to the writer's
`Committed` events for the terminal commit (the machinery exists —
`writer.Event` already fans out), or key the durable result so a
finished operation's outcome is not clobbered by the next one.

Two smaller relatives of the same shape, both CONFIRMED: the first
`await_result` call reads `session.last_result` *before* checking the
timeout, so `within_ms: 0` still performs one read (harmless); and the
poll loop subtracts a fixed 10 ms per iteration regardless of how long
the store read took, so `within_ms` is a floor on elapsed time, not a
bound.

---

## MEDIUM

### M1 — The ORCH-L4 fix does not reach the deferred-poll path, which is where deferred handles actually live (CONFIRMED)

`machine/planner.gleam:2475-2484` versus `1131-1141`;
`machine/classification.gleam:274-278`;
`machine/operation.gleam:396-413`.

`settle_assistant` now compares against the captured `request_api`, as
claimed. `settle_poll` does not:

```gleam
let classify_ctx =
  ClassifyCtx(
    ...
    expected_model: configuration.model,
    expected_api: message_api(message),      // the response's own claim
    ...
```

and `is_valid_handle` is `handle.api == ctx.expected_api`. On the poll
path the comparison is between the response's self-reported api and a
handle the same response supplied — vacuous by construction, which is the
exact defect ORCH-L4 named.

It is not merely an oversight in one branch: `DeferredSuspended` and
`DeferredEffectPending` carry `step_id`, `source_entry`, `poll`,
`configuration`, `stream_options` and **no captured api at all**, so the
poll path has nothing to compare against. Polls resolve identity through
`PollAdmissionKey` → `hooks.resolution`, which returns only
`ModelResolution` and never an api. Closing this needs a durable field,
not a one-line swap.

Impact is bounded by pi's second rule, which Loom does implement: a later
pending response must carry a handle "completely equal to its source
handle" (`planner.gleam` deferred branch), and the *initial* handle is now
validated against the request api. So a mid-chain substitution is caught
by equality even though the api check is vacuous. What remains genuinely
unchecked is the poll request's own identity.

The problem is that the documentation states the general rule as done.
`packages/machine/CLAUDE.md` asserts "classification compares
`{provider, model_id, api}` against that stored value — so a routing
change between dispatch and settlement cannot smuggle a handle in", and
`spec-gaps` M3 item 1 says admission's api is captured "so classification
validates deferred handles against the request's api rather than the
response's claim". Both are true of assistant settlement and false of
poll settlement. A future reader auditing the deferred path will trust
the invariant and stop looking.

### M2 — `create_strand` is a three-step non-atomic sequence and a partial failure burns the name permanently (CONFIRMED)

`runtime/api.gleam:545-629`; `runtime/supervisor.gleam:156-161`.

The sequence is: validate the fork point (one read) → `seed_strand` (one
commit) → `start_strand` (a supervisor call) → `accept_quietly` (a second
commit) → `nudge`. Three of those four can fail independently, and after
`seed_strand` commits, the name is taken forever:

- `StartFailed`: registers exist, no driver, no brief. Retrying the same
  `create_strand` now returns `StrandExists` because the seed CAS expects
  absence. The caller cannot recover the name, and there is no
  `delete_strand` or `rename` in the api.
- `BriefRejected`: strand exists and its driver runs, but the task brief
  that gives it a purpose was refused. Same dead end on retry; the caller
  must know to fall back to `send_to_strand`, which the error name does
  not suggest.
- Caller crash (or writer restart — see M3) between the seed commit and
  `start_strand`: registers durable, driver absent, caller never learned
  the outcome. This one self-heals on the next tree reboot because the
  booter lists `strand.*` and starts what is missing — the doctrine
  works — but until then the strand is a durably-recorded, silent,
  briefless participant that `api.strands` reports as existing.

The docstring's claim, "Because the registers are seeded before anything
runs, recovery restores the strand on every subsequent (re)boot", is
accurate and is the reason the crash case is survivable. It does not
cover the two *returned-error* cases, which leave the caller holding an
error and the store holding a name.

Suggested shape: make `StartFailed`/`BriefRejected` recoverable by
letting `create_strand` accept an already-seeded strand whose driver is
not running (the `ensure_strand_running` idempotency is already there),
or split seeding from briefing in the public surface — which
`spec-gaps` WP-L item 3 independently asks for ("an optional-brief
variant would close this").

### M3 — Every `runtime/api` operation panics its caller if the writer, registry, or strand factory is momentarily unregistered or dies mid-call (CONFIRMED)

`runtime/api.gleam:1154-1156`; `runtime/writer.gleam:250-255`;
`gleam_erlang/process.gleam:605-636,214-225`;
`gleam_otp/factory_supervisor.gleam:151-155,414-422`.

Every api read and commit resolves the writer by name and calls
`process.call_forever`. The vendored `perform_call` has two panic paths:

```gleam
let assert Ok(callee) = subject_owner(subject) as "Callee subject had no owner"
...
|> select_specific_monitor(monitor, fn(down) {
  panic as { "callee exited: " <> string.inspect(down) }
})
```

So a caller holding a `Runtime` is killed if the writer name is
unregistered at send time (mid-restart) *or* if the writer dies while the
call is in flight. `ApiError` has no variant for either, so there is no
way to report it; the caller simply dies. `process.send` on a named
subject has the same `let assert` (`process.gleam:220`).

The writer restarting is not exotic — it is the designed response to a
lost SQLite lease, and the rest-for-one tree restarts it on any writer
fault. The api's own doc leans on losses being harmless ("a lost nudge
costs latency, never data"), which is true of the doorbell and untrue of
the commit path underneath it.

The M3 wave both widens the exposure and makes the guarding inconsistent:

- `nudge` and `abort` go through `live_strand_subject`, which checks
  `subject_owner` + `is_alive` first (`api.gleam:399-414`);
- `create_strand` → `supervisor.start_strand` → `registry.ensure`
  (a `call_forever`) and `factory_supervisor.start_child` (an FFI
  `supervisor:start_child`, which exits `noproc` on an unregistered name)
  have **no** guard at all;
- every escalation operation, `put_fact`, `facts`, `strands`,
  `send_to_strand` and the acceptance/queue admissions are bare
  `call_forever`s.

Pre-existing in shape, but M3 multiplied the call sites and introduced
the two supervisor calls that have no guard where the neighbouring
doorbell does.

### M4 — One undecodable `escalation/*` register is an unrepairable session-wide poison pill (CONFIRMED, robustness)

`runtime/strand_runtime.gleam:1399-1426`, reached from `1356`;
`runtime/api.gleam:869-888`.

`approved_escalations` runs on **every tool clearance**, lists every
`escalation/`-prefixed `fact.custom` cell, and `try_map`s
`escalation.decode` over all of them. A single undecodable payload
returns `Error`, which becomes `KeyHalt` → `actor.stop_abnormal`. The
driver restarts, drives, reaches the same clearance, halts again. The
factory's restart tolerance is exhausted, the factory dies, rest-for-one
takes the booter with it, and the session supervisor's tolerance follows.
A corrupt record in one strand's blackboard kills every strand's session.

There is no repair path: `put_fact` refuses the `escalation/` prefix by
design (correctly — see "Checked and sound"), and there is no
`delete_fact` or `delete_escalation`. `api.escalations` fails the same
way, so an operator cannot even enumerate to find the offender.

The comment says this is deliberate — "Corrupt records fault the strand —
they are durable state, and partial trust is a bug class" — and the
principle is right. What is missing is the escape hatch that makes
"fault" recoverable rather than terminal. Two cheap options: skip and
report undecodable records on the clearance path (the grant union is
additive, so a skipped record can only *narrow* what a call gets, which
is the safe direction), or add a repair operation that can delete a
reserved-prefix cell by exact key.

### M5 — One un-startable strand takes the whole session down (CONFIRMED, robustness)

`runtime/supervisor.gleam:204-225`.

```gleam
cells |> list.try_each(fn(cell) { ... ensure_strand_running(...) ... })
```

`try_each` aborts on the first failure, so `boot_strands` returns
`Error`, `booter_start` returns `InitFailed`, and the booter child fails.
It is the last child in the rest-for-one order, so it alone restarts —
and re-runs the *whole* list, succeeding on the already-alive strands
(idempotent, good) and failing again on the same one. Five failures
inside the tolerance period and the session supervisor gives up: healthy
strands with open operations die because one strand could not start.

There is no partial-boot degradation and no reporting of which strand
failed beyond a synthesized string; the underlying `actor.StartError` is
discarded at `supervisor.gleam:220-221`, so the failure reason never
reaches a log or the caller.

`list.try_each` is also doing double duty here: it stops the *boot*, but
what the doctrine actually wants is "start what is missing", which is
naturally a fold that reports failures rather than a short-circuit.

### M6 — `send_to_strand` and `create_strand` capture the *sender's* run settings into the target strand's run (CONFIRMED)

`runtime/api.gleam:220-222,252-287,545-568,654-690`.

`on_strand` rebinds only the strand name:

```gleam
pub fn on_strand(runtime: Runtime, strand: String) -> Runtime {
  Runtime(..runtime, strand:)
}
```

`accept_quietly` then builds `AcceptCtx(..., settings: runtime.settings,
...)`, and `settings` came from whichever `Runtime` record the sender
held. So when `send_to_strand` finds the target idle and takes the
`Started` path, the new run on the *target* strand is accepted under the
*sender's* `RunSettings` — `tool_execution`, `steering_mode`,
`follow_up_mode`, and the compaction settings. Same for the brief in
`create_strand`.

The strand's own durable identity is respected — `strand.config`
(model, thinking level, `active_tool_names`) is read by the driver from
the target's register, and the clearance path passes
`loaded.configuration`, so the tool allow-list is correctly the target's.
It is specifically the run settings that leak across the strand boundary.

In today's wiring `Options.settings` is session-wide so the values
coincide, which is why no test catches it. But `Runtime` is a public
record with a public `settings` field, `on_strand` is the documented way
to address a sibling, and the whole point of M3 is strands that differ.
A parent configured `Parallel` silently makes its subagent's first run
parallel; a subagent messaging `main` silently reconfigures `main`'s next
run. `mint_context` has the same shape for `clock`/`entropy`
(`api.gleam:1149-1152`) — lower stakes, same reasoning.

Either read the target's settings where they should be durable, or make
`on_strand` refuse to carry settings that were not read for that strand.

### M7 — The runtime accepts any grants on approval; the subset check exists only in the gateway (CONFIRMED, security)

`runtime/api.gleam:902-910`; `broker/escalation.gleam:108-128`;
`client/gateway.gleam:1710-1723`.

`api.approve_escalation(runtime, id, grants)` writes whatever it is
given. The rule "a subset of the denial's wanted diff" is enforced in two
places, neither of them the runtime: `broker/escalation.approve` (pure,
process-local, and never called on this path — the runtime holds no
broker import by design) and `client/gateway.approve`, which decodes the
denial and calls `grants.first_unwanted`.

So the check holds for protocol clients and holds for nothing else. The
docstring is careful to say "validated by the broker layer that raised
it", and `runtime/escalation.gleam:56-58` repeats it — but the runtime
api is the boundary that actually feeds grants into `ClearanceQuery`, and
it is `pub`. `client/demo.gleam:252-276` already drives raise/consume
directly; the conformance runner drives the api directly; a future
serving layer will too.

The runtime cannot decode grants (that is the `E → A,B,C,D` direction the
design protects, and it is the right call). But it *can* enforce set
membership on opaque JSON: the wanted diff is already inside the stored
denial, and `escalation.decode` already has it in hand. Comparing opaque
values for membership needs no vocabulary.

---

## LOW

### L1 — The wake guard narrows the window it cannot close (CONFIRMED)

`runtime/strand_runtime.gleam:672-687`; `runtime/api.gleam:399-414`;
`gleam_erlang/process.gleam:214-225`.

`wake` and `live_strand_subject` both do `subject_owner` → `is_alive` →
`send`, which is two independent name lookups with a gap. If the driver
dies in the gap, `process.send`'s `let assert Ok(pid) = named(name)`
panics in the sender — a timer process, an effect process, or the api
caller.

The comment is right about why the guard exists ("raising at an
unregistered name inside someone else's process … turns an ordinary
reboot into a crash report from a process the supervisor knows nothing
about") and the guard does remove the common case, where the driver has
been dead for a while. It does not remove the race. Given how often
drivers restart by design (`Fault` → `stop_abnormal` → restart), it is
worth either a small catching FFI or a comment that says "narrows, does
not close".

### L2 — `tool_done` lacks the ownership guard `provider_done` has (CONFIRMED asymmetry, SUSPECTED reachability)

`runtime/strand_runtime.gleam:315-330` versus `424-454`.

`provider_done` checks `current_operation_owns` before feeding an
observation forward, with a good reason recorded: "Feeding it forward
would hand the *next* operation a mismatched observation." `tool_done`
takes the live entry and pushes the observation with no such check.

I could not close reachability: `materialize` only finishes the batch
when `all_completed`, `every_terminates` requires *every* call to
terminate, and abort reconciliation parks on `AwaitEffect(ToolKey)` while
a tool effect is registered — so I found no path where a run reaches its
terminal transaction with a tool effect still live. The asymmetry is
still worth closing, because the invariant `provider_done` protects is
the same one, and the cost is one register read that path already makes
elsewhere.

### L3 — The drive loop silently drops an observation the planner did not consume (SUSPECTED)

`runtime/strand_runtime.gleam:584-596,630-641,647-669`.

`drive_loop` pops an observation, `plan` hands it to `next_action`, and
on `Transition`/`Finish`/`Dispatch` the success continuation is
`drive_loop(state, fuel - 1)` — the observation is gone whether or not
the planner used it. `Wait` is the same (`park_retry` and the
`DeferredPollDue` `Continue` both discard it). Only `AwaitEffect` +
`KeyWait` and the `StaleExpectation` path push it back.

The load-bearing assumption is "the planner returns a
non-observation-consuming action only when no observation was present". I
traced the tools phase carefully — `tools_action` checks the frontier's
ready run *before* `advance_batch` consumes the observation, which is the
one shape where the assumption could break — and could not construct a
reachable interleaving, because staging and materialization happen in the
same synchronous drive pass with an empty observation queue between them.

It stays SUSPECTED rather than sound because nothing enforces it. A
cheap assertion — fault when a real observation survives a committed
transition — would convert a silent lost tool result into a loud fault,
which is the direction the rest of this codebase leans.

### L4 — Fork-point validation checks existence and nothing else (CONFIRMED behaviour, SUSPECTED impact)

`runtime/api.gleam:570-586`.

`validate_fork_point` asks `writer.get_entries([entry])` whether the id
resolves, then seeds the leaf. It does not check the entry's kind, or
that it lies on any live strand's branch.

Consequences I could establish: a leaf may be seeded on a `Compaction`
entry, in which case `with_projection`'s
`branch_scan |> branch_stop_at_kind(Compaction)`
(`strand_runtime.gleam:1013-1031`) starts at its own stop condition and
the subagent begins with an empty context — silently, with no error. A
leaf may also be seeded on an entry from a branch no strand still points
at, which is legitimate under "fork-in-place, shared tree" but is
indistinguishable from a caller passing a stale id.

The TOCTOU I went looking for is *not* there: the transaction vocabulary
has no entry delete, so a validated entry cannot vanish before the seed
commits. Entries are genuinely write-once in-session, and the
`rewrite_*` functions in `session/repo` operate on the file, not through
the writer.

Recommend at least rejecting non-message entries, and saying in the
docstring that any tree entry is accepted so a caller knows the check is
existence-only.

### L5 — Parallel batches recover one call at a time (CONFIRMED, fidelity)

`runtime/strand_runtime.gleam:786-805,1546-1554`;
`machine/planner.gleam:1786-1795`.

`resolve_key`'s `ToolKey` branch parks on `has_live_tool(operation,
step_id)` — operation-and-step granularity, not per source index. During
orphan recovery of a parallel batch the planner asks for the frontier's
pending call, gets `ObservedToolOrphaned`, `recover_tool` dispatches a
`ToolReplay`, and the next pass parks because *a* tool is live. So a
crashed parallel batch of five replay-safe calls replays them serially,
where the same batch dispatched fresh would overlap them.

Not a correctness break — it is the safe direction, and it is incidentally
why the exclusivity gate cannot be bypassed by a replay (see "Checked and
sound"). But it makes parallel recovery quietly sequential, which is
worth a comment at `has_live_tool` so nobody "fixes" the granularity
without noticing it is load-bearing for L5's sibling property.

### L6 — `put_fact` has no CAS, and "transactional blackboard" oversells it (CONFIRMED)

`runtime/api.gleam:746-771`.

```gleam
tx.Tx(writes: [tx.SetRegister(ns: register.FactCustom, key:, value: ...)],
      expected: [])
```

No expectation, so concurrent strands writing the same key silently
overwrite each other with no way to detect it, and no read-modify-write
is expressible. The docstring calls it "the shared, transactional
multi-agent blackboard"; what it is, is last-write-wins. The word
"transactional" is accurate about the single write being atomic and
misleading about everything a multi-agent caller would want it to mean.
An optional expected-seq parameter would make the concurrent case
expressible without changing the simple one.

### L7 — Abort re-arming is unbounded and silent; booter errors are lossy (CONFIRMED, minor)

`runtime/strand_runtime.gleam:489-518`; `runtime/supervisor.gleam:218-222`.

The ORCH-L5 fix is right in shape — a lost abort race must not drop the
request or restart the strand — but `AbortRaceLost` re-arms a timer with
no attempt ceiling, no backoff growth, and no telemetry. A permanently
contended strand re-fires `RequestAbort` at the poll interval forever and
nothing observes it. One counter, or a log after N re-arms, would make
the pathological case visible without weakening the convergence argument.

Separately, `boot_strands` discards the real `actor.StartError`
(`Error(_error) -> Error("the strand booter could not start strand " <>
strand_name)`), so the reason a strand would not start never reaches
anyone — which matters more given M5.

---

## Checked and sound

These are the hunt-list items where the code does what it claims. Recorded
so the next reviewer does not re-derive them.

**Abort settlement versus the monitor Down (the ORCH-M3 ordering claim).**
The claim at `strand_runtime.gleam:564-574` is that killing an effect
process without deregistering it is safe because a settlement already sent
is ordered before the `Down`. This holds, and for the right reason: the
settlement is sent **by the dying process itself**
(`spawn_provider:1042-1054` and `spawn_tool:1072-1076` both call
`wake(parent, ...)` inside the spawned closure), and the `Down` about that
process is likewise a signal from that process to the driver. BEAM
guarantees signal order per sender/receiver pair, so `[ProviderDone,
Down]` cannot invert. `take_live` then demonitors and removes the entry,
and the late `Down` falls into `effect_exit`'s unknown-pid branch. The
caveat worth writing down: this guarantee is a property of *who sends the
settlement*. If a future refactor routes settlements through a relay — a
timer, a pool, a supervisor — the ordering argument evaporates silently.
`real_timers` (`effects.gleam:243-252`) already sends from a third
process, which is exactly why `wake`'s guard exists there.

**Consume-before-dispatch crash safety.** A crash between the consumption
commit and the dispatch does spend the grant without executing, and the
re-cleared call then runs or refuses under the base policy. Fail-safe as
described. (The problem in H2 is the ordering relative to *clearance*, not
relative to dispatch.)

**The reserved-prefix refusal in `put_fact` is airtight.**
`string.starts_with(key, "escalation/")` is an exact match on an ASCII
prefix and `escalation.register_key` is injective, so no fact key can
forge or collide with an escalation record. Case variants ("Escalation/")
are permitted but land outside the prefix and therefore outside the
listing — they cannot impersonate. `facts` filters the prefix out of
listings. And the sqlite prefix listing escapes LIKE metacharacters
(`storage/sqlite.gleam:1879-1882`), so a crafted prefix cannot widen a
scan; the memory backend uses `string.starts_with` directly.

**The exclusivity gate cannot be bypassed by a crash-restore.**
`tool_may_start` (`strand_runtime.gleam:1325-1342`) is consulted only at
`ToolClearanceKey`, and `ToolReplay` dispatches skip clearance entirely —
which looks like a hole. It is not, because `ObservedToolOrphaned` is only
produced when `has_live_tool` is false, and the next pass then parks on
the replay it just started. So a replay never begins beside a live tool,
and an `Exclusive` tool cannot start next to a restored `Concurrent` one.
Fresh parallel dispatch is gated correctly in both directions (an
`Exclusive` call waits for an empty live set; nothing starts while one
runs), and the unknown-name default is `ExclusiveExecution`, the safe
direction.

**Out-of-order parallel settlement and source-ordered materialization.**
Traced the full interleave for a three-call batch settling 1, 2, 0.
`tools_action` materializes only the *contiguous* outcome-ready run at the
frontier, `stage_result` accepts any index, and `first_planned` walks past
pending and ready calls to find the next planned one. A late-settling head
therefore holds materialization until it lands, and entries enter the tree
in source order with each parented to the previous. `every_terminates`
requires all calls to terminate, so one `terminate: True` cannot end a run
while siblings are in flight. This matches pi §3.8's parallel row exactly.

**`send_to_strand`'s bounded retry neither livelocks nor drops.**
Exhaustion returns `Error(RaceLost)` — a value the caller can see, not a
silent drop. The attempt counter decrements only on the genuine
steer-refused-then-accept-busy race, and the inner `retry_admission(4)`
loops are independently bounded, so the worst case is a finite ~32 writer
round trips. The `Started`-versus-`Steered` distinction is reported
honestly.

**The ORCH-L6 leaf expectation is complete.** All four acceptance paths
funnel through one `plan` (`acceptance.gleam:212,263,343,365` → `420-434`),
so the `build.expect_leaf` addition covers every acceptance transaction
rather than the run path only. All three `AcceptCtx` construction sites
outside the machine — `runtime/api.gleam:262`,
`client/gateway.gleam:2188`, `conformance/simulation/runner.gleam:1068` —
read the real cell rather than passing a placeholder, so no caller
silently expects absence.

**ORCH-M3's abort usage retention is consistent across both settle
paths.** `settle_assistant`'s cancelled branch (`planner.gleam:1144-1165`)
already retained the real message and its usage; the M3 change brings
`settle_poll` to the same shape, and `settle_cancelled_poll` is correctly
narrowed to the unknown-outcome orphan path rather than deleted. This
matches pi §4.6's split between "really started … retaining reported
usage" and "no live result … zero usage". Restored effect-pending tools
under cancelled control are correctly never replayed
(`recover_tool`'s `Running, ReplaySafe` guard).

**Registry survival and booter idempotency.** The registry sits first in
the rest-for-one order, so a writer or strand crash leaves the name map
intact and a replacement driver re-registers under the same process name —
no orphaned drivers, because a factory restart shuts its children down
before the booter repopulates. `ensure_strand_running`'s
start-then-recheck-aliveness handles the booter-versus-`create_strand`
race without a lock: the loser's `start_child` fails on the duplicate name
registration and the aliveness recheck turns that into success. Rapid
create/kill/create of one name cannot collide, because `seed_strand`'s
absence expectation refuses the second create outright.
