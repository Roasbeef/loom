# Scheduled heartbeats: durable time-triggered admission

Design ruling for a cron/heartbeat capability, consulted (Fable 5 advisor,
read-only) before any code was written, per `docs/execution.md` §7. This
note is the record; the issue tracks the work; the code is the truth
where the two disagree later.

## The ask, and the prior art

Loom has no time-triggered admission today — a strand only hears from a
human, a sibling strand, or a content-triggered rule (#27). Two systems
were used as reference, not as templates to copy structurally:

- **Claude Code** ships two shapes: an ephemeral, in-memory, per-session
  `CronCreate`/`CronList`/`CronDelete` (jittered, 7-day auto-expiring,
  gone when the session ends), and durable server-side "Routines" that
  can resume a session or spawn a fresh one on a schedule with nobody
  present.
- **Prime Agent** (PrimeIntellect-ai) calls the same idea a *heartbeat*:
  a cron-style message injected on a fixed interval, delivered through
  the session's ordinary steer/follow-up path — "the same execution and
  persistence path" as any other prompt, just another source tag.

Loom has no daemon and no cross-session infrastructure, so the only
version of "wake a dormant session" that is coherent here is *wake an
idle strand inside a session whose server the operator left running*.
That reframing does most of the work below.

## The mechanism: `client/rules` + `client/rulescan`, time-triggered

The nearest existing analog is the triggered-project-rules feature (#27):
an operator-authored, parsed-and-bounded config store
(`client/rules.gleam`) plus a session-scoped restartable actor
(`client/rulescan.gleam`) that fires a durable, fenced, non-authority-
framed injection via `runtime/api.steer_marking` — one transaction that
both admits the queue item and writes a write-once `fact.custom` mark,
so a crash between deciding and committing can never double-fire.

Scheduled heartbeats reuse the same shape verbatim: `client/schedule.gleam`
(the config/store half) and `client/schedulescan.gleam` (the actor half).
Nothing here touches `machine` — the frozen `next_action` surface, the
operation state space, and the register/queue vocabulary are unchanged.
"Next fire" is *derived*, not stored: schedule config (from `loom.toml`)
plus the write-once fire-marks already in `fact.custom` fully determine
what is due at any instant, the same way `rulescan` re-derives its
`Progress` from the store on every incarnation rather than trusting
anything held in memory.

## The crux: may a schedule wake an idle strand?

`rulescan`'s rule is deliberate: a *content*-triggered rule may only
steer an open run, never start one, because content arrives constantly
and unpredictably — a rule that could wake an idle strand could keep a
session alive forever, invisibly, one fire at a time.

A schedule breaks every leg of that argument: it is operator-authored,
time-driven (its total fire count is computable from its config), and
carries a mandatory expiry (see Bounds). A heartbeat that can only steer
an already-open run is not a heartbeat — it cannot watch a subagent
unattended or poll anything while the strand is idle, which is the
entire point of both pieces of prior art.

**Ruling: allowed, opt-in, per schedule.** A schedule's `wake` field
defaults to `false` (steer an open run, hold — freeze and retry next
tick — when idle, exactly mirroring `rulescan`). Set `wake = true` to let
this schedule accept a fresh run on an idle strand
(`runtime/api.Delivery.Started`). The guardrail that makes this safe is
that every recurring schedule expires (Bounds), so a `wake = true`
schedule cannot keep a session alive past a bound the operator set and
can see in the config file.

## The one real gap: fresh-run admission has no marking door

`runtime/api.steer_marking` folds a write-once `fact.custom` mark into
the *steer* admission's transaction (`marked(plan_tx, mark)`, which is
generic over `core/tx.Tx`) and tells the mark's own stale expectation
apart from the ordinary operation-state race
(`commit_admission`/`conflicted_key`). The fresh-run path
(`accept_quietly`, built on `machine/acceptance.accept_prompt` through
`accept_request`) had no such door before this work, because nothing
needed one — `send_to_strand` only ever carried an ephemeral doorbell,
no mark. A `wake = true` schedule needs exactly-once semantics on *that*
path too, or a crash between deciding to wake and committing could
double-fire on restart.

Fixed by threading the same `Option(Mark)` `enqueue` already threads,
through `accept_request` into the commit, reusing `marked`/
`commit_admission` unchanged (they are already generic over `tx.Tx` and
`Option(Mark)`):

```gleam
pub fn accept_quietly_marking(
  runtime: Runtime,
  prompts: List(AgentMessage),
  mark: Mark,
) -> Result(OpId, ApiError) {
  accept_request(runtime, AcceptRun(prompts:), Some(mark))
}

pub fn send_to_strand_marking(
  runtime: Runtime,
  to target: String,
  message message: AgentMessage,
  mark mark: Mark,
) -> Result(Delivery, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(mark.key),
    return: Error(UnreservedFactKey(key: mark.key)),
  )
  send_attempts_marking(on_strand(runtime, target), message, mark, 4)
}
```

`send_attempts_marking` mirrors `send_attempts`: try `steer_marking`
first, fall back to `accept_quietly_marking` on `QueueRejected(NoActiveRun)`,
retry the steer if a run opens in the gap (`AcceptRejected(StrandBusy)`).
This is additive-only Gleam API surface inside `runtime/api` — not a wire
or `machine` interface — so it needs no `protocol-change/` proposal,
exactly as `rule/`'s reserved prefix and `steer_marking` itself did not
when #27 landed.

A `wake = false` schedule needs none of this — it calls the existing
`steer_marking` directly, unchanged, exactly as `rulescan` already does.

## Model-writability: cut, not deferred

Operator-only `[[schedule]]` in `loom.toml`, restart-to-change, like
`[[rule]]`. `client/rules.injection`'s fenced, non-authority framing
solves "whose text is this" for content the model might mistake for a
human; it does nothing for a model that can extend its own liveness and
spend unsupervised by scheduling its own future wake-ups, which is a
sharper problem than the one framing was built to solve. If a
model-facing self-scheduling primitive is ever wanted, the shape is: the
model *requests* a schedule through the escalation plane and an operator
approves it — a durable, attributable grant, not a blackboard write.
Not built here.

## Durability and the crash story

- Fires only while the session's server process is running. A session
  closed through a missed window catches up to **at most one** late
  fire per schedule at the next boot, then resumes on schedule — never a
  replay of the whole missed backlog.
- Interval schedules align to a fixed grid: `slot = floor(now_s /
  interval_s)`. There is no stored "started at"; a slot's fire-mark
  existing or not, read fresh from the store, is the entire state. A
  boot (or a tick) that finds no mark for the *current* slot fires it
  once — never iterates older skipped slots — which is what makes "at
  most one late fire" fall out of the algorithm rather than needing
  separate bookkeeping. Late is a display-only annotation:
  `now_s >= slot_start_s + interval_s`.
- One-shot schedules have exactly one occurrence — the `at` timestamp —
  and fire it once, whenever first observed at or after `now`, with the
  same late annotation. There is no useful distinction between "the
  timestamp was already past when the config was parsed" and "the
  server was down past it": both are the identical one-shot catch-up
  case, so there is no separate parse-time refusal for a past `at`.
- Fire marks are the correctness-critical, CAS-on-absence write, exactly
  like `rule/fired/*`: `schedule/fired/{strand}/{name}/{occurrence}`
  where `occurrence` is the slot's epoch second (interval) or the `at`
  epoch second (one-shot) — disjoint from `rule/`'s namespace, per the
  house rule that a reserved prefix is a security-relevant surface, not
  a filing convenience. There is no lazy "cursor" register the way
  `rule/cursor/` speeds up rulescan's read side: expiry and "is this due"
  are computed directly from a bounded scan of the fire-marks under one
  schedule's prefix (`runtime/api.reserved_facts`), which is exact,
  never a wrongly-cached approximation, and cheap because the count is
  bounded (see Bounds).
- Built on the existing injected `runtime/effects.Timers` seam
  (`Timers.after(delay_ms, wake)`, sharing the strand driver's clock
  base), never a second, untestable clock — non-negotiable, since it is
  what keeps this under the deterministic simulation runner.
- The scanner actor recomputes fully from the store on every tick and
  holds no state across ticks beyond the parsed, static schedule list —
  a restart loses nothing because there was nothing to lose. Each tick,
  after firing whatever is due, re-arms a single timer for the soonest
  next boundary across every still-active schedule.

## Bounds

Every bound refuses at `loom.toml` parse time with a worded message,
`client/rules`'s style, never a boot into a degraded state:

- `max_schedules = 16` — each is a standing clock; nobody has a use case
  for more yet, and raising it later needs evidence, not a knob.
- `min_interval_s = 60` — below that a schedule is a busy-loop against
  provider budget; comfortably above timer/poll granularity.
- `max_name_length = 64`, `max_body_length = 8192` — copied from
  `client/rules` verbatim, same reasoning (a durable key segment; a rule
  is supposed to cost less than the prompt line it replaces).
- **Expiry is mandatory for a recurring (`every`) schedule, and both
  bounds are always active, whichever the operator states or not**:
  `max_fires` defaults to and caps at `1000`; `expires_after` defaults to
  and caps at `604800` seconds (7 days, matching Claude Code's own
  auto-expiry). Whichever bound is hit first ends the schedule. This is
  a deliberate tightening of "cap 1000 *or* cap-and-default 7 days" into
  "both bounds, always, earliest wins": it fixes a single worst case
  instead of leaving a 60-second-interval, 7-day, no-`max_fires` schedule
  free to leave 10,080 fire-marks rather than 1,000. Worst case per
  schedule is exactly 1,000 fire-mark rows — 1,001 for one extra tick
  under an exceedingly narrow crash race (the scanner killed between
  committing the 1,000th mark and that commit's visibility, a slot
  boundary crossed in that same window, and the restart's first scan
  landing before the dead incarnation's commit applies), which per-
  occurrence exactly-once survives untouched and the very next tick's
  scan corrects by expiring the schedule — and worst case per session is
  `max_schedules x 1000 = 16,000` rows, which is what
  `client/schedulescan.read_prefix` scans directly off the store (never
  through the writer) on the rare tick that computes an expiry from
  scratch — bounded, not open-ended, in the same sense `client/rules`
  bounds a config-driven scan cost.
- One-shot (`at`) schedules have no expiry field: their occurrence count
  is 1 by construction.

## Cut list

Shipped: `[[schedule]]` config; a fixed `every = "Ns"` interval or a
one-shot `at` (RFC3339, UTC); a `target` strand name (default `"main"`);
steer-only delivery to an open run, held when idle by default; opt-in
`wake = true` for the new marking fresh-run door; coalesced one-late-fire
catch-up; fenced non-authority injected framing (`client/rules.injection`'s
shape, plus a late annotation); the bounds above; tests on the injected
timers seam under the deterministic simulation runner.

Cut, deliberately, not merely deferred:

1. Five-field cron syntax — parsing, DST and timezone semantics are a
   swamp neither prior-art use case needs; fixed interval + one-shot
   covers watching a subagent and polling unattended.
2. All timezone handling — every timestamp is UTC/epoch seconds.
3. A model-facing self-scheduling tool (see Model-writability above).
4. Cross-session or cloud routines, and completion notifications.
5. Webhook-triggered fires.
6. Jitter — single-session, no thundering herd to smear.
7. `follow_up` as a delivery mode — steer only, matching `rulescan`.
8. Live update tooling (a client command to add/edit/remove a schedule
   without a restart) — edit the file, restart the server, like rules.

## The falsifier that was checked before implementing

The advisor's proposed cheapest falsifier — whether the fresh-run
admission path can carry a mark in the *same* transaction the way steer
admission does — was checked directly against `runtime/api.gleam` before
any implementation began (see the code excerpt above): `marked` and
`commit_admission` are already generic over `tx.Tx` and `Option(Mark)`,
so `accept_request` needed only a threaded `Option(Mark)` parameter, no
new transaction-composition mechanism. The design's exactly-once story
holds. What remains to prove in code, per the simulation runner: a
`wake = true` schedule firing exactly once with the mark landed; a
scan-actor restart between decide and commit losing the race to its own
earlier self (`FactConflict`, no second admission); and a reboot past a
missed window producing exactly one late fire, not a replay of the
backlog.

## Where this leaves the doc graph

`docs/architecture/messaging.md`'s durable-vs-ephemeral table gains a row
for a scheduled fire (a commit, never lost) beside the fire-mark it lands
with. `packages/client/CLAUDE.md` and `packages/runtime/CLAUDE.md` gain
the new types and the marking-admission invariant respectively. Neither
package's per-package doc existed for #27 as a separate
`docs/architecture/*.md` file, and this follows the same precedent rather
than inventing a `scheduling.md`.

---

## Addendum: model-created schedules, and the reversal of the cut

The ruling above cut model-writability entirely — "cut, not deferred" —
on the argument that a self-scheduling model extends its own liveness and
spend unsupervised. That cut has been reversed. The tools exist
(`tools/schedule`: `schedule_create`, `schedule_list`, `schedule_cancel`),
the operator's say is one knob with three positions
(`client/schedule.Policy`), and **the default is open**.

The original argument was not wrong; it was under-decomposed. It reads as
one argument and is really two, of very different strength.

**Liveness.** A schedule that may wake an idle strand keeps a session
working after everyone has gone home. This is the sharp one, and it is
the one the cut was really about.

**Spend.** A schedule that may only steer a run already open cannot
extend liveness at all — it holds when the strand is idle, exactly as a
triggered rule does, so the session still ends when the work in flight
ends. All it can do is add turns to a run that was going to happen
anyway.

Separating them offered an obvious middle position: register the tools,
force `wake` false. That was built (`ModelSchedulesSteer`) and rejected as
the *default*, because it is not really a feature. A heartbeat exists to
fire when nobody is prompting — to check on unattended work, to poll
something that changes on its own — and one that can only steer an open
run never fires when it matters. Shipping it as the default would have
meant shipping a cron that reads as broken.

So the default is `ModelSchedulesWake`, and what makes that defensible is
that the guardrail is structural rather than postural. It is the same
guardrail the original ruling identified as what made operator `wake =
true` safe, and it applies unchanged to a model:

- Every recurring schedule expires. Both `max_fires` and
  `expires_after_s` are always active, earlier wins, and **a model cannot
  raise either** — `build` holds a model's request to exactly the bounds
  `parse` holds a `[[schedule]]` to, through the same predicates.
- A model-created schedule fires onto the strand that created it and no
  other. There is no `target` argument.
- One session holds at most `max_model_schedules` of them, counted live,
  so a cancel frees a slot and a creation loop meets a wall it can read.
- The session is one an operator is running and can stop.

The worst case *per schedule* is therefore bounded and computable.

### Correction: the bound is per schedule, not per session

An adversarial review of this change found that the paragraph above, as
first written, claimed more than the code delivers. It said a model "can
wake itself, and cannot wake itself indefinitely." **The second half is
false**, and the mechanism is simple enough that it should have been
caught before the reversal shipped.

Expiry is derived from fired-marks under
`schedule/fired/<strand>/<name>/`. A *fresh name* is therefore a *fresh
clock*. A model with a `wake = true` heartbeat is, by construction, a
running model every time that heartbeat fires — and a running model can
call `schedule_create` again. So `hb-1` runs to its bound, and at any
fire along the way the model creates `hb-2`; or it cancels `hb-1`, which
frees a ceiling slot, and recreates it under a new name. Nothing in
`scheduleseam.create` prevents this, and the `max_model_schedules`
ceiling does not either: it bounds how many schedules exist at once, not
how many a session may create over its life.

What actually holds is narrower, and it is what the code should be read
as claiming:

- **No single schedule is unbounded.** Every recurring one expires on
  both bounds, earliest wins, and no model can raise either.
- **No session holds more than `max_model_schedules` at a time.**
- **Nothing here escapes the session.** Every schedule dies with the
  server, and an operator who stops it stops all of them.

What does *not* hold is "a model cannot keep a session alive
indefinitely." A model that wants to can chain wakes for as long as the
operator leaves the server running. Whether that is acceptable is a
policy question rather than a bug — it is a *cost* and *supervision*
concern, not an escape — but the original ruling's objection was exactly
this, and the reversal above does not answer it. It narrows it: the
liveness a model extends is bounded by the process an operator controls
and can see, rather than being unbounded in the way the original note
feared.

An operator who wants the strong property has `ModelSchedulesSteer`,
under which no model-created schedule can wake an idle strand at all, and
`ModelSchedulesOff`. Whether the *default* should remain
`ModelSchedulesWake` given the chaining hole was left as **issue #161**
rather than silently settled here; the section below records how it was
settled.

### The default moved to `steer`

Ruled while the PR was being taken to merge, on the priority order the
repository is built to: isolation, then correctness, then robustness,
then performance, then capability. The open default was a capability
argument — a heartbeat that can only steer never fires when a heartbeat
is for — resting on a safety claim the correction above withdrew. Once
the per-schedule bound stopped bounding the session, the posture that
lets a model keep a session running unsupervised became the operator's
to opt into rather than the build's to assume.

So `default_policy` is `ModelSchedulesSteer`. The tools are still
registered by default, a model can still create schedules for itself,
and every one of them steers an open run and holds when the strand is
idle. `wake` is one line of `loom.toml` away, and the example config
says what choosing it permits. A model that asks to wake under the
default gets a schedule that steers and a result that says so, which the
tool already did under a `steer` policy, so nothing about the model's
side of the door changed. Issue #161 closes with this: the chaining
property is now something an operator accepts by writing `"wake"`, not
something the default ships.

### The rest of what that review found

Three findings were fixed on the branch: the scanner leaked a timer chain
per `poke`, an unbounded timer delay could kill the scanner silently, and
`injection` told every fire it was operator configuration including ones
the model wrote. Four were filed rather than fixed, because each needs a
decision or new mechanism rather than a correction:

- **#161** — the chaining hole above, and whether the default survives it.
- **#162** — concurrent `schedule.create` through the *code-mode* door can
  double-create and over-admit. The "Exclusive, one batch at a time"
  argument in `client/scheduleseam`'s doc covers the tool door only;
  `ServedHere` plans run on their own processes.
- **#163** — schedules on a settled subagent strand are uncancellable,
  burn the session ceiling, and with `wake = true` re-open runs on that
  settled strand. The inverse of the ownership question #154 is waiting
  on: we refused to let a parent schedule onto a child, and a child can
  schedule onto itself indefinitely.
- **#164** — cancellation tombstones grow the config prefix without
  bound, and every tick and every seam call reads the whole prefix.

### What this cost, and what is still not built

Two things the ruling above suggested are still not built, and neither
became necessary.

The **escalation-gated grant** — model requests, operator approves — was
the shape the original note proposed if self-scheduling were ever wanted.
It was not taken, and the reason is worth recording: `gateway.attached`
answers zero when nobody is watching, and the escalation seam settles as
a refusal rather than parking on a prompt no one will answer. So a model
could only ever get a schedule approved *while someone was present*,
which is precisely when a heartbeat is least needed. The authority is
absent exactly when the capability matters. A `CallScope`-shaped approval
also does not fit a schedule, which is not a call.

**Scheduling on behalf of a subagent** — the motivating case the ruling
names for `wake` — is still not possible. A strand may only schedule onto
itself. Letting a parent schedule onto a child needs a lineage check and
an ownership argument (the parent extends the child's liveness, which it
already controls, not its own) that nobody has written down. It is the
obvious next increment and it is deliberately not in this change:
**issue #154**.

Two smaller things are also owed a decision rather than a fix.
`cap/schedule` is on the workspace seam and not the orchestration one,
because the intersection of those two allowlists is a confinement
property a test asserts and widening it costs a real guarantee
(**issue #156**). And a schedule that never once fires never expires,
because the expiry clock is measured from the earliest fired-mark and a
schedule with no marks has none — a cost question rather than a safety
one, but `expires_after_s` reads to an operator like something it does
not mean (**issue #157**).

### The collision nobody would have found by reading

Both kinds of schedule feed one scanner, which derives a fired-mark from
`{target, name}` alone. Two schedules sharing both would share a mark and
silently suppress each other's fires. Neither parser can catch it —
`parse` never sees a model's names, and by the time the scanner has them
they are indistinguishable — so the check lives in the seam, which is the
one place that holds both lists at once (`client/scheduleseam`'s
`Wiring.operator_schedules` exists for exactly this and nothing else).
