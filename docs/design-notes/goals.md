# Session goals

Exploratory design note for the `/goal` feature: a persistent objective the
operator pins to a session, which the session keeps working toward
autonomously — continuing while idle, accounting the primary's token spend
against a required budget, and stopping when a reviewer judges the
objective achieved. The external reference is Codex's `/goal` (analyzed in
detail against `openai/codex@2abdeb34d5`); the question here is what the
same feature looks like when the harness already owns an advisor plane.

Status: design accepted by the operator (reviewer-judged completion;
primary-only accounting), amended after a first adversarial review pass,
and substantially reworked after a second pass read the implementation
rather than the draft. The second pass found that the loop as built was
edge-triggered on lossy casts with its phase in the actor's heap, that
the accounting had two code paths and both were wrong, that two of the
three "non-optional" bounds could not fire, and that the stopped statuses
did not record why they had stopped. The loop is now level-triggered over
a durable phase, and the transitions are a pure function
(`client/goalloop`) the state space is property-tested through. The
protocol proposal (`protocol-change/044`) is the implementation contract;
its two Review sections record each finding and its disposition.

---

## What a goal is

A goal is **operator-authored data plus a harness-owned state machine**, and
the distinction is the whole design. The objective text is never authority:
it reaches the primary and the reviewer inside frames that name it as the
operator's objective, exactly the way advice text is framed as a review
rather than an order. The state machine — who may flip which status — is
owned by the operator and the harness, never by either model.

```
            goal_set (operator)                     goal_clear (operator)
              ┌────────────┐                              ┌─────────┐
              ▼            │                              ▼         │
           Active ────────┼─ pause (operator) ─▶ Paused ──┴── clear  │
              │  ▲         │  continuation cap (harness)    │       │
              │  │         │  zero-progress ×2 (harness)    │       │
              │  │         │                          │    │       │
              │  │         └── abort of a goal-woken   │    │       │
              │  │             run (harness: the gateway's abort   │
              │  │             handler casts the actor, which      │
              │  │             gates on the durable phase; an      │
              │  │             aborted run never reaches run_end)  │
              │  │                                          │      │
              │  │          budget exhausted (harness)     resume    │
              │  │            (one-shot wrap-up)       (operator)   │
              │  └────────────── resume (operator) ───────┤        │
              ▼                                             ▼      │
        Limited(by) ───────────────────────────────────▶ Active    │
              │                                                      │
              │  Complete (reviewer verdict)                          │
              ▼                                                       │
           Complete ─────────── clear ────────────────────────────────┘
```

One goal at a time, stored in one durable cell, like Codex. The two
stopped states carry a reason (see below). `Complete` is terminal; setting a new goal after one completes starts a fresh cell with
fresh accounting.

## Why the advisor plane is the right host

Every load-bearing piece of Codex's goal runtime has an existing Loom
counterpart, and the ones that are hard — the isolation between the worker
and the judge — are the ones Loom already built for review:

| Codex built | Loom already has |
|---|---|
| Rollout rendering into a review prompt | `client/advisorslice` feed (bounded, cursor-tracked, thinking redacted) |
| Goal row in sqlite, one per thread, optimistic concurrency | Reserved `fact.custom` cells under `advisor/`, single-writer actor |
| `goal_runtime_apply` event dispatcher | The advisor actor's hook slots (`run_end`, `usage`) |
| `MaybeContinueIfIdle` — auto-continuation | The nudge **idle-wake door** (`deliver_nudges` starting a run on an idle primary) |
| Token accounting from usage events | The `usage` hook's committed `UsageRow` |
| `<untrusted_objective>` framing + XML escaping | `advisorslice` frame headers/footers, `frame_safe` |
| `budget_limit.md` one-shot wrap-up steer | The block channel + duplicate ring ("already told" is exactly `budget_limit_reported_goal_id`) |
| Plan-mode opt-out | — (no plan mode; not needed) |

The one deliberate divergence is **who declares completion**.

## Reviewer-judged completion

Codex gives the primary an `update_goal(complete)` tool and then spends its
whole continuation template telling the model not to declare the goal
complete because "the work felt thorough" — and its `get_goal`/`create_goal` tools invite the
model to reason about goal state it should not own. Loom's isolation
doctrine solves this structurally instead of rhetorically: **the strand
that does not share the worker's context is the one that judges whether the
work is done.** The primary gets no goal tool at all. The reviewer — the
advisor — answers a goal feed with one of two new verdicts:

- `continue(text)` — the objective is not achieved; wake the idle primary
  with a framed continuation carrying the objective (as data) and the
  reviewer's "what remains" text.
- `complete(text)` — the objective is achieved; the status flips to
  `Complete`, the reviewer's text is recorded with it, and the loop stops.

The old three verdicts keep their existing meanings on ordinary feeds — and
on ordinary feeds alone. On a goal feed the **only** legal answers are the
two goal words: `quiet`, `nudge` and `block` there are in-band errors naming
the two acceptable words, the same pair-decision discipline the decoder
already uses for a `quiet` carrying text. The first draft read `quiet` as
"ask again later", which the review pass showed is a silent stall — an
idle primary has no next occasion, so the goal sits open forever with
nothing running. A reviewer that answers the wrong words fails loudly in
its tool results instead.

Costs of the divergence, stated plainly: completion waits on the reviewer
(a goal genuinely finished in one turn costs one extra review to
certify), and a lazy reviewer can under-certify (say `continue` forever)
or over-certify. Both are bounded: the required token budget and the
harness's continuation cap are the backstops for the first, and the
operator's `/goal clear` and `/goal pause` are the override for either. (An
earlier draft left the budget optional and named it the only backstop; the
review pass showed that an unbudgeted goal with a generous reviewer is an
unbounded loop, so v1 requires a budget and adds the cap.)

Because the primary has no goal tool, nothing the primary can do marks
its own work complete. That is the difference between preventing the
failure Codex's continuation template argues against and arguing against
it.

## The loop, in one place

The loop is **level-triggered**. Every message the advisor actor receives
is an occasion to ask one question — given the goal as stored and what
the two strands are actually doing, what should happen now? — and the
answer is a pure function, `client/goalloop.next_action`. The actor
gathers the facts, calls it, performs the action it returns, and stores
the goal. It decides nothing itself.

This replaced an edge-triggered first implementation, and the reason is
the design's own premise. An idle primary has no next occasion. So any
notification the loop needed and did not get left an Active goal with
nothing running, nothing scheduled, and a panel that said it was working.
There were five ways to lose one: a daemon or supervisor restart, a
reviewer run that ended without a verdict, a failed send of the feed, a
dropped accounting cast, and a feed the loop declined to send because the
branch had nothing new on it. Under level triggering each of those costs
one evaluation's delay instead, because the next evaluation reads the same
level and reaches the same answer.

Three things make that work.

**The phase is durable.** The goal cell carries `phase`: `idle`,
`awaiting_verdict` naming the advisor run that owes the verdict, or
`continuing` naming the primary run the loop itself opened. A replacement
actor reads it and knows a verdict is owed and by whom. The three
counters that bound the loop are durable for the same reason: a bound a
restart forgets is not a bound.

**Every notification is redundant.** A run that ended is a run the store
no longer shows open, so the phase and the store together say what a lost
cast would have said. `AwaitingVerdict` whose advisor run is gone is a
feed nobody answered; `Continuing` whose primary run is gone is a woken
run whose end was never announced. The notifications remain because they
make the loop prompt, not because it is correct only with them.

**A periodic tick asks.** `weft/actor`'s own `periodic`, armed once in
`start` for the actor's life, every two minutes. It is armed
unconditionally rather than when a goal exists, which is what makes "an
Active goal with no evaluation pending" unrepresentable; a session with no
goal pays one message that reads a cached absence.

Arming it only while a goal is active would be better and `weft/actor`
cannot express it: `periodic` is a builder field, not something a `Next`
carries, so a handler can neither cancel nor re-time it, and there is no
one-shot on the public surface a handler could arm instead. The primitive
that can is `weft/state_machine`'s named-timeout pair, which means porting
this actor to a state machine — worth doing on its own terms rather than
inside the goal loop. The interval is two minutes rather than thirty
seconds for a reason that is not about the loop at all: the tick is only
the recovery path, since every real occasion evaluates at once, and an
unconditional tick keeps this actor out of hibernation, so it should be
comfortably longer than the idle window a `hibernate_after` would use.

The occasions, then, and what each contributes:

1. The operator sets a goal (`/goal <objective>` or `goal_set`). The cell
   is written by the advisor actor, which owns the `goal/` reserved
   prefix, and the command is followed by an evaluation — a goal pinned
   onto an idle primary must start on its own, because an idle primary has
   no next run end.
2. The primary works. The evaluation recomputes the accounting from the
   ledger (below) before it decides anything, so a bound is read against a
   fresh number.
3. The primary's run ends with the primary idle and the goal Active, and
   the evaluation sends the advisor a **goal feed**: the same bounded slice
   machinery, in a frame naming the objective, the budget spent and
   remaining, and the question. A feed with nothing new on the branch is
   still sent, with a line saying so, because that is exactly what `/goal
   resume` finds on an already-reviewed idle primary.
4. The advisor answers, and only the two goal words are legal here.
   `continue` → the actor wakes the idle primary with a framed
   continuation through a goal door of its own, not the nudge wake door.
   `complete` → the status flips and the loop stops. `quiet`, `nudge` and
   `block` on a goal feed are in-band errors naming the two acceptable
   words: an idle primary has no next occasion to retry at.
5. A reviewer run that ends owing a verdict returns the phase to idle, so
   the next evaluation re-offers the feed. That is bounded: three
   consecutive unanswered feeds pause the goal with
   `reviewer_unresponsive`, because a provider that will never answer the
   goal words should be reported rather than paid to refuse forever. A
   feed the host would not deliver at all counts against the same bound.
6. The woken run's own end steps the loop again. The loop is closed by its
   own bounds rather than by the one-per-operator-turn nudge budget, which
   exists to kill self-feeding loops and would be the wrong instrument
   here; the nudge channel keeps its one wake per operator turn through an
   arbitrarily long goal loop.
7. A bound reached stops the loop wherever it stands, including inside a
   run, and one harness-authored wrap-up reaches the primary. The wrap-up
   is one-shot structurally rather than by a duplicate-ring guard: the
   goal is already `Limited` when the action is returned, and a `Limited`
   goal rests, so no later evaluation can reach the action again until the
   operator resumes.
8. The operator aborts a run the loop opened → the goal is held with
   `aborted` as its reason, never cleared. An aborted run bypasses the
   run-end hook, so the abort is observed where it enters: the gateway's
   abort handler casts the actor, which gates on the durable phase.

## The three bounds

None optional, and the second and third are stated here because the first
implementation could not fire either of them.

1. **The token budget**, required. Crossed → `budget_limited` with reason
   `token_budget`.
2. **A continuation cap** of eight, counting continuations *since the last
   run start on the primary that the loop did not open*. That reset is the
   whole bound: without it the count only ever rose, so the cap was a
   lifetime cap and `/goal resume` after a trip tripped again on its first
   evaluation. A run start the loop did not open is the operator, a
   schedule or another layer arriving with work of their own, and an
   operator resume clears it too. Crossed → `budget_limited` with reason
   `continuation_cap`.

   Two things about that reset are worth stating plainly, because both
   decide how much the cap is worth. The runs the *harness* opens do not
   reset it, and the phase alone cannot say which those are: the harness
   opens runs for a goal continuation, for a reviewer's nudge wake, and
   for a tripped bound's own wrap-up, and only the first is in the phase.
   Read as somebody arriving with work, the other two cleared the cap, so
   a reviewer that nudged between continuations could hold the bound off
   for as long as it kept nudging. The run start therefore carries who
   opened it (`goalloop.Origin`) rather than leaving the loop to infer it.

   And a run start the *model* arranged — a schedule it created, a
   background job's wake, a sub-agent's result coming back — does reset
   it, because nothing in the harness can tell one from the operator's own
   prompt. Under a primary that schedules its own wakes the cap is
   therefore not binding, and the token budget is the bound that is. That
   is a limit of the cap rather than a gap to close: a cap that tried to
   distinguish the two would be guessing about intent from the shape of a
   run, and would stop the operator's own work the first time it guessed
   wrong.
3. **Zero-progress suppression.** A goal-woken run that committed no tool
   result and no operator turn did no work toward the objective; two in a
   row pause the goal with reason `zero_progress`. The predicate has to
   exclude the harness's own frames, and the first implementation did not:
   it counted any user message as progress, and a goal continuation *is* a
   user message, committed after the feed cursor advances. So every woken
   stretch contained one, every stretch "progressed", and the bound could
   never fire. The predicate now recognizes the three frames this harness
   writes by their two-token pairs, which is also what stops a model
   promoting its own output into work by quoting a header.

## Why a status carries its reason

A stopped status without its cause tells the operator nothing they can
act on. The first implementation wrote `paused` for an operator pause, an
abort, and zero-progress suppression alike, and wrote `budget_limited`
with the words "the goal's token budget is exhausted" whether the budget
or the continuation cap had tripped — a false statement half the time.

So `Paused` and `Limited` carry a cause: `operator`, `aborted`,
`zero_progress`, `reviewer_unresponsive`; `token_budget`,
`continuation_cap`. The status word on the wire does not move — the four
words of 044 §1 are unchanged — and a sibling `reason` field carries the
cause, null for the two statuses that have none. The cause reaches the
`goal_get` board, the panel, the wrap-up the primary reads, and the
refusals the reviewer reads, all worded from one place.

## Accounting

- Only the **primary's** usage rows count. The reviewer's own spend is the
  cost of judging, not of working — it is the operator's cost of running
  an advisor, already paid on every review, and counting it would let the
  reviewer's verbosity eat the worker's budget.
- The delta is `(input − cache_read − cache_write)` floored at zero, plus
  `output`. `reasoning` is a subset of `output` and is not added on top;
  `cache_write_1h` folds into cache write. Dollar cost rides along in
  `Usage.cost.total` and is recorded for the panel, never for gating.
- **One code path adds.** There were two, and both were wrong. The cast
  path added a row's tokens on arrival and moved `accounted_through_seq`
  to *that row's* seq, so a cast lost for seq 101 followed by a delivered
  cast for 105 skipped 101 forever — the permanent undercount this design
  says cannot happen. The ledger path filtered with a predicate that was
  always true, so `set.contains` was never called and the reviewer's own
  spend, which lands after the primary's last row on every cycle, was
  charged to the primary's budget.
- Now the `usage` hook's cast is a **trigger carrying nothing**. It makes
  the ledger scan prompt, which is what lets the budget trip at the row
  that crosses it rather than at the primary's next idle boundary, and
  losing it costs the delay to the next evaluation. The scan reads rows
  past `accounted_through_seq` and counts a row when the entry it names is
  on the primary's branch — the attribution the gateway itself uses, since
  `UsageRow` carries an `entry_id` and no strand. The branch scan is
  bounded by the accounting window rather than by a row cap, because a
  capped set is a *prefix* of the chain and would drop the primary's older
  rows as foreign once membership is actually tested.
- Two under-counts are stated rather than guessed at. A row whose
  `entry_id` is `None` — a structural summary's own spend — is not
  counted, because which strand a compaction belonged to is a guess. And a
  row whose entry was committed at or below the cursor is not counted:
  entries and usage rows draw from one session-wide seq counter and a row
  is written in the same transaction as its entry, so this needs two
  strands committing across one another, and the loss is one row of a
  budget the bound reads as a floor.
- No compare-and-set. The CAS door in this tree claims absence, and the
  loss mode here is a dropped cast, which no CAS catches. A single writer
  with a recomputable value is the honest shape.

## The state, and who owns it

| State | Where | Model-writable? |
|---|---|---|
| Goal cell: objective, status, reason, phase, budget, tokens_used, cost, the three bound counters, created/updated | reserved `goal/` cell (single writer: the advisor actor) | No — `put_fact` refuses the prefix, like `advisor/` |
| Verdicts | `advise` tool arguments | The reviewer's only lever; the actor translates |
| `continue`/`complete` availability | Whether the feed frame carries the goal question | Harness-chosen, per feed |
| Status transitions | `client/goalloop`, a pure function the actor calls | Operator (`pause`/`resume`/`clear`/`set`), harness (bounds, abort), reviewer (`complete`) |

Nothing the loop decides from lives in the actor's heap any more. That was
the first implementation's shape and it is what made a restart lose the
loop; the actor's only goal state now is a cache of the cell it just read.

The **primary** never sees the goal cell, has no goal tool, cannot address
the advisor (no lineage cell — already true), and reaches the goal only as
framed text. The **reviewer** reaches the goal only as the feed frame's
data and its own verdicts. The **operator** sees everything, with the
reason a stopped status carries.

## Frames

Three new frames ride the existing `advisorslice` conventions (header +
footer, `frame_safe` bodies, two-token recognition, terminal suppression
and labelling in feeds):

- **Goal feed** → advisor: `[advisor goal feed: the primary stopped with
  the session's goal still open]` … objective, budget lines, the slice,
  and the ask — "answer with `continue` or `complete`".
- **Continuation** → primary: `[goal continuation]` … the objective in
  untrusted framing, budget lines, and the reviewer's `continue` text as
  review-framed advice. The primary's model reads a harness frame it has
  seen before (advice frames), not an operator turn.
- **Wrap-up** (budget) → primary: one-shot, harness-authored, review voice.

The continuation's budget lines are the same numbers the panel shows,
rendered by one shared function, so the model and the operator cannot be
shown different books.

## Surfaces

- TUI: `/goal <objective>` (inline arg, like `/effort`), bare `/goal`
  (status panel: status and its cause, objective, tokens used/budget,
  cost, continuations, ages, reviewer note), `clear`, `pause`, `resume`
  subcommands; palette entries. A goal row in the pending/advisor panel
  area for as long as a goal is pinned. The grammar is below.

### The `/goal` grammar

```
/goal                                 show the status panel
/goal clear | pause | resume          the matching mutation
/goal [--budget <tokens>] <objective> pin or replace the goal
```

An objective is free text, so every rule that reads a word out of it is a
rule that can take one by mistake. Two decisions keep that from happening,
and both were chosen over the alternatives on purpose.

**A subcommand is a subcommand only as the whole argument.** `/goal clear`
unpins the goal; `/goal clear the failing test` pins that objective. The
same holds for `pause` and `resume`. An operator whose objective happens to
be one word — `/goal clear` meaning "pin the objective *clear*" — cannot
say it, and that is the cost: one word each for three words, against
silently unpinning a goal somebody was trying to pin.

**The budget is carried by `--budget` in the first position and nowhere
else.** A trailing integer is a word of the objective: `/goal fix issue
468` pins that objective with the default budget rather than a 468-token
one. The alternative — reading a trailing integer as the budget — needs an
escape form for every objective that ends in a number, which is a common
shape ("fix issue 468", "get the 3 flaky tests green"), and the failure is
silent: a goal pinned to a spend nobody chose looks exactly like a goal
pinned correctly until it trips. The flag's own argument is digits with
optional `_` separators (`200_000`), and no `k`/`m` suffix: an explicit
number in a command that pins a spend is worth the keystrokes. A flag whose
argument is not a positive count is refused, with the rejected word shown
back — never defaulted, for the same reason.

**A `/goal` with no budget pins a default of 200,000 primary tokens**
(`command.default_goal_budget`) rather than being refused. The wire requires
a positive budget, so the terminal has to either supply one or make every
`/goal` carry a number. It supplies one because the loop has two harness
bounds besides the budget — eight consecutive turns, and suppression after
two that produce nothing — so a defaulted budget cannot run away
unobserved; and because the panel prints spend against budget from the
first read, so an operator who wanted a different number sees this one
immediately. The row confirming the goal names the budget and names the
flag that sets it.

The palette completes `/goal` and, past its space, the three subcommands
and `--budget`; the rows stop matching as soon as the text stops being one
of those words, so an objective is offered nothing.

An unrecognized status word on the board is refused and worded — there is
nothing left to place it against — while an unrecognized *reason* word
keeps the board and shows the server's `because` sentence, which is what
`docs/client-protocol.md` §4.9.26 asks a client to do. Every goal command a
server refuses, including the `code_unsupported` an older daemon or a
session with no advisor answers, reaches the operator as a sentence: a
panel that silently fails to appear looks exactly like a session with no
goal.
- Gateway: `goal_set`/`goal_get`/`goal_clear`/`goal_pause`/`goal_resume`
  session commands, owner-only mutations beside `rename`'s discipline,
  read-only observation for the panel (a subscribed read like
  `advisor_pending`). The protocol proposal owns the wire shapes.
- Configuration: none new. A goal requires a routed advisor; that is the
  gate. (Deliberately no `[goals]` table for v1 — the advisor's
  `[advisor]` table already configures the judge.)

## An operator-supplied check: designed, not built

The reviewer judges the objective from a rendering of what the primary
did. That is evidence about the work, not evidence about the result: a
reviewer reading a transcript in which the tests were run and passed is
reading the primary's account of the tests passing. An operator-supplied
check closes that gap. `goal_set` would take an optional `check`, a shell
command string; before each goal feed the harness would run it and the
feed frame would carry a `Check:` block with the command, its exit status
and a bounded tail of its output, labelled as harness-run evidence. The
reviewer would still give the verdict, and the tool description would say
that a failing check is strong evidence against `complete`.

Two properties are not negotiable and shape everything below. The command
is operator-authored, so it is not model-influenced text — but Rule Zero
is about where code runs, not about who wrote it, and a command that ran
in the harness VM would be a hole in the effect plane whatever its
provenance. So it runs through the same capability-checked, jailed effect
path an ordinary tool command takes, with the session's workspace, a
bounded wall clock and a bounded captured output. And the output is
untrusted once it exists: a check that prints an objective delimiter or a
frame footer must not be able to close the frame it is quoted inside, so
it is made frame-safe the way every other quoted body in `advisorslice`
is.

**This is designed and deferred rather than blocked, and the distinction
matters because an earlier draft of this note claimed an obstacle that
does not survive inspection.** The claim was that the effect plane cannot
be reached from here: `broker.clear_call` and the collector that reads its
events are synchronous *in the calling process* — by design, since a
broker that parked on checkout would deadlock, so the wait for a pool slot
happens in the borrower — and the advisor actor cannot block, because it
answers the nudge drains at the primary's run start and run end on the
strand driver's critical path under `pending_timeout_ms`. All of that is
true. What it does not imply is that the check cannot be run, because the
call does not have to happen on the actor's process.

The level-triggered loop is what makes the off-actor shape cheap, and
every primitive it needs is already in the tree:

- **The task.** `weft.new([...]) |> weft.deadline(within:) |>
  weft.start_witnessed(...)` is the deadline-bounded spawn `docs/weft.md`
  prescribes. The task body blocks on the broker as much as it likes and
  reports back to the actor by name; the actor never blocks, and a task
  killed at its deadline simply reports nothing.
- **The jailed path.** `tools/tool.broker_runner(broker:, waiting:)` is the
  same closure the `bash` tool clears through, so the check admits under
  exactly the rules a model-authored command does: the same requirements,
  the same `RefuseNarrowed`, the same enforcement demand, the same
  escalation path. A wall clock and an output ceiling are expressed the way
  `client/hookrunner` expresses them — `limits.wall_s`, `limits.output_bytes`
  and a `Budget` deadline.
- **The wiring.** `client/jobs.Wiring` is the precedent and carries exactly
  the fields needed: `clear_call`, `base_policy`, `demand`, `env`,
  `workspace`, `clock`, `seed`. Every one of them is in scope in the same
  function that builds the advisor's wiring, a few lines above it.
- **The recovery.** A lost result and a dead task need no new mechanism.
  The phase gains `Checking(deadline_ms)`, and the periodic evaluation
  already asks the only question that matters: a `Checking` phase past its
  deadline records "the check did not finish" as the evidence and feeds the
  reviewer with it. The loop cannot stall on a check for the same reason it
  cannot stall on a feed.

The shape, then, concretely: `Phase` gains `Checking(deadline_ms: Int)` and
`ReadyToFeed`; `Action` gains `RunCheck(command)`; `Event` gains
`Checked(outcome)`; the goal gains `check: Option(String)` and a recorded
last outcome for the panel. `Idle` with a check configured answers
`RunCheck` instead of `FeedReviewer`; `Checked` records the outcome and
moves to `ReadyToFeed`; `ReadyToFeed` feeds. `ReadyToFeed` exists so the
check runs once per feed rather than in a loop with it, and it is
unreachable without a configured check.

Nothing in that list is a frozen interface. `broker.clear_call`,
`CallSpec`, `effects.Hooks` and `advisor.Wiring` are all outside spec
Part 1, so no `protocol-change` proposal is needed for the mechanism; the
`goal_set` argument and the cell field are 044's own surface and are
recorded in 044 §8. What it needs is a wave of its own, because it adds an
off-process effect path to an actor that has none, and reviewing that
together with the loop rework would mean reviewing two unrelated risks at
once. It is deferred for that reason and for no other; nothing in the
tree prevents it.

## Deliberately not built (v1)

- **Wall-clock time budget.** Codex accounts elapsed seconds; Loom's
  sessions outlive terminals and a wall-clock number across daemon
  restarts is a misleading book. Token budget only; the panel shows the
  goal's age.
- **A model-facing goal tool.** The primary gets nothing; the reviewer's
  verdicts are the only model-reachable lever, and only `complete`/`continue`.
- **Multiple concurrent goals.** One cell, one goal. The complexity of a
  ledger of goals buys nothing the operator cannot get from a fresh
  session.
- **A `paused` popup on resume.** The TUI shows status in the panel;
  no modal flow for v1.
- **The operator-supplied check.** Designed above down to the phase
  variants and the primitives, and deferred to its own wave rather than
  blocked: it adds an off-process effect path to an actor that has none.
- **`continue` carrying explicit task instructions to inject.** The
  continuation frame carries the reviewer's text verbatim as advice; it
  does not become the operator's voice. If reviewers need to direct work
  more sharply, that is a `block` on the next ordinary feed.

## Open questions for implementation

All three were settled by the review pass and are frozen in the protocol
proposal (044):

1. **One actor.** The goal loop extends `client/advisor` — the goal state
   machine is another translation of verdicts and another cell, and the
   actor already owns the occasions, the wake door, and the isolation. A
   sibling actor would re-derive all three and race the advisor for the
   same run-end moments.
2. **`quiet` is not answerable on a goal feed** — an idle primary has no
   next occasion, so a retrying loop stalls silently. The ordinary words
   are in-band errors there; the goal frame's footer asks for exactly one
   of the two goal words.
3. **The budget wrap-up steers a mid-run primary** (the block door): the
   budget trip is exactly a "stop soon" interruption. On an idle one it
   wakes, the same one-shot discipline.

Settled by the same pass, worth restating: the required budget, the
continuation cap and the zero-progress predicate are the loop's bounds;
the abort is observed at the gateway's abort handler (an aborted run never
reaches the run-end hook); and accounting is a seq cursor plus recompute,
never a CAS.
