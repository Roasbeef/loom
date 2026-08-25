# Adversarial judgment: agent communication tools and the system prompt

Target: `docs/design-notes/agent-comms-and-system-prompt.md` (988 lines, HEAD
commit `89ddf9f`). Read in full; every claim below was traced against the
code at `main`, not against the design's own account of it.

Verdict up front: **BUILD WITH CHANGES.** The two loudest claims — that a
blocking wait cannot deadlock, and that `agent_spawn` is idempotent under
replay — mostly survive a determined attack, and the reasons they survive
are the structural ones the design gives. But the design is wrong about
the concurrency it needs (the fan-out story does not work under the
shipped defaults, and its own two halves contradict each other), it is
missing a reconciliation branch that a two-commit `create_strand` makes
reachable, it proposes reaping children from a hook that runs on the
driver process, and its sandbox-prompt argument is priced against the
wrong enforcement mode. Six things must change before code is written;
the ordered list is at the end.

---

## Claim 1 — "a blocking `agent_wait` does not deadlock"

### 1(a) "The strand actor is not blocked" — **UPHELD**

Traced: `strand_runtime.plan` (`packages/runtime/src/runtime/strand_runtime.gleam:629`)
receives `planner.AwaitEffect(key:)` and calls `resolve_key`. For a tool
key, `resolve_key` (`:793`) tests `has_live_tool(state, operation, step_id)`;
with a live tool it returns `KeyWait`, and `plan` answers `Continue(state)`
(`:632-638`), which `finish` (`:319`) turns into `actor.continue(state)`.
The driver is back in its receive loop. `handle` (`:295-316`) then serves
`Nudge`, `PollTick`, `RetryDue`, `RequestAbort`, `ProviderDone`, `ToolDone`
and `EffectExit` normally.

I tried to break this by looking for a synchronous call on the `KeyWait`
path and found none. The claim holds exactly as stated.

### 1(b) "The writer is not blocked" — **UPHELD, with a thinner margin than claimed**

The tool body runs on a process the driver spawned: `spawn_tool` (`:1150`)
→ `spawn_effect` (`:1112`) → `process.spawn_unlinked`. There is **no pool**
— the question of a bounded effect-process pool starving other effects has
no purchase, because effect processes are raw BEAM spawns. (The one bounded
pool in the system, `exec.start_pool(size: 2, …)` in `client/serve.gleam:505`,
serves jailed executions only; `agent_*` tools take the empty policy and
never reach the broker.)

The poll loop also genuinely misses the StorageWriter: `api.await_result`
reads `operation_result` via `storage.get_register(runtime.session.store, …)`
(`api.gleam:504-514`) and falls back to `session.last_result` — neither goes
through `writer`. So a wait holds no writer capacity.

Two corrections to the design's phrasing, neither fatal:

- "There is no lock to hold" overstates it. Every storage backend
  "serialize[s] all operations through one actor mailbox"
  (`packages/storage/src/storage/storage.gleam`, module doc), so poll reads
  queue in the *same* mailbox as the writer's commits. The design already
  concedes "under contention, arbitrarily more" for elapsed time; the
  mechanism is this mailbox, and it is worth naming.
- Every writer entry point is `process.call_forever` (`writer.gleam:254,
  269, 285, 301, 316, 331, 345`) — no timeout anywhere. Nothing in this
  design wedges the writer, but the consequence of ever doing so is
  session-wide and permanent, not a timeout. That raises the bar for
  claim 1(a)'s cousin, below.

### 1(c) "Tool batch scheduling is per-operation" — **UPHELD, but the load-bearing corollary is BROKEN**

The narrow claim is true. `tool_may_start` (`:1413-1430`) filters
`state.live`, which is one driver's own list. Nothing reaches across
strands. A parent's batch cannot exclude a child from anything.

The corollary the design actually depends on is false as built:

> "`agent_wait` and the three readers are `Concurrent`, which is the
> load-bearing choice — a join over eight children is one tool batch of
> eight concurrent waits, not eight serial ones."

`Exclusive`/`Concurrent` is consulted only from `ToolClearanceKey`
(`strand_runtime.gleam:783`), and the planner only *reaches* a second
clearance while an earlier call is in flight under `tool_execution: Parallel`.
`request_batch_work` (`planner.gleam:1745-1754`) is explicit:

```gleam
CallEffectPending(source_index:, result_entry:, replay: _) ->
  case settings.tool_execution {
    operation.Sequential ->
      AwaitEffect(key: ToolKey(...))          // park; work nothing else
    operation.Parallel -> ...                  // work the next planned call
  }
```

And `api.default_options` sets `tool_execution: Sequential`
(`api.gleam:123`), which `client/serve.gleam:565` uses unmodified. Nothing
outside `packages/runtime/test/runtime/parallel_tools_test.gleam` and the
gateway's `set_config` handler ever selects `Parallel`.

So under the shipped configuration a join over eight children is **eight
serial waits**. With `max_wait_ms` at the design's default 60 s that is up
to eight minutes of one held-open operation — during which, by the design's
own analysis, a human steer is committed but undrainable, because steer
drains "at a checkpoint before generating"
(`docs/architecture/orchestration.md:285`), i.e. after the batch the strand
is inside. The design justifies the 60 s cap on the residual-cost of *one*
wait and then silently multiplies it by the fan-out.

There is a second, independent contradiction inside the design itself. The
`agent_wait` schema takes `handles: {"type": "array"}`, but the Agency
signature is `wait: fn(Handle, Int) -> Result(Waited, Refusal)` and `Waited`
carries a single `strand`. One tool call carrying eight handles is eight
serial Agency calls on one effect process, whatever `tool_execution` says.
The two halves of the design disagree about what the unit of waiting is.

Either of the two fixes works, but one must be chosen and its consequences
carried: (i) make `Agency.wait` a real multi-handle wait — one loop, one
deadline, first-settled-wins or all-settled — which makes the array schema
honest and leaves `Sequential` alone; or (ii) require `tool_execution:
Parallel`, which is a `serve` default change affecting every tool including
`bash` against a two-helper pool. (i) is smaller, truer to the schema
already written, and does not perturb anything else. Recommended.

### 1(d) "Mutual waiting is closed by construction" — **UPHELD, conditionally on finding 5(i)**

This is the strongest part of the design and it survived the attacks I
tried.

*Is the rule enforceable?* Yes, and for the right reason. The caller's
identity comes from `ToolRun.strand` ← `state.strand`, which is the
driver's own durable name, never a model argument. I looked for a way for
a model to lie about who it is and found none: `state.strand` is set by the
factory (`supervisor.gleam`, `Options(..template, strand: strand_name)`)
and reaches the tool only through fields the design proposes to add.

*Can a cycle be drawn?* No. `seed_strand` (`api.gleam:624-658`) commits all
three registers in one transaction with `Expect(seq: None)` on each, so a
name can be claimed exactly once; a fresh mint therefore always names a
strand that did not previously exist, and the lineage fact written at spawn
fixes its parent forever. Parent edges point strictly backwards in creation
order. A cycle would require a strand to be its own ancestor, which would
require a name to be claimed twice.

*What I tried and could not make work:* addressing a sibling (blocked by
the rule); addressing an operator-created strand with no lineage fact
(the Agency must fail closed here — **the design does not say this and
should**: "no lineage fact" must mean "not a descendant", never "unknown,
allow"); getting a child to wait on its parent via `agent_send` (send never
waits, confirmed — `send_to_strand` commits and returns).

**But the proof rests on the ledger's integrity, and the ledger is not
protected today.** `reserved_fact_key` (`api.gleam:854-860`) guards only
`escalation/` and `operation-result/`. Until `agency/` joins it, any writer
of `put_fact` can rewrite a parent link and manufacture the cycle the
argument says cannot be drawn. Finding 5(i) is therefore not hygiene; it is
a **precondition of claim 1(d)**, and the design files it under "failure
modes" rather than under the proof it holds up.

### Does abort reach a blocked waiter? — **UPHELD**

`RequestAbort` → `abort` (`:508`) → `abort_commit` → on `AbortDurable`,
`interrupt_live_effects` (`:582-585`) does `process.kill(live.pid)` for
every live effect. `process.kill` is untrappable, so a waiter blocked in a
sleep, in a `call_forever`, or anywhere else dies immediately. The monitor
`Down` reaches `effect_exit` (`:467-500`), which routes a `ToolEffect` to
`tool_done(… ToolFailed(…))` and settles it in-band. Then `recover_tool`
(`planner.gleam:1934`) refuses to replay because control is no longer
`Running`, so the aborted wait stages the interrupted result rather than
re-arming. Clean.

One hole the design's *lazy deadline enforcement* falls into: `api.abort`
(`api.gleam:426-434`) is a no-op when `live_strand_subject` finds no
registered driver — "the caller re-requests". The design's rule is "any
`agent_wait` or `agent_roster` call that observes an overdue child aborts
it before answering", with no re-request and no durable record of the
intent. Concrete failure: child C's deadline passed; C's driver crashed
80 ms ago and the factory has not yet restarted it; the parent's
`agent_roster` calls abort; `live_strand_subject` returns `Error(Nil)`; the
abort evaporates; the roster reports C reaped; C's restarted driver
re-plans from durable state and keeps running until the session closes.
The abort intent must be durable (a field on the lineage cell the strand's
own next checkpoint honours) or re-issued on every observation.

### The wedge the design did not consider: **hooks run on the driver process**

The design's lifetime bound says "The seam is `Hooks.run_end`, which fires
at a finishable boundary and can both abort undetached live children and
return a follow-up message reporting what they had produced," and its open
question 3 asks "May a hook abort?".

That is the wrong question. Look at where the hook runs:

```gleam
// strand_runtime.gleam:735-737, inside resolve_key, inside drive_loop
planner.RunEndKey(operation:) ->
  KeyObservation(planner.ObservedRunEnd(follow_up: hooks.run_end(operation)))
```

`resolve_key` is called from `plan`, which is called from `drive_loop`,
which runs **on the driver process**, before any `Continue`. Every hook —
`run_start`, `run_end`, `admission`, `threshold`, `resolution`,
`structural_decision`, `overflow_preparation`, `summary_progress` — is a
synchronous call on the driver.

So a `run_end` that reaps children does its work inside the parent driver's
receive loop. Aborting is fire-and-forget and survivable. But "return a
follow-up message reporting what they had produced" means reading each
child's result, which means at minimum `writer.get_entries` — a
`process.call_forever` from the driver — and if anyone ever writes it as
"wait briefly for the children to settle before reporting", the parent
driver stops serving `RequestAbort`, `Nudge`, and `PollTick` for the
duration. **That is exactly the failure claim 1(a) says cannot happen**,
reintroduced through a seam the design chose without checking where it
executes. The right question is *may a hook block*, and the answer from the
code is no.

A second defect in the same seam, which the design missed even though it
found the identical problem one type over: `run_end: fn(OpId) -> Option(AgentMessage)`
(`effects.gleam:205`) **carries no strand**. Production installs one `Hooks`
record for the whole session — `supervisor.gleam`'s doc is explicit that
only `strand` and `writer` are replaced per spawned strand, "so the same
effects, stream options, retry policy, and poll interval serve every
strand". A `run_end` hook therefore cannot tell whose run ended and cannot
know whose children to reap without an extra durable `OpId → strand`
lookup. The design correctly diagnosed this for `ToolRun` and added
`strand: String`; `Hooks.run_start`/`run_end` need the same field, and
unlike `ToolRun` that change touches every hook builder in `runtime/hooks`,
the simulation, and the test fakes.

### Two more interaction-model holes

**A child cannot get an answer from its parent while the parent waits.**
The design writes off child-to-parent traffic with "it lands as a durable
steer on the parent's open run and drains at the parent's next checkpoint,
which is after the batch the parent is currently in." True, and it means
the ask-my-parent pattern is unavailable precisely when a child needs it —
mid-task clarification, during the parent's `agent_wait`. Not a deadlock;
a designed-in hole that one sentence papers over. Worth stating, because a
model that discovers it will burn a whole 60 s window learning it.

**`agent_send` to a finished parent starts a fresh run.** `send_to_strand`
(`api.gleam:700-720`) falls back to `accept_quietly` on
`QueueRejected(NoActiveRun)`, which *opens a new operation*. That is
verbatim the property the design rejects auto-enqueue over: "a parent that
has already finished is woken into a fresh run, burning tokens with no
human present." Its own accepted primitive has the property it rejected the
alternative for. Either bound it (an Agency-level refusal when a send would
*start* rather than *steer* a run, unless `deliver: on_complete` asked for
it) or drop that leg of the rejection argument. As written the design is
inconsistent with itself.

---

## Claim 2 — "`agent_spawn` is replay-safe"

### The name derives only from persisted state — **UPHELD**

`recover_tool` (`planner.gleam:1918-1961`) replays only when control is
`Running`, the persisted policy is `ReplaySafe`, *and* the live
registration still agrees (`replay_still_safe`, from
`wiring.replay_still_safe`). It dispatches `ToolReplay` with
`arguments_key: build.tool_args_key(op.id, batch.turn_id, source_index)` —
so `{operation, step, source index}` are exactly the coordinates available
and durable, and the call's `purpose` argument comes from the durable
source assistant entry. The design's derivation is sound.

`StrandExists` on a replayed mint is also real: `seed_strand`'s
`StaleExpectation` arm maps to `StrandExists(name:)` (`api.gleam:655`).

### The three converging branches — **BROKEN. There is a fourth state.**

`create_strand` is **two commits, not one**:

```gleam
// api.gleam:735-757
use Nil <- result.try(validate_fork_point(...))
use Nil <- result.try(seed_strand(...))            // commit 1: three registers
use Nil <- result.try(supervisor.start_strand(...))
case accept_quietly(subagent, brief) { ... }        // commit 2: the brief run
```

A crash after commit 1 and before commit 2 leaves a strand with all three
registers seeded, `strand.state.current_operation == None` (`seed_strand`
writes exactly that, `api.gleam:642`), no `last_result`, and no lineage
fact. On replay:

- Branch 1 ("lineage fact exists") — no.
- Branch 2 ("strand exists but no lineage fact — recover the brief's
  operation id from the child's `strand.state` (or its `strand.last_result`
  if it has already finished)") — **both are empty. There is no operation
  id to recover.** The branch has no answer.
- Branch 3 ("neither exists") — no, the strand exists.

"All three converge on one child with one handle" is false for this state.
And the consequence is durable, not transient: the booter
(`supervisor.boot_strands`) starts a driver for every strand in
`register.StrandConfig` on every reboot, so the briefless strand sits Idle
forever, its name permanently claimed, counted against the fan-out cap by
any ledger-versus-live-strand-set scan.

The missing arm is small and should be written down: *strand exists, no
lineage fact, no current operation, no last result* → `accept_quietly` the
brief onto the existing strand now, write the fact, return the handle.
`accept_quietly` already has its own CAS retry ladder, so it is safe to
call on a strand whose driver may be mid-anything.

### Two siblings racing — **not a hazard for names; real for caps**

Names: `agent_spawn` is `Exclusive` and, under the shipped `Sequential`
default, nothing overlaps anyway; distinct `source_index` gives distinct
names regardless. No race.

Caps: `put_fact` commits with `expected: []` (`api.gleam:786-796`) — **no
CAS**. The fan-out check is read-ledger-then-write with no atomicity, so
two spawns that genuinely overlap can both pass a "16 live strands per
session" check. Impossible at `depth: 1` (only `main` spawns, and its
spawns are `Exclusive`), so it is not a blocker — but the design presents
the depth cap as "a configuration knob", and raising it makes this live.
Either make the count a CAS on one counter cell or state that the cap is
advisory above depth 1.

### Name hygiene — unspecified and it matters

`purpose` is model-supplied free text and becomes part of a strand name,
which is a key in three register namespaces and half of the
`sub:main/reviewer-1#op_01J…` handle text the model parses back. The design
asserts a model "cannot claim `main`, cannot shadow an operator's naming
convention" — true only for a slug function that does not exist yet, and
`create_strand` validates no names of its own. Specify it: `[a-z0-9-]+`,
length-capped, non-empty fallback, `/` and `#` rejected so the handle stays
unambiguously splittable.

---

## Claim 3 — "the floor-not-a-bound fix" — **UPHELD, both halves**

The description of the defect is exact. `api.gleam:518-529`:

```gleam
fn await_result_wait(runtime, operation, timeout_ms) {
  case timeout_ms <= 0 {
    True -> Error(Nil)
    False -> {
      process.sleep(10)
      await_result(runtime, operation, within_ms: timeout_ms - 10)
    }
  }
}
```

10 ms sleep, recursion on `timeout_ms - 10`, and the two store reads that
`await_result` performs each iteration (`operation_result`, then the
`session.last_result` fallback) are charged nothing. Elapsed ≥ budget
always, and unboundedly more under storage-mailbox contention.

`within_ms: 0` does what the design assumes, and I checked this specifically
because "returns immediately-empty forever" would have killed the sketch.
It does not: `await_result` (`api.gleam:481-499`) performs *both* reads
**before** it consults the budget, and only then falls into
`await_result_wait`, which returns `Error(Nil)`. A zero budget is a genuine
single-shot read of both the operation-keyed row and the strand-register
fallback. The `wait_until` sketch is sound, and its three claimed
properties (deadline from an injected clock rather than by subtraction;
backoff cutting store traffic to ~4 reads/s per waiter; logical time under
simulation) all follow.

Two things to say honestly that the design does not:

- This routes *around* the defect; it does not fix it. Every other caller
  of `api.await_strand_result` — tests, the gateway, the demo — keeps the
  floor. The `docs/notebook.md:212` item stays open, and the design should
  say so rather than implying the deferred item is discharged.
- The Agency's own loop must carry an **absolute** deadline in the lineage
  cell, not a relative `within_ms`. Otherwise the "deadline is computed
  from the injected clock rather than accumulated by subtraction" property
  dies at the first strand restart, because a `ReplaySafe` `agent_wait`
  re-arms from zero. See the fault-amplification section.

---

## Claim 4 — the sandbox security call — **BROKEN as reasoned**

The design's position:

> State the layers this kernel does enforce. Do not enumerate the ones it
> does not.

resting on: "nothing a cooperative agent does differs for knowing that
seccomp is unavailable," and conceding one counterargument: "a degraded jail
can let a command succeed that the agent was told would be refused."

**Both the premise and the conceded counterargument are written against
`BestEffort` semantics, and production runs `FullEnforcement`.**

`client/serve.gleam:311-314` sets `demand: exec.FullEnforcement` unless an
explicit `--best-effort` flag is passed; `wiring.gleam:141-144` says
`BestEffort` is "for development containers and self-tests only". Under
`FullEnforcement`:

- A helper whose hello advertises `degraded` is refused **before dispatch**:
  `case request.demand, degraded_features(features) { FullEnforcement, True
  -> process.send(reply, Error(DegradedHelper(features:))) }`
  (`broker/exec.gleam:597-601`).
- A result whose `enforcement` list carries any `skip:` entry is refused
  **after** the run: `FullEnforcement, True -> Failed(failure:
  DegradedExecution(result:))` (`broker/exec.gleam:761-763`), and the
  comment is explicit that a `skip:` counts "whatever the bool says".

So on a degraded production host, every jailed execution **fails**. The
conceded counterargument imagines the opposite failure. And the premise —
that a cooperative agent's behaviour does not differ — is exactly inverted:
on such a host `bash` stops working entirely and the agent has no way to
know why.

That mis-pricing propagates into the section's four behaviour-changing
bullets, three of which are actively wrong for a degraded production host:
a refusal there is **not** "a structured policy denial", repeating is
correctly discouraged but for the wrong reason, and "a denial can be
escalated to a human, who may approve exactly one widened re-execution"
is false — no policy widening conjures a missing kernel layer, and the
escalation path will not clear it. The one "neutral sentence" the design
grudgingly allows for a degraded host turns out to be the single most
behaviour-changing sentence available, because it is the only thing that
explains a total tool failure.

The benefit side is weaker than claimed too. An injection payload holding
`bash` does not need the prompt to map the holes: `grep Seccomp
/proc/self/status`, a `prctl` probe, one `curl` to test egress. Enumerating
your own confinement from inside a shell is one tool call and returns
*ground truth*, where prompt text is only a claim an attacker would have to
trust. Withholding costs the attacker roughly one tool call. It costs the
cooperative agent the only sentence that would let it behave correctly —
and the cooperative agent is the only party that will not probe, because it
has no reason to.

I argued the design's side as hard as I could before landing here. The best
version of its case is: prompt text is free, reliable and unlogged, while a
probe is a tool call that leaves a trace and can be denied — so there *is*
a real if small asymmetry, and "prompts are UX, never a control" is the
correct frame. That is enough to justify not printing a layer inventory. It
is not enough to justify withholding behavioural posture.

Recommended replacement, which gives the attacker nothing a single `curl`
would not, and gives the agent everything it needs:

- State posture at behavioural granularity, not layer names: "network
  egress is blocked, and that block is enforced below you."
- On a degraded host, give the failure mode its own sentence and
  distinguish it from a policy denial: "kernel enforcement this host cannot
  provide is unavailable, so jailed execution is refused outright rather
  than run unconfined. This is a host problem, not a policy denial, and
  escalation will not clear it — report it."

That also answers open question 4 — *no*, do not omit the enforcement line
on a fully-enforced host. The presence of the line on every host is what
makes its variation meaningful.

**Separately: `Environment.enforced_layers` and `enforcement_complete` have
no source in the harness today.** The helper's hello features carry only a
coarse `degraded` flag (`degraded_features`, `exec.gleam:634`); the
per-layer `skip:` list exists only inside an `ExecResult`, i.e. after a real
execution; and the `ENFORCED`/`SKIPPED` report is `./loom-helper --self-test`,
a separate process invocation behind `make selftest:129`. Populating those
two fields at session open is unbuilt work the design does not scope. Either
scope it (a probe at pool start, cached — it is the sort of thing the
pinning section exists to make reproducible) or reduce the fields to what
hello actually provides.

---

## Claim 5(i) — reserved fact prefixes — **UPHELD, exactly as reported**

```gleam
// api.gleam:854-860
fn reserved_fact_key(key: String) -> Bool {
  string.starts_with(key, escalation.key_prefix)          // "escalation/"
  || string.starts_with(key, operation.result_fact_prefix) // "operation-result/"
}
```

(`escalation.gleam:108`, `operation.gleam:540`.) Nothing else is reserved.
`agency/` and `prompt/` are writable through `put_fact` today, so
`agent_note` — if it ever escaped its own prefix, or if any other trusted
caller is added — could rewrite a parent link or the pinned operator
prompt. This must land first. As argued under claim 1(d), it is the
precondition of the acyclicity proof, not a hygiene item.

Three follow-ons the design does not state and an implementer will hit:

1. **Reserving a prefix also hides it from reads.** `api.facts` filters
   reserved keys out of its listing (`api.gleam:838-852`). So once `agency/`
   is reserved, `agent_roster` cannot read the lineage ledger through
   `facts`. It must use `api.fact`/`writer.get_register` (the singular read
   does *not* consult `reserved_fact_key`) or the Agency needs a privileged
   list path. Decide which and write it down.
2. **`agent/` and `agency/` are one character apart, and one is the guard
   for the other.** They do not actually overlap (`"agency/…"` does not
   start with `"agent/"` — they diverge at index 4), so there is no bug
   today. But a design where the model-writable namespace and the
   integrity-critical ledger differ by two letters is one typo in
   `reserved_fact_key` away from lineage forgery. Rename the ledger to
   something disjoint — `lineage/`.
3. **`agent_notes` with no prefix leaks the whole blackboard.** Its schema
   says "omit to read everything visible", and the obvious implementation
   is `api.facts(runtime, prefix: None)` — which returns *every*
   non-reserved fact in the session, operator writes included. The prose
   says "reads the whole `agent/` namespace"; the schema says otherwise, and
   the schema is what the model reads. The Agency must clamp an absent
   prefix to `agent/`.

## Claim 5(ii) — tool order and the cache prefix — **UPHELD as a description; "live defect" needs qualifying**

The mechanism is exactly right. `wiring.tool_specs` (`wiring.gleam:319-331`)
is `list.filter_map(active, …)` over the configuration's list — config
order, verbatim, no sort, no dedup, no registry-membership validation. It
feeds `provider_request.tools` (`wiring.gleam:242`). The Anthropic adapter
hangs a one-hour breakpoint on the last tool definition and a second on the
system block (`adapter/anthropic.gleam:320-370, 417-430`), and the API
"caches by exact byte prefix over the render order `tools` -> `system` ->
`messages`" — so the tool array is a strict prefix of the system block's
cached region, and any reordering invalidates both head positions. Prompt
caching did land this session (`97c821b`, `1b49480`).

The qualification: it is a **reachable latent defect, not one currently
firing**. `serve.gleam:538` seeds a fixed order —
`["bash", "fs_read", "fs_write", "fs_edit", "grep"]`, which is notably
*not* sorted — and nothing rewrites it spontaneously, so an untouched
session caches correctly. The reachable path is `set_config active_tools`
(`gateway.gleam:2473-2494`), which takes the client's array **verbatim**:

```gleam
Ok(update_configuration(_, strand, fn(configuration) {
  machine_strand.StrandConfiguration(..configuration, active_tool_names: names)
}))
```

No sort, no dedup, no membership check. A client that re-sends the same
five names in a different order pays a full 2× one-hour head write for
nothing, every time. A client that sends a duplicate renders the same tool
twice on the wire.

So: fix it now, independently of this design, in **two** places. Sorting
`tool_specs` alone is not sufficient, because `active_tool_names` is also
the membership test in `wiring.clear`
(`list.contains(query.configuration.active_tool_names, name)`) and a
duplicated or unknown name belongs nowhere in a strand's durable
configuration. Sort and dedup at the `set_config` boundary too.

The design's downstream conclusion — bespoke per-child tool subsets buy
each child a distinct head prefix and eight children pay the one-hour write
eight times — follows correctly, and the recommendation that children share
one standard worker set is right for the stated arithmetic reason.

One detail that strengthens it and is missing: today `wiring.Config.system`
is `None` unless `LOOM_SYSTEM_PROMPT` is set, and the adapter emits no
`system` field at all in that case (`anthropic.gleam:130-131`). So the
second head breakpoint is currently unspent. Part B is what makes the head
worth protecting; the sorting fix is what keeps it protected.

---

## Claim 6 — the seam

**Dependency DAG — UPHELD in shape, BROKEN in the sketch.** `client`
depends on `runtime` and `tools` (`packages/client/gleam.toml:12,15`);
`tools` depends on neither. A record of plain-data closures declared in
`tools` and filled in `client` is exactly the `clear_call` precedent and
respects the DAG. Purity layering is untouched — `tools` is not a pure
package (`gleam-style.md:591` names only `core` and `machine`), so a
function-record seam is unremarkable there.

But the sketch as written does not compile: `send: fn(String, String) ->
Result(Delivery, Refusal)` names `Delivery`, which is defined in
`runtime/api.gleam:662`. `tools` cannot import it. It needs a local mirror
— precisely the pattern `effects.ToolOutcome` already uses, whose doc says
it mirrors "the broker's `CallOutcome` split … without a broker dependency"
(`effects.gleam:106-108`). Cosmetic, but it is the kind of thing discovered
at the end of an implementation rather than the start.

**Bootstrap knot — UNPROVEN. The design names it and does not solve it.**
"Production wiring fills it with closures over the live runtime" is not
achievable as stated. `serve` builds `wiring.Config` → `wiring.build_effects`
→ `effects_record` and only *then* calls `api.open` (`serve.gleam:541-573`),
and `Runtime` **contains** `effects: Effects` (`api.gleam:68-76`). A closure
reachable from `Effects` that captures the `Runtime` is a genuine value
cycle, not a plumbing inconvenience. `tool.Ctx` is built inside
`wiring.tool_context(config, …)`, itself a closure over `wiring.Config`
built before open, so putting `Agency` in `Ctx` inherits the cycle exactly.

The repo already ships the fix, four lines above the knot:
`hub.commit_forwarder(to: name)` mints a process name before the gateway
exists and the effects close over the *name*, not the process. The Agency
must do the same — close over a `Name`, start an agency actor holding the
`Runtime` after `api.open`, and let calls arriving before it starts settle
as ordinary refusals. Say this in the design or it will be rediscovered
mid-implementation.

The same knot bites Part B: the assembled `system` string must be in
`wiring.Config` *before* `api.open`, so the pinned `prompt/` cell has to be
read and written on the session store **directly, before the tree boots**
and takes the writer lease. That is legal — there is no committer yet — but
it is a real constraint on the pinning design and it is unstated.

**Does `Option` make every call a silent no-op? — No, but the shape is
still wrong.** `tool.dispatch` returns a structured `is_error: True`
outcome for an unregistered name (`tool.gleam:288-296`), and a `None`
agency would return the same in-band refusal — visible to the model, not
silent. The real cost is elsewhere: `tool_specs` builds the wire array from
the **registry**, not from the agency. An unwired host therefore ships six
tool definitions the model can only ever be refused on — tokens paid on
every request of every strand forever, and paid at the very front of the
cached prefix. Better shape: drop `Option` from `Ctx` and have `registry()`
take an `Agency`, registering the six tools only when one exists. An
unwired host then has five tools and no wasted head bytes, and the
`None`-handling code does not need to exist.

---

## The open questions

### Listed as open, actually narrowed by the code

**Q6 (wake on an EventBus `StrandResult` hint).** The event exists and is
`StrandResult(strand: String)` (`events/bus.gleam:70`) — **strand-keyed, not
operation-keyed**. The design's own §"Reusing the await machinery" praises
the operation-keyed `operation-result/{op}` row precisely because
latest-wins on the strand is wrong (that was `RT-await-aba`,
`m3-triage.md:47`). So the hint cannot distinguish a child's first result
from its second, and can only ever mean "re-poll now". That narrows the
question considerably; the design's conclusion ("the poll must remain
underneath either way") is already correct.

**Q3 (may a hook abort?).** Partially settled, in a direction the design
did not look: hooks run on the driver process, so the binding constraint is
that a hook must not *block*, and abort happens to satisfy it because
`api.abort` is fire-and-forget. Reframe the question and the answer follows.

### Treated as settled, actually still open

- The `Concurrent` execution mode as the fan-out enabler (claim 1(c)) —
  inert under the shipped `Sequential` default, and contradicted by the
  Agency's single-`Handle` signature.
- `Hooks.run_end` as the reaping seam — not usable as-is: no strand, runs
  on the driver.
- The three reconciliation branches — not exhaustive.
- `Environment.enforced_layers` / `enforcement_complete` — no source.
- "Production wiring fills it with closures over the live runtime" — a
  value cycle, not plumbing.

### Fault amplification: **not a ship blocker, but worse than described, and cheaply mitigated**

The design says a faulting strand "restarts, faults again, and keeps
faulting until the supervisor's tolerance is exhausted, at which point the
whole session tree dies visibly," and that a waiting parent "sees `Pending`
right up until it sees nothing."

The chain is real: a register that fails a total decode makes `load` return
`Error(reason)` → `Halt` → `actor.stop_abnormal`
(`strand_runtime.gleam:319-323`); the factory restarts it under
`factory_supervisor.restart_tolerance(config.tolerance)`; the same corrupt
register faults it again. `api.default_options` sets
`Tolerance(intensity: 5, period: 5)`.

But the intermediate behaviour is worse than "sees `Pending` until it sees
nothing". The session supervisor is **`RestForOne`** over
`[registry, writer, strand-factory, booter]` (`supervisor.gleam:96-121`).
When the factory's own tolerance blows, the factory dies, and rest-for-one
restarts **the factory and the booter** — killing and rebooting *every*
strand driver in the session, not just the faulting one. Only after the
session supervisor's own 5-in-5 intensity is spent does the tree die.

For this design that means: on each round, every parent's blocked
`agent_wait` effect is reaped by its incarnation reaper (the driver dies →
the reaper linked to it dies → the effect linked to the reaper dies —
`strand_runtime.gleam:1044-1120`, the closed `RT-restart-leak`); the
restarted driver re-plans, hits `ObservedToolOrphaned` with
`replay_still_safe: True`, and — because `agent_wait` is `ReplaySafe` —
**re-arms the wait from zero for a full fresh deadline window**. A 60 s wait
can be restarted several times before the tree finally dies, and each
restart hands the model a wait that outlives the budget it was promised.

Why it is not a blocker: the amplification is bounded and fast (seconds to
tree death), the failure is visible rather than silent, and model-spawned
strands are not intrinsically more likely to hold corrupt registers than
operator-spawned ones — the design's "multiplies the number of strands that
can fault" is a counting argument that, at `depth: 1` and `fan_out: 8`,
multiplies by at most nine.

Why it should not ship without two cheap things:

1. Start model-spawned strands under a **separate factory with its own
   tolerance**, so a subagent crash-loop cannot spend the session's
   restart budget or reboot `main`. This answers open question 4 *yes*, and
   it is a `supervisor.Config` change, not a redesign.
2. Carry an **absolute** deadline in the lineage cell rather than a
   relative `within_ms`, so a replayed `agent_wait` resumes toward the same
   wall-clock instant instead of restarting its clock. This is required
   anyway for claim 3's "deadline computed from the injected clock rather
   than accumulated by subtraction" to survive a restart.

### One robustness note not in the design

`supervisor.start_strand` → `ensure_strand_running` →
`factory_supervisor.start_child(factory_supervisor.get_by_name(strands_name), …)`
has **no aliveness guard**, unlike `api.nudge` and `api.abort`, which both
check `live_strand_subject` first precisely because "sending into an
unregistered name would crash the sender" (`api.gleam:396-399`). An
`agent_spawn` that races a factory restart takes its effect process down.
That settles in-band as a `ToolFailed` → synthetic error result, so it is
ugly-but-safe rather than a fault — but a guard and an explicit refusal is
one line and reads better than a process death in the logs.

---

## What survived

Recorded plainly, because a design that holds up is a useful verdict:

- **The driver is genuinely not blocked by a blocking tool.** I looked for
  a synchronous call on the `KeyWait` path and there is none.
- **Abort genuinely reaches a blocked waiter**, and a replayed aborted wait
  genuinely does not re-arm (control is not `Running`, so `recover_tool`
  stages the interrupted result).
- **The descendant-only rule is genuinely enforceable and genuinely
  acyclic**, for the reasons the design gives, once `agency/` is reserved.
  I could not construct a cycle: sibling addressing is blocked, child→parent
  never waits, and a name can be claimed exactly once by CAS.
- **`within_ms: 0` genuinely reads once and returns.** This was the most
  likely way for claim 3's sketch to be quietly wrong and it is not.
- **The name derivation is genuinely from persisted state only**, and
  `build.tool_args_key(op.id, turn_id, source_index)` proves those exact
  coordinates are the durable ones.
- **The seam respects the dependency DAG and the purity layering.**
- **The compaction argument for system-prompt placement is correct** —
  compaction rewrites the message prefix; `system` is not in the entry tree
  at all, so guidance in `messages[0]` evaporates and guidance in `system`
  does not.
- **The stability contract's five points are achievable**, and points 1 and
  3 are already true by construction because `wiring.Config.system` is one
  session-scoped value shared by every strand.
- The rejections of `cap/strand`, raw `Process.send`, `spawn_session`,
  auto-enqueue-as-primary, a `const` prompt in Gleam, per-role prompts, and
  per-turn rendering are all correct and correctly argued.

---

## Recommendation: **BUILD WITH CHANGES**

### Must change before implementation

1. **Reserve `agency/` and `prompt/` in `reserved_fact_key`** — and decide
   how the Agency reads a reserved prefix, since `api.facts` filters them
   out. Rename the ledger prefix to `lineage/` so it is not one character
   from the model-writable `agent/`. *(Precondition of claim 1(d); the
   design files it as a failure mode.)*

2. **Fix the fan-out story and make the design's two halves agree.** Make
   `Agency.wait` a genuine multi-handle wait over one deadline, matching the
   `handles: array` schema already written — or declare `tool_execution:
   Parallel` a requirement and change `serve`'s default, carrying the
   consequences for `bash` against a two-helper pool. Re-derive `max_wait_ms`
   from whichever is chosen; the current 60 s is justified for one wait and
   silently multiplied by the fan-out.

3. **Add the fourth reconciliation branch to `agent_spawn`** — strand
   seeded, no operation, no last result, no lineage fact → `accept_quietly`
   the brief onto the existing strand now, then write the fact. And specify
   the slug function (`[a-z0-9-]+`, capped, `/` and `#` rejected).

4. **Do not reap from `Hooks.run_end` as it stands.** Hooks execute on the
   driver process inside `drive_loop`; a blocking hook breaks claim 1(a)
   directly. If `run_end` is the seam it must be strictly non-blocking —
   fire-and-forget aborts, no waits, no result rendering — and it needs a
   `strand` field, because one `Hooks` record serves every strand in the
   session. Rewrite open question 3 as "may a hook block?" and answer no.

5. **Rewrite the sandbox enforcement paragraph against `FullEnforcement`
   semantics.** A degraded production host refuses every jailed execution
   before dispatch; three of the section's four bullets are wrong for that
   case. State posture behaviourally rather than by layer inventory, and
   give the degraded case its own sentence distinguishing a host failure
   from a policy denial. Answer open question 4 *no*. Name a source for
   `enforced_layers`/`enforcement_complete` or drop the fields.

6. **Solve the bootstrap knot explicitly** — the named-subject indirection
   `hub.commit_forwarder` already demonstrates — for both the Agency and the
   pinned `prompt/` cell (which must be read and written on the session
   store before `api.open` takes the writer lease).

### Should change, with or before

7. **Sort and dedup `active_tool_names` in two places**: `wiring.tool_specs`
   *and* the `set_config active_tools` handler, which also needs a
   registry-membership check. Ship this independently — it is a live latent
   cache defect against already-shipped prompt caching.
8. **Clamp `agent_notes` with no prefix to `agent/`**; the schema currently
   promises "everything visible" and the naive implementation delivers it.
9. **Mirror `Delivery` (and any other `runtime`/`machine` type) into
   `tools`**, following `effects.ToolOutcome`'s precedent.
10. **Gate agent-tool registration on the Agency's presence** instead of
    `Option(Agency)` in `Ctx`, so an unwired host does not ship six
    permanently-refusing tool definitions at the front of the cached prefix.
11. **Carry an absolute deadline in the lineage cell**, so a `ReplaySafe`
    `agent_wait` resumes toward the same instant rather than restarting its
    clock after a restart.
12. **Make the lazy deadline abort durable or re-issued** — `api.abort` is
    silently dropped when no driver is registered.
13. **Give model-spawned strands their own factory and tolerance** — this
    answers open question 4 yes, and it is the cheap half of the
    fault-amplification mitigation.

### Ship as designed

Claim 3's wait loop and its `within_ms: 0` reuse. The descendant-only
addressing rule, once (1) lands. `ReplayNever` on `agent_send` and the
interrupted-result story. `context: fresh`, narrow-only `tools`, `depth: 1`.
The prompt pack shape, the six sections, root-only framed capped
`CLAUDE.md`, system-prompt-over-`messages[0]`, pinning, and the stability
contract given (7). Every rejected alternative.

### Two things to state honestly rather than fix

The `await` timeout floor stays open in `api` for every other caller — the
Agency routes around it, it does not discharge the `docs/notebook.md`
item. And the interaction model has a designed-in hole: a child cannot get
an answer from its parent while the parent is inside `agent_wait`, and
`agent_send` to a *finished* parent opens a fresh run — which is the exact
property the design rejects auto-enqueue over. Either bound that leg or drop
it from the rejection argument; as written the design contradicts itself.
